import Foundation
import XCTest
@testable import OilFindApp

final class WorkBuddyReplayTests: XCTestCase {
    func testResendForkNoticeSelectsEditedBranchAndItsAncestors() {
        let records: [[String: Any]] = [
            message("root", role: "user"),
            message("root-reply", parent: "root", role: "assistant"),
            message("old-user", parent: "root-reply", role: "user"),
            message("old-reply", parent: "old-user", role: "assistant"),
            ["type": "custom-title", "id": "title"],
            ["type": "resend-fork-notice", "id": "fork", "parentId": "root-reply"],
            message("edited-user", parent: "old-reply", role: "user"),
            message("edited-reply", parent: "edited-user", role: "assistant")
        ]

        XCTAssertEqual(WorkBuddyReplay.activeIndices(records), Set([0, 1, 6, 7]))
        XCTAssertEqual(records[6]["parentId"] as? String, "old-reply", "Selection must not rewrite source records")
    }

    func testContentFilterNoticeActivatesHistorySelectionAndKeepsEqualIDRows() {
        let records: [[String: Any]] = [
            message("discarded"),
            message("root", role: "user"),
            message("answer", parent: "root", role: "assistant"),
            message("answer", parent: "root", role: "assistant", providerData: ["contentFilterNotice": true])
        ]

        XCTAssertEqual(WorkBuddyReplay.activeIndices(records), Set([1, 2, 3]))
    }

    func testCompactAndSystemTeammateParentsAreRecoveredForBranchSelection() {
        let records: [[String: Any]] = [
            message("root", role: "user"),
            message("answer", parent: "compact", role: "assistant"),
            message("compact", parent: "answer", role: "user", providerData: ["isCompactInternal": true]),
            [
                "type": "message", "id": "teammate", "role": "user",
                "content": "<teammate-message from=\"worker\">internal note</teammate-message>"
            ],
            message("latest", parent: "teammate", role: "user", providerData: ["contentFilterNotice": true])
        ]

        XCTAssertEqual(WorkBuddyReplay.activeIndices(records), Set([0, 2, 3, 4]))
        XCTAssertEqual(records[2]["parentId"] as? String, "answer", "Compact recovery is an internal projection only")
    }

    func testVisibleTextKeepsOnlyUserAssistantTextAndDropsInternalContent() {
        XCTAssertEqual(WorkBuddyReplay.text([
            "type": "message", "role": "user",
            "content": [
                ["type": "input_text", "text": "visible prompt"],
                ["type": "reasoning", "text": "private reasoning"],
                ["type": "tool", "text": "tool arguments"]
            ]
        ]), "visible prompt")
        XCTAssertEqual(WorkBuddyReplay.text([
            "type": "message", "role": "assistant", "content": [["type": "output_text", "text": "visible answer"]]
        ]), "visible answer")
        XCTAssertEqual(WorkBuddyReplay.text([
            "type": "message", "role": "user",
            "content": "<system-reminder data-role=\"user-context\">private skill instructions</system-reminder>\n<user_query>visible prompt</user_query><image_local_path>/private/path</image_local_path>"
        ]), "visible prompt")
        XCTAssertEqual(WorkBuddyReplay.text([
            "type": "message", "role": "user", "content": "Please inspect <svg><path d=\"M0 0\" /></svg>."
        ]), "Please inspect <svg><path d=\"M0 0\" /></svg>.")

        let hidden: [[String: Any]] = [
            ["type": "message", "role": "user", "providerData": ["isMeta": true], "content": "meta-private"],
            ["type": "message", "role": "user", "providerData": ["isCompactInternal": true], "content": "compact-private"],
            ["type": "message", "role": "assistant", "providerData": ["compactType": "user-command"], "content": "compact-private"],
            ["type": "message", "role": "user", "content": "<compact-request>summarize</compact-request>"],
            ["type": "message", "role": "assistant", "content": "<conversation_history_summary>private</conversation_history_summary>"],
            ["type": "message", "role": "assistant", "content": "<system-reminder data-role=\"compact-summary\">private</system-reminder>"],
            ["type": "function_call_result", "role": "assistant", "content": "tool-private"]
        ]
        XCTAssertTrue(hidden.allSatisfy { WorkBuddyReplay.text($0).isEmpty })
    }

    private func message(
        _ id: String,
        parent: String? = nil,
        role: String = "assistant",
        providerData: [String: Any] = [:]
    ) -> [String: Any] {
        var result: [String: Any] = ["type": "message", "id": id, "role": role, "content": id]
        if let parent { result["parentId"] = parent }
        if !providerData.isEmpty { result["providerData"] = providerData }
        return result
    }
}
