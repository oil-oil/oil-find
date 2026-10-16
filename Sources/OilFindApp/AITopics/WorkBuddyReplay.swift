import Foundation

/// Selects and filters the visible portion of a WorkBuddy persisted transcript.
enum WorkBuddyReplay {
    private struct ReplayItem {
        let id: String?
        var parentID: String?
        var logicalParentID: String?
        let type: String?
        let role: String?
        let isMeta: Bool
        let skipRun: Bool
        let isCompactInternal: Bool
        let hasCompactType: Bool
        let hasContentFilterNotice: Bool
        let isSteer: Bool
        let isSystemTeammate: Bool

        var isCustom: Bool { Self.customTypes.contains(type ?? "") }
        var isCompactMessage: Bool {
            type == "message" && role == "user" && (isCompactInternal || hasCompactType)
        }

        private static let customTypes: Set<String> = [
            "custom-title", "ai-title", "file-history-snapshot", "summary", "topic",
            "goal-result", "goal-progress", "resend-fork-notice"
        ]
    }

    /// Returns indices for the active transcript while leaving the input records untouched.
    static func activeIndices(_ objects: [[String: Any]]) -> Set<Int> {
        var items = objects.map(makeItem)
        recoverLegacyParents(&items)

        let needsActiveBranch = items.contains { $0.hasContentFilterNotice }
            || items.contains { $0.type == "resend-fork-notice" }
            || hasSiblingRealUserParent(items)
        guard needsActiveBranch else {
            return Set(items.indices.filter { !items[$0].isCustom })
        }

        guard let initialTargetID = items.reversed().first(where: { $0.id != nil && !$0.isCustom })?.id else {
            return []
        }

        var targetID: String? = initialTargetID
        var selected = Set<Int>()
        var cursor = items.count - 1
        while cursor >= 0, let currentTargetID = targetID {
            guard items[cursor].id == currentTargetID else {
                cursor -= 1
                continue
            }

            var start = cursor
            while start > 0, items[start - 1].id == currentTargetID { start -= 1 }
            for index in start...cursor where !items[index].isCustom {
                selected.insert(index)
            }

            targetID = activeHopTarget(items, before: start, head: items[start])
            cursor = start - 1
        }
        return selected
    }

    /// Extracts searchable text from a visible user or assistant message.
    static func text(_ object: [String: Any]) -> String {
        guard object["type"] as? String == "message",
              let role = object["role"] as? String,
              role == "user" || role == "assistant" else { return "" }

        let providerData = object["providerData"] as? [String: Any] ?? [:]
        if role == "user", providerData["isMeta"] as? Bool == true { return "" }
        if providerData["isCompactInternal"] as? Bool == true || providerData["compactType"] is String {
            return ""
        }

        let body = visibleContentText(object["contentText"] ?? object["content"])
        let visibleBody = role == "user" ? stripSystemTags(body) : body
        let trimmed = visibleBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if isCompactSummaryReminder(body.trimmingCharacters(in: .whitespacesAndNewlines)) { return "" }
        if role == "user", isLegacyCompactPrompt(trimmed) { return "" }
        if role == "assistant", isLegacyCompactSummary(body) { return "" }
        if isSystemTeammate(object, providerData: providerData) { return "" }
        return visibleBody
    }

    private static func makeItem(_ object: [String: Any]) -> ReplayItem {
        let providerData = object["providerData"] as? [String: Any] ?? [:]
        let clientMeta = providerData["clientMeta"] as? [String: Any] ?? [:]
        let namespacedClientMeta = clientMeta["codebuddy.ai"] as? [String: Any] ?? [:]
        return ReplayItem(
            id: readString(object["id"]),
            parentID: readString(object["parentId"]),
            logicalParentID: readString(object["logicalParentId"]),
            type: object["type"] as? String,
            role: object["role"] as? String,
            isMeta: providerData["isMeta"] as? Bool == true,
            skipRun: providerData["skipRun"] as? Bool == true,
            isCompactInternal: providerData["isCompactInternal"] as? Bool == true,
            hasCompactType: providerData["compactType"] is String,
            hasContentFilterNotice: providerData["contentFilterNotice"] as? Bool == true,
            isSteer: namespacedClientMeta["queueOrigin"] as? String == "steer",
            isSystemTeammate: isSystemTeammate(object, providerData: providerData)
        )
    }

    private static func recoverLegacyParents(_ items: inout [ReplayItem]) {
        var ids = Set<String>()
        var itemByID: [String: Int] = [:]
        for (index, item) in items.enumerated() {
            guard let id = item.id else { continue }
            ids.insert(id)
            // Dictionary assignment intentionally preserves the last record for duplicate IDs.
            itemByID[id] = index
        }

        for index in items.indices {
            let item = items[index]
            guard let id = item.id else { continue }
            let parentID = item.parentID
            let brokenParent = parentID == nil || parentID == id || !ids.contains(parentID ?? "")
            let cyclicCompactParent = parentID.map {
                item.isCompactMessage && parentChainReaches($0, id, items: items, itemByID: itemByID)
            } ?? false
            guard brokenParent || cyclicCompactParent,
                  item.logicalParentID == nil,
                  item.isCompactMessage || item.isSystemTeammate,
                  let previousID = findPreviousID(before: index, currentID: id, items: items, itemByID: itemByID) else {
                continue
            }

            if item.isCompactMessage {
                items[index].parentID = nil
                items[index].logicalParentID = previousID
            } else {
                items[index].parentID = previousID
            }
        }
    }

