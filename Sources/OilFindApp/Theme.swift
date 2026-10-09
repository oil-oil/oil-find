import AppKit
import QuartzCore

// Point measurements are fixed by the M3 design specification.
enum Theme {
    enum Motion {
        static var panelIn: CASpringAnimation { spring(stiffness: 500, damping: 36) }
        static var selection: CASpringAnimation { spring(stiffness: 1400, damping: 64) }
        static var chip: CASpringAnimation { spring(stiffness: 900, damping: 50) }
        static let panelInFade = 0.12, panelOut = 0.13
        static let selectionRepeat = 0.045, crossfade = 0.12, press = 0.08
        static let toastIn = 0.16, toastOut = 0.12, toastStay = 2.4
        static let nudge = 0.22, hover = 0.08, keycap = 0.07, reducedFade = 0.1
        static let panelInScale: CGFloat = 0.96, panelInOffset: CGFloat = 8
        static let panelOutScale: CGFloat = 0.985, pressScale: CGFloat = 0.985
        static let accessoryScale: CGFloat = 0.8, toastOffset: CGFloat = 6, nudgeOffset: CGFloat = 9
        static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        private static func spring(stiffness: CGFloat, damping: CGFloat) -> CASpringAnimation {
            let animation = CASpringAnimation()
            animation.mass = 1; animation.stiffness = stiffness; animation.damping = damping
            animation.duration = animation.settlingDuration
            return animation
        }
        static func basic(_ duration: Double, _ curve: CAMediaTimingFunctionName = .easeInEaseOut) -> CABasicAnimation {
            let animation = CABasicAnimation(); animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: curve)
            return animation
        }
        // Read the presentation value before replacing the model target or its animation.
        static func animate(_ layer: CALayer, _ path: String, to value: Any, using animation: CABasicAnimation?, from: Any? = nil) {
            let start = from ?? layer.presentation()?.value(forKeyPath: path) ?? layer.value(forKeyPath: path)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.setValue(value, forKeyPath: path); layer.removeAnimation(forKey: path)
            if let animation {
                animation.keyPath = path; animation.fromValue = start; animation.toValue = value
                layer.add(animation, forKey: path)
            }
            CATransaction.commit()
        }
        static func frame(_ view: NSView, to rect: NSRect, using animation: CABasicAnimation?) {
            guard let layer = view.layer else { view.frame = rect; return }
            let position = layer.presentation()?.position ?? layer.position
            let bounds = layer.presentation()?.bounds ?? layer.bounds
            view.frame = rect
            animate(layer, "position", to: NSValue(point: layer.position), using: animation?.copy() as? CABasicAnimation, from: NSValue(point: position))
            animate(layer, "bounds", to: NSValue(rect: layer.bounds), using: animation?.copy() as? CABasicAnimation, from: NSValue(rect: bounds))
        }
        static func opacity(_ view: NSView, to value: Float, using animation: CABasicAnimation?) {
            let start = view.layer?.presentation()?.opacity ?? Float(view.alphaValue)
            view.alphaValue = CGFloat(value)
            if let layer = view.layer { animate(layer, "opacity", to: value, using: animation, from: start) }
        }
    }
    static let panelSize = NSSize(width: 800, height: 560)
    static let corner: CGFloat = 22
    static let searchHeight: CGFloat = 64
    static let filterHeight: CGFloat = 40
    static let footerHeight: CGFloat = 34
    static let rowHeight: CGFloat = 50
    static func dark(_ view: NSView) -> Bool {
        view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
    static func pixel(_ view: NSView) -> CGFloat { 1 / (view.window?.backingScaleFactor ?? 2) }
    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))!
    }
    static func label(_ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        return label
    }
    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// A passive backing plate never intercepts a row or button's native hit testing.
final class TintPlate: FlippedView {
    let radius: CGFloat
    let color: (NSView) -> NSColor
    init(radius: CGFloat, color: @escaping (NSView) -> NSColor) {
        self.radius = radius; self.color = color
        super.init(frame: .zero); wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        color(self).setFill(); NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

final class SeparatorView: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.separatorColor.setFill(); bounds.fill() }
}

// Native buttons retain keyboard and accessibility behavior while drawing the specified chrome.
class ChromeButton: NSButton {
    enum Style { case filter, plain, primary }
    let chromeStyle: Style
    var active = false { didSet { if active != oldValue { updateFilterText(); needsDisplay = true } } }
    var hovered = false { didSet { normalLabel.textColor = hovered ? .labelColor : .secondaryLabelColor; needsDisplay = true } }
    var onPress: (() -> Void)?
    var trailingSymbol: NSImage?
    var textTint: NSColor?
    private var tracking: NSTrackingArea?
    private let normalLabel = Theme.label(12.5, .medium, .secondaryLabelColor)
    private let activeLabel = Theme.label(12.5, .medium, .controlAccentColor)
    init(_ title: String, style: Style, size: CGFloat, weight: NSFont.Weight) {
        chromeStyle = style
        super.init(frame: .zero)
        self.title = title; font = .systemFont(ofSize: size, weight: weight)
        isBordered = false; bezelStyle = .regularSquare; setButtonType(.momentaryChange)
        target = self; action = #selector(pressed)
        if style == .filter {
            for label in [normalLabel, activeLabel] {
                label.stringValue = title; label.alignment = .center; label.wantsLayer = true; addSubview(label)
            }
            activeLabel.alphaValue = 0
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { false }
    @objc private func pressed() { onPress?() }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func layout() {
        super.layout()
        if chromeStyle == .filter {
            [normalLabel, activeLabel].forEach { $0.frame = NSRect(x: 0, y: (bounds.height - 17) / 2, width: bounds.width, height: 17) }
        }
    }
    private func updateFilterText() {
        guard chromeStyle == .filter else { return }
        let animation = window?.isVisible == true ? Theme.Motion.basic(Theme.Motion.crossfade) : nil
        Theme.Motion.opacity(normalLabel, to: active ? 0 : 1, using: animation)
        Theme.Motion.opacity(activeLabel, to: active ? 1 : 0, using: animation?.copy() as? CABasicAnimation)
    }
    override func draw(_ dirtyRect: NSRect) {
        let pressed = cell?.isHighlighted == true
        var color: NSColor = hovered ? .labelColor : .secondaryLabelColor
        switch chromeStyle {
        case .filter:
            if !active && hovered {
                NSColor.labelColor.withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 13, yRadius: 13).fill()
            }
            return
        case .primary:
            let accent = NSColor.controlAccentColor
            let fill = pressed ? accent.blended(withFraction: 0.08, of: .black)! : hovered ? accent.blended(withFraction: 0.06, of: .white)! : accent
            fill.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
            color = .white
        case .plain: break
        }
        let textSize = (title as NSString).size(withAttributes: [.font: font!])
        let extra: CGFloat = trailingSymbol == nil ? 0 : 16
        let x = (bounds.width - textSize.width - extra) / 2
        color = textTint ?? color
        (title as NSString).draw(at: NSPoint(x: x, y: (bounds.height - textSize.height) / 2), withAttributes: [.font: font!, .foregroundColor: isEnabled ? color : color.withAlphaComponent(0.4)])
        if let trailingSymbol {
            let rect = NSRect(x: x + textSize.width + 6, y: (bounds.height - 10) / 2, width: 10, height: 10)
            let tinted = trailingSymbol.copy() as! NSImage
            tinted.lockFocus(); color.set(); NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop); tinted.unlockFocus()
            tinted.draw(in: rect)
        }
    }
}
