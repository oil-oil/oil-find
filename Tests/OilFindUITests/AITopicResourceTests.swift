import AppKit
import XCTest
@testable import OilFindApp

final class AITopicResourceTests: XCTestCase {
    func testEveryProviderHasABundledIcon() {
        for provider in AITopicProvider.allCases {
            XCTAssertNotNil(AITopicIcons.bundledImage(provider), provider.rawValue)
        }
    }

    func testInstalledResourcesResolveWithoutTheBuildDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oilfind-resources-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Oil Find.app/Contents/Resources")
        let icons = resources.appendingPathComponent("OilFind_OilFindApp.bundle/Resources/TopicIcons")
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        let source = try XCTUnwrap(AITopicIcons.bundledImage(.codex)?.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: source))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: icons.appendingPathComponent("codex.png"))
        XCTAssertNotNil(AITopicIcons.bundledImage(.codex, directories: [resources]))
        XCTAssertNil(AITopicIcons.bundledImage(.claude, directories: [resources]))
    }

    func testMissingResourcesAllowTheFallbackIcon() {
        XCTAssertNil(AITopicIcons.bundledImage(.codex, directories: []))
    }
}
