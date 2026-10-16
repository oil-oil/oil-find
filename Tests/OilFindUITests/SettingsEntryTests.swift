import AppKit
import XCTest
@testable import OilFindApp

final class SettingsEntryTests: XCTestCase {
    func testSettingsHasIconAndTextAfterHintsAndInvokesTheExistingAction() throws {
        _ = NSApplication.shared
        defer { L10n.snapshotChinese = nil }
        for chinese in [true, false] {
            L10n.snapshotChinese = chinese
            let controller = SearchViewController(snapshot: true)
            controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 560)
            controller.view.layoutSubtreeIfNeeded()
            let footer = controller.footer
            footer.actionable = true; footer.needsLayout = true; footer.layoutSubtreeIfNeeded()
            let button = try XCTUnwrap(footer.subviews.compactMap { $0 as? SettingsButton }.first)
            XCTAssertEqual(button.title, chinese ? "设置" : "Settings")
            XCTAssertEqual(button.frame.maxX, footer.bounds.width - 18)
            XCTAssertTrue(controller.searchField.subviews.compactMap { $0 as? NSButton }.allSatisfy { !($0 is SettingsButton) })
            XCTAssertTrue(button.subviews.contains { $0 is NSImageView })
            let label = try XCTUnwrap(button.subviews.compactMap { $0 as? NSTextField }.first)
            XCTAssertEqual(label.stringValue, button.title)
            XCTAssertGreaterThanOrEqual(label.frame.width, ceil(label.attributedStringValue.size().width))
            for hint in footer.subviews where hint.frame.height == 18 && !hint.isHidden {
                XCTAssertLessThanOrEqual(hint.frame.maxX, button.frame.minX - 14)
            }
            var opened = 0; controller.onSettings = { opened += 1 }
            button.performClick(nil); XCTAssertEqual(opened, 1)
        }
    }
}
