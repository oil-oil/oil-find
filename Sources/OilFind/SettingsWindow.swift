import AppKit
import SwiftUI
import ServiceManagement
import Carbon
import UniformTypeIdentifiers
import OilFindCore

enum SettingsSection: String, CaseIterable {
    case general, search, clipboard, index
    var localizationKey: String { "settings." + rawValue }
}

final class SettingsModel: ObservableObject {
    @Published var section: SettingsSection = .general {
        didSet { if section != oldValue { cancelRecording() } }
    }
    @Published private(set) var language: AppLanguage
    @Published var launchAtLogin: Bool
    let update: UpdateManager
    let clipboard: ClipboardHistory
    private var languageObserver: NSObjectProtocol?
    private let languageDefaults: UserDefaults
    private var coverageExplanation: CoverageExplanation?
    private let snapshot: Bool
    @Published var loginError: String?
    @Published var pinyinEnabled: Bool
    @Published var calculatorEnabled: Bool
    @Published var webSearchEnabled: Bool
    @Published var webSearchEngine: WebSearchEngine
    @Published var excludedPaths: [String]
    @Published var keyCode: UInt32
    @Published var modifiers: UInt32
    @Published var indexDependencyDirs: Bool
    @Published var indexPackageContents: Bool
    @Published var indexUserLibrary: Bool
    @Published var indexSystemDirs: Bool
    @Published var recording = false
    @Published var shortcutError: String?
    @Published var actualShortcut: String?
    @Published var coverage = CoverageStats()
    @Published var explanation: String?
    @Published var expandedCoverage: Set<String> = []
    @Published var indexedCount = 0
    @Published var scanDate: Date?
    @Published var granted = false
    @Published var rebuilding = false
    weak var manager: IndexManager?
    var onConfigChange: (() -> Void)?
    var onPinyinChange: (() -> Void)?
    var suspendHotKey: (() -> Void)?
    var registerHotKey: ((UInt32, UInt32) -> Bool)?
    var onContentChange: (() -> Void)?
    var onRetryHotKey: (() -> Void)?
    private let snapshotStore: IndexStore?
    private var keyMonitor: Any?
    private var timer: Timer?

