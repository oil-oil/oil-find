import AppKit
import SwiftUI
import XCTest
@testable import OilFindCore
@testable import OilFindApp

final class CoverageSourcesUITests: XCTestCase {
    private final class Extension: ApplicationExtension {
        var sources: [SearchSource] = []
        func searchSources() -> [SearchSource] { sources }
        func start(chinese: Bool, showSettings: @escaping () -> Void) {}
        func stop() {}
        func languageDidChange(chinese: Bool) {}
        func handle(_ url: URL) {}
        func settingsSection(window: @escaping () -> NSWindow?) -> AnyView { AnyView(EmptyView()) }
    }
    func testSettingsInspectorUsesSourceScopeAndFallsBackWhenSourceIsUnavailable() {
        _ = NSApplication.shared
        let root = "/Volumes/Archive", excluded = root + "/skip"
        var buffer = ScanBuffer()
        Array("readme.md".utf8).withUnsafeBufferPointer {
            buffer.append(id: 1, parent: 0, size: 0, mtime: 0, flags: SiftFlag.userArea, depth: 2, kind: 3, name: $0)
        }
        let config = IndexConfig(rootPath: root, userExcludedPaths: [excluded])
        let store = IndexStore(scan: ScanOutput(buffers: [buffer], count: 2, homeIndex: .max, elapsed: 0, finishedAt: 0), config: config)
        store.write { store.buildHash() }
        let appExtension = Extension()
        func source(online: Bool) -> SearchSource {
            SearchSource(id: "archive", displayName: "Archive", isOnline: online, store: store,
                         explainPath: { Coverage.explain(path: $0, config: config, store: store) })
        }
        appExtension.sources = [source(online: true)]
        let manager = IndexManager(config: .standard(), dbURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = SettingsModel(snapshot: true)
        model.manager = manager
        let controller = SettingsWindowController(model: model, appExtension: appExtension)
        defer { controller.close() }
        func check(_ path: String, _ answer: CoverageExplanation) {
            model.explanation = nil
            model.check(path: path)
            let deadline = Date().addingTimeInterval(3)
            while model.explanation == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            XCTAssertEqual(model.explanation, L10n.explanation(answer), path)
        }
        check(root + "/readme.md", .indexed)
        check(excluded + "/readme.md", .userExcluded(excluded))
        check(root + "/node_modules/readme.md", .scope(.dependency))
        check(root + " 1/readme.md", .volume)
        check("/Volumes/Network/readme.md", .volume)
        appExtension.sources = []
        check(root + "/readme.md", .volume)
        appExtension.sources = [source(online: false)]
        check(root + "/readme.md", .volume)
    }
}
