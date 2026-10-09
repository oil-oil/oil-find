import AppKit
import Combine
import CoreServices
import Foundation
import OilFindCore

struct LauncherApp: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let bundleID: String?
    let aliases: [String]
    let lastLaunched: Date?

    init(name: String, path: String, bundleID: String? = nil, aliases: [String] = [], lastLaunched: Date? = nil) {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        self.id = canonical
        self.name = name
        self.path = canonical
        self.bundleID = bundleID
        self.aliases = aliases
        self.lastLaunched = lastLaunched
    }
}

enum LauncherMatch {
    static func rank(_ query: String, in strings: [String]) -> Int? {
        let normalizedQuery = normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let words = normalizedQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return 0 }
        let candidates = strings.map(normalize).filter { !$0.isEmpty }
        if candidates.contains(normalizedQuery) { return 0 }
        var overall = 0
        for word in words {
            var best: Int?
            for candidate in candidates {
                let rank: Int?
                if candidate == word { rank = 0 }
                else if candidate.hasPrefix(word) { rank = 1 }
                else if candidate.contains(word) { rank = 2 }
                else { rank = nil }
                if let rank { best = min(best ?? rank, rank) }
            }
            guard let best else { return nil }
            overall = max(overall, best)
        }
        return overall
    }

    private static func normalize<S: StringProtocol>(_ value: S) -> String {
        String(value).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }
}

final class ApplicationCatalog: ObservableObject {
    @Published private(set) var apps: [LauncherApp] = []
    @Published private(set) var revision = 0

    private let defaults: UserDefaults
    private let snapshot: Bool
    private let queue = DispatchQueue(label: "com.oiloil.find.application-catalog", qos: .utility)
    private let stateQueue = DispatchQueue(label: "com.oiloil.find.application-catalog.state")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var stream: FSEventStreamRef?
    private var pendingRefresh: DispatchWorkItem?
    private var excluded: [String] = []
    private var launched: [String: Date] = [:]
    private var stopped = true
    private let recencyKey = "launcher.application.lastLaunched"

    init(snapshot: Bool = false, defaults: UserDefaults = .standard) {
        self.snapshot = snapshot
        self.defaults = defaults
        self.launched = defaults.dictionary(forKey: recencyKey) as? [String: Date] ?? [:]
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        stop()
    }

    func start(excludedPaths: [String] = []) {
        guard !snapshot else { return }
        let shouldStart = stateQueue.sync { () -> Bool in
            excluded = Self.canonicalPaths(excludedPaths)
            guard stopped else { return false }
            stopped = false
            return true
        }
        queue.async { [weak self] in
            guard let self else { return }
            guard self.stateQueue.sync(execute: { !self.stopped }) else { return }
            self.refreshOnQueue()
            if shouldStart, self.stateQueue.sync(execute: { !self.stopped }) { self.startWatching() }
        }
    }

