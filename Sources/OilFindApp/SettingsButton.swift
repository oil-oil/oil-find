import AppKit

final class SettingsButton: NSButton {
    private let background = TintPlate(radius: 8) { _ in NSColor.labelColor.withAlphaComponent(0.06) }
    private let normalIcon = NSImageView(), hoverIcon = NSImageView()
    private let label = Theme.label(11.5, .regular, .secondaryLabelColor)
    var desiredWidth: CGFloat { ceil(Theme.textWidth(title, font: label.font!)) + 34 }
    private var tracking: NSTrackingArea?
    var onPress: (() -> Void)?
    init() {
        super.init(frame: .zero); isBordered = false; setButtonType(.momentaryChange)
        target = self; action = #selector(pressed)
        localize()
        background.alphaValue = 0; hoverIcon.alphaValue = 0
        for icon in [normalIcon, hoverIcon] { icon.image = Theme.symbol("gearshape", size: 12, weight: .regular); icon.wantsLayer = true }
        normalIcon.contentTintColor = .tertiaryLabelColor; hoverIcon.contentTintColor = .labelColor
        [background, normalIcon, hoverIcon, label].forEach(addSubview)
    }
    func localize() {
        title = L10n.text("panel.settings"); label.stringValue = title
        toolTip = title; setAccessibilityLabel(title); needsLayout = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { false }
    @objc private func pressed() { onPress?() }
    override func layout() {
        super.layout(); background.frame = bounds
        [normalIcon, hoverIcon].forEach { $0.frame = NSRect(x: 7, y: (bounds.height - 13) / 2, width: 13, height: 13) }
        label.frame = NSRect(x: 24, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 29), height: 16)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func draw(_ dirtyRect: NSRect) {}
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    private func hover(_ active: Bool) {
        label.textColor = active ? .labelColor : .secondaryLabelColor
        for view in [background, hoverIcon] { Theme.Motion.opacity(view, to: active ? 1 : 0, using: Theme.Motion.basic(Theme.Motion.hover)) }
        Theme.Motion.opacity(normalIcon, to: active ? 0 : 1, using: Theme.Motion.basic(Theme.Motion.hover))
    }
    override func mouseEntered(with event: NSEvent) { hover(true) }
    override func mouseExited(with event: NSEvent) { hover(false) }
}
