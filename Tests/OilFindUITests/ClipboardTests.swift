import AppKit
import CryptoKit
import Security
import XCTest
@testable import OilFind

final class ClipboardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testMissingKeyLookupRestoresLegacyInteractionStateWithoutCreatingAnItem() {
        var before: DarwinBoolean = false
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&before), errSecSuccess)
        let keys = ClipboardKeychain(service: "OilFindMissingKeyTest-\(UUID().uuidString)")
        XCTAssertThrowsError(try keys.key(createIfMissing: false))
        var after: DarwinBoolean = false
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&after), errSecSuccess)
        XCTAssertEqual(before.boolValue, after.boolValue)
    }

    private func defaults() -> UserDefaults {
        let name = "OilFindClipboardTests-\(UUID().uuidString)"
        let result = UserDefaults(suiteName: name)!
        addTeardownBlock { result.removePersistentDomain(forName: name) }
        return result
    }

    private func entry(_ text: String, age: TimeInterval = 0, app: String? = nil) -> ClipboardEntry {
        ClipboardEntry(text: text, copiedAt: now.addingTimeInterval(-age), sourceBundleID: app, sourceName: "Example")
    }

    private func eventually(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func copy(_ history: ClipboardHistory, _ entry: ClipboardEntry) -> Bool {
        var outcome: ClipboardCopyOutcome?
        history.copy(entry) { outcome = $0 }
        eventually { outcome != nil }
        return outcome == .copied
    }

    func testDefaultsAndPruningByAgeAndCount() {
        let values = [entry("old", age: 8 * 86_400), entry("boundary", age: 7 * 86_400),
                      entry("middle", age: 2), entry("latest")]
        let defaults = ClipboardHistoryStore(now: now)
        XCTAssertEqual(defaults.retentionDays, 7)
        XCTAssertEqual(defaults.maxItems, 500)
        let limited = ClipboardHistoryStore(entries: values, maxItems: 2, now: now)
        XCTAssertEqual(limited.entries.map(\.text), ["latest", "middle"])
        let all = ClipboardHistoryStore(entries: values, now: now)
        XCTAssertEqual(all.entries.map(\.text), ["latest", "middle", "boundary"])
    }

    func testLatestExactCopyWinsAndUnicodeBytesStayDistinct() {
        var store = ClipboardHistoryStore(now: now)
        let older = entry("same", age: 10)
        let latest = ClipboardEntry(text: "same", copiedAt: now, sourceBundleID: "org.example.editor", sourceName: "New Editor")
        XCTAssertNotEqual(older.id, latest.id)
        XCTAssertTrue(store.record(older, now: now))
        XCTAssertTrue(store.record(latest, now: now))
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.id, older.id)
        XCTAssertEqual(store.entries.first?.copiedAt, latest.copiedAt)
        XCTAssertEqual(store.entries.first?.sourceBundleID, latest.sourceBundleID)
        XCTAssertEqual(store.entries.first?.sourceName, latest.sourceName)
        XCTAssertTrue(store.record(entry("\u{00E9}"), now: now))
        XCTAssertTrue(store.record(entry("e\u{0301}"), now: now))
        XCTAssertEqual(store.entries.count, 3)
        XCTAssertNotEqual(Data(store.entries[0].text.utf8), Data(store.entries[1].text.utf8))
    }

    func testExclusionsNormalizeMatchHelpersAndRemoveExistingEntries() {
        var store = ClipboardHistoryStore(entries: [entry("normal", app: "org.example")], now: now)
        XCTAssertFalse(store.record(entry("password", app: "COM.1PASSWORD.1PASSWORD"), now: now))
        XCTAssertFalse(store.record(entry("secret", app: "com.bitwarden.desktop.helper"), now: now))
        XCTAssertFalse(store.record(entry("keychain", app: "com.apple.keychainaccess"), now: now))
        XCTAssertTrue(store.record(entry("allowed", app: "com.bitwarden.desktopish"), now: now))
        store.configure(days: 0, items: 50_000, exclusions: [" ORG.EXAMPLE ", "org.example", ""], now: now)
        XCTAssertEqual(store.retentionDays, 1)
        XCTAssertEqual(store.maxItems, 10_000)
        XCTAssertEqual(store.excludedAppIDs, ["org.example"])
        XCTAssertEqual(store.entries.map(\.text), ["allowed"])
    }

    func testRejectsEmptyOversizeAndFutureEntriesAndBoundsTotalBytes() {
        var store = ClipboardHistoryStore(maxItems: 10_000, now: now)
        XCTAssertFalse(store.record(entry(""), now: now))
        XCTAssertFalse(store.record(entry(String(repeating: "é", count: 131_073)), now: now))
        XCTAssertFalse(store.record(entry("future", age: -1), now: now))
        let values = (0..<140).map { index in
            entry(String(index) + String(repeating: "a", count: 256 * 1024 - 4), age: Double(index))
        }
        let bounded = ClipboardHistoryStore(entries: values, maxItems: 10_000, now: now)
        XCTAssertLessThan(bounded.entries.count, values.count)
        XCTAssertLessThanOrEqual(bounded.entries.reduce(0) { $0 + $1.text.utf8.count }, 32 * 1024 * 1024)
        XCTAssertEqual(bounded.entries.first?.text, values.first?.text)
    }

    func testSearchAndRemovalKeepNewestOrder() {
        var store = ClipboardHistoryStore(entries: [entry("Alpha", age: 1), entry("βeta")], now: now)
        XCTAssertEqual(store.search("ALP").map(\.text), ["Alpha"])
        XCTAssertEqual(store.search("example").count, 2)
        store.remove(store.entries[0].id)
        XCTAssertEqual(store.search("").map(\.text), ["Alpha"])
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testEncryptedStorageRoundTripAndAuthenticatedTamperDetection() throws {
        let io = MemoryArchive(), keys = FakeKeys()
        let storage = ClipboardEncryptedStorage(io: io, keys: keys)
        XCTAssertEqual(try storage.load(), [])
        XCTAssertTrue(keys.requests.isEmpty)
        let values = [entry("plain secret 🔐"), entry("second", age: 1)]
        try storage.save(values)
        let encrypted = try XCTUnwrap(io.data)
        XCTAssertNil(encrypted.range(of: Data("plain secret".utf8)))
        XCTAssertEqual(keys.requests, [true])
        XCTAssertEqual(try ClipboardEncryptedStorage(io: io, keys: keys).load(), values)
        XCTAssertEqual(keys.requests, [true, false])
        io.data![encrypted.count / 2] ^= 1
        let tampered = ClipboardEncryptedStorage(io: io, keys: keys)
        XCTAssertThrowsError(try tampered.load()) { XCTAssertEqual($0 as? ClipboardFailure, .corruptArchive) }
        let preserved = io.data
        XCTAssertThrowsError(try tampered.save([]))
        XCTAssertEqual(io.data, preserved)
        XCTAssertEqual(io.writes, 1)
    }

    func testMissingKeyAndUnreadableArchiveNeverCreateKeyOrOverwrite() throws {
        let io = MemoryArchive(), keys = FakeKeys()
        io.data = Data([1, 2, 3])
        keys.failure = ClipboardFailure.keyUnavailable
        let storage = ClipboardEncryptedStorage(io: io, keys: keys)
        XCTAssertThrowsError(try storage.load())
        XCTAssertEqual(keys.requests, [false])
        XCTAssertThrowsError(try storage.save([]))
        XCTAssertEqual(io.writes, 0)
        XCTAssertEqual(io.data, Data([1, 2, 3]))

        let unreadable = MemoryArchive(), untouchedKeys = FakeKeys()
        unreadable.readFailure = ClipboardFailure.storageUnavailable
        let inaccessible = ClipboardEncryptedStorage(io: unreadable, keys: untouchedKeys)
        XCTAssertThrowsError(try inaccessible.load())
        XCTAssertThrowsError(try inaccessible.save([]))
        XCTAssertTrue(untouchedKeys.requests.isEmpty)
        XCTAssertEqual(unreadable.writes, 0)
    }

    func testWrongKeyFailsAuthentication() throws {
        let io = MemoryArchive()
        try ClipboardEncryptedStorage(io: io, keys: FakeKeys()).save([entry("secret")])
        let wrong = FakeKeys(byte: 2)
        XCTAssertThrowsError(try ClipboardEncryptedStorage(io: io, keys: wrong).load()) {
            XCTAssertEqual($0 as? ClipboardFailure, .corruptArchive)
        }
        XCTAssertEqual(io.writes, 1)
    }

    func testAtomicFileRoundTripCreatesOnlyOneEncryptedFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OilFindClipboard-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.encrypted")
        let storage = ClipboardEncryptedStorage(io: ClipboardArchiveFile(url: file), keys: FakeKeys())
        XCTAssertEqual(try storage.load(), [])
        try storage.save([entry("first")])
        try storage.save([entry("second")])
        XCTAssertEqual(try storage.load().map(\.text), ["second"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .map { $0.resolvingSymlinksInPath() }, [file.resolvingSymlinksInPath()])
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRuntimeNeverTouchesClipboardBeforeOptInOrWhilePaused() {
        let board = FakePasteboard(), storage = FakeStorage()
        let history = ClipboardHistory(defaults: defaults(), storage: storage, pasteboard: board, clock: { self.now }, source: { (nil, nil) })
        defer { history.stop() }
        history.start()
        history.pollOnce()
        XCTAssertEqual(board.accessChecks, 0)
        XCTAssertEqual(board.countReads, 0)
        XCTAssertEqual(board.textReads, 0)
        history.setEnabled(true)
        XCTAssertEqual(board.textReads, 0)
        board.text = "new"; board.count += 1
        history.pollOnce()
        XCTAssertEqual(history.entries.map(\.text), ["new"])
        history.setPaused(true)
        let checks = board.accessChecks, counts = board.countReads, reads = board.textReads
        board.count += 1
        history.pollOnce()
        XCTAssertEqual(board.accessChecks, checks)
        XCTAssertEqual(board.countReads, counts)
        XCTAssertEqual(board.textReads, reads)
        history.setPaused(false)
        history.pollOnce()
        XCTAssertEqual(board.textReads, reads)
    }

    func testAccessGateDoesNotReadAndReauthorizationUsesFreshBaseline() {
        let board = FakePasteboard()
        board.allowed = false
        let history = ClipboardHistory(defaults: defaults(), storage: FakeStorage(), pasteboard: board, clock: { self.now }, source: { (nil, nil) })
        defer { history.stop() }
        history.start(); history.setEnabled(true)
        XCTAssertEqual(board.accessRequests, 1)
        history.setEnabled(true)
        XCTAssertEqual(board.accessRequests, 1)
        for _ in 0..<4 { history.pollOnce() }
        XCTAssertTrue(history.needsAccess)
        XCTAssertEqual(board.countReads, 0)
        XCTAssertEqual(board.textReads, 0)
        board.allowed = true
        history.pollOnce()
        XCTAssertFalse(history.needsAccess)
        XCTAssertEqual(board.textReads, 0)
        board.count += 1
        history.pollOnce()
        XCTAssertEqual(board.textReads, 1)
    }

    func testStopFlushesPendingLoadAndDebouncedSaveBeforeReturning() {
        let storage = FakeStorage(), board = FakePasteboard()
        storage.restored = [entry("restored", age: 1)]
        let history = ClipboardHistory(defaults: defaults(), storage: storage, pasteboard: board,
                                       clock: { self.now }, source: { (nil, nil) }, saveDelay: 60)
        history.start()
        XCTAssertTrue(copy(history, entry("latest")))
        history.stop()
        XCTAssertEqual(storage.saves.count, 1)
        XCTAssertEqual(storage.saves[0].map(\.text), ["latest", "restored"])
        XCTAssertEqual(history.entries.map(\.text), ["latest", "restored"])
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        XCTAssertEqual(storage.saves.count, 1)
    }

    func testExcludedSourceIsCheckedBeforeClipboardRead() {
        let board = FakePasteboard()
        let history = ClipboardHistory(defaults: defaults(), storage: FakeStorage(), pasteboard: board,
            clock: { self.now }, source: { ("com.bitwarden.desktop", "Bitwarden") })
        defer { history.stop() }
        history.start(); history.setEnabled(true)
        board.count += 1
        history.pollOnce()
        XCTAssertEqual(board.textReads, 0)
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testChangedClipboardDuringReadIsDiscarded() {
        let board = FakePasteboard()
        board.onRead = { board.count += 1 }
        let history = ClipboardHistory(defaults: defaults(), storage: FakeStorage(), pasteboard: board, clock: { self.now }, source: { (nil, nil) })
        defer { history.stop() }
        history.start(); history.setEnabled(true)
        board.count += 1; history.pollOnce()
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testRuntimeClampsDirectPublishedAssignments() {
        let history = ClipboardHistory(snapshot: true, defaults: defaults(), storage: FakeStorage(), pasteboard: FakePasteboard(), clock: { self.now }, source: { (nil, nil) })
        history.retentionDays = 0
        history.maxItems = 20_000
        history.excludedAppIDs = [" A.B ", "a.b", ""]
        XCTAssertEqual(history.retentionDays, 1)
        XCTAssertEqual(history.maxItems, 10_000)
        XCTAssertEqual(history.excludedAppIDs, ["a.b"])
    }

    func testSnapshotHasNoServiceOrPreferenceSideEffects() {
        let preferences = defaults(), board = FakePasteboard(), storage = FakeStorage()
        let history = ClipboardHistory(snapshot: true, defaults: preferences, storage: storage,
                                       pasteboard: board, clock: { self.now }, source: { (nil, nil) })
        history.start(); history.setEnabled(true); history.setPaused(true)
        history.setRetention(days: 4, items: 20)
        history.prepareSnapshot([entry("demo")]); history.pollOnce()
        XCTAssertEqual(history.entries.map(\.text), ["demo"])
        XCTAssertFalse(copy(history, entry("demo")))
        history.clear(); history.stop()
        XCTAssertEqual(board.accessChecks + board.countReads + board.textReads + board.writes + board.accessRequests, 0)
        XCTAssertEqual(storage.loads + storage.saves.count, 0)
        XCTAssertNil(preferences.object(forKey: "clipboardHistoryEnabled"))
    }

    func testLoadFailureContinuesMemoryOnlyAndPreservesErrorAfterCopyAndClear() {
        let storage = FakeStorage(), board = FakePasteboard()
        storage.loadFailure = ClipboardFailure.corruptArchive
        let history = ClipboardHistory(defaults: defaults(), storage: storage, pasteboard: board,
                                       clock: { self.now }, source: { (nil, nil) }, saveDelay: 0)
        history.start()
        eventually { history.error != nil }
        XCTAssertTrue(copy(history, entry("in memory")))
        XCTAssertEqual(history.entries.map(\.text), ["in memory"])
        XCTAssertEqual(history.error, ClipboardFailure.corruptArchive.localizedDescription)
        history.clear(); history.stop()
        XCTAssertEqual(history.error, ClipboardFailure.corruptArchive.localizedDescription)
        XCTAssertTrue(storage.saves.isEmpty)
    }

    func testClearBeforeAsyncLoadCannotResurrectEntriesAndSavesAreDebounced() {
        let storage = FakeStorage()
        storage.restored = [entry("restored")]
        let history = ClipboardHistory(defaults: defaults(), storage: storage, pasteboard: FakePasteboard(),
                                       clock: { self.now }, source: { (nil, nil) }, saveDelay: 0.04)
        history.start(); history.clear()
        XCTAssertTrue(copy(history, entry("one")))
        XCTAssertTrue(copy(history, entry("two")))
        eventually { !storage.saves.isEmpty }
        XCTAssertEqual(history.entries.map(\.text), ["two", "one"])
        XCTAssertEqual(storage.saves.count, 1)
        XCTAssertEqual(storage.saves[0].map(\.text), ["two", "one"])
        history.stop()
    }

    func testRemoveBeforeLoadAndWriteFailureAreVisible() {
        let storage = FakeStorage()
        let removed = entry("remove")
        storage.restored = [removed, entry("retain", age: 1)]
        storage.saveFailure = ClipboardFailure.storageUnavailable
        let history = ClipboardHistory(defaults: defaults(), storage: storage, pasteboard: FakePasteboard(),
                                       clock: { self.now }, source: { (nil, nil) }, saveDelay: 0)
        history.start(); history.remove(removed.id)
        eventually { history.error != nil }
        XCTAssertEqual(history.entries.map(\.text), ["retain"])
        XCTAssertEqual(history.error, ClipboardFailure.storageUnavailable.localizedDescription)
        history.stop()
    }

    func testExplicitStorageRetryMergesFileHistoryAndMemoryEntriesWithoutOverwritingFailedStorage() {
        let failed = FakeStorage(), recovered = FakeStorage(), board = FakePasteboard()
        failed.loadFailure = ClipboardFailure.keychainUnavailable
        recovered.loadFailure = ClipboardFailure.keychainUnavailable
        recovered.restored = [ClipboardEntry(content: .files(["/tmp/old-file.pdf"]), copiedAt: now.addingTimeInterval(-1))]
        let preferences = defaults()
        preferences.set(true, forKey: "clipboardHistoryEnabled")
        var recoveryRequests = 0
        let history = ClipboardHistory(defaults: preferences, storage: failed, pasteboard: board,
            clock: { self.now }, source: { (nil, nil) }, saveDelay: 0,
            recoveryStorage: { recoveryRequests += 1; return recovered })
        defer { history.stop() }
        history.requestPersistenceAccess()
        XCTAssertEqual(recoveryRequests, 0)
        history.start()
        eventually { history.error != nil }
        board.text = "new memory entry"; board.count += 1
        history.pollOnce()
        XCTAssertEqual(history.entries.map(\.text), ["new memory entry"])
        XCTAssertTrue(failed.saves.isEmpty)
        history.requestPersistenceAccess()
        XCTAssertTrue(history.requestingPersistenceAccess)
        history.requestPersistenceAccess()
        XCTAssertEqual(recoveryRequests, 1)
        eventually { !history.requestingPersistenceAccess }
        XCTAssertNotNil(history.error)
        XCTAssertEqual(history.entries.map(\.text), ["new memory entry"])
        XCTAssertTrue(recovered.saves.isEmpty)
        recovered.loadFailure = nil
        history.requestPersistenceAccess()
        history.requestPersistenceAccess()
        XCTAssertEqual(recoveryRequests, 2)
        eventually { !recovered.saves.isEmpty }
        XCTAssertFalse(history.requestingPersistenceAccess)
        XCTAssertNil(history.error)
        XCTAssertEqual(history.entries.map(\.text), ["new memory entry", "/tmp/old-file.pdf"])
        XCTAssertEqual(recovered.saves.last, history.entries)
        XCTAssertTrue(failed.saves.isEmpty)
    }

    func testCopyFailureDoesNotChangeHistory() {
        let board = FakePasteboard()
        board.writeResult = false
        let history = ClipboardHistory(defaults: defaults(), storage: FakeStorage(), pasteboard: board, clock: { self.now }, source: { (nil, nil) })
        XCTAssertFalse(copy(history, entry("text")))
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertEqual(history.error, ClipboardFailure.copyFailed.localizedDescription)
    }

    func testFileGroupsDeduplicateByExactPathsAndStayDistinctFromText() {
        let paths = ["/tmp/设计 notes.pdf", "/tmp/资料"]
        let first = ClipboardEntry(content: .files(paths), copiedAt: now.addingTimeInterval(-10))
        let again = ClipboardEntry(content: .files(Array(paths.reversed())), copiedAt: now, sourceName: "Finder")
        var store = ClipboardHistoryStore(now: now)
        XCTAssertTrue(store.record(first, now: now))
        XCTAssertTrue(store.record(again, now: now))
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.id, first.id)
        XCTAssertEqual(store.entries.first?.filePaths, Array(paths.reversed()))
        XCTAssertEqual(store.entries.first?.sourceName, "Finder")
        XCTAssertTrue(store.record(ClipboardEntry(text: again.text, copiedAt: now), now: now))
        XCTAssertEqual(store.entries.count, 2)
        let onePath = ClipboardEntry(content: .files(["/tmp/a\n/tmp/b"]), copiedAt: now)
        let twoPaths = ClipboardEntry(content: .files(["/tmp/a", "/tmp/b"]), copiedAt: now)
        XCTAssertEqual(onePath.text, twoPaths.text)
        XCTAssertTrue(store.record(onePath, now: now)); XCTAssertTrue(store.record(twoPaths, now: now))
        XCTAssertEqual(store.entries.count, 4)
        XCTAssertTrue(store.record(ClipboardEntry(content: .files(["/tmp/é"]), copiedAt: now), now: now))
        XCTAssertTrue(store.record(ClipboardEntry(content: .files(["/tmp/e\u{0301}"]), copiedAt: now), now: now))
        XCTAssertEqual(store.entries.count, 6)
    }

    func testFilePathsAreBoundedAndShareRetentionCountAndExclusionPolicies() {
        for paths in [[], ["relative.txt"], ["/tmp/a\0b"], ["/tmp/a", "/tmp/a"],
                      (0...1_000).map { "/tmp/\($0)" }, ["/" + String(repeating: "a", count: 256 * 1024)]] {
            XCTAssertFalse(ClipboardHistoryStore.accepts(ClipboardEntry(content: .files(paths))))
        }
        let entry = ClipboardEntry(content: .files((0..<1_000).map { "/tmp/file-\($0)" }), copiedAt: now)
        XCTAssertTrue(ClipboardHistoryStore.accepts(entry))
        var store = ClipboardHistoryStore(entries: [entry], maxItems: 1, now: now)
        XCTAssertEqual(store.entries.count, 1)
        let old = ClipboardEntry(content: .files(["/tmp/old"]), copiedAt: now.addingTimeInterval(-2 * 86_400))
        XCTAssertFalse(store.record(ClipboardEntry(content: .files(["/tmp/secret"]), copiedAt: now,
                                                  sourceBundleID: "com.1password.1password"), now: now))
        store.configure(days: 1, items: 3, exclusions: [], now: now)
        XCTAssertFalse(store.record(old, now: now))
        let large = (0..<80).map { index in
            ClipboardEntry(content: .files(["/\(index)/" + String(repeating: "x", count: 256 * 1024 - 10)]),
                           copiedAt: now.addingTimeInterval(-Double(index)))
        }
        let bounded = ClipboardHistoryStore(entries: large, maxItems: 1_000, now: now)
        XCTAssertLessThan(bounded.entries.count, large.count)
        XCTAssertLessThanOrEqual(bounded.entries.reduce(0) { $0 + $1.storageBytes }, ClipboardHistoryStore.maximumTotalBytes)
    }

    func testOldEncryptedTextArchiveLoadsAndMixedHistorySurvivesRestart() throws {
        let io = MemoryArchive(), keys = FakeKeys()
        let old = entry("Text saved before file history existed")
        let encoded = try PropertyListEncoder().encode(old)
        var oldDictionary = try XCTUnwrap(PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any])
        oldDictionary.removeValue(forKey: "filePaths")
        let legacy = try PropertyListSerialization.data(fromPropertyList: ["version": 1, "entries": [oldDictionary]],
                                                        format: .binary, options: 0)
        io.data = try AES.GCM.seal(legacy, using: keys.value, authenticating: Data("OilFindClipboard.v1".utf8)).combined
        let storage = ClipboardEncryptedStorage(io: io, keys: keys)
        XCTAssertEqual(try storage.load(), [old])
        let files = ClipboardEntry(content: .files(["/tmp/Private report.pdf", "/tmp/Design assets"]), copiedAt: now)
        try storage.save([files, old])
        XCTAssertNil(try XCTUnwrap(io.data).range(of: Data("Private report".utf8)))
        XCTAssertEqual(try ClipboardEncryptedStorage(io: io, keys: keys).load(), [files, old])
    }

    func testFileClipboardHandlesLegacyPathsAndRejectsPromisesAndMixedItems() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let adapter = ClipboardSystemPasteboard(pasteboard: board)
        let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        board.clearContents()
        XCTAssertTrue(board.setPropertyList(["/tmp/a.pdf", "/tmp/b"], forType: filenames))
        XCTAssertEqual(adapter.readContent(), .files(["/tmp/a.pdf", "/tmp/b"]))
        func fileItem() -> NSPasteboardItem {
            let item = NSPasteboardItem()
            item.setString("file:///tmp/a.pdf", forType: .fileURL)
            item.setData(Data([1]), forType: NSPasteboard.PasteboardType("com.adobe.pdf"))
            return item
        }
        board.clearContents(); XCTAssertTrue(board.writeObjects([fileItem()]))
        XCTAssertEqual(adapter.readContent(), .files(["/tmp/a.pdf"]))
        let other = NSPasteboardItem(); other.setString("ordinary text", forType: .string)
        board.clearContents(); XCTAssertTrue(board.writeObjects([fileItem(), other]))
        XCTAssertNil(adapter.readContent())
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
                       "com.apple.pasteboard.promised-file-content-type", "com.apple.pasteboard.promised-file-url", ClipboardSystemPasteboard.ownCopyType.rawValue] {
            let marked = NSPasteboardItem()
            marked.setString("file:///tmp/secret.txt", forType: .fileURL)
            marked.setData(Data([1]), forType: NSPasteboard.PasteboardType(marker))
            board.clearContents(); XCTAssertTrue(board.writeObjects([fileItem(), marked]))
            XCTAssertNil(adapter.readContent(), marker)
        }
        for value in ["https://example.com/file", "file://remote-host/tmp/file", "file:///tmp/a?query=1", "invalid"] {
            board.clearContents(); XCTAssertTrue(board.setString(value, forType: .fileURL))
            XCTAssertNil(adapter.readContent(), value)
        }
    }

    func testRestoredFilesExposeNativeURLsAndDoNotCreateOwnCopyDuplicates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OilFindFileClipboard-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("设计 notes #1.txt")
        try Data("Synthetic file body".utf8).write(to: document)
        let folder = directory.appendingPathComponent("Assets", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let adapter = ClipboardSystemPasteboard(pasteboard: board)
        let preferences = defaults(); preferences.set(true, forKey: "clipboardHistoryEnabled")
        let history = ClipboardHistory(defaults: preferences, storage: FakeStorage(), pasteboard: adapter,
                                       clock: { self.now }, source: { ("com.apple.finder", "Finder") })
        defer { history.stop() }
        history.start()
        board.clearContents(); XCTAssertTrue(board.writeObjects([document as NSURL, folder as NSURL]))
        history.pollOnce()
        let captured = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(captured.filePaths, [document.path, folder.path])
        XCTAssertTrue(copy(history, captured))
        let urls = try XCTUnwrap(board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])
        XCTAssertEqual(urls.map(\.path), [document.path, folder.path])
        XCTAssertNil(adapter.readContent())
        history.pollOnce()
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries.first?.id, captured.id)
        history.remove(captured.id)
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: document.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testMissingFilePreventsPartialCopyAndPreservesCurrentPasteboard() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents(); board.setString("Keep current clipboard", forType: .string)
        let count = board.changeCount
        let history = ClipboardHistory(defaults: defaults(), storage: FakeStorage(), pasteboard: ClipboardSystemPasteboard(pasteboard: board))
        let entry = ClipboardEntry(content: .files([FileManager.default.temporaryDirectory.path, "/tmp/OilFind-Missing-\(UUID())"]))
        XCTAssertFalse(copy(history, entry))
        XCTAssertEqual(history.error, ClipboardFailure.missingFiles.localizedDescription)
        XCTAssertEqual(board.changeCount, count)
        XCTAssertEqual(board.string(forType: .string), "Keep current clipboard")
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testSlowFileValidationDoesNotBlockMainAndRechecksCurrentSelectionBeforeWriting() {
        let board = FakePasteboard(), began = expectation(description: "Background validation began")
        let release = DispatchSemaphore(value: 0)
        let history = ClipboardHistory(defaults: defaults(), storage: FakeStorage(), pasteboard: board,
                                       fileExists: { _ in
            XCTAssertFalse(Thread.isMainThread)
            began.fulfill(); release.wait(); return true
        })
        let files = ClipboardEntry(content: .files(["/tmp/slow-mount/file"]))
        var current = true, outcome: ClipboardCopyOutcome?
        history.copy(files, isCurrent: { current }) { outcome = $0 }
        wait(for: [began], timeout: 2)
        XCTAssertNil(outcome)
        XCTAssertEqual(board.writes, 0)
        current = false
        release.signal()
        eventually { outcome != nil }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(board.writes, 0)
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testFileValidationDeadlinePreservesClipboardAndIgnoresLateCompletion() {
        let board = FakePasteboard(), began = expectation(description: "Slow path entered")
        let release = DispatchSemaphore(value: 0)
        let history = ClipboardHistory(defaults: defaults(), storage: FakeStorage(), pasteboard: board,
                                       fileExists: { _ in began.fulfill(); release.wait(); return true }, validationTimeout: 0.05)
        var outcomes: [ClipboardCopyOutcome] = []
        history.copy(ClipboardEntry(content: .files(["/tmp/slow-mount/file"]))) { outcomes.append($0) }
        wait(for: [began], timeout: 2)
        eventually { !outcomes.isEmpty }
        XCTAssertEqual(outcomes, [.failed])
        XCTAssertEqual(history.error, ClipboardFailure.validationTimedOut.localizedDescription)
        XCTAssertEqual(board.writes, 0)
        release.signal()
        XCTAssertTrue(copy(history, entry("new text")))
        XCTAssertEqual(board.writes, 1)
        XCTAssertEqual(board.text, "new text")
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(outcomes, [.failed])
        XCTAssertEqual(board.writes, 1)
        XCTAssertEqual(board.text, "new text")
    }

    func testNewCopyAndRemovingHistoryCancelPendingFileWrites() {
        for remove in [false, true] {
            let board = FakePasteboard(), began = expectation(description: "File validation entered")
            let release = DispatchSemaphore(value: 0)
            let history = ClipboardHistory(defaults: defaults(), storage: FakeStorage(), pasteboard: board,
                                           fileExists: { _ in began.fulfill(); release.wait(); return true })
            let files = ClipboardEntry(content: .files(["/tmp/slow-mount/file"]))
            var outcomes: [ClipboardCopyOutcome] = []
            history.copy(files) { outcomes.append($0) }
            wait(for: [began], timeout: 2)
            if remove { history.remove(files.id) }
            else { XCTAssertTrue(copy(history, entry("new copy"))) }
            XCTAssertEqual(outcomes, [.cancelled])
            release.signal()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            XCTAssertEqual(outcomes, [.cancelled])
            XCTAssertEqual(board.writes, remove ? 0 : 1)
        }
    }

    func testControllerCancelsFileCopyWhenSelectionQueryOrPanelChanges() {
        _ = NSApplication.shared
        for change in ["selection", "query", "hide"] {
            let board = FakePasteboard(), began = expectation(description: "Controller validation began")
            let release = DispatchSemaphore(value: 0), finished = expectation(description: "Validator returned")
            let history = ClipboardHistory(defaults: defaults(), storage: FakeStorage(), pasteboard: board,
                                           fileExists: { _ in
                began.fulfill(); release.wait()
                DispatchQueue.main.async { finished.fulfill() }
                return true
            })
            let controller = SearchViewController(snapshot: false, clipboard: history)
            _ = controller.view
            let files = ClipboardEntry(content: .files(["/tmp/slow-mount/file"]))
            controller.scopes.scope = .clipboard
            controller.results.show(SearchSnapshot(raw: "", scope: .clipboard, leading: [.clipboard(files), .clipboard(entry("other"))]))
            controller.setState(nil)
            let commandC = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                          timestamp: 0, windowNumber: 0, context: nil,
                                          characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
            XCTAssertTrue(controller.handleKey(commandC))
            wait(for: [began], timeout: 2)
            switch change {
            case "selection": controller.results.select(1)
            case "query": controller.searchField.text = "changed while checking"
            default: controller.panelDidHide()
            }
            release.signal()
            wait(for: [finished], timeout: 2)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            XCTAssertEqual(board.writes, 0, change)
            XCTAssertTrue(history.entries.isEmpty, change)
        }
    }

    func testFileHistorySearchesNamesPathsAndSourceWithoutFileQuerySyntax() {
        let file = ClipboardEntry(content: .files(["/Users/demo/Documents/设计 notes.pdf", "/Users/demo/Desktop/ext:pdf.txt"]), copiedAt: now,
                                  sourceBundleID: "com.apple.finder", sourceName: "Finder")
        let store = ClipboardHistoryStore(entries: [file], now: now)
        for query in ["notes", "Documents", "设计 NOTES", "ext:pdf", "/Users/demo/Desktop", "Finder"] {
            XCTAssertEqual(store.search(query), [file], query)
        }
        XCTAssertTrue(store.search("missing").isEmpty)
        XCTAssertTrue(file.displayTitle.contains("设计 notes.pdf"))
        XCTAssertNotNil(file.locationSummary)
    }

    func testFinderFileCopiesAreRecordedAsGroupsAndTextMonitoringContinues() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let adapter = ClipboardSystemPasteboard(pasteboard: board)
        let preferences = defaults()
        preferences.set(true, forKey: "clipboardHistoryEnabled")
        let history = ClipboardHistory(defaults: preferences, storage: FakeStorage(), pasteboard: adapter,
                                       clock: { self.now }, source: { ("com.apple.finder", "Finder") })
        defer { history.stop() }
        history.start()
        let files = [URL(fileURLWithPath: "/tmp/OilFind-copy-test.txt") as NSURL,
                     URL(fileURLWithPath: "/tmp/OilFind-copy-folder", isDirectory: true) as NSURL]
        for copied in [[files[0]], files] {
            board.clearContents()
            XCTAssertTrue(board.writeObjects(copied))
            // Finder can include textual filenames alongside file URL representations.
            board.setString("OilFind-copy-test.txt", forType: .string)
            XCTAssertNil(adapter.readText())
            XCTAssertEqual(adapter.readContent(), .files(copied.map { $0.path! }))
            history.pollOnce()
            XCTAssertEqual(history.entries.first?.filePaths, copied.map { $0.path! })
        }
        XCTAssertEqual(history.entries.count, 2)
        board.clearContents()
        XCTAssertTrue(board.setString("Text copied after the files", forType: .string))
        history.pollOnce()
        XCTAssertEqual(history.entries.first?.text, "Text copied after the files")
        XCTAssertNil(history.entries.first?.filePaths)
        XCTAssertEqual(history.entries.count, 3)
        XCTAssertFalse(history.needsAccess)
    }

    func testIsolatedPasteboardFiltersSensitiveTypesAndOwnCopies() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let adapter = ClipboardSystemPasteboard(pasteboard: board)
        let rejected = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                        "org.nspasteboard.AutoGeneratedType", "public.file-url", "public.png",
                        "com.adobe.pdf"]
        for raw in rejected {
            let item = NSPasteboardItem()
            item.setString("secret", forType: .string)
            item.setData(Data([1]), forType: NSPasteboard.PasteboardType(raw))
            board.clearContents(); XCTAssertTrue(board.writeObjects([item]))
            XCTAssertNil(adapter.readText(), raw)
        }
        XCTAssertTrue(adapter.writeText("ordinary text"))
        XCTAssertNil(adapter.readText())
        board.clearContents(); XCTAssertTrue(board.setString("plain 🔐", forType: .string))
        XCTAssertEqual(adapter.readText(), "plain 🔐")
        let first = NSPasteboardItem(), second = NSPasteboardItem()
        first.setString("first", forType: .string); second.setString("second", forType: .string)
        board.clearContents(); XCTAssertTrue(board.writeObjects([first, second]))
        XCTAssertNil(adapter.readText())
    }

    func testPasteWaitsForHideThenActivationAndChecksBeforeSending() {
        let adapter = FakePasteAdapter()
        let paste = ClipboardPasteController(adapter: adapter)
        paste.captureTarget()
        var hidden: (() -> Void)?, outcomes: [PasteOutcome] = []
        paste.pasteCurrentClipboard(hidePanel: { adapter.log.append("hide"); hidden = $0 }, completion: { outcomes.append($0) })
        XCTAssertEqual(adapter.log, ["capture", "hide"])
        XCTAssertTrue(outcomes.isEmpty)
        hidden?()
        XCTAssertEqual(adapter.log, ["capture", "hide", "permission", "process", "activate"])
        XCTAssertTrue(outcomes.isEmpty)
        adapter.activation?(true)
        XCTAssertEqual(adapter.log, ["capture", "hide", "permission", "process", "activate",
                                     "permission", "process", "focus", "event"])
        XCTAssertEqual(outcomes, [.sent])
        hidden?(); adapter.activation?(true)
        XCTAssertEqual(outcomes, [.sent])
        XCTAssertEqual(adapter.log.filter { $0 == "event" }.count, 1)
    }

    func testPasteFallbackForMissingTargetPermissionProcessActivationFocusAndEvents() {
        for failure in ["target", "permission", "process", "activation", "focus", "event"] {
            let adapter = FakePasteAdapter()
            if failure == "target" { adapter.target = nil }
            if failure == "permission" { adapter.permission = false }
            if failure == "process" { adapter.running = false }
            if failure == "focus" { adapter.focused = false }
            if failure == "event" { adapter.eventResult = false }
            let paste = ClipboardPasteController(adapter: adapter)
            paste.captureTarget()
            var outcomes: [PasteOutcome] = []
            paste.pasteCurrentClipboard(hidePanel: { $0() }, completion: { outcomes.append($0) })
            adapter.activation?(failure != "activation")
            XCTAssertEqual(outcomes, [.copiedOnly], failure)
            if failure != "event" { XCTAssertFalse(adapter.log.contains("event"), failure) }
        }
    }

    func testPasteRechecksPermissionAndProcessAfterActivation() {
        for failure in ["permission", "process"] {
            let adapter = FakePasteAdapter()
            let controller = ClipboardPasteController(adapter: adapter)
            controller.captureTarget()
            var outcome: PasteOutcome?
            controller.pasteCurrentClipboard(hidePanel: { $0() }, completion: { outcome = $0 })
            if failure == "permission" { adapter.permission = false } else { adapter.running = false }
            adapter.activation?(true)
            XCTAssertEqual(outcome, .copiedOnly)
            XCTAssertFalse(adapter.log.contains("event"))
        }
    }

    func testPasteSnapshotDoesNotUseAdapter() {
        let adapter = FakePasteAdapter()
        let paste = ClipboardPasteController(snapshot: true, adapter: adapter)
        paste.captureTarget()
        var outcome: PasteOutcome?, didHide = false
        paste.pasteCurrentClipboard(hidePanel: { didHide = true; $0() }, completion: { outcome = $0 })
        XCTAssertTrue(didHide)
        XCTAssertEqual(outcome, .copiedOnly)
        XCTAssertTrue(adapter.log.isEmpty)
    }

    func testHeldHideCallbackTimesOutAndLateHideCannotActivateOrBlockNextPaste() {
        let adapter = FakePasteAdapter(), deadline = FakePasteDeadline()
        let paste = ClipboardPasteController(adapter: adapter, scheduleFailureDeadline: deadline.schedule)
        paste.captureTarget()
        var hidden: (() -> Void)?, outcomes: [PasteOutcome] = []
        paste.pasteCurrentClipboard(hidePanel: { hidden = $0 }, completion: { outcomes.append($0) })
        XCTAssertEqual(adapter.log, ["capture"])
        XCTAssertTrue(outcomes.isEmpty)
        deadline.callbacks[0]()
        XCTAssertEqual(outcomes, [.copiedOnly])
        XCTAssertEqual(deadline.cancellations, 1)
        hidden?()
        XCTAssertEqual(adapter.log, ["capture"])

        paste.captureTarget()
        var nextOutcome: PasteOutcome?
        paste.pasteCurrentClipboard(hidePanel: { $0() }, completion: { nextOutcome = $0 })
        XCTAssertNil(nextOutcome)
        hidden?(); deadline.callbacks[0]()
        XCTAssertEqual(outcomes, [.copiedOnly])
        adapter.activation?(true)
        XCTAssertEqual(nextOutcome, .sent)
        XCTAssertEqual(adapter.log.filter { $0 == "event" }.count, 1)
    }

    func testLateActivationAfterDeadlineCannotSendOrCheckFocus() {
        let adapter = FakePasteAdapter(), deadline = FakePasteDeadline()
        let paste = ClipboardPasteController(adapter: adapter, scheduleFailureDeadline: deadline.schedule)
        paste.captureTarget()
        var hidden: (() -> Void)?, outcomes: [PasteOutcome] = []
        paste.pasteCurrentClipboard(hidePanel: { hidden = $0; $0() }, completion: { outcomes.append($0) })
        XCTAssertEqual(adapter.log, ["capture", "permission", "process", "activate"])
        deadline.callbacks[0]()
        XCTAssertEqual(outcomes, [.copiedOnly])
        let finishedLog = adapter.log
        adapter.activation?(true); adapter.activation?(false); hidden?()
        XCTAssertEqual(adapter.log, finishedLog)
        XCTAssertFalse(adapter.log.contains("event"))
        XCTAssertEqual(outcomes, [.copiedOnly])
        XCTAssertEqual(deadline.cancellations, 1)
    }

    func testDeadlineAfterSuccessfulPasteCannotCompleteAgain() {
        let adapter = FakePasteAdapter(), deadline = FakePasteDeadline()
        let paste = ClipboardPasteController(adapter: adapter, scheduleFailureDeadline: deadline.schedule)
        paste.captureTarget()
        var outcomes: [PasteOutcome] = []
        paste.pasteCurrentClipboard(hidePanel: { $0() }, completion: { outcomes.append($0) })
        adapter.activation?(true)
        let finishedLog = adapter.log
        deadline.callbacks[0](); adapter.activation?(true)
        XCTAssertEqual(outcomes, [.sent])
        XCTAssertEqual(adapter.log, finishedLog)
        XCTAssertEqual(deadline.cancellations, 1)
    }
}