    init(snapshotStore: IndexStore? = nil, snapshot: Bool = false, languageDefaults: UserDefaults = .standard, clipboard: ClipboardHistory? = nil) {
        self.snapshot = snapshot
        self.languageDefaults = languageDefaults
        self.language = L10n.language
        self.update = snapshot ? UpdateManager(snapshot: true) : .shared
        self.clipboard = clipboard ?? ClipboardHistory(snapshot: snapshot)
        launchAtLogin = snapshot ? false : SMAppService.mainApp.status == .enabled
        if !snapshot { SettingsPreferences.register() }
        let defaults = UserDefaults.standard
        indexDependencyDirs = !snapshot && defaults.bool(forKey: "indexDependencyDirs")
        indexPackageContents = !snapshot && defaults.bool(forKey: "indexPackageContents")
        indexUserLibrary = !snapshot && defaults.bool(forKey: "indexUserLibrary")
        indexSystemDirs = !snapshot && defaults.bool(forKey: "indexSystemDirs")
        pinyinEnabled = snapshot ? true : defaults.bool(forKey: "pinyinEnabled")
        calculatorEnabled = snapshot ? true : defaults.bool(forKey: "calculatorEnabled")
        webSearchEnabled = snapshot ? true : defaults.bool(forKey: "webSearchEnabled")
        webSearchEngine = snapshot ? .duckDuckGo : WebSearchEngine(rawValue: defaults.string(forKey: "webSearchEngine") ?? "") ?? .duckDuckGo
        excludedPaths = snapshot ? [] : ExcludedFolders.adding(defaults.stringArray(forKey: "userExcludedPaths") ?? [], to: [])
        keyCode = snapshot ? Shortcut.defaultKeyCode : UInt32(clamping: defaults.integer(forKey: "hotKeyCode"))
        modifiers = snapshot ? Shortcut.defaultModifiers : UInt32(clamping: defaults.integer(forKey: "hotKeyModifiers"))
        self.snapshotStore = snapshotStore
        languageObserver = NotificationCenter.default.addObserver(forName: L10n.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.language = L10n.language
            self.shortcutError = L10n.relocalized(self.shortcutError)
            if let answer = self.coverageExplanation { self.explanation = L10n.explanation(answer) }
            self.onContentChange?()
        }
        refresh()
    }
    // Grouped Form keeps longer sections scrollable inside the fixed window.
    var contentHeight: CGFloat { 680 }
    func updateShortcutStatus(keyCode actualKeyCode: UInt32?, modifiers actualModifiers: UInt32?, clearErrorWhenBound: Bool = true) {
        actualShortcut = actualKeyCode.flatMap { code in actualModifiers.map { Shortcut.symbols(keyCode: code, modifiers: $0) } }
        guard !recording else { return }
        if actualKeyCode == keyCode && actualModifiers == modifiers {
            if clearErrorWhenBound { shortcutError = nil }
        } else { shortcutError = L10n.text("settings.shortcutConflict") }
    }
    func startRefreshing() {
        refresh(); timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func stopRefreshing() { timer?.invalidate(); timer = nil; cancelRecording() }
    func refresh() {
        let wasGranted = granted
        if !snapshot { launchAtLogin = SMAppService.mainApp.status == .enabled }
        granted = snapshot ? false : Permissions.hasFullDiskAccess()
        rebuilding = manager?.isRescanning == true || manager?.state == .scanning || manager?.state == .loading
        if let store = snapshotStore ?? manager?.store {
            let values = store.read { (store.liveCount, store.scanFinishedAt, store.coverage) }
            if coverage != values.2 { coverage = values.2 }
            indexedCount = values.0
            scanDate = values.1 == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(values.1))
        } else { indexedCount = 0; scanDate = nil }
        if wasGranted != granted { onContentChange?() }
    }
    func checkFile(in window: NSWindow?) {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let path = panel.url?.path else { return }
            let manager = self.manager
            DispatchQueue.global(qos: .utility).async {
                let answer = manager?.explain(path: path) ?? .pending
                DispatchQueue.main.async { self.coverageExplanation = answer; self.explanation = L10n.explanation(answer) }
            }
        }
    }
    func setLogin(_ enabled: Bool) {
        if snapshot { launchAtLogin = enabled; return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch { loginError = error.localizedDescription }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        onContentChange?()
    }
    func setPinyin(_ enabled: Bool) {
        pinyinEnabled = enabled
        if !snapshot { UserDefaults.standard.set(enabled, forKey: "pinyinEnabled") }
        onPinyinChange?()
    }
    func setCalculator(_ enabled: Bool) {
        calculatorEnabled = enabled
        if !snapshot { UserDefaults.standard.set(enabled, forKey: "calculatorEnabled") }
    }
    func setWebSearch(_ enabled: Bool) {
        webSearchEnabled = enabled
        if !snapshot { UserDefaults.standard.set(enabled, forKey: "webSearchEnabled") }
    }
    func setWebSearchEngine(_ engine: WebSearchEngine) {
        webSearchEngine = engine
        if !snapshot { UserDefaults.standard.set(engine.rawValue, forKey: "webSearchEngine") }
    }
    func addExcludedApplications(in window: NSWindow?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false; panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            let identifiers = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
            self.clipboard.setExcludedApplications(Array(Set(self.clipboard.excludedAppIDs).union(identifiers)).sorted())
        }
    }
    func removeExcludedApplication(_ identifier: String) {
        clipboard.setExcludedApplications(clipboard.excludedAppIDs.filter { $0 != identifier })
    }
    func setLanguage(_ value: AppLanguage) { L10n.setLanguage(value, in: languageDefaults) }
    func setScope(_ key: String, _ enabled: Bool) {
        switch key {
        case "indexDependencyDirs": indexDependencyDirs = enabled
        case "indexPackageContents": indexPackageContents = enabled
        case "indexUserLibrary": indexUserLibrary = enabled
        case "indexSystemDirs": indexSystemDirs = enabled
        default: preconditionFailure("Unknown scope key")
        }
        if !snapshot { UserDefaults.standard.set(enabled, forKey: key) }
        onConfigChange?(); refresh()
    }
    func addFolders(in window: NSWindow?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            self.setExcluded(ExcludedFolders.adding(panel.urls.map(\.path), to: self.excludedPaths))
        }
    }
    func removeFolder(_ path: String) { setExcluded(excludedPaths.filter { $0 != path }) }
    private func setExcluded(_ paths: [String]) {
        guard paths != excludedPaths else { return }
        excludedPaths = paths
        if !snapshot { UserDefaults.standard.set(paths, forKey: "userExcludedPaths") }
        onConfigChange?(); onContentChange?()
    }
    func rebuild() { manager?.rescan(); rebuilding = manager != nil }
    func beginRecording(in window: NSWindow?) {
        guard !recording, let window else { return }
        shortcutError = nil; recording = true; suspendHotKey?(); onContentChange?()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, self.recording, let window, event.window === window else { return event }
            self.record(event); return nil
        }
    }
    private func endRecording() {
        recording = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        onContentChange?()
    }
    func cancelRecording() {
        guard recording else { return }
        shortcutError = registerHotKey?(keyCode, modifiers) == true ? nil : L10n.text("settings.shortcutConflict")
        endRecording()
    }
    func record(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { cancelRecording(); return }
        let reset = event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)
        let code = reset ? Shortcut.defaultKeyCode : UInt32(event.keyCode)
        let mask = reset ? Shortcut.defaultModifiers : HotKey.carbonModifiers(event.modifierFlags)
        guard mask & UInt32(cmdKey | controlKey | optionKey) != 0 else {
            shortcutError = L10n.text("settings.shortcutModifier"); onContentChange?(); return
        }
        let registered = registerHotKey?(code, mask) == true
        if reset || registered {
            keyCode = code; modifiers = mask
            if !snapshot {
                UserDefaults.standard.set(Int(code), forKey: "hotKeyCode")
                UserDefaults.standard.set(Int(mask), forKey: "hotKeyModifiers")
            }
        }
        if !reset && !registered {
            _ = registerHotKey?(keyCode, modifiers)
        }
        shortcutError = registered ? nil : L10n.text("settings.shortcutConflict")
        endRecording()
    }
    deinit {
        timer?.invalidate()
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}

