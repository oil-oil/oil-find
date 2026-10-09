import Foundation

enum AppLanguage: String, CaseIterable {
    case system
    case chinese = "zh"
    case english = "en"

    static let preferenceKey = "appLanguage"
    static func load(from defaults: UserDefaults = .standard) -> AppLanguage {
        defaults.string(forKey: preferenceKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }
    func usesChinese(systemLanguages: [String] = Locale.preferredLanguages) -> Bool {
        switch self {
        case .system: return systemLanguages.first?.lowercased().hasPrefix("zh") == true
        case .chinese: return true
        case .english: return false
        }
    }
    var title: String {
        switch self {
        case .system: return L10n.text("settings.language.system")
        case .chinese: return "中文"
        case .english: return "English"
        }
    }
}