    func stop() {
        stateQueue.sync {
            stopped = true
            pendingRefresh?.cancel()
            pendingRefresh = nil
        }
        let cleanup = { [self] in
            if let stream = self.stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { cleanup() }
        else { queue.sync(execute: cleanup) }
    }

    func refresh(excludedPaths: [String]) {
        let paths = Self.canonicalPaths(excludedPaths)
        stateQueue.sync { excluded = paths }
        if snapshot { return }
        coalesceRefresh()
    }

    func search(_ query: String) -> [LauncherApp] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return apps.sorted { recencyOrder($0, $1) } }
        return apps.compactMap { app -> (LauncherApp, Int)? in
            guard let rank = LauncherMatch.rank(query, in: [app.name] + app.aliases + [app.bundleID ?? ""]) else { return nil }
            return (app, rank)
        }.sorted { lhs, rhs in lhs.1 == rhs.1 ? recencyOrder(lhs.0, rhs.0) : lhs.1 < rhs.1 }.map(\.0)
    }

    func recordLaunch(_ app: LauncherApp) {
        let date = Date()
        stateQueue.sync { launched[app.id] = date; defaults.set(launched, forKey: recencyKey) }
        publish(apps.map { $0.id == app.id ? LauncherApp(name: $0.name, path: $0.path, bundleID: $0.bundleID, aliases: $0.aliases, lastLaunched: date) : $0 })
    }

    func prepareSnapshot(_ apps: [LauncherApp]) { publish(Self.withSearchAliases(apps, launched: [:])) }

    private func recencyOrder(_ lhs: LauncherApp, _ rhs: LauncherApp) -> Bool {
        switch (lhs.lastLaunched, rhs.lastLaunched) {
        case let (a?, b?): return a == b ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending : a > b
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func refreshOnQueue() {
        let exclusions = stateQueue.sync { excluded }
        let found = Self.scan(excludedPaths: exclusions)
        let recency = stateQueue.sync { launched }
        publish(Self.withSearchAliases(found, launched: recency))
    }

    private func publish(_ newApps: [LauncherApp]) {
        let update = { [weak self] in
            guard let self else { return }
            self.apps = newApps
            self.revision &+= 1
        }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }

    private static func canonicalPaths(_ paths: [String]) -> [String] {
        paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    private static func isExcluded(_ path: String, exclusions: [String]) -> Bool {
        exclusions.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    static func scan(roots: [URL]? = nil, excludedPaths: [String] = []) -> [LauncherApp] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let scanRoots = roots ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications"), URL(fileURLWithPath: "/System/Applications")]
        var result: [LauncherApp] = []
        var seen = Set<String>()
        for root in scanRoots where fm.fileExists(atPath: root.path) {
            guard !isExcluded(root.path, exclusions: excludedPaths) else { continue }
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .nameKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            while let url = enumerator.nextObject() as? URL {
                let path = url.standardizedFileURL.path
                if isExcluded(path, exclusions: excludedPaths) { enumerator.skipDescendants(); continue }
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isSymbolicLink != true else { enumerator.skipDescendants(); continue }
                guard url.pathExtension.lowercased() == "app", values.isDirectory == true else { continue }
                enumerator.skipDescendants()
                guard let bundle = Bundle(url: url) else { continue }
                let pathID = url.standardizedFileURL.path
                guard seen.insert(pathID).inserted else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                let raw = bundle.infoDictionary ?? [:]
                let localized = bundle.localizedInfoDictionary ?? [:]
                let localizedStrings = localizedInfoPlistStrings(in: url)
                let bilingualNames = [raw["CFBundleDisplayName"], localized["CFBundleDisplayName"], raw["CFBundleName"],
                                      localized["CFBundleName"], url.deletingPathExtension().lastPathComponent].compactMap { $0 as? String }
                    + localizedStrings
                result.append(LauncherApp(name: name, path: pathID, bundleID: bundle.bundleIdentifier, aliases: bilingualNames))
            }
        }
        return result.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
    }

    private static func localizedInfoPlistStrings(in bundleURL: URL) -> [String] {
        let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let localizations = ["en", "en_GB", "zh_CN", "zh-Hans", "zh_Hans", "zh"]
        var values: [String] = []
        for localization in localizations {
            let file = resources.appendingPathComponent(localization + ".lproj/InfoPlist.strings")
            guard let data = try? Data(contentsOf: file),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let dictionary = plist as? [String: Any] else { continue }
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let value = dictionary[key] as? String, !value.isEmpty {
                    values.append(value)
                }
            }
        }
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func withSearchAliases(_ apps: [LauncherApp], launched: [String: Date]) -> [LauncherApp] {
        apps.map { app in
            let name = app.name
            var aliases = Array(Set(app.aliases.filter { $0 != app.name }))
            for source in [app.name] + aliases {
                let latin = source.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false)
                if let latin, latin != source { aliases.append(latin) }
                guard source.unicodeScalars.contains(where: { $0.value >= 0x4e00 && $0.value <= 0x9fff }) else { continue }
                var full: [UInt8] = [], initials: [UInt8] = []
                let hasPinyin = Array(source.utf8).withUnsafeBufferPointer { bytes in
                    Pinyin.shared.keys(for: bytes, full: &full, initials: &initials)
                }
                if hasPinyin {
                    aliases.append(String(decoding: full, as: UTF8.self))
                    aliases.append(String(decoding: initials, as: UTF8.self))
                }
            }
            if let bundleID = app.bundleID { aliases.append(bundleID) }
            return LauncherApp(name: name, path: app.path, bundleID: app.bundleID,
                               aliases: Array(Set(aliases)).sorted(), lastLaunched: launched[app.id] ?? app.lastLaunched)
        }
    }

    private func startWatching() {
        let roots = ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path, "/System/Applications"]
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        guard let stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            let catalog = Unmanaged<ApplicationCatalog>.fromOpaque(info).takeUnretainedValue()
            catalog.coalesceRefresh()
        }, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
        UInt32(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)) else { return }
        guard stateQueue.sync(execute: { !stopped }) else {
            FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        if !FSEventStreamStart(stream) { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
    }

    private func coalesceRefresh() {
        stateQueue.sync {
            guard !stopped else { return }
            pendingRefresh?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.refreshOnQueue() }
            pendingRefresh = item
            queue.asyncAfter(deadline: .now() + 0.35, execute: item)
        }
    }
}

