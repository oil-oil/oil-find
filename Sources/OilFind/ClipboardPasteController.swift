import AppKit
import ApplicationServices

enum PasteOutcome: Equatable { case sent, copiedOnly }

struct ClipboardPasteTarget {
    let processIdentifier: pid_t
    let bundleID: String?
    let launchDate: Date?
    let focusedElement: AXUIElement?

    init(processIdentifier: pid_t, bundleID: String? = nil, launchDate: Date? = nil,
         focusedElement: AXUIElement? = nil) {
        self.processIdentifier = processIdentifier
        self.bundleID = bundleID
        self.launchDate = launchDate
        self.focusedElement = focusedElement
    }
}

protocol ClipboardPasteAdapting: AnyObject {
    var hasPermission: Bool { get }
    func captureTarget() -> ClipboardPasteTarget?
    func isRunning(_ target: ClipboardPasteTarget) -> Bool
    func activate(_ target: ClipboardPasteTarget, completion: @escaping (Bool) -> Void)
    func hasFocus(_ target: ClipboardPasteTarget) -> Bool
    func sendCommandV(to target: ClipboardPasteTarget) -> Bool
}

final class ClipboardSystemPasteAdapter: ClipboardPasteAdapting {
    // Passive checks only. A user can grant accessibility access in System Settings.
    var hasPermission: Bool { AXIsProcessTrusted() && CGPreflightPostEventAccess() }

    func captureTarget() -> ClipboardPasteTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !app.isTerminated, app.activationPolicy == .regular else { return nil }
        let element = hasPermission ? focusedElement(pid: app.processIdentifier) : nil
        return ClipboardPasteTarget(processIdentifier: app.processIdentifier, bundleID: app.bundleIdentifier,
                                    launchDate: app.launchDate, focusedElement: element)
    }

    func isRunning(_ target: ClipboardPasteTarget) -> Bool {
        guard target.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: target.processIdentifier),
              !app.isTerminated, app.activationPolicy == .regular else { return false }
        // Launch date also protects against reuse of a PID by the same application.
        return app.bundleIdentifier == target.bundleID && app.launchDate == target.launchDate
    }

    func activate(_ target: ClipboardPasteTarget, completion: @escaping (Bool) -> Void) {
        guard isRunning(target), let app = NSRunningApplication(processIdentifier: target.processIdentifier)
        else { completion(false); return }
        if app.isActive {
            DispatchQueue.main.async { completion(true) }
            return
        }
        let center = NSWorkspace.shared.notificationCenter
        var observer: NSObjectProtocol?
        var timeout: Timer?
        var finished = false
        let finish: (Bool) -> Void = { success in
            guard !finished else { return }
            finished = true
            if let observer { center.removeObserver(observer) }
            timeout?.invalidate()
            completion(success)
        }
        observer = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                      object: nil, queue: .main) { notification in
            guard let active = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  active.processIdentifier == target.processIdentifier else { return }
            // Allow the activation notification to finish before checking AX focus.
            DispatchQueue.main.async { finish(true) }
        }
        // This timer is a failure deadline, never a delay before sending a key.
        timeout = Timer(timeInterval: 1, repeats: false) { _ in finish(false) }
        if let timeout { RunLoop.main.add(timeout, forMode: .common) }
        guard app.activate(options: []) else { finish(false); return }
        if app.isActive { DispatchQueue.main.async { finish(true) } }
    }

    func hasFocus(_ target: ClipboardPasteTarget) -> Bool {
        guard hasPermission, isRunning(target),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
              NSRunningApplication(processIdentifier: target.processIdentifier)?.isActive == true,
              let element = focusedElement(pid: target.processIdentifier) else { return false }
        if let original = target.focusedElement, !CFEqual(original, element) { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == target.processIdentifier else { return false }
        var enabled: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled) == .success,
           let value = enabled as? Bool, !value { return false }
        return true
    }

    private func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func sendCommandV(to target: ClipboardPasteTarget) -> Bool {
        guard hasPermission, isRunning(target), hasFocus(target),
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(target.processIdentifier)
        up.postToPid(target.processIdentifier)
        return true
    }
}

// Main-thread integration: capture immediately before showing the panel. The
// caller copies the selected entry first; this controller never reads clipboard data.
final class ClipboardPasteController {
    typealias FailureDeadline = (@escaping () -> Void) -> (() -> Void)
    private let adapter: ClipboardPasteAdapting
    private let snapshot: Bool
    private let scheduleFailureDeadline: FailureDeadline
    private var target: ClipboardPasteTarget?
    private var busy = false

    init(snapshot: Bool = false, adapter: ClipboardPasteAdapting? = nil,
         scheduleFailureDeadline: @escaping FailureDeadline = { failure in
             // A failure deadline, never a delay or authorization to send keys.
             let timer = Timer(timeInterval: 1.75, repeats: false) { _ in failure() }
             RunLoop.main.add(timer, forMode: .common)
             return { timer.invalidate() }
         }) {
        self.snapshot = snapshot
        self.adapter = adapter ?? ClipboardSystemPasteAdapter()
        self.scheduleFailureDeadline = scheduleFailureDeadline
    }

    func captureTarget() {
        guard !snapshot, !busy else { return }
        target = adapter.captureTarget()
    }

    func pasteCurrentClipboard(hidePanel: (@escaping () -> Void) -> Void,
                               completion: @escaping (PasteOutcome) -> Void) {
        guard !busy else { completion(.copiedOnly); return }
        busy = true
        let captured = target
        target = nil
        var finished = false, hidden = false, activated = false
        var cancelDeadline: (() -> Void)?
        let finish: (PasteOutcome) -> Void = { [weak self] outcome in
            guard !finished else { return }
            finished = true
            cancelDeadline?()
            cancelDeadline = nil
            self?.busy = false
            completion(outcome)
        }
        cancelDeadline = scheduleFailureDeadline { finish(.copiedOnly) }
        // Also tolerate an injected scheduler firing synchronously.
        guard !finished else { cancelDeadline?(); cancelDeadline = nil; return }
        hidePanel { [weak self] in
            guard !finished, !hidden else { return }
            hidden = true
            guard let self, !self.snapshot, let captured,
                  self.adapter.hasPermission, self.adapter.isRunning(captured) else { finish(.copiedOnly); return }
            self.adapter.activate(captured) { [weak self] success in
                guard !finished, !activated else { return }
                activated = true
                guard let self, success, self.adapter.hasPermission,
                      self.adapter.isRunning(captured), self.adapter.hasFocus(captured),
                      self.adapter.sendCommandV(to: captured) else { finish(.copiedOnly); return }
                finish(.sent)
            }
        }
    }
}
