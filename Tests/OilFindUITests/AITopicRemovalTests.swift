import Foundation
import XCTest
@testable import OilFindApp

final class AITopicRemovalTests: XCTestCase {
    func testLegacyHarnessCacheIsHiddenReadOnlyAndPurgedByWriterOpen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oilfind-topic-removal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("index.sqlite")
        do { _ = try AITopicIndex(url: url) }

        do {
            let seed = try AITopicSQL(url)
            try seed.run("""
                INSERT INTO topics(id,session,provider,title,project,modified,desktop,transcript,archived,excerpt)
                VALUES('harness:legacy','legacy','harness','legacy harness topic','',1,'','',0,'');
                INSERT INTO topic_docs(topic,folded,bytes,boundaries)
                SELECT pk,X'00',1,X'' FROM topics WHERE provider='harness';
                """)
        }

        let legacy = try AITopicIndex(url: url, readOnly: true)
        XCTAssertEqual(try legacy.count(), 0)
        XCTAssertTrue(try legacy.search("").topics.isEmpty)
        XCTAssertNil(try legacy.topic("harness:legacy"))
        let beforeCleanup = try AITopicSQL(url, readOnly: true)
        let staleRows = try beforeCleanup.prepare("SELECT count(*) FROM topics WHERE provider='harness'")
        _ = try staleRows.next()
        XCTAssertEqual(staleRows.int(0), 1)

        let cleaned = try AITopicIndex(url: url)
        XCTAssertEqual(try cleaned.count(), 0)
        XCTAssertNil(try cleaned.topic("harness:legacy"))
        let remainingRows = try cleaned.sql.prepare("SELECT count(*) FROM topics WHERE provider='harness'")
        _ = try remainingRows.next()
        XCTAssertEqual(remainingRows.int(0), 0)

        let suite = "oilfind-topic-removal-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "aiTopicsProvider.harness.enabled")
        let manager = AITopicManager(defaults: defaults, detectProviders: { [] })
        XCTAssertTrue(manager.enabledProviders.isEmpty)
    }
}
