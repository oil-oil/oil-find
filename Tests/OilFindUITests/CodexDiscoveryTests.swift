import Foundation
import XCTest
@testable import OilFindApp

final class CodexDiscoveryTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oilfind-codex-discovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func line(_ value: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(10)
        return data
    }

    private func rolloutHeader(_ id: String, project: String = "/demo", subagent: Bool = false) throws -> Data {
        var payload: [String: Any] = ["id": id, "cwd": project]
        if subagent { payload["source"] = ["subagent": true] }
        return try line(["type": "session_meta", "payload": payload])
    }

    private func userMessage(_ text: String) throws -> Data {
        try line(["type": "response_item", "payload": ["type": "message", "role": "user",
            "content": [["type": "input_text", "text": text]]]])
    }

    func testKnownHistoryRolloutIsSkippedBeforeOpeningItsHeader() throws {
        let root = try temporaryDirectory(), home = root.appendingPathComponent("home")
        let codex = home.appendingPathComponent(".codex"), sessions = codex.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased(), rollout = sessions.appendingPathComponent("rollout-" + id + ".jsonl")
        try (rolloutHeader(id) + userMessage("legacy rollout body must stay unused")).write(to: rollout)

        let state = try AITopicSQL(codex.appendingPathComponent("state_5.sqlite"))
        try state.run("CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,name TEXT,cwd TEXT,updated_at REAL,rollout_path TEXT,archived INTEGER,thread_source TEXT,source TEXT,first_user_message TEXT)")
        let thread = try state.prepare("INSERT INTO threads VALUES(?,?,?,?,?,?,?,?,?,?)")
        thread.bind([id, "metadata title", "", "/demo", "1", rollout.path, "0", "user", "user", ""])
        _ = try thread.next()

        let history = try AITopicSQL(codex.appendingPathComponent("thread_history_1.sqlite"))
        try history.run("CREATE TABLE thread_items(thread_id TEXT,item_id TEXT,item_type TEXT,item_json TEXT,rollout_ordinal INTEGER,updated_at_ordinal INTEGER,PRIMARY KEY(thread_id,item_id))")
        let historyObject = try JSONSerialization.data(withJSONObject: ["type": "agentMessage", "text": "canonical history body"])
        let item = try history.prepare("INSERT INTO thread_items VALUES(?,?,?,?,?,?)")
        item.bind([id, "message-1", "agentMessage", String(decoding: historyObject, as: UTF8.self), "1", "1"])
        _ = try item.next()

        let index = try AITopicIndex(url: root.appendingPathComponent("index.sqlite"))
        let importer = AITopicIndexer(index: index, locations: .init(home: home, codex: codex))
        try importer.refresh(providers: [.codex])

        XCTAssertEqual(try index.search("canonical history body").topics.count, 1)
        XCTAssertTrue(try index.search("legacy rollout body").topics.isEmpty)
        XCTAssertEqual(importer.lastCodexDiscoveryMetrics.canonicalHistoryPathsSkipped, 1)
        XCTAssertEqual(importer.lastCodexDiscoveryMetrics.headerBytesRead, 0)
        XCTAssertEqual(importer.lastCodexDiscoveryMetrics.headersParsed, 0)

        try importer.refresh(providers: [.codex])
        XCTAssertEqual(importer.lastCodexDiscoveryMetrics.canonicalHistoryPathsSkipped, 1)
        XCTAssertEqual(importer.lastCodexDiscoveryMetrics.headerBytesRead, 0)
        XCTAssertEqual(importer.lastCodexDiscoveryMetrics.headersParsed, 0)
    }

    func testLegacyDiscoveryReusesHeadersAndKeepsMoveRewriteAndDeleteBehavior() throws {
        let root = try temporaryDirectory(), home = root.appendingPathComponent("home")
        let codex = home.appendingPathComponent(".codex"), sessions = codex.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased(), subagentID = UUID().uuidString.lowercased()
        let file = sessions.appendingPathComponent("legacy.jsonl")
        let subagent = sessions.appendingPathComponent("delegated.jsonl")
        let initialText = "legacy body original unique marker " + String(repeating: "padding ", count: 6_000)
        try (rolloutHeader(id) + userMessage(initialText)).write(to: file)
        try (rolloutHeader(subagentID, subagent: true) + userMessage("subagent body must stay excluded")).write(to: subagent)

        let index = try AITopicIndex(url: root.appendingPathComponent("index.sqlite"))
        let importer = AITopicIndexer(index: index, locations: .init(home: home, codex: codex))
        try importer.refresh(providers: [.codex])
        XCTAssertEqual(try index.search("original unique marker").topics.map(\.id), [id])
        XCTAssertTrue(try index.search("subagent body").topics.isEmpty)
        XCTAssertEqual(importer.lastCodexDiscoveryMetrics.headersParsed, 2)
        XCTAssertLessThanOrEqual(importer.lastCodexDiscoveryMetrics.headerBytesRead, 2 * 4096)
        XCTAssertEqual(importer.lastCodexDiscoveryMetrics.codexHistorySortDateLookups, 2)

        try importer.refresh(providers: [.codex])
        XCTAssertEqual(importer.lastCodexDiscoveryMetrics.cachedHeadersReused, 2)
        XCTAssertEqual(importer.lastCodexDiscoveryMetrics.headerBytesRead, 0)
        XCTAssertEqual(importer.lastCodexDiscoveryMetrics.headersParsed, 0)
        XCTAssertEqual(importer.lastCodexDiscoveryMetrics.codexHistorySortDateLookups, 2)

        let replacement = "legacy body rewritten unique marker with the same session header " + String(repeating: "longer ", count: 7_000)
        try (rolloutHeader(id) + userMessage(replacement)).write(to: file)
        try importer.refresh(providers: [.codex])
        XCTAssertEqual(importer.lastCodexDiscoveryMetrics.headersParsed, 1)
        XCTAssertTrue(try index.search("original unique marker").topics.isEmpty)
        XCTAssertEqual(try index.search("rewritten unique marker").topics.map(\.id), [id])

        let archive = codex.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let archived = archive.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.moveItem(at: file, to: archived)
        try importer.refresh(providers: [.codex])
        XCTAssertTrue(try index.search("rewritten unique marker").topics.isEmpty)
        XCTAssertEqual(try index.topic("codex:" + id)?.archived, true)

        try FileManager.default.moveItem(at: archived, to: file)
        try importer.refresh(providers: [.codex])
        XCTAssertEqual(try index.search("rewritten unique marker").topics.map(\.id), [id])
        XCTAssertEqual(try index.topic("codex:" + id)?.archived, false)

        try FileManager.default.removeItem(at: subagent)
        try FileManager.default.removeItem(at: file)
        try importer.refresh(providers: [.codex])
        XCTAssertTrue(try index.search("rewritten unique marker").topics.isEmpty)
        XCTAssertNil(try index.topic("codex:" + id))
    }

    func testCodexMetadataReuseSkipsOnlyUnchangedAuthoritativeRows() throws {
        let root = try temporaryDirectory(), home = root.appendingPathComponent("home")
        let codex = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let stateURL = codex.appendingPathComponent("state_1.sqlite")
        let state = try AITopicSQL(stateURL)
        try state.run("PRAGMA journal_mode=WAL")
        try state.run("CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,name TEXT,cwd TEXT,updated_at REAL,rollout_path TEXT,archived INTEGER,thread_source TEXT,source TEXT,first_user_message TEXT)")
        let rowCount = 64
        for row in 0..<rowCount {
            let id = String(format: "thread-%04d", row)
            let title = row == rowCount - 1 ? "" : "Metadata title \(row)"
            let excerpt = row == rowCount - 2 ? "" : "Prompt excerpt \(row)"
            try state.run("INSERT INTO threads VALUES('\(id)','\(title)','','/demo',\(row + 1),'',0,'user','user','\(excerpt)')")
        }

        let index = try AITopicIndex(url: root.appendingPathComponent("index.sqlite"))
        let importer = AITopicIndexer(index: index, locations: .init(home: home, codex: codex))
        try importer.refreshMetadata(providers: [.codex])
        XCTAssertEqual(importer.lastCodexDiscoveryMetrics.codexMetadataRowsRead, rowCount)
        XCTAssertEqual(importer.lastCodexDiscoveryMetrics.codexMetadataRowsReused, 0)
        XCTAssertEqual(importer.lastCodexDiscoveryMetrics.codexMetadataRowsUpserted, rowCount)

        try importer.refreshMetadata(providers: [.codex])
        XCTAssertEqual(importer.lastCodexDiscoveryMetrics.codexMetadataRowsRead, rowCount)
        XCTAssertEqual(importer.lastCodexDiscoveryMetrics.codexMetadataRowsReused, rowCount - 2)
        XCTAssertEqual(importer.lastCodexDiscoveryMetrics.codexMetadataRowsUpserted, 2)

        // A live WAL update changes one authoritative row without requiring index work for its peers.
        try state.run("UPDATE threads SET title='Updated metadata title', first_user_message='Updated prompt excerpt', archived=1 WHERE id='thread-0000'")
        try importer.refreshMetadata(providers: [.codex])
        XCTAssertEqual(importer.lastCodexDiscoveryMetrics.codexMetadataRowsRead, rowCount)
        XCTAssertEqual(importer.lastCodexDiscoveryMetrics.codexMetadataRowsReused, rowCount - 3)
        XCTAssertEqual(importer.lastCodexDiscoveryMetrics.codexMetadataRowsUpserted, 3)
        let updated = try XCTUnwrap(index.topic("codex:thread-0000"))
        XCTAssertEqual(updated.title, "Updated metadata title")
        XCTAssertEqual(updated.excerpt, "Updated prompt excerpt")
        XCTAssertTrue(updated.archived)
    }
}
