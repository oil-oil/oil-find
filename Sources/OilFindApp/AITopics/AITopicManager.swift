import AppKit
import Combine
import OilFindCore
import SQLite3

/// Separate serial connections let reads continue while the importer commits individual topics.
final class AITopicManager: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var enabledProviders: Set<AITopicProvider>
    @Published private(set) var indexing = false
    @Published private(set) var failed = false
    @Published private(set) var count = 0
    @Published private(set) var diskBytes: Int64 = 0
    var onChange: (() -> Void)?
    var onAvailabilityChange: (() -> Void)?
    var isEnabled: Bool { enabled && !activeProviders.isEmpty }
    private let defaults: UserDefaults
    private let detectProviders: () -> Set<AITopicProvider>
    let url: URL
    private let locations: AITopicLocations
    private let writerQueue = DispatchQueue(label: "com.oiloil.find.topics.import", qos: .utility)
    private let readerQueue = DispatchQueue(label: "com.oiloil.find.topics.search", qos: .userInitiated)
    private let eventQueue = DispatchQueue(label: "com.oiloil.find.topics.events", qos: .utility)
    private let lock = NSLock()
    private var selectedProviders = Set(AITopicProvider.allCases)
    private var lifecycle = 0, queryGeneration = 0
    private var active = false, suspended = false
    private var writer: AITopicIndex?, reader: AITopicIndex?
    private var importer: AITopicIndexer?
    private var importerLifecycle: Int?
    private var initialImportPending = Set<AITopicProvider>()
    private var syncQueue = AITopicSyncQueue()
    private var failedProviders = Set<AITopicProvider>()
    private var watcher: FSWatcher?
    private var databaseWatcher: AITopicFileWatcher?
    private var codexDatabaseWatcher: AITopicFileWatcher?
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var running = false, started = false, visible = false
    private var lastProgress = Date.distantPast
    #if DEBUG
    private(set) var snapshot = false
    #endif
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Oil Find/ai-topics/index.sqlite")
    private static func providerPreferenceKey(_ provider: AITopicProvider) -> String { "aiTopicsProvider.\(provider.rawValue).enabled" }
    init(defaults: UserDefaults = .standard, url: URL? = nil, locations: AITopicLocations = .local,
         detectProviders: @escaping () -> Set<AITopicProvider> = { AITopicInstallation.installed() }) {
        self.defaults = defaults; self.locations = locations
        self.detectProviders = detectProviders
        self.url = url ?? Self.defaultURL
        enabled = defaults.object(forKey: "aiTopicsEnabled") as? Bool ?? true
        let installed = detectProviders()
        let storedProviders = Set(AITopicProvider.allCases.filter { defaults.object(forKey: Self.providerPreferenceKey($0)) as? Bool ?? installed.contains($0) })
        enabledProviders = storedProviders; selectedProviders = storedProviders
    }
    private func locked<T>(_ work: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return work() }
    private var activeProviders: Set<AITopicProvider> { locked { selectedProviders } }
    func isProviderEnabled(_ provider: AITopicProvider) -> Bool { locked { selectedProviders.contains(provider) } }
    func start() { guard !started else { return }; started = true; if !refreshProviderAvailability() { enabledChanged() } }
    @discardableResult func refreshProviderAvailability() -> Bool {
        let installed = detectProviders()
        let updated = Set(AITopicProvider.allCases.filter { defaults.object(forKey: Self.providerPreferenceKey($0)) as? Bool ?? installed.contains($0) })
        guard locked({ selectedProviders != updated }) else { return false }
        locked { selectedProviders = updated }
        enabledProviders = updated
        enabledChanged(); refreshCount()
        return true
    }
    func stop() {
        started = false; pending?.cancel(); pending = nil; timer?.invalidate(); timer = nil
        watcher?.stop(); watcher = nil
        databaseWatcher?.stop(); databaseWatcher = nil
        codexDatabaseWatcher?.stop(); codexDatabaseWatcher = nil
        locked { active = false; lifecycle += 1; queryGeneration += 1 }
        // Drain connections on their owner queues, without blocking the main thread.
        writerQueue.async { [self] in importer = nil; importerLifecycle = nil; initialImportPending.removeAll(); writer = nil }
        readerQueue.async { [self] in reader = nil }
    }
    deinit { watcher?.stop(); databaseWatcher?.stop(); codexDatabaseWatcher?.stop(); timer?.invalidate() }
    func setEnabled(_ value: Bool) {
        enabled = value; defaults.set(value, forKey: "aiTopicsEnabled"); enabledChanged()
    }
    func setProviderEnabled(_ provider: AITopicProvider, enabled value: Bool) {
        // An explicit selection overrides future automatic detection, even if the switch was already off.
        defaults.set(value, forKey: Self.providerPreferenceKey(provider))
        let updated = locked { () -> Set<AITopicProvider>? in
            guard selectedProviders.contains(provider) != value else { return nil }
            if value { selectedProviders.insert(provider) } else { selectedProviders.remove(provider) }
            return selectedProviders
        }
        guard let updated else { return }
        enabledProviders = updated
        enabledChanged()
        refreshCount()
    }
    private func enabledChanged() {
        let providers = activeProviders
        let usable = started && isEnabled && !providers.isEmpty
        locked { active = usable; lifecycle += 1; queryGeneration += 1 }
        #if DEBUG
        if snapshot { onAvailabilityChange?(); return }
        #endif
        pending?.cancel(); pending = nil; timer?.invalidate(); timer = nil
        watcher?.stop(); watcher = nil
        databaseWatcher?.stop(); databaseWatcher = nil
        codexDatabaseWatcher?.stop(); codexDatabaseWatcher = nil
        syncQueue = AITopicSyncQueue(); failedProviders.removeAll()
        onAvailabilityChange?()
        guard usable else { indexing = false; failed = false; onChange?(); return }
        // Enabled installations may create their data directory after Oil Find starts.
        var roots: [String] = []
        if providers.contains(.codex) { roots.append(locations.codex.path) }
        if providers.contains(.claude) { roots.append(contentsOf: [locations.claude.path, locations.claudeDesktop.path]) }
        if providers.contains(.workbuddy) { roots.append(locations.workbuddy.path) }
        roots = roots.map { path in
            var url = URL(fileURLWithPath: path)
            while !FileManager.default.fileExists(atPath: url.path) && url.path != "/" { url.deleteLastPathComponent() }
            return url.path
        }
        watcher = FSWatcher(paths: Array(Set(roots)), sinceWhen: FSWatcher.currentEventId(), latency: 0.15, queue: eventQueue) { [weak self] changes, rescan in
            guard let self else { return }
            let changed = rescan ? providers : Set(providers.filter { provider in changes.contains { self.affectsTopics($0.path, provider: provider) } })
            guard !changed.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in self?.databaseWatcher?.rescan(); self?.requestRefresh(providers: changed) }
        }
        _ = watcher?.start()
        if providers.contains(.codex) {
            codexDatabaseWatcher = AITopicFileWatcher(paths: codexDatabasePaths(), queue: eventQueue) { [weak self] in
                DispatchQueue.main.async { [weak self] in self?.requestRefresh(providers: [.codex]) }
            }
        }
        if providers.contains(.workbuddy) {
            databaseWatcher = AITopicFileWatcher(paths: [locations.workbuddy.path, locations.workbuddy.appendingPathComponent("workbuddy.db").path, locations.workbuddy.appendingPathComponent("workbuddy.db-wal").path], queue: eventQueue) { [weak self] in
                guard let self else { return }
                DispatchQueue.main.async { [weak self] in self?.requestRefresh(providers: [.workbuddy]) }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.requestRefresh() }
        requestRefresh(immediate: true)
    }
    func visibilityChanged(_ value: Bool) {
        visible = value
        if value { refreshProviderAvailability() }
        if value { locked { suspended = false } }
        if value { requestRefresh(immediate: true) }
        else { locked { queryGeneration += 1 } }
    }
    func backgroundIndexingChanged(_ busy: Bool) {
        let changed = locked { let old = suspended; suspended = busy && !visible; return old != suspended }
        if changed && !busy { requestRefresh() }
    }
    private func affectsTopics(_ path: String, provider: AITopicProvider) -> Bool {
        let path = Self.canonicalPath(path)
        let codex = Self.canonicalPath(locations.codex.path), claude = Self.canonicalPath(locations.claude.path)
        let desktop = Self.canonicalPath(locations.claudeDesktop.path)
        let workbuddy = Self.canonicalPath(locations.workbuddy.path)
        if provider == .workbuddy { return path == workbuddy || path == workbuddy + "/projects" || path.hasPrefix(workbuddy + "/projects/") ||
            path == workbuddy + "/storage" || path == workbuddy + "/storage/skeleton" || path == workbuddy + "/storage/skeleton/account-snapshot.json" ||
            ["workbuddy.db", "workbuddy.db-wal"].contains(URL(fileURLWithPath: path).lastPathComponent) && URL(fileURLWithPath: path).deletingLastPathComponent().path == workbuddy }
        if provider == .claude { return path == claude || path == desktop || path.hasPrefix(desktop + "/") || path == claude + "/projects" || path.hasPrefix(claude + "/projects/") }
        if path == codex { return true }
        guard path.hasPrefix(codex + "/") else { return false }
        let relative = String(path.dropFirst(codex.count + 1))
        return relative.hasPrefix("state_") || relative.hasPrefix("thread_history_") || relative.hasPrefix("sessions/") || relative.hasPrefix("archived_sessions/") || relative == "sessions" || relative == "archived_sessions"
    }
    private static func canonicalPath(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path), suffix: [String] = []
        // Resolving a deleted path itself leaves /private aliases unresolved on macOS.
        while !FileManager.default.fileExists(atPath: existing.path) && existing.path != "/" {
            suffix.append(existing.lastPathComponent); existing.deleteLastPathComponent()
        }
        return suffix.reversed().reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
    }
    private func codexDatabasePaths() -> [String] {
        let children = (try? FileManager.default.contentsOfDirectory(at: locations.codex, includingPropertiesForKeys: nil)) ?? []
        var paths = [locations.codex.path]
        for url in children where (url.lastPathComponent.hasPrefix("state_") || url.lastPathComponent.hasPrefix("thread_history_")) && url.pathExtension == "sqlite" {
            paths.append(url.path); paths.append(url.path + "-wal")
        }
        return paths
    }
    func requestRefresh(immediate: Bool = false, providers: Set<AITopicProvider>? = nil) {
        #if DEBUG
        if snapshot { return }
        #endif
        guard started && isEnabled else { return }
        let selected = activeProviders
        databaseWatcher?.rescan()
        codexDatabaseWatcher?.rescan(paths: codexDatabasePaths())
        syncQueue.enqueue((providers ?? selected).intersection(selected))
        scheduleRefresh(immediate: immediate)
    }
    private func scheduleRefresh(immediate: Bool) {
        guard !running, !syncQueue.isEmpty else { return }
        // Anchor the debounce to the first event, so a streaming source cannot postpone it forever.
        if pending != nil && !immediate { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }; pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : 0.25), execute: work)
    }
    private func refresh() {
        pending = nil
        guard !running, started, isEnabled, !locked({ suspended }) else { return }
        let (token, capturedProviders) = locked { (lifecycle, selectedProviders) }
        guard let job = syncQueue.next() else { return }
        running = true; indexing = true; onChange?()
        // Normal source writes enqueue another pass; only lifecycle changes cancel committed progress.
        let cancelled = { [weak self] in
            guard let self else { return true }
            return self.locked { !self.active || self.lifecycle != token || self.suspended }
        }
        writerQueue.async { [weak self] in
            guard let self else { return }
            // Serial dispatch jobs can use different OS threads; thread CPU baselines stay local.
            let budget = AITopicWorkBudget()
            var failures = Set<AITopicProvider>(), successes = Set<AITopicProvider>()
            var interrupted = false, complete = false
            do {
                guard !cancelled() else { throw CancellationError() }
                if self.writer == nil {
                    try FileManager.default.createDirectory(at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let index = try AITopicIndex(url: self.url, cacheBudgetBytes: 0)
                    self.writer = index
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.url.path)
                }
                if self.importerLifecycle != token {
                    self.importer = AITopicIndexer(index: self.writer!, locations: self.locations)
                    self.importerLifecycle = token
                    self.initialImportPending = capturedProviders
                }
                let checkpoint = {
                    if cancelled() { throw CancellationError() }
                    budget.checkpoint(isCancelled: cancelled)
                    if cancelled() { throw CancellationError() }
                }
                self.writer!.workCheckpoint = checkpoint
                defer { self.writer?.workCheckpoint = nil }
                let progress = {
                    if Date().timeIntervalSince(self.lastProgress) > 0.5 {
                        self.lastProgress = Date()
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.locked({ self.lifecycle == token }) else { return }; self.onChange?()
                        }
                    }
                }
                // Publish visibility for every dirty source before spending time on any history.
                for provider in AITopicProvider.allCases where job.metadata.contains(provider) {
                    do { try self.importer!.refreshMetadata(providers: [provider], isCancelled: cancelled, progress: progress) }
                    catch is CancellationError { throw CancellationError() }
                    catch { failures.insert(provider); Self.reportFailure(error, provider: provider, stage: "metadata") }
                }
                let began = ProcessInfo.processInfo.systemUptime
                do {
                    complete = try self.importer!.refreshHistory(provider: job.history, isCancelled: cancelled,
                        shouldYield: { ProcessInfo.processInfo.systemUptime - began >= 0.5 },
                        yieldHistoricalWork: { budget.checkpoint(isCancelled: cancelled) },
                        reportExternalCPU: { budget.chargeExternalCPU($0) }, progress: progress)
                    if complete && !failures.contains(job.history) { successes.insert(job.history) }
                } catch is CancellationError { throw CancellationError() }
                catch { failures.insert(job.history); complete = true; Self.reportFailure(error, provider: job.history, stage: "history") }
                if cancelled() { throw CancellationError() }
                if complete && !failures.contains(job.history) {
                    self.initialImportPending.remove(job.history)
                    if self.initialImportPending.isEmpty { try self.writer?.finishInitialImport() }
                }
                try self.writer?.checkpoint()
            } catch is CancellationError { interrupted = true }
            catch { failures.insert(job.history); complete = true; Self.reportFailure(error, provider: job.history, stage: "writer") }
            let total = (try? self.writer?.count(providers: capturedProviders)) ?? 0
            let size = ["", "-wal"].reduce(Int64(0)) { total, suffix in
                total + ((try? FileManager.default.attributesOfItem(atPath: self.url.path + suffix)[.size] as? NSNumber)?.int64Value ?? 0)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.running = false
                guard self.locked({ self.lifecycle == token }) else { if self.isEnabled && self.started { self.scheduleRefresh(immediate: true) }; return }
                if interrupted { self.syncQueue.enqueue(job.metadata) }
                if interrupted || !complete { self.syncQueue.resume(job.history) }
                if complete { self.syncQueue.complete(job.history) }
                self.failedProviders.subtract(successes); self.failedProviders.formUnion(failures)
                self.indexing = !self.syncQueue.isEmpty && !self.locked({ self.suspended })
                self.failed = !self.failedProviders.isEmpty; self.diskBytes = size; self.count = total
                self.onChange?()
                self.scheduleRefresh(immediate: true)
            }
        }
    }
    private static func reportFailure(_ error: Error, provider: AITopicProvider, stage: String) {
        #if DEBUG
        NSLog("Oil Find topic sync: provider=%@ stage=%@ error=%@", provider.rawValue, stage, error.localizedDescription)
        #endif
    }
    func search(_ text: String, provider: AITopicProvider?, limit: Int = 100, completion: @escaping (Result<AITopicSearchResult, Error>) -> Void) {
        let (token, providers) = locked { () -> (Int, Set<AITopicProvider>) in
            queryGeneration += 1; return (queryGeneration, selectedProviders)
        }
        let cancelled = { [weak self] in
            guard let self else { return true }; return self.locked { token != self.queryGeneration }
        }
        readerQueue.async { [weak self] in
            guard let self, !cancelled() else { return }
            let result: Result<AITopicSearchResult, Error>
            do {
                guard self.isEnabled, !providers.isEmpty else {
                    result = .success(.init(topics: [], hasMore: false, elapsedMs: 0))
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !cancelled(), self.isEnabled else { return }; completion(result)
                    }
                    return
                }
                if self.reader == nil { self.reader = try AITopicIndex(url: self.url, readOnly: true) }
                let found = try self.reader!.search(text, provider: provider, providers: self.searchableProviders(providers, index: self.reader!), limit: limit, isCancelled: cancelled)
                result = .success(found)
            } catch { self.reader = nil; result = .failure(error) }
            DispatchQueue.main.async { [weak self] in
                guard let self, !cancelled(), self.isEnabled else { return }; completion(result)
            }
        }
    }
    func readSearch(_ text: String, isCancelled: @escaping () -> Bool) throws -> AITopicSearchResult {
        let (token, providers) = locked { (lifecycle, selectedProviders) }
        guard isEnabled, !providers.isEmpty else { return .init(topics: [], hasMore: false, elapsedMs: 0) }
        let cancelled = { [weak self] in
            guard let self else { return true }; return isCancelled() || self.locked { self.lifecycle != token }
        }
        return try readerQueue.sync {
            if reader == nil { reader = try AITopicIndex(url: url, readOnly: true) }
            let found = try reader!.search(text, providers: searchableProviders(providers, index: reader!), limit: Int.max, isCancelled: cancelled)
            return cancelled() ? .init(topics: [], hasMore: false, elapsedMs: found.elapsedMs) : found
        }
    }
    private func refreshCount() {
        let (token, providers) = locked { (lifecycle, selectedProviders) }
        readerQueue.async { [weak self] in
            guard let self else { return }
            var total = 0
            if !providers.isEmpty, FileManager.default.fileExists(atPath: self.url.path) {
                do {
                    if self.reader == nil { self.reader = try AITopicIndex(url: self.url, readOnly: true) }
                    total = try self.reader!.count(providers: self.searchableProviders(providers, index: self.reader!))
                } catch { total = 0 }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.locked({ self.lifecycle == token }) else { return }
                self.count = total; self.onChange?()
            }
        }
    }
    func resolve(_ key: String, completion: @escaping (AITopic?) -> Void) {
        let token = locked { lifecycle }
        readerQueue.async { [weak self] in
            guard let self else { return }
            if self.reader == nil { self.reader = try? AITopicIndex(url: self.url, readOnly: true) }
            let topic = try? self.reader?.topic(key)
            let providers = self.reader.map { self.searchableProviders(self.activeProviders, index: $0) } ?? []
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let resolved = self.isEnabled && self.locked { self.lifecycle == token && topic?.archived == false && topic.map { self.selectedProviders.contains($0.provider) && providers.contains($0.provider) } == true }
                completion(resolved ? topic : nil)
            }
        }
    }
    private func searchableProviders(_ selected: Set<AITopicProvider>, index: AITopicIndex) -> Set<AITopicProvider> {
        #if DEBUG
        if snapshot { return selected }
        #endif
        guard selected.contains(.workbuddy) else { return selected }
        var result = selected
        let current = WorkBuddyTopicImporter.account(in: locations.workbuddy)
        if current == nil || current != (try? index.scope(.workbuddy)) { result.remove(.workbuddy) }
        return result
    }
    #if DEBUG
    func installSnapshot(url: URL) {
        snapshot = true; enabled = true
        readerQueue.sync { reader = try? AITopicIndex(url: url, readOnly: true) }
    }
    #endif
}
