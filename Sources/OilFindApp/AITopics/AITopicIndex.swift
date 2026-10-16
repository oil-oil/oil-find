import Foundation
import SQLite3
import Compression
import Darwin

private final class TopicCancellation {
    let cancelled: () -> Bool
    init(_ cancelled: @escaping () -> Bool) { self.cancelled = cancelled }
}

private final class TopicBuffer {
    private var storage = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    private var capacity = 1
    deinit { storage.deallocate() }
    func decode(_ source: UnsafeRawPointer?, count: Int, length: Int) throws -> UnsafeBufferPointer<UInt8> {
        guard let source, count > 0, length >= 0 else { throw AITopicError.database("Invalid compressed topic data") }
        let bytes = source.assumingMemoryBound(to: UInt8.self)
        if bytes[0] == 0 {
            guard count - 1 == length else { throw AITopicError.database("Invalid plain topic data") }
            return UnsafeBufferPointer(start: bytes + 1, count: length)
        }
        guard bytes[0] == 1 || bytes[0] == 2 else { throw AITopicError.database("Unknown topic compression") }
        if length > capacity {
            storage.deallocate(); capacity = length; storage = .allocate(capacity: max(1, length))
        }
        let decoded = compression_decode_buffer(storage, length, bytes + 1, count - 1, nil, bytes[0] == 2 ? COMPRESSION_ZLIB : COMPRESSION_LZFSE)
        guard decoded == length else { throw AITopicError.database("Cannot decode topic data") }
        return UnsafeBufferPointer(start: storage, count: decoded)
    }
}

private struct TopicSearchCacheKey: Hashable {
    let terms: [String]
    let provider: String?
    let providers: [String]?
    let limit: Int
}

private struct CachedTopicSearch {
    let key: TopicSearchCacheKey
    let version: Int64, changes: Int64
    let topics: [AITopic]
    let more: Bool
    let cost: Int
}

private final class CachedTopicDocument {
    let key: Int64, revision: Int64, text: Data, boundaries: Data
    weak var previous: CachedTopicDocument?
    var next: CachedTopicDocument?
    var cost: Int { text.count + boundaries.count + 128 }
    init(key: Int64, revision: Int64, text: Data, boundaries: Data) {
        self.key = key; self.revision = revision; self.text = text; self.boundaries = boundaries
    }
}

/// Topic-level candidate postings, compressed message bodies, and compressed verification documents.
/// No expanded token strings or duplicate uncompressed bodies are stored in SQLite.
public final class AITopicIndex {
    let sql: AITopicSQL
    private let readOnly: Bool
    private var inTransaction = false
    private var dirty = Set<Int64>()
    private var dirtyRows: [Int64: Set<Int64>] = [:]
    private var incremental: Bool
    private var chunkSummaries = false
    /// Invoked between bounded pieces of indexing work, including long gram construction.
    var workCheckpoint: (() throws -> Void)?
    private(set) var lastWriteStats = (foldedBytes: 0, chunks: 0)
    private var cachedSearches: [CachedTopicSearch] = []
    private(set) var searchCacheBytes = 0
    private var resultCacheBudget: Int { min(8 * 1024 * 1024, cacheBudget / 4) }
    private var documentCacheBudget: Int { cacheBudget - resultCacheBudget }
    private(set) var resultCacheHits = 0
    private(set) var lastVerifiedMessageRanges = 0
    private var topicKeys: [String: Int64] = [:]
    private var statements: [String: AITopicStatement] = [:]
    private let buffer = TopicBuffer()
    private var documents: [Int64: CachedTopicDocument] = [:]
    private var cacheHead: CachedTopicDocument?, cacheTail: CachedTopicDocument?
    private var cacheBytes = 0
    private var cacheEpoch: (version: Int64, changes: Int64)?
    private let cacheBudget: Int
    private(set) var cacheHits = 0
    var documentCacheBytes: Int { cacheBytes }
    private(set) var lastSearchStats = (candidates: 0, decodedBytes: 0)

