import AppKit
import XCTest
@testable import OilFind
@testable import OilFindCore

final class LauncherSearchTests: XCTestCase {
    // Synthetic SoA stores exercise the real parser/searcher without filesystem scans.
    private func store(_ names: [String], root: String = "/Users/demo/LauncherSearchTests") -> IndexStore {
        let store = IndexStore(rootPath: root, count: 1, namesLen: 0, altCount: 0, altLen: 0,
                               fingerprint: 0, homeIndex: UInt32.max, finishedAt: 0)
        store.nameOff[0] = 0; store.nameOff[1] = 0
        store.parent[0] = 0; store.sizeC[0] = 0; store.mtime[0] = 0
        store.flags[0] = SiftFlag.dir; store.depth[0] = 3; store.kind[0] = 1; store.altOff[0] = 0
        store.write {
            store.buildHash()
            for name in names {
                Array(name.utf8).withUnsafeBufferPointer {
                    _ = store.insert(parent: 0, name: $0, attrs: EntryAttrs(type: name.hasSuffix(".app") ? 1 : 0))
                }
            }
        }
        return store
    }

    private func result(_ store: IndexStore, raw: String = "", ids: [UInt32]? = nil) -> SearchResult {
        let items = ids ?? (1..<store.count).map(UInt32.init)
        return SearchResult(store: store, query: Query.parse(raw, store: store), options: .init(),
                            items: items, total: items.count, sortedCount: items.count, elapsedMs: 0,
                            scores: Array(repeating: 0, count: items.count))
    }

    private func identities(_ snapshot: SearchSnapshot) -> [String] {
        (0..<snapshot.count).compactMap { snapshot.row(at: $0)?.identity }
    }

    private func search(_ coordinator: SearchCoordinator, raw: String, scope: SearchScope = .all,
                        store: IndexStore? = nil, apps: [LauncherApp] = [], clipboard: [ClipboardEntry] = [],
                        clipboardEnabled: Bool = false, composing: Bool = false,
                        calculator: Bool = false, web: Bool = false) {
        coordinator.search(raw: raw, scope: scope, options: .init(sort: .name, ascending: true), store: store,
                           editingRange: nil, composing: composing, apps: apps, clipboard: clipboard,
                           clipboardEnabled: clipboardEnabled, calculator: calculator, web: web, engine: .duckDuckGo)
    }

    // Queue fences run after work enqueues its main-thread publication. No timing sleeps.
    private func drain(_ queues: [DispatchQueue]) {
        let fences = queues.enumerated().map { index, queue -> XCTestExpectation in
            let fence = expectation(description: "Queue \(index) and its publications drained")
            queue.async { DispatchQueue.main.async { fence.fulfill() } }
            return fence
        }
        wait(for: fences, timeout: 3)
    }

    func testAutomaticFileRoutingIncludesPathsPrefixesAndGlobs() {
        for query in ["/Applications", "~/Documents", "./src", "../notes", "docs/report.pdf", "file:///tmp/report.pdf",
                      "kind:app", "!EXT:pdf", "notes file:report", "folder:docs", "size:>1mb", "dm:today",
                      "regex:^notes", "path:Documents", "!PATH:private", "case:README", "notes *.md", "photo?.jpg"] {
            XCTAssertEqual(SearchRoute.effectiveScope(query, requested: .all), .files, query)
        }
        for query in ["notes", "系统设置", "report.pdf", "", "150*20%", "5/2", "https://example.com/path?q=1",
                      "example.com/docs", "web: docs/report.pdf", "10公里转英里"] {
            XCTAssertEqual(SearchRoute.effectiveScope(query, requested: .all), .all, query)
        }
    }

    func testExplicitScopeAndIMECompositionTakePriorityOverAutomaticRouting() {
        for scope in [SearchScope.apps, .files, .settings, .clipboard] {
            for query in ["/Applications", "ext:pdf", "5/2", "web: keyboard"] {
                XCTAssertEqual(SearchRoute.effectiveScope(query, requested: scope), scope)
            }
        }
        XCTAssertEqual(SearchRoute.effectiveScope("path:Documents", requested: .all, composing: true), .all)
        XCTAssertEqual(SearchRoute.effectiveScope("folder/report", requested: .clipboard, composing: true), .clipboard)
    }

    func testSnapshotOffsetsAndBoundaryRowsPreserveEveryUnpromotedFile() {
        let files = result(store(["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"]))
        let leading: [LauncherRow] = [.enableClipboard]
        let tail = LauncherRow.web("notes", WebSearchEngine.bing.url(for: "notes"))
        let snapshot = SearchSnapshot(raw: "notes", scope: .all, fileResult: files, leading: leading,
                                      trailing: [tail], removedOffsets: [3, 1], filesPending: true)
        XCTAssertEqual(snapshot.removedOffsets, [1, 3])
        XCTAssertEqual(snapshot.count, 5)
        XCTAssertTrue(snapshot.filesPending)
        XCTAssertEqual(identities(snapshot), ["enableClipboard", "file:\(files.store.rootPath)/a.txt",
                                            "file:\(files.store.rootPath)/c.txt", "file:\(files.store.rootPath)/e.txt", "web:notes"])
        XCTAssertNil(snapshot.row(at: -1)); XCTAssertNil(snapshot.row(at: snapshot.count))
        XCTAssertNil(SearchSnapshot.fileItem(files, offset: -1)); XCTAssertNil(SearchSnapshot.fileItem(files, offset: 5))
        XCTAssertEqual(snapshot.position(of: tail.identity), 4)
        XCTAssertNil(snapshot.position(of: "file:\(files.store.rootPath)/b.txt"))
    }

