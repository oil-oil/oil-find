import Foundation
import COilFind

public struct SearchSource {
    public let id: String, displayName: String, isOnline: Bool, store: IndexStore
    private let explainPath: ((String) -> CoverageExplanation)?
    public init(id: String, displayName: String, isOnline: Bool, store: IndexStore, explainPath: ((String) -> CoverageExplanation)? = nil) {
        self.id = id; self.displayName = displayName; self.isOnline = isOnline; self.store = store
        self.explainPath = explainPath
    }
    // Cold inspection only; the provider uses the same configuration as its index.
    public func explain(path: String) -> CoverageExplanation? {
        let path = path.precomposedStringWithCanonicalMapping
        let root = store.rootPath.precomposedStringWithCanonicalMapping
        guard path == root || path.hasPrefix(root == "/" ? "/" : root + "/") else { return nil }
        if let explainPath { return explainPath(path) }
        return store.read { store.containsPath(path) } ? .indexed : nil
    }
}

public struct SearchHit {
    public let sourceIndex: Int, entryID: UInt32, reason: String?
    public init(sourceIndex: Int, entryID: UInt32, reason: String? = nil) {
        self.sourceIndex = sourceIndex; self.entryID = entryID; self.reason = reason
    }
}

public final class MultiSearchResult {
    public let sources: [SearchSource], results: [SearchResult], items: [SearchHit]
    public let total: Int, sortedCount: Int, elapsedMs: Double, query: Query, createdAt: Date
    internal init(sources: [SearchSource], results: [SearchResult], items: [SearchHit], sortedCount: Int, elapsedMs: Double, query: Query, total: Int? = nil) {
        self.sources = sources; self.results = results; self.items = items
        self.total = total ?? results.reduce(0) { $0 + $1.total }; self.sortedCount = sortedCount
        self.elapsedMs = elapsedMs; self.query = query; createdAt = Date()
    }
}

public enum MultiSearcher {
    public static func search(_ query: Query, options: SearchOptions = SearchOptions(), in sources: [SearchSource], previous: MultiSearchResult? = nil, caches: [String: SearchCache] = [:], isCancelled: () -> Bool = { false }) -> MultiSearchResult? {
        let began = CFAbsoluteTimeGetCurrent()
        if isCancelled() { return nil }
        let slots = UnsafeMutablePointer<SearchResult?>.allocate(capacity: max(1, sources.count))
        slots.initialize(repeating: nil, count: max(1, sources.count))
        defer { slots.deinitialize(count: max(1, sources.count)); slots.deallocate() }
        func searchSource(_ i: Int) {
            let source = sources[i]
            if isCancelled() { return }
            if let cached = caches[source.id]?.lookup(query: query, options: options, store: source.store) { slots[i] = cached; return }
            let old = previous.flatMap { result -> SearchResult? in
                guard let position = result.sources.firstIndex(where: { $0.id == source.id && $0.store === source.store }) else { return nil }
                return result.results[position]
            }
            slots[i] = Searcher.search(query, options: options, in: source.store, previous: old, isCancelled: isCancelled)
            if let result = slots[i] { caches[source.id]?.insert(result) }
        }
        if sources.count == 1 { searchSource(0) }
        else { DispatchQueue.concurrentPerform(iterations: sources.count, execute: searchSource) }
        if isCancelled() || sources.indices.contains(where: { slots[$0] == nil }) { return nil }
        let results = sources.indices.map { slots[$0]! }
        // Lock once per source for the merge; no names or paths are materialized.
        let stores = sources.map(\.store)
        func mergeLocked(_ i: Int) -> MultiSearchResult? {
            if i < stores.count { return stores[i].read { mergeLocked(i + 1) } }
            guard !isCancelled(), results.indices.allSatisfy({ results[$0].storeVersion == stores[$0].version }) else { return nil }
            let total = results.reduce(0) { $0 + $1.total }
            let limit = query.isEmpty ? min(200, total) : (total > 200_000 ? min(5000, total) : total)
            struct Head { var source: Int, position: Int }
            func better(_ a: Head, _ b: Head) -> Bool {
                let x = results[a.source].items[a.position], y = results[b.source].items[b.position]
                let lhs = stores[a.source], rhs = stores[b.source]
                switch query.isEmpty ? SortKey.modified : options.sort {
                case .relevance:
                    let xs = results[a.source].scores[a.position], ys = results[b.source].scores[b.position]
                    if xs != ys { return xs > ys }
                case .name:
                    let xn = lhs.nameBytes(x), yn = rhs.nameBytes(y)
                    let cmp = sift_name_compare(xn.baseAddress, xn.count, yn.baseAddress, yn.count)
                    if cmp != 0 { return options.ascending ? cmp < 0 : cmp > 0 }
                case .modified:
                    let xs = lhs.mtime[Int(x)], ys = rhs.mtime[Int(y)]
                    if xs != ys { return !query.isEmpty && options.ascending ? xs < ys : xs > ys }
                case .size:
                    let xs = lhs.size(x), ys = rhs.size(y)
                    if xs != ys { return options.ascending ? xs < ys : xs > ys }
                }
                return a.source == b.source ? x < y : a.source < b.source
            }
            var heap: [Head] = [], items: [SearchHit] = []
            items.reserveCapacity(query.isEmpty ? limit : total)
            for source in results.indices where results[source].sortedCount > 0 {
                heap.append(Head(source: source, position: 0))
                var child = heap.count - 1
                while child > 0 {
                    let parent = (child - 1) / 2
                    if !better(heap[child], heap[parent]) { break }
                    heap.swapAt(child, parent); child = parent
                }
            }
            var consumed = [Int](repeating: 0, count: results.count)
            while !heap.isEmpty && items.count < limit {
                if items.count & 4095 == 0 && isCancelled() { return nil }
                let head = heap[0], next = head.position + 1
                items.append(SearchHit(sourceIndex: head.source, entryID: results[head.source].items[head.position]))
                consumed[head.source] = next
                if next < results[head.source].sortedCount { heap[0] = Head(source: head.source, position: next) }
                else { heap.swapAt(0, heap.count - 1); heap.removeLast() }
                var parent = 0
                while parent * 2 + 1 < heap.count {
                    var child = parent * 2 + 1
                    if child + 1 < heap.count && better(heap[child + 1], heap[child]) { child += 1 }
                    if !better(heap[child], heap[parent]) { break }
                    heap.swapAt(child, parent); parent = child
                }
            }
            let sortedCount = items.count
            // Keep every match, including each source's unsorted tail, for narrowing.
            for source in results.indices where !query.isEmpty {
                for position in consumed[source]..<results[source].items.count {
                    if position & 4095 == 0 && isCancelled() { return nil }
                    items.append(SearchHit(sourceIndex: source, entryID: results[source].items[position]))
                }
            }
            return MultiSearchResult(sources: sources, results: results, items: items, sortedCount: sortedCount, elapsedMs: (CFAbsoluteTimeGetCurrent() - began) * 1000, query: query, total: query.isEmpty ? items.count : nil)
        }
        return mergeLocked(0)
    }
}
