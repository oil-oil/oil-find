import Foundation

public enum SettingsPreferences {
    public static func register(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            "hotKeyCode": Int(Shortcut.defaultKeyCode), "hotKeyModifiers": Int(Shortcut.defaultModifiers),
            "pinyinEnabled": true, "userExcludedPaths": [String](), "skippedFullDiskAccess": false, "didFinishOnboarding": false,
            "calculatorEnabled": true, "webSearchEnabled": true, "webSearchEngine": "duckDuckGo",
            "indexDependencyDirs": false, "indexPackageContents": false, "indexUserLibrary": false, "indexSystemDirs": false,
            "sortKey": "relevance", "sortAscending": false
        ])
    }
    public static func searchOptions(in defaults: UserDefaults = .standard) -> SearchOptions {
        let key: SortKey
        switch defaults.string(forKey: "sortKey") {
        case "name": key = .name
        case "modified": key = .modified
        case "size": key = .size
        default: key = .relevance
        }
        return SearchOptions(sort: key, ascending: defaults.bool(forKey: "sortAscending"), pinyin: defaults.bool(forKey: "pinyinEnabled"))
    }
    public static func indexConfig(limited: Bool, in defaults: UserDefaults = .standard) -> IndexConfig {
        var config = IndexConfig.standard(limited: limited)
        config.indexDependencyDirs = defaults.bool(forKey: "indexDependencyDirs")
        config.indexPackageContents = defaults.bool(forKey: "indexPackageContents")
        config.indexUserLibrary = defaults.bool(forKey: "indexUserLibrary")
        config.indexSystemDirs = defaults.bool(forKey: "indexSystemDirs")
        config.userExcludedPaths = ExcludedFolders.adding(defaults.stringArray(forKey: "userExcludedPaths") ?? [], to: [])
        return config
    }
}

public enum ExcludedFolders {
    // Lexical normalization preserves the spelling used by the scanner and FSEvents.
    public static func normalized(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        return IndexConfig(rootPath: path).rootPath.precomposedStringWithCanonicalMapping
    }
    public static func contains(_ parent: String, path: String) -> Bool {
        guard let parent = normalized(parent), let path = normalized(path) else { return false }
        return parent == "/" || path == parent || path.hasPrefix(parent + "/")
    }
    public static func adding(_ paths: [String], to existing: [String]) -> [String] {
        var result: [String] = []
        for value in existing + paths {
            guard let path = normalized(value), !result.contains(where: { contains($0, path: path) }) else { continue }
            // A newly selected ancestor replaces its redundant descendants.
            result.removeAll { contains(path, path: $0) }
            result.append(path)
        }
        return result
    }
}