    func testNonemptyComposeDeduplicatesApplicationsBeyondPromotedFilePrefix() {
        let names = (0..<30).map { String(format: "tool-%02d.txt", $0) } + ["tool-Z.app"]
        let files = result(store(names), raw: "tool")
        let app = LauncherApp(name: "tool", path: files.store.rootPath + "/tool-Z.app")
        let snapshot = SearchCoordinator.compose(raw: "tool", scope: .all, fileResult: files, extras: [.app(app), .app(app)])
        let rows = identities(snapshot)
        XCTAssertEqual(snapshot.leading.first?.identity, "file:" + app.path)
        XCTAssertEqual(snapshot.leading.count, 5)
        XCTAssertTrue(snapshot.removedOffsets.contains(30))
        XCTAssertEqual(snapshot.count, files.items.count)
        XCTAssertEqual(Set(rows).count, rows.count)
        XCTAssertEqual(rows.filter { $0 == "file:" + app.path }.count, 1)
        XCTAssertEqual(Set(rows), Set(names.map { "file:" + files.store.rootPath + "/" + $0 }))
    }

    func testEmptyComposeDeduplicatesAllRecentAppsAcrossEntireFileArray() {
        let names = (0..<24).map { "note-\($0).txt" } + ["Alpha.app", "Beta.app"]
        let files = result(store(names))
        let apps = ["Alpha", "Beta"].map { LauncherRow.app(LauncherApp(name: $0, path: files.store.rootPath + "/" + $0 + ".app")) }
        let snapshot = SearchCoordinator.compose(raw: "  ", scope: .all, fileResult: files, extras: apps)
        XCTAssertEqual(snapshot.removedOffsets, [24, 25])
        XCTAssertEqual(snapshot.count, names.count)
        XCTAssertEqual(Set(identities(snapshot)).count, snapshot.count)
        XCTAssertEqual(Array(identities(snapshot).prefix(2)), apps.map(\.identity))
    }

    func testApplicationDeduplicationAcrossVectorBlocksAndScalarTail() {
        let names = (0..<259).map { "needle-\($0).app" }
        let files = result(store(names), raw: "needle")
        let offsets = [0, 15, 16, 255, 258]
        let apps = offsets.map { offset in
            LauncherRow.app(LauncherApp(name: names[offset], path: files.store.rootPath + "/" + names[offset]))
        }
        let snapshot = SearchCoordinator.compose(raw: "needle", scope: .all, fileResult: files, extras: apps)
        XCTAssertEqual(snapshot.removedOffsets, offsets)
        XCTAssertEqual(snapshot.count, names.count)
        XCTAssertEqual(Set(identities(snapshot)).count, names.count)
        XCTAssertEqual(Set(identities(snapshot)), Set(names.map { "file:" + files.store.rootPath + "/" + $0 }))
    }

    func testStablePromotionOrderAndScopeIsolation() {
        let appA = LauncherApp(name: "notes", path: "/Applications/A.app")
        let appB = LauncherApp(name: "notes", path: "/Applications/B.app")
        let setting = SystemSetting(id: "test-notes", englishName: "notes", chineseName: "notes", symbol: "gear",
                                    url: URL(string: "https://example.com/settings")!)
        let files = result(store(["notes", "notes.txt"]), raw: "notes")
        let snapshot = SearchCoordinator.compose(raw: "notes", scope: .all, fileResult: files,
                                                 extras: [.setting(setting), .app(appB), .app(appA)])
        XCTAssertEqual(Array(identities(snapshot).prefix(3)), ["file:" + appB.path, "file:" + appA.path, "setting:test-notes"])
        let apps = SearchCoordinator.compose(raw: "notes", scope: .apps, fileResult: files, extras: [.app(appA)])
        XCTAssertNil(apps.fileResult); XCTAssertEqual(apps.count, 1)
        let fileOnly = SearchCoordinator.compose(raw: "notes", scope: .files, fileResult: files, extras: [])
        XCTAssertEqual(fileOnly.count, 2); XCTAssertTrue(fileOnly.leading.isEmpty)
    }

