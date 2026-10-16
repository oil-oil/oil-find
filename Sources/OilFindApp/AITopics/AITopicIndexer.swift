import Foundation
import Darwin
import SQLite3

public struct AITopicLocations {
    public var codex: URL
    public var claude: URL
    public var claudeDesktop: URL
    public var workbuddy: URL
    public init(home: URL, codex: URL? = nil, claude: URL? = nil, workbuddy: URL? = nil) {
        self.codex = codex ?? home.appendingPathComponent(".codex")
        self.claude = claude ?? home.appendingPathComponent(".claude")
        claudeDesktop = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        self.workbuddy = workbuddy ?? home.appendingPathComponent(".workbuddy")
    }
    public static var local: AITopicLocations {
        let environment = ProcessInfo.processInfo.environment
        return .init(home: FileManager.default.homeDirectoryForCurrentUser,
                     codex: environment["CODEX_HOME"].map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) },
                     claude: environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) },
                     workbuddy: environment["WORKBUDDY_CONFIG_DIR"].map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) })
    }
}

struct AITopicMessage {
    let body: String
    let user: Bool
}

struct AITopicCodexDiscoveryMetrics: Equatable {
    var enumeratedJSONLFiles = 0
    var canonicalHistoryPathsSkipped = 0
    var cachedHeadersReused = 0
    var headerBytesRead = 0
    var headersParsed = 0
    var codexMetadataRowsRead = 0
    var codexMetadataRowsReused = 0
    var codexMetadataRowsUpserted = 0
    var codexHistorySortDateLookups = 0
}

enum AITopicTranscript {
    static func text(_ value: Any?) -> String {
        if let text = value as? String { return text }
        guard let blocks = value as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            guard ["text", "input_text", "output_text"].contains(block["type"] as? String ?? "") else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
    }
    static func claude(_ object: [String: Any]) -> AITopicMessage? {
        guard object["isMeta"] as? Bool != true,
              let type = object["type"] as? String, type == "user" || type == "assistant",
              let message = object["message"] as? [String: Any] else { return nil }
        let body = text(message["content"])
        return body.isEmpty ? nil : .init(body: body, user: type == "user")
    }
    static func codex(_ object: [String: Any]) -> AITopicMessage? {
        let type = object["type"] as? String
        if type == "userMessage" {
            let body = text(object["content"]); return .init(body: body, user: true)
        }
        if type == "agentMessage", let body = object["text"] as? String { return .init(body: body, user: false) }
        guard type == "response_item", let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "message", let role = payload["role"] as? String,
              role == "user" || role == "assistant" else { return nil }
        let body = text(payload["content"])
        return body.isEmpty ? nil : .init(body: body, user: role == "user")
    }
}

