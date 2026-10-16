import AppKit
import OilFindCore

final class AITopicSearchProvider: AdditionalSearchProvider {
    private let manager: AITopicManager
    private let icons = AITopicIcons()
    private var chinese: Bool { L10n.chinese }
    var onChange: (() -> Void)?
    var isEnabled: Bool { manager.isEnabled }
    var placeholder: String { L10n.text("topicsPlaceholder", chinese: chinese) }
    var title: String { L10n.text("topicsTitle", chinese: chinese) }
    var status: String? {
        manager.failed ? L10n.text("topicsSyncFailed", chinese: chinese) : manager.indexing ? L10n.text("topicsBuildingShort", chinese: chinese) : nil
    }
    init(manager: AITopicManager) {
        self.manager = manager
        manager.onChange = { [weak self] in self?.onChange?() }
        manager.onAvailabilityChange = { [weak self] in self?.onChange?() }
    }
    func visibilityChanged(_ visible: Bool) { manager.visibilityChanged(visible) }
    func backgroundIndexingChanged(_ busy: Bool) { manager.backgroundIndexingChanged(busy) }
    func availableItems(from items: [AdditionalSearchItem]) -> [AdditionalSearchItem] {
        guard isEnabled else { return [] }
        let scopes = Set(manager.enabledProviders.map(\.rawValue))
        return items.filter { item in item.availabilityScope.map(scopes.contains) ?? false }
    }
    func prepareSearch(_ query: Query, isCancelled: @escaping () -> Bool) -> () throws -> [AdditionalSearchItem] {
        let images = Dictionary(uniqueKeysWithValues: AITopicProvider.allCases.map { ($0, icons.image($0)) })
        let chinese = chinese
        let terms = AITopicIndex.fold(query.raw).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return { [manager] in
            let found = try manager.readSearch(query.raw, isCancelled: isCancelled)
            if isCancelled() { return [] }
            return found.topics.map { topic in
                let topicKey = topic.key
                let actions = { () -> [AdditionalSearchAction] in
                    let definitions: [(AdditionalSearchAction.Kind, String)] = [(.open, "topicsOpen"), (.copy, "topicsCopyResume"), (.copyName, "topicsCopyTitle")]
                    return definitions.map { (kind: AdditionalSearchAction.Kind, label: String) in
                        AdditionalSearchAction(kind: kind, title: L10n.text(label, chinese: chinese)) { completion in
                            manager.resolve(topicKey) { current in
                                guard let current else { completion(false); return }
                                switch kind {
                                case .open: completion(AITopicActions.open(current))
                                case .copy:
                                    AITopicActions.copyResume(current)
                                    completion(true)
                                case .copyName:
                                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(current.title, forType: .string); completion(true)
                                }
                            }
                        }
                    }
                }
                let project = topic.project.isEmpty ? "" : " · " + URL(fileURLWithPath: topic.project).lastPathComponent
                return AdditionalSearchItem(id: topicKey, title: topic.title.isEmpty ? L10n.text("topicsUntitled", chinese: chinese) : topic.title,
                    detail: topic.excerpt, location: topic.provider.name + project, modified: Date(timeIntervalSince1970: topic.modified),
                    icon: images[topic.provider]!, relevance: Self.relevance(topic, terms: terms), availabilityScope: topic.provider.rawValue, actions: actions)
            }
        }
    }
    private static func relevance(_ topic: AITopic, terms: [String]) -> Int32 {
        let title = AITopicIndex.fold(topic.title)
        guard !terms.isEmpty else { return 0 }
        let scores = terms.map { term -> Int in
            if title == term { return 1000 }
            if title.hasPrefix(term) { return 800 }
            if title.range(of: term) != nil { return 600 }
            return 250
        }
        let length = max(0, title.utf8.count - terms.reduce(0) { $0 + $1.utf8.count })
        let age = Date().timeIntervalSince1970 - topic.modified
        let recent = age <= 86400 ? 60 : age <= 604800 ? 45 : age <= 2592000 ? 30 : age <= 31536000 ? 10 : 0
        let average: Int = scores.reduce(0, +) / scores.count
        let lengthPenalty: Int = 2 * min(length, 64)
        let rank: Int = average - lengthPenalty + 60 + recent
        return Int32(rank)
    }
}
