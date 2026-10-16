import AppKit
import XCTest
import OilFindCore
@testable import OilFindApp

final class AITopicTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oilfind-topics-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func eventually(timeout: Double = 5, _ body: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !body() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return body()
    }
    func testLiteralSearchCompressionCacheAndCancellationAgainstOracle() throws { try runCoreChecks(directory()) }
    func testImporterReconcilesRenamesDeletionsAndRewrites() throws { try runSyncChecks(directory()) }
    func testDisabledProviderRefreshPreservesItsIndexUntilReenabled() throws {
        let root = try directory(), home = root.appendingPathComponent("home")
        let project = home.appendingPathComponent(".claude/projects/demo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased(), file = project.appendingPathComponent(id + ".jsonl")
        func line(_ text: String) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: ["type":"user", "cwd":"/demo", "message":["content":text]])
            data.append(10); return data
        }
        try line("cachedbeforebody").write(to: file)
        let index = try AITopicIndex(url: root.appendingPathComponent("index.sqlite"))
        let importer = AITopicIndexer(index: index, locations: .init(home: home))
        try importer.refresh()
        XCTAssertEqual(try index.search("cachedbeforebody").topics.count, 1)
        try line("refreshedafterbody").write(to: file)
        try importer.refresh(providers: [.codex])
        XCTAssertEqual(try index.search("cachedbeforebody").topics.count, 1)
        XCTAssertTrue(try index.search("refreshedafterbody").topics.isEmpty)
        try importer.refresh()
        XCTAssertTrue(try index.search("cachedbeforebody").topics.isEmpty)
        XCTAssertEqual(try index.search("refreshedafterbody").topics.count, 1)
    }
    func testArchivedTopicsAreExcludedBeforePaginationAndStaleActionsAreRejected() throws {
        let root = try directory(), url = root.appendingPathComponent("index.sqlite")
        let index = try AITopicIndex(url: url)
        var active: [AITopic] = []
        for provider in AITopicProvider.allCases {
            let topic = AITopic(id: "active", provider: provider, title: "shared title", modified: 1)
            active.append(topic)
            try index.upsert(topic); try index.message(topic.key, key: "body", body: "sharedbody")
            for i in 0..<3 {
                let archived = AITopic(id: "archived-\(i)", provider: provider, title: "shared title", modified: Double(10 + i), archived: true)
                try index.upsert(archived); try index.message(archived.key, key: "body", body: "sharedbody")
            }
        }
        let reader = try AITopicIndex(url: url, readOnly: true)
        for query in ["", "shared title", "sharedbody"] {
            let combined = try reader.search(query, limit: 1)
            XCTAssertEqual(combined.topics.count, 1); XCTAssertTrue(combined.hasMore)
            XCTAssertEqual(try reader.search(query, providers: []).topics.count, 0)
            for topic in active {
                let found = try reader.search(query, provider: topic.provider, limit: 1)
                XCTAssertEqual(found.topics.map(\.key), [topic.key]); XCTAssertFalse(found.hasMore)
            }
        }
        XCTAssertEqual(try reader.count(providers: [.claude]), 1)
        XCTAssertEqual(try reader.count(providers: []), 0)
        let manager = AITopicManager(url: url, locations: .init(home: root), detectProviders: { Set(AITopicProvider.allCases) })
        manager.installSnapshot(url: url); defer { manager.stop() }
        for var topic in active {
            var resolved = false, current: AITopic?
            manager.resolve(topic.key) { current = $0; resolved = true }
            XCTAssertTrue(eventually { resolved }); XCTAssertEqual(current?.key, topic.key)
            topic.archived = true; try index.upsert(topic)
            XCTAssertTrue(try reader.search("sharedbody", provider: topic.provider).topics.isEmpty)
            resolved = false
            manager.resolve(topic.key) { current = $0; resolved = true }
            XCTAssertTrue(eventually { resolved }); XCTAssertNil(current)
            topic.archived = false; try index.upsert(topic)
            XCTAssertEqual(try reader.search("sharedbody", provider: topic.provider).topics.map(\.key), [topic.key])
        }
    }
    func testWatchImportsNewSessionAppendRenameAndDeletionWithoutManualRefresh() throws {
        if ProcessInfo.processInfo.environment["CI"] != nil { throw XCTSkip("FSEvents delivery is verified locally") }
        let root = try directory(), home = root.appendingPathComponent("home")
        let project = home.appendingPathComponent(".claude/projects/test")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let suite = "oilfind-topics-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = AITopicManager(defaults: defaults, url: root.appendingPathComponent("index/index.sqlite"), locations: .init(home: home), detectProviders: { Set(AITopicProvider.allCases) })
        manager.start(); defer { manager.onChange = nil; manager.stop() }
        XCTAssertTrue(eventually { !manager.indexing && manager.count == 0 && FileManager.default.fileExists(atPath: manager.url.path) })
        let id = UUID().uuidString, file = project.appendingPathComponent(id + ".jsonl")
        func line(_ text: String) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: ["type":"user", "cwd":"/project", "message":["content":text]])
            data.append(10); return data
        }
        let began = Date(); try line("watchnewsession").write(to: file)
        var found: AITopicSearchResult?
        manager.onChange = { manager.search("watchnewsession", provider: nil) { if case .success(let value) = $0 { found = value } } }
        XCTAssertTrue(eventually { found?.topics.count == 1 })
        print("Topic watcher new-session latency: \(Date().timeIntervalSince(began) * 1000) ms")
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: line("watchappendedbody")); try handle.close()
        found = nil
        manager.onChange = { manager.search("watchappendedbody", provider: nil) { if case .success(let value) = $0 { found = value } } }
        XCTAssertTrue(eventually { found?.topics.count == 1 })
        let rename = try JSONSerialization.data(withJSONObject: ["customTitle":"watchrenamedtitle", "type":"custom-title"])
        let append = try FileHandle(forWritingTo: file); try append.seekToEnd(); try append.write(contentsOf: rename + Data([10])); try append.close()
        found = nil
        manager.onChange = { manager.search("watchrenamedtitle", provider: nil) { if case .success(let value) = $0 { found = value } } }
        XCTAssertTrue(eventually { found?.topics.first?.title == "watchrenamedtitle" })
        try FileManager.default.removeItem(at: file); found = nil
        manager.onChange = { manager.search("watchrenamedtitle", provider: nil) { if case .success(let value) = $0 { found = value } } }
        XCTAssertTrue(eventually { found?.topics.isEmpty == true && manager.count == 0 }, "count=\(manager.count) found=\(String(describing: found?.topics.map(\.title))) failed=\(manager.failed) indexing=\(manager.indexing)")
        manager.setEnabled(false)
        XCTAssertTrue(eventually { !manager.isEnabled })
    }
    func testWatchRemovesArchivedTopicsAndRestoresUnarchivedTopicsWithoutManualRefresh() throws {
        if ProcessInfo.processInfo.environment["CI"] != nil { throw XCTSkip("FSEvents delivery is verified locally") }
        let root = try directory(), home = root.appendingPathComponent("home")
        let locations = AITopicLocations(home: home)
        let descriptors = locations.claudeDesktop.appendingPathComponent("account")
        try FileManager.default.createDirectory(at: descriptors, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: locations.codex, withIntermediateDirectories: true)
        let claudeID = UUID().uuidString.lowercased(), codexID = UUID().uuidString.lowercased()
        let descriptor = descriptors.appendingPathComponent("session.json")
        func writeClaude(archived: Bool) throws {
            try JSONSerialization.data(withJSONObject: ["sessionId":"local_" + claudeID, "cliSessionId":claudeID,
                "title":"archivewatchclaude", "lastActivityAt":1, "isArchived":archived]).write(to: descriptor, options: .atomic)
        }
        try writeClaude(archived: false)
        let state = try AITopicSQL(locations.codex.appendingPathComponent("state_5.sqlite"))
        try state.run("PRAGMA journal_mode=WAL; CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,updated_at INTEGER,archived INTEGER)")
        let insert = try state.prepare("INSERT INTO threads VALUES(?,?,1,0)")
        insert.bind([codexID,"archivewatchcodex"]); _ = try insert.next()
        let suite = "oilfind-archive-watch-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = AITopicManager(defaults: defaults, url: root.appendingPathComponent("index/index.sqlite"), locations: locations, detectProviders: { Set(AITopicProvider.allCases) })
        let provider = AITopicSearchProvider(manager: manager)
        manager.start(); defer { manager.stop() }
        var displayed: [AdditionalSearchItem] = []
        provider.onChange = { displayed = (try? provider.prepareSearch(.parse("archivewatch"), isCancelled: { false })()) ?? [] }
        XCTAssertTrue(eventually { displayed.count == 2 && manager.count == 2 })
        let oldActions = displayed.compactMap { $0.actions.first { $0.kind == .copyName } }
        // Only the archive flag changes; modification timestamps remain identical.
        try writeClaude(archived: true)
        try state.run("UPDATE threads SET archived=1")
        XCTAssertTrue(eventually { displayed.isEmpty && manager.count == 0 })
        XCTAssertTrue(try manager.readSearch("", isCancelled: { false }).topics.isEmpty)
        for action in oldActions {
            var completed = false, accepted = true
            action.perform { accepted = $0; completed = true }
            XCTAssertTrue(eventually { completed }); XCTAssertFalse(accepted)
        }
        try writeClaude(archived: false)
        try state.run("UPDATE threads SET archived=0")
        XCTAssertTrue(eventually { displayed.count == 2 && manager.count == 2 })
    }
    func testNewerQuerySuppressesStaleResponseAndDisableSuppressesPendingActions() throws {
        let root = try directory(), url = root.appendingPathComponent("index.sqlite")
        let index = try AITopicIndex(url: url)
        try index.upsert(.init(id: UUID().uuidString, provider: .codex, title: "first"))
        try index.upsert(.init(id: UUID().uuidString, provider: .claude, title: "second"))
        let manager = AITopicManager(url: url, locations: .init(home: root), detectProviders: { Set(AITopicProvider.allCases) })
        manager.installSnapshot(url: url)
        var stale = false, delivered = false
        manager.search("first", provider: nil) { _ in stale = true }
        manager.search("second", provider: .claude) { result in
            if case .success(let found) = result { delivered = found.topics.map(\.title) == ["second"] }
        }
        XCTAssertTrue(eventually { delivered }); XCTAssertFalse(stale)
        manager.stop()
    }
    func testFreeSettingsPersistIndependentProviderTogglesAndFilterExistingIndex() throws {
        _ = NSApplication.shared
        let root = try directory(), url = root.appendingPathComponent("index.sqlite")
        let index = try AITopicIndex(url: url)
        try index.upsert(.init(id: "free-session", provider: .claude, title: "free topic"))
        try index.upsert(.init(id: "codex-session", provider: .codex, title: "codex topic"))
        let suite = "oilfind-topics-settings-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = AITopicManager(defaults: defaults, url: url, locations: .init(home: root), detectProviders: { Set(AITopicProvider.allCases) })
        manager.installSnapshot(url: url); defer { manager.stop() }
        let provider = AITopicSearchProvider(manager: manager)
        let settings = SettingsModel(snapshot: true, preferences: defaults, topics: manager)
        XCTAssertTrue(settings.topics === manager)
        XCTAssertTrue(provider.isEnabled)
        XCTAssertTrue(manager.isProviderEnabled(.claude)); XCTAssertTrue(manager.isProviderEnabled(.codex))
        XCTAssertEqual(try provider.prepareSearch(.parse("topic"), isCancelled: { false })().count, 2)
        let displayed = try provider.prepareSearch(.parse("topic"), isCancelled: { false })()
        let claudeAction = try XCTUnwrap(provider.prepareSearch(.parse("free topic"), isCancelled: { false })().first?.actions.first { $0.kind == .copyName })
        settings.topics.setProviderEnabled(.claude, enabled: false)
        XCTAssertFalse(manager.isProviderEnabled(.claude)); XCTAssertTrue(manager.isProviderEnabled(.codex))
        XCTAssertEqual(defaults.object(forKey: "aiTopicsProvider.claude.enabled") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "aiTopicsProvider.codex.enabled") as? Bool, nil)
        XCTAssertEqual(try provider.prepareSearch(.parse("topic"), isCancelled: { false })().map(\.title), ["codex topic"])
        XCTAssertEqual(provider.availableItems(from: displayed).map(\.title), ["codex topic"])
        XCTAssertTrue(try provider.prepareSearch(.parse("free topic"), isCancelled: { false })().isEmpty)
        XCTAssertTrue(eventually { manager.count == 1 })
        let restoredSettings = AITopicManager(defaults: defaults, url: url, locations: .init(home: root), detectProviders: { Set(AITopicProvider.allCases) })
        XCTAssertFalse(restoredSettings.isProviderEnabled(.claude)); XCTAssertTrue(restoredSettings.isProviderEnabled(.codex))
        var completed = false, succeeded = true
        claudeAction.perform { succeeded = $0; completed = true }
        XCTAssertTrue(eventually { completed }); XCTAssertFalse(succeeded)
        settings.topics.setProviderEnabled(.codex, enabled: false)
        XCTAssertTrue(try provider.prepareSearch(.parse(""), isCancelled: { false })().isEmpty)
        XCTAssertTrue(eventually { manager.count == 0 })
        XCTAssertEqual(try index.count(), 2)
        settings.topics.setProviderEnabled(.codex, enabled: true)
        settings.topics.setProviderEnabled(.claude, enabled: true)
        XCTAssertTrue(eventually { manager.count == 2 })
        XCTAssertEqual(try provider.prepareSearch(.parse("topic"), isCancelled: { false })().count, 2)
        settings.topics.setEnabled(false)
        XCTAssertFalse(provider.isEnabled); XCTAssertFalse(defaults.bool(forKey: "aiTopicsEnabled"))
        settings.topics.setEnabled(true)
        XCTAssertTrue(provider.isEnabled)
        XCTAssertEqual(try provider.prepareSearch(.parse("free topic"), isCancelled: { false })().count, 1)
    }
    func testDesktopIdentityAndShellQuoting() throws {
        let id = UUID().uuidString.lowercased()
        let topic = AITopic(id: id, provider: .claude, title: "test", project: "/tmp/a'b $(touch unsafe)", desktopID: "local_" + id)
        let url = try XCTUnwrap(AITopicActions.desktopURL(topic))
        XCTAssertEqual(url.host, "claude.ai"); XCTAssertEqual(url.path, "/epitaxy/" + topic.desktopID)
        XCTAssertTrue(topic.resumeCommand.contains("'\\''")); XCTAssertTrue(topic.resumeCommand.contains("--resume '" + id + "'"))
        XCTAssertNil(AITopicActions.desktopURL(.init(id: id, provider: .claude, title: "", desktopID: "bad?session=other")))
        XCTAssertEqual(AITopicActions.desktopURL(.init(id: id, provider: .codex, title: ""))?.absoluteString, "codex://threads/" + id)
        for provider in AITopicProvider.allCases { XCTAssertFalse(AITopicIcons().image(provider).representations.isEmpty) }
    }
    func testProviderReturnsAllMatchesWithoutMoreAndRejectsDeletedCapturedAction() throws {
        _ = NSApplication.shared
        let root = try directory(), url = root.appendingPathComponent("index.sqlite")
        let index = try AITopicIndex(url: url)
        try index.transaction {
            for i in 0..<150 { try index.upsert(.init(id: String(i), provider: i % 2 == 0 ? .claude : .codex, title: "shared \(i)", modified: Double(i))) }
        }
        let manager = AITopicManager(url: url, locations: .init(home: root), detectProviders: { Set(AITopicProvider.allCases) })
        manager.installSnapshot(url: url); defer { manager.stop() }
        let provider = AITopicSearchProvider(manager: manager)
        let found = try provider.prepareSearch(.parse("shared"), isCancelled: { false })()
        XCTAssertEqual(found.count, 150)
        XCTAssertTrue(try provider.prepareSearch(.parse("missing unique phrase"), isCancelled: { false })().isEmpty)
        XCTAssertTrue(try provider.prepareSearch(.parse("shared"), isCancelled: { true })().isEmpty)
        let captured = try XCTUnwrap(found.first), action = try XCTUnwrap(captured.actions.first { $0.kind == .copyName })
        try index.reconcile(provider: .codex, topics: [], files: [])
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { source -> NSPasteboardItem in
            let copy = NSPasteboardItem(); for type in source.types { if let data = source.data(forType: type) { copy.setData(data, forType: type) } }; return copy
        }
        defer { pasteboard.clearContents(); pasteboard.writeObjects(saved) }
        pasteboard.clearContents(); pasteboard.setString("unchanged sentinel", forType: .string)
        var finished = false, succeeded = true
        action.perform { succeeded = $0; finished = true }
        XCTAssertTrue(eventually { finished }); XCTAssertFalse(succeeded)
        XCTAssertEqual(pasteboard.string(forType: .string), "unchanged sentinel")
    }
    func testOlderCodexBodyChangesWithoutMetadataTimestampStillRefresh() throws {
        let root = try directory(), home = root.appendingPathComponent("home"), source = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let state = try AITopicSQL(source.appendingPathComponent("state_5.sqlite"))
        try state.run("CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,updated_at REAL)")
        let history = try AITopicSQL(source.appendingPathComponent("thread_history_1.sqlite"))
        try history.run("CREATE TABLE thread_items(thread_id TEXT,item_id TEXT,item_type TEXT,item_json TEXT,rollout_ordinal INTEGER,updated_at_ordinal INTEGER)")
        for i in 0..<25 {
            let row = try state.prepare("INSERT INTO threads VALUES(?,?,?)"); row.bind(["topic-\(i)", "topic \(i)", String(100 - i)]); _ = try row.next()
        }
        try history.run("INSERT INTO thread_items VALUES('topic-24','m1','agentMessage','{\"type\":\"agentMessage\",\"text\":\"olduniquebody\"}',1,1)")
        let index = try AITopicIndex(url: root.appendingPathComponent("index.sqlite")), importer = AITopicIndexer(index: try AITopicIndex(url: root.appendingPathComponent("index.sqlite")), locations: .init(home: home))
        try importer.refresh(); try importer.refresh()
        XCTAssertEqual(try index.search("olduniquebody").topics.count, 1)
        try history.run("UPDATE thread_items SET item_json='{\"type\":\"agentMessage\",\"text\":\"newuniquebody\"}',updated_at_ordinal=2")
        try importer.refresh()
        XCTAssertTrue(try index.search("olduniquebody").topics.isEmpty)
        XCTAssertEqual(try index.search("newuniquebody").topics.count, 1)
    }
}
