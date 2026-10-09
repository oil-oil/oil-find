import AppKit
import SwiftUI
import Carbon
import OilFindCore

final class WelcomeModel: ObservableObject {
    @Published var granted: Bool
    @Published var waiting = false
    @Published var keyCode: UInt32
    @Published var modifiers: UInt32
    @Published var held: NSEvent.ModifierFlags = []
    var onStart: (() -> Void)?
    var onSettings: (() -> Void)?
    var onContentChange: (() -> Void)?
    init(granted: Bool, snapshot: Bool = false) {
        self.granted = granted
        if !snapshot { SettingsPreferences.register() }
        keyCode = snapshot ? Shortcut.defaultKeyCode : UInt32(clamping: UserDefaults.standard.integer(forKey: "hotKeyCode"))
        modifiers = snapshot ? Shortcut.defaultModifiers : UInt32(clamping: UserDefaults.standard.integer(forKey: "hotKeyModifiers"))
    }
    func openPermissions() { waiting = true; onContentChange?(); Permissions.openSettings() }
    func updateShortcut(_ code: UInt32, _ mask: UInt32) { keyCode = code; modifiers = mask }
}

private struct WelcomeKeycap: View {
    let text: String
    let held: Bool
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        Text(text).font(.system(size: 19, weight: .medium)).foregroundStyle(Color(nsColor: .labelColor))
            .padding(.horizontal, 12).frame(minWidth: 44).frame(height: 44)
            .background(held ? Color(nsColor: .controlAccentColor).opacity(0.18) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 1 / displayScale))
            .shadow(color: Color(nsColor: .separatorColor), radius: 0, x: 0, y: 1)
            .animation(.easeInOut(duration: Theme.Motion.keycap), value: held)
    }
}

struct WelcomeContent: View {
    @ObservedObject var model: WelcomeModel
    @Environment(\.displayScale) private var displayScale
    private let modifierKeys: [(Int, String, NSEvent.ModifierFlags)] = [
        (controlKey, "⌃", .control), (optionKey, "⌥", .option), (shiftKey, "⇧", .shift), (cmdKey, "⌘", .command)
    ]
    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("Oil Find").font(.system(size: 22, weight: .semibold)).padding(.top, 14)
            Text(L10n.text("welcome.subtitle")).font(.system(size: 13))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor)).padding(.top, 6)
            HStack(spacing: 8) {
                ForEach(modifierKeys.filter { model.modifiers & UInt32($0.0) != 0 }, id: \.0) { key in
                    WelcomeKeycap(text: key.1, held: model.held.contains(key.2))
                }
                WelcomeKeycap(text: Shortcut.keyName(model.keyCode), held: false)
            }.padding(.top, 22)
            Button(L10n.text("welcome.changeHotkey")) { model.onSettings?() }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color(nsColor: .controlAccentColor)).padding(.top, 10)
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1 / displayScale).padding(.top, 22)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("welcome.permission")).font(.system(size: 13))
                    Text(L10n.text(model.waiting ? "welcome.permission.waiting" : "welcome.permission.caption"))
                        .font(.system(size: 11.5)).foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if model.granted {
                    HStack(spacing: 6) {
                        Circle().fill(Color(nsColor: .systemGreen)).frame(width: 8, height: 8)
                        Text(L10n.text("welcome.permission.granted")).font(.system(size: 12)).foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    }
                } else {
                    Button(L10n.text("welcome.permission.open"), action: model.openPermissions).controlSize(.small).buttonStyle(.bordered)
                }
            }.padding(.top, 14)
            WelcomeStartButton(model: model).frame(maxWidth: .infinity).frame(height: 36).padding(.top, 20)
        }
        .foregroundStyle(Color(nsColor: .labelColor))
        .padding(.horizontal, 28).padding(.top, 36).padding(.bottom, 24)
        .frame(width: 420).fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// Use the native default-button cell, including Return dispatch, in the SwiftUI layout.
private final class WelcomeDefaultButton: ChromeButton {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); window?.defaultButtonCell = cell as? NSButtonCell
    }
}

private struct WelcomeStartButton: NSViewRepresentable {
    let model: WelcomeModel
    func makeNSView(context: Context) -> WelcomeDefaultButton {
        let button = WelcomeDefaultButton(L10n.text("welcome.start"), style: .primary, size: 13, weight: .medium)
        button.keyEquivalent = "\r"; button.keyEquivalentModifierMask = []
        button.onPress = { [weak model] in model?.onStart?() }
        return button
    }
    func updateNSView(_ button: WelcomeDefaultButton, context: Context) { button.title = L10n.text("welcome.start") }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WelcomeDefaultButton, context: Context) -> NSSize? {
        NSSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: 36)
    }
}

final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    let model: WelcomeModel
    private var flagsMonitor: Any?
    private var languageObserver: NSObjectProtocol?
    private var finishing = false
    init(granted: Bool, snapshot: Bool = false) {
        model = WelcomeModel(granted: granted, snapshot: snapshot)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 420), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let hosting = NSHostingController(rootView: WelcomeContent(model: model))
        hosting.safeAreaRegions = []
        window.contentViewController = hosting
        model.onContentChange = { [weak self] in self?.resizeToContent() }
        languageObserver = NotificationCenter.default.addObserver(forName: L10n.changed, object: nil, queue: .main) { [weak self] _ in
            self?.model.objectWillChange.send()
            DispatchQueue.main.async { [weak self] in self?.resizeToContent() }
        }
        resizeToContent()
        if !snapshot {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self, self.window?.isKeyWindow == true else { return event }
                self.model.held = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                return event
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func resizeToContent() {
        guard let view = window?.contentView,
              let hosting = window?.contentViewController as? NSHostingController<WelcomeContent> else { return }
        view.layoutSubtreeIfNeeded()
        let size = hosting.sizeThatFits(in: NSSize(width: 420, height: CGFloat.greatestFiniteMagnitude))
        // Full-size content includes the titlebar; set the frame size to avoid
        // adding its height a second time to the hosting view's fitted height.
        if let window {
            window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 420, height: ceil(size.height))), display: false)
        }
    }
    func present() {
        guard let window else { return }
        resizeToContent()
        if !window.isVisible {
            let mouse = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
                window.setFrameOrigin(NSPoint(x: (screen.frame.midX - window.frame.width / 2).rounded(), y: (screen.frame.midY - window.frame.height / 2).rounded()))
            }
        }
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func finish() { finishing = true; window?.close() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if finishing { return true }
        model.onStart?(); return false
    }
    func windowDidResignKey(_ notification: Notification) { model.held = [] }
    func windowDidBecomeKey(_ notification: Notification) { model.held = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask) }
    deinit {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    }
}
