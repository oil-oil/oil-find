import AppKit
import Carbon
import ServiceManagement
import os
import OilFindCore

enum AppLog {
    static let logger = Logger(subsystem: "com.oiloil.find", category: "app")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let panel = SearchPanel()
    private var statusItem: NSStatusItem?
    private var localizedMenuItems: [(String, NSMenuItem)] = []
    private var languageObserver: NSObjectProtocol?
    private var hotKey: HotKey?
    private var actualKeyCode: UInt32?, actualModifiers: UInt32?
    private var shortcutRetryObserver: NSObjectProtocol?
    private var manager: IndexManager?
    private var settingsController: SettingsWindowController?
    private var updateItem: NSMenuItem?, checkUpdateItem: NSMenuItem?, quitItem: NSMenuItem?
    private var secondaryInstance = false
    private var openItem: NSMenuItem?, hotKeyFailureItem: NSMenuItem?
    private var permissionTimer: Timer?
    private var welcomeController: WelcomeWindowController?
    private var welcomeState: WelcomeState?
    private var indexStateStartedAt = ProcessInfo.processInfo.systemUptime
    private var limited = false
    private var countItem: NSMenuItem?, limitedItem: NSMenuItem?, loginItem: NSMenuItem?, rescanItem: NSMenuItem?
    static let dbURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Oil Find/index.oilfind")
    private static let showRequest = Notification.Name("com.oiloil.find.show")
    func applicationDidFinishLaunching(_ notification: Notification) {
        LegacyAuthorizationCleanup.run()
        DispatchQueue.global(qos: .utility).async { _ = Pinyin.shared }
        if let id = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            secondaryInstance = true
            DistributedNotificationCenter.default().postNotificationName(Self.showRequest, object: nil, userInfo: nil, deliverImmediately: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            return
        }
        UpdateManager.shared.start()
        UpdateManager.shared.onChange = { [weak self] in self?.refreshUpdateMenu() }
        NSApp.setActivationPolicy(.accessory)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reopenRequested(_:)), name: Self.showRequest, object: nil)
        let defaults = UserDefaults.standard
        let key = UInt32(clamping: defaults.integer(forKey: "hotKeyCode"))
        let modifiers = UInt32(clamping: defaults.integer(forKey: "hotKeyModifiers"))
        _ = registerHotKey(keyCode: key, modifiers: modifiers)
        buildMenu(keyCode: key, modifiers: modifiers)
        updateShortcutStatus()
        shortcutRetryObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.settingsController?.model.recording != true else { return }
            let wanted = UInt32(clamping: defaults.integer(forKey: "hotKeyCode"))
            let mask = UInt32(clamping: defaults.integer(forKey: "hotKeyModifiers"))
            if self.actualKeyCode != wanted || self.actualModifiers != mask { self.retryHotKey() }
        }
        languageObserver = NotificationCenter.default.addObserver(forName: L10n.changed, object: nil, queue: .main) { [weak self] _ in self?.localizeMenu() }
        panel.searchController.onSettings = { [weak self] in self?.showSettings() }
        panel.searchController.startSources()
        let fullDiskAccess = Permissions.hasFullDiskAccess()
        var state = WelcomeState(didFinishOnboarding: defaults.bool(forKey: "didFinishOnboarding"), skippedFullDiskAccess: defaults.bool(forKey: "skippedFullDiskAccess"), granted: fullDiskAccess)
        let indexRequest = state.launch()
        welcomeState = state
        AppLog.logger.info("launch hotkeyRegistered=\(self.hotKey != nil, privacy: .public) granted=\(fullDiskAccess, privacy: .public) welcome=\(state.isShowing, privacy: .public)")
        if state.isShowing {
            let controller = WelcomeWindowController(granted: fullDiskAccess)
            welcomeController = controller
            controller.model.onStart = { [weak self] in self?.finishWelcome() }
            controller.model.onSettings = { [weak self] in self?.showSettings() }
            controller.present()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self else { return }
                let granted = Permissions.hasFullDiskAccess()
                self.welcomeController?.model.granted = granted
                if granted { self.welcomeController?.model.waiting = false }
                if let limited = self.welcomeState?.permissionDetected(granted) { self.startIndex(limited: limited) }
            }
        }
        if let limited = indexRequest { startIndex(limited: limited) }
        if let failure = SystemUpdateFiles().cleanupAfterLaunch(application: Bundle.main.bundleURL, current: UpdateManager.current) {
            UpdateManager.shared.reportLaunchFailure(failure)
        }
    }
    private func finishWelcome(source: PanelSource = .welcome) {
        guard welcomeState?.isShowing == true else { return }
        let detected = welcomeState?.permissionDetected(Permissions.hasFullDiskAccess())
        let finished = welcomeState?.finish()
        let request = detected ?? finished
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "didFinishOnboarding")
        defaults.set(welcomeState?.skippedFullDiskAccess == true, forKey: "skippedFullDiskAccess")
        permissionTimer?.invalidate(); permissionTimer = nil
        welcomeController?.finish(); welcomeController = nil
        if let limited = request { startIndex(limited: limited) }
        panel.show(source: source)
    }
    private func handleHotKey() {
        if welcomeState?.isShowing == true { finishWelcome(source: .hotkey) }
        else { panel.toggle(source: .hotkey) }
    }

    private func startIndex(limited: Bool) {
        guard manager == nil else { return }
        self.limited = limited
        let manager = IndexManager(config: SettingsPreferences.indexConfig(limited: limited), dbURL: Self.dbURL)
        self.manager = manager; panel.searchController.manager = manager
        settingsController?.model.manager = manager
        panel.searchController.searchField.focus()
        indexStateStartedAt = ProcessInfo.processInfo.systemUptime
        manager.onStateChange = { [weak self, weak manager] state in
            guard let self, let manager else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let count = manager.store.map { store in store.read { store.liveCount } } ?? manager.scannedCount
            let name = String(describing: state)
            AppLog.logger.info("index state=\(name, privacy: .public) entries=\(count, privacy: .public) elapsed=\(now - self.indexStateStartedAt, privacy: .public)s")
            self.indexStateStartedAt = now
            self.panel.searchController.managerStateChanged(state)
        }
        manager.onIndexChange = { [weak self] in self?.panel.searchController.indexChanged() }
        manager.start()
    }
    private func buildMenu(keyCode: UInt32, modifiers: UInt32) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = Theme.symbol("magnifyingglass", size: 16, weight: .regular); image.isTemplate = true
        statusItem?.button?.image = image
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self
        func item(_ key: String, _ action: Selector?, _ equivalent: String = "") -> NSMenuItem {
            let value = NSMenuItem(title: L10n.text(key), action: action, keyEquivalent: equivalent)
            value.target = self; value.isEnabled = action != nil; menu.addItem(value)
            localizedMenuItems.append((key, value)); return value
        }
        hotKeyFailureItem = item("menu.hotkeyFailed", nil)
        hotKeyFailureItem?.isHidden = hotKey != nil
        openItem = item("menu.open", #selector(showSearch), Shortcut.keyEquivalent(keyCode))
        openItem?.keyEquivalentModifierMask = HotKey.modifierFlags(modifiers)
        menu.addItem(.separator())
        countItem = item("menu.indexing", nil)
        limitedItem = item("menu.limited", #selector(openPermissions))
        rescanItem = item("menu.rescan", #selector(rescan))
        menu.addItem(.separator())
        loginItem = item("menu.loginItem", #selector(toggleLogin))
        _ = item("menu.settings", #selector(showSettings), ",")
        checkUpdateItem = item("update.check", #selector(checkUpdates))
        updateItem = item("update.check", #selector(presentUpdate))
        refreshUpdateMenu()
        menu.addItem(.separator()); quitItem = item("menu.quit", #selector(quit), "q")
        statusItem?.menu = menu
    }
    private func localizeMenu() {
        for (key, item) in localizedMenuItems { item.title = L10n.text(key) }
        if let menu = statusItem?.menu { menuWillOpen(menu) }
        refreshUpdateMenu()
    }
    private func registerHotKey(keyCode: UInt32, modifiers: UInt32) -> Bool {
        hotKey?.unregister()
        hotKey = nil; actualKeyCode = nil; actualModifiers = nil
        if !SpotlightShortcut.isReserved(keyCode: keyCode, modifiers: modifiers) {
            hotKey = HotKey(keyCode: keyCode, modifiers: modifiers) { [weak self] in self?.handleHotKey() }
        }
        let requestedRegistered = hotKey != nil
        if requestedRegistered { actualKeyCode = keyCode; actualModifiers = modifiers }
        else if keyCode == Shortcut.defaultKeyCode && modifiers == Shortcut.defaultModifiers,
                !SpotlightShortcut.isReserved(keyCode: Shortcut.fallbackKeyCode, modifiers: Shortcut.fallbackModifiers) {
            hotKey = HotKey(keyCode: Shortcut.fallbackKeyCode, modifiers: Shortcut.fallbackModifiers) { [weak self] in self?.handleHotKey() }
            if hotKey != nil { actualKeyCode = Shortcut.fallbackKeyCode; actualModifiers = Shortcut.fallbackModifiers }
        }
        updateShortcutStatus(clearErrorWhenBound: requestedRegistered)
        return requestedRegistered
    }
    private func updateShortcutStatus(clearErrorWhenBound: Bool = false) {
        let defaults = UserDefaults.standard
        let desired = UInt32(clamping: defaults.integer(forKey: "hotKeyCode"))
        let modifiers = UInt32(clamping: defaults.integer(forKey: "hotKeyModifiers"))
        hotKeyFailureItem?.isHidden = actualKeyCode == desired && actualModifiers == modifiers
        if hotKey != nil {
            openItem?.keyEquivalent = Shortcut.keyEquivalent(actualKeyCode!)
            openItem?.keyEquivalentModifierMask = HotKey.modifierFlags(actualModifiers!)
            welcomeController?.model.updateShortcut(actualKeyCode!, actualModifiers!)
        } else { openItem?.keyEquivalent = "" }
        settingsController?.model.updateShortcutStatus(keyCode: actualKeyCode, modifiers: actualModifiers,
                                                      clearErrorWhenBound: clearErrorWhenBound)
    }
    private func retryHotKey() {
        let defaults = UserDefaults.standard
        _ = registerHotKey(keyCode: UInt32(clamping: defaults.integer(forKey: "hotKeyCode")), modifiers: UInt32(clamping: defaults.integer(forKey: "hotKeyModifiers")))
    }
    @objc func showSettings() { presentSettings() }
    private func presentSettings() {
        panel.hide(source: .settings)
        NSApp.activate(ignoringOtherApps: true)
        if settingsController == nil {
            let model = SettingsModel(clipboard: panel.searchController.clipboard); model.manager = manager
            model.suspendHotKey = { [weak self] in
                self?.hotKey?.unregister(); self?.hotKey = nil
                self?.actualKeyCode = nil; self?.actualModifiers = nil; self?.updateShortcutStatus()
            }
            model.registerHotKey = { [weak self] code, mask in
                let registered = self?.registerHotKey(keyCode: code, modifiers: mask) ?? false
                DispatchQueue.main.async { [weak self] in self?.updateShortcutStatus() }
                return registered
            }
            model.onConfigChange = { [weak self] in
                guard let self else { return }
                self.manager?.updateConfig(SettingsPreferences.indexConfig(limited: self.limited))
                self.panel.searchController.applications.refresh(excludedPaths: UserDefaults.standard.stringArray(forKey: "userExcludedPaths") ?? [])
            }
            model.onPinyinChange = { [weak self] in self?.panel.searchController.startSearch(preserveSelection: true) }
            model.onRetryHotKey = { [weak self] in self?.retryHotKey() }
            settingsController = SettingsWindowController(model: model)
        }
        settingsController?.present()
        updateShortcutStatus()
    }
    func menuWillOpen(_ menu: NSMenu) {
        refreshUpdateMenu()
        if let store = manager?.store { countItem?.title = L10n.text("menu.indexed", Presentation.countText(store.read { store.liveCount })) }
        else { countItem?.title = L10n.text("menu.indexing") }
        limitedItem?.isHidden = !limited
        rescanItem?.isEnabled = manager?.state == .ready && manager?.isRescanning == false
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
    private func refreshUpdateMenu() {
        let update = UpdateManager.shared
        checkUpdateItem?.isEnabled = update.canCheck
        updateItem?.isHidden = update.manifest == nil
        updateItem?.title = update.menuTitle
        updateItem?.isEnabled = !update.state.busy
        quitItem?.isEnabled = !update.preventsTermination
    }
    @objc private func checkUpdates() { UpdateManager.shared.check() }
    @objc private func presentUpdate() { UpdateManager.shared.present() }
    @objc private func showSearch() {
        if welcomeState?.isShowing == true { welcomeController?.present() }
        else { panel.show(source: .menu) }
    }
    @objc private func reopenRequested(_ notification: Notification) {
        AppLog.logger.info("reopen requested")
        if welcomeState?.isShowing == true { welcomeController?.present() }
        else { panel.show(source: .reopen) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reopenRequested(Notification(name: Self.showRequest)); return true
    }
    @objc private func openPermissions() { Permissions.openSettings() }
    @objc private func rescan() { manager?.rescan() }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSSound.beep() }
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        UpdateManager.shared.preventsTermination ? .terminateCancel : .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { if !secondaryInstance { UpdateManager.shared.stop() }; panel.searchController.stopSources(); settingsController?.model.stopRefreshing(); permissionTimer?.invalidate(); hotKey?.unregister(); manager?.stop() }
    deinit {
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
        if let shortcutRetryObserver { NSWorkspace.shared.notificationCenter.removeObserver(shortcutRetryObserver) }
    }
}