private final class FakePasteDeadline {
    var callbacks: [() -> Void] = []
    var cancellations = 0
    func schedule(_ failure: @escaping () -> Void) -> () -> Void {
        callbacks.append(failure)
        return { self.cancellations += 1 }
    }
}

private final class FakeKeys: ClipboardKeyProviding {
    let value: SymmetricKey
    var requests: [Bool] = []
    var failure: Error?
    init(byte: UInt8 = 1) { value = SymmetricKey(data: Data(repeating: byte, count: 32)) }
    func key(createIfMissing: Bool) throws -> SymmetricKey {
        requests.append(createIfMissing)
        if let failure { throw failure }
        return value
    }
}

private final class MemoryArchive: ClipboardArchiveIO {
    var data: Data?, readFailure: Error?
    var writes = 0
    func read() throws -> Data? { if let readFailure { throw readFailure }; return data }
    func writeAtomically(_ data: Data) throws { writes += 1; self.data = data }
}

private final class FakePasteboard: ClipboardPasteboardReading {
    var count = 1, allowed = true, text = "text", writeResult = true
    var countReads = 0, accessChecks = 0, textReads = 0, writes = 0, accessRequests = 0
    var onRead: (() -> Void)?
    var changeCount: Int { countReads += 1; return count }
    var canReadWithoutPrompt: Bool { accessChecks += 1; return allowed }
    func readText() -> String? { textReads += 1; onRead?(); return text }
    func requestAccess() { accessRequests += 1 }
    func writeText(_ text: String) -> Bool { writes += 1; if writeResult { self.text = text; count += 1 }; return writeResult }
}

