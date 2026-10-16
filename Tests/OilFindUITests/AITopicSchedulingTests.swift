import Foundation
import XCTest
@testable import OilFindApp

final class AITopicSchedulingTests: XCTestCase {
    func testRepeatedWritesKeepOtherProvidersAheadOfResumedHistory() {
        var queue = AITopicSyncQueue()
        queue.enqueue(Set(AITopicProvider.allCases))
        XCTAssertEqual(queue.next()?.history, .claude)
        for _ in 0..<100 { queue.enqueue([.claude]) }
        queue.resume(.claude)
        let codex = queue.next()
        XCTAssertEqual(codex?.history, .codex)
        XCTAssertEqual(codex?.metadata, [.claude])
        XCTAssertEqual(queue.next()?.history, .workbuddy)
        XCTAssertEqual(queue.next()?.history, .claude)
        XCTAssertTrue(queue.isEmpty)
    }
    func testNewEventsMergedWithContinuationStillRunAFreshPass() {
        var queue = AITopicSyncQueue()
        queue.enqueue([.claude, .codex])
        XCTAssertEqual(queue.next()?.history, .claude)
        queue.resume(.claude)
        queue.enqueue([.claude])
        // Codex publishes the new Claude metadata while Claude's old history plan is paused.
        let codex = queue.next()
        XCTAssertEqual(codex?.history, .codex)
        XCTAssertEqual(codex?.metadata, [.claude])
        queue.complete(.codex)
        XCTAssertEqual(queue.next()?.history, .claude)
        queue.complete(.claude)
        XCTAssertFalse(queue.isEmpty, "A frozen plan cannot consume a newer source event")
        XCTAssertEqual(queue.next()?.history, .claude)
        queue.complete(.claude)
        XCTAssertTrue(queue.isEmpty)
    }

    func testOtherSourceArchiveAndNewSessionArriveDuringContinuousWrites() throws {
        if ProcessInfo.processInfo.environment["CI"] != nil { throw XCTSkip("Local sustained-write latency check") }
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("oilfind-fairness-" + UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), locations = AITopicLocations(home: home)
        let url = root.appendingPathComponent("index.sqlite")
        func row(_ object: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: object) + Data([10])
        }
        try files.createDirectory(at: locations.codex, withIntermediateDirectories: true)
        let state = try AITopicSQL(locations.codex.appendingPathComponent("state_5.sqlite"))
        try state.run("PRAGMA journal_mode=WAL; CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,updated_at INTEGER,archived INTEGER,rollout_path TEXT)")
        func codex(_ id: String) throws {
            let file = locations.codex.appendingPathComponent("sessions/" + id + ".jsonl")
            try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = try row(["type":"session_meta", "payload":["id":id, "cwd":"/demo"]])
            data.append(try row(["type":"response_item", "payload":["type":"message", "role":"user", "content":[["type":"input_text", "text":"fairnessnewtopic"]]]]))
            try data.write(to: file)
            let insert = try state.prepare("INSERT INTO threads VALUES(?,?,1,0,?)")
            insert.bind([id, "fairness " + id, file.path]); _ = try insert.next()
        }
        try codex("old")
        do {
            let index = try AITopicIndex(url: url)
            try AITopicIndexer(index: index, locations: locations).refresh(providers: [.codex])
        }
        try state.run("UPDATE threads SET archived=1 WHERE id='old'")
        try codex("new")
        let project = locations.claude.appendingPathComponent("projects/fairness")
        try files.createDirectory(at: project, withIntermediateDirectories: true)
        let body = try row(["type":"user", "message":["content":String(repeating: "streaming context ", count: 1500)]])
        var first: URL!
        for i in 0..<100 {
            let file = project.appendingPathComponent(UUID().uuidString + ".jsonl")
            try body.write(to: file)
            if i == 0 { first = file }
        }
        let suite = "oilfind-fairness-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = AITopicManager(defaults: defaults, url: url, locations: locations, detectProviders: { [.claude, .codex] })
        manager.start()
        defer { manager.onChange = nil; manager.stop() }
        let handle = try FileHandle(forWritingTo: first)
        try handle.seekToEnd()
        defer { try? handle.close() }
        let append = try row(["type":"assistant", "message":["content":"stream continues"]])
        var writes = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            try? handle.write(contentsOf: append); writes += 1
            manager.requestRefresh(providers: [.claude])
        }
        defer { timer.invalidate() }
        let reader = try AITopicIndex(url: url, readOnly: true), began = Date()
        var observed = false
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            observed = try reader.topic("codex:old")?.archived == true && reader.search("fairnessnewtopic", provider: .codex).topics.map(\.id) == ["new"]
        } while !observed && Date().timeIntervalSince(began) < 8
        XCTAssertTrue(observed, "Another provider must progress while source writes keep arriving")
        XCTAssertGreaterThan(writes, 5)
        print("Topic cross-provider continuous-write latency: \(Date().timeIntervalSince(began) * 1000) ms; writes=\(writes)")
    }

    func testContinuousEventsCannotPostponeIdleDebounceForever() throws {
        if ProcessInfo.processInfo.environment["CI"] != nil { throw XCTSkip("Local event scheduling latency check") }
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("oilfind-debounce-" + UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let locations = AITopicLocations(home: root.appendingPathComponent("home"))
        let project = locations.claude.appendingPathComponent("projects/debounce")
        try files.createDirectory(at: project, withIntermediateDirectories: true)
        let suite = "oilfind-debounce-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = AITopicManager(defaults: defaults, url: root.appendingPathComponent("index.sqlite"), locations: locations, detectProviders: { [.claude] })
        manager.start(); defer { manager.stop() }
        var deadline = Date().addingTimeInterval(5)
        repeat { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        while (manager.indexing || !files.fileExists(atPath: manager.url.path)) && Date() < deadline
        XCTAssertFalse(manager.indexing)
        let file = project.appendingPathComponent(UUID().uuidString + ".jsonl")
        let row = try JSONSerialization.data(withJSONObject: ["type":"user", "message":["content":"debounceproof"]]) + Data([10])
        try row.write(to: file)
        manager.requestRefresh(providers: [.claude])
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in manager.requestRefresh(providers: [.claude]) }
        defer { timer.invalidate() }
        deadline = Date().addingTimeInterval(3)
        while manager.count != 1 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(manager.count, 1, "Debounce must start despite uninterrupted events")
    }
}
