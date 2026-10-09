import AppKit
import XCTest
import OilFindCore
@testable import OilFindApp

final class M17UITests: XCTestCase {
    func testSyntaxShortcutEscapeAndExamplePreserveSearchInput() {
        _ = NSApplication.shared
        let controller = SearchViewController(snapshot: true)
        _ = controller.view
        func event(_ key: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, characters: key == 44 ? "/" : "", charactersIgnoringModifiers: key == 44 ? "/" : "", isARepeat: false, keyCode: key)!
        }
        controller.searchField.text = "original"
        XCTAssertTrue(controller.handleKey(event(44, .command)))
        XCTAssertTrue(controller.syntaxVisible)
        XCTAssertTrue(controller.handleKey(event(53)))
        XCTAssertFalse(controller.syntaxVisible)
        XCTAssertEqual(controller.searchField.text, "original")
        controller.toggleSyntax(true)
        controller.view.frame = NSRect(origin: .zero, size: Theme.panelSize)
        controller.view.layoutSubtreeIfNeeded()
        let button = controller.syntax.subviews.compactMap { $0 as? NSButton }[3]
        for label in button.subviews.compactMap({ $0 as? NSTextField }) {
            let point = label.convert(NSPoint(x: label.bounds.midX, y: label.bounds.midY), to: controller.view)
            XCTAssertTrue(controller.syntax.hitTest(point) === button)
        }
        button.performClick(nil)
        XCTAssertFalse(controller.syntaxVisible)
        XCTAssertEqual(controller.searchField.text, "~/Desktop/ png")
    }
    func testLocalizationUsesExactDiagnosticAndCoverageCopy() {
        defer { L10n.snapshotChinese = nil }
        L10n.snapshotChinese = true
        XCTAssertEqual(L10n.text("coverage.title"), "未覆盖")
        XCTAssertEqual(L10n.text("coverage.volumes", "2"), "外置磁盘和网络卷：2 个（不在索引范围内）")
        XCTAssertEqual(L10n.explanation(.volume), "它在外置磁盘或网络卷上，不在索引范围内。")
        XCTAssertEqual(L10n.text("empty.noAccess"), "有些文件夹没有访问权限，其中的文件搜不到。")
        XCTAssertEqual(L10n.diagnostic(QueryDiagnostic(kind: .size)), "size: 的写法是 size:>10mb 或 size:1mb..5mb")
        L10n.snapshotChinese = false
        XCTAssertEqual(L10n.text("coverage.volumes", "2"), "External and network volumes: 2 (not indexed)")
        XCTAssertEqual(L10n.explanation(.volume), "It's on an external or network volume, which isn't indexed.")
        XCTAssertEqual(L10n.diagnostic(QueryDiagnostic(kind: .date)), "Write dm: as dm:today, dm:week or dm:2026-10-01")
        XCTAssertEqual(L10n.explanation(.cloud), "It's in a folder that's only in the cloud. Download it to this Mac to search it.")
    }
}
