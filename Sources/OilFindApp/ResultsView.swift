import AppKit
import QuartzCore
import OilFindCore

struct ResultItem {
    let id: UInt32
    let name: String, parentPath: String, path: String
    let size: UInt64, modified: Date, flags: UInt8, kind: UInt8
}

private final class ResultRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override var isEmphasized: Bool { get { true } set {} }
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
}

private final class ResultCell: NSTableCellView {
    override var isFlipped: Bool { true }
    override var backgroundStyle: NSView.BackgroundStyle { get { .normal } set {} }
    private let icon = NSImageView()
    private let nameLabel = Theme.label(13.5, .medium, .labelColor)
    private let pathLabel = Theme.label(11.5, .regular, .secondaryLabelColor)
    private let dateLabel = Theme.label(11.5, .regular, .secondaryLabelColor)
    private let sizeLabel = Theme.label(11.5, .regular, .tertiaryLabelColor)
    private var displayedPath = ""
    override init(frame: NSRect) {
        super.init(frame: frame)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        dateLabel.alignment = .right; sizeLabel.alignment = .right
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        [icon, nameLabel, pathLabel, dateLabel, sizeLabel].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 26, y: 9, width: 32, height: 32)
        let width = max(0, bounds.width - 236)
        nameLabel.frame = NSRect(x: 70, y: 8, width: width, height: 18)
        pathLabel.frame = NSRect(x: 70, y: 27, width: width, height: 15)
        dateLabel.frame = NSRect(x: bounds.width - 150, y: 9, width: 124, height: 16)
        sizeLabel.frame = NSRect(x: bounds.width - 150, y: 27, width: 124, height: 15)
    }
    func configure(_ item: ResultItem, query: Query, icons: IconProvider) {
        displayedPath = item.path
        let name = NSMutableAttributedString(string: item.name, attributes: [.font: nameLabel.font!, .foregroundColor: NSColor.labelColor])
        for range in Presentation.highlightRanges(name: item.name, query: query) {
            name.addAttributes([.foregroundColor: NSColor.controlAccentColor, .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold)], range: range)
        }
        nameLabel.attributedStringValue = name
        pathLabel.stringValue = Presentation.abbreviate(path: item.parentPath, home: NSHomeDirectory())
        dateLabel.stringValue = Presentation.dateText(item.modified, now: Date(), calendar: .current, chinese: L10n.chinese)
        sizeLabel.stringValue = item.kind == 2 ? L10n.text("meta.app") : item.flags & SiftFlag.dir != 0 && item.flags & SiftFlag.package == 0 ? L10n.text("meta.folder") : Presentation.sizeText(item.size)
        toolTip = item.path
        icon.image = icons.icon(name: item.name, path: item.path, flags: item.flags, kind: item.kind) { [weak self] image in
            if self?.displayedPath == item.path { self?.icon.image = image }
        }
    }
}

private final class ResultTable: NSTableView {
    var contextMenu: ((Int) -> NSMenu?)?
    var onPointerMove: (() -> Void)?
    var onPointerExit: (() -> Void)?
    var onPointerReselection: (() -> Void)?
    private(set) var selectingWithPointer = false
    private var tracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { false }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); window?.acceptsMouseMovedEvents = true
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseMoved(with event: NSEvent) { onPointerMove?() }
    override func mouseEntered(with event: NSEvent) { onPointerMove?() }
    override func mouseExited(with event: NSEvent) { onPointerExit?() }
    override func mouseDown(with event: NSEvent) {
        selectingWithPointer = true; defer { selectingWithPointer = false }
        // Reselecting a row does not emit a selection-change notification.
        if selectedRow >= 0, row(at: convert(event.locationInWindow, from: nil)) == selectedRow { onPointerReselection?() }
        super.mouseDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        selectingWithPointer = true; defer { selectingWithPointer = false }
        if row == selectedRow { onPointerReselection?() }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return contextMenu?(row)
    }
}

private final class ResultScrollView: NSScrollView {
    var onScrollWheel: ((NSEvent) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        onScrollWheel?(event); super.scrollWheel(with: event)
    }
}

// Refresh policy is independent of AppKit and uses the displayed result as its baseline.
enum ResultRefreshAction: Equatable { case replaceResult, reloadVisibleRows, reloadPreservingViewport, deferRefresh }

