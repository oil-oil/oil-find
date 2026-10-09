import AppKit
import OilFindCore

enum SnapshotError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let reason): return reason } }
}

#if DEBUG
enum Snapshot {
    static func run(_ arguments: [String]) throws {
        let allowed = Set(["--snapshot", "--state", "--query", "--filter", "--sort", "--select", "--appearance", "--db", "--settings-scroll", "--settings-section", "--language", "--coverage", "--update-notes", "--update-scroll"])
        var values: [String: String] = [:], i = 0, granted = false
        while i < arguments.count {
            if arguments[i] == "--granted" { granted = true; i += 1; continue }
            guard allowed.contains(arguments[i]), i + 1 < arguments.count else { throw SnapshotError.failed("Invalid snapshot argument: \(arguments[i])") }
            values[arguments[i]] = arguments[i + 1]; i += 2
        }
        guard let output = values["--snapshot"], !output.isEmpty else { throw SnapshotError.failed("--snapshot requires an output path") }
        if let language = values["--language"] {
            guard ["zh", "en"].contains(language) else { throw SnapshotError.failed("Invalid language: \(language)") }
            L10n.snapshotChinese = language == "zh"
        }
        defer { L10n.snapshotChinese = nil }
        let state = values["--state"] ?? "results"
        let launcherStates: Set<String> = ["unified", "clipboard", "clipboard-files", "system-settings", "calculator"]
        let settingsStates: Set<String> = ["settings", "clipboard-permission", "shortcut-conflict"]
        guard launcherStates.contains(state) || settingsStates.contains(state) || ["results", "recent", "empty", "indexing", "welcome", "toast", "no-access", "diagnostic", "syntax", "update-available", "update-downloading", "update-failed", "update-latest"].contains(state) else { throw SnapshotError.failed("Invalid state: \(state)") }
        let settingsSection: SettingsSection?
        if let section = values["--settings-section"] {
            guard let parsed = SettingsSection(rawValue: section) else { throw SnapshotError.failed("Invalid settings section: \(section)") }
            settingsSection = parsed
        } else { settingsSection = nil }
        let appearance = values["--appearance"] ?? "light"
        guard ["light", "dark"].contains(appearance) else { throw SnapshotError.failed("Invalid appearance: \(appearance)") }
        let filter = values["--filter"] ?? "all"
        guard let kind = FilterBar.names.firstIndex(of: filter) else { throw SnapshotError.failed("Invalid filter: \(filter)") }
        let sort = values["--sort"] ?? "relevance"
        let sorts: [String: SortKey] = ["relevance": .relevance, "name": .name, "modified": .modified, "size": .size]
        guard let key = sorts[sort], let selection = Int(values["--select"] ?? "0"), selection >= 0 else { throw SnapshotError.failed("Invalid sort or selected row") }
        var store: IndexStore?
        let needsIndex = !launcherStates.contains(state) && !settingsStates.contains(state) && !state.hasPrefix("update-") && !["indexing", "welcome"].contains(state)
        if needsIndex || (state == "settings" && values["--db"] != nil) {
            let fallback = NSHomeDirectory() + "/Library/Caches/Oil Find/cli-index.oilfind"
            let defaultPath = FileManager.default.fileExists(atPath: AppDelegate.dbURL.path) ? AppDelegate.dbURL.path : fallback
            let db = NSString(string: values["--db"] ?? defaultPath).expandingTildeInPath
            guard let loaded = IndexStore.load(from: db) else { throw SnapshotError.failed("Cannot load index: \(db)") }
            store = loaded
        }
        if values["--coverage"] == "sample", let store {
            store.write {
                for reason in CoverageReason.allCases {
                    store.coverage.buckets[reason] = CoverageBucket(count: reason == .dependency ? 248 : 3, examples: [reason == .noAccess ? "/Users/demo/Library/Mail" : "/Users/demo/" + reason.rawValue])
                }
            }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        if state.hasPrefix("update-") {
            var manifest = try UpdateManifest.parse(Data(#"{"version":"1.2.0","build":5,"url":"https://find.oiloil.org/downloads/Oil-Find-1.2.0.zip","size":1,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","minimumSystemVersion":"14.0","published":"2026-10-04","notes":{"zh":["应用内检查更新：有新版本时提示，一键下载、校验并重启到新版本。","官网新增更新日志。"],"en":["Built-in updates: Oil Find tells you when a new version is out, then downloads, verifies and restarts into it.","A changelog is now on the website."]}}"#.utf8))
            if let text = values["--update-notes"] {
                guard let count = Int(text), (1...20).contains(count) else { throw SnapshotError.failed("Invalid update note count") }
                var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as! [String: Any]
                object["notes"] = ["zh": (0..<count).map { manifest.notes.zh[$0 % 2] }, "en": (0..<count).map { manifest.notes.en[$0 % 2] }]
                manifest = try UpdateManifest.parse(JSONSerialization.data(withJSONObject: object))
            }
            let model = UpdateManager(snapshot: true, current: state == "update-latest" ? UpdateManager.current : UpdateVersion("1.1.0", build: 4)!)
            let states: [String: UpdateState] = ["update-available": .available, "update-downloading": .downloading(0.42), "update-failed": .failed(.signature), "update-latest": .latest]
            model.prepareSnapshot(states[state]!, manifest: state == "update-latest" ? nil : manifest)
            let controller = UpdateWindowController(model: model)
            guard let window = controller.window, let view = window.contentView else { throw SnapshotError.failed("Cannot create update view") }
            window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            view.layoutSubtreeIfNeeded()
            if let text = values["--update-scroll"] {
                guard let fraction = Double(text), (0...1).contains(fraction) else { throw SnapshotError.failed("Invalid update scroll fraction") }
                func findScroll(_ node: NSView) -> NSScrollView? {
                    if let scroll = node as? NSScrollView { return scroll }
                    return node.subviews.lazy.compactMap(findScroll).first
                }
                guard let scroll = findScroll(view), let document = scroll.documentView else { throw SnapshotError.failed("Cannot find update scroll view") }
                let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? maximum * fraction : maximum * (1 - fraction)))
                scroll.reflectScrolledClipView(scroll.contentView)
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                print("update notes scroll: maximum=\(maximum) origin=\(scroll.contentView.bounds.origin.y)")
            }
            try write(view: view, appearance: window.appearance, output: output)
            return
        }
        if state == "welcome" {
            let controller = WelcomeWindowController(granted: granted, snapshot: true)
            guard let window = controller.window, let view = window.contentView else { throw SnapshotError.failed("Cannot create welcome view") }
            window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            controller.resizeToContent(); view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            if let warmup = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: warmup) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            try write(view: view, appearance: window.appearance, output: output)
            return
        }
        if settingsStates.contains(state) {
            let model = SettingsModel(snapshotStore: store, snapshot: true)
            // Existing expanded/scrolling coverage snapshots must open the index tab.
            model.section = settingsSection ?? (values["--coverage"] == "sample" || values["--settings-scroll"] != nil ? .index : .general)
            if values["--coverage"] == "sample" {
                model.expandedCoverage = ["noAccess", "scope"]
                if store == nil {
                    for reason in CoverageReason.allCases {
                        model.coverage.buckets[reason] = CoverageBucket(count: reason == .dependency ? 248 : 3,
                            examples: [reason == .noAccess ? "/Users/demo/Library/Mail" : "/Users/demo/" + reason.rawValue])
                    }
                    model.indexedCount = 12_345
                }
            }
            if state == "clipboard-permission" {
                model.section = .clipboard
                model.clipboard.prepareSnapshot([], enabled: true, needsAccess: true)
            } else if state == "shortcut-conflict" {
                model.section = .general
                model.keyCode = Shortcut.defaultKeyCode; model.modifiers = Shortcut.defaultModifiers
                model.shortcutError = L10n.text("settings.shortcutConflict")
                model.actualShortcut = Shortcut.symbols(keyCode: Shortcut.fallbackKeyCode, modifiers: Shortcut.fallbackModifiers)
            }
            let controller = SettingsWindowController(model: model)
            guard let window = controller.window, let view = window.contentView else { throw SnapshotError.failed("Cannot create settings view") }
            window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            view.layoutSubtreeIfNeeded()
            // SwiftUI commits its initial layout on the run loop, without showing a window.
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            view.layoutSubtreeIfNeeded()
            if let value = values["--settings-scroll"] {
                guard let fraction = Double(value), (0...1).contains(fraction) else { throw SnapshotError.failed("Invalid settings scroll fraction") }
                func scrollViews(_ view: NSView) -> [NSScrollView] {
                    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
                }
                if let scroll = scrollViews(view).first, let document = scroll.documentView {
                    let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? maximum * fraction : maximum * (1 - fraction)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                    view.layoutSubtreeIfNeeded()
                }
            }
            try write(view: view, appearance: window.appearance, output: output)
            return
        }
        let panel = SearchPanel(snapshot: true)
        panel.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        let controller = panel.searchController
        if launcherStates.contains(state) {
            let fixture = try launcherFixture(state: state, query: values["--query"])
            try controller.prepareLauncherSnapshot(fixture.snapshot, clipboardEntries: fixture.clipboard, selection: selection)
        } else {
            try controller.prepareSnapshot(state: state, query: values["--query"] ?? "readme", options: SearchOptions(sort: key, ascending: key == .name, kind: kind == 0 ? nil : UInt8(kind)), store: store, selection: selection)
        }
        let view = controller.view
        view.frame = NSRect(origin: .zero, size: Theme.panelSize)
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let deadline = Date().addingTimeInterval(1)
        while !controller.results.icons.isIdle && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        view.layoutSubtreeIfNeeded()
        if let warmup = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: warmup) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
        try write(view: view, appearance: panel.appearance, output: output)
    }
    // Value-only fixtures: no real index, application catalog or pasteboard reads.
    static func launcherFixture(state: String, query: String? = nil) throws -> (snapshot: SearchSnapshot, clipboard: [ClipboardEntry]) {
        let now = Date()
        let clips = [
            ClipboardEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                text: L10n.chinese ? "项目会议记录：周五检查搜索体验。" : "Project meeting notes: review search on Friday.",
                copiedAt: now.addingTimeInterval(-120), sourceBundleID: "com.apple.Notes", sourceName: "Notes"),
            ClipboardEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                text: "https://find.oiloil.org", copiedAt: now.addingTimeInterval(-600), sourceBundleID: "com.apple.Safari", sourceName: "Safari"),
            ClipboardEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                text: "swift build -c release\nswift test", copiedAt: now.addingTimeInterval(-1800), sourceBundleID: "com.apple.Terminal", sourceName: "Terminal")
        ]
        switch state {
        case "clipboard":
            let raw = query ?? ""
            let rows = clips.filter { $0.matches(raw) }.map(LauncherRow.clipboard)
            return (SearchSnapshot(raw: raw, scope: .clipboard, leading: rows), clips)
        case "clipboard-files":
            let files = [
                ClipboardEntry(content: .files(["/Users/demo/Documents/Project Notes.pdf", "/Users/demo/Documents/Timeline.xlsx"]),
                               copiedAt: now.addingTimeInterval(-60), sourceBundleID: "com.apple.finder", sourceName: "Finder"),
                ClipboardEntry(content: .files(["/Users/demo/Documents/Design Assets"]),
                               copiedAt: now.addingTimeInterval(-180), sourceBundleID: "com.apple.finder", sourceName: "Finder"),
                ClipboardEntry(content: .files(["/Users/demo/Desktop/Draft.md", "/Users/demo/Documents/Reference.pdf"]),
                               copiedAt: now.addingTimeInterval(-300), sourceBundleID: "com.apple.finder", sourceName: "Finder")
            ] + clips
            let raw = query ?? ""
            return (SearchSnapshot(raw: raw, scope: .clipboard, leading: files.filter { $0.matches(raw) }.map(LauncherRow.clipboard)), files)
        case "system-settings":
            let raw = query ?? (L10n.chinese ? "键盘" : "keyboard")
            return (SearchSnapshot(raw: raw, scope: .settings, leading: SystemSettingsCatalog.search(raw).map(LauncherRow.setting)), [])
        case "calculator":
            let raw = query ?? "150 × 20%"
            guard let answer = LauncherTools.evaluate(raw) else { throw SnapshotError.failed("Invalid calculator snapshot expression: \(raw)") }
            return (SearchSnapshot(raw: raw, scope: .all, leading: [.answer(answer)], trailing: [.web(raw, WebSearchEngine.duckDuckGo.url(for: raw))]), [])
        case "unified":
            let raw = query ?? (L10n.chinese ? "显示" : "display")
            let apps = [LauncherApp(name: "Display Studio", path: "/Users/demo/Applications/Display Studio.app", aliases: ["显示"]),
                        LauncherApp(name: "Display Notes", path: "/Users/demo/Applications/Display Notes.app", aliases: ["显示"])]
            let files = ["Display review.pdf", "Display measurements.csv", "Display notes.md"].enumerated().map { index, name in
                LauncherRow.file(ResultItem(id: UInt32(index + 1), name: name, parentPath: "/Users/demo/Documents", path: "/Users/demo/Documents/" + name,
                    size: UInt64((index + 1) * 2048), modified: now, flags: 0, kind: 3))
            }
            let words = raw.split(whereSeparator: { $0.isWhitespace })
            let fileRows = files.filter { row in words.allSatisfy { row.title.localizedStandardContains(String($0)) || $0 == "显示" } }
            let appRows = apps.filter { LauncherMatch.rank(raw, in: [$0.name] + $0.aliases) != nil }.map(LauncherRow.app)
            let rows = appRows + SystemSettingsCatalog.search(raw).map(LauncherRow.setting) + fileRows
            return (SearchSnapshot(raw: raw, scope: .all, leading: rows, trailing: [.web(raw, WebSearchEngine.duckDuckGo.url(for: raw))]), [])
        default: throw SnapshotError.failed("Invalid launcher fixture: \(state)")
        }
    }
    private static func write(view: NSView, appearance: NSAppearance?, output: String) throws {
        let size = view.bounds.size
        let width = Int(size.width * 2), height = Int(size.height * 2)
        guard let suggested = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SnapshotError.failed("Cannot allocate snapshot bitmap")
        }
        let bitmap: NSBitmapImageRep
        if suggested.pixelsWide == width && suggested.pixelsHigh == height { bitmap = suggested }
        else {
            guard let retina = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                throw SnapshotError.failed("Cannot allocate 2x snapshot bitmap")
            }
            bitmap = retina
        }
        bitmap.size = size
        appearance?.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SnapshotError.failed("Cannot encode snapshot PNG") }
        let url = URL(fileURLWithPath: NSString(string: output).expandingTildeInPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url, options: .atomic)
        print("snapshot: \(url.path) \(width)x\(height)")
    }
}
#endif
