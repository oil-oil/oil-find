import AppKit
import SwiftUI
import ServiceManagement
import Carbon
import OilFindCore

final class SettingsModel: ObservableObject {
    @Published private(set) var language: AppLanguage
    @Published var launchAtLogin: Bool
    let update: UpdateManager
    private var languageObserver: NSObjectProtocol?
    private let languageDefaults: UserDefaults
    private var coverageExplanation: CoverageExplanation?
    private let snapshot: Bool
    @Published var loginError: String?
    @Published var pinyinEnabled: Bool
    @Published var excludedPaths: [String]
    @Published var keyCode: UInt32
    @Published var modifiers: UInt32
    @Published var indexDependencyDirs: Bool
    @Published var indexPackageContents: Bool
    @Published var indexUserLibrary: Bool
    @Published var indexSystemDirs: Bool
    @Published var recording = false
    @Published var shortcutError: String?
    @Published var coverage = CoverageStats()
    @Published var explanation: String?
    @Published var expandedCoverage: Set<String> = []
    @Published var indexedCount = 0
    @Published var scanDate: Date?
    @Published var granted = false
    @Published var rebuilding = false
    weak var manager: IndexManager?
    var additionalSources: (() -> [SearchSource])?
    private var inspectionGeneration = 0
    var onConfigChange: (() -> Void)?
    var onPinyinChange: (() -> Void)?
    var suspendHotKey: (() -> Void)?
    var registerHotKey: ((UInt32, UInt32) -> Bool)?
    var onContentChange: (() -> Void)?
    private let snapshotStore: IndexStore?
    private var keyMonitor: Any?
    private var timer: Timer?

    init(snapshotStore: IndexStore? = nil, snapshot: Bool = false, languageDefaults: UserDefaults = .standard) {
        self.snapshot = snapshot
        self.languageDefaults = languageDefaults
        self.language = L10n.language
        self.update = snapshot ? UpdateManager(snapshot: true) : .shared
        launchAtLogin = snapshot ? false : SMAppService.mainApp.status == .enabled
        if !snapshot { SettingsPreferences.register() }
        let defaults = UserDefaults.standard
        indexDependencyDirs = !snapshot && defaults.bool(forKey: "indexDependencyDirs")
        indexPackageContents = !snapshot && defaults.bool(forKey: "indexPackageContents")
        indexUserLibrary = !snapshot && defaults.bool(forKey: "indexUserLibrary")
        indexSystemDirs = !snapshot && defaults.bool(forKey: "indexSystemDirs")
        pinyinEnabled = snapshot ? true : defaults.bool(forKey: "pinyinEnabled")
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
    // Grouped Form owns scrolling; the content grows until the specified 600 pt cap.
    var contentHeight: CGFloat {
        min(600, 880 - (granted ? 30 : 0) + CGFloat(max(0, excludedPaths.count - 1)) * 32
            + (loginError == nil ? 0 : 40) + (shortcutError == nil ? 0 : 28))
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
        var stats = CoverageStats()
        if let store = snapshotStore ?? manager?.store {
            let values = store.read { (store.liveCount, store.scanFinishedAt, store.coverage) }
            stats = values.2
            indexedCount = values.0
            scanDate = values.1 == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(values.1))
        } else { indexedCount = 0; scanDate = nil }
        if !snapshot { stats.refreshVolumes(excluding: Set((additionalSources?() ?? []).filter(\.isOnline).map { $0.store.rootPath })) }
        if coverage != stats { coverage = stats }
        if wasGranted != granted { onContentChange?() }
    }
    func checkFile(in window: NSWindow?) {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let path = panel.url?.path else { return }
            self.check(path: path)
        }
    }
    func check(path: String) {
        // Capture extension state on the main thread before inspecting the filesystem.
        let sources = (additionalSources?() ?? []).filter(\.isOnline), manager = manager
        inspectionGeneration += 1
        let generation = inspectionGeneration
        DispatchQueue.global(qos: .utility).async {
            let answer = sources.lazy.compactMap { $0.explain(path: path) }.first ?? manager?.explain(path: path) ?? .pending
            DispatchQueue.main.async {
                guard generation == self.inspectionGeneration else { return }
                self.coverageExplanation = answer; self.explanation = L10n.explanation(answer)
            }
        }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch { loginError = error.localizedDescription }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        onContentChange?()
    }
    func setPinyin(_ enabled: Bool) {
        pinyinEnabled = enabled; UserDefaults.standard.set(enabled, forKey: "pinyinEnabled")
        onPinyinChange?()
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
        UserDefaults.standard.set(enabled, forKey: key)
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
        excludedPaths = paths; UserDefaults.standard.set(paths, forKey: "userExcludedPaths")
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
    private func record(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { cancelRecording(); return }
        let reset = event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)
        let code = reset ? Shortcut.defaultKeyCode : UInt32(event.keyCode)
        let mask = reset ? Shortcut.defaultModifiers : HotKey.carbonModifiers(event.modifierFlags)
        guard mask & UInt32(cmdKey | controlKey | optionKey) != 0 else {
            shortcutError = L10n.text("settings.shortcutModifier"); onContentChange?(); return
        }
        if registerHotKey?(code, mask) == true {
            keyCode = code; modifiers = mask
            UserDefaults.standard.set(Int(code), forKey: "hotKeyCode")
            UserDefaults.standard.set(Int(mask), forKey: "hotKeyModifiers")
            shortcutError = nil
        } else {
            _ = registerHotKey?(keyCode, modifiers)
            shortcutError = L10n.text("settings.shortcutConflict")
        }
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
    var appExtension: ApplicationExtension?
    var window: () -> NSWindow?
    var body: some View {
        Form {
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
                    if let error = model.shortcutError { hint(error).foregroundStyle(.red) }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Toggle(L10n.text("settings.pinyin"), isOn: Binding(get: { model.pinyinEnabled }, set: model.setPinyin))
                    hint(L10n.text("settings.pinyinHint"))
                }
            }
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
            if let appExtension { appExtension.settingsSection(window: window) }
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
        .formStyle(.grouped).toggleStyle(.switch)
        .frame(width: 540, height: model.contentHeight)
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
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           let editor = firstResponder as? NSTextView, editor.isFieldEditor, !editor.hasMarkedText() {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": editor.selectAll(nil); return true
            case "c": editor.copy(nil); return true
            case "x": editor.cut(nil); return true
            case "v": editor.paste(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel
    init(model: SettingsModel, appExtension: ApplicationExtension? = nil) {
        self.model = model
        model.additionalSources = { [weak appExtension] in appExtension?.searchSources() ?? [] }
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: model.contentHeight), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.settingsModel = model
        window.title = L10n.text("settings.title"); window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: SettingsForm(model: model, appExtension: appExtension, window: { [weak window] in window }))
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
    func windowDidBecomeKey(_ notification: Notification) { model.refresh() }
}
