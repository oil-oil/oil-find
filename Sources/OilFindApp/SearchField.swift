import AppKit
import QuartzCore

final class SearchEditor: NSTextView {
    var handleKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), handleKey?(event) == true { return }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !hasMarkedText(), handleKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

private final class SettingsButton: NSButton {
    private let background = TintPlate(radius: 8) { _ in NSColor.labelColor.withAlphaComponent(0.06) }
    private let normalIcon = NSImageView(), hoverIcon = NSImageView()
    private var tracking: NSTrackingArea?
    var onPress: (() -> Void)?
    init() {
        super.init(frame: .zero); isBordered = false; setButtonType(.momentaryChange)
        target = self; action = #selector(pressed); toolTip = L10n.text("panel.settings")
        setAccessibilityLabel(L10n.text("panel.settings"))
        background.alphaValue = 0; hoverIcon.alphaValue = 0
        for icon in [normalIcon, hoverIcon] { icon.image = Theme.symbol("gearshape", size: 14, weight: .regular); icon.wantsLayer = true }
        normalIcon.contentTintColor = .tertiaryLabelColor; hoverIcon.contentTintColor = .labelColor
        [background, normalIcon, hoverIcon].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { false }
    @objc private func pressed() { onPress?() }
    override func layout() {
        super.layout(); background.frame = bounds
        [normalIcon, hoverIcon].forEach { $0.frame = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func draw(_ dirtyRect: NSRect) {}
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    private func hover(_ active: Bool) {
        for view in [background, hoverIcon] { Theme.Motion.opacity(view, to: active ? 1 : 0, using: Theme.Motion.basic(Theme.Motion.hover)) }
        Theme.Motion.opacity(normalIcon, to: active ? 0 : 1, using: Theme.Motion.basic(Theme.Motion.hover))
    }
    override func mouseEntered(with event: NSEvent) { hover(true) }
    override func mouseExited(with event: NSEvent) { hover(false) }
}

private final class PassiveProgressIndicator: NSProgressIndicator {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class SearchField: FlippedView, NSTextFieldDelegate {
    let input = NSTextField()
    let editor = SearchEditor()
    private let glass = NSImageView()
    private let clear = NSButton()
    private let progress = PassiveProgressIndicator()
    private let settings = SettingsButton()
    private var selectionObserver: NSObjectProtocol?
    private var clearVisible = false, progressVisible = false
    var onSettings: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    var onChange: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var indexing = false { didSet { updateAccessory() } }
    var text: String {
        get { input.stringValue }
        set { input.stringValue = newValue; updateAccessory() }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.image = Theme.symbol("magnifyingglass", size: 19, weight: .medium)
        glass.contentTintColor = .secondaryLabelColor
        input.font = .systemFont(ofSize: 21); input.textColor = .labelColor
        input.isBordered = false; input.drawsBackground = false; input.focusRingType = .none
        input.cell?.isScrollable = true; input.cell?.usesSingleLineMode = true
        input.lineBreakMode = .byClipping
        input.placeholderAttributedString = NSAttributedString(string: L10n.text("placeholder"), attributes: [.font: input.font!, .foregroundColor: NSColor.placeholderTextColor])
        input.delegate = self
        editor.isFieldEditor = true
        selectionObserver = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: editor, queue: .main) { [weak self] _ in self?.onSelectionChange?() }
        editor.handleKey = { [weak self] event in self?.onKey?(event) ?? false }
        clear.isBordered = false; clear.image = Theme.symbol("xmark.circle.fill", size: 15, weight: .regular)
        clear.contentTintColor = .tertiaryLabelColor; clear.target = self; clear.action = #selector(clearText)
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        [clear, progress].forEach { $0.wantsLayer = true; $0.alphaValue = 0 }
        settings.onPress = { [weak self] in self?.onSettings?() }
        [glass, input, clear, progress, settings].forEach(addSubview)
        updateAccessory()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func localize() {
        input.placeholderAttributedString = NSAttributedString(string: L10n.text("placeholder"), attributes: [.font: input.font!, .foregroundColor: NSColor.placeholderTextColor])
        settings.toolTip = L10n.text("panel.settings")
        settings.setAccessibilityLabel(L10n.text("panel.settings"))
    }
    override func layout() {
        super.layout()
        glass.frame = NSRect(x: 24, y: (bounds.height - 22) / 2, width: 22, height: 22)
        input.frame = NSRect(x: 58, y: (bounds.height - 29) / 2, width: max(0, bounds.width - 144), height: 29)
        clear.frame = NSRect(x: bounds.width - 68, y: (bounds.height - 16) / 2, width: 16, height: 16)
        progress.frame = NSRect(x: bounds.width - 68, y: (bounds.height - 16) / 2, width: 16, height: 16)
        settings.frame = NSRect(x: bounds.width - 44, y: (bounds.height - 26) / 2, width: 26, height: 26)
    }
    func focus(selectAll: Bool = false) {
        window?.makeFirstResponder(input)
        if selectAll { input.selectText(nil) }
    }
    deinit { if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) } }
    func controlTextDidEndEditing(_ obj: Notification) { onSelectionChange?() }
    func controlTextDidChange(_ obj: Notification) { updateAccessory(); onChange?() }
    @objc private func clearText() { text = ""; focus(); onChange?() }
    private func accessory(_ view: NSView, visible: Bool) {
        let animate = window?.isVisible == true
        view.isHidden = false
        Theme.Motion.opacity(view, to: visible ? 1 : 0, using: animate ? Theme.Motion.basic(Theme.Motion.crossfade) : nil)
        if let layer = view.layer {
            let frame = layer.frame; layer.anchorPoint = CGPoint(x: 0.5, y: 0.5); layer.frame = frame
            Theme.Motion.animate(layer, "transform.scale", to: visible ? 1 : Theme.Motion.accessoryScale, using: animate ? Theme.Motion.basic(Theme.Motion.crossfade) : nil)
        }
    }
    private func updateAccessory() {
        let showClear = !indexing && !text.isEmpty
        if clearVisible != showClear { clearVisible = showClear; accessory(clear, visible: showClear) }
        clear.isEnabled = showClear
        if progressVisible != indexing {
            progressVisible = indexing
            if indexing { progress.startAnimation(nil) }
            accessory(progress, visible: indexing)
            if !indexing {
                DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.crossfade) { [weak self] in
                    if self?.indexing == false { self?.progress.stopAnimation(nil) }
                }
            }
        }
    }
}