    func testIdentityRecoveryUsesPathWhenSameStoreHasNoFileIDAndAfterStoreReplacement() throws {
        let oldStore = store(["a.txt", "selected.txt", "z.txt"])
        let newStore = store(["z.txt", "a.txt", "selected.txt"])
        let identity = "file:" + oldStore.rootPath + "/selected.txt"
        let old = SearchSnapshot(raw: "", scope: .files, fileResult: result(oldStore))
        XCTAssertEqual(old.position(of: identity, fileID: nil, store: oldStore), 1)
        let replacement = SearchSnapshot(raw: "", scope: .files, fileResult: result(newStore))
        XCTAssertEqual(replacement.position(of: identity, fileID: 2, store: oldStore), 2)
        XCTAssertNil(replacement.position(of: "file:" + oldStore.rootPath + "/missing.txt", fileID: 2, store: oldStore))
        let promotedApp = LauncherApp(name: "selected", path: oldStore.rootPath + "/selected.txt")
        let promoted = SearchCoordinator.compose(raw: "selected", scope: .all, fileResult: result(oldStore), extras: [.app(promotedApp)])
        XCTAssertEqual(promoted.position(of: identity, fileID: 2, store: oldStore), 0)

        _ = NSApplication.shared
        let view = ResultsView(frame: NSRect(origin: .zero, size: Theme.panelSize))
        view.show(old, selection: 1)
        view.refresh(promoted)
        XCTAssertEqual(view.selectedLauncherRow?.identity, identity)
        XCTAssertNil(view.selectedID)
        // App -> file demotion shares the store but lacks a selected compact file ID.
        view.refresh(old)
        XCTAssertEqual(view.selectedRow, 1)
        XCTAssertEqual(view.selectedLauncherRow?.identity, identity)
        view.refresh(replacement)
        XCTAssertEqual(view.selectedRow, 2)
        XCTAssertEqual(view.selectedLauncherRow?.identity, identity)
    }