/// Imports only saved local data. No login, model calls, or writes to either application's storage.
public final class AITopicIndexer {
    private struct CodexFileStamp: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
    }
    private struct CodexHeader {
        let stamp: CodexFileStamp
        let sessionID: String?
        let project: String
        let isSubagent: Bool
        var transcriptImported: Bool
    }
    private struct CodexMetadataSourceIdentity: Equatable {
        let path: String
        let device: UInt64
        let inode: UInt64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
        let columns: Set<String>
    }
    private struct CodexMetadataRowSignature: Equatable {
        let title: String
        let project: String
        let modified: Double
        let transcript: String
        let archived: Int64
        let excerpt: String
        let threadSource: String
        let source: String
    }
    private struct CodexMetadataCacheEntry {
        let signature: CodexMetadataRowSignature
        let topic: AITopic
    }
    private struct CodexMetadataCache {
        let identity: CodexMetadataSourceIdentity
        let rows: [String: CodexMetadataCacheEntry]
    }
    private struct ClaudeHistoryPlan {
        let paths: [URL]
        var nextIndex = 0
        var imported = Set<String>()
    }
    private struct CodexHistoryPlan {
        let metadata: [AITopic]
        let metadataByKey: [String: AITopic]
        let hasMetadata: Bool
        var nextMetadataIndex = 0
        var imported = Set<String>()
        var canonicalHistoryPaths = Set<String>()
        var historyScanned = false
        var paths: [URL]?
        var nextPathIndex = 0
        var currentPaths = Set<String>()
        var enumerationComplete = true
        init(metadata: [AITopic], hasMetadata: Bool) {
            self.metadata = metadata
            metadataByKey = Dictionary(metadata.map { ($0.key, $0) }, uniquingKeysWith: { _, latest in latest })
            self.hasMetadata = hasMetadata
        }
    }
    private enum CodexStampResult {
        case success(CodexFileStamp)
        case failure(Int32)
    }

    private let index: AITopicIndex
    private let locations: AITopicLocations
    private let files = FileManager.default
    private var topics: [String: AITopic] = [:]
    private var completeProviders = Set(AITopicProvider.allCases)
    private var seenFiles: [AITopicProvider: Set<String>] = [:]
    private var hasCodexMetadata = false
    private var codexHeaders: [String: CodexHeader] = [:]
    private(set) var lastCodexDiscoveryMetrics = AITopicCodexDiscoveryMetrics()
    private var stagedProviders = Set<AITopicProvider>()
    private var metadataTopicKeys: [AITopicProvider: Set<String>] = [:]
    private var metadataFailures: [AITopicProvider: Error] = [:]
    private var activeHistoryProviders = Set<AITopicProvider>()
    private var codexMetadataSnapshot: [AITopic] = []
    private var codexMetadataCache: CodexMetadataCache?
    private var codexMetadataDirtyKeys = Set<String>()
    private var claudeHistoryPlan: ClaudeHistoryPlan?
    private var codexHistoryPlan: CodexHistoryPlan?
    public init(index: AITopicIndex, locations: AITopicLocations = .local) { self.index = index; self.locations = locations }

    private var cancellation: () -> Bool = { false }
    private var yieldWork: () -> Void = { }
    private func checkCancellation() throws {
        if cancellation() { throw CancellationError() }
        yieldWork()
        if cancellation() { throw CancellationError() }
    }
    public func refresh(providers: Set<AITopicProvider> = Set(AITopicProvider.allCases), isCancelled: @escaping () -> Bool = { false }, yieldHistoricalWork: @escaping () -> Void = { }, reportExternalCPU: @escaping (Double) -> Void = { _ in }, progress: () -> Void = {}, metadataAlreadyRefreshed: Bool = false) throws {
        cancellation = isCancelled
        defer { cancellation = { false }; yieldWork = { } }
        yieldWork = yieldHistoricalWork
        if !metadataAlreadyRefreshed { try refreshMetadata(providers: providers, isCancelled: isCancelled, progress: progress) }
        var firstFailure: Error?
        for provider in AITopicProvider.allCases where providers.contains(provider) {
            do {
                while !(try refreshHistory(provider: provider, isCancelled: isCancelled, shouldYield: { false },
                                           yieldHistoricalWork: yieldHistoricalWork, reportExternalCPU: reportExternalCPU,
                                           progress: progress)) { }
            } catch is CancellationError { throw CancellationError() }
            catch { if firstFailure == nil { firstFailure = error } }
        }
        if let firstFailure { throw firstFailure }
    }

    public func refreshMetadata(providers: Set<AITopicProvider> = Set(AITopicProvider.allCases), isCancelled: @escaping () -> Bool = { false }, progress: () -> Void = {}) throws {
        cancellation = isCancelled
        var completed = false
        defer {
            cancellation = { false }
            if !completed { codexMetadataCache = nil }
        }
        try checkCancellation()
        lastCodexDiscoveryMetrics = AITopicCodexDiscoveryMetrics()
        stagedProviders.formUnion(providers)
        completeProviders.formUnion(providers)
        if providers.contains(.codex) { hasCodexMetadata = false }
        metadataFailures = metadataFailures.filter { !providers.contains($0.key) }
        // Keep legacy topics already committed by a history plan that is being resumed. Current
        // descriptors below replace stale metadata rows for those providers.
        topics = topics.filter { provider, keyTopic in
            !providers.contains(keyTopic.provider) || (activeHistoryProviders.contains(keyTopic.provider) && !metadataTopicKeys[keyTopic.provider, default: []].contains(provider))
        }
        for provider in providers where !activeHistoryProviders.contains(provider) { seenFiles[provider] = [] }
        if providers.contains(.claude) {
            do { metadataTopicKeys[.claude] = try claudeDescriptors() }
            catch is CancellationError { throw CancellationError() }
            catch {
                completeProviders.remove(.claude)
                metadataFailures[.claude] = error
                throw error
            }
        }
        if providers.contains(.codex) {
            do {
                codexMetadataSnapshot = try codexMetadata(progress: progress)
                metadataTopicKeys[.codex] = Set(codexMetadataSnapshot.map(\.key))
            } catch is CancellationError { throw CancellationError() }
            catch {
                completeProviders.remove(.codex)
                metadataFailures[.codex] = error
                throw error
            }
        }
        progress()
        if providers.contains(.workbuddy) {
            do { try WorkBuddyTopicImporter(index: index, root: locations.workbuddy, checkpoint: checkCancellation).refresh(metadataOnly: true, progress: progress) }
            catch is CancellationError { throw CancellationError() }
            catch { completeProviders.remove(.workbuddy); metadataFailures[.workbuddy] = error }
        }
        completed = true
    }

    @discardableResult
    public func refreshHistory(provider: AITopicProvider, isCancelled: @escaping () -> Bool = { false }, shouldYield: () -> Bool = { false }, yieldHistoricalWork: @escaping () -> Void = { }, reportExternalCPU: @escaping (Double) -> Void = { _ in }, progress: () -> Void = {}) throws -> Bool {
        guard stagedProviders.contains(provider) else { return true }
        cancellation = isCancelled
        yieldWork = yieldHistoricalWork
        defer { cancellation = { false }; yieldWork = { } }
        try checkCancellation()
        if let failure = metadataFailures.removeValue(forKey: provider) { throw failure }
        if !activeHistoryProviders.contains(provider) {
            activeHistoryProviders.insert(provider)
            seenFiles[provider] = []
            if provider == .claude { claudeHistoryPlan = nil }
            if provider == .codex { codexHistoryPlan = nil }
        }
        switch provider {
        case .claude:
            guard try claudeTranscripts(shouldYield: shouldYield, progress: progress) else { return false }
        case .codex:
            guard try codexTranscripts(shouldYield: shouldYield, progress: progress) else { return false }
        case .workbuddy:
            try WorkBuddyTopicImporter(index: index, root: locations.workbuddy, checkpoint: checkCancellation).refresh(progress: progress)
            activeHistoryProviders.remove(provider)
        }
        if (provider == .claude || provider == .codex), completeProviders.contains(provider) {
            let live = Set(topics.values.filter { $0.provider == provider }.map(\.key))
            try index.reconcile(provider: provider, topics: live, files: seenFiles[provider] ?? [])
        }
        if provider == .claude { claudeHistoryPlan = nil }
        if provider == .codex { codexHistoryPlan = nil }
        activeHistoryProviders.remove(provider)
        return true
    }
    private func children(_ root: URL) -> [URL] {
        do { return try files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: []) }
        catch {
            let error = error as NSError
            if error.domain != NSCocoaErrorDomain || ![NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                completeProviders.remove(root.path.hasPrefix(locations.codex.path) ? .codex : .claude)
            }
            return []
        }
    }
    private func database(_ root: URL, prefix: String) -> URL? {
        children(root).filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "sqlite" }
            .max { a, b in
                let version: (URL) -> Int = { Int($0.deletingPathExtension().lastPathComponent.dropFirst(prefix.count)) ?? 0 }
                return version(a) < version(b)
            }
    }
    private func claudeDescriptors() throws -> Set<String> {
        guard !children(locations.claudeDesktop).isEmpty,
              let enumerator = files.enumerator(at: locations.claudeDesktop, includingPropertiesForKeys: nil, errorHandler: { [self] _, _ in completeProviders.remove(.claude); return true }) else { return [] }
        var descriptors: [AITopic] = []
        for case let url as URL in enumerator where url.pathExtension == "json" {
            try checkCancellation()
            guard let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { completeProviders.remove(.claude); continue }
            guard let desktopID = object["sessionId"] as? String else { continue }
            let id = object["cliSessionId"] as? String ?? desktopID
            let modified = Self.date(object["lastActivityAt"]) ?? Self.date(object["createdAt"]) ?? 0
            var topic = AITopic(id: id, provider: .claude, title: object["title"] as? String ?? "",
                                project: object["cwd"] as? String ?? "", modified: modified, desktopID: desktopID,
                                archived: object["isArchived"] as? Bool ?? false, excerpt: String((object["postTurnSummary"] as? String ?? "").prefix(220)))
            if let persisted = try index.topic(topic.key) {
                if topic.title.isEmpty { topic.title = persisted.title }
                if topic.project.isEmpty { topic.project = persisted.project }
                if topic.excerpt.isEmpty { topic.excerpt = persisted.excerpt }
            }
            topics[topic.key] = topic
            descriptors.append(topic)
        }
        try index.transaction { for topic in descriptors { try index.upsert(topic) } }
        return Set(descriptors.map(\.key))
    }
    private func codexMetadata(progress: () -> Void) throws -> [AITopic] {
        guard let url = database(locations.codex, prefix: "state_") else {
            codexMetadataCache = nil
            return []
        }
        let initialStamp: CodexFileStamp?
        if case .success(let stamp) = Self.codexFileStamp(url) { initialStamp = stamp }
        else { initialStamp = nil }
        let source = try AITopicSQL(url, readOnly: true)
        let columns = try source.columns("threads")
        guard columns.contains("id"), columns.contains("title") else { throw AITopicError.database("Unsupported Codex thread database") }
        let sourceIdentity = initialStamp.map {
            CodexMetadataSourceIdentity(path: url.standardizedFileURL.path, device: $0.device, inode: $0.inode,
                                        changedSeconds: $0.changedSeconds, changedNanoseconds: $0.changedNanoseconds,
                                        columns: columns)
        }
        let reusableRows = sourceIdentity.flatMap { identity in
            codexMetadataCache?.identity == identity ? codexMetadataCache?.rows : nil
        } ?? [:]
        let column: (String, String) -> String = { columns.contains($0) ? "COALESCE(\($0),\($1))" : $1 }
        hasCodexMetadata = true
        let time = columns.contains("updated_at_ms") ? "COALESCE(updated_at_ms/1000.0,\(column("updated_at", "0")),0)" : column("updated_at", "0")
        let title = columns.contains("name") ? "COALESCE(NULLIF(name,''),title,'')" : "COALESCE(title,'')"
        let s = try source.prepare("SELECT id,\(title),\(column("cwd", "''")),\(time),\(column("rollout_path", "''")),\(column("archived", "0")),\(column("first_user_message", "''")),\(column("thread_source", "''")),\(column("source", "''")) FROM threads ORDER BY \(time) DESC")
        var result: [AITopic] = []
        var nextRows: [String: CodexMetadataCacheEntry] = [:]
        var pendingUpserts: [AITopic] = []
        func flushPendingUpserts() throws {
            guard !pendingUpserts.isEmpty else { return }
            let count = pendingUpserts.count
            try index.transaction { for topic in pendingUpserts { try index.upsert(topic) } }
            lastCodexDiscoveryMetrics.codexMetadataRowsUpserted += count
            pendingUpserts.removeAll(keepingCapacity: true)
        }
        while try s.next() {
            try checkCancellation()
            lastCodexDiscoveryMetrics.codexMetadataRowsRead += 1
            if ["subagent", "guardian_review"].contains(s.text(7)) || s.text(8).contains("subagent") || s.text(8).contains("guardian") { continue }
            let id = s.text(0), sourceTitle = s.text(1), project = s.text(2), modified = s.double(3)
            let transcript = s.text(4), archived = s.int(5), sourceExcerpt = s.text(6)
            let threadSource = s.text(7), source = s.text(8)
            let topic = AITopic(id: id, provider: .codex, title: String(sourceTitle.prefix(120)).replacingOccurrences(of: "\n", with: " "), project: project, modified: modified,
                                transcript: transcript, archived: archived != 0, excerpt: String(sourceExcerpt.prefix(220)))
            let signature = CodexMetadataRowSignature(title: sourceTitle, project: project, modified: modified,
                                                      transcript: transcript, archived: archived, excerpt: sourceExcerpt,
                                                      threadSource: threadSource, source: source)
            let cacheEntry = CodexMetadataCacheEntry(signature: signature, topic: topic)
            let hasAuthoritativeDisplayText = !topic.title.isEmpty && !topic.project.isEmpty && !topic.excerpt.isEmpty
            let canReuse = hasAuthoritativeDisplayText && !codexMetadataDirtyKeys.contains(topic.key)
                && reusableRows[topic.key].map { $0.signature == signature && $0.topic == topic } == true
            if canReuse {
                lastCodexDiscoveryMetrics.codexMetadataRowsReused += 1
            } else {
                pendingUpserts.append(topic)
            }
            nextRows[topic.key] = cacheEntry
            result.append(topic); topics[topic.key] = topic
            if result.count % 100 == 0 {
                try flushPendingUpserts()
                progress()
            }
        }
        try flushPendingUpserts()
        if result.count % 100 != 0 { progress() }
        try checkCancellation()
        if let sourceIdentity, let initialStamp, case .success(let finalStamp) = Self.codexFileStamp(url),
           initialStamp.device == finalStamp.device, initialStamp.inode == finalStamp.inode,
           initialStamp.changedSeconds == finalStamp.changedSeconds, initialStamp.changedNanoseconds == finalStamp.changedNanoseconds {
            codexMetadataCache = CodexMetadataCache(identity: sourceIdentity, rows: nextRows)
        } else {
            codexMetadataCache = nil
        }
        codexMetadataDirtyKeys.removeAll()
        return result
    }
    private func claudeTranscripts(shouldYield: () -> Bool, progress: () -> Void) throws -> Bool {
        if claudeHistoryPlan == nil {
            let projectRoot = locations.claude.appendingPathComponent("projects")
            let transcripts = children(projectRoot).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.flatMap(children).filter { $0.pathExtension == "jsonl" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
                .sorted { Self.modified($0) > Self.modified($1) }
            claudeHistoryPlan = ClaudeHistoryPlan(paths: transcripts)
        }
        guard var plan = claudeHistoryPlan else { return true }
        while plan.nextIndex < plan.paths.count {
            if shouldYield() { claudeHistoryPlan = plan; return false }
            try checkCancellation()
            let i = plan.nextIndex, url = plan.paths[i]
            let id = url.deletingPathExtension().lastPathComponent
            if !plan.imported.insert(id).inserted {
                plan.nextIndex += 1; claudeHistoryPlan = plan
                continue
            }
            let persisted = try index.topic("claude:" + id)
            var topic = topics["claude:" + id] ?? persisted ?? AITopic(id: id, provider: .claude, title: "", modified: Self.modified(url), transcript: url.path)
            if topics[topic.key] == nil { topic.desktopID = "" }
            seenFiles[.claude, default: []].insert(url.path)
            topic.transcript = url.path; topic.modified = max(topic.modified, Self.modified(url))
            try index.upsert(topic)
            try transcript(url, topic: &topic)
            topics[topic.key] = topic
            plan.nextIndex += 1; claudeHistoryPlan = plan
            if i % 8 == 0 { progress() }
        }
        return true
    }
    private func codexTranscripts(shouldYield: () -> Bool, progress: () -> Void) throws -> Bool {
        if codexHistoryPlan == nil {
            codexHistoryPlan = CodexHistoryPlan(metadata: codexMetadataSnapshot, hasMetadata: hasCodexMetadata)
        }
        guard var plan = codexHistoryPlan else { return true }
        if !plan.historyScanned {
            if let url = database(locations.codex, prefix: "thread_history_"), let source = try? AITopicSQL(url, readOnly: true),
               (try source.tables()).contains("thread_items") {
                let columns = try source.columns("thread_items")
                if ["thread_id", "item_id", "item_type", "item_json", "rollout_ordinal"].allSatisfy(columns.contains) {
                    let ordinal = columns.contains("updated_at_ordinal") ? "COALESCE(updated_at_ordinal,rollout_ordinal)" : "rollout_ordinal"
                    let identity = Self.fileIdentity(url)
                    let summary = try source.prepare("SELECT COUNT(*),MAX(rollout_ordinal) FROM thread_items WHERE thread_id=?")
                    let latestUpdate = columns.contains("updated_at_ordinal") ? try source.prepare("SELECT updated_at_ordinal FROM thread_items WHERE thread_id=? ORDER BY updated_at_ordinal DESC LIMIT 1") : nil
                    while plan.nextMetadataIndex < plan.metadata.count {
                        if shouldYield() { codexHistoryPlan = plan; return false }
                        try checkCancellation()
                        let i = plan.nextMetadataIndex, topic = plan.metadata[i]
                        let path = url.path + ":" + topic.id
                        let cursor = try index.cursor(path)
                        sqlite3_reset(summary.handle); summary.bind([topic.id]); _ = try summary.next()
                        let count = summary.int(0), lastOrdinal = summary.int(1)
                        sqlite3_reset(summary.handle)
                        var update = lastOrdinal
                        if let latestUpdate {
                            sqlite3_reset(latestUpdate.handle); latestUpdate.bind([topic.id])
                            if try latestUpdate.next() { update = max(update, latestUpdate.int(0)) }
                            sqlite3_reset(latestUpdate.handle)
                        }
                        // Covering source indexes detect older updates/deletions without rereading every message ID.
                        let fingerprint = identity + ":" + String(topic.modified) + ":" + String(count) + ":" + String(lastOrdinal) + ":" + String(update)
                        if i >= 20 && cursor?.identity == fingerprint {
                            plan.imported.insert(topic.id)
                            if !topic.transcript.isEmpty { plan.canonicalHistoryPaths.insert(Self.normalizedPath(topic.transcript, relativeTo: locations.codex)) }
                            plan.nextMetadataIndex += 1; codexHistoryPlan = plan
                            continue
                        }
                        var offset = cursor?.identity.hasPrefix(identity + ":") == true ? cursor!.offset : -1
                        let live = try source.prepare("SELECT item_id FROM thread_items WHERE thread_id=? AND item_type IN ('userMessage','agentMessage')")
                        live.bind([topic.id]); var liveKeys = Set<String>()
                        while try live.next() { try checkCancellation(); liveKeys.insert("history:" + live.text(0)) }
                        if try index.reconcileMessages(topic.key, prefix: "history:", liveKeys: liveKeys) { offset = -1 }
                        let statement = try source.prepare("SELECT item_id,item_json,\(ordinal) FROM thread_items WHERE thread_id=? AND \(ordinal)>=? AND item_type IN ('userMessage','agentMessage') ORDER BY rollout_ordinal")
                        statement.bind([topic.id]); sqlite3_bind_int64(statement.handle, 2, offset)
                        var last = offset, found = false
                        try index.transaction {
                            if offset == -1 { try index.removeMessages(topic.key, prefix: "history:") }
                            while try statement.next() {
                                try checkCancellation()
                                found = true; last = max(last, statement.int(2))
                                guard let object = try? JSONSerialization.jsonObject(with: Data(statement.text(1).utf8)) as? [String: Any], let message = AITopicTranscript.codex(object) else { continue }
                                try index.message(topic.key, key: "history:" + statement.text(0), body: message.body)
                            }
                            if found || offset >= 0 || cursor != nil { try index.cursor(path, identity: fingerprint, offset: last, topic: topic.key, kind: "history") }
                        }
                        if found || offset >= 0 || cursor != nil {
                            plan.imported.insert(topic.id)
                            if !topic.transcript.isEmpty { plan.canonicalHistoryPaths.insert(Self.normalizedPath(topic.transcript, relativeTo: locations.codex)) }
                            try index.removeMessages(topic.key, prefix: "file:")
                        }
                        plan.nextMetadataIndex += 1; codexHistoryPlan = plan
                        if i % 20 == 0 { progress() }
                    }
                }
            }
            plan.historyScanned = true
            codexHistoryPlan = plan
        }
        if plan.paths == nil {
            // Older versions persist only JSONL. Also discover transcripts absent from the metadata DB.
            var paths = plan.metadata.filter { !plan.imported.contains($0.id) && !$0.transcript.isEmpty }
                .map { URL(fileURLWithPath: Self.normalizedPath($0.transcript, relativeTo: locations.codex)) }
            for root in ["sessions", "archived_sessions"] {
                let directory = locations.codex.appendingPathComponent(root)
                do {
                    _ = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])
                    guard let enumerator = files.enumerator(at: directory, includingPropertiesForKeys: nil, errorHandler: { [self] _, _ in completeProviders.remove(.codex); return true }) else {
                        completeProviders.remove(.codex); plan.enumerationComplete = false
                        continue
                    }
                    for case let url as URL in enumerator {
                        try checkCancellation()
                        if url.pathExtension == "jsonl" { paths.append(url) }
                    }
                } catch {
                    let nsError = error as NSError
                    if nsError.domain != NSCocoaErrorDomain || ![NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code) {
                        completeProviders.remove(.codex); plan.enumerationComplete = false
                    }
                }
            }
            var datedPaths: [(url: URL, modified: Double)] = []
            let uniquePaths = Set(paths)
            datedPaths.reserveCapacity(uniquePaths.count)
            for path in uniquePaths {
                datedPaths.append((path, Self.modified(path)))
                lastCodexDiscoveryMetrics.codexHistorySortDateLookups += 1
            }
            plan.paths = datedPaths.sorted { $0.modified > $1.modified }.map(\.url)
            codexHistoryPlan = plan
        }
        guard let paths = plan.paths else { return false }
        while plan.nextPathIndex < paths.count {
            if shouldYield() { codexHistoryPlan = plan; return false }
            try checkCancellation()
            let i = plan.nextPathIndex, url = paths[i]
            try processCodexRollout(url, order: i, plan: &plan, progress: progress)
            plan.nextPathIndex += 1
            codexHistoryPlan = plan
        }
        if plan.enumerationComplete && completeProviders.contains(.codex) {
            codexHeaders = codexHeaders.filter { plan.currentPaths.contains($0.key) }
        }
        codexHistoryPlan = nil
        return true
    }

    private func processCodexRollout(_ url: URL, order: Int, plan: inout CodexHistoryPlan, progress: () -> Void) throws {
        lastCodexDiscoveryMetrics.enumeratedJSONLFiles += 1
        let path = Self.normalizedPath(url.path, relativeTo: locations.codex)
        plan.currentPaths.insert(path)
        if plan.canonicalHistoryPaths.contains(path) {
            lastCodexDiscoveryMetrics.canonicalHistoryPathsSkipped += 1
            return
        }

        let stamp: CodexFileStamp
        switch Self.codexFileStamp(url) {
        case .success(let value): stamp = value
        case .failure(let code):
            if code != ENOENT && code != ENOTDIR { completeProviders.remove(.codex) }
            return
        }
        let cached = codexHeaders[path]
        let header: CodexHeader
        if let cached, cached.stamp == stamp {
            header = cached
            lastCodexDiscoveryMetrics.cachedHeadersReused += 1
        } else {
            let firstLine: Data
            do {
                let read = try Self.readCodexFirstLine(url)
                firstLine = read.line
                lastCodexDiscoveryMetrics.headerBytesRead += read.bytesRead
            } catch {
                let nsError = error as NSError
                if nsError.domain != NSCocoaErrorDomain || ![NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code) {
                    completeProviders.remove(.codex)
                }
                return
            }
            lastCodexDiscoveryMetrics.headersParsed += 1
            let object = (try? JSONSerialization.jsonObject(with: firstLine)) as? [String: Any]
            let payload = object?["type"] as? String == "session_meta" ? object?["payload"] as? [String: Any] : nil
            let source = payload?["source"] as? [String: Any]
            header = CodexHeader(stamp: stamp, sessionID: payload?["id"] as? String,
                                 project: payload?["cwd"] as? String ?? "", isSubagent: source?["subagent"] != nil,
                                 transcriptImported: false)
            switch Self.codexFileStamp(url) {
            case .success(let current) where current == stamp: codexHeaders[path] = header
            case .failure(ENOENT), .failure(ENOTDIR): return
            default: completeProviders.remove(.codex); return
            }
        }
        guard let id = header.sessionID, !header.isSubagent, !plan.imported.contains(id) else { return }
        if plan.hasMetadata && topics["codex:" + id] == nil { return }
        let persisted = try index.topic("codex:" + id)
        var topic = topics["codex:" + id] ?? persisted ?? AITopic(id: id, provider: .codex, title: "", project: header.project, modified: Self.modified(url), transcript: url.path, archived: url.path.contains("/archived_sessions/"))
        topic.modified = max(topic.modified, Self.modified(url))
        if !plan.hasMetadata {
            topic.project = header.project
            topic.archived = url.path.contains("/archived_sessions/")
        }
        topic.transcript = url.path
        seenFiles[.codex, default: []].insert(url.path)
        if plan.hasMetadata, plan.metadataByKey[topic.key].map({ $0 != topic }) == true {
            codexMetadataDirtyKeys.insert(topic.key)
        }
        try index.upsert(topic)
        // Reuse only a completed import. Metadata remains authoritative when its title or archive state changes.
        if !(header.transcriptImported && persisted?.transcript == url.path) {
            try transcript(url, topic: &topic, clearDerivedFieldsOnRewrite: !plan.hasMetadata)
            if completeProviders.contains(.codex), var updated = codexHeaders[path] {
                updated.transcriptImported = true; codexHeaders[path] = updated
            }
        }
        if plan.hasMetadata, plan.metadataByKey[topic.key].map({ $0 != topic }) == true {
            codexMetadataDirtyKeys.insert(topic.key)
        }
        topics[topic.key] = topic
        plan.imported.insert(id)
        if order % 8 == 0 { progress() }
    }
    private func transcript(_ url: URL, topic: inout AITopic, clearDerivedFieldsOnRewrite: Bool = false) throws {
        guard let attributes = try? files.attributesOfItem(atPath: url.path), let size = attributes[.size] as? NSNumber,
              let handle = try? FileHandle(forReadingFrom: url) else { completeProviders.remove(topic.provider); return }
        defer { try? handle.close() }
        let cursor = try index.cursor(url.path)
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? "0"
        let stamp = String((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        var offset: Int64 = 0
        if let cursor {
            let fields = cursor.identity.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if fields.count == 6, fields[0] == inode, let length = Int(fields[1]), let tailLength = Int(fields[4]), size.int64Value >= cursor.offset {
                let prefix = try handle.read(upToCount: length) ?? Data()
                try handle.seek(toOffset: UInt64(max(0, cursor.offset - Int64(tailLength))))
                let tail = try handle.read(upToCount: tailLength) ?? Data()
                if Self.hash(prefix) == fields[2], Self.hash(tail) == fields[5], size.int64Value > cursor.offset || fields[3] == stamp { offset = cursor.offset }
            }
        }
        if offset == size.int64Value && (size.int64Value > 0 || cursor?.offset == 0) { return }
        try handle.seek(toOffset: UInt64(offset))
        var buffer = Data(), position = offset
        try index.transaction {
            if offset == 0 {
                try index.removeMessages(topic.key, prefix: "file:")
                if topic.provider == .claude && topic.desktopID.isEmpty {
                    topic.title = ""; topic.project = ""; topic.excerpt = ""
                } else if clearDerivedFieldsOnRewrite {
                    topic.title = ""; topic.excerpt = ""
                }
            }
            while true {
                let remaining = size.int64Value - position - Int64(buffer.count)
                guard remaining > 0 else { break }
                let readCount = Int(min(Int64(256 * 1024), remaining))
                guard let chunk = try handle.read(upToCount: readCount), !chunk.isEmpty else { break }
                try checkCancellation()
                buffer.append(chunk)
                var start = buffer.startIndex
                while let end = buffer[start...].firstIndex(of: 10) {
                    let line = buffer[start..<end]
                    try consume(line, offset: position, topic: &topic)
                    position += Int64(line.count + 1); start = end + 1
                }
                if start > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start) }
            }
            // An unfinished append is retried from the last complete JSON record.
            if !buffer.isEmpty, (try? JSONSerialization.jsonObject(with: buffer)) != nil {
                try consume(buffer[...], offset: position, topic: &topic); position += Int64(buffer.count)
            }
            try index.upsert(topic)
            try handle.seek(toOffset: 0)
            let length = min(512, Int(position)), prefix = try handle.read(upToCount: length) ?? Data()
            try handle.seek(toOffset: UInt64(max(0, position - Int64(length))))
            let tail = try handle.read(upToCount: length) ?? Data()
            try index.cursor(url.path, identity: inode + ":" + String(length) + ":" + Self.hash(prefix) + ":" + stamp + ":" + String(length) + ":" + Self.hash(tail), offset: position, topic: topic.key, kind: "file")
        }
    }
    private func consume(_ line: Data.SubSequence, offset: Int64, topic: inout AITopic) throws {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return }
        if topic.provider == .claude {
            if topic.project.isEmpty { topic.project = object["cwd"] as? String ?? "" }
            if topic.desktopID.isEmpty {
                if let title = object["customTitle"] as? String ?? object["aiTitle"] as? String { topic.title = title }
            }
        }
        guard let message = topic.provider == .claude ? AITopicTranscript.claude(object) : AITopicTranscript.codex(object) else { return }
        if message.user && topic.title.isEmpty { topic.title = String(message.body.prefix(120)).replacingOccurrences(of: "\n", with: " ") }
        if topic.excerpt.isEmpty { topic.excerpt = String(message.body.prefix(220)) }
        try index.message(topic.key, key: "file:" + String(offset), body: message.body)
    }
    private static func normalizedPath(_ path: String, relativeTo root: URL) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, relativeTo: root).standardizedFileURL.path
    }
    private static func codexFileStamp(_ url: URL) -> CodexStampResult {
        var status = stat()
        let result = url.path.withCString { fstatat(AT_FDCWD, $0, &status, 0) }
        guard result == 0 else { return .failure(errno) }
        return .success(CodexFileStamp(device: UInt64(status.st_dev), inode: UInt64(status.st_ino), size: Int64(status.st_size),
                                       modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
                                       modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec),
                                       changedSeconds: Int64(status.st_ctimespec.tv_sec),
                                       changedNanoseconds: Int64(status.st_ctimespec.tv_nsec)))
    }
    private static func readCodexFirstLine(_ url: URL) throws -> (line: Data, bytesRead: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let maximumHeaderBytes = 128 * 1024
        var line = Data(), bytesRead = 0
        while bytesRead < maximumHeaderBytes {
            let chunk = try handle.read(upToCount: min(4096, maximumHeaderBytes - bytesRead)) ?? Data()
            guard !chunk.isEmpty else { break }
            bytesRead += chunk.count
            if let newline = chunk.firstIndex(of: 10) {
                line.append(contentsOf: chunk[..<newline])
                return (line, bytesRead)
            }
            line.append(chunk)
        }
        return (line, bytesRead)
    }
    private static func fileIdentity(_ url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.systemFileNumber] as? NSNumber)?.stringValue ?? "0"
    }
    private static func modified(_ url: URL) -> Double { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0 }
    private static func hash(_ data: Data) -> String {
        var value: UInt64 = 14695981039346656037
        for byte in data { value = (value ^ UInt64(byte)) &* 1099511628211 }
        return String(value, radix: 16)
    }
    private static func date(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { let value = number.doubleValue; return value > 100_000_000_000 ? value / 1000 : value }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text))?.timeIntervalSince1970
    }
}