private struct UpdateSettingsRow: View {
    @ObservedObject var update: UpdateManager
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Toggle(L10n.text("update.auto"), isOn: $update.automatic)
                    Text(L10n.text("update.autoHint")).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(L10n.text("update.check")) { update.check() }.disabled(!update.canCheck)
            }
            Text(UpdateManager.current.version.text).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct LanguagePicker: NSViewRepresentable {
    @ObservedObject var model: SettingsModel
    final class Coordinator: NSObject {
        let model: SettingsModel
        init(_ model: SettingsModel) { self.model = model }
        @objc func selected(_ button: NSPopUpButton) {
            guard AppLanguage.allCases.indices.contains(button.indexOfSelectedItem) else { return }
            model.setLanguage(AppLanguage.allCases[button.indexOfSelectedItem])
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small; button.font = .systemFont(ofSize: 12.5)
        button.target = context.coordinator; button.action = #selector(Coordinator.selected(_:))
        button.setAccessibilityIdentifier("settings.language")
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let titles = AppLanguage.allCases.map(\.title)
        if button.itemTitles != titles { button.removeAllItems(); button.addItems(withTitles: titles) }
        button.selectItem(at: AppLanguage.allCases.firstIndex(of: model.language)!)
        button.setAccessibilityLabel(L10n.text("settings.language"))
    }
}

private struct SettingsForm: View {
    @ObservedObject var model: SettingsModel
    var window: () -> NSWindow?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(SettingsSection.allCases, id: \.self) { section in
                    Button { model.section = section } label: {
                        Text(L10n.text(section.localizationKey))
                            .font(.system(size: 13, weight: model.section == section ? .semibold : .regular))
                            .foregroundStyle(Color(nsColor: .labelColor))
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(model.section == section
                                ? Color(nsColor: .controlAccentColor).opacity(0.14)
                                : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(
                                model.section == section ? Color(nsColor: .controlAccentColor).opacity(0.65)
                                    : Color(nsColor: .separatorColor), lineWidth: 1))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.navigation." + section.rawValue)
                    .accessibilityAddTraits(model.section == section ? .isSelected : [])
                }
            }
            .padding(20)
            .accessibilityIdentifier("settings.navigation")
            Form {
                switch model.section {
                case .general: generalSections
                case .search: searchSections
                case .clipboard: ClipboardSettingsSections(model: model, clipboard: model.clipboard, window: window)
                case .index: indexSections
                }
            }
            .formStyle(.grouped).toggleStyle(.switch)
        }
        .frame(width: 540, height: model.contentHeight)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    private var generalSections: some View {
        Section(L10n.text("settings.general")) {
            HStack {
                Text(L10n.text("settings.language")); Spacer()
                LanguagePicker(model: model).frame(width: 140, height: 24)
            }
            UpdateSettingsRow(update: model.update).id(model.language)
            VStack(alignment: .leading, spacing: 5) {
                Toggle(L10n.text("settings.login"), isOn: Binding(get: { model.launchAtLogin }, set: model.setLogin))
                if let error = model.loginError { hint(error).foregroundStyle(.red) }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(L10n.text("settings.shortcut")); Spacer()
                    ShortcutRecorder(model: model).frame(width: 120, height: 24)
                }
                hint(L10n.text("settings.shortcutDesired", Shortcut.symbols(keyCode: model.keyCode, modifiers: model.modifiers)))
                hint(L10n.text("settings.shortcutCurrent", model.actualShortcut ?? L10n.text("settings.shortcutInactive")))
                if let error = model.shortcutError { hint(error).foregroundStyle(.red) }
                HStack {
                    Button(L10n.text("settings.spotlightShortcuts")) { _ = SystemSettingsCatalog.openSpotlightShortcuts() }
                        .help(L10n.text("settings.spotlightBreadcrumb"))
                    Spacer()
                    Button(L10n.text("settings.retryHotKey")) { model.onRetryHotKey?() }
                        .disabled(model.onRetryHotKey == nil || model.recording)
                }
                hint(L10n.text("settings.spotlightBreadcrumb"))
            }
        }
    }
    private var searchSections: some View {
        Section(L10n.text("settings.search")) {
            VStack(alignment: .leading, spacing: 5) {
                Toggle(L10n.text("settings.pinyin"), isOn: Binding(get: { model.pinyinEnabled }, set: model.setPinyin))
                hint(L10n.text("settings.pinyinHint"))
            }
            VStack(alignment: .leading, spacing: 5) {
                Toggle(L10n.text("settings.calculator"), isOn: Binding(get: { model.calculatorEnabled }, set: model.setCalculator))
                hint(L10n.text("settings.calculatorHint"))
            }
            VStack(alignment: .leading, spacing: 5) {
                Toggle(L10n.text("settings.webSearch"), isOn: Binding(get: { model.webSearchEnabled }, set: model.setWebSearch))
                hint(L10n.text("settings.webSearchHint"))
            }
            Picker(L10n.text("settings.webSearchEngine"), selection: Binding(get: { model.webSearchEngine }, set: model.setWebSearchEngine)) {
                ForEach(WebSearchEngine.allCases, id: \.self) { engine in
                    Text(L10n.text("settings.webSearchEngine." + engine.rawValue)).tag(engine)
                }
            }
            .disabled(!model.webSearchEnabled)
        }
    }
    @ViewBuilder private var indexSections: some View {
        Section(L10n.text("settings.index")) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(L10n.text("settings.indexed")); Spacer()
                    Text(L10n.text("settings.items", Presentation.countText(model.indexedCount)))
                }
                if let date = model.scanDate {
                    hint(L10n.text("settings.scanDate", Presentation.dateText(date, now: Date(), calendar: .current, chinese: L10n.chinese)))
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("coverage.title")).font(.subheadline).foregroundStyle(.secondary)
                coverageRow("noAccess", bucket: model.coverage[.noAccess])
                if model.coverage.scopeCount > 0 {
                    DisclosureGroup(isExpanded: coverageBinding("scope")) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(CoverageReason.allCases.filter { $0.scopeKey != nil && model.coverage[$0].count > 0 }, id: \.self) { reason in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(L10n.text("settings.scope." + reason.scopeKey!) + " · " + String(model.coverage[reason].count))
                                        .font(.footnote).foregroundStyle(.secondary)
                                    examples(model.coverage[reason])
                                }
                            }
                        }
                        .padding(.top, 4).padding(.leading, 12).frame(maxWidth: .infinity, alignment: .leading)
                    } label: { Text(L10n.text("coverage.scope", String(model.coverage.scopeCount))).fixedSize(horizontal: false, vertical: true) }
                }
                coverageRow("userExcluded", bucket: model.coverage[.userExcluded])
                coverageRow("cloud", bucket: model.coverage[.cloud])
                coverageRow("volumes", bucket: model.coverage[.volumes])
                Button(L10n.text("coverage.check")) { model.checkFile(in: window()) }
                if let explanation = model.explanation { hint(explanation) }
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(L10n.text("settings.permission")); Spacer()
                    Circle().fill(Color(nsColor: model.granted ? .systemGreen : .systemOrange)).frame(width: 8, height: 8)
                    Text(L10n.text(model.granted ? "settings.granted" : "settings.notGranted"))
                }
                if !model.granted { Button(L10n.text("settings.openPermissions"), action: Permissions.openSettings) }
            }
            Button(L10n.text(model.rebuilding ? "settings.rebuilding" : "settings.rebuild"), action: model.rebuild)
                .disabled(model.rebuilding || model.manager == nil)
        }
        Section {
            scopeRow("dependency", key: "indexDependencyDirs", enabled: model.indexDependencyDirs)
            scopeRow("packages", key: "indexPackageContents", enabled: model.indexPackageContents)
            scopeRow("library", key: "indexUserLibrary", enabled: model.indexUserLibrary)
            scopeRow("system", key: "indexSystemDirs", enabled: model.indexSystemDirs)
        } header: { Text(L10n.text("settings.scope")) }
          footer: { hint(L10n.text("settings.scopeHint")) }
        Section {
            if model.excludedPaths.isEmpty { Text(L10n.text("settings.noExcluded")).foregroundStyle(.secondary) }
            ForEach(model.excludedPaths, id: \.self) { path in
                HStack {
                    Text(Presentation.abbreviate(path: path, home: NSHomeDirectory())).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { model.removeFolder(path) } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
            }
            Button(L10n.text("settings.addFolder")) { model.addFolders(in: window()) }
        } header: { Text(L10n.text("settings.excluded")) }
          footer: { hint(L10n.text("settings.excludedHint")) }
    }
    private func coverageBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { model.expandedCoverage.contains(key) }, set: { if $0 { model.expandedCoverage.insert(key) } else { model.expandedCoverage.remove(key) } })
    }
    @ViewBuilder private func coverageRow(_ key: String, bucket: CoverageBucket) -> some View {
        if bucket.count > 0 {
            DisclosureGroup(isExpanded: coverageBinding(key)) { examples(bucket).padding(.top, 4).padding(.leading, 12) }
                label: { Text(L10n.text("coverage." + key, String(bucket.count))).fixedSize(horizontal: false, vertical: true) }
        }
    }
    // Left-aligned, one line each; long paths truncate in the middle and show in full on hover.
    private func examples(_ bucket: CoverageBucket) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(bucket.examples, id: \.self) { path in
                Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(path)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func scopeRow(_ name: String, key: String, enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(L10n.text("settings.scope." + name), isOn: Binding(get: { enabled }, set: { model.setScope(key, $0) }))
            hint(L10n.text("settings.scope." + name + "Hint"))
        }
    }
    private func hint(_ text: String) -> some View { Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

private struct ClipboardSettingsSections: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var clipboard: ClipboardHistory
    var window: () -> NSWindow?
    @State private var confirmingClear = false

    @ViewBuilder var body: some View {
        Section(L10n.text("settings.clipboard")) {
            Toggle(L10n.text("settings.clipboardEnabled"), isOn: Binding(get: { clipboard.enabled }, set: clipboard.setEnabled))
            Text(L10n.text("settings.clipboardHint")).font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("settings.clipboardAccessibilityHint")).font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.text("settings.clipboardOpenAccessibility")) {
                let title = L10n.text("settings.clipboardOpenAccessibility")
                let setting = SystemSetting(id: "clipboardPasteAccessibility", englishName: title, chineseName: title,
                    symbol: "hand.raised", url: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!,
                    fallbackURL: SystemSettingsCatalog.entries.first(where: { $0.id == "privacysecurity" })?.url)
                _ = SystemSettingsCatalog.open(setting)
            }
            Toggle(L10n.text("settings.clipboardPaused"), isOn: Binding(get: { clipboard.paused }, set: clipboard.setPaused))
                .disabled(!clipboard.enabled)
            HStack {
                Stepper(value: Binding(get: { clipboard.retentionDays }, set: { clipboard.setRetention(days: $0, items: clipboard.maxItems) }), in: 1...365) {
                    Text(L10n.text("settings.clipboardRetentionDays", String(clipboard.retentionDays)))
                }
                TextField(L10n.text("settings.clipboardRetentionDays", String(clipboard.retentionDays)), value: Binding(
                    get: { clipboard.retentionDays }, set: { clipboard.setRetention(days: min(365, max(1, $0)), items: clipboard.maxItems) }), format: .number)
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 70)
            }
            HStack {
                Stepper(value: Binding(get: { clipboard.maxItems }, set: { clipboard.setRetention(days: clipboard.retentionDays, items: $0) }), in: 1...10_000) {
                    Text(L10n.text("settings.clipboardMaxItems", String(clipboard.maxItems)))
                }
                TextField(L10n.text("settings.clipboardMaxItems", String(clipboard.maxItems)), value: Binding(
                    get: { clipboard.maxItems }, set: { clipboard.setRetention(days: clipboard.retentionDays, items: min(10_000, max(1, $0))) }), format: .number)
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 70)
            }
            Text(L10n.text("settings.clipboardSavedItems", String(clipboard.entries.count)))
                .foregroundStyle(.secondary)
            if clipboard.needsAccess {
                Text(L10n.text("settings.clipboardNeedsAccess")).font(.footnote)
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("settings.clipboardPermissionBreadcrumb")).font(.footnote)
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L10n.text("settings.openPermissions")) {
                    if let setting = SystemSettingsCatalog.entries.first(where: { $0.id == "privacysecurity" }) {
                        _ = SystemSettingsCatalog.open(setting)
                    }
                }
                .help(L10n.text("settings.clipboardPermissionBreadcrumb"))
            }
            if let error = clipboard.error {
                Text(L10n.text("settings.clipboardError", error)).font(.footnote)
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button(L10n.text("clipboard.authorizeStorage")) { clipboard.requestPersistenceAccess() }
                    .disabled(clipboard.requestingPersistenceAccess)
            }
        }
        Section {
            if clipboard.excludedAppIDs.isEmpty {
                Text(L10n.text("settings.clipboardNoExcluded")).foregroundStyle(.secondary)
            }
            ForEach(clipboard.excludedAppIDs.sorted(), id: \.self) { identifier in
                HStack {
                    Text(identifier).lineLimit(1).truncationMode(.middle).help(identifier)
                    Spacer()
                    Button { model.removeExcludedApplication(identifier) } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .accessibilityLabel(L10n.text("settings.clipboardRemoveExcluded", identifier))
                }
            }
            Button(L10n.text("settings.clipboardAddExcluded")) { model.addExcludedApplications(in: window()) }
        } header: { Text(L10n.text("settings.clipboardExcluded")) }
          footer: { Text(L10n.text("settings.clipboardExcludedHint")).font(.footnote).foregroundStyle(.secondary) }
        Section {
            Button(L10n.text("settings.clipboardClear"), role: .destructive) { confirmingClear = true }
                .disabled(clipboard.entries.isEmpty)
                .confirmationDialog(L10n.text("settings.clipboardClearTitle"), isPresented: $confirmingClear, titleVisibility: .visible) {
                    Button(L10n.text("settings.clipboardClear"), role: .destructive) { clipboard.clear() }
                    Button(L10n.text("settings.cancel"), role: .cancel) {}
                } message: { Text(L10n.text("settings.clipboardClearMessage")) }
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var model: SettingsModel
    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onBegin = { [weak model, weak button] in model?.beginRecording(in: button?.window) }
        button.onCancel = { [weak model] in model?.cancelRecording() }
        return button
    }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.recording = model.recording
        button.title = model.recording ? L10n.text("settings.record") : Shortcut.symbols(keyCode: model.keyCode, modifiers: model.modifiers)
        button.needsDisplay = true
    }
}

