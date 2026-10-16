import Foundation
import Darwin
import CoreServices

public final class IndexManager {
    public enum State { case idle, loading, scanning, ready }
    // The requested config belongs to eventQueue; each scan captures its own value.
    private var config: IndexConfig
    private var settingsObserver: NSObjectProtocol?
    private let settingsDefaults: UserDefaults?
    private var offline = false
    private let dbURL: URL
    private let volumeUUID: String?
    private let lock = NSLock()
    private let eventQueue = DispatchQueue(label: "com.oiloil.find.events", qos: .utility)
    private let scanQueue = DispatchQueue(label: "com.oiloil.find.scan", qos: .utility)
    private let saveQueue = DispatchQueue(label: "com.oiloil.find.save", qos: .background)
    private let eventKey = DispatchSpecificKey<Bool>(), saveKey = DispatchSpecificKey<Bool>()
    private var currentState: State = .idle, currentStore: IndexStore?, currentScanner: Scanner?
    private var rescanning = false, active = false, generation = 0, summary: ApplySummary?
    private var scanWatcher: FSWatcher?, bufferedEvents: [String: FSChange] = [:], bufferingToken: Int?, bufferedRescan = false
    private var bufferedEventBytes = 0
    internal var bufferedEventByteLimit = 8 * 1024 * 1024
    private var watcher: FSWatcher?, timer: DispatchSourceTimer?
    internal var onBeforeLoadedHashBuild: (() -> Void)?
    internal var onRescanStart: (() -> Void)?
    internal var onScannerCreated: ((Scanner) -> Void)?
    internal var onBufferedEvents: (([FSChange]) -> Void)?
    internal var onUpdaterCreated: ((IndexUpdater) -> Void)?
    private var recoveryRescanPending = false
    // Scheduling a scan does not repair the published catalog's replay interval.
    private var unresolvedLossCursor: UInt64?
    private var watcherEpoch: UInt64 = 0, scanStartEventId: UInt64 = 0
    internal var watcherEpochForTesting: UInt64 {
        DispatchQueue.getSpecific(key: eventKey) == true ? watcherEpoch : eventQueue.sync { watcherEpoch }
    }
    private var updater: IndexUpdater?
    private weak var savedStore: IndexStore?
    private var savedVersion: UInt64 = 0
    private var pendingNotification: DispatchWorkItem?, lastNotification = -Double.infinity
    private var stateCallback: ((State) -> Void)?, indexCallback: (() -> Void)?, batchCallback: ((ApplySummary) -> Void)?
    private var replayCount = 0, dataPrefix = false, hashMs = 0.0
    public init(config: IndexConfig, dbURL: URL, volumeUUID: String? = nil, settingsDefaults: UserDefaults? = .standard) {
        self.config = config; self.dbURL = dbURL; self.volumeUUID = volumeUUID
        self.settingsDefaults = settingsDefaults
        if let values = settingsDefaults?.stringArray(forKey: "excludedExtensions") { self.config.excludedExtensions = Set(values) }
        eventQueue.setSpecific(key: eventKey, value: true); saveQueue.setSpecific(key: saveKey, value: true)
        if let settingsDefaults {
            settingsObserver = NotificationCenter.default.addObserver(forName: SettingsPreferences.excludedExtensionsChanged, object: settingsDefaults, queue: nil) { [weak self] notification in
                guard let extensions = notification.userInfo?["extensions"] as? Set<String> else { return }
                self?.eventQueue.async { [weak self] in
                    guard let self, self.config.excludedExtensions != extensions else { return }
                    self.config.excludedExtensions = extensions
                    if self.locked({ self.offline }) { self.reloadOffline() }
                    else { self.beginRescan() }
                }
            }
        }
    }
    deinit { if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }; timer?.cancel(); pendingNotification?.cancel(); currentScanner?.cancel() }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    public var state: State { locked { currentState } }
    public var store: IndexStore? { locked { currentStore } }
    public var scannedCount: Int { let scanner = locked { currentScanner }; return scanner?.scannedCount ?? 0 }
    public var isRescanning: Bool { locked { rescanning } }
    public var lastSummary: ApplySummary? { locked { summary } }
    public var replayedEventCount: Int { locked { replayCount } }
    public var reportedDataPrefix: Bool { locked { dataPrefix } }
    public var buildHashMs: Double { locked { hashMs } }
    public var onStateChange: ((State) -> Void)? { get { locked { stateCallback } } set { locked { stateCallback = newValue } } }
    public var onIndexChange: (() -> Void)? { get { locked { indexCallback } } set { locked { indexCallback = newValue } } }
    // Each batch is observable independently of the UI notification throttle.
    public var onApply: ((ApplySummary) -> Void)? { get { locked { batchCallback } } set { locked { batchCallback = newValue } } }
    private func setState(_ state: State) {
        let callback = locked { () -> ((State) -> Void)? in
            if currentState == state { return nil }; currentState = state; return stateCallback
        }
        DispatchQueue.main.async { callback?(state) }
    }
    private func valid(_ token: Int) -> Bool { locked { active && generation == token } }
    private func device(config: IndexConfig) -> dev_t? {
        var s = stat(); guard stat(config.rootPath == "/" ? "/System/Volumes/Data" : config.rootPath, &s) == 0 else { return nil }
        return s.st_dev
    }
    private func mountedVolumeMatches(_ config: IndexConfig) -> Bool {
        guard let volumeUUID else { return true }
        guard let actual = try? URL(fileURLWithPath: config.rootPath).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString else { return false }
        return actual.caseInsensitiveCompare(volumeUUID) == .orderedSame
    }
    private func deviceUUID(config: IndexConfig) -> String? { device(config: config).flatMap(FSWatcher.uuid) }
    private func fingerprint(_ config: IndexConfig) -> UInt64 { volumeUUID.map { config.fingerprint(volumeUUID: $0) } ?? config.fingerprint }
    private func cursorIsValid(_ store: IndexStore, config: IndexConfig, uuid: String?) -> Bool {
        guard let uuid, store.fsEventsUUID == uuid else { return false }
        guard volumeUUID != nil else { return true }
        guard let device = device(config: config) else { return false }
        let latest = FSWatcher.currentEventId(forDevice: device)
        // The per-device value can lag delivered events until the journal flushes.
        return store.lastEventId <= max(latest, FSWatcher.currentEventId())
    }
    public func startOffline() {
        eventQueue.async { [weak self] in
            guard let self, !self.locked({ self.active }) else { return }
            self.locked { self.active = true; self.offline = true }
            self.reloadOffline()
        }
    }
    private func scopeFingerprint(_ config: IndexConfig) -> UInt64 {
        var scope = config; scope.excludedExtensions = []
        return fingerprint(scope)
    }
    private func reloadOffline() {
        guard locked({ active && offline }) else { return }
        let token = locked { generation += 1; return generation }
        setState(.loading)
        let config = self.config
        scanQueue.async { [weak self] in
            guard let self, self.valid(token) else { return }
            let loaded = IndexStore.load(from: self.dbURL.path)
            self.eventQueue.async {
                guard self.valid(token) else { return }
                guard let loaded, loaded.configFingerprint == self.fingerprint(config)
                    || loaded.scopeFingerprint == self.scopeFingerprint(config)
                    || loaded.configFingerprint == self.scopeFingerprint(config) else {
                    self.locked { self.active = false; self.currentStore = nil }
                    self.setState(.idle); self.notifyIndex(replaced: true); return
                }
                if self.volumeUUID != nil { loaded.rebase(to: config.rootPath) }
                // Filter a fresh catalog in memory; retain the on-disk snapshot for undo and reconnect.
                if config.hasExcludedExtensions {
                    loaded.write {
                        var bucket = loaded.coverage[.fileType], changed = false
                        for i in 1..<loaded.count where loaded.isLive(UInt32(i)) && loaded.flags[i] & SiftFlag.dir == 0 {
                            guard config.excludesFile(name: loaded.nameBytes(UInt32(i))) else { continue }
                            bucket.count &+= 1
                            if bucket.examples.count < 5 {
                                let path = loaded.path(UInt32(i))
                                if !bucket.examples.contains(path) { bucket.examples.append(path) }
                            }
                            changed = loaded.remove(UInt32(i)) || changed
                        }
                        loaded.coverage.buckets[.fileType] = bucket
                        if changed { loaded.version &+= 1 }
                    }
                }
                self.locked { self.currentStore = loaded }
                self.saveQueue.sync { self.savedStore = loaded; self.savedVersion = loaded.version }
                self.setState(.ready); self.notifyIndex(replaced: true)
            }
        }
    }
    public func start() {
        eventQueue.async { [weak self] in
            guard let self, !self.locked({ self.active }) else { return }
            let token = self.locked { self.active = true; self.offline = false; self.replayCount = 0; self.dataPrefix = false; self.generation += 1; return self.generation }
            self.setState(.loading)
            let config = self.config
            self.scanQueue.async { [weak self] in
                guard let self, self.valid(token) else { return }
                guard self.mountedVolumeMatches(config) else {
                    self.eventQueue.async { if self.valid(token) { self.locked { self.active = false }; self.setState(.idle) } }
                    return
                }
                let uuid = self.deviceUUID(config: config)
                if let s = IndexStore.load(from: self.dbURL.path), s.configFingerprint == self.fingerprint(config),
                   (self.volumeUUID != nil || s.rootPath == config.rootPath), self.cursorIsValid(s, config: config, uuid: uuid) {
                    let rootChanged = s.rootPath != config.rootPath
                    if self.volumeUUID != nil { s.rebase(to: config.rootPath) }
                    self.eventQueue.async {
                        guard self.valid(token) else { return }
                        self.locked { self.currentStore = s; self.hashMs = 0 }
                        self.saveQueue.sync { self.savedStore = s; self.savedVersion = rootChanged ? UInt64.max : s.version }
                        self.setState(.ready); self.notifyIndex(replaced: true)
                        DispatchQueue.global(qos: .utility).async { _ = Pinyin.shared }
                        self.onBeforeLoadedHashBuild?()
                        let begin = CFAbsoluteTimeGetCurrent()
                        let built = s.makeHash()
                        s.write { s.installHash(built) }
                        self.locked { self.hashMs = (CFAbsoluteTimeGetCurrent() - begin) * 1000 }
                        let updater = IndexUpdater(config: config)
                        self.onUpdaterCreated?(updater)
                        self.locked { self.updater = updater }
                        self.startWatcher(s, token: token); self.startTimer()
                        self.scanLatestConfigIfNeeded()
                        if UInt64(Date().timeIntervalSince1970) > s.scanFinishedAt + 7*86400 {
                            self.eventQueue.asyncAfter(deadline: .now()+60) { [weak self] in if let self, self.valid(token) { self.rescan() } }
                        }
                    }
                } else {
                    guard self.valid(token) else { return }
                    self.eventQueue.async { if self.valid(token) { self.setState(.scanning) } }
                    self.scan(config: config, token: token, isRescan: false, uuid: uuid)
                }
            }
        }
    }
    private func scan(config: IndexConfig, token: Int, isRescan: Bool, uuid: String?) {
        guard mountedVolumeMatches(config) else {
            eventQueue.async { if self.valid(token) { self.locked { self.rescanning = false; if !isRescan { self.active = false } }; if !isRescan { self.setState(.idle) } } }
            return
        }
        // Background rebuilds keep spare cores for interactive work; CLI benchmarks can still opt into wider scans.
        let startId = volumeUUID.flatMap { _ in device(config: config).map(FSWatcher.currentEventId(forDevice:)) } ?? FSWatcher.currentEventId(), scanner = Scanner(config: config, threads: min(2, ProcessInfo.processInfo.activeProcessorCount))
        eventQueue.sync {
            guard self.valid(token) else { return }
            self.scanStartEventId = startId
            // A fresh live stream precedes every scan. Replaying the lost historical stream
            // after rebuilding can deliver the same loss again and schedule endless rebuilds.
            let epoch = self.watcherEpoch &+ 1
            let monitor = FSWatcher(paths: [config.rootPath], sinceWhen: UInt64(kFSEventStreamEventIdSinceNow),
                device: self.volumeUUID == nil ? nil : self.device(config: config), queue: self.eventQueue) { [weak self] changes, rescan in
                self?.receiveEvents(changes, mustRescanAll: rescan, token: token, epoch: epoch)
            }
            let watching = monitor.start()
            if watching {
                self.watcherEpoch = epoch
                self.watcher?.stop(); self.watcher = nil; self.scanWatcher?.stop()
                self.scanWatcher = monitor; self.bufferingToken = token
                self.bufferedEvents.removeAll(keepingCapacity: true); self.bufferedEventBytes = 0; self.bufferedRescan = false
            }
            // Any loss delivered before this scan starts is covered by this scan. Loss on
            // the new stream while scanning is tracked separately and still queues recovery.
            self.recoveryRescanPending = false
            #if DEBUG
            NSLog("Oil Find file scan start: watermark=%llu epoch=%llu fresh=%d", startId, self.watcherEpoch, watching ? 1 : 0)
            #endif
        }
        onScannerCreated?(scanner)
        let proceed = locked { () -> Bool in
            guard active && generation == token else { return false }; currentScanner = scanner; return true
        }
        guard proceed else { return }
        guard let output = scanner.run(), valid(token) else {
            eventQueue.async {
                guard self.valid(token) else { return }
                self.locked { self.currentScanner = nil; self.rescanning = false; if !isRescan { self.active = false } }
                if isRescan {
                    // Preserve the old catalog's replay cursor if opening the scan root failed.
                    if self.unresolvedLossCursor == nil { self.unresolvedLossCursor = self.store.map { store in store.read { store.lastEventId } } ?? startId }
                    _ = self.adoptScanWatcher(token: token)
                    self.recoveryRescanPending = true
                    self.eventQueue.asyncAfter(deadline: .now() + 60) { [weak self] in
                        guard let self, self.valid(token) else { return }; self.startPendingRecovery()
                    }
                } else {
                    self.scanWatcher?.stop(); self.scanWatcher = nil; self.bufferingToken = nil
                    self.bufferedEvents.removeAll(); self.bufferedEventBytes = 0; self.bufferedRescan = false; self.setState(.idle)
                }
            }; return
        }
        let s = IndexStore(scan: output, config: config)
        guard valid(token) else { return }
        s.configFingerprint = fingerprint(config)
        s.scopeFingerprint = scopeFingerprint(config)
        let begin = CFAbsoluteTimeGetCurrent(); s.write { s.buildHash() }
        let ms = (CFAbsoluteTimeGetCurrent()-begin)*1000
        s.lastEventId = startId; s.scanFinishedAt = UInt64(Date().timeIntervalSince1970); s.fsEventsUUID = uuid ?? ""
        eventQueue.async { [weak self] in
            guard let self, self.valid(token) else { return }
            self.watcher?.stop(); self.watcher = nil
            let adopted = self.adoptScanWatcher(token: token)
            let buffered = Array(self.bufferedEvents.values)
            let lost = self.bufferedRescan || self.recoveryRescanPending
            let updater = IndexUpdater(config: config)
            self.locked { self.updater = updater }
            self.onUpdaterCreated?(updater)
            // Reconcile before publishing. A concurrent save may observe the old safe catalog
            // or the fully prepared replacement, never a cursor temporarily beyond a known gap.
            var batch: ApplySummary?
            if !lost && !buffered.isEmpty { batch = updater.apply(buffered, to: s) }
            guard self.valid(token), !updater.isCancelled else { return }
            let installed = s.read { s.needsCompaction ? s.compacted() : s }
            self.bufferedEvents.removeAll(keepingCapacity: true); self.bufferedEventBytes = 0; self.bufferedRescan = false
            self.unresolvedLossCursor = lost ? startId : nil
            self.recoveryRescanPending = lost
            self.locked { self.currentStore = installed; self.currentScanner = nil; self.rescanning = false; self.hashMs = ms }
            if let batch {
                let callback = self.locked { self.summary = batch; return self.batchCallback }
                DispatchQueue.main.async { callback?(batch) }
            }
            self.setState(.ready); self.notifyIndex(replaced: true)
            DispatchQueue.global(qos: .utility).async { _ = Pinyin.shared }
            if !adopted { self.startWatcher(installed, token: token) }
            self.saveNow(); self.startTimer()
            self.scanLatestConfigIfNeeded()
            self.startPendingRecovery()
        }
    }
    @discardableResult private func adoptScanWatcher(token: Int) -> Bool {
        guard let monitor = scanWatcher, bufferingToken == token else { return false }
        scanWatcher = nil; watcher = monitor; bufferingToken = nil
        return true
    }
    private func startWatcher(_ s: IndexStore, token: Int) {
        watcherEpoch &+= 1
        let epoch = watcherEpoch
        let w = FSWatcher(paths: [s.rootPath], sinceWhen: volumeUUID != nil && s.fsEventsUUID.isEmpty ? UInt64(kFSEventStreamEventIdSinceNow) : s.lastEventId, device: volumeUUID == nil ? nil : device(config: config), queue: eventQueue) { [weak self] changes, rescan in
            self?.receiveEvents(changes, mustRescanAll: rescan, token: token, epoch: epoch)
        }
        watcher = w
        if !w.start() { fputs("Oil Find: cannot start FSEvents\n", stderr) }
    }
    private func receiveEvents(_ changes: [FSChange], mustRescanAll: Bool, token: Int, epoch: UInt64) {
        guard valid(token), epoch == watcherEpoch else {
            #if DEBUG
            if mustRescanAll { NSLog("Oil Find stale file recovery ignored: events=%d min=%llu max=%llu epoch=%llu current=%llu", changes.count, changes.map(\.eventId).min() ?? 0, changes.map(\.eventId).max() ?? 0, epoch, watcherEpoch) }
            #endif
            return
        }
        if let monitor = scanWatcher ?? watcher { locked { replayCount = monitor.replayedEventCount; dataPrefix = monitor.reportedDataPrefix } }
        if bufferingToken == token || unresolvedLossCursor != nil {
            // A root loss is not a usable subtree update. The replacement scan handles it;
            // applying it synchronously here would perform another full walk on eventQueue.
            if !mustRescanAll {
                for change in changes {
                    if var existing = bufferedEvents[change.path] {
                        existing.flags |= change.flags; existing.eventId = max(existing.eventId, change.eventId)
                        bufferedEvents[change.path] = existing
                    } else {
                        let cost = change.path.utf8.count + 96
                        if cost > bufferedEventByteLimit - bufferedEventBytes { bufferedRescan = true; continue }
                        bufferedEvents[change.path] = change; bufferedEventBytes += cost
                    }
                }
            }
            bufferedRescan = bufferedRescan || mustRescanAll
            onBufferedEvents?(changes)
            #if DEBUG
            if mustRescanAll { NSLog("Oil Find buffered file recovery: events=%d min=%llu max=%llu watermark=%llu epoch=%llu", changes.count, changes.map(\.eventId).min() ?? 0, changes.map(\.eventId).max() ?? 0, scanStartEventId, epoch) }
            #endif
        } else { handleEvents(changes, mustRescanAll: mustRescanAll) }
    }
    // Test injection and FSEvents share the event-queue implementation, including stream identity.
    internal func injectEvents(_ changes: [FSChange], mustRescanAll: Bool, watcherEpoch: UInt64? = nil) {
        eventQueue.async { [weak self] in
            guard let self, self.locked({ self.active }) else { return }
            self.receiveEvents(changes, mustRescanAll: mustRescanAll, token: self.locked { self.generation }, epoch: watcherEpoch ?? self.watcherEpoch)
        }
    }
    private func handleEvents(_ changes: [FSChange], mustRescanAll: Bool) {
        if mustRescanAll {
            #if DEBUG
            let flags = Set(changes.map { String($0.flags, radix: 16) }).sorted().joined(separator: ",")
            NSLog("Oil Find file recovery: events=%d flags=%@ pending=%d min=%llu max=%llu watermark=%llu epoch=%llu", changes.count, flags, isRescanning ? 1 : 0, changes.map(\.eventId).min() ?? 0, changes.map(\.eventId).max() ?? 0, scanStartEventId, watcherEpoch)
            #endif
            if unresolvedLossCursor == nil { unresolvedLossCursor = self.store.map { store in store.read { store.lastEventId } } }
            if isRescanning { recoveryRescanPending = true }
            else { beginRescan(reason: "lost-events") }
            return
        }
        guard !changes.isEmpty, let store = self.store, let updater = locked({ self.updater }) else { return }
        let result = updater.apply(changes, to: store)
        guard !updater.isCancelled else { return }
        let callback = locked { self.summary = result; return batchCallback }
        DispatchQueue.main.async { callback?(result) }
        if store.read({ store.needsCompaction }) {
            // The event queue is the sole writer; readers may continue during copying.
            let compact = store.read { store.compacted() }
            locked { currentStore = compact }; notifyIndex(replaced: true)
        } else { notifyIndex(replaced: false) }
    }
    public func explain(path: String) -> CoverageExplanation {
        let config = DispatchQueue.getSpecific(key: eventKey) == true ? self.config : eventQueue.sync { self.config }
        return Coverage.explain(path: path, config: config, store: store)
    }
    public func rescan() {
        eventQueue.async { [weak self] in
            self?.beginRescan()
        }
    }
    public func updateConfig(_ config: IndexConfig) {
        eventQueue.async { [weak self] in
            guard let self, self.fingerprint(self.config) != self.fingerprint(config) else { return }
            self.config = config
            if let values = self.settingsDefaults?.stringArray(forKey: "excludedExtensions") { self.config.excludedExtensions = Set(values) }
            if self.locked({ self.offline }) { self.reloadOffline() }
            else { self.beginRescan() }
        }
    }
    private func scanLatestConfigIfNeeded() {
        if store?.configFingerprint != fingerprint(config) { beginRescan(reason: "fingerprint-change") }
    }
    private func beginRescan(reason: String = "requested") {
        let token: Int? = locked {
            guard active && !offline && currentState == .ready && !rescanning else { return nil }
            rescanning = true; return generation
        }
        guard let token else { return }
        #if DEBUG
        NSLog("Oil Find file rescan: reason=%@", reason)
        #endif
        let config = self.config
        onRescanStart?()
        scanQueue.async { [weak self] in
            if let self, self.valid(token) {
                self.scan(config: config, token: token, isRescan: true, uuid: self.deviceUUID(config: config))
            }
        }
    }
    private func startPendingRecovery() {
        guard recoveryRescanPending, !isRescanning else { return }
        recoveryRescanPending = false
        beginRescan(reason: "recovery")
    }
    private func notifyIndex(replaced: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        if replaced || now-lastNotification >= 1 {
            pendingNotification?.cancel(); pendingNotification = nil; lastNotification = now
            let callback = locked { indexCallback }; DispatchQueue.main.async { callback?() }
        } else if pendingNotification == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.locked({ self.active }) else { return }
                self.pendingNotification = nil; self.notifyIndex(replaced: false)
            }
            pendingNotification = work; eventQueue.asyncAfter(deadline: .now() + (1-(now-lastNotification)), execute: work)
        }
    }
    private func startTimer() {
        if timer != nil { return }
        let timer = DispatchSource.makeTimerSource(queue: eventQueue)
        timer.schedule(deadline: .now()+1800, repeating: 1800)
        timer.setEventHandler { [weak self] in self?.saveQueue.async { [weak self] in self?.saveChanged() } }
        self.timer = timer; timer.resume()
    }
    private func saveChanged() {
        guard !locked({ offline }), let s = store else { return }
        let version = s.read { s.version }
        if savedStore === s && savedVersion == version { return }
        do {
            // The saved version is captured under the same read lock as the file snapshot.
            let saved = try s.saveSnapshot(to: dbURL.path)
            savedStore = s; savedVersion = saved
        } catch { fputs("Oil Find: save failed: \(error)\n", stderr) }
    }
    public func saveNow() {
        if DispatchQueue.getSpecific(key: saveKey) == true { saveChanged() }
        else { saveQueue.sync { saveChanged() } }
    }
    public func stop() {
        let resources = locked { (currentScanner, updater) }
        let scanner = resources.0
        scanner?.cancel(); resources.1?.cancel()
        let stopEvents = {
            let pending = self.locked { () -> (Scanner?, IndexUpdater?) in
                let pending = (self.currentScanner, self.updater)
                self.active = false; self.generation += 1; self.currentScanner = nil; self.updater = nil; self.rescanning = false
                return pending
            }
            pending.0?.cancel(); pending.1?.cancel()
            self.recoveryRescanPending = false; self.unresolvedLossCursor = nil
            self.watcherEpoch &+= 1
            self.watcher?.stop(); self.watcher = nil
            self.scanWatcher?.stop(); self.scanWatcher = nil; self.bufferingToken = nil; self.bufferedEvents.removeAll(); self.bufferedEventBytes = 0; self.bufferedRescan = false
            self.timer?.cancel(); self.timer = nil; self.pendingNotification?.cancel(); self.pendingNotification = nil
            self.setState(.idle)
        }
        if DispatchQueue.getSpecific(key: eventKey) == true { stopEvents() } else { eventQueue.sync(execute: stopEvents) }
        // Jobs publish only through the generation-checked event queue. Cancellation
        // releases directory handles without waiting for a discarded store build.
        saveNow()
    }
}
