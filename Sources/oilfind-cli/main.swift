import Foundation
import Darwin
import OilFindCore
import COilFind

let args = Array(CommandLine.arguments.dropFirst())
let dbDefault = NSHomeDirectory() + "/Library/Caches/Oil Find/cli-index.oilfind"
func option(_ key: String, fallback: String = "") -> String {
    guard let i = args.firstIndex(of: key), i + 1 < args.count else { return fallback }
    return args[i+1]
}
func report(_ store: IndexStore, scanSeconds: Double? = nil, loadSeconds: Double? = nil) {
    let count = store.count, dirs = (0..<count).reduce(0) { $0 + (store.flags[$1] & SiftFlag.dir != 0 ? 1 : 0) }
    let clean = (0..<count).reduce(0) { n,i in let f = store.flags[i]; return n + (f & SiftFlag.userArea != 0 && f & (SiftFlag.noise | SiftFlag.inPackage | SiftFlag.hidden) == 0 ? 1 : 0) }
    let noise = (0..<count).reduce(0) { $0 + (store.flags[$1] & SiftFlag.noise != 0 ? 1 : 0) }
    let inside = (0..<count).reduce(0) { $0 + (store.flags[$1] & SiftFlag.inPackage != 0 ? 1 : 0) }
    let hidden = (0..<count).reduce(0) { $0 + (store.flags[$1] & SiftFlag.hidden != 0 ? 1 : 0) }
    print("entries=\(count) directories=\(dirs)")
    if let t = scanSeconds { print(String(format: "scan=%.3fs rate=%.0f entries/s", t, Double(count)/max(t,0.001))) }
    if let t = loadSeconds { print(String(format: "load=%.3fs", t)) }
    print(String(format: "arrays=%d bytes bytes/entry=%.2f altKeys=%d", store.allocatedBytes, Double(store.allocatedBytes)/Double(max(count,1)), store.altCount))
    print("nameOff=\((store.capacity+1)*4) parent=\(store.capacity*4) sizeC=\(store.capacity*4) mtime=\(store.capacity*4) flags=\(store.capacity) depth=\(store.capacity) kind=\(store.capacity) names=\(store.namesCapacity) altOff=\((store.altCapacity+1)*4) altOwner=\(store.altCapacity*4) altNames=\(store.altNamesCapacity)")
    print("hashTable=\(store.tableCapacity * 4) bytes capacity=\(store.tableCapacity) ready=\(store.hashReady)")
    print("noise=\(noise) inPackage=\(inside) hidden=\(hidden) clean=\(clean)")
    var kinds = [Int](repeating: 0, count: 9)
    for i in 0..<count { kinds[Int(store.kind[i])] += 1 }
    print("kinds=" + kinds.enumerated().map { "\($0.offset):\($0.element)" }.joined(separator: " "))
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    print("resident=\(sift_resident_bytes()) bytes rssPeak=\(usage.ru_maxrss) bytes")
}
let db = option("--db", fallback: dbDefault)
let searchQueue = DispatchQueue(label: "oilfind-cli.search", qos: .userInteractive)
func runSearch(_ query: Query, options: SearchOptions = SearchOptions(), in store: IndexStore, previous: SearchResult? = nil) -> SearchResult? {
    searchQueue.sync { Searcher.search(query, options: options, in: store, previous: previous) }
}
func warmPinyin(output: Bool = false) {
    let began = CFAbsoluteTimeGetCurrent(); _ = Pinyin.shared
    if output { print(String(format: "pinyin init: %.3f ms", (CFAbsoluteTimeGetCurrent() - began) * 1000)) }
}
func fullScope(_ config: inout IndexConfig) {
    if args.contains("--full") {
        config.indexDependencyDirs = true; config.indexPackageContents = true
        config.indexUserLibrary = true; config.indexSystemDirs = true
    }
}
func typing(_ text: String, in store: IndexStore, useCache: Bool = true, output: Bool = false) -> (count: Int, maxMs: Double) {
    let cache = SearchCache(maxItems: max(4_000_000, store.count)), options = SearchOptions()
    var previous: SearchResult?, prefixes = [""], maximum = 0.0, finalCount = 0
    for character in text { prefixes.append(prefixes.last! + String(character)) }
    // Cache the initial empty panel as well, so the final backspace can hit it.
    if useCache, let empty = runSearch(Query.parse(""), options: options, in: store) { cache.insert(empty) }
    func step(_ prefix: String) -> SearchResult {
        let query = Query.parse(prefix), began = CFAbsoluteTimeGetCurrent()
        let result: SearchResult, method: String
        if useCache, let cached = cache.lookup(query: query, options: options, store: store) {
            result = cached; method = "cache"
        } else {
            guard let searched = runSearch(query, options: options, in: store, previous: previous) else { exit(1) }
            result = searched; method = searched.isNarrowed ? "narrow" : "full"
            if useCache { cache.insert(result) }
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - began) * 1000
        maximum = max(maximum, elapsed); previous = result
        if output { print(String(format: "%@  %d  %.3f ms  %@", prefix.isEmpty ? "(empty)" : prefix, result.total, elapsed, method)) }
        return result
    }
    for prefix in prefixes.dropFirst() { finalCount = step(prefix).total }
    for prefix in prefixes.dropLast().reversed() { _ = step(prefix) }
    return (finalCount, maximum)
}
guard let command = args.first else { fputs("usage: oilfind-cli scan|stats|search|typing|bench|watch|m2-bench|multi-bench\n", stderr); exit(2) }
switch command {
case "multi-bench":
    multiBenchmark(db: db, args: args)
case "watch":
    setbuf(stdout, nil)
    var config = IndexConfig.standard(limited: args.contains("--limited"))
    fullScope(&config)
    config.rootPath = IndexConfig(rootPath: option("--root", fallback: "/")).rootPath
    let manager = IndexManager(config: config, dbURL: URL(fileURLWithPath: db))
    let began = CFAbsoluteTimeGetCurrent()
    manager.onStateChange = { state in
        print(String(format: "state=%@ elapsed=%.3fs", String(describing: state), CFAbsoluteTimeGetCurrent()-began))
        if state == .ready, let s = manager.store {
            s.read { print(String(format: "entries=%d buildHash=%.3fms bytes/entry=%.2f hashReady=%@", s.count, manager.buildHashMs, Double(s.allocatedBytes)/Double(s.count), s.hashReady ? "true" : "false")) }
        }
    }
    manager.onApply = { summary in
        print(String(format: "+%d −%d ~%d，子树 %d 个，%.3f ms (mutation=%.3f ms)", summary.inserted, summary.removed, summary.updated, summary.scannedDirs, summary.elapsedMs, summary.mutationMs))
    }
    let inputQueue = DispatchQueue(label: "oilfind-cli.input", qos: .userInteractive)
    let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: inputQueue)
    var pending = Data()
    input.setEventHandler {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
        if n <= 0 { input.cancel(); return }
        pending.append(contentsOf: bytes.prefix(n))
        while let newline = pending.firstIndex(of: 10) {
            let query = String(decoding: pending[..<newline], as: UTF8.self); pending.removeSubrange(...newline)
            guard let s = manager.store else { print("index not ready"); continue }
            if let result = Searcher.search(Query.parse(query), in: s) {
                s.read { for id in result.items.prefix(10) where s.isLive(id) { print(s.path(id)) } }
                print(String(format: "query=%@ total=%d elapsed=%.3fms", query, result.total, result.elapsedMs))
            }
        }
    }
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler {
        input.cancel(); manager.stop()
        print("stopped replayedEvents=\(manager.replayedEventCount) dataPrefix=\(manager.reportedDataPrefix)")
        exit(0)
    }
    interrupt.resume(); input.resume(); manager.start()
    RunLoop.main.run()