private final class RecorderButton: NSButton {
    var recording = false
    var onBegin: (() -> Void)?, onCancel: (() -> Void)?
    init() {
        super.init(frame: .zero); isBordered = false
        font = .systemFont(ofSize: 12.5, weight: .medium)
        setButtonType(.momentaryPushIn)
        target = self; action = #selector(begin)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    @objc private func begin() { window?.makeFirstResponder(self); onBegin?() }
    override func mouseDown(with event: NSEvent) { begin() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 49 || event.keyCode == 36 { begin() } else { super.keyDown(with: event) } }
    override func resignFirstResponder() -> Bool { onCancel?(); return super.resignFirstResponder() }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        NSColor.labelColor.withAlphaComponent(0.07).setFill(); path.fill()
        if recording {
            let pixel = 1 / (window?.backingScaleFactor ?? 2)
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: pixel / 2, dy: pixel / 2), xRadius: 6, yRadius: 6)
            border.lineWidth = pixel; border.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font!, .foregroundColor: NSColor.labelColor]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

final class SettingsWindow: NSWindow {
    weak var settingsModel: SettingsModel?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // The accessory app has no Edit menu to dispatch field-editor commands.
        return super.performKeyEquivalent(with: event)
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel
    init(model: SettingsModel) {
        self.model = model
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: model.contentHeight), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.settingsModel = model
        window.title = L10n.text("settings.title"); window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: SettingsForm(model: model, window: { [weak window] in window }))
        model.onContentChange = { [weak self] in self?.resizeToContent() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() {
        guard let window else { return }
        if !window.isVisible { model.startRefreshing(); resizeToContent(); window.center() }
        window.makeKeyAndOrderFront(nil)
    }
    private func resizeToContent() {
        window?.title = L10n.text("settings.title")
        window?.setContentSize(NSSize(width: 540, height: model.contentHeight))
    }
    func windowWillClose(_ notification: Notification) { model.stopRefreshing() }
    func windowDidResignKey(_ notification: Notification) { model.cancelRecording() }
    func windowDidBecomeKey(_ notification: Notification) {
        model.refresh()
        if !model.recording { model.onRetryHotKey?() }
    }
}