struct SystemSetting: Identifiable, Equatable {
    let id: String
    private let englishName: String
    private let chineseName: String
    private let localizedSubtitle: String
    var subtitle: String { L10n.relocalized(localizedSubtitle) ?? localizedSubtitle }
    let symbol: String
    let aliases: [String]
    let url: URL
    let fallbackURL: URL
    let breadcrumb: String

    var name: String { L10n.chinese ? chineseName : englishName }
    static var accessibility: SystemSetting { SystemSettingsCatalog.entries.first { $0.id == "accessibility" }! }

    init(id: String, englishName: String, chineseName: String, subtitle: String = "", symbol: String,
         aliases: [String] = [], url: URL, fallbackURL: URL? = nil, breadcrumb: String = "") {
        self.id = id; self.englishName = englishName; self.chineseName = chineseName; self.localizedSubtitle = subtitle
        var indexedAliases = [englishName, chineseName] + aliases
        for source in indexedAliases {
            var full: [UInt8] = [], initials: [UInt8] = []
            let hasPinyin = Array(source.utf8).withUnsafeBufferPointer { bytes in
                Pinyin.shared.keys(for: bytes, full: &full, initials: &initials)
            }
            if hasPinyin {
                indexedAliases.append(String(decoding: full, as: UTF8.self))
                indexedAliases.append(String(decoding: initials, as: UTF8.self))
            }
        }
        self.symbol = symbol; self.aliases = Array(Set(indexedAliases)).sorted(); self.url = url; self.fallbackURL = fallbackURL ?? url
        self.breadcrumb = breadcrumb
    }
}

enum SystemSettingsCatalog {
    private static let catalog = makeEntries(osVersion: ProcessInfo.processInfo.operatingSystemVersion)
    static var entries: [SystemSetting] { catalog }
    static func search(_ query: String) -> [SystemSetting] {
        let ranked: [(setting: SystemSetting, rank: Int)] = entries.compactMap { setting -> (SystemSetting, Int)? in
            guard let rank = LauncherMatch.rank(query, in: [setting.name, setting.id, setting.subtitle, setting.breadcrumb] + setting.aliases) else { return nil }
            return (setting: setting, rank: rank)
        }
        let sorted: [(setting: SystemSetting, rank: Int)] = ranked.sorted { lhs, rhs in
            lhs.rank == rhs.rank ? lhs.setting.id < rhs.setting.id : lhs.rank < rhs.rank
        }
        return sorted.map(\.setting)
    }
    static func open(_ setting: SystemSetting) -> Bool {
        NSWorkspace.shared.open(setting.url) || (setting.fallbackURL != setting.url && NSWorkspace.shared.open(setting.fallbackURL))
    }
    static func openSpotlightShortcuts() -> Bool {
        guard let setting = entries.first(where: { $0.id == "keyshortcuts" }) else { return false }
        return open(setting)
    }