    private static func findPreviousID(
        before index: Int,
        currentID: String,
        items: [ReplayItem],
        itemByID: [String: Int]
    ) -> String? {
        guard index > 0 else { return nil }
        for candidateIndex in stride(from: index - 1, through: 0, by: -1) {
            let candidate = items[candidateIndex]
            guard let id = candidate.id, id != currentID, !candidate.isCustom else { continue }
            if parentChainReaches(id, currentID, items: items, itemByID: itemByID) { continue }
            return id
        }
        return nil
    }

    private static func parentChainReaches(
        _ startID: String,
        _ targetID: String,
        items: [ReplayItem],
        itemByID: [String: Int]
    ) -> Bool {
        var cursor: String? = startID
        var seen = Set<String>()
        while let id = cursor, seen.insert(id).inserted {
            if id == targetID { return true }
            cursor = itemByID[id].flatMap { items[$0].parentID }
        }
        return false
    }

    private static func activeHopTarget(_ items: [ReplayItem], before index: Int, head: ReplayItem) -> String? {
        if isRealUserMessage(head), let forkNotice = nearestPreviousForkNotice(in: items, before: index) {
            return forkNotice.parentID
        }
        return head.parentID ?? head.logicalParentID
    }

    private static func nearestPreviousForkNotice(in items: [ReplayItem], before index: Int) -> ReplayItem? {
        guard index > 0 else { return nil }
        for cursor in stride(from: index - 1, through: 0, by: -1) {
            let item = items[cursor]
            if item.type == "resend-fork-notice" { return item }
            if isHopGap(item) { continue }
            return nil
        }
        return nil
    }

    private static func isHopGap(_ item: ReplayItem) -> Bool {
        (item.isCustom && item.type != "resend-fork-notice") || item.isSystemTeammate
    }

    private static func isRealUserMessage(_ item: ReplayItem) -> Bool {
        item.type == "message" && item.role == "user"
            && !item.skipRun && !item.isMeta && !item.isCompactInternal && !item.hasCompactType
            && !item.isSteer && !item.isSystemTeammate
    }

    private static func hasSiblingRealUserParent(_ items: [ReplayItem]) -> Bool {
        var seen = Set<String>()
        for item in items where isRealUserMessage(item) {
            guard let parentID = item.parentID else { continue }
            if !seen.insert(parentID).inserted { return true }
        }
        return false
    }

    private static func isSystemTeammate(_ object: [String: Any], providerData: [String: Any]) -> Bool {
        if let teammate = providerData["teammateMessage"] as? [String: Any], teammate["from"] is String {
            return true
        }
        let body = rawText(object["contentText"] ?? object["content"])
        return matches(#"^\s*<teammate-message\b[^>]*>[\s\S]*</teammate-message>\s*$"#, in: body, caseInsensitive: true)
    }

    private static func visibleContentText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        guard let blocks = value as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            guard let type = block["type"] as? String,
                  ["text", "input_text", "output_text"].contains(type) else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
    }

    private static func rawText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let object = value as? [String: Any] { return object["text"] as? String ?? "" }
        if let blocks = value as? [Any] { return blocks.map { rawText($0) }.joined() }
        return ""
    }

    private static func stripSystemTags(_ text: String) -> String {
        let withoutReminders = replace(#"<system-reminder[^>]*>[\s\S]*?</system-reminder>\s*"#, in: text, with: "")
        let withoutImages = replace(#"<image_local_path>[\s\S]*?</image_local_path>\s*"#, in: withoutReminders, with: "")
        return replace(#"<user_query>([\s\S]*?)</user_query>"#, in: withoutImages, with: "$1")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isLegacyCompactPrompt(_ text: String) -> Bool {
        let patterns = [
            #"^\s*<compact-request\b"#,
            #"^\s*Your task is to write a detailed and structured summary[\s\S]*<conversation_history_summary\b"#,
            #"^(?:\s|\*)*Your ONLY output should be the\s+<conversation_history_summary>[\s\S]*<conversation_history_summary\b"#,
            #"^(?:\s|\*)*Your task is to create a detailed summary of the conversation so far[\s\S]*<conversation_history_summary\b"#,
            #"^\s*Please continue with the conversation based on the summarized context above\b"#,
            #"^\s*Please\s+summarize\s+the\s+conversation\s+above[\s\S]*<(?:conversation_history_summary|cb_summary)\b"#
        ]
        return patterns.contains { matches($0, in: text, caseInsensitive: true) }
    }

    private static func isLegacyCompactSummary(_ text: String) -> Bool {
        if matches(#"^\s*<conversation_history_summary\b"#, in: text, caseInsensitive: true) {
            return true
        }
        guard matches(#"^\s*<cb_summary\b"#, in: text, caseInsensitive: true),
              matches(#"</cb_summary>\s*$"#, in: text, caseInsensitive: true) else { return false }
        let body = replace(#"^\s*<cb_summary\b[^>]*>"#, in: text, with: "")
        return matches(#"^\s*<previous_tool_call\b"#, in: body, caseInsensitive: true)
            || matches(#"<previous_(?:tool_call|user_message)\b"#, in: body, caseInsensitive: true)
            || matches(#"<previous_assistant_message\b"#, in: body, caseInsensitive: true)
    }

    private static func isCompactSummaryReminder(_ text: String) -> Bool {
        matches(#"^<system-reminder\b[^>]*data-role=[\"']compact-summary[\"']"#, in: text, caseInsensitive: true)
    }

    private static func readString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func matches(_ pattern: String, in text: String, caseInsensitive: Bool = false) -> Bool {
        let options: String.CompareOptions = caseInsensitive ? [.regularExpression, .caseInsensitive] : [.regularExpression]
        return text.range(of: pattern, options: options) != nil
    }

    private static func replace(_ pattern: String, in text: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
}
