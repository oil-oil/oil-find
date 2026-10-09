import AppKit

// The tuples mirror site/content/dict.ts; site tests verify every example, explanation and group.
private final class SyntaxRow: NSButton {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {}
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
}
final class SyntaxReference: FlippedView {
    static let zh = [
        ["wd", "拼音首字母，找到「文档」", "拼音"],
        ["readme !node_modules", "包含 readme，排除 node_modules 里的", "排除"],
        ["*.png", "通配符，匹配整个名称", "通配"],
        ["~/Desktop/ png", "只在桌面下面找", "路径"],
        ["dm:today ext:md", "今天改过的 Markdown", "时间"]
    ]
    static let en = [
        ["wd", "Pinyin initials, finds 文档", "Pinyin"],
        ["readme !node_modules", "Contains readme, not inside node_modules", "Exclude"],
        ["*.png", "Wildcard, matches the whole name", "Wildcard"],
        ["~/Desktop/ png", "Only under the Desktop", "Path"],
        ["dm:today ext:md", "Markdown files changed today", "Date"]
    ]
    var onExample: ((String) -> Void)?
    private let title = Theme.label(14, .semibold, .labelColor)
    private var buttons: [NSButton] = [], examples: [NSTextField] = [], descriptions: [NSTextField] = [], groups: [NSTextField] = []
    private var rows: [[String]] { L10n.chinese ? Self.zh : Self.en }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        title.stringValue = L10n.text("hint.syntax"); addSubview(title)
        for (i, row) in rows.enumerated() {
            let button = SyntaxRow(title: row[0], target: self, action: #selector(choose(_:)))
            button.tag = i; button.isBordered = false; button.alignment = .left
            button.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
            let example = Theme.label(13, .medium, .controlAccentColor); example.font = button.font; example.stringValue = row[0]
            button.contentTintColor = .controlAccentColor
            let description = Theme.label(12, .regular, .secondaryLabelColor); description.stringValue = row[1]
            let group = Theme.label(11, .medium, .tertiaryLabelColor); group.stringValue = row[2]; group.alignment = .right
            buttons.append(button); examples.append(example); descriptions.append(description); groups.append(group)
            addSubview(button); [example, description, group].forEach(button.addSubview)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func choose(_ sender: NSButton) { onExample?(rows[sender.tag][0]) }
    func localize() {
        title.stringValue = L10n.text("hint.syntax")
        for (i, row) in rows.enumerated() {
            buttons[i].title = row[0]; examples[i].stringValue = row[0]
            descriptions[i].stringValue = row[1]; groups[i].stringValue = row[2]
        }
        needsLayout = true
    }
    override func layout() {
        super.layout(); title.frame = NSRect(x: 28, y: 24, width: bounds.width - 56, height: 20)
        for i in buttons.indices {
            let y = CGFloat(64 + i * 67)
            buttons[i].frame = NSRect(x: 18, y: y - 4, width: bounds.width - 36, height: 63)
            examples[i].frame = NSRect(x: 10, y: 4, width: buttons[i].bounds.width - 116, height: 24)
            descriptions[i].frame = NSRect(x: 10, y: 31, width: buttons[i].bounds.width - 20, height: 18)
            groups[i].frame = NSRect(x: buttons[i].bounds.width - 98, y: 7, width: 88, height: 18)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        for i in 0..<4 { NSRect(x: 28, y: CGFloat(120 + i * 67), width: bounds.width - 56, height: Theme.pixel(self)).fill() }
    }
}
