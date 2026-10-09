import XCTest
@testable import OilFindApp

final class ResultRefreshTests: XCTestCase {
    func testIdenticalItemsKeepSelectionAndViewport() {
        XCTAssertEqual(resultRefreshAction(oldItems: [7, 9, 12], newItems: [7, 9, 12], sameStore: true,
                                           sameVersion: true, scrolling: false, dragging: false), .replaceResult)
        XCTAssertEqual(resultRefreshAction(oldItems: [7, 9, 12], newItems: [7, 9, 12], sameStore: true,
                                           sameVersion: false, scrolling: false, dragging: false), .reloadVisibleRows)
        XCTAssertEqual(resultRefreshAction(oldItems: [], newItems: [], sameStore: true,
                                           sameVersion: false, scrolling: false, dragging: false), .reloadVisibleRows)
    }
    func testChangedItemsRestoreSelectionAndViewport() {
        let variants: [[UInt32]] = [[7, 12], [12, 9, 7], [7, 9, 12, 15], []]
        for items in variants {
            XCTAssertEqual(resultRefreshAction(oldItems: [7, 9, 12], newItems: items, sameStore: true,
                                               sameVersion: false, scrolling: false, dragging: false), .reloadPreservingViewport)
        }
        // IDs in a replacement store do not identify the same files.
        XCTAssertEqual(resultRefreshAction(oldItems: [7, 9, 12], newItems: [7, 9, 12], sameStore: false,
                                           sameVersion: true, scrolling: false, dragging: false), .reloadPreservingViewport)
    }
    func testScrollingAndDraggingDeferEveryRefresh() {
        let variants: [[UInt32]] = [[7, 9, 12], [7, 12]]
        for (scrolling, dragging) in [(true, false), (false, true), (true, true)] {
            for items in variants {
                XCTAssertEqual(resultRefreshAction(oldItems: [7, 9, 12], newItems: items, sameStore: true,
                                                   sameVersion: false, scrolling: scrolling, dragging: dragging), .deferRefresh)
            }
            XCTAssertEqual(resultRefreshAction(oldItems: [7], newItems: [7], sameStore: true,
                                               sameVersion: true, scrolling: scrolling, dragging: dragging), .deferRefresh)
        }
    }
}
