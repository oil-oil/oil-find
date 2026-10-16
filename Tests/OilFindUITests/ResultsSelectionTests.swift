import AppKit
import QuartzCore
import XCTest
import OilFindCore
@testable import OilFindApp

final class ResultsSelectionTests: XCTestCase {
    func testCategoryMotionSurvivesSearchRefreshAndLayout() throws {
        _ = NSApplication.shared
        if Theme.Motion.reduced { throw XCTSkip("Category motion respects Reduce Motion") }
        final class Provider: AdditionalSearchProvider {
            var isEnabled = true
            let title = "AI Topics"
            var onChange: (() -> Void)?
            func prepareSearch(_ query: Query, isCancelled: @escaping () -> Bool) -> () throws -> [AdditionalSearchItem] { { [] } }
            func visibilityChanged(_ visible: Bool) { }
        }
        let provider = Provider(), controller = SearchViewController(snapshot: true)
        controller.additionalSearchProvider = provider
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 800, height: 560), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        window.orderFrontRegardless(); defer { window.close() }
        controller.view.layoutSubtreeIfNeeded()
        let filters = controller.filters
        let plate = try XCTUnwrap(filters.subviews.compactMap { $0 as? TintPlate }.first)
        let layer = try XCTUnwrap(plate.layer)
        for index in [1, 8, FilterBar.names.count, 0] {
            filters.select(index)
            let spring = try XCTUnwrap(layer.animation(forKey: "position") as? CASpringAnimation)
            XCTAssertEqual(spring.stiffness, Theme.Motion.chip.stiffness)
            XCTAssertEqual(spring.damping, Theme.Motion.chip.damping)
            controller.view.layoutSubtreeIfNeeded()
            XCTAssertNotNil(layer.animation(forKey: "position"), "Layout must not snap an active category transition to its endpoint")
            provider.onChange?(); controller.view.layoutSubtreeIfNeeded()
            let afterRefresh = try XCTUnwrap(layer.animation(forKey: "position") as? CASpringAnimation)
            XCTAssertEqual(afterRefresh.fromValue as? NSValue, spring.fromValue as? NSValue)
            let selected = try XCTUnwrap(filters.subviews.compactMap { $0 as? ChromeButton }.first { $0.active })
            XCTAssertEqual(plate.frame, selected.frame)
            XCTAssertTrue(selected.subviews.compactMap { $0 as? NSTextField }.allSatisfy { $0.layer?.animation(forKey: "opacity") != nil })
        }
    }
    func testPointerSelectionSnapsAndKeyboardSelectionKeepsMotion() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OilFindSelection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<12 { try Data().write(to: root.appendingPathComponent("row\(index).txt")) }
        let config = IndexConfig(rootPath: root.path)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        let controller = SearchViewController(snapshot: true)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Theme.panelSize),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }
        try controller.prepareSnapshot(state: "results", query: "row", options: .init(sort: .name), store: store, selection: 0)
        controller.view.layoutSubtreeIfNeeded()
        let results = controller.results
        let scroll = try XCTUnwrap(results.subviews.compactMap { $0 as? NSScrollView }.first)
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        let plate = try XCTUnwrap(table.subviews.compactMap { $0 as? TintPlate }.first { !$0.isHidden && $0.alphaValue > 0 })
        let layer = try XCTUnwrap(plate.layer)
        XCTAssertEqual(table.numberOfRows, 12)
        XCTAssertEqual(plate.frame, table.rect(ofRow: 0).insetBy(dx: 10, dy: 1))
        XCTAssertNil(layer.animation(forKey: "position"))

        func key(_ code: UInt16, command: Bool = false, repeating: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command ? .command : [],
                             timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "",
                             charactersIgnoringModifiers: "", isARepeat: repeating, keyCode: code)!
        }
        func assertKeyboardMotion(repeating: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws {
            if Theme.Motion.reduced { XCTAssertNil(layer.animation(forKey: "position"), file: file, line: line); return }
            let animation = try XCTUnwrap(layer.animation(forKey: "position") as? CABasicAnimation, file: file, line: line)
            if repeating {
                XCTAssertFalse(animation is CASpringAnimation, file: file, line: line)
                XCTAssertEqual(animation.duration, Theme.Motion.selectionRepeat, file: file, line: line)
                XCTAssertEqual(animation.timingFunction, CAMediaTimingFunction(name: .linear), file: file, line: line)
            } else {
                XCTAssertTrue(animation is CASpringAnimation, file: file, line: line)
            }
        }
        // Exercise arrows, Page Up/Down, Command-Up/Down, and key repeat through the controller.
        for event in [key(125), key(126), key(121), key(116), key(125, command: true), key(126, command: true)] {
            let previous = results.selectedRow
            XCTAssertTrue(controller.handleKey(event))
            XCTAssertNotEqual(results.selectedRow, previous)
            try assertKeyboardMotion()
        }
        XCTAssertTrue(controller.handleKey(key(125, repeating: true)))
        try assertKeyboardMotion(repeating: true)

        func mouse(_ type: NSEvent.EventType, row: Int) -> NSEvent {
            let rect = table.rect(ofRow: row)
            return NSEvent.mouseEvent(with: type, location: table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil),
                                      modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                      clickCount: 1, pressure: 1)!
        }
        // Observe the plate during selection notification, before mouse tracking returns.
        var pointerNotifications = 0
        results.onSelection = {
            pointerNotifications += 1
            XCTAssertEqual(plate.frame, table.rect(ofRow: results.selectedRow).insetBy(dx: 10, dy: 1))
            XCTAssertNil(layer.animation(forKey: "position"))
            XCTAssertNil(layer.animation(forKey: "bounds"))
        }
        NSApplication.shared.postEvent(mouse(.leftMouseUp, row: 4), atStart: true)
        table.mouseDown(with: mouse(.leftMouseDown, row: 4))
        XCTAssertEqual(results.selectedRow, 4)
        XCTAssertEqual(pointerNotifications, 1)
        results.onSelection = nil
        XCTAssertTrue(controller.handleKey(key(125)))
        try assertKeyboardMotion()
        // Clicking the keyboard's current target must also stop its in-flight motion.
        NSApplication.shared.postEvent(mouse(.leftMouseUp, row: 5), atStart: true)
        table.mouseDown(with: mouse(.leftMouseDown, row: 5))
        XCTAssertEqual(results.selectedRow, 5)
        XCTAssertEqual(plate.frame, table.rect(ofRow: 5).insetBy(dx: 10, dy: 1))
        XCTAssertNil(layer.animation(forKey: "position"))
        XCTAssertNil(layer.animation(forKey: "bounds"))
        _ = table.menu(for: mouse(.rightMouseDown, row: 2))
        XCTAssertEqual(results.selectedRow, 2)
        XCTAssertEqual(plate.frame, table.rect(ofRow: 2).insetBy(dx: 10, dy: 1))
        XCTAssertNil(layer.animation(forKey: "position"))
        XCTAssertNil(layer.animation(forKey: "bounds"))
        results.select(3)
        try assertKeyboardMotion()
        _ = table.menu(for: mouse(.rightMouseDown, row: 3))
        XCTAssertEqual(results.selectedRow, 3)
        XCTAssertEqual(plate.frame, table.rect(ofRow: 3).insetBy(dx: 10, dy: 1))
        XCTAssertNil(layer.animation(forKey: "position"))
        XCTAssertNil(layer.animation(forKey: "bounds"))
    }
}
