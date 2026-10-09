import XCTest
import OilFindCore
@testable import OilFindApp

final class M9Tests: XCTestCase {
    func testT90MotionVariables() {
        let panel = Theme.Motion.panelIn, selection = Theme.Motion.selection, chip = Theme.Motion.chip
        XCTAssertTrue((0.25...0.50).contains(panel.settlingDuration), "panel: \(panel.settlingDuration)")
        XCTAssertTrue((0.12...0.30).contains(selection.settlingDuration), "selection: \(selection.settlingDuration)")
        XCTAssertTrue((0.15...0.35).contains(chip.settlingDuration), "chip: \(chip.settlingDuration)")
        XCTAssertLessThan(Theme.Motion.panelOut, panel.duration)
    }
    func testT91ToastText() {
        for (kind, zh, en) in [(ToastKind.copiedPath, "已拷贝：", "Copied: "), (.copiedName, "已拷贝名称：", "Copied name: "), (.trashed, "已移到废纸篓：", "Moved to Trash: ")] {
            XCTAssertEqual(Presentation.toastText(kind, value: "/Users/me/文档.pdf", chinese: true), zh + "/Users/me/文档.pdf")
            XCTAssertEqual(Presentation.toastText(kind, value: "/Users/me/文档.pdf", chinese: false), en + "/Users/me/文档.pdf")
        }
    }
    func testT92WelcomeState() {
        var skipped = WelcomeState(didFinishOnboarding: false, skippedFullDiskAccess: false, granted: false)
        XCTAssertNil(skipped.launch()); XCTAssertTrue(skipped.isShowing)
        XCTAssertEqual(skipped.finish(), true)
        XCTAssertTrue(skipped.didFinishOnboarding); XCTAssertTrue(skipped.skippedFullDiskAccess)
        XCTAssertEqual(skipped.indexLimited, true); XCTAssertNil(skipped.finish())

        var granted = WelcomeState(didFinishOnboarding: false, skippedFullDiskAccess: false, granted: true)
        XCTAssertEqual(granted.launch(), false); XCTAssertEqual(granted.indexLimited, false)
        XCTAssertNil(granted.finish()); XCTAssertTrue(granted.didFinishOnboarding)
        XCTAssertFalse(granted.skippedFullDiskAccess)

        var detected = WelcomeState(didFinishOnboarding: false, skippedFullDiskAccess: false, granted: false)
        XCTAssertNil(detected.launch()); XCTAssertNil(detected.permissionDetected(false))
        XCTAssertEqual(detected.permissionDetected(true), false)
        XCTAssertNil(detected.permissionDetected(true)); XCTAssertNil(detected.launch())
        XCTAssertEqual(detected.indexLimited, false); XCTAssertNil(detected.finish())
        XCTAssertFalse(detected.skippedFullDiskAccess)

        var closed = WelcomeState(didFinishOnboarding: false, skippedFullDiskAccess: false, granted: false)
        XCTAssertNil(closed.launch()); XCTAssertEqual(closed.close(), true)
        XCTAssertEqual(closed.didFinishOnboarding, skipped.didFinishOnboarding)
        XCTAssertEqual(closed.skippedFullDiskAccess, skipped.skippedFullDiskAccess)
        XCTAssertEqual(closed.indexLimited, skipped.indexLimited)

        for hasAccess in [false, true] {
            var returning = WelcomeState(didFinishOnboarding: true, skippedFullDiskAccess: false, granted: hasAccess)
            XCTAssertFalse(returning.isShowing); XCTAssertEqual(returning.launch(), !hasAccess)
        }
    }
}