    static func preferenceURL(_ identifier: String, osVersion: OperatingSystemVersion) -> URL {
        if osVersion.majorVersion >= 13 { return URL(string: "x-apple.systempreferences:" + identifier)! }
        let legacy = legacyID(for: identifier)
        let target = legacy.hasPrefix("com.apple.preference.") || legacy.hasPrefix("com.apple.preferences.")
            || legacy == "com.apple.ExtensionsPreferences"
            ? legacy : "com.apple.preference." + legacy
        return URL(string: "x-apple.systempreferences:" + target)!
    }

    static func legacyID(for identifier: String) -> String {
        let map = ["com.apple.Displays-Settings.extension":"displays", "com.apple.Sound-Settings.extension":"sound",
                   "com.apple.WiFiSettings.extension":"network", "com.apple.wifi-settings-extension":"network",
                   "com.apple.BluetoothSettings":"com.apple.preferences.Bluetooth",
                   "com.apple.Network-Settings.extension":"network", "com.apple.Keyboard-Settings.extension":"keyboard",
                   "com.apple.Mouse-Settings.extension":"mouse", "com.apple.Trackpad-Settings.extension":"trackpad",
                   "com.apple.Dock-Settings.extension":"dock", "com.apple.Appearance-Settings.extension":"appearance",
                   "com.apple.preference.dock":"dock",
                   "com.apple.Wallpaper-Settings.extension":"desktop", "com.apple.Notifications-Settings.extension":"notifications",
                   "com.apple.Focus-Settings.extension":"doNotDisturb", "com.apple.Battery-Settings.extension":"battery",
                   "com.apple.Accessibility-Settings.extension":"universalAccess",
                   "com.apple.settings.PrivacySecurity.extension":"security", "com.apple.settings.Storage":"storage",
                   "com.apple.Localization-Settings.extension":"international",
                   "com.apple.LoginItems-Settings.extension":"com.apple.ExtensionsPreferences",
                   "com.apple.Software-Update-Settings.extension":"softwareupdate", "com.apple.Date-Time-Settings.extension":"datetime",
                   "com.apple.Language-Settings.extension":"international", "com.apple.Print-Scan-Settings.extension":"print",
                   "com.apple.Time-Machine-Settings.extension":"TimeMachine", "com.apple.Spotlight-Settings.extension":"spotlight"]
        return map[identifier] ?? identifier
    }

