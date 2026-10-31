import Foundation

final class RecentQueries {
    private let defaults: UserDefaults
    private let key = "recentSearches"
    init(defaults: UserDefaults) { self.defaults = defaults }
    var entries: [String] { defaults.stringArray(forKey: key) ?? [] }
    func add(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        defaults.set(Array(([query] + entries.filter { $0 != query }).prefix(10)), forKey: key)
    }
    func clear() { defaults.removeObject(forKey: key) }
}