private final class FakeStorage: ClipboardHistoryPersisting {
    private let lock = NSLock()
    private var loadCount = 0, saved: [[ClipboardEntry]] = []
    var restored: [ClipboardEntry] = []
    var loadFailure: Error?, saveFailure: Error?
    var loads: Int { lock.lock(); defer { lock.unlock() }; return loadCount }
    var saves: [[ClipboardEntry]] { lock.lock(); defer { lock.unlock() }; return saved }
    func load() throws -> [ClipboardEntry] {
        lock.lock(); defer { lock.unlock() }
        loadCount += 1
        if let loadFailure { throw loadFailure }
        return restored
    }
    func save(_ entries: [ClipboardEntry]) throws {
        lock.lock(); defer { lock.unlock() }
        if let saveFailure { throw saveFailure }
        saved.append(entries)
    }
}

private final class FakePasteAdapter: ClipboardPasteAdapting {
    var target: ClipboardPasteTarget? = ClipboardPasteTarget(processIdentifier: 123, bundleID: "org.example")
    var permission = true, running = true, focused = true, eventResult = true
    var log: [String] = []
    var activation: ((Bool) -> Void)?
    var hasPermission: Bool { log.append("permission"); return permission }
    func captureTarget() -> ClipboardPasteTarget? { log.append("capture"); return target }
    func isRunning(_ target: ClipboardPasteTarget) -> Bool { log.append("process"); return running }
    func activate(_ target: ClipboardPasteTarget, completion: @escaping (Bool) -> Void) { log.append("activate"); activation = completion }
    func hasFocus(_ target: ClipboardPasteTarget) -> Bool { log.append("focus"); return focused }
    func sendCommandV(to target: ClipboardPasteTarget) -> Bool { log.append("event"); return eventResult }
}