    public init(url: URL, readOnly: Bool = false, cacheBudgetBytes: Int = 32 * 1024 * 1024) throws {
        self.readOnly = readOnly; cacheBudget = max(0, cacheBudgetBytes)
        sql = try AITopicSQL(url, readOnly: readOnly)
        if readOnly {
            incremental = try sql.tables().contains("topic_chunks")
            if incremental { chunkSummaries = try sql.columns("topic_chunks").contains("fully_live") }
            return
        }
        incremental = true
        try sql.run("""
            PRAGMA journal_mode=WAL;
            PRAGMA foreign_keys=ON;
            BEGIN IMMEDIATE;
            CREATE TABLE IF NOT EXISTS topics(
                pk INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
                session TEXT NOT NULL, provider TEXT NOT NULL, title TEXT NOT NULL,
                project TEXT NOT NULL, modified REAL NOT NULL, desktop TEXT NOT NULL,
                transcript TEXT NOT NULL, archived INTEGER NOT NULL, excerpt TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS topics_recent ON topics(modified DESC,id);
            CREATE TABLE IF NOT EXISTS messages(
                rowid INTEGER PRIMARY KEY, topic INTEGER NOT NULL REFERENCES topics(pk) ON DELETE CASCADE,
                key TEXT NOT NULL, body BLOB NOT NULL, bytes INTEGER NOT NULL, UNIQUE(topic,key));
            CREATE TABLE IF NOT EXISTS topic_docs(
                topic INTEGER PRIMARY KEY REFERENCES topics(pk) ON DELETE CASCADE,
                folded BLOB NOT NULL, bytes INTEGER NOT NULL, boundaries BLOB NOT NULL, revision INTEGER NOT NULL DEFAULT 1);
            CREATE VIRTUAL TABLE IF NOT EXISTS topic_fts USING fts5(grams,content='',contentless_delete=1,detail=none);
            CREATE TRIGGER IF NOT EXISTS topic_delete AFTER DELETE ON topics BEGIN
                DELETE FROM topic_fts WHERE rowid=old.pk;
            END;
            CREATE TABLE IF NOT EXISTS topic_cursors(
                path TEXT PRIMARY KEY, identity TEXT NOT NULL, offset INTEGER NOT NULL,
                topic INTEGER NOT NULL REFERENCES topics(pk) ON DELETE CASCADE, kind TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS topic_scopes(provider TEXT PRIMARY KEY, identity TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS topic_chunks(
                id INTEGER PRIMARY KEY AUTOINCREMENT, topic INTEGER NOT NULL REFERENCES topics(pk) ON DELETE CASCADE,
                folded BLOB NOT NULL, bytes INTEGER NOT NULL, boundaries BLOB NOT NULL,
                fully_live INTEGER NOT NULL DEFAULT 1, first_row INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX IF NOT EXISTS topic_chunks_topic ON topic_chunks(topic);
            CREATE TABLE IF NOT EXISTS topic_chunk_rows(
                message INTEGER PRIMARY KEY REFERENCES messages(rowid) ON DELETE CASCADE,
                topic INTEGER NOT NULL REFERENCES topics(pk) ON DELETE CASCADE,
                chunk INTEGER NOT NULL REFERENCES topic_chunks(id) ON DELETE CASCADE);
            CREATE INDEX IF NOT EXISTS topic_chunk_rows_topic ON topic_chunk_rows(topic);
            CREATE INDEX IF NOT EXISTS topic_chunk_rows_chunk ON topic_chunk_rows(chunk);
            CREATE TABLE IF NOT EXISTS topic_overrides(
                topic INTEGER NOT NULL REFERENCES topics(pk) ON DELETE CASCADE, row INTEGER NOT NULL,
                PRIMARY KEY(topic,row));
            CREATE VIRTUAL TABLE IF NOT EXISTS topic_chunk_fts USING fts5(grams,content='',contentless_delete=1,detail=none);
            CREATE TRIGGER IF NOT EXISTS topic_message_delete BEFORE DELETE ON messages BEGIN
                INSERT OR IGNORE INTO topic_overrides SELECT old.topic,old.rowid WHERE EXISTS(SELECT 1 FROM topic_docs WHERE topic=old.topic AND bytes>0);
            END;
            CREATE TRIGGER IF NOT EXISTS topic_chunk_row_delete AFTER DELETE ON topic_chunk_rows BEGIN
                DELETE FROM topic_chunks WHERE id=old.chunk AND NOT EXISTS(SELECT 1 FROM topic_chunk_rows WHERE chunk=old.chunk);
            END;
            CREATE TRIGGER IF NOT EXISTS topic_chunk_delete AFTER DELETE ON topic_chunks BEGIN
                DELETE FROM topic_chunk_fts WHERE rowid=old.id;
            END;
            """)
        if try !sql.columns("topic_docs").contains("revision") { try sql.run("ALTER TABLE topic_docs ADD COLUMN revision INTEGER NOT NULL DEFAULT 1") }
        if try !sql.columns("topic_docs").contains("base_revision") {
            try sql.run("ALTER TABLE topic_docs ADD COLUMN base_revision INTEGER NOT NULL DEFAULT 1; UPDATE topic_docs SET base_revision=revision")
        }
        if try !sql.columns("topic_chunks").contains("fully_live") {
            try sql.run("""
                ALTER TABLE topic_chunks ADD COLUMN fully_live INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE topic_chunks ADD COLUMN first_row INTEGER NOT NULL DEFAULT 0;
                UPDATE topic_chunks SET fully_live=(SELECT count(*) FROM topic_chunk_rows WHERE chunk=topic_chunks.id)=length(boundaries)/16,
                    first_row=coalesce((SELECT min(message) FROM topic_chunk_rows WHERE chunk=topic_chunks.id),0);
                """)
        }
        // A deletion makes only its original chunk sparse; other chunks retain their contiguous fast path.
        try sql.run("""
            DROP TRIGGER IF EXISTS topic_chunk_row_delete;
            CREATE TRIGGER topic_chunk_row_delete AFTER DELETE ON topic_chunk_rows BEGIN
                UPDATE topic_chunks SET fully_live=0 WHERE id=old.chunk;
                DELETE FROM topic_chunks WHERE id=old.chunk AND NOT EXISTS(SELECT 1 FROM topic_chunk_rows WHERE chunk=old.chunk);
            END;
            DELETE FROM topic_scopes WHERE provider='harness';
            DELETE FROM topics WHERE provider='harness';
            COMMIT;
            """)
        chunkSummaries = true
    }
    static func fold(_ text: String) -> String { text.precomposedStringWithCanonicalMapping.lowercased() }
    private func prepareMaintenance() throws {
        guard !inTransaction else { throw AITopicError.database("Cannot maintain an active topic transaction") }
        // Only the writer queue invokes maintenance, after importer work has returned.
        statements.values.forEach { sqlite3_reset($0.handle) }
    }
    func checkpoint() throws {
        try prepareMaintenance()
        try sql.run("PRAGMA wal_checkpoint(PASSIVE)")
    }
    func finishInitialImport() throws {
        try prepareMaintenance()
        let version: Int64
        do { let s = try sql.prepare("PRAGMA user_version"); _ = try s.next(); version = s.int(0); sqlite3_reset(s.handle) }
        guard version == 0 else { return }
        try sql.run("INSERT INTO topic_fts(topic_fts) VALUES('optimize'); INSERT INTO topic_chunk_fts(topic_chunk_fts) VALUES('optimize'); VACUUM; PRAGMA user_version=1")
    }
    static func grams(_ text: String, query: Bool = false) -> String {
        // Query callers do not need cooperative indexing checkpoints.
        try! grams(text, query: query, checkpoint: nil)
    }
    private static func grams(_ text: String, query: Bool = false, checkpoint: (() throws -> Void)?) throws -> String {
        let scalars = text.unicodeScalars
        let count = scalars.count
        let shortQuery = query && count < 3
        let asciiQuery = query && scalars.allSatisfy { $0.value < 128 }
        var values = Set<UInt64>()
        var previous: UInt32?, beforePrevious: UInt32?
        var processed = 0
        for scalar in scalars {
            processed += 1
            if processed & 4095 == 0 { try checkpoint?() }
            let value = scalar.value
            if !query || count == 1 { values.insert(UInt64(value)) }
            if let previous, !query || shortQuery || !asciiQuery {
                values.insert((1 << 42) | UInt64(previous) << 21 | UInt64(value))
            }
            if let previous, let beforePrevious, previous < 128 && beforePrevious < 128 && value < 128 {
                values.insert((1 << 63) | UInt64(beforePrevious) << 42 | UInt64(previous) << 21 | UInt64(value))
            }
            beforePrevious = previous; previous = value
        }
        let separator = query ? " AND " : " "
        var result = ""; result.reserveCapacity(values.count * 18)
        for (index, value) in values.sorted().enumerated() {
            if index & 4095 == 0 { try checkpoint?() }
            if !result.isEmpty { result += separator }; result += "x"; result += String(value, radix: 16)
        }
        return result
    }
    private static func pack(_ data: Data, compact: Bool = false) -> Data {
        guard !data.isEmpty else { return Data([0]) }
        var compressed = Data(count: data.count)
        let count = compressed.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                compression_encode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, output.count,
                                          input.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, compact ? COMPRESSION_ZLIB : COMPRESSION_LZFSE)
            }
        }
        if count > 0 && count < data.count {
            compressed.count = count; var result = Data([compact ? 2 : 1]); result.append(compressed); return result
        }
        var result = Data([0]); result.append(data); return result
    }
    private func statement(_ query: String) throws -> AITopicStatement {
        if let s = statements[query] { sqlite3_reset(s.handle); sqlite3_clear_bindings(s.handle); return s }
        let s = try sql.prepare(query); statements[query] = s; return s
    }
    private func bindBlob(_ data: Data, _ column: Int32, _ s: AITopicStatement) {
        _ = data.withUnsafeBytes { sqlite3_bind_blob(s.handle, column, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func key(_ topic: String) throws -> Int64 {
        if let key = topicKeys[topic] { return key }
        let s = try statement("SELECT pk FROM topics WHERE id=?"); s.bind([topic])
        defer { sqlite3_reset(s.handle) }
        guard try s.next() else { throw AITopicError.database("Missing topic") }
        let value = s.int(0); topicKeys[topic] = value; return value
    }
    func transaction(_ work: () throws -> Void) throws {
        if inTransaction { try work(); return }
        try workCheckpoint?()
        try sql.run("BEGIN IMMEDIATE"); inTransaction = true
        lastWriteStats = (0, 0)
        do {
            try work(); try flush(); try workCheckpoint?(); statements.values.forEach { sqlite3_reset($0.handle) }; try sql.run("COMMIT"); inTransaction = false
        } catch {
            statements.values.forEach { sqlite3_reset($0.handle) }; try? sql.run("ROLLBACK"); inTransaction = false; dirty.removeAll(); dirtyRows.removeAll(); topicKeys.removeAll()
            documents.removeAll(); cacheHead = nil; cacheTail = nil; cacheBytes = 0; cacheEpoch = nil
            cachedSearches.removeAll(); searchCacheBytes = 0
            throw error
        }
    }
    private func flush() throws {
        for topic in dirty {
            try workCheckpoint?()
            // Existing verification documents remain immutable. Only changed messages are folded,
            // posted and compressed, in chunks close to 64 KiB rather than whole conversations.
            let doc = try statement("INSERT INTO topic_docs(topic,folded,bytes,boundaries,revision,base_revision) VALUES(?,x'00',0,x'',1,1) ON CONFLICT(topic) DO UPDATE SET revision=topic_docs.revision+1")
            sqlite3_bind_int64(doc.handle, 1, topic); _ = try doc.next()
            var folded = Data(), boundaries = Data(), members: [Int64] = []
            func writeChunk() throws {
                guard !members.isEmpty else { return }
                try workCheckpoint?()
                let grams = try Self.grams(String(decoding: folded, as: UTF8.self), checkpoint: workCheckpoint)
                let packed = Self.pack(folded)
                try workCheckpoint?()
                let chunk = try statement("INSERT INTO topic_chunks(topic,folded,bytes,boundaries,first_row,fully_live) VALUES(?,?,?,?,?,1)")
                sqlite3_bind_int64(chunk.handle, 1, topic); bindBlob(packed, 2, chunk)
                sqlite3_bind_int64(chunk.handle, 3, Int64(folded.count)); bindBlob(boundaries, 4, chunk); sqlite3_bind_int64(chunk.handle, 5, members[0]); _ = try chunk.next()
                let chunkID = sqlite3_last_insert_rowid(sql.db)
                let fts = try statement("INSERT INTO topic_chunk_fts(rowid,grams) VALUES(?,?)")
                fts.bind([String(chunkID), grams]); _ = try fts.next()
                for row in members {
                    let owner = try statement("INSERT INTO topic_chunk_rows(message,topic,chunk) VALUES(?,?,?)")
                    owner.bind([String(row), String(topic), String(chunkID)]); _ = try owner.next()
                }
                lastWriteStats.chunks += 1
                folded.removeAll(keepingCapacity: true); boundaries.removeAll(keepingCapacity: true); members.removeAll(keepingCapacity: true)
            }
            for row in (dirtyRows[topic] ?? []).sorted() {
                try workCheckpoint?()
                let message = try statement("SELECT body,bytes FROM messages WHERE rowid=? AND topic=?")
                message.bind([String(row), String(topic)])
                guard try message.next() else { continue }
                let body = try buffer.decode(sqlite3_column_blob(message.handle, 0), count: Int(sqlite3_column_bytes(message.handle, 0)), length: Int(message.int(1)))
                let text = Data(Self.fold(String(decoding: body, as: UTF8.self)).utf8)
                try workCheckpoint?()
                if !folded.isEmpty && folded.count + text.count + 1 > 64 * 1024 { try writeChunk() }
                folded.append(text); folded.append(10); members.append(row)
                lastWriteStats.foldedBytes += text.count + 1
                var end = UInt64(folded.count).littleEndian, id = UInt64(row).littleEndian
                withUnsafeBytes(of: &end) { boundaries.append(contentsOf: $0) }
                withUnsafeBytes(of: &id) { boundaries.append(contentsOf: $0) }
            }
            try writeChunk()
        }
        dirty.removeAll(keepingCapacity: true); dirtyRows.removeAll(keepingCapacity: true)
    }
    private func changed(_ topic: Int64, row: Int64) throws {
        let overrideStatement = try statement("INSERT OR IGNORE INTO topic_overrides(topic,row) SELECT ?,? WHERE EXISTS(SELECT 1 FROM topic_docs WHERE topic=? AND bytes>0)")
        overrideStatement.bind([String(topic), String(row), String(topic)]); _ = try overrideStatement.next()
        let old = try statement("DELETE FROM topic_chunk_rows WHERE message=?")
        sqlite3_bind_int64(old.handle, 1, row); _ = try old.next()
        dirtyRows[topic, default: []].insert(row); dirty.insert(topic)
    }
    func upsert(_ topic: AITopic) throws {
        try transaction {
            let s = try statement("""
                INSERT INTO topics(id,session,provider,title,project,modified,desktop,transcript,archived,excerpt)
                VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                title=excluded.title,project=excluded.project,modified=excluded.modified,desktop=excluded.desktop,
                transcript=excluded.transcript,archived=excluded.archived,excerpt=excluded.excerpt
                WHERE title!=excluded.title OR project!=excluded.project OR modified!=excluded.modified OR desktop!=excluded.desktop
                   OR transcript!=excluded.transcript OR archived!=excluded.archived OR excerpt!=excluded.excerpt
                """)
            s.bind([topic.key, topic.id, topic.provider.rawValue, topic.title, topic.project, String(topic.modified), topic.desktopID, topic.transcript, topic.archived ? "1" : "0", topic.excerpt]); _ = try s.next()
            try message(topic.key, key: "meta", body: topic.title + "\n" + topic.project)
        }
    }
    func message(_ topic: String, key messageKey: String, body: String) throws {
        try transaction {
            let pk = try key(topic)
            if body.isEmpty {
                let s = try statement("DELETE FROM messages WHERE topic=? AND key=?"); s.bind([String(pk), messageKey]); _ = try s.next()
                if sqlite3_changes(sql.db) > 0 { dirty.insert(pk) }; return
            }
            try workCheckpoint?()
            let bytes = Data(body.utf8)
            let old = try statement("SELECT body,bytes FROM messages WHERE topic=? AND key=?"); old.bind([String(pk), messageKey])
            if try old.next(), old.int(1) == bytes.count {
                let existing = try buffer.decode(sqlite3_column_blob(old.handle, 0), count: Int(sqlite3_column_bytes(old.handle, 0)), length: Int(old.int(1)))
                if bytes.elementsEqual(existing) { return }
            }
            let s = try statement("INSERT INTO messages(topic,key,body,bytes) VALUES(?,?,?,?) ON CONFLICT(topic,key) DO UPDATE SET body=excluded.body,bytes=excluded.bytes")
            s.bind([String(pk), messageKey]); bindBlob(Self.pack(bytes, compact: true), 3, s); sqlite3_bind_int64(s.handle, 4, Int64(bytes.count)); _ = try s.next()
            let current = try statement("SELECT rowid FROM messages WHERE topic=? AND key=?")
            current.bind([String(pk), messageKey]); guard try current.next() else { throw AITopicError.database("Missing message") }
            try changed(pk, row: current.int(0))
        }
    }
    func topic(_ key: String) throws -> AITopic? {
        guard let separator = key.firstIndex(of: ":"),
              AITopicProvider(rawValue: String(key[..<separator])) != nil else { return nil }
        let s = try statement("SELECT session,provider,title,project,modified,desktop,transcript,archived,excerpt FROM topics WHERE id=?"); s.bind([key])
        defer { sqlite3_reset(s.handle) }
        return try s.next() ? Self.topic(s) : nil
    }
    func synchronizeArchives(_ archived: Set<String>, provider: AITopicProvider) throws {
        try transaction {
            let rows = try statement("SELECT id,session,archived FROM topics WHERE provider=?")
            rows.bind([provider.rawValue])
            var changes: [(String, Bool)] = []
            while try rows.next() {
                let value = archived.contains(rows.text(1))
                if value != (rows.int(2) != 0) { changes.append((rows.text(0), value)) }
            }
            for (id, value) in changes {
                let update = try statement("UPDATE topics SET archived=? WHERE id=?")
                update.bind([value ? "1" : "0", id]); _ = try update.next()
            }
        }
    }
    func synchronizeScope(_ identity: String, provider: AITopicProvider) throws {
        try transaction {
            let scope = try statement("SELECT identity FROM topic_scopes WHERE provider=?")
            scope.bind([provider.rawValue])
            if try scope.next(), scope.text(0) == identity { return }
            try reconcile(provider: provider, topics: [], files: [])
            let update = try statement("INSERT INTO topic_scopes VALUES(?,?) ON CONFLICT(provider) DO UPDATE SET identity=excluded.identity")
            update.bind([provider.rawValue, identity]); _ = try update.next()
        }
    }
    func scope(_ provider: AITopicProvider) throws -> String? {
        let scope = try statement("SELECT identity FROM topic_scopes WHERE provider=?")
        scope.bind([provider.rawValue]); defer { sqlite3_reset(scope.handle) }
        return try scope.next() ? scope.text(0) : nil
    }
    func removeTopic(_ id: String) throws {
        try transaction {
            let lookup = try statement("SELECT pk FROM topics WHERE id=?"); lookup.bind([id])
            guard try lookup.next() else { return }
            let pk = lookup.int(0)
            let remove = try statement("DELETE FROM topics WHERE id=?"); remove.bind([id]); _ = try remove.next()
            dirty.remove(pk); topicKeys.removeValue(forKey: id)
        }
    }
    private static func topic(_ s: AITopicStatement) -> AITopic {
        AITopic(id: s.text(0), provider: AITopicProvider(rawValue: s.text(1))!, title: s.text(2), project: s.text(3), modified: s.double(4), desktopID: s.text(5), transcript: s.text(6), archived: s.int(7) != 0, excerpt: s.text(8))
    }
    func cursor(_ path: String) throws -> (identity: String, offset: Int64)? {
        let s = try statement("SELECT identity,offset FROM topic_cursors WHERE path=?"); s.bind([path])
        defer { sqlite3_reset(s.handle) }
        return try s.next() ? (s.text(0), s.int(1)) : nil
    }
    func cursor(_ path: String, identity: String, offset: Int64, topic: String, kind: String) throws {
        let s = try statement("INSERT INTO topic_cursors VALUES(?,?,?,?,?) ON CONFLICT(path) DO UPDATE SET identity=excluded.identity,offset=excluded.offset,topic=excluded.topic,kind=excluded.kind")
        s.bind([path, identity, String(offset), String(try key(topic)), kind]); _ = try s.next()
    }
    func removeMessages(_ topic: String, prefix: String) throws {
        try transaction {
            let pk = try key(topic)
            let s = try statement("DELETE FROM messages WHERE topic=? AND key GLOB ?"); s.bind([String(pk), prefix + "*"]); _ = try s.next()
            if sqlite3_changes(sql.db) > 0 { dirty.insert(pk) }
        }
    }
    func reconcileMessages(_ topic: String, prefix: String, liveKeys: Set<String>) throws -> Bool {
        var removed = false
        try transaction {
            let pk = try key(topic)
            let rows = try statement("SELECT rowid,key FROM messages WHERE topic=? AND substr(key,1,?)=?")
            rows.bind([String(pk), String(prefix.count), prefix])
            var stale: [Int64] = []
            while try rows.next() { if !liveKeys.contains(rows.text(1)) { stale.append(rows.int(0)) } }
            for row in stale {
                let s = try statement("DELETE FROM messages WHERE rowid=?"); sqlite3_bind_int64(s.handle, 1, row); _ = try s.next()
            }
            if !stale.isEmpty { dirty.insert(pk); removed = true }
        }
        return removed
    }
    func reconcile(provider: AITopicProvider, topics: Set<String>, files: Set<String>) throws {
        try transaction {
            try sql.run("CREATE TEMP TABLE IF NOT EXISTS seen_topics(id TEXT PRIMARY KEY); DELETE FROM seen_topics; CREATE TEMP TABLE IF NOT EXISTS seen_files(path TEXT PRIMARY KEY); DELETE FROM seen_files")
            for id in topics { let s = try statement("INSERT INTO seen_topics VALUES(?)"); s.bind([id]); _ = try s.next() }
            for path in files { let s = try statement("INSERT INTO seen_files VALUES(?)"); s.bind([path]); _ = try s.next() }
            let stale = try statement("SELECT c.path,t.id FROM topic_cursors c JOIN topics t ON t.pk=c.topic WHERE t.provider=? AND c.kind='file' AND c.path NOT IN (SELECT path FROM seen_files)"); stale.bind([provider.rawValue])
            var removedFiles: [(String,String)] = []; while try stale.next() { removedFiles.append((stale.text(0), stale.text(1))) }
            for (path, topic) in removedFiles {
                let owner = try statement("SELECT 1 FROM topic_cursors WHERE topic=? AND kind='file' AND path IN (SELECT path FROM seen_files) LIMIT 1")
                sqlite3_bind_int64(owner.handle, 1, try key(topic))
                if try !owner.next() { try removeMessages(topic, prefix: "file:") }
                let s = try statement("DELETE FROM topic_cursors WHERE path=?"); s.bind([path]); _ = try s.next()
            }
            let remove = try statement("DELETE FROM topics WHERE provider=? AND id NOT IN (SELECT id FROM seen_topics)"); remove.bind([provider.rawValue]); _ = try remove.next()
            if sqlite3_changes(sql.db) > 0 { topicKeys.removeAll() }
            dirty = Set(try dirty.filter { pk in
                let s = try statement("SELECT 1 FROM topics WHERE pk=?"); s.bind([String(pk)]); return try s.next()
            })
        }
    }
    private func unlink(_ entry: CachedTopicDocument) {
        if let previous = entry.previous { previous.next = entry.next } else { cacheHead = entry.next }
        if let next = entry.next { next.previous = entry.previous } else { cacheTail = entry.previous }
        entry.previous = nil; entry.next = nil
    }
    private func touch(_ entry: CachedTopicDocument) {
        if cacheTail === entry { return }
        unlink(entry); entry.previous = cacheTail; cacheTail?.next = entry
        cacheTail = entry; if cacheHead == nil { cacheHead = entry }
    }
    private func pruneDocuments() throws {
        guard !documents.isEmpty else { return }
        let query = incremental ? "SELECT topic,base_revision FROM topic_docs UNION ALL SELECT -id,0 FROM topic_chunks" : "SELECT topic,revision FROM topic_docs"
        let rows = try statement(query)
        var live: [Int64: Int64] = [:]
        while try rows.next() { live[rows.int(0)] = rows.int(1) }
        for entry in Array(documents.values) where live[entry.key] != entry.revision {
            unlink(entry); documents.removeValue(forKey: entry.key); cacheBytes -= entry.cost
        }
    }
    private func document(_ key: Int64, revision: Int64) throws -> CachedTopicDocument {
        if let entry = documents[key] {
            if entry.revision == revision { cacheHits += 1; touch(entry); return entry }
            unlink(entry); documents.removeValue(forKey: key); cacheBytes -= entry.cost
        }
        let s = try statement(key < 0 ? "SELECT folded,bytes,boundaries FROM topic_chunks WHERE id=?" : "SELECT folded,bytes,boundaries FROM topic_docs WHERE topic=?")
        sqlite3_bind_int64(s.handle, 1, key < 0 ? -key : key)
        defer { sqlite3_reset(s.handle) }
        guard try s.next() else { throw AITopicError.database("Missing topic document") }
        let bytes = try buffer.decode(sqlite3_column_blob(s.handle, 0), count: Int(sqlite3_column_bytes(s.handle, 0)), length: Int(s.int(1)))
        lastSearchStats.decodedBytes += bytes.count
        let text = bytes.isEmpty ? Data() : Data(bytes: bytes.baseAddress!, count: bytes.count)
        let boundaryBytes = Int(sqlite3_column_bytes(s.handle, 2))
        let boundaries = boundaryBytes == 0 ? Data() : Data(bytes: sqlite3_column_blob(s.handle, 2)!, count: boundaryBytes)
        let entry = CachedTopicDocument(key: key, revision: revision, text: text, boundaries: boundaries)
        // A full scan must not evict the next documents that the same scan will need.
        // Keep admitted documents stable; revisions release stale entries on lookup.
        if entry.cost <= documentCacheBudget - cacheBytes {
            entry.previous = cacheTail; cacheTail?.next = entry; cacheTail = entry
            if cacheHead == nil { cacheHead = entry }; documents[key] = entry; cacheBytes += entry.cost
        }
        return entry
    }
    private static func excerpt(_ bytes: UnsafeBufferPointer<UInt8>, offset: Int, term: String) -> String {
        var lower = max(0, min(offset, bytes.count) - 192)
        var upper = min(bytes.count, min(offset, bytes.count) + max(1024, term.utf8.count + 256))
        while lower > 0 && bytes[lower] & 0xc0 == 0x80 { lower -= 1 }
        while upper < bytes.count && bytes[upper] & 0xc0 == 0x80 { upper += 1 }
        var body = String(decoding: bytes[lower..<upper], as: UTF8.self)
        var found = body.range(of: term, options: .caseInsensitive)
        if found == nil { body = String(decoding: bytes, as: UTF8.self); found = body.range(of: term, options: .caseInsensitive) }
        let match = found?.lowerBound ?? body.startIndex
        let start = body.index(match, offsetBy: -45, limitedBy: body.startIndex) ?? body.startIndex
        return String(body[start...].prefix(220))
    }
    private static func find(_ bytes: UnsafeBufferPointer<UInt8>, _ needle: [UInt8], start: Int = 0) -> Int? {
        guard !needle.isEmpty, start <= bytes.count, bytes.count - start >= needle.count else { return nil }
        return needle.withUnsafeBufferPointer { needle in
            guard let match = memmem(bytes.baseAddress! + start, bytes.count - start, needle.baseAddress!, needle.count) else { return nil }
            return UnsafeRawPointer(bytes.baseAddress!).distance(to: match)
        }
    }
    public func count(providers: Set<AITopicProvider>? = nil) throws -> Int {
        let values = (providers ?? Set(AITopicProvider.allCases)).sorted { $0.rawValue < $1.rawValue }
        if values.isEmpty { return 0 }
        let filter = " AND provider IN (" + Array(repeating: "?", count: values.count).joined(separator: ",") + ")"
        let statement = try sql.prepare("SELECT count(*) FROM topics WHERE archived=0" + filter)
        statement.bind(values.map(\.rawValue))
        guard try statement.next() else { return 0 }
        return Int(statement.int(0))
    }

    private func literalMatch(_ topic: Int64, revision: Int64, baseBytes: Int, meta: Int64?, edited: Bool, needles: [[UInt8]], isCancelled: () -> Bool) throws -> (matched: Bool, excerpt: (row: Int64, offset: Int)?) {
        var matches = Array(repeating: false, count: needles.count)
        var excerpt: (row: Int64, offset: Int)?
        func select(_ row: Int64, _ offset: Int) {
            if excerpt == nil || (excerpt!.row == meta && row != meta) || (row != meta && excerpt!.row != meta && row < excerpt!.row) {
                excerpt = (row, offset)
            }
        }
        // Whole live chunks need only one literal byte scan per outstanding term. Message
        // boundaries are binary-searched for the excerpt, rather than visited for every match.
        // Whitespace-separated query terms cannot cross the newline between two messages.
        func scanContiguous(_ document: CachedTopicDocument, firstRow: Int64) {
            document.text.withUnsafeBytes { text in
                let bytes = text.bindMemory(to: UInt8.self)
                let needsExcerpt = excerpt == nil || excerpt!.row == meta || firstRow < excerpt!.row
                var first: Int?
                for (index, needle) in needles.enumerated() where !matches[index] || (index == 0 && needsExcerpt) {
                    if let offset = Self.find(bytes, needle) { matches[index] = true; if index == 0 { first = offset } }
                }
                guard let first else { return }
                document.boundaries.withUnsafeBytes { ptr in
                    let count = ptr.count / 16
                    func end(_ index: Int) -> Int { Int(ptr.loadUnaligned(fromByteOffset: index * 16, as: UInt64.self).littleEndian) }
                    func boundary(_ offset: Int) -> Int {
                        var lower = 0, upper = count
                        while lower < upper { let middle = (lower + upper) / 2; if end(middle) <= offset { lower = middle + 1 } else { upper = middle } }
                        return lower
                    }
                    var offset = first, index = boundary(first)
                    if index < count {
                        let row = Int64(bitPattern: ptr.loadUnaligned(fromByteOffset: index * 16 + 8, as: UInt64.self).littleEndian)
                        if row == meta, let bodyOffset = Self.find(bytes, needles[0], start: end(index)) { offset = bodyOffset; index = boundary(bodyOffset) }
                    }
                    if index < count {
                        let row = Int64(bitPattern: ptr.loadUnaligned(fromByteOffset: index * 16 + 8, as: UInt64.self).littleEndian)
                        select(row, offset - (index > 0 ? end(index - 1) : 0))
                    }
                }
            }
        }
        func scanSparse(_ document: CachedTopicDocument, live: (Int64) -> Bool) {
            document.text.withUnsafeBytes { text in
                let bytes = text.bindMemory(to: UInt8.self)
                document.boundaries.withUnsafeBytes { boundaries in
                    var start = 0
                    for index in 0..<(boundaries.count / 16) {
                        let end = Int(boundaries.loadUnaligned(fromByteOffset: index * 16, as: UInt64.self).littleEndian)
                        let row = Int64(bitPattern: boundaries.loadUnaligned(fromByteOffset: index * 16 + 8, as: UInt64.self).littleEndian)
                        defer { start = end }
                        guard live(row), end > start, end <= bytes.count else { continue }
                        lastVerifiedMessageRanges += 1
                        let body = UnsafeBufferPointer(rebasing: bytes[start..<end])
                        for (index, needle) in needles.enumerated() where index == 0 || !matches[index] {
                            if let offset = Self.find(body, needle) { matches[index] = true; if index == 0 { select(row, offset) } }
                        }
                    }
                }
            }
        }
        if baseBytes > 0 {
            let base = try document(topic, revision: revision)
            var overrides = Set<Int64>()
            if edited {
                let rows = try statement("SELECT row FROM topic_overrides WHERE topic=?"); sqlite3_bind_int64(rows.handle, 1, topic)
                while try rows.next() { if isCancelled() { return (false, nil) }; overrides.insert(rows.int(0)) }
            }
            if overrides.isEmpty { scanContiguous(base, firstRow: 0) }
            else { scanSparse(base) { !overrides.contains($0) } }
        }
        if edited {
            let query = chunkSummaries
                ? "SELECT id,fully_live,first_row FROM topic_chunks WHERE topic=? ORDER BY first_row,id"
                : "SELECT c.id,(SELECT count(*) FROM topic_chunk_rows WHERE chunk=c.id)=length(c.boundaries)/16,coalesce((SELECT min(message) FROM topic_chunk_rows WHERE chunk=c.id),0) AS first_row FROM topic_chunks c WHERE c.topic=? ORDER BY first_row,c.id"
            let rows = try statement(query); sqlite3_bind_int64(rows.handle, 1, topic)
            while try rows.next() {
                if isCancelled() { return (false, nil) }
                let chunk = rows.int(0), first = rows.int(2)
                if matches.allSatisfy({ $0 }), let excerpt, excerpt.row != meta, first >= excerpt.row { continue }
                let document = try document(-chunk, revision: 0)
                if rows.int(1) != 0 { scanContiguous(document, firstRow: first) }
                else {
                    let owners = try statement("SELECT message FROM topic_chunk_rows WHERE chunk=?"); sqlite3_bind_int64(owners.handle, 1, chunk)
                    var live = Set<Int64>(); while try owners.next() { live.insert(owners.int(0)) }
                    scanSparse(document) { live.contains($0) }
                }
            }
        }
        return (matches.allSatisfy { $0 }, excerpt)
    }

    public func search(_ query: String, provider: AITopicProvider? = nil, providers: Set<AITopicProvider>? = nil, limit requestedLimit: Int = 100, isCancelled: @escaping () -> Bool = { false }) throws -> AITopicSearchResult {
        let began = CFAbsoluteTimeGetCurrent(), limit = max(1, requestedLimit)
        lastSearchStats = (0, 0); cacheHits = 0; resultCacheHits = 0; lastVerifiedMessageRanges = 0
        func result(_ topics: [AITopic], _ more: Bool = false) -> AITopicSearchResult { .init(topics: topics, hasMore: more, elapsedMs: (CFAbsoluteTimeGetCurrent() - began) * 1000) }
        if isCancelled() || providers?.isEmpty == true { return result([]) }
        let terms = Array(Set(Self.fold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init))).sorted()
        let needles = terms.map { Array($0.utf8) }
        let versionStatement = try statement("PRAGMA data_version")
        _ = try versionStatement.next(); let version = versionStatement.int(0); sqlite3_reset(versionStatement.handle)
        let changes = sqlite3_total_changes64(sql.db)
        if !incremental { incremental = try sql.tables().contains("topic_chunks") }
        if incremental && !chunkSummaries { chunkSummaries = try sql.columns("topic_chunks").contains("fully_live") }
        if cacheEpoch?.version != version || cacheEpoch?.changes != changes {
            try pruneDocuments(); cacheEpoch = (version, changes)
        }
        let cacheKey = TopicSearchCacheKey(terms: terms, provider: provider?.rawValue, providers: providers.map { $0.map(\.rawValue).sorted() }, limit: limit)
        if let cached = cachedSearches.first, cached.version != version || cached.changes != changes {
            cachedSearches.removeAll(keepingCapacity: true); searchCacheBytes = 0
        }
        if let index = cachedSearches.firstIndex(where: { $0.key == cacheKey }) {
            if isCancelled() { return result([]) }
            let cached = cachedSearches.remove(at: index); cachedSearches.append(cached)
            resultCacheHits = 1; return result(cached.topics, cached.more)
        }
        func completed(_ topics: [AITopic], _ more: Bool = false) -> AITopicSearchResult {
            if isCancelled() { return result([]) }
            let budget = resultCacheBudget
            var cost = 256
            for topic in topics {
                cost += topic.id.utf8.count + topic.title.utf8.count + topic.project.utf8.count + topic.desktopID.utf8.count + topic.transcript.utf8.count + topic.excerpt.utf8.count + 256
                if cost > budget { break }
            }
            if !inTransaction && cost <= budget && !isCancelled() {
                while searchCacheBytes + cost > budget || cachedSearches.count >= 8 {
                    guard !cachedSearches.isEmpty else { break }
                    searchCacheBytes -= cachedSearches.removeFirst().cost
                }
                cachedSearches.append(.init(key: cacheKey, version: version, changes: changes, topics: topics, more: more, cost: cost))
                searchCacheBytes += cost
            }
            return result(topics, more)
        }
        let knownProviders = AITopicProvider.allCases.sorted { $0.rawValue < $1.rawValue }
        var bindings: [String] = knownProviders.map(\.rawValue)
        var conditions: [String] = ["t.archived=0", "t.provider IN (" + Array(repeating: "?", count: knownProviders.count).joined(separator: ",") + ")"]
        if !terms.isEmpty {
            if incremental {
                // Terms may occur in different chunks. Intersect topic identities per term,
                // then verify literals against only the live message ranges below.
                for term in terms {
                    let grams = Self.grams(term, query: true)
                    conditions.append("t.pk IN (SELECT rowid FROM topic_fts WHERE topic_fts MATCH ? UNION SELECT c.topic FROM topic_chunk_fts JOIN topic_chunks c ON c.id=topic_chunk_fts.rowid WHERE topic_chunk_fts MATCH ?)")
                    bindings.append(contentsOf: [grams, grams])
                }
            } else {
                conditions.append("t.pk IN (SELECT rowid FROM topic_fts WHERE topic_fts MATCH ?)")
                bindings.append(Set(terms.flatMap { Self.grams($0, query: true).components(separatedBy: " AND ") }).sorted().joined(separator: " AND "))
            }
        }
        if let provider { conditions.append("t.provider=?"); bindings.append(provider.rawValue) }
        if let providers {
            let values = providers.sorted { $0.rawValue < $1.rawValue }
            conditions.append("t.provider IN (" + Array(repeating: "?", count: values.count).joined(separator: ",") + ")")
            bindings.append(contentsOf: values.map(\.rawValue))
        }
        let selection = " WHERE " + conditions.joined(separator: " AND ")
        let cancellation = TopicCancellation(isCancelled)
        sqlite3_progress_handler(sql.db, 1000, { context in
            guard let context else { return 0 }
            return Unmanaged<TopicCancellation>.fromOpaque(context).takeUnretainedValue().cancelled() ? 1 : 0
        }, Unmanaged.passUnretained(cancellation).toOpaque())
        defer { statements.values.forEach { sqlite3_reset($0.handle) }; sqlite3_progress_handler(sql.db, 0, nil, nil); withExtendedLifetime(cancellation) {} }
        do {
            let state = incremental ? "d.base_revision,EXISTS(SELECT 1 FROM topic_chunks c WHERE c.topic=t.pk) OR EXISTS(SELECT 1 FROM topic_overrides o WHERE o.topic=t.pk)" : "d.revision,0"
            let s = try sql.prepare("SELECT t.session,t.provider,t.title,t.project,t.modified,t.desktop,t.transcript,t.archived,t.excerpt,t.pk," + state + ",d.bytes,(SELECT rowid FROM messages WHERE topic=t.pk AND key='meta') FROM topics t JOIN topic_docs d ON d.topic=t.pk" + selection + " ORDER BY t.modified DESC,t.id")
            s.bind(bindings); var topics: [AITopic] = []
            while try s.next() {
                if isCancelled() { return result([]) }; lastSearchStats.candidates += 1
                var excerpt: (row: Int64, offset: Int)?
                if !needles.isEmpty {
                    let match = try literalMatch(s.int(9), revision: s.int(10), baseBytes: Int(s.int(12)), meta: s.int(13) == 0 ? nil : s.int(13), edited: s.int(11) != 0, needles: needles, isCancelled: isCancelled)
                    if !match.matched { continue }; excerpt = match.excerpt
                }
                if topics.count == limit { return completed(topics, true) }
                var topic = Self.topic(s)
                if let excerpt, let term = terms.first {
                    let detail = try statement("SELECT body,bytes FROM messages WHERE rowid=?"); sqlite3_bind_int64(detail.handle, 1, excerpt.row)
                    if try detail.next() {
                        let bytes = try buffer.decode(sqlite3_column_blob(detail.handle, 0), count: Int(sqlite3_column_bytes(detail.handle, 0)), length: Int(detail.int(1)))
                        topic.excerpt = Self.excerpt(bytes, offset: excerpt.offset, term: term)
                    }
                }
                topics.append(topic)
            }
            if isCancelled() { return result([]) }
            return completed(topics)
        } catch { if isCancelled() { return result([]) }; throw error }
    }
}
