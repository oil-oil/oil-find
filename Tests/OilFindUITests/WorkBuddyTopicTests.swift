import AppKit
import XCTest
@testable import OilFindApp

final class WorkBuddyTopicTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oilfind-workbuddy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func account(_ home: URL, uid: String = "owner", age: Double = 0) throws {
        let url = home.appendingPathComponent(".workbuddy/storage/skeleton/account-snapshot.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["primary":["version":1,"uid":uid,"nickname":"Test","type":"private","savedAt":(Date().timeIntervalSince1970 - age) * 1000]]).write(to: url, options: .atomic)
    }
    private func database(_ home: URL) throws -> AITopicSQL {
        try account(home)
        let db = try AITopicSQL(home.appendingPathComponent(".workbuddy/workbuddy.db"))
        try db.run("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE sessions(id TEXT PRIMARY KEY,cwd TEXT,user_id TEXT,title TEXT,custom_title TEXT,status TEXT,
                created_at INTEGER,updated_at INTEGER,last_activity_at INTEGER,deleted_at INTEGER,transport TEXT,session_settings TEXT);
            """)
        return db
    }
    private func session(_ source: AITopicSQL, id: String = "topic-demo", user: String = "owner", status: String = "completed", settings: String = "", transport: String = "local") throws {
        let s = try source.prepare("INSERT INTO sessions VALUES(?,'/demo',?,?,'Custom title',?,1000,2000,3000,NULL,?,?)")
        s.bind([id,user,"Original title",status,transport,settings]); _ = try s.next()
    }
    private func rows(_ objects: [[String: Any]]) throws -> Data {
        try objects.reduce(into: Data()) { data, object in
            data.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])); data.append(10)
        }
    }
    private func message(_ text: String, id: String = "message-one", session: String = "topic-demo", type: String = "message", role: String = "user") -> [String: Any] {
        ["type":type,"id":id,"sessionId":session,"role":role,"content":[["type":role == "user" ? "input_text" : "output_text","text":text]]]
    }
    private func fixture(_ home: URL, id: String = "topic-demo") throws -> URL {
        let file = home.appendingPathComponent(".workbuddy/projects/demo/" + id + ".jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rows([
            message("humanfindword", session: id),
            message("assistantfindword", id:"message-two", session:id, role:"assistant"),
            message("reasoningprivateword", id:"message-three", session:id, type:"reasoning"),
            message("toolprivateword", id:"message-four", session:id, type:"function_call_result"),
            message("wrongsessionword", id:"message-five", session:"wrong-session")
        ]).write(to: file)
        return file
    }

    func testAuthoritativeMetadataVisibilityArchivesAndDeletion() throws {
        let root = try directory(), home = root.appendingPathComponent("home"), source = try database(home)
        try session(source); _ = try fixture(home)
        try session(source, id:"archived", status:"archived"); _ = try fixture(home, id:"archived")
        try session(source, id:"other-user", user:"other"); _ = try fixture(home, id:"other-user")
        try session(source, id:"deleted"); _ = try fixture(home, id:"deleted"); try source.run("UPDATE sessions SET deleted_at=1 WHERE id='deleted'")
        try session(source, id:"quick", settings:"{\"conversationTags\":{\"wbQuickAsk\":\"1\"}}"); _ = try fixture(home, id:"quick")
        try session(source, id:"marker"); let marker = try fixture(home, id:"marker"); try Data().write(to: marker.deletingPathExtension().appendingPathExtension("quickask"))
        try session(source, id:"cloud", transport:"cloud"); _ = try fixture(home, id:"cloud")
        try session(source, id:"title-only"); _ = try fixture(home, id:"orphan")
        let nested = home.appendingPathComponent(".workbuddy/projects/demo/topic-demo/subagents/child.jsonl")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rows([message("childprivateword", session:"topic-demo")]).write(to: nested)
        let index = try AITopicIndex(url: root.appendingPathComponent("index.sqlite")), importer = AITopicIndexer(index:index,locations:.init(home:home))
        try importer.refresh(providers:[.workbuddy])
        XCTAssertEqual(Set(try index.search("").topics.map(\.id)), ["topic-demo","title-only"])
        XCTAssertEqual(try index.search("humanfindword").topics.map(\.id), ["topic-demo"])
        XCTAssertEqual(try index.search("assistantfindword").topics.first?.title, "Custom title")
        XCTAssertEqual(try index.topic("workbuddy:topic-demo")?.modified, 3)
        for text in ["reasoningprivateword","toolprivateword","wrongsessionword","childprivateword"] { XCTAssertTrue(try index.search(text).topics.isEmpty) }
        try source.run("UPDATE sessions SET status='archived' WHERE id='topic-demo'"); try importer.refresh(providers:[.workbuddy])
        XCTAssertTrue(try index.search("humanfindword").topics.isEmpty)
        try source.run("UPDATE sessions SET status='completed' WHERE id='topic-demo'"); try importer.refresh(providers:[.workbuddy])
        XCTAssertEqual(try index.search("humanfindword").topics.count, 1)
        try source.run("DELETE FROM sessions WHERE id='topic-demo'"); try importer.refresh(providers:[.workbuddy])
        XCTAssertTrue(try index.search("humanfindword").topics.isEmpty)
    }

    func testIncrementalAppendReplacementAndMissingBody() throws {
        let root = try directory(), home = root.appendingPathComponent("home"), source = try database(home)
        try session(source); let file = try fixture(home)
        let index = try AITopicIndex(url:root.appendingPathComponent("index.sqlite")), importer = AITopicIndexer(index:index,locations:.init(home:home))
        try importer.refresh(providers:[.workbuddy])
        let append = try rows([message("appendfindword",id:"new-message",role:"assistant")])
        let handle = try FileHandle(forWritingTo:file); try handle.seekToEnd(); try handle.write(contentsOf:append.prefix(20))
        try importer.refresh(providers:[.workbuddy]); XCTAssertTrue(try index.search("appendfindword").topics.isEmpty)
        try handle.write(contentsOf:append.dropFirst(20)); try handle.close(); try importer.refresh(providers:[.workbuddy])
        XCTAssertEqual(try index.search("appendfindword").topics.count,1)
        try rows([message("replacementword")]).write(to:file); try importer.refresh(providers:[.workbuddy])
        XCTAssertTrue(try index.search("humanfindword").topics.isEmpty); XCTAssertEqual(try index.search("replacementword").topics.count,1)
        try Data("{\"type\":".utf8).write(to:file)
        XCTAssertThrowsError(try importer.refresh(providers:[.workbuddy])); XCTAssertEqual(try index.search("replacementword").topics.count,1)
        try source.run("UPDATE sessions SET status='archived'")
        XCTAssertThrowsError(try importer.refresh(providers:[.workbuddy])); XCTAssertTrue(try index.search("replacementword").topics.isEmpty)
        try source.run("UPDATE sessions SET status='completed'"); try FileManager.default.removeItem(at:file)
        try importer.refresh(providers:[.workbuddy]); XCTAssertTrue(try index.search("replacementword").topics.isEmpty)
        XCTAssertEqual(try index.search("Custom title").topics.count,1)
    }

    func testAccountScopeFailClosedAndProviderToggleActions() throws {
        let root = try directory(), home = root.appendingPathComponent("home"), source = try database(home)
        try session(source); _ = try fixture(home)
        let url = root.appendingPathComponent("index.sqlite"), index = try AITopicIndex(url:url), importer = AITopicIndexer(index:index,locations:.init(home:home))
        try importer.refresh(providers:[.workbuddy])
        let suite = "oilfind-workbuddy-settings-" + UUID().uuidString, defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let manager = AITopicManager(defaults:defaults,url:url,locations:.init(home:home), detectProviders: { Set(AITopicProvider.allCases) }); manager.installSnapshot(url:url); defer { manager.stop() }
        let provider = AITopicSearchProvider(manager:manager)
        let result = try XCTUnwrap(provider.prepareSearch(.parse("humanfindword"),isCancelled:{false})().first)
        XCTAssertTrue(result.location.hasPrefix("WorkBuddy")); XCTAssertEqual(result.actions.map(\.kind),[.open,.copy,.copyName])
        let topic = try XCTUnwrap(index.topic("workbuddy:topic-demo"))
        XCTAssertEqual(AITopicActions.desktopURL(topic)?.absoluteString,"workbuddy://chat/topic-demo")
        XCTAssertEqual(topic.resumeCommand,"open 'workbuddy://chat/topic-demo'")
        XCTAssertNil(AITopic(id:"../unsafe",provider:.workbuddy,title:"").workbuddyURL)
        manager.setProviderEnabled(.workbuddy,enabled:false)
        XCTAssertTrue(try provider.prepareSearch(.parse("humanfindword"),isCancelled:{false})().isEmpty)
        XCTAssertFalse(AITopicManager(defaults:defaults, detectProviders: { Set(AITopicProvider.allCases) }).isProviderEnabled(.workbuddy))
        try importer.refresh(providers:[.codex]); XCTAssertEqual(try index.search("humanfindword").topics.count,1)
        try account(home,uid:"different-owner"); try importer.refresh(providers:[.workbuddy]); XCTAssertEqual(try index.count(providers:[.workbuddy]),0)
        try account(home); try importer.refresh(providers:[.workbuddy]); XCTAssertEqual(try index.search("humanfindword").topics.count,1)
        try account(home,age:31*86400); try importer.refresh(providers:[.workbuddy]); XCTAssertEqual(try index.count(),0)
        try account(home); try importer.refresh(providers:[.workbuddy]); XCTAssertEqual(try index.count(),1)
        try FileManager.default.removeItem(at:home.appendingPathComponent(".workbuddy/storage/skeleton/account-snapshot.json"))
        try importer.refresh(providers:[.workbuddy]); XCTAssertEqual(try index.count(),0)
    }

    func testEditedBranchesHiddenMetadataAndLegacyACPBinding() throws {
        let root = try directory(), home = root.appendingPathComponent("home"), source = try database(home)
        try session(source)
        let file = try fixture(home), index = try AITopicIndex(url:root.appendingPathComponent("index.sqlite"))
        let importer = AITopicIndexer(index:index,locations:.init(home:home))
        try importer.refresh(providers:[.workbuddy])
        var user = message("editedpromptword",id:"edited-user"); user["parentId"] = "message-two"
        var answer = message("editedanswerword",id:"edited-answer",role:"assistant"); answer["parentId"] = "edited-user"
        var meta = message("hiddenmetaword",id:"meta"); meta["providerData"] = ["isMeta":true]; meta["parentId"] = "edited-answer"
        var compact = message("hiddencompactword",id:"compact",role:"assistant"); compact["providerData"] = ["isCompactInternal":true]; compact["parentId"] = "meta"
        let handle = try FileHandle(forWritingTo:file); try handle.seekToEnd()
        try handle.write(contentsOf:rows([
            ["type":"resend-fork-notice","id":"fork","sessionId":"topic-demo"], user, answer, meta, compact
        ])); try handle.close()
        try importer.refresh(providers:[.workbuddy])
        XCTAssertTrue(try index.search("humanfindword").topics.isEmpty)
        XCTAssertTrue(try index.search("assistantfindword").topics.isEmpty)
        XCTAssertEqual(try index.search("editedpromptword").topics.count,1)
        XCTAssertEqual(try index.search("editedanswerword").topics.count,1)
        XCTAssertTrue(try index.search("hiddenmetaword").topics.isEmpty)
        XCTAssertTrue(try index.search("hiddencompactword").topics.isEmpty)
        try FileManager.default.removeItem(at:file)
        let alias = file.deletingLastPathComponent().appendingPathComponent("acp-legacy.jsonl")
        try rows([message("legacyacpword",session:"acp-legacy")]).write(to:alias)
        let binding = file.deletingLastPathComponent().appendingPathComponent("topic-demo.acp-session.json")
        try JSONSerialization.data(withJSONObject:["acpSessionId":"acp-legacy"]).write(to:binding)
        try importer.refresh(providers:[.workbuddy])
        let result = try XCTUnwrap(index.search("legacyacpword").topics.first)
        XCTAssertEqual(result.id,"topic-demo"); XCTAssertEqual(result.workbuddyURL?.absoluteString,"workbuddy://chat/topic-demo")
        XCTAssertTrue(try index.search("editedpromptword").topics.isEmpty)
    }

    func testAccountChangeClearsCacheEvenWhenSourceDatabaseIsUnavailable() throws {
        let root = try directory(), home = root.appendingPathComponent("home"), source = try database(home)
        try session(source); _ = try fixture(home)
        let index = try AITopicIndex(url:root.appendingPathComponent("index.sqlite")), importer = AITopicIndexer(index:index,locations:.init(home:home))
        try importer.refresh(providers:[.workbuddy]); XCTAssertEqual(try index.count(),1)
        let manager = AITopicManager(url:root.appendingPathComponent("index.sqlite"),locations:.init(home:home), detectProviders: { Set(AITopicProvider.allCases) })
        XCTAssertEqual(try manager.readSearch("humanfindword",isCancelled:{false}).topics.count,1)
        try source.run("ALTER TABLE sessions RENAME TO unavailable")
        try account(home,uid:"different-owner")
        XCTAssertTrue(try manager.readSearch("humanfindword",isCancelled:{false}).topics.isEmpty)
        let claude = home.appendingPathComponent(".claude/projects/demo/" + UUID().uuidString + ".jsonl")
        try FileManager.default.createDirectory(at:claude.deletingLastPathComponent(),withIntermediateDirectories:true)
        try rows([["type":"user","message":["content":"independentsourceword"]]]).write(to:claude)
        XCTAssertThrowsError(try importer.refresh(providers:[.workbuddy,.claude]))
        XCTAssertEqual(try index.count(providers:[.workbuddy]),0)
        XCTAssertEqual(try index.search("independentsourceword").topics.first?.provider,.claude)
    }

    func testWatchUpdatesDatabaseArchivesAndNewMessages() throws {
        if ProcessInfo.processInfo.environment["CI"] != nil { throw XCTSkip("FSEvents delivery is verified locally") }
        let root = try directory(), home = root.appendingPathComponent("home"), source = try database(home)
        try session(source); let file = try fixture(home)
        let suite = "oilfind-workbuddy-watch-" + UUID().uuidString, defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let manager = AITopicManager(defaults:defaults,url:root.appendingPathComponent("index/index.sqlite"),locations:.init(home:home), detectProviders: { Set(AITopicProvider.allCases) })
        for provider in AITopicProvider.allCases where provider != .workbuddy { manager.setProviderEnabled(provider,enabled:false) }
        func eventually(_ body: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while !body() && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }; return body()
        }
        manager.start(); defer { manager.stop() }
        XCTAssertTrue(eventually { manager.count == 1 && !manager.indexing })
        try source.run("UPDATE sessions SET status='archived'")
        XCTAssertTrue(eventually { manager.count == 0 && !manager.indexing })
        try source.run("UPDATE sessions SET status='completed'")
        XCTAssertTrue(eventually { manager.count == 1 && !manager.indexing })
        var found = false
        manager.onChange = { manager.search("watchedappendword",provider:.workbuddy) { if case .success(let result) = $0 { found = !result.topics.isEmpty } } }
        let handle = try FileHandle(forWritingTo:file); try handle.seekToEnd()
        try handle.write(contentsOf:rows([message("watchedappendword",id:"watched")])); try handle.close()
        XCTAssertTrue(eventually { found })
        try FileManager.default.removeItem(at:home.appendingPathComponent(".workbuddy/storage/skeleton/account-snapshot.json"))
        XCTAssertTrue(eventually { manager.count == 0 && !manager.indexing })
    }

    func testLocalWorkBuddyReadOnlySmoke() throws {
        guard ProcessInfo.processInfo.environment["OILFIND_WORKBUDDY_SMOKE"] == "1" else { throw XCTSkip("Opt-in local WorkBuddy data") }
        let root = try directory(), index = try AITopicIndex(url:root.appendingPathComponent("index.sqlite"))
        let importer = AITopicIndexer(index:index)
        let start = Date(); try importer.refresh(providers:[.workbuddy]); let initial = Date().timeIntervalSince(start)
        let found = try index.search("",providers:[.workbuddy],limit:Int.max)
        XCTAssertFalse(found.topics.isEmpty); XCTAssertTrue(found.topics.allSatisfy { !$0.archived && $0.workbuddyURL != nil })
        let count = try index.sql.prepare("SELECT SUM(archived),SUM(transcript!='') FROM topics WHERE provider='workbuddy'"); _ = try count.next()
        let next = Date(); try importer.refresh(providers:[.workbuddy]); let unchanged = Date().timeIntervalSince(next)
        print("WorkBuddy read-only smoke: active=\(found.topics.count), archived=\(count.int(0)), transcripts=\(count.int(1)), initialSeconds=\(initial), unchangedSeconds=\(unchanged)")
        let suite = "oilfind-workbuddy-smoke-" + UUID().uuidString, defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let manager = AITopicManager(defaults:defaults,url:root.appendingPathComponent("manager/index.sqlite"), detectProviders: { Set(AITopicProvider.allCases) })
        for provider in AITopicProvider.allCases where provider != .workbuddy { manager.setProviderEnabled(provider,enabled:false) }
        manager.start(); defer { manager.stop() }
        let deadline = Date().addingTimeInterval(15)
        while (manager.count != found.topics.count || manager.indexing) && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(manager.count,found.topics.count); XCTAssertFalse(manager.indexing); XCTAssertFalse(manager.failed)
        var refreshes = 0
        manager.onChange = { if manager.indexing { refreshes += 1 } }
        RunLoop.main.run(until:Date().addingTimeInterval(1.2))
        XCTAssertLessThan(refreshes,4,"Read-only synchronization must settle without retriggering itself")
    }
}