func resultRefreshAction(oldItems: [UInt32], newItems: [UInt32], sameStore: Bool,
                         sameVersion: Bool, scrolling: Bool, dragging: Bool) -> ResultRefreshAction {
    if scrolling || dragging { return .deferRefresh }
    if sameStore && oldItems == newItems { return sameVersion ? .replaceResult : .reloadVisibleRows }
    return .reloadPreservingViewport
}

final class ResultsView: FlippedView, NSTableViewDataSource, NSTableViewDelegate {
    private let scroll = ResultScrollView()
    private let table = ResultTable()
    private let hoverPlate = TintPlate(radius: 10) { _ in NSColor.labelColor.withAlphaComponent(0.04) }
    private let selectionPlate = TintPlate(radius: 10) { view in
        NSColor.controlAccentColor.withAlphaComponent(Theme.dark(view) ? 0.30 : 0.16)
    }
    private var refreshing = false, repeating = false
    private var pressGeneration = 0
    private var pendingPress = false
    private var hoverRow: Int?
    private var liveScrolling = false, wheelScrolling = false, momentumScrolling = false, dragging = false
    private var scrollEnd: DispatchWorkItem?
    // Legacy wheels have no end phase; also bridge the gesture-to-momentum gap.
    private static let scrollQuietPeriod = 0.12
    private var pendingRefresh: SearchResult?
    private var scrolling: Bool { liveScrolling || wheelScrolling || momentumScrolling }
    let icons = IconProvider()
    var result: SearchResult?
    var onOpen: (() -> Void)?
    var onSelection: (() -> Void)?
    var onContextMenu: ((Int) -> NSMenu?)?
    var onDragging: ((Bool) -> Void)?
    var onRefreshApplied: ((SearchResult) -> Void)?
    var selectedRow: Int { table.selectedRow }
    var selectedID: UInt32? {
        guard let result, result.items.indices.contains(selectedRow) else { return nil }
        return result.items[selectedRow]
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        wantsLayer = true; table.wantsLayer = true
        table.style = .plain
        table.backgroundColor = .clear; table.headerView = nil; table.rowHeight = 50
        table.intercellSpacing = .zero; table.usesAutomaticRowHeights = false
        table.selectionHighlightStyle = .regular; table.allowsMultipleSelection = false
        table.focusRingType = .none; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result")); column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.delegate = self; table.dataSource = self
        table.target = self; table.doubleAction = #selector(doubleClicked)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.contextMenu = { [weak self] row in self?.onContextMenu?(row) }
        table.onPointerMove = { [weak self] in self?.recomputeHover() }
        table.onPointerExit = { [weak self] in self?.hideHover() }
        table.onPointerReselection = { [weak self] in self?.updateSelection(animated: false) }
        scroll.onScrollWheel = { [weak self] event in self?.wheelScrolled(event) }
        scroll.documentView = table; addSubview(scroll)
        table.addSubview(hoverPlate, positioned: .below, relativeTo: nil); hoverPlate.alphaValue = 0
        table.addSubview(selectionPlate, positioned: .below, relativeTo: nil); selectionPlate.isHidden = true
        let notifications = NotificationCenter.default
        notifications.addObserver(self, selector: #selector(scrollStarted), name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        notifications.addObserver(self, selector: #selector(scrollEnded), name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        scroll.contentView.postsBoundsChangedNotifications = true
        notifications.addObserver(self, selector: #selector(clipBoundsChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout(); scroll.frame = bounds
        let width = scroll.contentSize.width
        if table.tableColumns[0].width != width { table.tableColumns[0].width = width }
        updateSelection(animated: false); recomputeHover()
    }
    func show(_ result: SearchResult, selection: Int = 0, resetScroll: Bool = true) {
        cancelPendingRefresh(); hideHover(immediately: true)
        refreshing = true
        self.result = result; table.reloadData()
        select(selection)
        if resetScroll { scroll.contentView.scroll(to: NSPoint(x: 0, y: -6)); scroll.reflectScrolledClipView(scroll.contentView) }
        updateSelection(animated: false); refreshing = false
        recomputeHover(); onSelection?()
    }
    func cancelPendingRefresh() { pendingRefresh = nil }
    func localize() {
        let range = table.rows(in: table.visibleRect)
        guard range.location != NSNotFound, range.length > 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: range.location..<NSMaxRange(range)), columnIndexes: IndexSet(integer: 0))
    }
    func refresh(_ result: SearchResult) {
        let previous = self.result
        let action = resultRefreshAction(oldItems: previous?.items ?? [], newItems: result.items,
                                         sameStore: previous?.store === result.store,
                                         sameVersion: previous?.storeVersion == result.storeVersion,
                                         scrolling: scrolling, dragging: dragging)
        if action == .deferRefresh { pendingRefresh = result; return }
        pendingRefresh = nil
        let origin = scroll.contentView.bounds.origin
        var row = selectedRow
        if action == .reloadPreservingViewport {
            var id = selectedID
            if previous?.store !== result.store {
                id = selectedItem.flatMap { item in result.store.read { result.store.hashReady ? result.store.resolve(path: item.path) : nil } }
            }
            row = id.flatMap { result.items.firstIndex(of: $0) } ?? 0
        }
        refreshing = true; self.result = result
        switch action {
        case .replaceResult: break
        case .reloadVisibleRows:
            hideHover(immediately: true)
            let visible = table.rows(in: table.visibleRect)
            if visible.location != NSNotFound {
                let range = NSIntersectionRange(visible, NSRange(location: 0, length: result.items.count))
                if range.length > 0 {
                    table.reloadData(forRowIndexes: IndexSet(integersIn: range.location..<NSMaxRange(range)), columnIndexes: IndexSet(integer: 0))
                }
            }
        case .reloadPreservingViewport:
            hideHover(immediately: true); table.reloadData()
            setSelection(row, reveal: false)
            var rect = scroll.contentView.bounds; rect.origin = origin
            scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(rect).origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            updateSelection(animated: false)
        case .deferRefresh: break
        }
        refreshing = false
        if action != .replaceResult { recomputeHover(); onSelection?() }
        onRefreshApplied?(result)
    }
    private func hideHover(immediately: Bool = false) {
        hoverRow = nil
        Theme.Motion.opacity(hoverPlate, to: 0, using: immediately ? nil : Theme.Motion.basic(Theme.Motion.hover))
    }
    private func recomputeHover() {
        guard !refreshing, !scrolling, !dragging, let window, window.isVisible else { hideHover(immediately: true); return }
        let point = window.mouseLocationOutsideOfEventStream
        guard scroll.contentView.bounds.contains(scroll.contentView.convert(point, from: nil)) else { hideHover(); return }
        let row = table.row(at: table.convert(point, from: nil))
        guard row >= 0, row != selectedRow else { hideHover(); return }
        Theme.Motion.frame(hoverPlate, to: table.rect(ofRow: row).insetBy(dx: 10, dy: 1), using: nil)
        if hoverRow == nil { Theme.Motion.opacity(hoverPlate, to: 1, using: Theme.Motion.basic(Theme.Motion.hover)) }
        hoverRow = row
    }
    @objc private func scrollStarted() { liveScrolling = true; hideHover(immediately: true) }
    @objc private func scrollEnded() { liveScrolling = false; finishInteraction() }
    @objc private func clipBoundsChanged() {
        hideHover(immediately: true)
        if !scrolling && !dragging {
            DispatchQueue.main.async { [weak self] in self?.recomputeHover() }
        }
    }
    private func wheelScrolled(_ event: NSEvent) {
        wheelScrolling = true; hideHover(immediately: true)
        if !event.momentumPhase.intersection([.began, .changed, .stationary]).isEmpty { momentumScrolling = true }
        if !event.momentumPhase.intersection([.ended, .cancelled]).isEmpty { momentumScrolling = false }
        scrollEnd?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.wheelScrolling = false; self.finishInteraction()
        }
        scrollEnd = work; DispatchQueue.main.asyncAfter(deadline: .now() + Self.scrollQuietPeriod, execute: work)
    }
    private func finishInteraction() {
        guard !scrolling, !dragging else { return }
        if let pendingRefresh { refresh(pendingRefresh) }
        recomputeHover()
    }
    deinit { scrollEnd?.cancel(); NotificationCenter.default.removeObserver(self) }
    func item(at row: Int) -> ResultItem? {
        guard let result, result.items.indices.contains(row) else { return nil }
        let store = result.store, id = result.items[row]
        return store.read {
            guard Int(id) < store.count, store.isLive(id) else { return nil }
            let name = store.name(id), parent = store.parentPath(id)
            return ResultItem(id: id, name: name, parentPath: parent, path: parent == "/" ? "/" + name : parent + "/" + name,
                              size: store.size(id), modified: store.modified(id), flags: store.flags[Int(id)], kind: store.kind[Int(id)])
        }
    }
    var selectedItem: ResultItem? { item(at: selectedRow) }
    func select(_ row: Int, repeatKey: Bool = false) {
        repeating = repeatKey; defer { repeating = false }
        setSelection(row, reveal: true)
    }
    private func setSelection(_ row: Int, reveal: Bool) {
        guard let result, !result.items.isEmpty else { table.deselectAll(nil); return }
        let row = min(max(0, row), result.items.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if reveal { table.scrollRowToVisible(row) }
    }
    func move(_ delta: Int, repeatKey: Bool = false) {
        guard let result, !result.items.isEmpty else { return }
        let target = max(0, selectedRow) + delta
        if !repeatKey && (target < 0 || target >= result.items.count) { nudge(delta) }
        select(target, repeatKey: repeatKey)
    }
    func page(_ delta: Int, repeatKey: Bool = false) { select(max(0, selectedRow) + delta * max(1, Int(scroll.contentSize.height / Theme.rowHeight)), repeatKey: repeatKey) }
    private func updateSelection(animated: Bool) {
        guard selectedRow >= 0 else { selectionPlate.isHidden = true; return }
        let rect = table.rect(ofRow: selectedRow).insetBy(dx: 10, dy: 1)
        let first = selectionPlate.isHidden
        selectionPlate.isHidden = false
        let animation: CABasicAnimation? = animated && !first && !Theme.Motion.reduced
            ? (repeating ? Theme.Motion.basic(Theme.Motion.selectionRepeat, .linear) : Theme.Motion.selection) : nil
        Theme.Motion.frame(selectionPlate, to: rect, using: animation)
    }
    private func nudge(_ direction: Int) {
        guard !Theme.Motion.reduced, let layer = table.layer else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.y")
        let current = layer.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat ?? 0
        animation.values = [current, direction < 0 ? -Theme.Motion.nudgeOffset : Theme.Motion.nudgeOffset, 0]
        animation.keyTimes = [0, 0.5, 1]; animation.duration = Theme.Motion.nudge
        animation.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeOut)]
        layer.add(animation, forKey: "transform.translation.y")
    }
    func pressOpen(_ action: @escaping () -> Void) {
        guard !Theme.Motion.reduced, let layer = selectionPlate.layer else { action(); return }
        pressGeneration += 1; let token = pressGeneration
        pendingPress = true
        let frame = layer.frame; layer.anchorPoint = CGPoint(x: 0.5, y: 0.5); layer.frame = frame
        Theme.Motion.animate(layer, "transform.scale", to: Theme.Motion.pressScale, using: Theme.Motion.basic(Theme.Motion.press))
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.press) { [weak self] in
            guard let self, self.pressGeneration == token, self.pendingPress else { return }
            self.pendingPress = false
            Theme.Motion.animate(layer, "transform.scale", to: 1, using: Theme.Motion.basic(Theme.Motion.press))
            action()
        }
    }
    func cancelPress() {
        guard pendingPress else { return }
        pendingPress = false; pressGeneration += 1
        if let layer = selectionPlate.layer { Theme.Motion.animate(layer, "transform.scale", to: 1, using: Theme.Motion.basic(Theme.Motion.press)) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { result?.items.count ?? 0 }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("row")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? ResultRow ?? ResultRow(frame: .zero)
        view.identifier = identifier; return view
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ResultCell ?? ResultCell(frame: .zero)
        cell.identifier = identifier
        if let item = item(at: row), let result { cell.configure(item, query: result.query, icons: icons) }
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshing else { return }
        updateSelection(animated: !table.selectingWithPointer); recomputeHover(); onSelection?()
    }
    @objc private func doubleClicked() { if table.clickedRow >= 0 { onOpen?() } }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        item(at: row).map { NSURL(fileURLWithPath: $0.path) }
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        dragging = true; hideHover(immediately: true); onDragging?(true)
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false; finishInteraction(); onDragging?(false)
    }
}
