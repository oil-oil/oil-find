import AppKit
import SQLite3
import XCTest
@testable import OilFindApp

final class AITopicPerformanceRegressionTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oilfind-topic-performance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func scalar(_ index: AITopicIndex, _ query: String) throws -> Int64 {
        let s = try index.sql.prepare(query); XCTAssertTrue(try s.next()); return s.int(0)
    }
    private func blob(_ value: Data, _ column: Int32, _ statement: AITopicStatement) {
        _ = value.withUnsafeBytes { sqlite3_bind_blob(statement.handle, column, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    /// An actual pre-chunk index, not a new index with a compatibility flag changed.
    private func legacy(_ url: URL, body: String) throws {
        let sql = try AITopicSQL(url)
        try sql.run("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE topics(pk INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,session TEXT NOT NULL,provider TEXT NOT NULL,title TEXT NOT NULL,project TEXT NOT NULL,modified REAL NOT NULL,desktop TEXT NOT NULL,transcript TEXT NOT NULL,archived INTEGER NOT NULL,excerpt TEXT NOT NULL);
            CREATE TABLE messages(rowid INTEGER PRIMARY KEY,topic INTEGER NOT NULL REFERENCES topics(pk) ON DELETE CASCADE,key TEXT NOT NULL,body BLOB NOT NULL,bytes INTEGER NOT NULL,UNIQUE(topic,key));
            CREATE TABLE topic_docs(topic INTEGER PRIMARY KEY REFERENCES topics(pk) ON DELETE CASCADE,folded BLOB NOT NULL,bytes INTEGER NOT NULL,boundaries BLOB NOT NULL,revision INTEGER NOT NULL DEFAULT 1);
            CREATE VIRTUAL TABLE topic_fts USING fts5(grams,content='',contentless_delete=1,detail=none);
            INSERT INTO topics VALUES(1,'codex:legacy','legacy','codex','Legacy title','',1,'','',0,'fallback');
            """)
        var text = Data(), boundaries = Data()
        for (i, message) in ["Legacy title\n", body].enumerated() {
            let original = Data(message.utf8), row = try sql.prepare("INSERT INTO messages VALUES(?,1,?,?,?)")
            row.bind([String(i + 1), i == 0 ? "meta" : "body"])
            blob(Data([0]) + original, 3, row); sqlite3_bind_int64(row.handle, 4, Int64(original.count)); _ = try row.next()
            text.append(contentsOf: AITopicIndex.fold(message).utf8); text.append(10)
            var end = UInt64(text.count).littleEndian, id = UInt64(i + 1).littleEndian
            withUnsafeBytes(of: &end) { boundaries.append(contentsOf: $0) }; withUnsafeBytes(of: &id) { boundaries.append(contentsOf: $0) }
        }
        let doc = try sql.prepare("INSERT INTO topic_docs VALUES(1,?,?,?,7)")
        blob(Data([0]) + text, 1, doc); sqlite3_bind_int64(doc.handle, 2, Int64(text.count)); blob(boundaries, 3, doc); _ = try doc.next()
        let fts = try sql.prepare("INSERT INTO topic_fts(rowid,grams) VALUES(1,?)")
        fts.bind([AITopicIndex.grams(String(decoding: text, as: UTF8.self))]); _ = try fts.next()
    }
    func testTinyAppendKeepsLegacyBaseAndExistingReaderFindsNewChunks() throws {
        let url = try directory().appendingPathComponent("index.sqlite")
        let original = String(repeating: "oldbody café 搜索 alpha beta ", count: 50_000)
        try legacy(url, body: original)
        let reader = try AITopicIndex(url: url, readOnly: true)
        XCTAssertEqual(try reader.search("oldbody", limit: .max).topics.map(\.key), ["codex:legacy"])
        let writer = try AITopicIndex(url: url)
        let baseBytes = try scalar(writer, "SELECT bytes FROM topic_docs WHERE topic=1")
        try writer.message("codex:legacy", key: "append", body: "tinynewneedle")
        XCTAssertEqual(writer.lastWriteStats.foldedBytes, "tinynewneedle".utf8.count + 1)
        XCTAssertEqual(writer.lastWriteStats.chunks, 1)
        XCTAssertEqual(try scalar(writer, "SELECT bytes FROM topic_docs WHERE topic=1"), baseBytes)
        XCTAssertEqual(try scalar(writer, "SELECT base_revision FROM topic_docs WHERE topic=1"), 7)
        XCTAssertEqual(try scalar(writer, "SELECT revision FROM topic_docs WHERE topic=1"), 8)
        XCTAssertEqual(try reader.search("oldbody tinynewneedle", limit: .max).topics.map(\.key), ["codex:legacy"])
        try writer.message("codex:legacy", key: "body", body: "replacementnew e\u{301}")
        XCTAssertTrue(try reader.search("oldbody").topics.isEmpty)
        XCTAssertEqual(try reader.search("replacementnew É tinynewneedle").topics.map(\.key), ["codex:legacy"])
        try writer.message("codex:legacy", key: "append", body: "")
        XCTAssertTrue(try reader.search("tinynewneedle").topics.isEmpty)
        XCTAssertEqual(try reader.search("replacementnew").topics.first?.excerpt, "replacementnew e\u{301}")
        try writer.removeTopic("codex:legacy")
        XCTAssertEqual(try scalar(writer, "SELECT count(*) FROM topic_chunks"), 0)
        XCTAssertEqual(try scalar(writer, "SELECT count(*) FROM topic_overrides"), 0)
        XCTAssertTrue(try reader.search("replacementnew").topics.isEmpty)
    }
    func testChunkOwnershipPreservesCrossChunkANDAndRemovesReplacedDeletedText() throws {
        let url = try directory().appendingPathComponent("index.sqlite"), index = try AITopicIndex(url: url)
        let topic = AITopic(id: "chunks", provider: .claude, title: "firstneedle title")
        try index.transaction {
            try index.upsert(topic)
            try index.message(topic.key, key: "a", body: "firstneedle originalbody " + String(repeating: "x", count: 40_000))
            try index.message(topic.key, key: "b", body: "secondneedle " + String(repeating: "y", count: 40_000))
            try index.message(topic.key, key: "c", body: "thirdneedle")
        }
        XCTAssertGreaterThan(index.lastWriteStats.chunks, 1)
        let reader = try AITopicIndex(url: url, readOnly: true)
        XCTAssertEqual(try reader.search("firstneedle secondneedle thirdneedle").topics.map(\.key), [topic.key])
        XCTAssertTrue(try reader.search("firstneedle").topics.first?.excerpt.hasPrefix("firstneedle originalbody") == true)
        XCTAssertEqual(reader.lastVerifiedMessageRanges, 0, "Fully live chunks must not scan each message boundary")
        try index.message(topic.key, key: "a", body: "replacementneedle")
        XCTAssertTrue(try reader.search("originalbody").topics.isEmpty)
        XCTAssertGreaterThan(reader.lastVerifiedMessageRanges, 0, "Only the partially replaced chunk needs active-message verification")
        XCTAssertEqual(try reader.search("replacementneedle secondneedle thirdneedle").topics.map(\.key), [topic.key])
        XCTAssertEqual(try reader.search("firstneedle").topics.first?.excerpt, "firstneedle title\n")
        _ = try index.reconcileMessages(topic.key, prefix: "", liveKeys: ["meta", "a", "c"])
        XCTAssertTrue(try reader.search("secondneedle").topics.isEmpty)
        XCTAssertEqual(try reader.search("replacementneedle thirdneedle").topics.map(\.key), [topic.key])
        try index.removeMessages(topic.key, prefix: "c")
        XCTAssertTrue(try reader.search("thirdneedle").topics.isEmpty)
    }
    func testRepeatedBroadSearchHasBoundedReuseAndExternalMutationInvalidatesIt() throws {
        let url = try directory().appendingPathComponent("index.sqlite"), writer = try AITopicIndex(url: url)
        try writer.transaction {
            for i in 0..<30 {
                let topic = AITopic(id: String(i), provider: i % 2 == 0 ? .claude : .codex, title: "row \(i)", modified: Double(i))
                try writer.upsert(topic)
                try writer.message(topic.key, key: "body", body: "a b " + String(repeating: "z", count: 20_000))
            }
        }
        let reader = try AITopicIndex(url: url, readOnly: true, cacheBudgetBytes: 96 * 1024)
        let first = try reader.search("a", limit: .max)
        XCTAssertEqual(first.topics.count, 30)
        let decoded = reader.lastSearchStats.decodedBytes
        _ = try reader.search("b", limit: .max)
        let repeated = try reader.search("a b", limit: .max)
        XCTAssertEqual(repeated.topics, first.topics)
        XCTAssertGreaterThan(reader.cacheHits, 0, "Sequential scans larger than the cache must retain reusable documents")
        XCTAssertLessThan(reader.lastSearchStats.decodedBytes, decoded)
        XCTAssertLessThanOrEqual(reader.documentCacheBytes, 96 * 1024)
        XCTAssertLessThanOrEqual(reader.documentCacheBytes + reader.searchCacheBytes, 96 * 1024)
        _ = try reader.search("a b", limit: .max)
        XCTAssertEqual(reader.resultCacheHits, 1)
        XCTAssertEqual(reader.lastSearchStats.decodedBytes, 0)
        XCTAssertTrue(try reader.search("a", limit: .max, isCancelled: { true }).topics.isEmpty)
        XCTAssertEqual(try reader.search("a", provider: .claude, limit: .max).topics.count, 15)
        XCTAssertEqual(try reader.search("a", limit: 1).topics.count, 1)
        _ = try reader.search("a", limit: .max)
        var topic = try XCTUnwrap(writer.topic("codex:29")); topic.archived = true; try writer.upsert(topic)
        XCTAssertEqual(try reader.search("a", limit: .max).topics.count, 29)
        XCTAssertEqual(reader.resultCacheHits, 0)
        try writer.message("claude:0", key: "body", body: "newunique")
        XCTAssertEqual(try reader.search("a", limit: .max).topics.count, 28)
        XCTAssertEqual(try reader.search("newunique").topics.map(\.key), ["claude:0"])
    }
    func testEarlierChunkFormatReadOnlyFallbackAndSummaryMigrationPreserveSparseRows() throws {
        let url = try directory().appendingPathComponent("index.sqlite"), initial = try AITopicIndex(url: url)
        let topic = AITopic(id: "old-chunks", provider: .claude, title: "metadata")
        try initial.transaction {
            try initial.upsert(topic)
            try initial.message(topic.key, key: "a", body: "removedneedle")
            try initial.message(topic.key, key: "b", body: "retainedneedle")
        }
        try initial.message(topic.key, key: "a", body: "replacementneedle")
        // Reproduce the earlier chunk schema, including its deletion trigger.
        try initial.sql.run("""
            DROP TRIGGER topic_chunk_row_delete;
            ALTER TABLE topic_chunks DROP COLUMN fully_live;
            ALTER TABLE topic_chunks DROP COLUMN first_row;
            CREATE TRIGGER topic_chunk_row_delete AFTER DELETE ON topic_chunk_rows BEGIN
                DELETE FROM topic_chunks WHERE id=old.chunk AND NOT EXISTS(SELECT 1 FROM topic_chunk_rows WHERE chunk=old.chunk);
            END;
            """)
        let reader = try AITopicIndex(url: url, readOnly: true)
        XCTAssertTrue(try reader.search("removedneedle").topics.isEmpty)
        XCTAssertEqual(try reader.search("replacementneedle retainedneedle").topics.map(\.key), [topic.key])
        let upgraded = try AITopicIndex(url: url)
        XCTAssertEqual(try scalar(upgraded, "SELECT count(*) FROM topic_chunks WHERE fully_live=0"), 1)
        XCTAssertEqual(try scalar(upgraded, "SELECT count(*) FROM topic_chunks WHERE first_row<=0"), 0)
        XCTAssertTrue(try reader.search("removedneedle").topics.isEmpty)
        XCTAssertEqual(try reader.search("replacementneedle retainedneedle").topics.map(\.key), [topic.key])
        try upgraded.message(topic.key, key: "b", body: "")
        XCTAssertTrue(try reader.search("retainedneedle").topics.isEmpty)
        XCTAssertEqual(try reader.search("replacementneedle").topics.map(\.key), [topic.key])
        try upgraded.message(topic.key, key: "after-upgrade", body: "postmigrationneedle")
        XCTAssertEqual(try scalar(upgraded, "SELECT fully_live FROM topic_chunks ORDER BY id DESC LIMIT 1"), 1)
        XCTAssertEqual(try reader.search("postmigrationneedle").topics.map(\.key), [topic.key])
    }
    func testContiguousAndSparseChunksMatchLiteralOracleAcrossUnrelatedCommits() throws {
        let url = try directory().appendingPathComponent("index.sqlite"), writer = try AITopicIndex(url: url)
        let topic = AITopic(id: "oracle", provider: .claude, title: "title café")
        var bodies = ["ALPHA É 👩‍💻", "beta 搜索", "abab x bab", "ab", "c", "İ العربية", "last tail"]
        try writer.transaction {
            try writer.upsert(topic)
            for (i, body) in bodies.enumerated() { try writer.message(topic.key, key: String(i), body: body) }
        }
        let reader = try AITopicIndex(url: url, readOnly: true)
        let queries = ["a", "的", "ai", "alpha beta", "É 搜索", "e\u{301}", "👩‍💻", "i\u{307}", "abab", "abc", "tail café", "العربية"]
        func verify() throws {
            for (i, query) in queries.enumerated() {
                // Invalidate complete-query reuse without changing the topic under test.
                try writer.upsert(.init(id: "unrelated", provider: .codex, title: "unrelated \(i)", modified: Double(i)))
                let terms = AITopicIndex.fold(query).split(whereSeparator: { $0.isWhitespace }).map { Data($0.utf8) }
                let documents = ([topic.title + "\n" + topic.project] + bodies).filter { !$0.isEmpty }.map { Data(AITopicIndex.fold($0).utf8) }
                let expected = terms.allSatisfy { needle in documents.contains { $0.range(of: needle) != nil } }
                XCTAssertEqual(try reader.search(query, provider: .claude, limit: .max).topics.map(\.key), expected ? [topic.key] : [], query)
                XCTAssertEqual(reader.resultCacheHits, 0)
            }
        }
        try verify()
        XCTAssertEqual(reader.lastVerifiedMessageRanges, 0)
        bodies[0] = "replacement Ωμέγα"; try writer.message(topic.key, key: "0", body: bodies[0])
        bodies[1] = ""; try writer.message(topic.key, key: "1", body: "")
        try verify()
    }
    func testCooperativeFlushCancellationRollsBackBodiesPostingsAndRevision() throws {
        let url = try directory().appendingPathComponent("index.sqlite"), index = try AITopicIndex(url: url)
        let topic = AITopic(id: "cancel", provider: .claude, title: "existing")
        try index.upsert(topic)
        let revision = try scalar(index, "SELECT revision FROM topic_docs")
        var checks = 0
        index.workCheckpoint = {
            checks += 1
            if checks == 12 { throw NSError(domain: "cancelled", code: 1) }
        }
        XCTAssertThrowsError(try index.message(topic.key, key: "body", body: String(repeating: "cancelledneedle ", count: 20_000)))
        XCTAssertGreaterThanOrEqual(checks, 12)
        index.workCheckpoint = nil
        XCTAssertEqual(try scalar(index, "SELECT revision FROM topic_docs"), revision)
        XCTAssertEqual(try scalar(index, "SELECT count(*) FROM messages WHERE key='body'"), 0)
        XCTAssertTrue(try index.search("cancelledneedle").topics.isEmpty)
        try index.message(topic.key, key: "body", body: "committedneedle")
        XCTAssertEqual(try index.search("committedneedle").topics.map(\.key), [topic.key])
    }
    func testUnchangedProviderCursorReadsReleaseStatementsBeforeCheckpointAndVacuum() throws {
        let url = try directory().appendingPathComponent("index.sqlite"), index = try AITopicIndex(url: url)
        let providers: [AITopicProvider] = [.claude, .codex, .workbuddy]
        for provider in providers {
            let topic = AITopic(id: "maintenance", provider: provider, title: provider.name)
            try index.transaction {
                try index.upsert(topic)
                try index.message(topic.key, key: "body", body: "maintenance needle")
                try index.cursor(provider.rawValue, identity: "unchanged", offset: 42, topic: topic.key, kind: "file")
            }
        }
        // An unchanged refresh reads a cursor and has no following write transaction to
        // incidentally reset that cached SELECT. Maintenance must work in that same job.
        for provider in providers {
            XCTAssertEqual(try index.cursor(provider.rawValue)?.offset, 42)
            XCTAssertEqual(try index.topic(provider.rawValue + ":maintenance")?.title, provider.name)
            var statement = sqlite3_next_stmt(index.sql.db, nil), busy = 0
            while let current = statement {
                if sqlite3_stmt_busy(current) != 0 { busy += 1 }
                statement = sqlite3_next_stmt(index.sql.db, current)
            }
            XCTAssertEqual(busy, 0, "A completed cursor lookup must release its SQLite read transaction")
            XCTAssertNoThrow(try index.sql.run("PRAGMA wal_checkpoint(PASSIVE)"))
            XCTAssertNoThrow(try index.checkpoint())
        }
        try index.finishInitialImport()
        XCTAssertEqual(try scalar(index, "PRAGMA user_version"), 1)
        for provider in providers {
            XCTAssertEqual(try index.cursor(provider.rawValue)?.identity, "unchanged")
            XCTAssertNoThrow(try index.sql.run("PRAGMA wal_checkpoint(PASSIVE)"))
            XCTAssertNoThrow(try index.checkpoint())
        }
        XCTAssertEqual(try index.search("maintenance needle", limit: .max).topics.count, 3)
    }
    func testAdditionalActionsArePreparedOnlyWhenRequested() {
        var prepared = 0
        let item = AdditionalSearchItem(id: "stable-key", title: "title", detail: "detail", location: "location", modified: Date(), icon: NSImage()) {
            prepared += 1
            return [AdditionalSearchAction(kind: .copy, title: "Copy") { completion in completion(true) }]
        }
        XCTAssertEqual(item.id, "stable-key"); XCTAssertEqual(item.detail, "detail"); XCTAssertEqual(prepared, 0)
        XCTAssertEqual(item.actions.map(\.title), ["Copy"]); XCTAssertEqual(prepared, 1)
    }
}
