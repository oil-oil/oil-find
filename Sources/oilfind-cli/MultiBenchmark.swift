import Foundation
import OilFindCore

func multiBenchmark(db: String, args: [String]) {
    func number(_ key: String, fallback: Int) -> Int {
        guard let i = args.firstIndex(of: key), i + 1 < args.count else { return fallback }
        return max(1, Int(args[i + 1]) ?? fallback)
    }
    func synthetic(_ count: Int, root: String) -> IndexStore {
        var buffer = ScanBuffer()
        for i in 1...count {
            let name: String
            if i % 1000 == 0 { name = "readme-\(i).md" }
            else if i % 1000 == 1 { name = "文档-\(i).md" }
            else { name = "item-\(i).\(i % 20 == 0 ? "png" : "txt")" }
            buffer.ids.append(UInt32(i)); buffer.parents.append(0); buffer.sizes.append(UInt32(i * 10))
            buffer.mtimes.append(1_700_000_000 + UInt32(i % 1000)); buffer.flags.append(SiftFlag.userArea)
            buffer.depths.append(3); buffer.kinds.append(i % 20 == 0 ? 4 : 3)
            buffer.nameLens.append(UInt32(name.utf8.count)); buffer.nameBytes.append(contentsOf: name.utf8)
        }
        let store = IndexStore(scan: ScanOutput(buffers: [buffer], count: count + 1, homeIndex: 0, elapsed: 0, finishedAt: 0), config: IndexConfig(rootPath: root))
        store.write { store.buildHash() }; return store
    }
    let internalStore: IndexStore
    if !args.contains("--synthetic"), let loaded = IndexStore.load(from: db) { internalStore = loaded; internalStore.write { internalStore.buildHash() } }
    else { internalStore = synthetic(number("--internal-count", fallback: 850_000), root: "/") }
    let externalCount = number("--external-count", fallback: 1_000_000), runs = number("--runs", fallback: 20)
    let sources = [SearchSource(id: "startup", displayName: "Startup", isOnline: true, store: internalStore)] + (1...2).map {
        SearchSource(id: "drive-\($0)", displayName: "Drive \($0)", isOnline: $0 == 1, store: synthetic(externalCount, root: "/Volumes/Drive\($0)"))
    }
    _ = Pinyin.shared
    #if DEBUG
    print("configuration=DEBUG (unoptimized; release acceptance remains unmeasured)")
    #else
    print("configuration=optimized")
    #endif
    for source in sources {
        print(String(format: "source=%@ entries=%d bytesPerEntry=%.2f", source.id, source.store.count - 1, Double(source.store.allocatedBytes) / Double(source.store.count)))
    }
    print("query\ttotal\tmin_ms\tmedian_ms\tp95_ms")
    let queue = DispatchQueue(label: "oilfind-cli.multi-bench", qos: .userInteractive)
    for raw in ["readme", "wd", "kind:image", "a", "item", "readme-1000"] {
        let query = Query.parse(raw)
        _ = queue.sync { MultiSearcher.search(query, in: sources) }
        var times: [Double] = [], count = 0
        for _ in 0..<runs {
            guard let result = queue.sync(execute: { MultiSearcher.search(query, in: sources) }) else { exit(1) }
            times.append(result.elapsedMs); count = result.total
        }
        times.sort()
        print(String(format: "%@\t%d\t%.3f\t%.3f\t%.3f", raw, count, times[0], times[times.count / 2], times[min(times.count - 1, Int(ceil(Double(times.count) * 0.95)) - 1)]))
    }
}
