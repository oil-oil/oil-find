import AppKit
import XCTest
@testable import OilFindApp

final class AITopicInstallationTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oilfind-agent-detection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func defaults() -> UserDefaults {
        let suite = "oilfind-agent-detection-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }; return defaults
    }
    private func executable(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    private func app(_ url: URL, provider: AITopicProvider) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": AITopicInstallation.bundleIdentifiers[provider]!, "CFBundleName": provider.name, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    }
    func testDesktopDetectionRejectsStaleRegistrationsAndTrashedApps() throws {
        let root = try directory(), workbuddy = root.appendingPathComponent("WorkBuddy.app")
        try app(workbuddy, provider: .workbuddy)
        let stale = root.appendingPathComponent("Missing.app")
        let lookup: (String) -> URL? = { id in
            if id == AITopicInstallation.bundleIdentifiers[.workbuddy] { return workbuddy }
            return stale
        }
        XCTAssertEqual(AITopicInstallation.installed(home: root, environment: [:], application: lookup, executable: { _ in false }), [.workbuddy])
        let trashed = root.appendingPathComponent(".Trash/WorkBuddy.app")
        try FileManager.default.createDirectory(at: trashed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: workbuddy, to: trashed)
        XCTAssertTrue(AITopicInstallation.installed(home: root, environment: [:], application: { id in id == AITopicInstallation.bundleIdentifiers[.workbuddy] ? trashed : lookup(id) }, executable: { _ in false }).isEmpty)
    }
    func testCLIDetectionFindsUserAndNodeInstallationsWithoutRunningThem() throws {
        let home = try directory(), claude = home.appendingPathComponent(".local/bin/claude")
        try executable(claude)
        let check: (URL) -> Bool = { url in
            url.path.hasPrefix(home.path + "/") && FileManager.default.isExecutableFile(atPath: url.path) && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".local/bin/codex"), withIntermediateDirectories: true)
        XCTAssertEqual(AITopicInstallation.installed(home: home, environment: [:], application: { _ in nil }, executable: check), [.claude])
        let codex = home.appendingPathComponent(".nvm/versions/node/v22/bin/codex"), target = home.appendingPathComponent("codex-real")
        try executable(target)
        try FileManager.default.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: codex, withDestinationURL: target)
        XCTAssertEqual(AITopicInstallation.installed(home: home, environment: [:], application: { _ in nil }, executable: check), [.claude, .codex])
    }
    func testMissingAgentsStayOffAndDoNotStartAnIndex() throws {
        let root = try directory(), defaults = defaults(), index = root.appendingPathComponent("index/index.sqlite")
        // Leftover or damaged data is not evidence that the application is still installed.
        let data = root.appendingPathComponent(".workbuddy")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("broken data".utf8).write(to: data.appendingPathComponent("workbuddy.db"))
        let manager = AITopicManager(defaults: defaults, url: index, locations: .init(home: root), detectProviders: { [] })
        manager.start(); defer { manager.stop() }
        manager.visibilityChanged(true); manager.requestRefresh(immediate: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(manager.enabledProviders.isEmpty); XCTAssertFalse(manager.isEnabled)
        XCTAssertFalse(manager.indexing); XCTAssertFalse(manager.failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: index.path))
        XCTAssertNil(AITopicSearchProvider(manager: manager).status)
        XCTAssertTrue(try manager.readSearch("anything", isCancelled: { false }).topics.isEmpty)
        for provider in AITopicProvider.allCases { XCTAssertNil(defaults.object(forKey: "aiTopicsProvider.\(provider.rawValue).enabled")) }
    }
    func testManualChoicesPersistWhileAutomaticDefaultsFollowInstallations() throws {
        let defaults = defaults()
        var installed: Set<AITopicProvider> = [.claude]
        let manager = AITopicManager(defaults: defaults, detectProviders: { installed })
        manager.setEnabled(false)
        XCTAssertEqual(manager.enabledProviders, [.claude])
        manager.setProviderEnabled(.claude, enabled: true)
        manager.setProviderEnabled(.codex, enabled: false)
        installed = [.codex, .workbuddy]
        manager.refreshProviderAvailability()
        XCTAssertEqual(manager.enabledProviders, [.claude, .workbuddy])
        let restored = AITopicManager(defaults: defaults, detectProviders: { installed })
        XCTAssertEqual(restored.enabledProviders, [.claude, .workbuddy])
        XCTAssertFalse(restored.enabled)
        installed = []
        restored.refreshProviderAvailability()
        XCTAssertEqual(restored.enabledProviders, [.claude])
        XCTAssertNil(defaults.object(forKey: "aiTopicsProvider.workbuddy.enabled"))
    }
    func testDetectionRevokesCachedResultsAndOldActions() throws {
        let root = try directory(), defaults = defaults(), url = root.appendingPathComponent("index.sqlite")
        let index = try AITopicIndex(url: url)
        try index.upsert(.init(id: "claude-demo", provider: .claude, title: "shared topic"))
        try index.upsert(.init(id: "codex-demo", provider: .codex, title: "shared topic"))
        var installed: Set<AITopicProvider> = [.claude, .codex]
        let manager = AITopicManager(defaults: defaults, url: url, detectProviders: { installed })
        manager.installSnapshot(url: url); defer { manager.stop() }
        let provider = AITopicSearchProvider(manager: manager)
        let matches = try provider.prepareSearch(.parse("shared"), isCancelled: { false })()
        let stale = try XCTUnwrap(matches.first { $0.id == "claude:claude-demo" }?.actions.first { $0.kind == .copyName })
        installed = [.codex]; manager.refreshProviderAvailability()
        XCTAssertEqual(try provider.prepareSearch(.parse("shared"), isCancelled: { false })().map(\.id), ["codex:codex-demo"])
        var finished = false, accepted = true
        stale.perform { accepted = $0; finished = true }
        let deadline = Date().addingTimeInterval(2)
        while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(finished); XCTAssertFalse(accepted)
        XCTAssertEqual(try index.count(), 2)
        manager.setProviderEnabled(.claude, enabled: true)
        XCTAssertEqual(try provider.prepareSearch(.parse("shared"), isCancelled: { false })().count, 2)
    }
}