    static func makeEntries(osVersion: OperatingSystemVersion) -> [SystemSetting] {
        let specs: [(String,String,String,String,[String],String,String)] = [
            ("displays","Displays","显示器","display",["screen","屏幕","monitor","分辨率"],"com.apple.Displays-Settings.extension","com.apple.preference.displays"),
            ("sound","Sound","声音","speaker.wave.2",["audio","volume","麦克风"],"com.apple.Sound-Settings.extension","com.apple.preference.sound"),
            ("wifi","Wi-Fi","无线局域网","wifi",["wireless","网络","无线"],"com.apple.wifi-settings-extension","com.apple.preference.network"),
            ("bluetooth","Bluetooth","蓝牙","antenna.radiowaves.left.and.right",["蓝牙设备"],"com.apple.BluetoothSettings","com.apple.preferences.Bluetooth"),
            ("network","Network","网络","network",["ethernet","vpn","互联网"],"com.apple.Network-Settings.extension","com.apple.preference.network"),
            ("keyboard","Keyboard","键盘","keyboard",["输入","按键"],"com.apple.Keyboard-Settings.extension","com.apple.preference.keyboard"),
            ("keyshortcuts","Keyboard Shortcuts","键盘快捷键","command",["shortcuts","spotlight shortcut","快捷键","聚焦快捷键"],"com.apple.Keyboard-Settings.extension?KeyboardShortcuts","com.apple.preference.keyboard"),
            ("mouse","Mouse","鼠标","computermouse",["pointer","鼠标速度"],"com.apple.Mouse-Settings.extension","com.apple.preference.mouse"),
            ("trackpad","Trackpad","触控板","rectangle.and.hand.point.up.left",["gesture","触控板手势"],"com.apple.Trackpad-Settings.extension","com.apple.preference.trackpad"),
            ("dock","Desktop & Dock","桌面与程序坞","dock.rectangle",["dock","menu bar","程序坞"],"com.apple.preference.dock","com.apple.preference.dock"),
            ("appearance","Appearance","外观","sun.max",["dark mode","浅色","深色"],"com.apple.Appearance-Settings.extension","com.apple.preference.general"),
            ("wallpaper","Wallpaper","墙纸","photo",["background","桌面背景"],"com.apple.Wallpaper-Settings.extension","com.apple.preference.desktopscreeneffect"),
            ("notifications","Notifications","通知","bell.badge",["alerts","通知中心"],"com.apple.Notifications-Settings.extension","com.apple.preference.notifications"),
            ("focus","Focus","专注模式","moon",["do not disturb","勿扰"],"com.apple.Focus-Settings.extension","com.apple.preference.notifications"),
            ("battery","Battery","电池","battery.100",["power","电源"],"com.apple.Battery-Settings.extension","com.apple.preference.battery"),
            ("accessibility","Accessibility","辅助功能","accessibility",["voiceover","放大"],"com.apple.Accessibility-Settings.extension","com.apple.preference.universalaccess"),
            ("privacysecurity","Privacy & Security","隐私与安全性","hand.raised",["privacy","security","隐私"],"com.apple.settings.PrivacySecurity.extension","com.apple.preference.security"),
            ("fulldiskaccess","Full Disk Access","完全磁盘访问权限","externaldrive.badge.checkmark",["permissions","磁盘权限"],"com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles","com.apple.preference.security"),
            ("loginitems","Login Items","登录项","person.crop.circle.badge.checkmark",["startup apps","启动项"],"com.apple.LoginItems-Settings.extension","com.apple.ExtensionsPreferences"),
            ("storage","Storage","储存空间","internaldrive",["disk space","磁盘空间"],"com.apple.settings.Storage","com.apple.preference.storage"),
            ("softwareupdate","Software Update","软件更新","arrow.clockwise",["update","更新系统"],"com.apple.Software-Update-Settings.extension","com.apple.preferences.softwareupdate"),
            ("datetime","Date & Time","日期与时间","clock",["clock","time zone","时区"],"com.apple.Date-Time-Settings.extension","com.apple.preference.datetime"),
            ("language","Language & Region","语言与地区","globe",["input source","语言"],"com.apple.Localization-Settings.extension","com.apple.preference.international"),
            ("printers","Printers & Scanners","打印机与扫描仪","printer",["print","scanner","打印"],"com.apple.Print-Scan-Settings.extension","com.apple.preference.printfax"),
            ("timemachine","Time Machine","时间机器","clock.arrow.circlepath",["backup","备份"],"com.apple.Time-Machine-Settings.extension","com.apple.preference.timemachine"),
            ("spotlight","Spotlight","聚焦","magnifyingglass",["search","indexing","索引"],"com.apple.Spotlight-Settings.extension","com.apple.preference.spotlight")
        ]
        return specs.map { id, en, zh, symbol, aliases, modern, legacy in
            let modernURL = preferenceURL(modern, osVersion: osVersion)
            let legacyURL = URL(string: "x-apple.systempreferences:" + legacy)!
            let legacyFullDiskURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
            let top: URL
            if id == "keyshortcuts" {
                top = preferenceURL("com.apple.Keyboard-Settings.extension", osVersion: osVersion)
            } else if id == "fulldiskaccess" {
                top = legacyFullDiskURL
            } else if id == "privacysecurity" && osVersion.majorVersion < 26 {
                top = legacyURL
            } else {
                top = modernURL
            }
            let fallback: URL
            if id == "keyshortcuts" {
                fallback = legacyURL
            } else if id == "fulldiskaccess" && osVersion.majorVersion >= 26 {
                fallback = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!
            } else {
                fallback = legacyURL
            }
            let breadcrumb = id == "keyshortcuts" ? "Keyboard › Keyboard Shortcuts"
                : id == "fulldiskaccess" ? "Privacy & Security › Full Disk Access" : en
            let subtitle = id == "keyshortcuts" ? L10n.text("settings.keyboardShortcutsHint") : ""
            return SystemSetting(id: id, englishName: en, chineseName: zh, subtitle: subtitle, symbol: symbol, aliases: aliases,
                                 url: top, fallbackURL: fallback, breadcrumb: breadcrumb)
        }
    }
}
