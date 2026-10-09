import AppKit
import Quartz
import Combine
import OilFindCore

final class SearchViewController: NSViewController, NSWindowDelegate, NSMenuDelegate {
    let searchField = SearchField(frame: .zero)
    let filters = FilterBar(frame: .zero)
    let scopes = ScopeBar(frame: .zero)
    let results = ResultsView(frame: .zero)
    let footer = FooterBar(frame: .zero)
    let quickLook = QuickLook()
    private let topLine = SeparatorView(), bottomLine = SeparatorView()
    private let empty = StateView(.empty), indexing = StateView(.indexing)
    let syntax = SyntaxReference(frame: .zero)
    private(set) var syntaxVisible = false
    private var diagnostics: [QueryDiagnostic] = []
    private var snapshotNoAccess = false
    private let snapshot: Bool
    let applications: ApplicationCatalog
    let clipboard: ClipboardHistory
    let pasteController: ClipboardPasteController
    private let coordinator = SearchCoordinator()
    private var subscriptions: Set<AnyCancellable> = []
    private var userNavigated = false, preserveFirstSelection = false
    private var requestedScope = SearchScope.all
    private var clipboardPreview: NSPanel?
    private var clipboardActionGeneration = 0
    private var pendingClipboardID: UUID?
    private var timer: Timer?
    private var stateView: NSView?
    private var languageObserver: NSObjectProtocol?
    private var menuTracking = false, dragging = false
    private var trashing: Set<URL> = []
    var manager: IndexManager?
    var hidePanel: (() -> Void)?
    var onSettings: (() -> Void)?
    init(snapshot: Bool, clipboard: ClipboardHistory? = nil) {
        self.snapshot = snapshot
        applications = ApplicationCatalog(snapshot: snapshot)
        self.clipboard = clipboard ?? ClipboardHistory(snapshot: snapshot)
        pasteController = ClipboardPasteController(snapshot: snapshot)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = PanelSurface(snapshot: snapshot) }
    override func viewDidLoad() {
        super.viewDidLoad()
        [searchField, topLine, scopes, filters, results, empty, indexing, bottomLine, footer, syntax].forEach(view.addSubview)
        filters.isHidden = true
        scopes.onChange = { [weak self] scope in self?.selectScope(scope) }
        coordinator.onUpdate = { [weak self] found, refresh in
            guard let self else { return }
            self.diagnostics = found.fileResult?.query.diagnostics ?? []
            if refresh || self.preserveFirstSelection && self.results.snapshot != nil {
                self.results.refresh(found, preserveSelection: self.userNavigated || self.preserveFirstSelection)
            } else {
                self.results.show(found); self.snapshotDidChange(found)
            }
        }
        results.onSnapshotApplied = { [weak self] found in self?.snapshotDidChange(found) }
        applications.$revision.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshSources() }.store(in: &subscriptions)
        clipboard.$entries.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            if self?.scopes.scope == .clipboard { self?.refreshSources() }
        }.store(in: &subscriptions)
        clipboard.$enabled.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            if self?.scopes.scope == .clipboard { self?.refreshSources() }
        }.store(in: &subscriptions)
        clipboard.$error.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshClipboardStatus() }.store(in: &subscriptions)
        clipboard.$needsAccess.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshClipboardStatus() }.store(in: &subscriptions)
        syntax.isHidden = true
        syntax.onExample = { [weak self] example in
            guard let self else { return }; self.searchField.text = example; self.toggleSyntax(false); self.searchField.focus(); self.startSearch()
        }
        searchField.onSelectionChange = { [weak self] in self?.refreshDiagnostics() }
        searchField.onChange = { [weak self] in self?.startSearch() }
        searchField.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        filters.onChange = { [weak self] in self?.requestedScope = .files; self?.scopes.scope = .files; self?.searchField.focus(); self?.startSearch() }
        filters.onSortChange = { [weak self] in
            guard let self, !self.snapshot else { return }
            UserDefaults.standard.set(FilterBar.sortName(self.filters.options.sort), forKey: "sortKey")
            UserDefaults.standard.set(self.filters.options.ascending, forKey: "sortAscending")
        }
        filters.onMenuTracking = { [weak self] tracking in
            self?.menuTracking = tracking
            if !tracking { self?.hideIfInactive() }
        }
        results.onOpen = { [weak self] in self?.openSelected() }
        results.canPerformFileActions = { [weak self] in self?.resultIsCurrent == true && self?.stateView == nil }
        results.onUserNavigation = { [weak self] in self?.userNavigated = true }
        results.onSelection = { [weak self] in
            if let self, let pending = self.pendingClipboardID,
               self.results.selectedLauncherRow?.identity != "clip:" + pending.uuidString { self.invalidateClipboardCopy() }
            self?.quickLook.refresh()
            self?.updateActionHints()
        }
        results.onContextMenu = { [weak self] _ in self?.contextMenu() }
        results.onRefreshApplied = { [weak self] result in self?.resultDidChange(result) }
        results.onDragging = { [weak self] active in
            self?.dragging = active
            if !active { self?.hideIfInactive() }
        }
        quickLook.selectedURL = { [weak self] in self?.selectedURL }
        quickLook.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        searchField.onSettings = { [weak self] in self?.onSettings?() }
        languageObserver = NotificationCenter.default.addObserver(forName: L10n.changed, object: nil, queue: .main) { [weak self] _ in self?.localize() }
        setState(.empty)
        if !snapshot {
            filters.options = SettingsPreferences.searchOptions()
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.refreshProgress() }
        }
        localize()
    }
    deinit {
        timer?.invalidate()
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    }
    private func localize() {
        scopes.localize(); filters.localize(); footer.localize(); empty.localize(); indexing.localize(); syntax.localize(); results.localize()
        searchField.localize()
        if let found = results.snapshot { snapshotDidChange(found) }
        else if let result = results.result { updateFooter(result) }
        else if stateView === indexing { footer.text = L10n.text("footer.indexing", Presentation.countText(indexing.count)) }
        refreshProgress()
        view.needsLayout = true
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        let w = view.bounds.width, h = view.bounds.height, px = Theme.pixel(view)
        searchField.frame = NSRect(x: 0, y: 0, width: w, height: 64)
        topLine.frame = NSRect(x: 0, y: 64, width: w, height: px)
        scopes.frame = NSRect(x: 0, y: 64 + px, width: w, height: 40)
        filters.isHidden = scopes.scope != .files
        filters.frame = NSRect(x: 0, y: 104 + px, width: w, height: 40)
        let top: CGFloat = (filters.isHidden ? 104 : 144) + px
        let region = NSRect(x: 0, y: top, width: w, height: max(0, h - top - 34 - px))
        [results, empty, indexing, syntax].forEach { $0.frame = region }
        bottomLine.frame = NSRect(x: 0, y: h - 34 - px, width: w, height: px)
        footer.frame = NSRect(x: 0, y: h - 34, width: w, height: 34)
    }
    func setState(_ state: StateView.State?) {
        _ = view
        let previous: NSView = stateView ?? (results as NSView)
        stateView = state == .empty ? empty : state == .indexing ? indexing : nil
        let target: NSView = stateView ?? (results as NSView)
        footer.actionable = !syntaxVisible && stateView == nil && results.rowCount > 0
        guard previous !== target else { return }
        let animate = !snapshot && view.window?.isVisible == true && previous !== target
        for item in [results, empty, indexing] as [NSView] {
            let visible = item === target
            if visible { item.isHidden = false }
            Theme.Motion.opacity(item, to: visible ? 1 : 0, using: animate ? Theme.Motion.basic(Theme.Motion.crossfade) : nil)
            if !visible {
                if animate {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.crossfade) { [weak self, weak item] in
                        guard let self, let item else { return }
                        let current: NSView = self.stateView ?? (self.results as NSView)
                        if item !== current { item.isHidden = true }
                    }
                } else { item.isHidden = true }
            }
        }
    }
    func panelWillShow() {
        if scopes.scope == .clipboard { _ = clipboard.search("") }
        if !snapshot { startSearch(preserveSelection: true); return }
        let currentQuery = Query.parse(searchField.text, store: manager?.store)
        if let store = manager?.store, let result = results.result,
           result.store === store, store.read({ store.version == result.storeVersion }),
           result.query.raw == currentQuery.raw, !currentQuery.isTimeDependent,
           Date().timeIntervalSince(result.createdAt) <= 600 { return }
        startSearch(preserveSelection: true)
    }
    func indexChanged() {
        if view.window?.isVisible == true { coordinator.refreshFiles(store: manager?.store) }
    }
    func managerStateChanged(_ state: IndexManager.State) {
        refreshProgress()
        if state == .ready { coordinator.refreshFiles(store: manager?.store) }
    }
    private func refreshProgress() {
        if (results.snapshot == nil || scopes.scope == .files), let result = results.result, result.query.isEmpty { updateFooter(result) }
        guard let manager else { return }
        searchField.indexing = manager.state == .scanning || manager.isRescanning
        if manager.store == nil && scopes.scope == .files {
            let count = manager.scannedCount
            indexing.updateCount(count); footer.text = L10n.text("footer.indexing", Presentation.countText(count))
        }
    }
    func startSearch(preserveSelection: Bool = false) {
        invalidateClipboardCopy()
        _ = view
        preserveFirstSelection = preserveSelection; userNavigated = false; results.cancelPendingRefresh()
        footer.actionable = false
        let composing = searchField.editor.hasMarkedText()
        let effective = SearchRoute.effectiveScope(searchField.text, requested: requestedScope, composing: composing)
        if effective != scopes.scope { scopes.scope = effective; view.needsLayout = true }
        var options = filters.options
        if scopes.scope == .all { options.kind = nil }
        if !snapshot { options.pinyin = UserDefaults.standard.bool(forKey: "pinyinEnabled") }
        let defaults = UserDefaults.standard
        coordinator.search(raw: searchField.text, scope: scopes.scope, options: options, store: manager?.store,
                           editingRange: searchField.input.currentEditor() == nil ? nil : searchField.editor.selectedRange(), composing: composing,
                           apps: applications.apps, clipboard: clipboard.entries, clipboardEnabled: clipboard.enabled,
                           calculator: snapshot || defaults.bool(forKey: "calculatorEnabled"), web: snapshot || defaults.bool(forKey: "webSearchEnabled"),
                           engine: WebSearchEngine(rawValue: defaults.string(forKey: "webSearchEngine") ?? "duckDuckGo") ?? .duckDuckGo)
    }
    func startSources() {
        guard !snapshot else { return }
        applications.start(excludedPaths: UserDefaults.standard.stringArray(forKey: "userExcludedPaths") ?? [])
        clipboard.start()
    }
    func stopSources() { applications.stop(); clipboard.stop() }
    func selectScope(_ scope: SearchScope) {
        if scope == .clipboard { _ = clipboard.search("") }
        requestedScope = scope
        scopes.scope = scope; quickLook.close(); clipboardPreview?.close(); view.needsLayout = true
        searchField.focus(); startSearch()
    }
    private func refreshSources() {
        guard isViewLoaded, !snapshot else { return }
        let defaults = UserDefaults.standard
        coordinator.refreshSources(apps: applications.apps, clipboard: clipboard.entries, clipboardEnabled: clipboard.enabled,
                                   calculator: snapshot || defaults.bool(forKey: "calculatorEnabled"), web: snapshot || defaults.bool(forKey: "webSearchEnabled"),
                                   engine: WebSearchEngine(rawValue: defaults.string(forKey: "webSearchEngine") ?? "duckDuckGo") ?? .duckDuckGo)
    }
    private func snapshotDidChange(_ found: SearchSnapshot) {
        if let file = found.fileResult { configureEmpty(file) }
        else { empty.configure(diagnostic: nil, hasNoAccess: false) }
        setState(found.count == 0 ? (found.filesPending ? .indexing : .empty) : nil)
        footer.warning = !diagnostics.isEmpty
        if found.scope == .files, let file = found.fileResult { updateFooter(file) }
        else if found.scope == .clipboard {
            footer.text = clipboard.error ?? (clipboard.needsAccess ? L10n.text("clipboard.accessHint") : L10n.text("clipboard.count", String(found.count)))
        } else { footer.text = L10n.text("launcher.count", String(found.count)) }
        updateActionHints(); refreshProgress()
    }
    private func refreshClipboardStatus() {
        guard scopes.scope == .clipboard, let found = results.snapshot else { return }
        snapshotDidChange(found)
    }
    private func updateActionHints() { footer.setRow(results.selectedLauncherRow) }
    func present(_ result: SearchResult, selection: Int = 0, resetScroll: Bool = true) {
        results.show(result, selection: selection, resetScroll: resetScroll)
        resultDidChange(result)
    }
    private func editingQuery(store: IndexStore?) -> Query {
        Query.parse(searchField.text, store: store, editingRange: searchField.input.currentEditor() == nil ? nil : searchField.editor.selectedRange(), isComposing: searchField.editor.hasMarkedText())
    }
    private func refreshDiagnostics() {
        guard results.snapshot == nil || scopes.scope == .files else { return }
        let query = editingQuery(store: manager?.store ?? results.result?.store)
        guard let result = results.result, result.query.raw == query.raw else { return }
        diagnostics = query.diagnostics
        configureEmpty(result); updateFooter(result)
    }
    private func configureEmpty(_ result: SearchResult) {
        empty.configure(diagnostic: diagnostics.first, hasNoAccess: snapshotNoAccess || result.store.read { result.store.coverage[.noAccess].count > 0 })
    }
    func toggleSyntax(_ show: Bool? = nil) {
        let visible = show ?? !syntaxVisible
        syntaxVisible = visible
        footer.actionable = !visible && stateView == nil && results.rowCount > 0
        syntax.isHidden = false
        Theme.Motion.opacity(syntax, to: visible ? 1 : 0, using: snapshot ? nil : Theme.Motion.chip)
        if let layer = syntax.layer { Theme.Motion.animate(layer, "transform.translation.y", to: visible ? 0 : 8, using: snapshot ? nil : Theme.Motion.chip) }
        if !visible {
            if snapshot { syntax.isHidden = true }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.chip.settlingDuration) { [weak self] in if self?.syntaxVisible == false { self?.syntax.isHidden = true } } }
        }
    }
    private func resultDidChange(_ result: SearchResult) {
        configureEmpty(result)
        setState(result.total == 0 ? .empty : nil)
        updateFooter(result)
        refreshProgress()
    }
    private func updateFooter(_ result: SearchResult) {
        footer.warning = !diagnostics.isEmpty
        if let diagnostic = diagnostics.first { footer.text = L10n.diagnostic(diagnostic); return }
        if result.query.isEmpty {
            let count = Presentation.countText(result.store.read { result.store.liveCount })
            footer.text = L10n.text("footer.recent", count)
        } else {
            footer.text = L10n.text(result.sortedCount < result.total ? "footer.partial" : "footer.results", Presentation.countText(result.total), Presentation.elapsedText(result.elapsedMs))
        }
    }
    func prepareSnapshot(state: String, query: String, options: SearchOptions, store: IndexStore?, selection: Int) throws {
        _ = view
        requestedScope = .files; scopes.scope = .files; view.needsLayout = true
        searchField.text = state == "recent" ? "" : query; filters.options = options
        if state == "indexing" {
            setState(.indexing); indexing.updateCount(1_234_567); searchField.indexing = true
            footer.text = L10n.text("footer.indexing", Presentation.countText(1_234_567)); return
        }
        guard let store, let found = Searcher.search(Query.parse(searchField.text, store: store), options: options, in: store) else { throw SnapshotError.failed("Cannot search snapshot index") }
        diagnostics = Query.parse(searchField.text, store: store).diagnostics
        snapshotNoAccess = state == "no-access"
        present(found, selection: selection)
        if state == "syntax" { toggleSyntax(true) }
        if state == "toast", let item = results.selectedItem { footer.showToast(.copiedPath, value: item.path, snapshot: true) }
        if state == "empty" {
            setState(.empty)
            footer.text = L10n.text("footer.results", Presentation.countText(0), Presentation.elapsedText(found.elapsedMs))
        }
    }
    func prepareLauncherSnapshot(_ found: SearchSnapshot, clipboardEntries: [ClipboardEntry] = [], selection: Int = 0) throws {
        guard snapshot else { throw SnapshotError.failed("Launcher fixtures require snapshot mode") }
        _ = view
        clipboard.prepareSnapshot(clipboardEntries)
        requestedScope = found.scope; scopes.scope = found.scope; searchField.text = found.raw; view.needsLayout = true
        results.show(found, selection: selection)
        diagnostics = found.fileResult?.query.diagnostics ?? []
        snapshotDidChange(found)
    }
    private var selectedURL: URL? {
        guard stateView == nil, resultIsCurrent else { return nil }
        return results.selectedItem.map { URL(fileURLWithPath: $0.path) }
    }
    private var resultIsCurrent: Bool {
        guard let found = results.snapshot else { return true }
        return found.raw == searchField.text && found.scope == scopes.scope
    }
    func handleKey(_ event: NSEvent) -> Bool {
        if (view.window as? SearchPanel)?.hiding == true { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command), option = flags.contains(.option)
        if searchField.editor.hasMarkedText() { return false }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // A nonactivating panel has no Edit menu to dispatch text shortcuts.
        if flags.intersection([.command, .control, .option, .shift]) == .command,
           let editor = searchField.input.currentEditor() {
            switch key {
            case "a": editor.selectAll(nil); return true
            case "c" where editor.selectedRange.length > 0: editor.copy(nil); return true
            case "x": editor.cut(nil); return true
            case "v": editor.paste(nil); return true
            default: break
            }
        }
        if command && event.keyCode == 44 { toggleSyntax(); return true }
        if syntaxVisible && event.keyCode == 53 { toggleSyntax(false); return true }
        if syntaxVisible { return false }
        switch event.keyCode {
        case 126: userNavigated = true; if command { results.select(0, repeatKey: event.isARepeat) } else { results.move(-1, repeatKey: event.isARepeat) }; return true
        case 125: userNavigated = true; if command { results.select(results.rowCount - 1, repeatKey: event.isARepeat) } else { results.move(1, repeatKey: event.isARepeat) }; return true
        case 116: userNavigated = true; results.page(-1, repeatKey: event.isARepeat); return true
        case 121: userNavigated = true; results.page(1, repeatKey: event.isARepeat); return true
        case 36, 76: if command { revealSelected() } else { openSelected() }; return true
        case 48:
            if scopes.scope == .files { filters.cycle(flags.contains(.shift) ? -1 : 1) }
            else { let index = SearchScope.allCases.firstIndex(of: scopes.scope)!; selectScope(SearchScope.allCases[(index + (flags.contains(.shift) ? 4 : 1)) % 5]) }
            return true
        case 53: if quickLook.isVisible { quickLook.close() } else if clipboardPreview?.isVisible == true { clipboardPreview?.close() } else { hidePanel?() }; return true
        case 51 where command: trashSelected(); return true
        default: break
        }
        guard command else { return false }
        switch key {
        case "y": previewSelected(); return true
        case "c":
            if option { copyName(); return true }
            if searchField.input.currentEditor()?.selectedRange.length ?? 0 > 0 { return false }
            copyPath(); return true
        case "w": hidePanel?(); return true
        case ",": onSettings?(); return true
        case "0"..."9":
            let number = Int(key) ?? 0
            if option && number > 0 { requestedScope = .files; scopes.scope = .files; view.needsLayout = true; filters.select(number - 1) }
            else if !option && number < 5 { selectScope(SearchScope.allCases[number]) }
            return true
        default: return false
        }
    }
    private func openSelected() {
        guard stateView == nil, resultIsCurrent else { return }
        if let row = results.selectedLauncherRow {
            switch row {
            case .app(let app):
                guard FileManager.default.fileExists(atPath: app.path), NSWorkspace.shared.open(URL(fileURLWithPath: app.path)) else { NSSound.beep(); return }
                applications.recordLaunch(app); hidePanel?(); return
            case .setting(let setting):
                if SystemSettingsCatalog.open(setting) { hidePanel?() } else { NSSound.beep() }; return
            case .clipboard(let entry):
                copyClipboardEntry(entry) { [weak self] in
                    self?.pasteController.pasteCurrentClipboard(hidePanel: { [weak self] completion in
                        guard let panel = self?.view.window as? SearchPanel else { self?.hidePanel?(); completion(); return }
                        panel.hide(source: .interaction, completion: completion)
                    }, completion: { [weak self] outcome in
                        guard case .copiedOnly = outcome, let self else { return }
                        (self.view.window as? SearchPanel)?.show(source: .interaction)
                        self.footer.showMessage(L10n.text("clipboard.copiedOnly"))
                    })
                }; return
            case .answer(let answer): copyText(answer.value); return
            case .url(let url), .web(_, let url):
                if NSWorkspace.shared.open(url) { hidePanel?() } else { NSSound.beep() }; return
            case .enableClipboard: clipboard.setEnabled(true); startSearch(); return
            case .file: break
            }
        }
        guard stateView == nil, (view.window as? SearchPanel)?.hiding != true, let url = selectedURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { NSSound.beep(); return }
        results.pressOpen { [weak self] in
            guard NSWorkspace.shared.open(url) else { NSSound.beep(); return }
            self?.hidePanel?()
        }
    }
    private func revealSelected() {
        guard stateView == nil, resultIsCurrent else { return }
        if case .clipboard(let entry)? = results.selectedLauncherRow, entry.filePaths != nil {
            NSWorkspace.shared.activateFileViewerSelecting(entry.fileURLs); hidePanel?(); return
        }
        guard let url = selectedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url]); hidePanel?()
    }
    private func copyPath() {
        guard stateView == nil, resultIsCurrent else { return }
        if let row = results.selectedLauncherRow {
            switch row {
            case .clipboard(let entry):
                copyClipboardEntry(entry) { [weak self] in self?.footer.showMessage(L10n.text("clipboard.copied")) }; return
            case .answer(let answer): copyText(answer.value); return
            case .setting(let setting): copyText(setting.name); return
            case .app(let app): copyText(app.path); return
            case .url(let url), .web(_, let url): copyText(url.absoluteString); return
            case .enableClipboard: return
            case .file: break
            }
        }
        guard stateView == nil, let url = selectedURL else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([url as NSURL]); NSPasteboard.general.setString(url.path, forType: .string)
        footer.showToast(.copiedPath, value: url.path)
    }
    private func copyName() {
        guard stateView == nil, resultIsCurrent, let item = results.selectedItem else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.name, forType: .string)
        footer.showToast(.copiedName, value: item.name)
    }
    private func trashSelected() {
        guard stateView == nil, resultIsCurrent else { return }
        if case .clipboard(let entry)? = results.selectedLauncherRow { clipboard.remove(entry.id); return }
        guard stateView == nil, let url = selectedURL, let item = results.selectedItem else { return }
        guard FileManager.default.fileExists(atPath: url.path), trashing.insert(url).inserted else { return }
        NSWorkspace.shared.recycle([url]) { [weak self] _, error in
            DispatchQueue.main.async {
                self?.trashing.remove(url)
                if error != nil { NSSound.beep() }
                else { self?.footer.showToast(.trashed, value: item.name) }
            }
        }
    }
    private func contextMenu() -> NSMenu {
        let menu = NSMenu(); menu.delegate = self
        if let row = results.selectedLauncherRow, results.selectedItem == nil {
            var actions: [(String, Int)] = [("hint.open", 0), ("launcher.copy", 4)]
            if case .clipboard(let entry) = row {
                actions = [("clipboard.paste", 0), ("launcher.copy", 4), ("hint.preview", 2)]
                if entry.filePaths != nil { actions += [("hint.reveal", 1), ("clipboard.copyPaths", 8)] }
                actions.append(("clipboard.delete", 7))
            }
            if case .enableClipboard = row { actions = [("clipboard.enable", 0)] }
            for (key, tag) in actions {
                let item = NSMenuItem(title: L10n.text(key), action: #selector(contextAction(_:)), keyEquivalent: "")
                item.target = self; item.tag = tag; menu.addItem(item)
            }
            return menu
        }
        for (i, key) in ["open", "reveal", "preview", "-", "copyPath", "copyName", "-", "trash"].enumerated() {
            if key == "-" { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: L10n.text("ctx." + key), action: #selector(contextAction(_:)), keyEquivalent: "")
            item.target = self; item.tag = i; menu.addItem(item)
        }
        return menu
    }
    @objc private func contextAction(_ item: NSMenuItem) {
        switch item.tag {
        case 0: openSelected(); case 1: revealSelected(); case 2: previewSelected(); case 4: copyPath()
        case 5: copyName(); case 7: trashSelected()
        case 8:
            guard resultIsCurrent, case .clipboard(let entry)? = results.selectedLauncherRow else { return }
            copyText(entry.text)
        default: break
        }
    }
    private func invalidateClipboardCopy() {
        clipboardActionGeneration += 1
        pendingClipboardID = nil
        clipboard.cancelCopy()
    }
    private func copyClipboardEntry(_ entry: ClipboardEntry, completion: @escaping () -> Void) {
        invalidateClipboardCopy()
        let generation = clipboardActionGeneration
        let query = searchField.text, scope = scopes.scope
        pendingClipboardID = entry.id
        if entry.filePaths != nil { footer.showMessage(L10n.text("clipboard.checkingFiles")) }
        clipboard.copy(entry, isCurrent: { [weak self] in
            guard let self, self.clipboardActionGeneration == generation, self.stateView == nil,
                  self.searchField.text == query, self.scopes.scope == scope, self.resultIsCurrent,
                  case .clipboard(let selected)? = self.results.selectedLauncherRow,
                  selected.id == entry.id, selected.content == entry.content else { return false }
            if let window = self.view.window {
                return window.isVisible && window.isKeyWindow && (window as? SearchPanel)?.hiding != true
            }
            return true
        }, completion: { [weak self] outcome in
            guard let self, self.clipboardActionGeneration == generation else { return }
            self.pendingClipboardID = nil
            switch outcome {
            case .copied: completion()
            case .failed: self.footer.showMessage(self.clipboard.error ?? L10n.text("clipboard.failure.copyFailed")); NSSound.beep()
            case .cancelled: self.refreshClipboardStatus()
            }
        })
    }
    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        footer.showMessage(L10n.text("clipboard.copied"))
    }
    private func previewSelected() {
        guard stateView == nil, resultIsCurrent else { return }
        guard case .clipboard(let entry)? = results.selectedLauncherRow else { quickLook.toggle(); return }
        if clipboardPreview?.isVisible == true { clipboardPreview?.close(); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 380), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = entry.filePaths == nil ? L10n.text("scope.clipboard") : entry.displayTitle
        panel.isReleasedWhenClosed = false; panel.level = .floating
        let scroll = NSScrollView(frame: panel.contentView!.bounds); scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds); text.isEditable = false; text.string = entry.text; text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.textContainerInset = NSSize(width: 16, height: 16); text.autoresizingMask = [.width]; scroll.documentView = text
        panel.contentView = scroll; panel.center(); panel.orderFrontRegardless(); clipboardPreview = panel
    }
    func panelDidHide() { invalidateClipboardCopy(); quickLook.close(); clipboardPreview?.close() }
    func menuWillOpen(_ menu: NSMenu) { menuTracking = true }
    func menuDidClose(_ menu: NSMenu) { menuTracking = false; hideIfInactive() }
    private func hideIfInactive() {
        if view.window?.isKeyWindow == false && !quickLook.isVisible && clipboardPreview?.isVisible != true && !menuTracking && !dragging { hidePanel?() }
    }
    func windowDidResignKey(_ notification: Notification) {
        // Quick Look visibility settles after the key-window transition.
        DispatchQueue.main.async { [weak self] in self?.hideIfInactive() }
    }
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        (client as? NSTextField) === searchField.input ? searchField.editor : nil
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { selectedURL != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { quickLook.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { quickLook.end(panel) }
}
