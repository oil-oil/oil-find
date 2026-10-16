import AppKit
import OilFindCore

final class FilterBar: FlippedView, NSMenuDelegate {
    static let names = ["all", "folder", "app", "document", "image", "video", "audio", "code", "archive"]
    private var buttons: [ChromeButton] = []
    private var buttonWidths: [CGFloat] = []
    private let capsule = TintPlate(radius: 13) { view in
        NSColor.controlAccentColor.withAlphaComponent(Theme.dark(view) ? 0.26 : 0.15)
    }
    private var laidOut = false
    private(set) var additionalSelected = false
    var additionalTitle: String? {
        didSet {
            guard additionalTitle != oldValue else { return }
            if additionalTitle == nil { additionalSelected = false }
            buttons.last?.title = additionalTitle ?? ""
            buttons.last?.isHidden = additionalTitle == nil
            if let button = buttons.last { buttonWidths[buttons.count - 1] = Theme.textWidth(button.title, font: button.font!) + 22 }
            refresh(); needsLayout = true
        }
    }
    private let sortButton = ChromeButton("", style: .plain, size: 12, weight: .medium)
    var onChange: (() -> Void)?
    var onMenuTracking: ((Bool) -> Void)?
    var onSortChange: (() -> Void)?
    var options = SearchOptions() { didSet { refresh() } }
    var isEnabled = true {
        didSet { alphaValue = isEnabled ? 1 : 0.4; (buttons + [sortButton]).forEach { $0.isEnabled = isEnabled } }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(capsule)
        for (i, name) in Self.names.enumerated() {
            let button = ChromeButton(L10n.text("filter." + name), style: .filter, size: 12.5, weight: .medium)
            button.onPress = { [weak self] in self?.select(i) }
            buttons.append(button); buttonWidths.append(Theme.textWidth(button.title, font: button.font!) + 22); addSubview(button)
        }
        let additional = ChromeButton("", style: .filter, size: 12.5, weight: .medium)
        additional.isHidden = true; additional.onPress = { [weak self] in self?.select(Self.names.count) }
        buttons.append(additional); buttonWidths.append(0); addSubview(additional)
        sortButton.trailingSymbol = Theme.symbol("arrow.up.arrow.down", size: 10, weight: .medium)
        sortButton.onPress = { [weak self] in self?.showSortMenu() }
        addSubview(sortButton); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    static func sortName(_ key: SortKey) -> String {
        switch key { case .relevance: return "relevance"; case .name: return "name"; case .modified: return "modified"; case .size: return "size" }
    }
    func localize() {
        for (i, button) in buttons.prefix(Self.names.count).enumerated() {
            button.title = L10n.text("filter." + Self.names[i])
            buttonWidths[i] = Theme.textWidth(button.title, font: button.font!) + 22
        }
        refresh(); needsLayout = true
    }
    private func refresh() {
        for (i, button) in buttons.enumerated() { button.active = i == (additionalSelected ? Self.names.count : Int(options.kind ?? 0)) }
        let sortTitle = L10n.text("sort." + Self.sortName(options.sort))
        let changedSort = sortButton.title != sortTitle
        sortButton.title = sortTitle; sortButton.needsDisplay = true
        if laidOut { moveCapsule(animated: window?.isVisible == true) }
        if changedSort || sortButton.frame.isEmpty { needsLayout = true }
    }
    override func layout() {
        super.layout()
        var x: CGFloat = 18
        let visibleCount = Self.names.count + (additionalTitle == nil ? 0 : 1)
        let sortWidth = Theme.textWidth(sortButton.title, font: sortButton.font!) + 16
        let available = max(0, bounds.width - 36 - sortWidth - 12 - CGFloat(visibleCount - 1) * 2)
        let natural = buttonWidths.prefix(visibleCount).reduce(0, +)
        let reduction = max(0, (natural - available) / CGFloat(visibleCount))
        for (i, button) in buttons.prefix(visibleCount).enumerated() {
            let width = max(20, buttonWidths[i] - reduction)
            button.frame = NSRect(x: x, y: 7, width: width, height: 26); x += width + 2
        }
        let width = Theme.textWidth(sortButton.title, font: sortButton.font!) + 16
        sortButton.frame = NSRect(x: bounds.width - 18 - width, y: 7, width: width, height: 26)
        laidOut = true; moveCapsule(animated: false)
    }
    private func moveCapsule(animated: Bool) {
        let target = buttons[additionalSelected ? Self.names.count : Int(options.kind ?? 0)].frame
        guard capsule.frame != target else { return }
        Theme.Motion.frame(capsule, to: target, using: animated && !Theme.Motion.reduced ? Theme.Motion.chip : nil)
    }
    func select(_ index: Int, notify: Bool = true) {
        guard !isHidden, isEnabled, index >= 0, index < Self.names.count + (additionalTitle == nil ? 0 : 1) else { return }
        additionalSelected = index == Self.names.count
        options.kind = index == 0 || additionalSelected ? nil : UInt8(index)
        if notify { onChange?() }
    }
    func cycle(_ delta: Int) {
        let count = Self.names.count + (additionalTitle == nil ? 0 : 1)
        select(((additionalSelected ? Self.names.count : Int(options.kind ?? 0)) + delta + count) % count)
    }
    private func showSortMenu() {
        guard isEnabled else { return }
        let menu = NSMenu(); menu.delegate = self
        for (i, key) in [SortKey.relevance, .name, .modified, .size].enumerated() {
            let item = NSMenuItem(title: L10n.text("sort." + Self.sortName(key)), action: #selector(sortSelected(_:)), keyEquivalent: "")
            item.tag = i; item.target = self; item.state = options.sort == key ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: sortButton.frame.minX, y: sortButton.frame.maxY), in: self)
    }
    @objc private func sortSelected(_ item: NSMenuItem) {
        let key = [SortKey.relevance, .name, .modified, .size][item.tag]
        options.ascending = options.sort == key && key != .relevance ? !options.ascending : key == .name
        options.sort = key; onSortChange?(); onChange?()
    }
    func menuWillOpen(_ menu: NSMenu) { onMenuTracking?(true) }
    func menuDidClose(_ menu: NSMenu) { onMenuTracking?(false) }
}
