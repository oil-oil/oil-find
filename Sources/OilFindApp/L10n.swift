import Foundation
import OilFindCore

// Keys and copy are shared by every surface, including snapshots.
enum L10n {
    static var snapshotChinese: Bool?
    static let changed = Notification.Name("com.oiloil.find.languageChanged")
    private(set) static var language = AppLanguage.load()
    static var chinese: Bool { snapshotChinese ?? language.usesChinese() }
    static func setLanguage(_ value: AppLanguage, in defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: AppLanguage.preferenceKey)
        guard language != value else { return }
        language = value
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static func relocalized(_ value: String?) -> String? {
        guard let value else { return nil }
        guard let pair = strings.values.first(where: { $0.0 == value || $0.1 == value }) else { return value }
        return chinese ? pair.0 : pair.1
    }
    static func text(_ key: String, _ arguments: String...) -> String {
        guard let pair = strings[key] else { preconditionFailure("Unknown localization key: \(key)") }
        return String(format: chinese ? pair.0 : pair.1, arguments: arguments)
    }
    static func diagnostic(_ diagnostic: QueryDiagnostic) -> String {
        let value = diagnostic.kind == .kind ? Query.kindNames.joined(separator: ", ") : diagnostic.value
        return text("diag." + diagnostic.kind.rawValue, value)
    }
    static func explanation(_ explanation: CoverageExplanation) -> String {
        switch explanation {
        case .indexed: return text("explain.indexed")
        case .scope(let reason): return text("explain.scope", text("settings.scope." + reason.scopeKey!))
        case .userExcluded(let path): return text("explain.userExcluded", path)
        case .noAccess: return text("explain.noAccess")
        case .volume: return text("explain.volume")
        case .cloud: return text("explain.cloud")
        case .pending: return text("explain.pending")
        }
    }
    private static let strings: [String: (String, String)] = [
        "update.check": ("检查更新…", "Check for Updates…"),
        "update.available.title": ("Oil Find %@ 可以更新了", "Oil Find %@ Is Available"),
        "update.available.current": ("你现在用的是 %@。", "You have %@."),
        "update.install": ("更新并重启", "Update and Restart"),
        "update.later": ("稍后", "Later"),
        "update.skip": ("跳过这个版本", "Skip This Version"),
        "update.latest.title": ("已是最新版本", "You're Up to Date"),
        "update.latest.body": ("Oil Find %@ 是最新版本。", "Oil Find %@ is the latest version."),
        "update.downloading": ("正在下载更新… %@", "Downloading Update… %@"),
        "update.installing": ("正在安装…", "Installing…"),
        "update.failed": ("更新没有完成：%@。可以到官网下载新版本。", "The update didn't finish: %@. You can download the new version from the website."),
        "update.openWebsite": ("打开官网", "Open Website"),
        "update.menuAvailable": ("安装更新 %@…", "Install Update %@…"),
        "update.auto": ("自动检查更新", "Check for Updates Automatically"),
        "update.autoHint": ("每天检查一次，只读取版本信息。", "Checks once a day and only reads version info."),
        "update.reason.network": ("网络连接失败", "the network connection failed"),
        "update.reason.integrity": ("下载的文件校验没有通过", "the downloaded file didn't pass verification"),
        "update.reason.signature": ("新版本的签名不是 Oil Find 的", "the new version isn't signed by Oil Find"),
        "update.reason.permission": ("没有权限替换当前的应用", "Oil Find can't replace the current app"),
        "update.reason.other": ("发生了意外错误", "something unexpected happened"),
        "coverage.title": ("未覆盖", "Not Covered"),
        "coverage.noAccess": ("没有权限的文件夹：%@ 个", "Folders without access: %@"),
        "coverage.scope": ("按索引范围排除：%@ 项", "Excluded by index scope: %@"),
        "coverage.userExcluded": ("在你排除的路径里：%@ 项", "In paths you excluded: %@"),
        "coverage.cloud": ("仅在云端的文件夹：%@ 个（里面的文件没有列出）", "Cloud-only folders: %@ (their contents aren't listed)"),
        "coverage.volumes": ("外置磁盘和网络卷：%@ 个（暂不支持）", "External and network volumes: %@ (not supported yet)"),
        "coverage.check": ("检查文件为什么搜不到…", "Why Can't I Find a File…"),
        "explain.indexed": ("已在索引中，可以搜到。", "It's in the index and can be found."),
        "explain.scope": ("被「%@」范围排除。在上面打开这个开关后就能搜到。", "Excluded by the \"%@\" scope. Turn it on above to include it."),
        "explain.userExcluded": ("在你排除的路径「%@」里。", "It's inside a path you excluded: %@."),
        "explain.noAccess": ("Oil Find 没有权限读取它所在的文件夹。授予完全磁盘访问权限后会自动补上。", "Oil Find can't read the folder it's in. It'll be added once you grant Full Disk Access."),
        "explain.volume": ("它在外置磁盘或网络卷上，目前还不支持。", "It's on an external or network volume, which isn't supported yet."),
        "explain.cloud": ("它在仅存于云端的文件夹里，下载到这台 Mac 后才能搜到。", "It's in a folder that's only in the cloud. Download it to this Mac to search it."),
        "explain.pending": ("还没有进入索引，稍后会自动加入。", "It isn't indexed yet. It'll be added shortly."),
        "empty.noAccess": ("有些文件夹没有访问权限，其中的文件搜不到。", "Some folders aren't accessible, so files in them can't be found."),
        "empty.grant": ("授予权限…", "Grant Access…"),
        "diag.regex": ("正则表达式写法有误：%@", "Invalid regular expression: %@"),
        "diag.kind": ("kind: 只接受 %@", "kind: accepts %@"),
        "diag.size": ("size: 的写法是 size:>10mb 或 size:1mb..5mb", "Write size: as size:>10mb or size:1mb..5mb"),
        "diag.date": ("dm: 的写法是 dm:today、dm:week 或 dm:2026-10-01", "Write dm: as dm:today, dm:week or dm:2026-10-01"),
        "diag.title": ("查询写法有误", "Check Your Query"),
        "hint.syntax": ("语法", "Syntax"),
        "placeholder": ("搜索文件、文件夹和应用", "Search files, folders and apps"),
        "filter.all": ("全部", "All"), "filter.folder": ("文件夹", "Folders"),
        "filter.app": ("应用", "Apps"), "filter.document": ("文档", "Documents"),
        "filter.image": ("图片", "Images"), "filter.video": ("视频", "Videos"),
        "filter.audio": ("音频", "Audio"), "filter.code": ("代码", "Code"),
        "filter.archive": ("压缩包", "Archives"),
        "sort.relevance": ("相关度", "Relevance"), "sort.name": ("名称", "Name"),
        "sort.modified": ("修改时间", "Date Modified"), "sort.size": ("大小", "Size"),
        "footer.results": ("共 %@ 项 · %@ ms", "%@ items · %@ ms"),
        "footer.partial": ("共 %@ 项，前 5,000 项已排序 · %@ ms", "%@ items, first 5,000 sorted · %@ ms"),
        "footer.recent": ("最近修改 · 已索引 %@ 项", "Recently modified · %@ items indexed"),
        "footer.indexing": ("正在建立索引 · 已扫描 %@ 项", "Building index · %@ items scanned"),
        "hint.open": ("打开", "Open"), "hint.reveal": ("在访达中显示", "Show in Finder"),
        "hint.preview": ("预览", "Preview"), "hint.copy": ("拷贝路径", "Copy Path"),
        "empty.title": ("没有匹配的结果", "No results"),
        "empty.body": ("换个更短的关键词，或试试 *.pdf、ext:png、!node_modules", "Try a shorter keyword, or *.pdf, ext:png, !node_modules"),
        "indexing.title": ("正在建立索引", "Building index"),
        "indexing.body": ("已扫描 %@ 项。首次建立大约需要一分钟，之后每次启动都即开即用。", "%@ items scanned. The first build takes about a minute; later launches are instant."),
        "welcome.subtitle": ("按下快捷键，搜索这台 Mac 上的文件。", "Press the shortcut to search files on this Mac."),
        "welcome.changeHotkey": ("更改快捷键…", "Change Shortcut…"),
        "welcome.permission": ("完全磁盘访问权限", "Full Disk Access"),
        "welcome.permission.caption": ("不授权也能用，只是搜不到邮件和其他应用的数据。", "Optional. Without it, Mail and other apps' data can't be searched."),
        "welcome.permission.waiting": ("在列表里打开 Oil Find 的开关，系统会提示重新打开应用。", "Turn on Oil Find in the list. macOS will ask to reopen the app."),
        "welcome.permission.open": ("打开系统设置", "Open System Settings"),
        "welcome.permission.granted": ("已授权", "Granted"),
        "welcome.start": ("开始使用", "Get Started"),
        "panel.settings": ("设置", "Settings"),
        "toast.copiedPath": ("已拷贝：%@", "Copied: %@"),
        "toast.copiedName": ("已拷贝名称：%@", "Copied name: %@"),
        "toast.trashed": ("已移到废纸篓：%@", "Moved to Trash: %@"),
        "meta.folder": ("文件夹", "Folder"), "meta.app": ("应用", "App"),
        "date.today": ("今天 %@", "Today %@"), "date.yesterday": ("昨天 %@", "Yesterday %@"),
        "menu.open": ("打开搜索", "Open Search"), "menu.indexed": ("已索引 %@ 项", "%@ items indexed"),
        "menu.indexing": ("正在建立索引…", "Building index…"),
        "menu.rescan": ("重建索引", "Rebuild Index"),
        "menu.limited": ("未获得完全磁盘访问权限…", "Full Disk Access not granted…"),
        "menu.hotkeyFailed": ("快捷键已被其他应用占用", "Shortcut is in use by another app"),
        "menu.loginItem": ("登录时启动", "Launch at Login"), "menu.settings": ("设置…", "Settings…"),
        "menu.quit": ("退出 Oil Find", "Quit Oil Find"),
        "ctx.open": ("打开", "Open"), "ctx.reveal": ("在访达中显示", "Show in Finder"),
        "ctx.preview": ("快速查看", "Quick Look"), "ctx.copyPath": ("拷贝路径", "Copy Path"),
        "ctx.copyName": ("拷贝名称", "Copy Name"), "ctx.trash": ("移到废纸篓", "Move to Trash"),
        "settings.title": ("Oil Find 设置", "Oil Find Settings"),
        "settings.general": ("通用", "General"),
        "settings.language": ("语言", "Language"),
        "settings.language.system": ("跟随系统", "Follow System"),
        "settings.login": ("登录时启动", "Launch at Login"),
        "settings.shortcut": ("全局快捷键", "Global Shortcut"),
        "settings.record": ("按下新的快捷键", "Press a new shortcut"),
        "settings.shortcutConflict": ("这个快捷键已被其他应用占用", "This shortcut is in use by another app"),
        "settings.shortcutModifier": ("快捷键需要包含 ⌘、⌃ 或 ⌥", "A shortcut needs ⌘, ⌃ or ⌥"),
        "settings.pinyin": ("拼音搜索", "Pinyin Search"),
        "settings.pinyinHint": ("输入 wd 或 wendang 就能找到「文档」", "Type wd or wendang to find “文档”"),
        "settings.index": ("索引", "Index"),
        "settings.indexed": ("已索引", "Indexed"),
        "settings.items": ("%@ 项", "%@ items"),
        "settings.scanDate": ("上次完整扫描：%@", "Last full scan: %@"),
        "settings.permission": ("完全磁盘访问权限", "Full Disk Access"),
        "settings.granted": ("已授权", "Granted"),
        "settings.notGranted": ("未授权", "Not granted"),
        "settings.openPermissions": ("打开系统设置", "Open System Settings"),
        "settings.rebuild": ("重建索引", "Rebuild Index"),
        "settings.rebuilding": ("正在重建…", "Rebuilding…"),
        "settings.scope": ("索引范围", "Index Scope"),
        "settings.scopeHint": ("默认只索引你自己的文件。下面几类数量庞大、很少按名称查找，需要时再打开。改动之后会自动重建索引。", "Oil Find indexes your own files by default. The categories below are large and rarely searched by name; turn them on when you need them. The index rebuilds after changes."),
        "settings.scope.dependency": ("开发依赖目录", "Dependency Folders"),
        "settings.scope.dependencyHint": ("node_modules、site-packages、.venv、Pods、DerivedData、.git 等", "node_modules, site-packages, .venv, Pods, DerivedData, .git and similar"),
        "settings.scope.packages": ("应用与包的内部文件", "Inside Apps and Packages"),
        "settings.scope.packagesHint": (".app、.framework、.photoslibrary 等包里的文件", "Files inside .app, .framework, .photoslibrary and other packages"),
        "settings.scope.library": ("资源库", "Library"),
        "settings.scope.libraryHint": ("~/Library 里的应用数据。iCloud 云盘和网盘始终索引", "App data in ~/Library. iCloud Drive and cloud storage are always indexed"),
        "settings.scope.system": ("系统目录", "System Folders"),
        "settings.scope.systemHint": ("/System、/Library、/usr、/private、/opt", "/System, /Library, /usr, /private, /opt"),
        "settings.excluded": ("排除的文件夹", "Excluded Folders"),
        "settings.noExcluded": ("还没有排除任何文件夹", "No excluded folders yet"),
        "settings.addFolder": ("添加文件夹…", "Add Folder…"),
        "settings.excludedHint": ("这些文件夹和里面的内容不会出现在搜索结果里。改动之后会自动重建索引。", "These folders and their contents never appear in results. The index rebuilds after changes.")
    ]
}
