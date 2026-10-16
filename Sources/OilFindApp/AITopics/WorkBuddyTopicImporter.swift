import Foundation

/// The desktop database owns visibility. Orphan logs and nested subagents are never imported.
final class WorkBuddyTopicImporter {
    private struct Log { let url: URL; let sessionID: String }
    private let index: AITopicIndex
    private let root: URL
    private let checkpoint: () throws -> Void
    private let files = FileManager.default
    private var complete = true

    init(index: AITopicIndex, root: URL, checkpoint: @escaping () throws -> Void) {
        self.index = index; self.root = root; self.checkpoint = checkpoint
    }

    private func children(_ url: URL) -> [URL] {
        do { return try files.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]) }
        catch {
            let error = error as NSError
            if error.domain != NSCocoaErrorDomain || ![NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { complete = false }
            return []
        }
    }

    static func account(in root: URL) -> String? {
        // This is WorkBuddy's small, noncredential UI cache, not its encrypted authentication store.
        let url = root.appendingPathComponent("storage/skeleton/account-snapshot.json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4096,
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let primary = object["primary"] as? [String: Any], primary["version"] as? Int == 1,
              let uid = primary["uid"] as? String, !uid.isEmpty,
              primary["nickname"] is String, primary["type"] is String,
              let saved = primary["savedAt"] as? Double, saved.isFinite,
              Date().timeIntervalSince1970 * 1000 - saved <= 30 * 86400 * 1000 else { return nil }
        return uid
    }

    func refresh(metadataOnly: Bool = false, progress: () -> Void) throws {
        try checkpoint()
        let accountID = Self.account(in: root)
        try index.synchronizeScope(accountID ?? "", provider: .workbuddy)
        guard let uid = accountID else {
            // Logout, expired account hints and damaged snapshots must not expose another account's cache.
            try index.reconcile(provider: .workbuddy, topics: [], files: [])
            return
        }
        let database = root.appendingPathComponent("workbuddy.db")
        let source = try AITopicSQL(database, readOnly: true)
        let columns = try source.columns("sessions")
        guard ["id", "cwd", "user_id", "title", "status", "created_at", "updated_at", "deleted_at"].allSatisfy(columns.contains) else {
            throw AITopicError.database("Unsupported WorkBuddy session database")
        }
        let column: (String, String) -> String = { columns.contains($0) ? "COALESCE(\($0),\($1))" : $1 }
        // Local desktop conversations only. Cloud tombstones have different semantics and are not logs.
        let transport = columns.contains("transport") ? "AND transport='local'" : ""
        let statement = try source.prepare("""
            SELECT id,cwd,COALESCE(NULLIF(\(column("custom_title", "''")),''),title,''),
              MAX(updated_at,\(column("last_activity_at", "0")),created_at),status,\(column("session_settings", "''"))
            FROM sessions WHERE deleted_at IS NULL AND (user_id=? OR user_id='') \(transport)
            ORDER BY updated_at DESC
            """)
        statement.bind([uid])
        var topics: [AITopic] = []
        while try statement.next() {
            try checkpoint()
            let id = statement.text(0)
            guard id.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil else { continue }
            let settings = statement.text(5)
            if !settings.isEmpty {
                guard let value = try? JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any] else { continue }
                if (value["conversationTags"] as? [String: Any])?["wbQuickAsk"] as? String == "1" { continue }
            }
            topics.append(AITopic(id: id, provider: .workbuddy,
                title: String(statement.text(2).prefix(120)).replacingOccurrences(of: "\n", with: " "),
                project: statement.text(1), modified: statement.double(3) / 1000,
                archived: statement.text(4).lowercased() == "archived"))
        }
        var logs: [String: Log] = [:], aliases: [String: Log] = [:], quickAsk = Set<String>()
        for project in children(root.appendingPathComponent("projects")) where (try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            for url in children(project) {
                try checkpoint()
                if url.pathExtension == "quickask" { quickAsk.insert(url.deletingPathExtension().lastPathComponent) }
                if url.lastPathComponent.hasSuffix(".acp-session.json"),
                   let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4096,
                   let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let alias = object["acpSessionId"] as? String,
                   alias.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil {
                    let file = project.appendingPathComponent(alias + ".jsonl")
                    if Self.isRegularLog(file) {
                        let id = String(url.lastPathComponent.dropLast(".acp-session.json".count))
                        aliases[id] = Log(url: file, sessionID: alias)
                    }
                }
                guard url.pathExtension == "jsonl" else { continue }
                guard Self.isRegularLog(url) else { continue }
                let id = url.deletingPathExtension().lastPathComponent
                if let old = logs[id], Self.modified(old.url) >= Self.modified(url) { continue }
                logs[id] = Log(url: url, sessionID: id)
            }
        }
        for (id, alias) in aliases where logs[id] == nil { logs[id] = alias }
        topics.removeAll { quickAsk.contains($0.id) }
        var seen = Set<String>()
        // Preserve file bodies on enumeration failure, but still reconcile authoritative deletion and archives.
        if !complete {
            let cursors = try index.sql.prepare("SELECT c.path FROM topic_cursors c JOIN topics t ON c.topic=t.pk WHERE t.provider='workbuddy' AND c.kind='file'")
            while try cursors.next() { seen.insert(cursors.text(0)) }
        }
        try index.transaction {
            for i in topics.indices {
                try checkpoint()
                let cached = try index.topic(topics[i].key)
                if let log = logs[topics[i].id] {
                    topics[i].transcript = log.url.path; seen.insert(log.url.path)
                    topics[i].excerpt = cached?.excerpt ?? ""
                } else if !complete {
                    topics[i].transcript = cached?.transcript ?? ""; topics[i].excerpt = cached?.excerpt ?? ""
                }
                try index.upsert(topics[i])
            }
        }
        try index.reconcile(provider: .workbuddy, topics: Set(topics.map(\.key)), files: seen)
        progress()
        if metadataOnly {
            if !complete { throw AITopicError.database("Cannot read some WorkBuddy conversation files") }
            return
        }
        var damaged = !complete
        for var topic in topics {
            try checkpoint()
            guard let log = logs[topic.id] else { continue }
            do { try importLog(log.url, sessionID: log.sessionID, topic: &topic) }
            catch is CancellationError { throw CancellationError() }
            catch { damaged = true }
            progress()
        }
        if damaged { throw AITopicError.database("Cannot read some WorkBuddy conversation files") }
    }

    private func importLog(_ url: URL, sessionID: String, topic: inout AITopic) throws {
        let attributes = try files.attributesOfItem(atPath: url.path)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? "0"
        let stamp = String((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        var offset = 0
        if let cursor = try index.cursor(url.path) {
            let fields = cursor.identity.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if fields.count == 7, fields[0] == "workbuddy3", fields[1] == inode,
               let head = Int(fields[2]), let tail = Int(fields[4]), let end = Int(exactly: cursor.offset),
               head >= 0, tail >= 0, end >= tail, data.count >= end, data.count >= head,
               Self.hash(data.prefix(head)) == fields[3], Self.hash(data[(end - tail)..<end]) == fields[5],
               data.count > end || fields[6] == stamp { offset = end }
        }
        guard offset != data.count || offset == 0 else { return }
        let previous = try index.cursor(url.path)
        func records(from start: Int) throws -> (objects: [[String: Any]], end: Int) {
            var objects: [[String: Any]] = [], position = start
            while position < data.count, let end = data[position...].firstIndex(of: 10) {
                try checkpoint()
                let line = data[position..<end]
                if !line.isEmpty {
                    guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], object["type"] is String else {
                        throw AITopicError.database("Invalid WorkBuddy conversation record")
                    }
                    let savedSession = object["sessionId"] as? String
                    if savedSession == nil || savedSession == topic.id || savedSession == sessionID {
                        var node = object.filter { ["type", "id", "parentId", "logicalParentId", "role", "sessionId", "status", "providerData", "isMeta"].contains($0.key) }
                        if object["type"] as? String == "message" { node["content"] = AITopicTranscript.text(object["content"]) }
                        objects.append(node)
                    }
                }
                position = end + 1
            }
            return (objects, position)
        }
        var parsed = try records(from: offset)
        if offset > 0, parsed.objects.contains(where: {
            $0["type"] as? String == "resend-fork-notice" ||
                ($0["type"] as? String == "message" && $0["role"] as? String == "user") ||
                ($0["providerData"] as? [String: Any])?["contentFilterNotice"] as? Bool == true
        }) {
            // New user branches and tombstones can invalidate older keys; ordinary assistant appends stay incremental.
            offset = 0; parsed = try records(from: 0)
        }
        let position = parsed.end
        try index.transaction {
            if offset == 0 { try index.removeMessages(topic.key, prefix: "file:"); topic.excerpt = "" }
            let active = offset == 0 ? WorkBuddyReplay.activeIndices(parsed.objects) : Set(parsed.objects.indices)
            for i in parsed.objects.indices where active.contains(i) {
                try checkpoint()
                let object = parsed.objects[i]
                guard object["type"] as? String == "message", let id = object["id"] as? String, !id.isEmpty,
                      let savedSession = object["sessionId"] as? String, savedSession == topic.id || savedSession == sessionID else { continue }
                let body = WorkBuddyReplay.text(object)
                try index.message(topic.key, key: "file:" + id, body: body)
                if topic.excerpt.isEmpty { topic.excerpt = String(body.prefix(220)) }
            }
            if offset == 0, previous != nil, position < data.count {
                throw AITopicError.database("Incomplete replacement WorkBuddy conversation log")
            }
            try index.upsert(topic)
            let head = min(512, position), tail = min(512, position)
            let identity = ["workbuddy3", inode, String(head), Self.hash(data.prefix(head)), String(tail), Self.hash(data[(position - tail)..<position]), stamp].joined(separator: ":")
            try index.cursor(url.path, identity: identity, offset: Int64(position), topic: topic.key, kind: "file")
        }
    }

    private static func hash(_ data: Data.SubSequence) -> String {
        var value: UInt64 = 14695981039346656037
        for byte in data { value = (value ^ UInt64(byte)) &* 1099511628211 }
        return String(value, radix: 16)
    }
    private static func modified(_ url: URL) -> Double {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
    }
    private static func isRegularLog(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}
