import AppKit
import XCTest
@testable import OilFind

final class LauncherRenderingTests: XCTestCase {
    func testSystemSettingsSymbolsExistOnCurrentSystem() {
        for setting in SystemSettingsCatalog.entries {
            XCTAssertNotNil(NSImage(systemSymbolName: setting.symbol, accessibilityDescription: nil),
                            "Missing symbol for \(setting.id): \(setting.symbol)")
        }
    }

    func testUnknownSymbolFallsBackToVisibleImage() {
        let image = Theme.symbol("oilfind.missing.symbol", size: 28, weight: .regular)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
        XCTAssertNotNil(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    func testEveryLauncherRowRendersIncludingMissingSettingSymbol() throws {
        _ = NSApplication.shared
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        let unavailable = SystemSetting(id: "unavailable", englishName: "Unavailable", chineseName: "不可用",
                                        symbol: "oilfind.missing.symbol", url: url)
        let rows: [LauncherRow] = SystemSettingsCatalog.entries.map(LauncherRow.setting) + [
            .setting(unavailable), .app(LauncherApp(name: "Example", path: "/Applications/Example.app")),
            .clipboard(ClipboardEntry(text: "Line one\nLine two")),
            .clipboard(ClipboardEntry(content: .files(["/Users/demo/Documents/Report.pdf", "/Users/demo/Documents/Assets"]))),
            .answer(ToolAnswer(expression: "150*20%", value: "30", detail: "")),
            .url(url), .web("example", url), .enableClipboard
        ]
        let view = ResultsView(frame: NSRect(x: 0, y: 0, width: Theme.panelSize.width, height: 300))
        view.show(SearchSnapshot(raw: "", scope: .all, leading: rows))
        let table = NSTableView()
        for (index, row) in rows.enumerated() {
            let cell = try XCTUnwrap(view.tableView(table, viewFor: nil, row: index))
            XCTAssertTrue(cell.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == row.title })
            XCTAssertNotNil(cell.subviews.compactMap { $0 as? NSImageView }.first?.image, row.identity)
        }
    }
}