    func testClipboardAndTrailingWebIdentitySurviveReordering() {
        let entry = ClipboardEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!, text: "notes")
        let old = SearchSnapshot(raw: "", scope: .clipboard, leading: [.enableClipboard, .clipboard(entry)])
        let updated = SearchSnapshot(raw: "", scope: .clipboard, leading: [.clipboard(entry)])
        XCTAssertEqual(old.position(of: "clip:" + entry.id.uuidString), 1)
        XCTAssertEqual(updated.position(of: "clip:" + entry.id.uuidString), 0)
        let web = LauncherRow.web("notes", WebSearchEngine.google.url(for: "notes"))
        let snapshot = SearchSnapshot(raw: "notes", scope: .all, leading: [.enableClipboard], trailing: [web])
        XCTAssertEqual(snapshot.position(of: "web:notes"), 1)
        XCTAssertNil(snapshot.position(of: "web:missing"))
    }

    func testSourcesPublishWhileFileQueueIsBlockedThenFilesMergeAsRefresh() {
        let fileQueue = DispatchQueue(label: "LauncherSearchTests.blocked-files")
        let sourceQueue = DispatchQueue(label: "LauncherSearchTests.sources")
        fileQueue.suspend()
        var released = false
        defer { if !released { fileQueue.resume() } }
        let coordinator = SearchCoordinator(fileQueue: fileQueue, sourceQueue: sourceQueue)
        let files = store(["needle.txt"])
        let app = LauncherApp(name: "needle", path: "/Applications/Needle.app")
        var updates: [(SearchSnapshot, Bool)] = []
        coordinator.onUpdate = { found, refresh in
            XCTAssertTrue(Thread.isMainThread)
            updates.append((found, refresh))
        }
        search(coordinator, raw: "needle", store: files, apps: [app])
        drain([sourceQueue])
        XCTAssertEqual(updates.count, 1)
        XCTAssertNil(updates.first?.0.fileResult)
        XCTAssertEqual(updates.first?.0.filesPending, true)
        XCTAssertEqual(updates.first?.1, false)
        XCTAssertEqual(updates.first?.0.row(at: 0)?.identity, "file:" + app.path)
        fileQueue.resume(); released = true
        drain([fileQueue])
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates.last?.0.filesPending, false)
        XCTAssertTrue(updates.last?.0.fileResult?.store === files)
        XCTAssertEqual(updates.last?.1, true)
        XCTAssertEqual(Set(identities(updates.last!.0)), ["file:" + app.path, "file:" + files.rootPath + "/needle.txt"])
    }

    func testFilesPublishWhileSourceQueueIsBlocked() {
        let fileQueue = DispatchQueue(label: "LauncherSearchTests.files")
        let sourceQueue = DispatchQueue(label: "LauncherSearchTests.blocked-sources")
        sourceQueue.suspend()
        var released = false
        defer { if !released { sourceQueue.resume() } }
        let coordinator = SearchCoordinator(fileQueue: fileQueue, sourceQueue: sourceQueue)
        let files = store(["needle.txt"])
        let app = LauncherApp(name: "needle", path: "/Applications/Needle.app")
        var updates: [(SearchSnapshot, Bool)] = []
        coordinator.onUpdate = { updates.append(($0, $1)) }
        search(coordinator, raw: "needle", store: files, apps: [app])
        drain([fileQueue])
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.0.count, 1)
        XCTAssertNotNil(updates.first?.0.fileResult)
        XCTAssertEqual(updates.first?.1, false)
        sourceQueue.resume(); released = true
        drain([sourceQueue])
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates.last?.0.count, 2)
        XCTAssertEqual(updates.last?.1, true)
    }

    func testLateFilesKeepTheSelectedApplicationIdentityWhenLeadingRowsGrow() {
        _ = NSApplication.shared
        let fileQueue = DispatchQueue(label: "LauncherSearchTests.selection-files")
        let sourceQueue = DispatchQueue(label: "LauncherSearchTests.selection-sources")
        fileQueue.suspend()
        let coordinator = SearchCoordinator(fileQueue: fileQueue, sourceQueue: sourceQueue)
        let view = ResultsView(frame: NSRect(origin: .zero, size: Theme.panelSize))
        let apps = ["needle alpha", "needle selected"].enumerated().map {
            LauncherApp(name: $0.element, path: "/Users/demo/Apps/Needle-\($0.offset).app")
        }
        coordinator.onUpdate = { found, refresh in
            if refresh { view.refresh(found, preserveSelection: true) }
            else { view.show(found, selection: 1) }
        }
        search(coordinator, raw: "needle", store: store(["needle"]), apps: apps)
        drain([sourceQueue])
        XCTAssertEqual(view.selectedLauncherRow?.identity, "file:" + apps[1].path)
        XCTAssertEqual(view.selectedRow, 1)
        fileQueue.resume()
        drain([fileQueue])
        XCTAssertEqual(view.selectedRow, 2)
        XCTAssertEqual(view.selectedLauncherRow?.identity, "file:" + apps[1].path)
        XCTAssertEqual(view.snapshot?.leading.count, 3)
    }

    func testSelectedFileAndViewportReturnAfterShortSourceOnlyPendingSnapshot() throws {
        _ = NSApplication.shared
        let files = result(store((0..<40).map { String(format: "note-%02d.txt", $0) }), raw: "note")
        let original = SearchSnapshot(raw: "note", scope: .all, fileResult: files)
        let apps: [LauncherRow] = [.app(LauncherApp(name: "Notes", path: "/Users/demo/Notes.app")),
                                   .app(LauncherApp(name: "Notes Editor", path: "/Users/demo/Notes Editor.app"))]
        let pending = SearchSnapshot(raw: "note", scope: .all, leading: apps, filesPending: true)
        let complete = SearchSnapshot(raw: "note", scope: .all, fileResult: files, leading: apps)
        let view = ResultsView(frame: NSRect(x: 0, y: 0, width: Theme.panelSize.width, height: 300))
        view.show(original, selection: 10)
        view.layoutSubtreeIfNeeded()
        let selected = try XCTUnwrap(view.selectedItem?.path)
        let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? NSScrollView }.first)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300)); scroll.reflectScrolledClipView(scroll.contentView)
        let origin = scroll.contentView.bounds.origin
        XCTAssertGreaterThan(origin.y, 0)
        view.refresh(pending, preserveSelection: true)
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(view.selectedItem)
        XCTAssertTrue(view.snapshot?.filesPending == true)
        XCTAssertLessThan(scroll.contentView.bounds.origin.y, origin.y)
        view.refresh(complete, preserveSelection: true)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.selectedItem?.path, selected)
        XCTAssertEqual(view.selectedRow, 12)
        XCTAssertEqual(scroll.contentView.bounds.origin.x, origin.x, accuracy: 0.5)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, origin.y, accuracy: 0.5)
    }

    func testUserSelectionOrNavigationClearsPendingFileIdentity() throws {
        _ = NSApplication.shared
        let files = result(store((0..<30).map { "note-\($0).txt" }), raw: "note")
        let original = SearchSnapshot(raw: "note", scope: .all, fileResult: files)
        let apps: [LauncherRow] = [.app(LauncherApp(name: "Notes", path: "/Users/demo/Notes.app")),
                                   .app(LauncherApp(name: "Notes Editor", path: "/Users/demo/Notes Editor.app"))]
        let pending = SearchSnapshot(raw: "note", scope: .all, leading: apps, filesPending: true)
        let complete = SearchSnapshot(raw: "note", scope: .all, fileResult: files, leading: apps)
        for navigate in [false, true] {
            let view = ResultsView(frame: NSRect(x: 0, y: 0, width: Theme.panelSize.width, height: 300))
            view.show(original, selection: 10)
            view.layoutSubtreeIfNeeded()
            view.refresh(pending, preserveSelection: true)
            if navigate { view.move(1) } else { view.select(0) }
            let selected = try XCTUnwrap(view.selectedLauncherRow?.identity)
            let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? NSScrollView }.first)
            let origin = scroll.contentView.bounds.origin
            view.refresh(complete, preserveSelection: true)
            XCTAssertEqual(view.selectedLauncherRow?.identity, selected)
            XCTAssertNil(view.selectedItem)
            XCTAssertEqual(view.selectedRow, navigate ? 1 : 0)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, origin.y, accuracy: 0.5)
        }
    }

    func testStaleRawOrScopeBlocksClipboardOpenCopyAndDeleteActions() throws {
        _ = NSApplication.shared
        let controller = SearchViewController(snapshot: true)
        let entry = ClipboardEntry(text: "Synthetic clipboard note")
        func key(_ character: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                          timestamp: 0, windowNumber: 0, context: nil, characters: character,
                                          charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
        }
        for staleScope in [false, true] {
            let found = SearchSnapshot(raw: "old", scope: .clipboard, leading: [.clipboard(entry)])
            try controller.prepareLauncherSnapshot(found, clipboardEntries: [entry])
            if staleScope { controller.scopes.scope = .apps } else { controller.searchField.text = "new" }
            XCTAssertNil(controller.clipboard.error)
            XCTAssertTrue(controller.handleKey(try key("c", code: 8, modifiers: .command)))
            XCTAssertTrue(controller.handleKey(try key("\r", code: 36)))
            XCTAssertTrue(controller.handleKey(try key("", code: 51, modifiers: .command)))
            XCTAssertNil(controller.clipboard.error, "Stale rows must not even attempt snapshot Copy")
            XCTAssertEqual(controller.clipboard.entries, [entry], "Stale rows must not delete entries")
            XCTAssertTrue(controller.results.snapshot === found)
        }
        // Enable is a reversible local probe of the openSelected guard; no external open.
        try controller.prepareLauncherSnapshot(SearchSnapshot(raw: "old", scope: .clipboard, leading: [.enableClipboard]))
        controller.clipboard.prepareSnapshot([], enabled: false)
        controller.searchField.text = "new"
        XCTAssertTrue(controller.handleKey(try key("\r", code: 36)))
        XCTAssertFalse(controller.clipboard.enabled)
    }

    func testControllerReturnsFromAutomaticFilesToAllButPreservesExplicitFiles() throws {
        _ = NSApplication.shared
        let controller = SearchViewController(snapshot: true)
        try controller.prepareLauncherSnapshot(SearchSnapshot(raw: "", scope: .all))
        controller.searchField.text = "kind:doc"
        controller.startSearch()
        XCTAssertEqual(controller.scopes.scope, .files)
        XCTAssertEqual(controller.results.snapshot?.scope, .files)

        controller.searchField.text = "150*20%"
        controller.startSearch()
        XCTAssertEqual(controller.scopes.scope, .all)
        let calculated = expectation(for: NSPredicate { _, _ in
            guard let found = controller.results.snapshot else { return false }
            return found.raw == "150*20%" && found.scope == .all && found.leading.contains {
                if case .answer(let answer) = $0 { return answer.value == "30" }
                return false
            }
        }, evaluatedWith: controller)
        wait(for: [calculated], timeout: 3)
        XCTAssertEqual(controller.results.snapshot?.row(at: 0)?.identity, "answer:150*20%")

        controller.searchField.text = "kind:doc"
        controller.selectScope(.files)
        controller.searchField.text = "150*20%"
        controller.startSearch()
        XCTAssertEqual(controller.scopes.scope, .files)
        XCTAssertEqual(controller.results.snapshot?.scope, .files)
        XCTAssertEqual(controller.results.snapshot?.raw, "150*20%")
        XCTAssertEqual(controller.results.snapshot?.count, 0)
        controller.stopSources()
    }

    func testControllerScopeSwitchesReplaceResultsWithoutLeakingOtherSources() throws {
        _ = NSApplication.shared
        let controller = SearchViewController(snapshot: true)
        let app = LauncherApp(name: "Keyboard Notes", path: "/Users/demo/Keyboard Notes.app")
        let entry = ClipboardEntry(text: "Keyboard meeting notes")
        controller.applications.prepareSnapshot([app])
        controller.clipboard.prepareSnapshot([entry], enabled: true)
        try controller.prepareLauncherSnapshot(SearchSnapshot(raw: "keyboard", scope: .apps, leading: [.app(app)]), clipboardEntries: [entry])
        for scope in [SearchScope.settings, .clipboard, .apps, .files] {
            controller.selectScope(scope)
            let ready = expectation(for: NSPredicate { _, _ in controller.results.snapshot?.scope == scope }, evaluatedWith: controller)
            wait(for: [ready], timeout: 3)
            let found = try XCTUnwrap(controller.results.snapshot)
            XCTAssertEqual(controller.scopes.scope, scope)
            XCTAssertEqual(found.raw, "keyboard")
            switch scope {
            case .settings:
                XCTAssertTrue(identities(found).contains("setting:keyboard"))
                XCTAssertTrue(identities(found).allSatisfy { $0.hasPrefix("setting:") })
            case .clipboard: XCTAssertEqual(identities(found), ["clip:" + entry.id.uuidString])
            case .apps: XCTAssertEqual(identities(found), ["file:" + app.path])
            case .files: XCTAssertEqual(found.count, 0)
            case .all: XCTFail("Unexpected scope")
            }
        }
        controller.stopSources()
    }

    func testFileTypeShortcutWorksOnFirstPressFromHiddenAllScopeFilter() throws {
        _ = NSApplication.shared
        let controller = SearchViewController(snapshot: true)
        try controller.prepareLauncherSnapshot(SearchSnapshot(raw: "notes", scope: .all))
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.filters.isHidden)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .option], timestamp: 0, windowNumber: 0, context: nil,
            characters: "4", charactersIgnoringModifiers: "4", isARepeat: false, keyCode: 21))
        XCTAssertTrue(controller.handleKey(event))
        XCTAssertEqual(controller.scopes.scope, .files)
        XCTAssertEqual(controller.filters.options.kind, 3)
        XCTAssertEqual(controller.results.snapshot?.scope, .files)
        controller.stopSources()
    }

    func testStaleFileRowsCannotStartADrag() throws {
        _ = NSApplication.shared
        let controller = SearchViewController(snapshot: true)
        let files = result(store(["old.txt"]), raw: "old")
        try controller.prepareLauncherSnapshot(SearchSnapshot(raw: "old", scope: .files, fileResult: files))
        let table = try XCTUnwrap(controller.results.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSTableView)
        XCTAssertNotNil(controller.results.tableView(table, pasteboardWriterForRow: 0))
        controller.searchField.text = "new"
        XCTAssertNil(controller.results.tableView(table, pasteboardWriterForRow: 0))
        controller.searchField.text = "old"
        controller.scopes.scope = .apps
        XCTAssertNil(controller.results.tableView(table, pasteboardWriterForRow: 0))
    }

    func testLauncherRowMenusExposeOnlyApplicableActionsWithoutExecutingThem() throws {
        _ = NSApplication.shared
        let controller = SearchViewController(snapshot: true)
        let entry = ClipboardEntry(text: "Synthetic clipboard note")
        let setting = SystemSetting(id: "synthetic-setting", englishName: "Settings", chineseName: "设置", symbol: "gear",
                                    url: URL(string: "https://example.com/settings")!)
        let rows: [LauncherRow] = [.app(LauncherApp(name: "Synthetic", path: "/Users/demo/Synthetic.app")), .setting(setting),
                                  .answer(ToolAnswer(expression: "5/2", value: "2.5", detail: "5/2 = 2.5")),
                                  .url(URL(string: "https://example.com")!), .web("notes", WebSearchEngine.bing.url(for: "notes")),
                                  .clipboard(entry), .enableClipboard]
        for row in rows {
            try controller.prepareLauncherSnapshot(SearchSnapshot(raw: "notes", scope: .all, leading: [row]), clipboardEntries: [entry])
            let menu = try XCTUnwrap(controller.results.onContextMenu?(0))
            let expected: [Int]
            switch row {
            case .clipboard: expected = [0, 4, 2, 7]
            case .enableClipboard: expected = [0]
            default: expected = [0, 4]
            }
            XCTAssertEqual(menu.items.map(\.tag), expected)
            XCTAssertTrue(menu.items.allSatisfy { $0.target === controller && $0.action != nil })
            XCTAssertFalse(menu.items.contains { $0.tag == 1 || $0.tag == 5 })
        }
    }

    func testSnapshotClipboardAndPasteNeverConsultSystemAdapters() {
        let pasteboard = CountingPasteboard()
        let history = ClipboardHistory(snapshot: true, pasteboard: pasteboard)
        let entry = ClipboardEntry(text: "Synthetic clipboard note")
        history.prepareSnapshot([entry], enabled: true, needsAccess: true)
        history.start(); history.pollOnce(); history.requestAccess()
        var copyOutcome: ClipboardCopyOutcome?
        history.copy(entry) { copyOutcome = $0 }
        XCTAssertEqual(copyOutcome, .failed)
        XCTAssertEqual(history.entries, [entry])
        XCTAssertTrue(history.needsAccess)
        XCTAssertEqual(pasteboard.calls, 0)
        let adapter = CountingPasteAdapter()
        let controller = ClipboardPasteController(snapshot: true, adapter: adapter)
        controller.captureTarget()
        var outcome: PasteOutcome?
        controller.pasteCurrentClipboard(hidePanel: { $0() }, completion: { outcome = $0 })
        XCTAssertEqual(outcome, .copiedOnly)
        XCTAssertEqual(adapter.calls, 0)
    }

    func testFileClipboardResultsSupportClipboardActionsAndNeverExposeFileDeletion() throws {
        _ = NSApplication.shared
        let controller = SearchViewController(snapshot: true)
        let entry = ClipboardEntry(content: .files(["/Users/demo/Documents/Report.pdf", "/Users/demo/Documents/Assets"]))
        try controller.prepareLauncherSnapshot(SearchSnapshot(raw: "", scope: .clipboard, leading: [.clipboard(entry)]), clipboardEntries: [entry])
        let menu = try XCTUnwrap(controller.results.onContextMenu?(0))
        XCTAssertEqual(menu.items.map(\.tag), [0, 4, 2, 1, 8, 7])
        XCTAssertNil(controller.results.selectedItem)
        XCTAssertTrue(menu.items.contains { $0.tag == 7 && $0.title == L10n.text("clipboard.delete") })
        XCTAssertFalse(menu.items.contains { $0.title == L10n.text("ctx.trash") })
    }

    func testNewQueryCancelsQueuedOldFileAndSourceRequests() {
        let fileQueue = DispatchQueue(label: "LauncherSearchTests.queued-files")
        let sourceQueue = DispatchQueue(label: "LauncherSearchTests.queued-sources")
        fileQueue.suspend(); sourceQueue.suspend()
        let coordinator = SearchCoordinator(fileQueue: fileQueue, sourceQueue: sourceQueue)
        let files = store(["old.txt", "new.txt"])
        let apps = ["old", "new"].map { LauncherApp(name: $0, path: "/Applications/" + $0 + ".app") }
        var updates: [SearchSnapshot] = []
        coordinator.onUpdate = { snapshot, _ in updates.append(snapshot) }
        search(coordinator, raw: "old", store: files, apps: apps, web: true)
        search(coordinator, raw: "new", store: files, apps: apps, web: true)
        fileQueue.resume(); sourceQueue.resume()
        drain([fileQueue, sourceQueue])
        XCTAssertEqual(updates.count, 2)
        XCTAssertTrue(updates.allSatisfy { $0.raw == "new" })
        XCTAssertEqual(Set(identities(updates.last!)), ["file:/Applications/new.app", "file:" + files.rootPath + "/new.txt", "web:new"])
        XCTAssertFalse(updates.flatMap(identities).contains { $0.contains("old") })
    }

    func testNewQueryCancelsOldCompletionsAlreadyEnqueuedOnMainThread() {
        let fileQueue = DispatchQueue(label: "LauncherSearchTests.completed-files")
        let sourceQueue = DispatchQueue(label: "LauncherSearchTests.completed-sources")
        let coordinator = SearchCoordinator(fileQueue: fileQueue, sourceQueue: sourceQueue)
        let files = store(["old.txt", "new.txt"])
        var updates: [SearchSnapshot] = []
        coordinator.onUpdate = { snapshot, _ in updates.append(snapshot) }
        search(coordinator, raw: "old", store: files, web: true)
        // Workers finish without running the main loop: old publications are queued.
        fileQueue.sync {}; sourceQueue.sync {}
        search(coordinator, raw: "new", store: files, web: true)
        drain([fileQueue, sourceQueue])
        XCTAssertEqual(updates.count, 2)
        XCTAssertTrue(updates.allSatisfy { $0.raw == "new" })
        XCTAssertTrue(identities(updates.last!).contains("file:" + files.rootPath + "/new.txt"))
    }

    func testRemovingFileStorePublishesAndInvalidatesBlockedFileRequest() {
        let fileQueue = DispatchQueue(label: "LauncherSearchTests.removed-files")
        let sourceQueue = DispatchQueue(label: "LauncherSearchTests.remaining-sources")
        fileQueue.suspend()
        let coordinator = SearchCoordinator(fileQueue: fileQueue, sourceQueue: sourceQueue)
        var updates: [SearchSnapshot] = []
        coordinator.onUpdate = { snapshot, _ in updates.append(snapshot) }
        let app = LauncherApp(name: "needle", path: "/Applications/Needle.app")
        search(coordinator, raw: "needle", store: store(["needle.txt"]), apps: [app])
        drain([sourceQueue])
        XCTAssertEqual(updates.last?.filesPending, true)
        coordinator.refreshFiles(store: nil)
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates.last?.filesPending, false)
        XCTAssertNil(updates.last?.fileResult)
        XCTAssertEqual(updates.last?.row(at: 0)?.identity, "file:" + app.path)
        fileQueue.resume()
        drain([fileQueue])
        XCTAssertEqual(updates.count, 2)
    }

    func testReplacingFileRequestWithinSameQueryKeepsOnlyLatestStore() {
        let fileQueue = DispatchQueue(label: "LauncherSearchTests.replaced-files")
        let sourceQueue = DispatchQueue(label: "LauncherSearchTests.replaced-sources")
        fileQueue.suspend()
        let coordinator = SearchCoordinator(fileQueue: fileQueue, sourceQueue: sourceQueue)
        let old = store(["needle-old.txt"]), new = store(["needle-new.txt"])
        var updates: [SearchSnapshot] = []
        coordinator.onUpdate = { snapshot, _ in updates.append(snapshot) }
        search(coordinator, raw: "needle", store: old)
        drain([sourceQueue])
        coordinator.refreshFiles(store: new)
        fileQueue.resume()
        drain([fileQueue])
        XCTAssertEqual(updates.count, 2)
        XCTAssertTrue(updates.last?.fileResult?.store === new)
        XCTAssertEqual(identities(updates.last!), ["file:" + new.rootPath + "/needle-new.txt"])
    }

    func testRefreshingSourcesInvalidatesOldSourceRequestWithoutBlockingFiles() {
        let fileQueue = DispatchQueue(label: "LauncherSearchTests.source-refresh-files")
        let sourceQueue = DispatchQueue(label: "LauncherSearchTests.source-refresh")
        sourceQueue.suspend()
        let coordinator = SearchCoordinator(fileQueue: fileQueue, sourceQueue: sourceQueue)
        let old = LauncherApp(name: "needle old", path: "/Applications/Old.app")
        let new = LauncherApp(name: "needle new", path: "/Applications/New.app")
        var updates: [SearchSnapshot] = []
        coordinator.onUpdate = { snapshot, _ in updates.append(snapshot) }
        search(coordinator, raw: "needle", store: store(["needle.txt"]), apps: [old])
        drain([fileQueue])
        coordinator.refreshSources(apps: [new], clipboard: [], clipboardEnabled: false, calculator: false, web: false, engine: .bing)
        sourceQueue.resume()
        drain([sourceQueue])
        XCTAssertEqual(updates.count, 2)
        XCTAssertFalse(updates.flatMap(identities).contains("file:" + old.path))
        XCTAssertTrue(identities(updates.last!).contains("file:" + new.path))
    }

    func testClipboardScopeFiltersWordsAndRequiresOptInWithoutLeakingOtherSources() {
        let sourceQueue = DispatchQueue(label: "LauncherSearchTests.clipboard")
        let coordinator = SearchCoordinator(sourceQueue: sourceQueue)
        let match = ClipboardEntry(text: "Meeting notes for Friday")
        let other = ClipboardEntry(text: "Friday shopping")
        var updates: [SearchSnapshot] = []
        coordinator.onUpdate = { snapshot, _ in updates.append(snapshot) }
        search(coordinator, raw: "meeting Friday", scope: .clipboard, clipboard: [match, other], clipboardEnabled: true, web: true)
        drain([sourceQueue])
        XCTAssertEqual(identities(updates.last!), ["clip:" + match.id.uuidString])
        search(coordinator, raw: "", scope: .clipboard, clipboard: [match], clipboardEnabled: false, web: true)
        drain([sourceQueue])
        XCTAssertEqual(identities(updates.last!), ["enableClipboard"])
        XCTAssertNil(updates.last?.fileResult)
    }

    func testCalculatorWebAndCompositionUseRealCoordinatorSourcePipeline() {
        let sourceQueue = DispatchQueue(label: "LauncherSearchTests.tools")
        let coordinator = SearchCoordinator(sourceQueue: sourceQueue)
        var updates: [SearchSnapshot] = []
        coordinator.onUpdate = { snapshot, _ in updates.append(snapshot) }
        search(coordinator, raw: "150*20%", calculator: true, web: true)
        drain([sourceQueue])
        XCTAssertEqual(identities(updates.last!), ["answer:150*20%", "web:150*20%"])
        XCTAssertEqual(updates.last?.row(at: 0)?.title, "30")
        search(coordinator, raw: "web: 猫 & dogs", web: true)
        drain([sourceQueue])
        XCTAssertEqual(identities(updates.last!), ["web:猫 & dogs"])
        search(coordinator, raw: "150*20%", composing: true, calculator: true, web: true)
        drain([sourceQueue])
        XCTAssertEqual(updates.last?.count, 0)
    }

    #if DEBUG
    func testLauncherSnapshotFixturesAreSyntheticAndHaveExpectedScopes() throws {
        let unified = try Snapshot.launcherFixture(state: "unified", query: "display")
        XCTAssertEqual(unified.snapshot.scope, .all)
        XCTAssertNil(unified.snapshot.fileResult)
        XCTAssertTrue(identities(unified.snapshot).contains("file:/Users/demo/Applications/Display Studio.app"))
        XCTAssertTrue(identities(unified.snapshot).contains("setting:displays"))
        XCTAssertTrue(identities(unified.snapshot).contains("file:/Users/demo/Documents/Display review.pdf"))
        let clipboard = try Snapshot.launcherFixture(state: "clipboard")
        XCTAssertEqual(clipboard.snapshot.scope, .clipboard)
        XCTAssertEqual(clipboard.clipboard.count, 3)
        XCTAssertEqual(clipboard.snapshot.count, 3)
        let files = try Snapshot.launcherFixture(state: "clipboard-files", query: "Timeline")
        XCTAssertEqual(files.snapshot.scope, .clipboard)
        XCTAssertEqual(files.snapshot.count, 1)
        XCTAssertEqual(files.clipboard.count, 6)
        XCTAssertTrue(files.snapshot.row(at: 0)?.title.contains("Timeline.xlsx") == true)
        let controller = SearchViewController(snapshot: true)
        try controller.prepareLauncherSnapshot(files.snapshot, clipboardEntries: files.clipboard)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(controller.results.rowCount, 1)
        XCTAssertEqual(controller.results.snapshot?.scope, .clipboard)
        XCTAssertTrue(controller.results.selectedLauncherRow?.title.contains("Timeline.xlsx") == true)
        let settings = try Snapshot.launcherFixture(state: "system-settings", query: "keyboard")
        XCTAssertEqual(settings.snapshot.scope, .settings)
        XCTAssertTrue(identities(settings.snapshot).contains("setting:keyboard"))
        let calculator = try Snapshot.launcherFixture(state: "calculator")
        XCTAssertEqual(calculator.snapshot.row(at: 0)?.title, "30")
        XCTAssertThrowsError(try Snapshot.launcherFixture(state: "calculator", query: "report.pdf"))
        XCTAssertThrowsError(try Snapshot.launcherFixture(state: "unsupported"))
    }
    #endif
}

private final class CountingPasteboard: ClipboardPasteboardReading {
    var calls = 0
    var changeCount: Int { calls += 1; return 0 }
    var canReadWithoutPrompt: Bool { calls += 1; return true }
    func readText() -> String? { calls += 1; return "Must not be read" }
    func writeText(_ text: String) -> Bool { calls += 1; return true }
    func requestAccess() { calls += 1 }
}

private final class CountingPasteAdapter: ClipboardPasteAdapting {
    var calls = 0
    var hasPermission: Bool { calls += 1; return true }
    func captureTarget() -> ClipboardPasteTarget? { calls += 1; return ClipboardPasteTarget(processIdentifier: 12345) }
    func isRunning(_ target: ClipboardPasteTarget) -> Bool { calls += 1; return true }
    func activate(_ target: ClipboardPasteTarget, completion: @escaping (Bool) -> Void) { calls += 1; completion(true) }
    func hasFocus(_ target: ClipboardPasteTarget) -> Bool { calls += 1; return true }
    func sendCommandV(to target: ClipboardPasteTarget) -> Bool { calls += 1; return true }
}