case "m2-bench":
    guard let s = IndexStore.load(from: db) else { exit(1) }
    let start = CFAbsoluteTimeGetCurrent(); s.write { s.buildHash() }
    print(String(format: "buildHash=%.3fms entries=%d bytes/entry=%.2f allocated=%d", (CFAbsoluteTimeGetCurrent()-start)*1000, s.count, Double(s.allocatedBytes)/Double(s.count), s.allocatedBytes))
    var config = IndexConfig.standard(limited: args.contains("--limited")); config.rootPath = s.rootPath
    fullScope(&config)
    let updater = IndexUpdater(config: config)
    let fixture = NSHomeDirectory() + "/Desktop/OilFindM2Bench-" + UUID().uuidString
    do {
        try FileManager.default.createDirectory(atPath: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: fixture) }
        for i in 0..<1000 { try Data([65]).write(to: URL(fileURLWithPath: fixture + "/item-\(i).txt")) }
        let inserted = updater.apply([FSChange(path: fixture)], to: s)
        print(String(format: "1000insert-subtree mutation=%.3fms total=%.3fms inserted=%d", inserted.mutationMs, inserted.elapsedMs, inserted.inserted))
        let changes = (0..<1000).map { FSChange(path: fixture + "/item-\($0).txt") }
        for _ in 0..<5 {
            let result = updater.apply(changes, to: s)
            print(String(format: "1000changes mutation=%.3fms total=%.3fms", result.mutationMs, result.elapsedMs))
        }
        for i in 0..<1000 { try FileManager.default.removeItem(atPath: fixture + "/item-\(i).txt") }
        let removed = updater.apply(changes, to: s)
        print(String(format: "1000delete mutation=%.3fms total=%.3fms removed=%d", removed.mutationMs, removed.elapsedMs, removed.removed))
        s.write {
            if let i = s.resolve(path: fixture) { _ = s.remove(i) }
            let begin = CFAbsoluteTimeGetCurrent(); s.sweep()
            print(String(format: "sweep=%.3fms", (CFAbsoluteTimeGetCurrent()-begin)*1000))
        }
    } catch { fputs("benchmark failed: \(error)\n", stderr); exit(1) }
