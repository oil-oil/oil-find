import XCTest
import Foundation
import Darwin
@testable import OilFindCore

final class M21CoreTests: XCTestCase {
    private func synthetic(_ names: [String], root: String = "/catalog", offset: Int = 0) -> IndexStore {
        var buffer = ScanBuffer()
        for (position, name) in names.enumerated() {
            let i = position + offset
            Array(name.utf8).withUnsafeBufferPointer {
                buffer.append(id: UInt32(position + 1), parent: 0, size: UInt32(i % 5), mtime: UInt32(i % 7), flags: SiftFlag.userArea, depth: 2, kind: 3, name: $0)
            }
        }
        return IndexStore(scan: ScanOutput(buffers: [buffer], count: names.count + 1, homeIndex: 0, elapsed: 0, finishedAt: 0), config: IndexConfig(rootPath: root))
    }
    private func eventually(_ seconds: Double = 8, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < deadline
        return predicate()
    }
    func testSourceExplainsOnlyItsOwnRootUsingItsIndexScope() {
        let root = "/Volumes/Archive", excluded = root + "/skip"
        let store = synthetic(["readme.md"], root: root)
        store.write { store.buildHash() }
        let config = IndexConfig(rootPath: root, userExcludedPaths: [excluded])
        let source = SearchSource(id: "archive", displayName: "Archive", isOnline: true, store: store,
                                  explainPath: { Coverage.explain(path: $0, config: config, store: store) })
        XCTAssertEqual(source.explain(path: root + "/readme.md"), .indexed)
        XCTAssertEqual(source.explain(path: excluded + "/readme.md"), .userExcluded(excluded))
        XCTAssertEqual(source.explain(path: root + "/node_modules/readme.md"), .scope(.dependency))
        XCTAssertEqual(source.explain(path: root + "/App.app/Contents/Info.plist"), .scope(.packages))
        XCTAssertEqual(source.explain(path: root), .indexed)
        let plainSource = SearchSource(id: "plain", displayName: "Archive", isOnline: true, store: store)
        XCTAssertEqual(plainSource.explain(path: root + "/readme.md"), .indexed)
        XCTAssertNil(plainSource.explain(path: root + "/missing.md"))
        XCTAssertNil(source.explain(path: root + " 1/readme.md"))
        XCTAssertNil(source.explain(path: "/Volumes/Other/readme.md"))
        XCTAssertEqual(Coverage.explain(path: root + "/skip/readme.md", config: .standard(), store: nil), .volume)
    }
    func testUncoveredVolumesExcludeIndexedRootsBeforeSampleLimit() {
        let mounts = (0..<10).map { "/Volumes/Disk\($0)" }
        var stats = CoverageStats()
        stats.refreshVolumes(mountPaths: ["/", "/System/Volumes/Data"] + mounts,
                             excluding: [mounts[0], mounts[6], mounts[9], mounts[1] + "/folder"])
        XCTAssertEqual(stats[.volumes].count, 7)
        XCTAssertEqual(stats[.volumes].examples, Array(mounts[1...5]))
        stats.refreshVolumes(mountPaths: mounts, excluding: Set(mounts))
        XCTAssertEqual(stats[.volumes], CoverageBucket())
        stats.refreshVolumes(mountPaths: mounts, excluding: [])
        XCTAssertEqual(stats[.volumes].count, 10)
    }
    func testMergeMatchesCombinedIndexAndDeterministicTies() throws {
        let groups = [["readme.md", "Readme.md", "readme2.md"], ["readme.md", "readme4.md", "readme0.md"], ["readme7.md", "readme.md"]]
        var offset = 0
        let sources = groups.enumerated().map { position, names -> SearchSource in
            defer { offset += names.count }
            return SearchSource(id: String(position), displayName: String(position), isOnline: position == 0, store: synthetic(names, offset: offset))
        }
        let combined = synthetic(groups.flatMap { $0 })
        for sort in [SortKey.relevance, .name, .size, .modified] {
            for ascending in [false, true] {
                let options = SearchOptions(sort: sort, ascending: ascending)
                let result = try XCTUnwrap(MultiSearcher.search(Query.parse("readme"), options: options, in: sources))
                let baseline = try XCTUnwrap(Searcher.search(Query.parse("readme"), options: options, in: combined))
                let globalIDs = result.items.map { hit -> UInt32 in UInt32(groups.prefix(hit.sourceIndex).reduce(0) { $0 + $1.count }) + hit.entryID }
                XCTAssertEqual(globalIDs, baseline.items)
                XCTAssertEqual(result.total, 8)
            }
        }
        let recent = try XCTUnwrap(MultiSearcher.search(Query.parse(""), in: sources))
        let recentBaseline = try XCTUnwrap(Searcher.search(Query.parse(""), in: combined))
        XCTAssertEqual(recent.items.map { sources[$0.sourceIndex].store.mtime[Int($0.entryID)] }, recentBaseline.items.map { combined.mtime[Int($0)] })
    }
    func testNarrowingCachingSourceReorderAndCancellation() throws {
        let a = SearchSource(id: "a", displayName: "a", isOnline: true, store: synthetic(["readme", "reader", "other"]))
        let b = SearchSource(id: "b", displayName: "b", isOnline: false, store: synthetic(["readme2", "reappear"]))
        let caches = ["a": SearchCache(), "b": SearchCache()]
        let first = try XCTUnwrap(MultiSearcher.search(Query.parse("re"), in: [a, b], caches: caches))
        let narrowed = try XCTUnwrap(MultiSearcher.search(Query.parse("readme"), in: [b, a], previous: first, caches: caches))
        XCTAssertTrue(narrowed.results.allSatisfy(\.isNarrowed)); XCTAssertEqual(narrowed.total, 2)
        let cached = try XCTUnwrap(MultiSearcher.search(Query.parse("readme"), in: [a, b], caches: caches))
        XCTAssertTrue(cached.results[0] === narrowed.results[1])
        XCTAssertNil(MultiSearcher.search(Query.parse("readme"), in: [a, b], isCancelled: { true }))
        let single = try XCTUnwrap(MultiSearcher.search(Query.parse("readme"), in: [a]))
        XCTAssertEqual(single.items.map(\.entryID), Searcher.search(Query.parse("readme"), in: a.store)?.items)
    }
    func testLargeResultNarrowingRetainsUnsortedTail() throws {
        let source = SearchSource(id: "large", displayName: "large", isOnline: false, store: synthetic((0..<200_010).map { "a-\($0).md" }))
        let first = try XCTUnwrap(MultiSearcher.search(Query.parse("a"), in: [source]))
        XCTAssertEqual(first.total, 200_010); XCTAssertEqual(first.items.count, first.total); XCTAssertEqual(first.sortedCount, 5000)
        let narrow = try XCTUnwrap(MultiSearcher.search(Query.parse("a-200009"), in: [source], previous: first))
        XCTAssertTrue(narrow.results[0].isNarrowed); XCTAssertEqual(narrow.total, 1)
    }
    func testStableVolumeFingerprintAndOfflineLoad() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let old = IndexConfig(rootPath: "/Volumes/A", userExcludedPaths: ["/Volumes/A/skip"])
        let new = IndexConfig(rootPath: "/Volumes/B 1", userExcludedPaths: ["/Volumes/B 1/skip"])
        XCTAssertEqual(old.fingerprint(volumeUUID: "uuid"), new.fingerprint(volumeUUID: "uuid"))
        XCTAssertNotEqual(old.fingerprint(volumeUUID: "uuid"), new.fingerprint(volumeUUID: "other"))
        let store = synthetic(["offline.txt"], root: old.rootPath)
        store.configFingerprint = old.fingerprint(volumeUUID: "uuid")
        let db = base.appendingPathComponent("index.oilfind"); try store.save(to: db.path)
        let manager = IndexManager(config: new, dbURL: db, volumeUUID: "uuid")
        manager.startOffline(); defer { manager.stop() }
        XCTAssertTrue(eventually { manager.state == .ready })
        let loaded = try XCTUnwrap(manager.store)
        XCTAssertEqual(Searcher.search(Query.parse("offline"), in: loaded)?.total, 1)
        XCTAssertEqual(loaded.path(1), "/Volumes/B 1/offline.txt")
        XCTAssertFalse(loaded.hashReady)
    }

    func testRecentMergeKeepsGlobalTwoHundredLimitAndEmptySources() throws {
        let groups = [(0..<300).map { "item-\($0)" }, (300..<600).map { "item-\($0)" }]
        let sources = groups.enumerated().map { SearchSource(id: String($0.offset), displayName: "source", isOnline: true, store: synthetic($0.element, offset: $0.offset * 300)) }
        let result = try XCTUnwrap(MultiSearcher.search(Query.parse(""), in: sources))
        let combined = synthetic(groups.flatMap { $0 })
        let expected = try XCTUnwrap(Searcher.search(Query.parse(""), in: combined))
        XCTAssertEqual(result.total, 200); XCTAssertEqual(result.sortedCount, 200)
        XCTAssertEqual(result.items.map { UInt32($0.sourceIndex * 300) + $0.entryID }, expected.items)
        XCTAssertEqual(MultiSearcher.search(Query.parse("item"), in: [])?.total, 0)
    }
    func testReusedMountWithWrongUUIDNeverScansOrReplacesCatalog() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let config = IndexConfig(rootPath: base.path), db = base.appendingPathComponent("index.oilfind")
        let saved = synthetic(["retained.txt"], root: base.path)
        saved.configFingerprint = config.fingerprint(volumeUUID: "incorrect-volume")
        try saved.save(to: db.path)
        let manager = IndexManager(config: config, dbURL: db, volumeUUID: "incorrect-volume")
        var loaded = false
        manager.onStateChange = { if $0 == .loading { loaded = true } }
        manager.onScannerCreated = { _ in XCTFail("A reused mount belongs to another volume") }
        manager.start(); defer { manager.stop() }
        XCTAssertTrue(eventually { loaded && manager.state == .idle })
        XCTAssertNil(manager.store)
        XCTAssertEqual(IndexStore.load(from: db.path)?.name(1), "retained.txt")
    }
    func testLoadedCursorMayExceedFlushedDeviceJournal() throws {
        try skipIfCI("Checks the host APFS journal and unflushed event cursor.")
        let root = "/System/Volumes/Data"
        let uuid = try XCTUnwrap(try URL(fileURLWithPath: root).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        var status = stat(); XCTAssertEqual(stat(root, &status), 0)
        let journal = try XCTUnwrap(FSWatcher.uuid(forDevice: status.st_dev))
        let config = IndexConfig(rootPath: root), saved = synthetic(["catalog-entry.txt"], root: root)
        saved.configFingerprint = config.fingerprint(volumeUUID: uuid); saved.fsEventsUUID = journal
        saved.lastEventId = FSWatcher.currentEventId(); saved.scanFinishedAt = UInt64(Date().timeIntervalSince1970)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let db = base.appendingPathComponent("index.oilfind"); try saved.save(to: db.path)
        let manager = IndexManager(config: config, dbURL: db, volumeUUID: uuid)
        var scanned = false; manager.onStateChange = { if $0 == .scanning { scanned = true } }
        manager.start(); defer { manager.stop() }
        XCTAssertTrue(eventually { manager.state == .ready }); XCTAssertFalse(scanned)
        print("M21 accepted live cursor=\(saved.lastEventId) persistedDeviceCursor=\(FSWatcher.currentEventId(forDevice: status.st_dev))")
    }

    func testDeviceRelativeStartupJournalReplay() throws {
        try skipIfCI("Requires the host APFS journal and event delivery.")
        var status = stat()
        XCTAssertEqual(stat("/System/Volumes/Data", &status), 0)
        _ = try XCTUnwrap(FSWatcher.uuid(forDevice: status.st_dev))
        let cursor = FSWatcher.currentEventId(forDevice: status.st_dev)
        XCTAssertGreaterThan(cursor, 0)
        let base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/OilFindM21Replay-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let filename = "journal-" + UUID().uuidString + ".txt"
        try Data([65]).write(to: base.appendingPathComponent(filename))
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let lock = NSLock(), queue = DispatchQueue(label: "M21.replay")
        var found = false
        let watcher = FSWatcher(paths: ["/System/Volumes/Data"], sinceWhen: cursor, device: status.st_dev, queue: queue) { changes, _ in
            if changes.contains(where: { $0.path.hasSuffix("/" + filename) || $0.path.hasSuffix("/" + base.lastPathComponent) }) { lock.lock(); found = true; lock.unlock() }
        }
        XCTAssertTrue(watcher.start()); defer { watcher.stop() }
        XCTAssertTrue(eventually { lock.lock(); defer { lock.unlock() }; return found })
        XCTAssertGreaterThan(watcher.replayedEventCount, 0)
        print("M21 device-relative APFS replay=\(watcher.replayedEventCount) cursor=\(cursor) latest=\(watcher.latestEventId)")
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process(), out = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = out; process.standardError = error
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "M21Image", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: errorData, as: UTF8.self)]) }
        return data
    }
    func testAPFSDeviceHistoryOfflineRemountAndEject() throws { try imageLifecycle("APFS") }
    func testExFATDeviceHistoryOfflineRemountAndEject() throws { try imageLifecycle("ExFAT") }
    private func imageLifecycle(_ filesystem: String) throws {
        try skipIfCI("Requires mounted hdiutil images and real FSEvents history.")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OilFindM21-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let image = base.appendingPathComponent("test.sparseimage"), db = base.appendingPathComponent("index.oilfind")
        var deviceNode: String?, manager: IndexManager?
        defer {
            manager?.stop()
            if let deviceNode { _ = try? run("/usr/bin/hdiutil", ["detach", deviceNode, "-force"]) }
            try? FileManager.default.removeItem(at: base)
        }
        _ = try run("/usr/bin/hdiutil", ["create", "-size", "32g", "-type", "SPARSE", "-fs", filesystem, "-volname", "OilFindM21", image.path])
        func attach(_ name: String) throws -> URL {
            let root = URL(fileURLWithPath: "/Volumes/OilFindM21-" + base.lastPathComponent + "-" + name)
            _ = try run("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-mountpoint", root.path])
            let info = try PropertyListSerialization.propertyList(from: run("/usr/sbin/diskutil", ["info", "-plist", root.path]), format: nil) as! [String: Any]
            deviceNode = try XCTUnwrap(info["DeviceNode"] as? String)
            return root
        }
        func detach() throws {
            guard let device = deviceNode else { return }
            _ = try run("/usr/bin/hdiutil", ["detach", device]); deviceNode = nil
        }
        func config(_ root: URL) -> IndexConfig { IndexConfig(rootPath: root.path, excludedNames: [".fseventsd", ".Spotlight-V100", ".Trashes"], indexDependencyDirs: true) }
        func write(_ root: URL, _ name: String) throws { try Data("sample".utf8).write(to: root.appendingPathComponent(name)) }
        let root = try attach("mountA")
        let info = try PropertyListSerialization.propertyList(from: run("/usr/sbin/diskutil", ["info", "-plist", root.path]), format: nil) as! [String: Any]
        let uuid = try XCTUnwrap(info["VolumeUUID"] as? String)
        try write(root, "before.txt")
        let first = IndexManager(config: config(root), dbURL: db, volumeUUID: uuid); manager = first
        let scannedRoot = DispatchSemaphore(value: 0), resumeScan = DispatchSemaphore(value: 0), buffered = DispatchSemaphore(value: 0)
        defer { resumeScan.signal() }
        first.onScannerCreated = { scanner in
            scanner.installDirectoryCompletionHook { relative in
                if relative.isEmpty { scannedRoot.signal(); _ = resumeScan.wait(timeout: .now() + 5) }
            }
        }
        first.onBufferedEvents = { changes in if changes.contains(where: { $0.path.hasSuffix("/scan-gap.txt") }) { buffered.signal() } }
        first.start()
        XCTAssertTrue(eventually { scannedRoot.wait(timeout: .now()) == .success })
        try write(root, "scan-gap.txt")
        if FSWatcher.uuid(forDevice: { var s = stat(); stat(root.path, &s); return s.st_dev }()) == nil {
            XCTAssertTrue(eventually { buffered.wait(timeout: .now()) == .success }, "Live events must be buffered before the no-history scan")
        }
        resumeScan.signal()
         XCTAssertTrue(eventually { first.state == .ready })
        XCTAssertEqual(Searcher.search(Query.parse("regex:^scan-gap[.]txt$"), in: try XCTUnwrap(first.store))?.total, 1)
        print("M21 first \(filesystem) count=\(first.store?.count ?? 0) journal=\(first.store?.fsEventsUUID ?? "nil") root=\(root.path)")
        try write(root, "live.txt")
        XCTAssertTrue(eventually { first.store.map { Searcher.search(Query.parse("regex:^live[.]txt$"), in: $0)?.total == 1 } ?? false })
        try FileManager.default.moveItem(at: root.appendingPathComponent("live.txt"), to: root.appendingPathComponent("renamed.txt"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("before.txt"))
        XCTAssertTrue(eventually { first.store.map { Searcher.search(Query.parse("regex:^renamed[.]txt$"), in: $0)?.total == 1 && Searcher.search(Query.parse("regex:^before[.]txt$"), in: $0)?.total == 0 } ?? false })
        first.stop(); manager = nil; try detach()
        let offline = IndexManager(config: config(root), dbURL: db, volumeUUID: uuid); manager = offline; offline.startOffline()
        XCTAssertTrue(eventually { offline.state == .ready }); XCTAssertEqual(Searcher.search(Query.parse("regex:^renamed[.]txt$"), in: try XCTUnwrap(offline.store))?.total, 1)
        offline.stop(); manager = nil
        let other = try attach("otherMac")
        try write(other, "offline-new.txt")
        _ = try run("/usr/sbin/diskutil", ["renameVolume", other.path, "Renamed"])
        RunLoop.current.run(until: Date().addingTimeInterval(1.5)); try detach()
        let remounted = try attach("mountB 1")
        let second = IndexManager(config: config(remounted), dbURL: db, volumeUUID: uuid); manager = second
        var scanned = false; second.onStateChange = { if $0 == .scanning { scanned = true } }
        let readingSubtree = DispatchSemaphore(value: 0)
        second.onUpdaterCreated = { updater in
            updater.onSubtreeDirectoryOpen = { [weak updater] path in
                guard let updater else { return }
                if path.suffix("/cancel-tree/child".utf8.count).elementsEqual("/cancel-tree/child".utf8) {
                    readingSubtree.signal()
                    while !updater.isCancelled { Thread.sleep(forTimeInterval: 0.001) }
                }
            }
        }
        second.start()
        XCTAssertTrue(eventually { second.state == .ready && second.store.map { Searcher.search(Query.parse("regex:^offline-new[.]txt$"), in: $0)?.total == 1 } ?? false })
        let loaded = try XCTUnwrap(second.store)
        XCTAssertEqual(loaded.rootPath, remounted.path)
        print("M21 \(filesystem): historyUUID=\(loaded.fsEventsUUID) cursor=\(loaded.lastEventId) replay=\(second.replayedEventCount) remountRescan=\(scanned)")
        if loaded.fsEventsUUID.isEmpty {
            XCTAssertTrue(scanned, "Missing historical journal requires a full scan")
        } else {
            XCTAssertFalse(scanned, "A retained volume journal should replay without a full scan")
            XCTAssertGreaterThan(second.replayedEventCount, 0)
        }
        let cancelTree = remounted.appendingPathComponent("cancel-tree/child")
        try FileManager.default.createDirectory(at: cancelTree, withIntermediateDirectories: true)
        try write(cancelTree, "child.txt")
        second.injectEvents([FSChange(path: remounted.appendingPathComponent("cancel-tree").path, flags: 1, eventId: loaded.lastEventId + 1)], mustRescanAll: false)
        XCTAssertTrue(eventually { readingSubtree.wait(timeout: .now()) == .success })
        let updateBegin = CFAbsoluteTimeGetCurrent(); second.stop(); manager = nil
        let stoppedUpdate = CFAbsoluteTimeGetCurrent() - updateBegin
        try detach(); let ejectedUpdate = CFAbsoluteTimeGetCurrent() - updateBegin
        print(String(format: "M21 %@: updateStop=%.3fs updateStop+eject=%.3fs", filesystem, stoppedUpdate, ejectedUpdate))
        XCTAssertLessThan(ejectedUpdate, 1)
        let finalMount = try attach("finalMount")
        for i in 0..<300 { try FileManager.default.createDirectory(at: finalMount.appendingPathComponent("dir-\(i)"), withIntermediateDirectories: true) }
        let third = IndexManager(config: config(finalMount), dbURL: base.appendingPathComponent("fresh.oilfind"), volumeUUID: uuid); manager = third
        let opened = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        third.onScannerCreated = { scanner in
            scanner.installDirectoryOpenHook { relative in
                if !relative.isEmpty { opened.signal(); _ = resume.wait(timeout: .now() + 3) }
            }
        }
        third.start()
        XCTAssertTrue(eventually { opened.wait(timeout: .now()) == .success })
        XCTAssertEqual(third.state, .scanning); XCTAssertGreaterThan(third.scannedCount, 0)
        defer { for _ in 0..<ProcessInfo.processInfo.activeProcessorCount { resume.signal() } }
        let begin = CFAbsoluteTimeGetCurrent(); third.stop(); let stopped = CFAbsoluteTimeGetCurrent() - begin
        try detach(); let ejected = CFAbsoluteTimeGetCurrent() - begin
        print(String(format: "M21 %@: stop=%.3fs stop+eject=%.3fs", filesystem, stopped, ejected))
        XCTAssertLessThan(stopped, 1); XCTAssertLessThan(ejected, 1)
    }
}
