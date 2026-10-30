import XCTest
@testable import OilFindCore

final class M3Tests: XCTestCase {
    func testT40HighlightRanges() {
        func ranges(_ name: String, _ query: String) -> [NSRange] {
            Presentation.highlightRanges(name: name, query: Query.parse(query))
        }
        XCTAssertEqual(ranges("README.md", "readme"), [NSRange(location: 0, length: 6)])
        XCTAssertEqual(ranges("readme-readme.md", "readme md"), [NSRange(location: 0, length: 6), NSRange(location: 7, length: 6), NSRange(location: 14, length: 2)])
        XCTAssertEqual(ranges("banana", "ana nan"), [NSRange(location: 1, length: 5)])
        XCTAssertEqual(ranges("aAaA", "aaa"), [NSRange(location: 0, length: 4)])
        XCTAssertEqual(ranges("📄项目文档.md", "文档"), [NSRange(location: 4, length: 2)])
        XCTAssertEqual(ranges("readme-final.md", "read*?final.md"), [NSRange(location: 0, length: 4), NSRange(location: 7, length: 8)])
        XCTAssertEqual(ranges("README.md", "!readme ext:md path:README regex:README"), [])
        XCTAssertEqual(ranges("README.md", "case:readme"), [])
        XCTAssertEqual(ranges("README-readme.md", "case:readme"), [NSRange(location: 7, length: 6)])
        XCTAssertEqual(ranges("README-readme.md", "case:README"), [NSRange(location: 0, length: 6)])
        XCTAssertEqual(ranges("项目文档.md", "xmwd"), [])
        XCTAssertEqual(ranges("readme", "read|!me"), [NSRange(location: 0, length: 4)])
    }

    func testT41DateText() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        }
        let now = date(2026, 9, 30, 16)
        let examples: [(Date, String, String)] = [
            (date(2026, 9, 30, 14, 32), "今天 14:32", "Today 14:32"),
            (date(2026, 9, 29, 9, 10), "昨天 09:10", "Yesterday 09:10"),
            (date(2026, 3, 12), "3月12日", "Mar 12"),
            (date(2024, 3, 12), "2024/3/12", "2024/3/12")
        ]
        for (value, zh, en) in examples {
            XCTAssertEqual(Presentation.dateText(value, now: now, calendar: calendar, chinese: true), zh)
            XCTAssertEqual(Presentation.dateText(value, now: now, calendar: calendar, chinese: false), en)
        }
        for chinese in [true, false] {
            XCTAssertEqual(Presentation.dateText(date(2025, 12, 31, 23, 59), now: date(2026, 1, 1), calendar: calendar, chinese: chinese), chinese ? "昨天 23:59" : "Yesterday 23:59")
            XCTAssertEqual(Presentation.dateText(date(2025, 12, 30), now: date(2026, 1, 1), calendar: calendar, chinese: chinese), "2025/12/30")
            XCTAssertEqual(Presentation.dateText(date(2026, 9, 30), now: date(2026, 9, 30, 0, 1), calendar: calendar, chinese: chinese), chinese ? "今天 00:00" : "Today 00:00")
        }
    }

    func testT42Abbreviate() {
        XCTAssertEqual(Presentation.abbreviate(path: "/Users/me", home: "/Users/me"), "~")
        XCTAssertEqual(Presentation.abbreviate(path: "/Users/me/Documents/a", home: "/Users/me"), "~/Documents/a")
        XCTAssertEqual(Presentation.abbreviate(path: "/Users/me-too/a", home: "/Users/me"), "/Users/me-too/a")
        XCTAssertEqual(Presentation.abbreviate(path: "/", home: "/Users/me"), "/")
    }

    func testT43Formatting() {
        XCTAssertEqual(Presentation.countText(0), "0")
        XCTAssertEqual(Presentation.countText(1_234_567), "1,234,567")
        XCTAssertEqual(Presentation.elapsedText(1.25), "1.2")
        XCTAssertEqual(Presentation.elapsedText(9.9), "9.9")
        XCTAssertEqual(Presentation.elapsedText(10), "10")
        XCTAssertEqual(Presentation.elapsedText(12.6), "13")
        for bytes in [UInt64(0), 1, 1_024, 1_000_000, UInt64.max] {
            XCTAssertEqual(Presentation.sizeText(bytes), ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file))
        }
    }
}
