import AppKit
import OilFindCore

final class StateView: FlippedView {
    enum State { case empty, indexing }
    let state: State
    private var diagnostic: QueryDiagnostic?
    private var hasNoAccess = false
    private(set) var count = 0
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = Theme.label(14, .medium, .secondaryLabelColor)
    private let noAccess = Theme.label(12, .regular, .secondaryLabelColor)
    let grant = NSButton(title: L10n.text("empty.grant"), target: nil, action: nil)
    private let body = Theme.label(12, .regular, .tertiaryLabelColor)
    init(_ state: State) {
        self.state = state
        super.init(frame: .zero); wantsLayer = true
        titleLabel.alignment = .center; body.alignment = .center
        [icon, spinner, titleLabel, body, noAccess, grant].forEach(addSubview)
        noAccess.stringValue = L10n.text("empty.noAccess"); noAccess.alignment = .center
        grant.target = self; grant.action = #selector(grantAccess); grant.bezelStyle = .rounded
        noAccess.isHidden = true; grant.isHidden = true
        body.maximumNumberOfLines = 2
        spinner.style = .spinning; spinner.controlSize = .regular
        icon.isHidden = state == .indexing; spinner.isHidden = state != .indexing
        switch state {
        case .empty:
            icon.image = Theme.symbol("magnifyingglass", size: 34, weight: .light); icon.contentTintColor = .tertiaryLabelColor
            titleLabel.stringValue = L10n.text("empty.title"); body.stringValue = L10n.text("empty.body")
        case .indexing:
            titleLabel.stringValue = L10n.text("indexing.title"); updateCount(0); spinner.startAnimation(nil)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func grantAccess() { Permissions.openSettings() }
    func configure(diagnostic: QueryDiagnostic?, hasNoAccess: Bool) {
        self.diagnostic = diagnostic; self.hasNoAccess = hasNoAccess
        titleLabel.stringValue = L10n.text(diagnostic == nil ? "empty.title" : "diag.title")
        body.stringValue = diagnostic.map(L10n.diagnostic) ?? L10n.text("empty.body")
        noAccess.isHidden = !hasNoAccess; grant.isHidden = !hasNoAccess; needsLayout = true
    }
    func updateCount(_ count: Int) { self.count = count; body.stringValue = L10n.text("indexing.body", Presentation.countText(count)) }
    func localize() {
        noAccess.stringValue = L10n.text("empty.noAccess"); grant.title = L10n.text("empty.grant")
        switch state {
        case .empty: configure(diagnostic: diagnostic, hasNoAccess: hasNoAccess)
        case .indexing: titleLabel.stringValue = L10n.text("indexing.title"); updateCount(count)
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let iconSize: CGFloat = state == .indexing ? 32 : 34
        let total = iconSize + 14 + 20 + 6 + 36 + (grant.isHidden ? 0 : 64)
        var y = (bounds.height - total) / 2
        icon.frame = NSRect(x: (bounds.width - iconSize) / 2, y: y, width: iconSize, height: iconSize)
        spinner.frame = icon.frame; y += iconSize + 14
        titleLabel.frame = NSRect(x: 24, y: y, width: bounds.width - 48, height: 20); y += 26
        body.frame = NSRect(x: 24, y: y, width: bounds.width - 48, height: 36)
        noAccess.frame = NSRect(x: 24, y: y + 40, width: bounds.width - 48, height: 18)
        grant.frame = NSRect(x: (bounds.width - 150) / 2, y: y + 64, width: 150, height: 28)
    }
}
