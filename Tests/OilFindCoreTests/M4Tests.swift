import XCTest
import Carbon
import Darwin
@testable import OilFindCore

final class M4Tests: XCTestCase {
    func testT50ShortcutSymbols() {
        let modifiers = [controlKey, optionKey, shiftKey, cmdKey]
        let symbols = ["⌃", "⌥", "⇧", "⌘"]
        for combination in 0..<16 {
            var mask: UInt32 = 0, prefix = ""
            for bit in 0..<4 where combination & (1 << bit) != 0 {
                mask |= UInt32(modifiers[bit]); prefix += symbols[bit]
            }
            XCTAssertEqual(Shortcut.symbols(keyCode: UInt32(kVK_ANSI_F), modifiers: mask), prefix + "F")
        }
        XCTAssertEqual(Shortcut.symbols(keyCode: Shortcut.defaultKeyCode, modifiers: Shortcut.defaultModifiers), "⌘␣")
        XCTAssertEqual(Shortcut.symbols(keyCode: Shortcut.fallbackKeyCode, modifiers: Shortcut.fallbackModifiers), "⇧⌘F")
        for (code, name) in [(kVK_ANSI_A, "A"), (kVK_ANSI_Z, "Z"), (kVK_ANSI_0, "0"), (kVK_ANSI_9, "9"),
            (kVK_F1, "F1"), (kVK_F12, "F12"), (kVK_F20, "F20"), (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"),
            (kVK_UpArrow, "↑"), (kVK_DownArrow, "↓"), (kVK_Space, "␣"), (kVK_Return, "↩"), (kVK_ANSI_KeypadEnter, "⌤"),
            (kVK_Tab, "⇥"), (kVK_Delete, "⌫"), (kVK_ForwardDelete, "⌦"), (kVK_Escape, "⎋"),
            (kVK_Home, "↖"), (kVK_End, "↘"), (kVK_PageUp, "⇞"), (kVK_PageDown, "⇟"), (kVK_ANSI_KeypadClear, "⌧")] {
            XCTAssertEqual(Shortcut.symbols(keyCode: UInt32(code), modifiers: UInt32(cmdKey)), "⌘" + name)
        }
        XCTAssertEqual(Shortcut.keyEquivalent(UInt32(kVK_F1)), "\u{f704}")
        XCTAssertEqual(Shortcut.keyEquivalent(UInt32(kVK_Space)), " ")
        XCTAssertEqual(Shortcut.keyEquivalent(UInt32(kVK_Return)), "\r")
        XCTAssertEqual(Shortcut.keyEquivalent(UInt32(kVK_Home)), "\u{f729}")
        XCTAssertEqual(Shortcut.keyEquivalent(UInt32(kVK_ForwardDelete)), "\u{f728}")
    }

    func testT51ExcludedFolders() throws {
        XCTAssertTrue(ExcludedFolders.contains("/Users/me/Documents", path: "/Users/me/Documents/a/b"))
        XCTAssertTrue(ExcludedFolders.contains("/Users/me/Documents/", path: "/Users/me/Documents"))
        XCTAssertFalse(ExcludedFolders.contains("/Users/me/Documents", path: "/Users/me/Documents-old/a"))
        XCTAssertFalse(ExcludedFolders.contains("/Users/me/Documents/a", path: "/Users/me/Documents"))
        XCTAssertTrue(ExcludedFolders.contains("/", path: "/Users/me"))
        XCTAssertNil(ExcludedFolders.normalized("relative"))
        XCTAssertEqual(ExcludedFolders.normalized("/cafe\u{301}/"), "/café")
        let unicodeRule = IndexConfig(userExcludedPaths: ExcludedFolders.adding(["/cafe\u{301}"], to: []))
        Array("/café/leaf".utf8).withUnsafeBufferPointer { XCTAssertTrue(unicodeRule.isExcluded(path: $0)) }
        XCTAssertEqual(ExcludedFolders.adding(["/a/", "/a/b", "/a", "/abc", "relative", "/a/../c"], to: []), ["/a", "/abc", "/c"])
        XCTAssertEqual(ExcludedFolders.adding(["/a", "/a/d"], to: ["/a/b", "/a/c", "/other"]), ["/other", "/a"])
        XCTAssertEqual(ExcludedFolders.adding(["/"], to: ["/a", "/b"]), ["/"])
        Array("/Users/me/file".utf8).withUnsafeBufferPointer {
            XCTAssertTrue(IndexConfig(userExcludedPaths: ["/"]).isExcluded(path: $0))
        }
        let suite = "OilFindM4-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        SettingsPreferences.register(in: defaults)
        XCTAssertEqual(defaults.integer(forKey: "hotKeyCode"), 49)
        XCTAssertEqual(defaults.integer(forKey: "hotKeyModifiers"), Int(cmdKey))
        XCTAssertTrue(SettingsPreferences.searchOptions(in: defaults).pinyin)
        XCTAssertEqual(SettingsPreferences.searchOptions(in: defaults).sort, .relevance)
        XCTAssertFalse(defaults.bool(forKey: "sortAscending"))
        XCTAssertFalse(defaults.bool(forKey: "skippedFullDiskAccess"))
        defaults.set(false, forKey: "pinyinEnabled")
        defaults.set("name", forKey: "sortKey"); defaults.set(true, forKey: "sortAscending")
        defaults.set(["/a", "/a/sub"], forKey: "userExcludedPaths")
        XCTAssertFalse(SettingsPreferences.searchOptions(in: defaults).pinyin)
        XCTAssertEqual(SettingsPreferences.searchOptions(in: defaults).sort, .name)
        XCTAssertTrue(SettingsPreferences.searchOptions(in: defaults).ascending)
        XCTAssertEqual(SettingsPreferences.indexConfig(limited: true, in: defaults).userExcludedPaths, ["/a"])
        XCTAssertTrue(SettingsPreferences.indexConfig(limited: true, in: defaults).limitedMode)
    }

    func testLauncherPreferenceDefaultsAndPersistedChoices() throws {
        let suite = "OilFindLauncherPreferences-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        SettingsPreferences.register(in: defaults)
        XCTAssertTrue(defaults.bool(forKey: "calculatorEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "webSearchEnabled"))
        XCTAssertEqual(defaults.string(forKey: "webSearchEngine"), "duckDuckGo")

        defaults.set(12, forKey: "hotKeyCode")
        defaults.set(Int(controlKey | optionKey), forKey: "hotKeyModifiers")
        defaults.set(false, forKey: "calculatorEnabled")
        defaults.set(false, forKey: "webSearchEnabled")
        defaults.set("google", forKey: "webSearchEngine")
        SettingsPreferences.register(in: defaults)
        XCTAssertEqual(defaults.integer(forKey: "hotKeyCode"), 12)
        XCTAssertEqual(defaults.integer(forKey: "hotKeyModifiers"), Int(controlKey | optionKey))
        XCTAssertFalse(defaults.bool(forKey: "calculatorEnabled"))
        XCTAssertFalse(defaults.bool(forKey: "webSearchEnabled"))
        XCTAssertEqual(defaults.string(forKey: "webSearchEngine"), "google")

        defaults.set(Int(Shortcut.oldShiftCmdF.keyCode), forKey: "hotKeyCode")
        defaults.set(Int(Shortcut.oldShiftCmdF.modifiers), forKey: "hotKeyModifiers")
        SettingsPreferences.register(in: defaults)
        XCTAssertEqual(defaults.integer(forKey: "hotKeyCode"), Int(Shortcut.oldShiftCmdF.keyCode))
        XCTAssertEqual(defaults.integer(forKey: "hotKeyModifiers"), Int(Shortcut.oldShiftCmdF.modifiers))
    }

    func testT52UpdateConfig() throws {
        try skipIfCI("Live index rebuild timing is covered locally.")
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("OilFindM4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let pointer = try XCTUnwrap(realpath(raw.path, nil)); defer { free(pointer) }
        let base = URL(fileURLWithPath: String(cString: pointer))
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("tree"), db = base.appendingPathComponent("index.oilfind")
        for directory in ["a", "b", "c", "bulk"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
            try Data("sample".utf8).write(to: root.appendingPathComponent(directory + "/leaf.txt"))
        }
        for i in 0..<3_000 { try Data().write(to: root.appendingPathComponent("bulk/file-\(i).txt")) }
        let original = IndexConfig(rootPath: root.path, indexSystemDirs: true)
        let manager = IndexManager(config: original, dbURL: db)
        manager.start(); defer { manager.stop() }
        XCTAssertTrue(eventually { manager.state == .ready && !manager.isRescanning })
        let first = try XCTUnwrap(manager.store)
        manager.updateConfig(original)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(manager.store === first); XCTAssertFalse(manager.isRescanning)

        var configA = original; configA.userExcludedPaths = [root.path + "/a"]
        manager.updateConfig(configA)
        XCTAssertTrue(eventually { manager.isRescanning })
        XCTAssertTrue(manager.store === first)
        XCTAssertNotNil(Searcher.search(Query.parse("leaf"), in: first))
        XCTAssertTrue(eventually { !manager.isRescanning && manager.store?.configFingerprint == configA.fingerprint })
        let second = try XCTUnwrap(manager.store)
        XCTAssertNil(second.read { second.resolve(path: root.path + "/a") })
        manager.saveNow()
        XCTAssertEqual(IndexStore.load(from: db.path)?.configFingerprint, configA.fingerprint)

        manager.rescan()
        XCTAssertTrue(eventually { manager.isRescanning })
        var configB = original; configB.userExcludedPaths = [root.path + "/b"]
        var configC = original; configC.userExcludedPaths = [root.path + "/c"]
        manager.updateConfig(configB); manager.updateConfig(configC)
        XCTAssertTrue(eventually { !manager.isRescanning && manager.store?.configFingerprint == configC.fingerprint })
        let final = try XCTUnwrap(manager.store)
        final.read {
            XCTAssertNotNil(final.resolve(path: root.path + "/a/leaf.txt"))
            XCTAssertNotNil(final.resolve(path: root.path + "/b/leaf.txt"))
            XCTAssertNil(final.resolve(path: root.path + "/c"))
        }
        manager.saveNow()
        XCTAssertEqual(IndexStore.load(from: db.path)?.configFingerprint, configC.fingerprint)
        // The replacement updater accepts a formerly excluded path and rejects the latest exclusion.
        try Data().write(to: root.appendingPathComponent("c/hidden.txt"))
        try Data().write(to: root.appendingPathComponent("a/visible.txt"))
        XCTAssertTrue(eventually { manager.store.map { s in s.read { s.resolve(path: root.path + "/a/visible.txt") != nil } } ?? false })
        let live = try XCTUnwrap(manager.store)
        XCTAssertNil(live.read { live.resolve(path: root.path + "/c/hidden.txt") })
        var excludeRoot = original; excludeRoot.userExcludedPaths = ["/"]
        manager.updateConfig(excludeRoot)
        XCTAssertTrue(eventually { !manager.isRescanning && manager.store?.configFingerprint == excludeRoot.fingerprint })
        let onlyRoot = try XCTUnwrap(manager.store)
        XCTAssertEqual(onlyRoot.read { onlyRoot.liveCount }, 1)
    }
    private func eventually(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(8)
        repeat {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.002))
        } while Date() < deadline
        return predicate()
    }
}