case "scan":
    var config = IndexConfig.standard(limited: args.contains("--limited"))
    fullScope(&config)
    config.rootPath = IndexConfig(rootPath: option("--root", fallback: "/")).rootPath
    guard let output = Scanner(config: config).run() else { fputs("scan failed\n", stderr); exit(1) }
    let store = IndexStore(scan: output, config: config)
    do { try store.save(to: db) } catch { fputs("save failed: \(error)\n", stderr); exit(1) }
    report(store, scanSeconds: output.elapsed)
case "stats", "search", "typing", "bench":
    let start = CFAbsoluteTimeGetCurrent()
    guard let store = IndexStore.load(from: db) else { fputs("cannot load \(db)\n", stderr); exit(1) }
    let load = CFAbsoluteTimeGetCurrent() - start
    if command == "stats" {
        let began = CFAbsoluteTimeGetCurrent(); store.write { store.buildHash() }
        print(String(format: "buildHash=%.3fms", (CFAbsoluteTimeGetCurrent() - began) * 1000))
        report(store, loadSeconds: load); break
    }
    if command == "typing" {
        guard args.count > 1, !args[1].hasPrefix("--") else { fputs("usage: oilfind-cli typing TEXT [--db PATH] [--no-cache]\n", stderr); exit(2) }
        warmPinyin(output: true)
        _ = typing(args[1], in: store, useCache: !args.contains("--no-cache"), output: true)
        break
    }
    if command == "search" {
        let q = args.count > 1 ? args[1] : ""
        let sort: SortKey = ["name": .name, "modified": .modified, "size": .size][option("--sort")] ?? .relevance
        let kindText = option("--kind")
        let kind = Query.kindValue(kindText)
        if args.contains("--kind") && kind == nil { fputs("invalid --kind: use folder, app, doc, image, video, audio, code, archive or 0...8\n", stderr); exit(2) }
        let opts = SearchOptions(sort: sort, ascending: args.contains("--asc"), kind: kind, pinyin: !args.contains("--no-pinyin"))
        guard let result = Searcher.search(Query.parse(q, home: option("--home", fallback: NSHomeDirectory()), store: store), options: opts, in: store) else { exit(1) }
        let formatter = ISO8601DateFormatter()
        for (position, id) in result.items.prefix(max(0, Int(option("--limit", fallback: "20")) ?? 20)).enumerated() {
            let score = position < result.scores.count ? result.scores[position] : 0
            print("\(score)  \(store.size(id))  \(formatter.string(from: store.modified(id)))  \(store.path(id))")
        }
        print(String(format: "total=%d elapsed=%.3fms", result.total, result.elapsedMs))
    } else {
        warmPinyin()
        let queries = ["a", "e", "re", "log", "readme", "file:readme", "folder:src", "package.json", "*.pdf", "ext:png", "wd", "xm", "文档", "项目", "src/", "~/Library/", "/System/", "/private/", "kind:image", "~/Desktop/ png", "readme !node_modules", "jpg|png size:>1mb", "dm:7d ext:md", "regex:^IMG_\\d+", ""]
        print("query\tcount\tmin_ms\tmedian_ms\tp95_ms")
        for q in queries {
            let parsed = Query.parse(q, home: option("--home", fallback: NSHomeDirectory()), store: store); var times: [Double] = []; var count = 0
            for _ in 0..<20 {
                if let r = runSearch(parsed, in: store) { times.append(r.elapsedMs); count = r.total }
            }
            times.sort()
            if times.count == 20 { print(String(format: "%@\t%d\t%.3f\t%.3f\t%.3f", q.isEmpty ? "(empty)" : q, count, times[0], times[10], times[18])) }
        }
        var times: [Double] = [], count = 0
        for _ in 0..<20 {
            let result = typing("readme", in: store)
            times.append(result.maxMs); count = result.count
        }
        times.sort()
        print(String(format: "typing readme\t%d\t%.3f\t%.3f\t%.3f", count, times[0], times[10], times[18]))
    }
default: fputs("unknown command\n", stderr); exit(2)
}
