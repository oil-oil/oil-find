import Foundation
import Combine
import AppKit
import Darwin
import XCTest
@testable import OilFind
@testable import OilFindCore

private struct PerformanceClipboardStorage: ClipboardHistoryPersisting {
    func load() throws -> [ClipboardEntry] { [] }
    func save(_ entries: [ClipboardEntry]) throws {}
}

final class LauncherPerformanceTests: XCTestCase {
    private let repetitions = 20
    private let targetFiles = 10_000_000
    private var databaseURL: URL {
        if let path = ProcessInfo.processInfo.environment["OILFIND_PERF_DB"], !path.isEmpty {
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        }
        return AppDelegate.dbURL
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["OILFIND_PERF"] == "1" else {
            throw XCTSkip("Opt-in benchmark: OILFIND_PERF=1 swift test -c release -Xswiftc -DDEBUG --filter LauncherPerformanceTests")
        }
    }

    private func milliseconds<T>(_ body: () throws -> T) rethrows -> (value: T, elapsed: Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try body()
        return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    private func number(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func report(_ label: String, samples: [Double], work: String) {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return }
        func percentile(_ fraction: Double) -> Double { sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)] }
        print("OILFIND_PERF \(label) repeats=\(samples.count) \(work) mean_ms=\(number(samples.reduce(0, +) / Double(samples.count))) p50_ms=\(number(percentile(0.5))) p95_ms=\(number(percentile(0.95))) min_ms=\(number(sorted[0])) max_ms=\(number(sorted[sorted.count - 1]))")
    }

    private func compareSearchAndComposition(in store: IndexStore, query: String, scale: String) throws {
        let options = SearchOptions()
        let parsed = Query.parse(query, store: store)
        let apps = (0..<8).map { LauncherApp(name: query + " App \($0)", path: "/Users/demo/Applications/Perf-\($0).app", aliases: [query]) }
        let settings = (0..<3).map {
            SystemSetting(id: "perf-setting-\($0)", englishName: query + " Settings \($0)", chineseName: query + " 设置 \($0)",
                          symbol: "gear", aliases: [query], url: URL(string: "https://example.com/settings/\($0)")!)
        }
        // Catalog matching and synthetic construction are measured separately.
        let extras = apps.map(LauncherRow.app) + settings.map(LauncherRow.setting)
        let web = LauncherRow.web(query, WebSearchEngine.duckDuckGo.url(for: query))
        var engine: [Double] = [], wall: [Double] = [], composition: [Double] = []
        var matched = 0, rows = 0
        for _ in 0..<repetitions {
            let measured = try milliseconds { try XCTUnwrap(Searcher.search(parsed, options: options, in: store)) }
            let files = measured.value
            engine.append(files.elapsedMs); wall.append(measured.elapsed)
            let combined = milliseconds {
                SearchCoordinator.compose(raw: query, scope: .all, fileResult: files, extras: extras, trailing: [web])
            }
            composition.append(combined.elapsed)
            matched = files.total; rows = combined.value.count
            XCTAssertTrue(combined.value.fileResult === files)
            XCTAssertLessThanOrEqual(combined.value.leading.count, 5)
            XCTAssertNotNil(combined.value.row(at: 0))
        }
        let size = store.read { (store.count, store.liveCount, store.allocatedBytes) }
        let scaleVerified = size.1 - 1 >= targetFiles
        let context = "scale=\(scale) query=\(String(reflecting: query)) indexed_entries=\(size.0) live_entries=\(size.1) matches=\(matched) rows=\(rows) apps=\(apps.count) settings=\(settings.count) allocated_bytes=\(size.2) target_files=\(targetFiles) target_scale_verified=\(scaleVerified)"
        report("file_result_elapsed", samples: engine, work: context)
        report("file_search_wall", samples: wall, work: context)
        report("unified_compose", samples: composition, work: context)
        if !scaleVerified {
            print("OILFIND_PERF scale_limit: this index is below 10 million files; these timings do not verify the 10-million-file target.")
        }
        let engineTotal = engine.reduce(0, +)
        if engineTotal > 0 {
            print("OILFIND_PERF compose_to_engine_ratio=\(number(composition.reduce(0, +) / engineTotal)) (compose excludes source discovery and matching)")
        }
    }

    func testReadOnlyLocalIndexSearchComparedWithUnifiedComposition() throws {
        let path = databaseURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            print("OILFIND_PERF local_index_unavailable path=\(path) target_scale_verified=false")
            throw XCTSkip("No benchmark index; set OILFIND_PERF_DB. The benchmark never creates or rewrites it.")
        }
        let loaded = try milliseconds { try XCTUnwrap(IndexStore.load(from: path), "Cannot read the existing index") }
        let store = loaded.value
        let hash = milliseconds { store.write { store.buildHash() } }
        print("OILFIND_PERF local_index path=\(path) load_ms=\(number(loaded.elapsed)) in_memory_build_hash_ms=\(number(hash.elapsed))")
        let query = ProcessInfo.processInfo.environment["OILFIND_PERF_QUERY"] ?? "readme"
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            XCTFail("OILFIND_PERF_QUERY must be nonempty"); return
        }
        try compareSearchAndComposition(in: store, query: query, scale: "local-read-only")
    }

    func testRealFileFirstCallbackWhileSourcesAreHeldForFiveHundredMilliseconds() throws {
        let path = databaseURL.path
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("No benchmark index at \(path)") }
        let store = try XCTUnwrap(IndexStore.load(from: path))
        store.write { store.buildHash() }
        let query = ProcessInfo.processInfo.environment["OILFIND_PERF_QUERY"] ?? "readme"
        let sourceQueue = DispatchQueue(label: "LauncherPerformanceTests.held-sources")
        sourceQueue.suspend()
        var released = false
        defer { if !released { sourceQueue.resume() } }
        let coordinator = SearchCoordinator(sourceQueue: sourceQueue)
        let completed = expectation(description: "File first publication with held sources")
        let merged = expectation(description: "Sources eventually merge after release")
        let start = DispatchTime.now().uptimeNanoseconds
        var firstMs: Double?, engineMs: Double?, holdMs: Double?
        coordinator.onUpdate = { snapshot, refresh in
            XCTAssertTrue(Thread.isMainThread)
            if !refresh {
                XCTAssertNotNil(snapshot.fileResult)
                XCTAssertFalse(snapshot.filesPending)
                XCTAssertFalse(released, "File publication must be independent of source release")
                firstMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                engineMs = snapshot.fileResult?.elapsedMs
                completed.fulfill()
                // Keep sources held for at least 500 ms, even on a slow file query.
                let remainingMs = max(0, 500 - (firstMs ?? 0))
                DispatchQueue.main.asyncAfter(deadline: .now() + remainingMs / 1000) {
                    holdMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                    released = true; sourceQueue.resume()
                }
            } else { merged.fulfill() }
        }
        coordinator.search(raw: query, scope: .all, options: .init(), store: store,
                           editingRange: nil, composing: false,
                           apps: [LauncherApp(name: query + " App", path: "/Users/demo/Perf.app")],
                           clipboard: [], clipboardEnabled: false, calculator: false, web: true, engine: .duckDuckGo)
        wait(for: [completed, merged], timeout: 30, enforceOrder: true)
        if let firstMs, let engineMs, let holdMs {
            print("OILFIND_PERF file_first_callback query=\(String(reflecting: query)) indexed_entries=\(store.count) callback_ms=\(number(firstMs)) engine_ms=\(number(engineMs)) source_hold_ms=\(number(holdMs)) callback_before_source_release=true callback_under_500ms=\(firstMs < 500) target_scale_verified=\(store.liveCount - 1 >= targetFiles)")
        }
        coordinator.onUpdate = nil
    }

    func testOriginalFilePipelineComparedWithUnifiedPublication() throws {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { throw XCTSkip("No benchmark index") }
        let store = try XCTUnwrap(IndexStore.load(from: databaseURL.path))
        store.write { store.buildHash() }
        let catalog = ApplicationCatalog(snapshot: false, defaults: UserDefaults(suiteName: "OilFindPerformance-\(UUID())")!)
        catalog.start()
        let ready = expectation(description: "Real application catalog loaded")
        let subscription = catalog.$revision.dropFirst().sink { _ in ready.fulfill() }
        wait(for: [ready], timeout: 30)
        defer { catalog.stop(); subscription.cancel() }
        let apps = catalog.apps
        for query in ["a", "readme", "file:readme", "显示器"] {
            var samples: [String: [Double]] = [:]
            // Independent caches are warmed once, then pipelines alternate order.
            // This baseline reproduces the unchanged queue/cache/search/main path
            // from a4f6854; it excludes NSView rendering in both implementations.
            let originalQueue = DispatchQueue(label: "OriginalFilePipeline", qos: .userInteractive)
            let cache = SearchCache(), options = SearchOptions()
            var previous: SearchResult?
            let coordinators: [String: SearchCoordinator] = ["files": SearchCoordinator(), "all": SearchCoordinator()]
            for iteration in 0...repetitions {
                let order = iteration % 2 == 0 ? ["original", "files", "all"] : ["all", "files", "original"]
                for pipeline in order {
                    let completed = expectation(description: "\(query) \(pipeline) \(iteration)")
                    let start = DispatchTime.now().uptimeNanoseconds
                    let accept: (SearchResult) -> Void = { result in
                        if iteration > 0 { samples[pipeline, default: []].append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
                        XCTAssertEqual(result.query.raw, query)
                        completed.fulfill()
                    }
                    if pipeline == "original" {
                        let parsed = Query.parse(query, store: store)
                        originalQueue.async {
                            let found = cache.lookup(query: parsed, options: options, store: store)
                                ?? Searcher.search(parsed, options: options, in: store, previous: previous)
                            guard let found else { return }
                            cache.insert(found); previous = found
                            DispatchQueue.main.async { accept(found) }
                        }
                    } else {
                        let coordinator = coordinators[pipeline]!
                        var delivered = false
                        coordinator.onUpdate = { found, _ in
                            guard !delivered, let files = found.fileResult else { return }
                            delivered = true; accept(files)
                        }
                        coordinator.search(raw: query, scope: pipeline == "files" ? .files : .all, options: options, store: store,
                                           editingRange: nil, composing: false, apps: apps, clipboard: [], clipboardEnabled: false,
                                           calculator: true, web: true, engine: .duckDuckGo)
                    }
                    wait(for: [completed], timeout: 10)
                }
            }
            for pipeline in ["original", "files", "all"] {
                report("publication_\(pipeline)", samples: samples[pipeline]!,
                       work: "query=\(String(reflecting: query)) indexed_entries=\(store.count) real_apps=\(apps.count) warm_cache=true includes_dispatch_and_main_publication=true excludes_rendering=true")
            }
            for coordinator in coordinators.values { coordinator.onUpdate = nil }
        }
    }

    func testFiveHundredClipboardEntriesThroughRealCoordinator() throws {
        let entries = (0..<500).map {
            ClipboardEntry(text: "benchmark needle entry \($0)", copiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                           sourceBundleID: "example.synthetic", sourceName: "Synthetic")
        }
        let files = (0..<500).map { index in
            ClipboardEntry(content: .files(["/Users/demo/benchmark/needle report-\(index).pdf", "/Users/demo/benchmark/needle assets-\(index)"]),
                           copiedAt: Date(timeIntervalSince1970: 1_700_000_000), sourceBundleID: "com.apple.finder", sourceName: "Finder")
        }
        for (label, values) in [("clipboard_coordinator", entries), ("file_clipboard_coordinator", files)] {
            let coordinator = SearchCoordinator()
            var samples: [Double] = []
            for iteration in 0..<repetitions {
                let completed = expectation(description: "\(label) evaluator \(iteration)")
                let start = DispatchTime.now().uptimeNanoseconds
                coordinator.onUpdate = { snapshot, _ in
                    XCTAssertTrue(Thread.isMainThread)
                    XCTAssertEqual(snapshot.scope, .clipboard)
                    XCTAssertEqual(snapshot.count, 500)
                    XCTAssertNil(snapshot.fileResult)
                    samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                    completed.fulfill()
                }
                coordinator.search(raw: "benchmark needle", scope: .clipboard, options: .init(), store: nil,
                                   editingRange: nil, composing: false, apps: [], clipboard: values, clipboardEnabled: true,
                                   calculator: false, web: false, engine: .duckDuckGo)
                wait(for: [completed], timeout: 5)
            }
            coordinator.onUpdate = nil
            report(label, samples: samples, work: "entries=500 matches=500 includes_background_dispatch_and_main_publication=true")
        }
    }

    func testClipboardIdlePollingCPUAndResidentMemory() throws {
        let preferencesName = "OilFindIdlePerformance-\(UUID())"
        let preferences = UserDefaults(suiteName: preferencesName)!
        defer { preferences.removePersistentDomain(forName: preferencesName) }
        preferences.set(true, forKey: "clipboardHistoryEnabled")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let history = ClipboardHistory(defaults: preferences, storage: PerformanceClipboardStorage(),
                                       pasteboard: ClipboardSystemPasteboard(pasteboard: board), source: { (nil, nil) })
        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        func residentBytes() -> UInt64 {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
        }
        history.start()
        let loaded = expectation(description: "History loaded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { loaded.fulfill() }
        wait(for: [loaded], timeout: 2)
        // Warm AppKit's pasteboard machinery before measuring retained entries.
        autoreleasepool { history.copy(ClipboardEntry(text: "Synthetic warmup")) { XCTAssertEqual($0, .copied) } }
        history.clear(); history.flush()
        let before = residentBytes()
        for index in 0..<500 {
            // Small, representative text records; this does not simulate the 32 MiB limit.
            autoreleasepool {
                history.copy(ClipboardEntry(text: "Synthetic local clipboard note \(index): " + String(repeating: "x", count: 120))) {
                    XCTAssertEqual($0, .copied)
                }
            }
        }
        history.flush()
        let settled = expectation(description: "Cancelled save work drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        let after = residentBytes()
        for enabled in [false, true, true, false] {
            history.setPaused(!enabled)
            let cpu = cpuSeconds(), start = DispatchTime.now().uptimeNanoseconds
            let finished = expectation(description: "Idle sample")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { finished.fulfill() }
            wait(for: [finished], timeout: 8)
            let wall = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            let elapsedCPU = cpuSeconds() - cpu
            print("OILFIND_PERF clipboard_idle enabled=\(enabled) entries=\(history.entries.count) wall_seconds=\(number(wall)) process_cpu_ms=\(number(elapsedCPU * 1000)) one_core_percent=\(number(elapsedCPU / wall * 100)) isolated_real_pasteboard=true")
        }
        print("OILFIND_PERF clipboard_resident before_bytes=\(before) after_500_small_text_entries_bytes=\(after) delta_bytes=\(Int64(after) - Int64(before)) runner_increment_only=true excludes_app_baseline_and_full_capacity=true")
        XCTAssertEqual(history.entries.count, 500)
        history.stop()
    }

    func testFiveHundredSyntheticSettingsAndRealCatalogMatching() {
        let settings = (0..<500).map {
            SystemSetting(id: "benchmark-\($0)", englishName: "Benchmark Setting \($0)", chineseName: "性能设置 \($0)",
                          symbol: "gear", aliases: ["benchmark needle"], url: URL(string: "https://example.com/settings/\($0)")!)
        }
        var synthetic: [Double] = [], catalog: [Double] = []
        var catalogMatches = 0
        for _ in 0..<repetitions {
            let ranked = milliseconds {
                settings.compactMap { setting in LauncherMatch.rank("benchmark needle", in: [setting.name] + setting.aliases) }
            }
            XCTAssertEqual(ranked.value.count, 500)
            synthetic.append(ranked.elapsed)
            let real = milliseconds { SystemSettingsCatalog.search("keyboard") }
            catalogMatches = real.value.count
            XCTAssertTrue(real.value.contains { $0.id == "keyboard" })
            catalog.append(real.elapsed)
        }
        report("settings_matcher", samples: synthetic, work: "synthetic_entries=500 matches=500 matcher_only=true excludes_sort_and_dispatch=true")
        report("system_settings_catalog", samples: catalog, work: "catalog_entries=\(SystemSettingsCatalog.entries.count) matches=\(catalogMatches) includes_ranking_and_sort=true")
    }

    func testFiveHundredOfflineCalculatorAndUnitExpressions() {
        let cases = ["150*20%", "5/2", "2^3^2", "10 km to mi", "32°F 转 °C", "1 MiB to KB"]
        let expressions = (0..<500).map { cases[$0 % cases.count] }
        _ = LauncherTools.evaluate(cases[0])
        var samples: [Double] = []
        for _ in 0..<repetitions {
            let evaluated = milliseconds { expressions.compactMap(LauncherTools.evaluate) }
            XCTAssertEqual(evaluated.value.count, 500)
            XCTAssertTrue(evaluated.value.allSatisfy { !$0.value.isEmpty })
            samples.append(evaluated.elapsed)
        }
        report("offline_calculator_units", samples: samples, work: "expressions=500 arithmetic_and_units=true")
        report("offline_calculator_units_per_expression", samples: samples.map { $0 / 500 }, work: "batch_average=true")
    }

    func testOptionalTenMillionSyntheticFileIndex() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OILFIND_PERF_SYNTHETIC"] == "1" || environment["OILFIND_PERF_SYNTHETIC_10M"] == "1" else {
            throw XCTSkip("Also set OILFIND_PERF_SYNTHETIC=1 to allocate a synthetic 10-million-file index.")
        }
        let built = milliseconds { syntheticStore(fileCount: targetFiles) }
        print("OILFIND_PERF synthetic_construction files=\(targetFiles) fill_arrays_ms=\(number(built.elapsed)) hash_built=false persistence=false")
        for query in ["a", "readme", "log"] {
            try compareSearchAndComposition(in: built.value, query: query, scale: "synthetic-10m-flat-nohash")
        }
        let store = built.value
        store.write { store.buildHash() }
        let files = try XCTUnwrap(Searcher.search(Query.parse("a", store: store), options: .init(), in: store))
        let apps = (0..<5).map { offset -> LauncherRow in
            let name = String(format: "a-readme-log-%08d.txt", targetFiles - offset)
            return .app(LauncherApp(name: name, path: store.rootPath + "/" + name))
        }
        var deduplication: [Double] = []
        for _ in 0..<repetitions {
            let measured = milliseconds { SearchCoordinator.compose(raw: "a", scope: .all, fileResult: files, extras: apps) }
            XCTAssertEqual(measured.value.removedOffsets.count, 5)
            XCTAssertEqual(measured.value.count, files.items.count)
            deduplication.append(measured.elapsed)
        }
        report("unified_compose_with_application_deduplication", samples: deduplication,
               work: "scale=synthetic-10m matched_files=10000000 promoted_apps=5 duplicate_ids_near_array_end=true hash_built=true")
        print("OILFIND_PERF synthetic_limit: fixed ASCII names and a flat tree; no claim about real directory, language, or query distributions.")
    }

    private func syntheticStore(fileCount: Int) -> IndexStore {
        var name = Array("a-readme-log-00000000.txt".utf8)
        let length = name.count
        let store = IndexStore(rootPath: "/Users/demo/Performance", count: fileCount + 1, namesLen: fileCount * length,
                               altCount: 0, altLen: 0, fingerprint: 0, homeIndex: UInt32.max, finishedAt: 0)
        store.nameOff[0] = 0; store.parent[0] = 0; store.sizeC[0] = 0; store.mtime[0] = 0
        store.flags[0] = SiftFlag.dir; store.depth[0] = 3; store.kind[0] = 1; store.altOff[0] = 0
        name.withUnsafeMutableBufferPointer { bytes in
            for id in 1...fileCount {
                // Increment the eight decimal digits in place, with no per-file String.
                var digit = 20
                while bytes[digit] == 57 { bytes[digit] = 48; digit -= 1 }
                bytes[digit] += 1
                let offset = (id - 1) * length
                store.nameOff[id] = UInt32(offset); store.parent[id] = 0
                store.sizeC[id] = 1024; store.mtime[id] = 1_700_000_000
                store.flags[id] = 0; store.depth[id] = 4; store.kind[id] = 3
                store.names.advanced(by: offset).update(from: bytes.baseAddress!, count: length)
                if id % 1_000_000 == 0 { print("OILFIND_PERF synthetic_progress files=\(id)/\(fileCount)") }
            }
        }
        store.nameOff[fileCount + 1] = UInt32(fileCount * length)
        return store
    }
}
