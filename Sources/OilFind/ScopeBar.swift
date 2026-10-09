import AppKit

final class ScopeBar: FlippedView {
    private var buttons: [ChromeButton] = []
    var scope = SearchScope.all { didSet { refresh() } }
    var onChange: ((SearchScope) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        for scope in SearchScope.allCases {
            let button = ChromeButton(scope.title, style: .filter, size: 12.5, weight: .medium)
            button.onPress = { [weak self] in self?.scope = scope; self?.onChange?(scope) }
            button.toolTip = "⌘" + String(SearchScope.allCases.firstIndex(of: scope)!)
            buttons.append(button); addSubview(button)
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func localize() { for (button, scope) in zip(buttons, SearchScope.allCases) { button.title = scope.title }; refresh() }
    private func refresh() { for (button, value) in zip(buttons, SearchScope.allCases) { button.active = value == scope }; needsLayout = true }
    override func layout() {
        super.layout(); var x: CGFloat = 18
        for button in buttons {
            let width = Theme.textWidth(button.title, font: button.font!) + 26
            button.frame = NSRect(x: x, y: 7, width: width, height: 26); x += width + 5
        }
    }
}
