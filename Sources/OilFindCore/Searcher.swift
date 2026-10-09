import Foundation
import COilFind

public enum SortKey { case relevance, name, modified, size }
public struct SearchOptions {
    public var sort: SortKey = .relevance
    public var ascending: Bool = false
    public var kind: UInt8? = nil
    public var pinyin: Bool = true
    public init(sort: SortKey = .relevance, ascending: Bool = false, kind: UInt8? = nil, pinyin: Bool = true) {
        self.sort = sort; self.ascending = ascending; self.kind = kind; self.pinyin = pinyin
    }
}
public final class SearchResult {
    public let store: IndexStore, query: Query, items: [UInt32], total: Int, sortedCount: Int, elapsedMs: Double
    public let scores: [Int32]
    public let storeVersion: UInt64, options: SearchOptions
    public let isNarrowed: Bool
    public let createdAt: Date
    init(store: IndexStore, query: Query, options: SearchOptions, items: [UInt32], total: Int, sortedCount: Int, elapsedMs: Double, scores: [Int32], isNarrowed: Bool = false, createdAt: Date = Date()) {
        self.store = store; self.query = query; self.items = items; self.total = total
        self.sortedCount = sortedCount; self.elapsedMs = elapsedMs; self.scores = scores
        self.storeVersion = store.version; self.options = options; self.isNarrowed = isNarrowed
        self.createdAt = createdAt
    }
}

private struct Ranked {
    var id: UInt32
    var score: Int32
}
private struct AtomMatch {
    var matched: Bool
    var aborted: Bool
    var baseScore: Int
    var needleLength: Int
    init(matched: Bool, baseScore: Int, needleLength: Int, aborted: Bool = false) {
        self.matched = matched; self.aborted = aborted
        self.baseScore = baseScore; self.needleLength = needleLength
    }
}
private struct ChunkResult {
    var items: [UInt32] = []
    var scores: [Int32] = []
    var sortedCount = 0
    var total = 0
    var original: [Ranked] = []
}
private struct DriverNeedle {
    var bytes: [UInt8]
    var scanAlt: Bool
    var caseSensitive: Bool = false
}
private enum AtomTag: UInt8 {
    case name, path, glob, regex, ext, kind, filesOnly, foldersOnly, fileName, folderName, size, modified
}
private struct ByteSpan {
    var bytes: UnsafePointer<UInt8>?
    var count: Int
}
private struct HotAtom {
    var tag: AtomTag
    var negated: Bool
    var excludesAncestors = false
    var excludesRootAncestor = false
    var flag: Bool = false
    var ascii: Bool = false
    var bytes: UnsafePointer<UInt8>? = nil
    var length: Int = 0
    var components: UnsafePointer<ByteSpan>? = nil
    var componentCount: Int = 0
    var pathMask: UnsafePointer<UInt8>? = nil
    var extKeys: UnsafePointer<UInt64>? = nil
    var extCount: Int = 0
    var extKindMask: UInt16 = 0
    var lower: UInt64 = 0
    var upper: UInt64 = 0
    var regexIndex: Int = 0
}
private struct ClauseRange { var start: Int; var count: Int }
private final class SearchPlan {
    var atoms: [HotAtom] = []
    var clauses: [ClauseRange] = []
    var regexes: [NSRegularExpression] = []
    var drivers: [DriverNeedle]?
    var rootBytes: [UInt8] = []
    var allowedKinds: UInt16 = 0x1ff
    var requiredPath: UnsafePointer<UInt8>?
    var canBatchName: Bool {
        guard let first = atoms.first, first.tag == .name, !first.negated, first.length > 0,
              clauses.allSatisfy({ $0.count == 1 }) else { return false }
        return atoms.dropFirst().allSatisfy { $0.negated && $0.tag == .name && $0.ascii }
    }
    var hasFastFilter: Bool { allowedKinds != 0x1ff || requiredPath != nil }
    private var ownedBytes: [UnsafeMutablePointer<UInt8>] = []
    private var ownedSpans: [(UnsafeMutablePointer<ByteSpan>, Int)] = []
    private var ownedKeys: [UnsafeMutablePointer<UInt64>] = []
    private var ownedMasks: [UnsafeMutablePointer<UInt8>] = []
    func bytes(_ source: [UInt8]) -> UnsafePointer<UInt8>? {
        if source.isEmpty { return nil }
        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: source.count)
        source.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: source.count) }
        ownedBytes.append(pointer)
        return UnsafePointer(pointer)
    }
    func spans(_ source: [[UInt8]]) -> UnsafePointer<ByteSpan>? {
        if source.isEmpty { return nil }
        let pointer = UnsafeMutablePointer<ByteSpan>.allocate(capacity: source.count)
        for i in source.indices { pointer.advanced(by: i).initialize(to: ByteSpan(bytes: bytes(source[i]), count: source[i].count)) }
        ownedSpans.append((pointer, source.count))
        return UnsafePointer(pointer)
    }
    func keys(_ source: [UInt64]) -> UnsafePointer<UInt64>? {
        if source.isEmpty { return nil }
        let pointer = UnsafeMutablePointer<UInt64>.allocate(capacity: source.count)
        source.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: source.count) }
        ownedKeys.append(pointer)
        return UnsafePointer(pointer)
    }
    func descendantMask(store: IndexStore, components: UnsafePointer<ByteSpan>, count: Int) -> UnsafePointer<UInt8> {
        let inside = UnsafeMutablePointer<UInt8>.allocate(capacity: store.count)
        let dirMatch = UnsafeMutablePointer<UInt8>.allocate(capacity: store.count)
        // Match the chain ending at each directory, without the trailing wildcard entry.
        DispatchQueue.concurrentPerform(iterations: max(1, (store.count + 65535) / 65536)) { block in
            let end = min(store.count, (block + 1) * 65536)
            for i in (block * 65536)..<end {
                dirMatch[i] = 0
                if store.flags[i] & SiftFlag.dir == 0 { continue }
                var e = UInt32(i), okay = true
                for k in stride(from: count - 2, through: 0, by: -1) {
                    let component = components[k]
                    if component.count > 0 {
                        let name = store.nameBytes(e)
                        let hit = k == 0
                            ? sift_has_suffix(name.baseAddress, name.count, component.bytes, component.count, 0)
                            : sift_equals(name.baseAddress, name.count, component.bytes, component.count, 0)
                        if hit == 0 { okay = false; break }
                    }
                    if k > 0 {
                        if e == 0 { okay = false; break }
                        e = store.parent[Int(e)]
                    }
                }
                dirMatch[i] = okay ? 1 : 0
            }
        }
        inside[0] = 0
        for i in 1..<store.count {
            let parent = Int(store.parent[i])
            inside[i] = dirMatch[parent] | inside[parent]
        }
        dirMatch.deallocate(); ownedMasks.append(inside)
        return UnsafePointer(inside)
    }
    deinit {
        for (pointer, count) in ownedSpans { pointer.deinitialize(count: count); pointer.deallocate() }
        for pointer in ownedKeys { pointer.deallocate() }
        for pointer in ownedBytes { pointer.deallocate() }
        for pointer in ownedMasks { pointer.deallocate() }
    }
}
private final class SearchScratch {
    var streams: [[UInt32]]
    var positions: [Int]
    var candidates: [UInt32]?
    var full: [UInt8] = [], initials: [UInt8] = [], path: [UInt8] = []
    var ranked: [Ranked] = [], heap: [Ranked] = []
    let scanOut: UnsafeMutablePointer<UInt32>?
    let scoreOut: UnsafeMutablePointer<Int32>?
    init(streamCount: Int, chunkSize: Int, needsCandidates: Bool, needsScanOut: Bool, needsScoreOut: Bool) {
        streams = Array(repeating: [], count: streamCount)
        for i in streams.indices { streams[i].reserveCapacity(chunkSize * 2) }
        positions = Array(repeating: 0, count: streamCount)
        if needsCandidates {
            candidates = []
            candidates?.reserveCapacity(chunkSize)
        }
        ranked.reserveCapacity(chunkSize)
        heap.reserveCapacity(5000)
        full.reserveCapacity(2048); initials.reserveCapacity(2048); path.reserveCapacity(4096)
        scanOut = needsScanOut ? .allocate(capacity: 4096) : nil
        scoreOut = needsScoreOut ? .allocate(capacity: min(4096, chunkSize)) : nil
    }
    deinit { scanOut?.deallocate(); scoreOut?.deallocate() }
}

public enum Searcher {
    /// Evaluate existing query atoms against captured entries under one read lock.
    /// The callback is synchronous; predicate indexes correspond to the input atoms.
    public static func withEntryPredicates<T>(_ atoms: [Atom], options: SearchOptions = SearchOptions(), in store: IndexStore,
                                              isCancelled: @escaping () -> Bool = { false }, _ body: ((Int, UInt32) -> Bool) -> T) -> T {
        store.read {
            let query = Query(clauses: atoms.map { Clause(alternatives: [$0]) }, raw: "")
            let plan = makePlan(query, store: store, pinyin: options.pinyin, preserveOrder: true)
            let scratch = SearchScratch(streamCount: 0, chunkSize: 0, needsCandidates: false, needsScanOut: false, needsScoreOut: false)
            return plan.atoms.withUnsafeBufferPointer { pointer in
                body { ordinal, id in
                    guard ordinal >= 0, ordinal < pointer.count, Int(id) < store.count, store.isLive(id), !isCancelled() else { return false }
                    return matchHot(pointer.baseAddress!.advanced(by: ordinal), id: id, plan: plan, options: options, store: store, scratch: scratch, scoreNeeded: false, isCancelled: isCancelled).matched
                }
            }
        }
    }

    public static func search(_ query: Query, options: SearchOptions = SearchOptions(), in store: IndexStore, previous: SearchResult? = nil, isCancelled: () -> Bool = { false }) -> SearchResult? {
        let started = CFAbsoluteTimeGetCurrent()
        return store.read {
            if isCancelled() { return nil }
            if query.isEmpty { return recent(query, options: options, store: store, started: started, isCancelled: isCancelled) }
            let narrowed = previous.map { canNarrow(query, options: options, store: store, previous: $0) } ?? false
            let candidateCount = narrowed ? previous!.items.count : store.count - 1
            let plan = makePlan(query, store: store, pinyin: options.pinyin)
            let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
            let chunkSize = narrowed ? 65536 : max(65536, store.count / (cores * 4))
            let chunkCount = max(0, (candidateCount + chunkSize - 1) / chunkSize)
            if chunkCount == 0 { return SearchResult(store: store, query: query, options: options, items: [], total: 0, sortedCount: 0, elapsedMs: (CFAbsoluteTimeGetCurrent()-started)*1000, scores: [], isNarrowed: narrowed) }
            let workers = min(cores, chunkCount)
            let results = UnsafeMutablePointer<ChunkResult>.allocate(capacity: chunkCount)
            results.initialize(repeating: ChunkResult(), count: chunkCount)
            defer { results.deinitialize(count: chunkCount); results.deallocate() }
            let cancelled = UnsafeMutablePointer<UInt8>.allocate(capacity: workers)
            cancelled.initialize(repeating: 0, count: workers)
            defer { cancelled.deallocate() }
            let now = UInt32(clamping: Int64(Date().timeIntervalSince1970))
            let simpleName = options.sort == .relevance && plan.canBatchName
            func run(_ candidates: UnsafeBufferPointer<UInt32>?) {
                DispatchQueue.concurrentPerform(iterations: workers) { worker in
                    let cancellationState = cancelled.advanced(by: worker)
                    func cancellationRequested() -> Bool {
                        if cancellationState.pointee != 0 { return true }
                        if isCancelled() {
                            cancellationState.pointee = 1
                            return true
                        }
                        return false
                    }
                    let scratch = SearchScratch(streamCount: narrowed ? 0 : (plan.drivers?.count ?? 0) * 2,
                                                chunkSize: chunkSize,
                                                needsCandidates: narrowed || plan.drivers != nil || simpleName,
                                                needsScanOut: (!narrowed && (plan.drivers != nil || plan.hasFastFilter || options.kind != nil)) || (narrowed && simpleName),
                                                needsScoreOut: simpleName)
                    var block = worker
                    while block < chunkCount {
                        let e0 = 1 + block * chunkSize, e1 = min(e0 + chunkSize, store.count)
                        let slice = candidates.map { UnsafeBufferPointer(rebasing: $0[(block * chunkSize)..<min((block + 1) * chunkSize, $0.count)]) }
                        guard let result = processChunk(e0: e0, e1: e1, candidates: slice, sortAll: candidateCount <= 200_000, plan: plan, options: options, store: store, now: now, scratch: scratch, isCancelled: cancellationRequested) else {
                            cancelled[worker] = 1
                            break
                        }
                        results[block] = result
                        if cancellationRequested() { cancelled[worker] = 1; break }
                        block += workers
                    }
                }
            }
            if narrowed { previous!.items.withUnsafeBufferPointer { run($0) } } else { run(nil) }
            if (0..<workers).contains(where: { cancelled[$0] != 0 }) || isCancelled() { return nil }
            let total = (0..<chunkCount).reduce(0) { $0 + results[$1].total }
            let large = total > 200_000
            var items: [UInt32] = [], scores: [Int32] = []
            if !large { items.reserveCapacity(total) }
            if options.sort == .relevance { scores.reserveCapacity(large ? 5000 : total) }
            let sortedCount: Int
            if large {
                let selectedTop = mergeTop(results, count: chunkCount, options: options, store: store)
                var selected = [UInt8](repeating: 0, count: store.count)
                items = Array(unsafeUninitializedCapacity: total) { output, initialized in
                    selected.withUnsafeMutableBufferPointer { mask in
                        var cursor = 0
                        for entry in selectedTop {
                            mask[Int(entry.id)] = 1; output[cursor] = entry.id; cursor += 1
                            if options.sort == .relevance { scores.append(entry.score) }
                        }
                        for block in 0..<chunkCount {
                            results[block].original.withUnsafeBufferPointer { entries in
                                for entry in entries where mask[Int(entry.id)] == 0 {
                                    if narrowed { mask[Int(entry.id)] = 2 }
                                    else { output[cursor] = entry.id; cursor += 1 }
                                }
                            }
                        }
                        if narrowed {
                            // The unsorted suffix has the same ID order as a full scan.
                            for i in 1..<mask.count where mask[i] == 2 { output[cursor] = UInt32(i); cursor += 1 }
                        }
                        initialized = cursor
                    }
                }
                sortedCount = selectedTop.count
            } else {
                // Finish any bounded-heap chunks, then reuse the same merge for all results.
                for block in 0..<chunkCount where results[block].sortedCount < results[block].total {
                    results[block].original.sort { better($0, $1, options: options, store: store) }
                    results[block].items = results[block].original.map(\.id)
                    if options.sort == .relevance { results[block].scores = results[block].original.map(\.score) }
                    results[block].sortedCount = results[block].total
                }
                let all = mergeTop(results, count: chunkCount, limit: total, options: options, store: store)
                for entry in all { items.append(entry.id); if options.sort == .relevance { scores.append(entry.score) } }
                sortedCount = total
            }
            let completed = CFAbsoluteTimeGetCurrent()
            if isCancelled() { return nil }
            return SearchResult(store: store, query: query, options: options, items: items, total: total, sortedCount: sortedCount, elapsedMs: (completed-started)*1000, scores: scores, isNarrowed: narrowed)
        }
    }

    private static func canNarrow(_ query: Query, options: SearchOptions, store: IndexStore, previous: SearchResult) -> Bool {
        guard previous.store === store, previous.storeVersion == store.version,
              previous.options.kind == options.kind, previous.options.pinyin == options.pinyin,
              !previous.query.isEmpty, !previous.query.isTimeDependent,
              query.clauses.count >= previous.query.clauses.count else { return false }
        for i in previous.query.clauses.indices {
            let old = previous.query.clauses[i].alternatives, new = query.clauses[i].alternatives
            guard old.count == 1, new.count == 1, !old[0].negated, !new[0].negated,
                  case .name(let oldNeedle, let oldCase) = old[0].matcher,
                  case .name(let newNeedle, let newCase) = new[0].matcher, oldCase == newCase else { return false }
            // An empty name atom is not a universal match in the existing scorer.
            if oldNeedle.isEmpty { return false }
            // Non-ASCII needles also match Unicode lowercase keys; ASCII needles
            // only use pinyin keys. Changing that key domain is not monotonic.
            if !oldCase && oldNeedle.allSatisfy({ $0 < 128 }) && newNeedle.contains(where: { $0 >= 128 }) { return false }
            let contains = newNeedle.withUnsafeBufferPointer { n in
                oldNeedle.withUnsafeBufferPointer { o in sift_contains(n.baseAddress, n.count, o.baseAddress, o.count, 1) != 0 }
            }
            if !contains { return false }
        }
        return true
    }

    private static func recent(_ query: Query, options: SearchOptions, store: IndexStore, started: CFAbsoluteTime, isCancelled: () -> Bool) -> SearchResult? {
        var heap: [Ranked] = []
        heap.reserveCapacity(200)
        let recentOptions = SearchOptions(sort: .modified)
        var start = 1
        while start < store.count {
            if start > 1 && isCancelled() { return nil }
            let end = min(start + 4096, store.count)
            for i in start..<end {
                let flags = store.flags[i]
                if flags & (SiftFlag.deleted | SiftFlag.noise | SiftFlag.inPackage | SiftFlag.hidden) != 0 || flags & SiftFlag.userArea == 0 || store.kind[i] == 1 { continue }
                if let kind = options.kind, store.kind[i] != kind { continue }
                pushTop(Ranked(id: UInt32(i), score: 0), limit: 200, heap: &heap, options: recentOptions, store: store)
            }
            start = end
        }
        heap.sort { better($0, $1, options: recentOptions, store: store) }
        if isCancelled() { return nil }
        let ids = heap.map(\.id)
        return SearchResult(store: store, query: query, options: options, items: ids, total: ids.count, sortedCount: ids.count, elapsedMs: (CFAbsoluteTimeGetCurrent()-started)*1000, scores: [])
    }

    private static func makePlan(_ query: Query, store: IndexStore, pinyin: Bool, preserveOrder: Bool = false) -> SearchPlan {
        let plan = SearchPlan()
        let rootComponents = store.rootPath.lowercased().split(separator: "/", omittingEmptySubsequences: false).map { Array($0.utf8) }
        let clauses = preserveOrder ? query.clauses : query.clauses.sorted(by: { !$0.alternatives.contains(where: { $0.negated }) && $1.alternatives.contains(where: { $0.negated }) })
        for clause in clauses {
            let start = plan.atoms.count
            for atom in clause.alternatives {
                var hot = HotAtom(tag: .name, negated: atom.negated)
                hot.excludesAncestors = atom.excludesAncestors
                switch atom.matcher {
                case .name(let n, let cs):
                    hot.tag = .name; hot.bytes = plan.bytes(n); hot.length = n.count; hot.flag = cs; hot.ascii = n.allSatisfy { $0 < 128 }
                    hot.excludesRootAncestor = atom.excludesAncestors && rootComponents.contains(n)
                case .path(let c):
                    var normalized = c
                    if store.rootPath != "/" && c.count >= rootComponents.count && c.prefix(rootComponents.count).elementsEqual(rootComponents, by: { $0 == $1 }) { normalized = [[]] + c.dropFirst(rootComponents.count) }
                    hot.tag = .path; hot.components = plan.spans(normalized); hot.componentCount = normalized.count
                    if normalized.count >= 2 && normalized.last!.isEmpty { hot.pathMask = plan.descendantMask(store: store, components: hot.components!, count: normalized.count) }
                case .glob(let p, let onPath): hot.tag = .glob; hot.bytes = plan.bytes(p); hot.length = p.count; hot.flag = onPath
                case .regex(let r, let onPath):
                    hot.tag = .regex; hot.regexIndex = plan.regexes.count; plan.regexes.append(r); hot.flag = onPath
                    let prefix = r.options.intersection([.caseInsensitive, .anchorsMatchLines]).isEmpty ? literalRegexPrefix(r.pattern) : []
                    hot.bytes = plan.bytes(prefix); hot.length = prefix.count
                case .ext(let keys):
                    let sorted = keys.sorted(); hot.tag = .ext; hot.extKeys = plan.keys(sorted); hot.extCount = sorted.count
                    var mask: UInt16 = 1 << 1
                    for key in sorted {
                        let kind = Classifier.kind(forExtension: key)
                        if kind == 0 { mask = 0; break }
                        mask |= 1 << kind
                    }
                    hot.extKindMask = mask
                case .kind(let k): hot.tag = .kind; hot.lower = UInt64(k)
                case .filesOnly: hot.tag = .filesOnly
                case .foldersOnly: hot.tag = .foldersOnly
                case .fileName(let n): hot.tag = .fileName; hot.bytes = plan.bytes(n); hot.length = n.count; hot.ascii = n.allSatisfy { $0 < 128 }
                case .folderName(let n): hot.tag = .folderName; hot.bytes = plan.bytes(n); hot.length = n.count; hot.ascii = n.allSatisfy { $0 < 128 }
                case .size(let r): hot.tag = .size; hot.lower = r.lowerBound; hot.upper = r.upperBound
                case .modified(let r): hot.tag = .modified; hot.lower = UInt64(r.lowerBound); hot.upper = UInt64(r.upperBound)
                }
                plan.atoms.append(hot)
            }
            let count = plan.atoms.count - start
            plan.clauses.append(ClauseRange(start: start, count: count))
            if count == 1 && !plan.atoms[start].negated {
                let atom = plan.atoms[start]
                switch atom.tag {
                case .ext: if atom.extKindMask != 0 { plan.allowedKinds &= atom.extKindMask }
                case .kind: plan.allowedKinds &= 1 << atom.lower
                case .filesOnly: plan.allowedKinds &= ~(1 << 1)
                case .foldersOnly: plan.allowedKinds &= 1 << 1
                case .path: if plan.requiredPath == nil { plan.requiredPath = atom.pathMask }
                default: break
                }
            }
        }
        var drivers: [DriverNeedle]?, bestLength = 0
        for clause in query.clauses {
            var needles: [DriverNeedle] = []
            for atom in clause.alternatives {
                if atom.negated { needles.removeAll(); break }
                if case .name(let n, let cs) = atom.matcher {
                    needles.append(DriverNeedle(bytes: n, scanAlt: !cs && (pinyin && n.allSatisfy { $0 < 128 } || n.contains { $0 >= 128 }), caseSensitive: cs))
                } else if case .glob(let p, let onPath) = atom.matcher, !onPath && clause.alternatives.count == 1 {
                    let part = p.split(whereSeparator: { $0 == 42 || $0 == 63 }).max { $0.count < $1.count }.map(Array.init) ?? []
                    if !part.isEmpty { needles.append(DriverNeedle(bytes: part, scanAlt: false)) }
                } else { needles.removeAll(); break }
            }
            if let shortest = needles.map(\.bytes.count).min(), shortest > bestLength { drivers = needles; bestLength = shortest }
        }
        plan.drivers = drivers
        plan.rootBytes = Array(store.rootPath.utf8)
        return plan
    }
    private static func literalRegexPrefix(_ pattern: String) -> [UInt8] {
        guard pattern.first == "^", !pattern.contains("|") else { return [] }
        var prefix: [UInt8] = []
        for byte in pattern.utf8.dropFirst() {
            // A quantifier can make the preceding literal optional.
            if byte == 42 || byte == 63 || byte == 123 { return [] }
            if byte == 92 || byte == 46 || byte == 42 || byte == 43 || byte == 63 || byte == 91 || byte == 123 || byte == 40 || byte == 124 || byte == 36 || byte == 94 { break }
            prefix.append(byte)
        }
        return prefix
    }

    private static func processChunk(e0: Int, e1: Int, candidates: UnsafeBufferPointer<UInt32>?, sortAll: Bool, plan: SearchPlan, options: SearchOptions, store: IndexStore, now: UInt32, scratch: SearchScratch, isCancelled: () -> Bool) -> ChunkResult? {
        scratch.ranked.removeAll(keepingCapacity: true)
        var cancelled = false
        plan.atoms.withUnsafeBufferPointer { atoms in
            plan.clauses.withUnsafeBufferPointer { clauses in
                let simpleName = options.sort == .relevance && plan.canBatchName
                if let candidates {
                    guard scratch.candidates != nil else { cancelled = true; return }
                    scratch.candidates!.removeAll(keepingCapacity: true)
                    if simpleName {
                        guard let scanOut = scratch.scanOut else { cancelled = true; return }
                        let atom = atoms[0]
                        var start = 0
                        while start < candidates.count {
                            if start > 0 && isCancelled() { cancelled = true; break }
                            let end = min(start + 4096, candidates.count)
                            let batch = UnsafeBufferPointer(rebasing: candidates[start..<end])
                            let count = sift_scan_candidates(batch.baseAddress, batch.count, store.names, store.nameOff,
                                                             atom.bytes, atom.length, atom.flag ? 1 : 0,
                                                             !atom.flag && (options.pinyin || !atom.ascii) ? 1 : 0, scanOut)
                            scratch.candidates!.append(contentsOf: UnsafeBufferPointer(start: scanOut, count: count))
                            start = end
                        }
                    } else { scratch.candidates!.append(contentsOf: candidates) }
                } else if let drivers = plan.drivers {
                    guard scratch.candidates != nil, scratch.scanOut != nil else { cancelled = true; return }
                    cancelled = generateCandidates(e0: e0, e1: e1, drivers: drivers, store: store, scratch: scratch, isCancelled: isCancelled)
                } else if simpleName {
                    guard scratch.candidates != nil else { cancelled = true; return }
                    scratch.candidates!.removeAll(keepingCapacity: true)
                    var start = e0
                    while start < e1 {
                        if start > e0 && isCancelled() { cancelled = true; break }
                        let end = min(start + 4096, e1)
                        for i in start..<end { scratch.candidates!.append(UInt32(i)) }
                        start = end
                    }
                }
                if cancelled { return }
                if simpleName {
                    guard let candidateIDs = scratch.candidates else { cancelled = true; return }
                    if atoms.count == 1 {
                        cancelled = scoreSimpleName(atoms[0], candidates: candidateIDs, plan: plan, options: options, store: store, now: now, scratch: scratch, isCancelled: isCancelled)
                    } else {
                        cancelled = scoreNameWithNegations(atoms[0], candidates: candidateIDs, plan: plan, options: options, store: store, now: now, scratch: scratch, isCancelled: isCancelled)
                    }
                } else if candidates != nil || plan.drivers != nil {
                    guard let candidateIDs = scratch.candidates else { cancelled = true; return }
                    var start = 0
                    while start < candidateIDs.count {
                        if start > 0 && isCancelled() { cancelled = true; break }
                        let end = min(start + 4096, candidateIDs.count)
                        for j in start..<end {
                            if let entry = evaluateHot(id: candidateIDs[j], atoms: atoms.baseAddress!, clauses: clauses.baseAddress!, clauseCount: clauses.count, plan: plan, options: options, store: store, now: now, scratch: scratch, isCancelled: isCancelled) { scratch.ranked.append(entry) }
                        }
                        start = end
                    }
                } else if plan.hasFastFilter || options.kind != nil {
                    guard let scanOut = scratch.scanOut else { cancelled = true; return }
                    let kindMask = options.kind.map { plan.allowedKinds & (1 << $0) } ?? plan.allowedKinds
                    var start = e0
                    while start < e1 {
                        if start > e0 && isCancelled() { cancelled = true; break }
                        let end = min(start + 4096, e1)
                        let count = sift_filter_entries(UInt32(start), UInt32(end), store.flags, store.kind, kindMask, plan.requiredPath, scanOut)
                        for j in 0..<count {
                            if let entry = evaluateHot(id: scanOut[j], atoms: atoms.baseAddress!, clauses: clauses.baseAddress!, clauseCount: clauses.count, plan: plan, options: options, store: store, now: now, scratch: scratch, isCancelled: isCancelled) { scratch.ranked.append(entry) }
                        }
                        start = end
                    }
                } else {
                    var start = e0
                    while start < e1 {
                        if start > e0 && isCancelled() { cancelled = true; break }
                        let end = min(start + 4096, e1)
                        for i in start..<end {
                            if let entry = evaluateHot(id: UInt32(i), atoms: atoms.baseAddress!, clauses: clauses.baseAddress!, clauseCount: clauses.count, plan: plan, options: options, store: store, now: now, scratch: scratch, isCancelled: isCancelled) { scratch.ranked.append(entry) }
                        }
                        start = end
                    }
                }
            }
        }
        if cancelled { return nil }
        let count = scratch.ranked.count
        var result = ChunkResult()
        result.total = count
        result.original.reserveCapacity(count)
        result.original.append(contentsOf: scratch.ranked)
        let prefixCapacity = sortAll || count <= 50_000 ? count : min(count, 5000)
        result.items.reserveCapacity(prefixCapacity)
        if options.sort == .relevance { result.scores.reserveCapacity(prefixCapacity) }
        if sortAll || count <= 50_000 {
            scratch.ranked.sort { better($0, $1, options: options, store: store) }
            result.sortedCount = count
            for entry in scratch.ranked {
                result.items.append(entry.id)
                if options.sort == .relevance { result.scores.append(entry.score) }
            }
        } else {
            bestK(scratch.ranked, count: 5000, options: options, store: store, heap: &scratch.heap)
            result.sortedCount = scratch.heap.count
            for entry in scratch.heap {
                result.items.append(entry.id)
                if options.sort == .relevance { result.scores.append(entry.score) }
            }
        }
        return result
    }
    private static func scoreSimpleName(_ atom: HotAtom, candidates: [UInt32], plan: SearchPlan, options: SearchOptions, store: IndexStore, now: UInt32, scratch: SearchScratch, isCancelled: () -> Bool) -> Bool {
        guard let scoreOut = scratch.scoreOut else { return true }
        let batchSize = 4096
        var batchStart = 0
        while batchStart < candidates.count {
            if batchStart > 0 && isCancelled() { return true }
            let batchEnd = min(batchStart + batchSize, candidates.count)
            candidates.withUnsafeBufferPointer { allIDs in
                let ids = UnsafeBufferPointer(rebasing: allIDs[batchStart..<batchEnd])
                sift_score_name_batch(ids.baseAddress, ids.count, store.names, store.nameOff, store.flags, store.kind, store.depth, store.mtime, atom.bytes, atom.length, atom.flag ? 1 : 0, now, scoreOut)
                for j in 0..<ids.count {
                    let id = ids[j], i = Int(id)
                    if store.flags[i] & SiftFlag.deleted != 0 { continue }
                    if let kind = options.kind, store.kind[i] != kind { continue }
                    let score = scoreOut[j]
                    if score == OILFIND_SCORE_NO_MATCH { continue }
                    if score == OILFIND_SCORE_FALLBACK {
                        if let fallback = plan.atoms.withUnsafeBufferPointer({ atoms in plan.clauses.withUnsafeBufferPointer { clauses in evaluateHot(id: id, atoms: atoms.baseAddress!, clauses: clauses.baseAddress!, clauseCount: clauses.count, plan: plan, options: options, store: store, now: now, scratch: scratch, isCancelled: isCancelled) } }) { scratch.ranked.append(fallback) }
                    } else {
                        scratch.ranked.append(Ranked(id: id, score: score))
                    }
                }
            }
            batchStart = batchEnd
        }
        return false
    }

    private static func scoreNameWithNegations(_ atom: HotAtom, candidates: [UInt32], plan: SearchPlan, options: SearchOptions, store: IndexStore, now: UInt32, scratch: SearchScratch, isCancelled: () -> Bool) -> Bool {
        guard let scoreOut = scratch.scoreOut else { return true }
        return plan.atoms.withUnsafeBufferPointer { atoms in
            plan.clauses.withUnsafeBufferPointer { clauses in
                let batchSize = 4096
                var batchStart = 0
                while batchStart < candidates.count {
                    if batchStart > 0 && isCancelled() { return true }
                    let batchEnd = min(batchStart + batchSize, candidates.count)
                    candidates.withUnsafeBufferPointer { allIDs in
                        let ids = UnsafeBufferPointer(rebasing: allIDs[batchStart..<batchEnd])
                        sift_score_name_batch(ids.baseAddress, ids.count, store.names, store.nameOff, store.flags, store.kind, store.depth, store.mtime, atom.bytes, atom.length, atom.flag ? 1 : 0, now, scoreOut)
                        for a in 1..<atoms.count {
                            let excluded = atoms[a]
                            sift_exclude_name_batch(ids.baseAddress, ids.count, store.names, store.nameOff, store.parent, store.flags, store.kind, options.kind.map(Int32.init) ?? -1, excluded.bytes, excluded.length, excluded.flag ? 1 : 0, excluded.excludesAncestors ? 1 : 0, excluded.excludesRootAncestor ? 1 : 0, scoreOut)
                        }
                        for j in 0..<ids.count {
                            let id = ids[j], i = Int(id)
                            if store.flags[i] & SiftFlag.deleted != 0 { continue }
                            if let kind = options.kind, store.kind[i] != kind { continue }
                            let score = scoreOut[j]
                            if score == OILFIND_SCORE_NO_MATCH { continue }
                            if score == OILFIND_SCORE_FALLBACK {
                                if let fallback = evaluateHot(id: id, atoms: atoms.baseAddress!, clauses: clauses.baseAddress!, clauseCount: clauses.count, plan: plan, options: options, store: store, now: now, scratch: scratch, isCancelled: isCancelled) { scratch.ranked.append(fallback) }
                            } else {
                                scratch.ranked.append(Ranked(id: id, score: score))
                            }
                        }
                    }
                    batchStart = batchEnd
                }
                return false
            }
        }
    }

    private static func generateCandidates(e0: Int, e1: Int, drivers: [DriverNeedle], store: IndexStore, scratch: SearchScratch, isCancelled: () -> Bool) -> Bool {
        guard scratch.candidates != nil else { return false }
        scratch.candidates!.removeAll(keepingCapacity: true)
        var streamCount = 0
        for driver in drivers {
            scratch.streams[streamCount].removeAll(keepingCapacity: true)
            if scanEntries(blob: store.names, offsets: store.nameOff, e0: e0, e1: e1, needle: driver.bytes, cs: driver.caseSensitive, owner: nil, out: &scratch.streams[streamCount], scratch: scratch, isCancelled: isCancelled) { return true }
            streamCount += 1
            if driver.scanAlt {
                let a0 = lowerBound(store.altOwner, store.altCount, UInt32(e0))
                let a1 = lowerBound(store.altOwner, store.altCount, UInt32(e1))
                scratch.streams[streamCount].removeAll(keepingCapacity: true)
                if a0 < a1 && scanEntries(blob: store.altNames, offsets: store.altOff, e0: a0, e1: a1, needle: driver.bytes, cs: false, owner: store.altOwner, out: &scratch.streams[streamCount], scratch: scratch, isCancelled: isCancelled) { return true }
                streamCount += 1
            }
        }
        if streamCount == 1 || (streamCount == 2 && scratch.streams[1].isEmpty) {
            scratch.candidates!.append(contentsOf: scratch.streams[0])
            return false
        }
        if streamCount == 2 {
            var stopped = false
            scratch.streams[0].withUnsafeBufferPointer { a in
                scratch.streams[1].withUnsafeBufferPointer { b in
                    var x = 0, y = 0
                    var steps = 0
                    while x < a.count || y < b.count {
                        if steps > 0 && steps % 4096 == 0 && isCancelled() { stopped = true; return }
                        let next = min(x < a.count ? a[x] : .max, y < b.count ? b[y] : .max)
                        scratch.candidates!.append(next)
                        while x < a.count && a[x] == next { x += 1 }
                        while y < b.count && b[y] == next { y += 1 }
                        steps += 1
                    }
                }
            }
            return stopped
        }
        for j in 0..<streamCount { scratch.positions[j] = 0 }
        var steps = 0
        while true {
            if steps > 0 && steps % 4096 == 0 && isCancelled() { return true }
            var next = UInt32.max
            for j in 0..<streamCount where scratch.positions[j] < scratch.streams[j].count {
                let id = scratch.streams[j][scratch.positions[j]]
                if id < next { next = id }
            }
            if next == UInt32.max { break }
            scratch.candidates!.append(next)
            for j in 0..<streamCount {
                while scratch.positions[j] < scratch.streams[j].count && scratch.streams[j][scratch.positions[j]] == next { scratch.positions[j] += 1 }
            }
            steps += 1
        }
        return false
    }
    private static func scanEntries(blob: UnsafeMutablePointer<UInt8>, offsets: UnsafeMutablePointer<UInt32>, e0: Int, e1: Int, needle: [UInt8], cs: Bool, owner: UnsafeMutablePointer<UInt32>?, out: inout [UInt32], scratch: SearchScratch, isCancelled: () -> Bool) -> Bool {
        guard let scanOut = scratch.scanOut else { return false }
        var cancelled = false
        needle.withUnsafeBufferPointer { n in
            var start = e0
            while start < e1 {
                if start > e0 && isCancelled() { cancelled = true; return }
                let end = min(start + 4096, e1)
                var resume = UInt32(start)
                while resume < end {
                    let count = sift_scan_entries(blob, offsets, resume, UInt32(end), n.baseAddress, n.count, cs ? 1 : 0, scanOut, 4096, &resume)
                    if let owner { for j in 0..<count { out.append(owner[Int(scanOut[j])]) } }
                    else { out.append(contentsOf: UnsafeBufferPointer(start: scanOut, count: count)) }
                }
                start = end
            }
        }
        return cancelled
    }
    private static func lowerBound(_ owners: UnsafeMutablePointer<UInt32>, _ count: Int, _ value: UInt32) -> Int {
        var lo = 0, hi = count
        while lo < hi { let mid = (lo + hi) / 2; if owners[mid] < value { lo = mid + 1 } else { hi = mid } }
        return lo
    }

    private static func evaluateHot(id: UInt32, atoms: UnsafePointer<HotAtom>, clauses: UnsafePointer<ClauseRange>, clauseCount: Int, plan: SearchPlan, options: SearchOptions, store: IndexStore, now: UInt32, scratch: SearchScratch, isCancelled: () -> Bool) -> Ranked? {
        let i = Int(id), flags = store.flags[i]
        if flags & SiftFlag.deleted != 0 { return nil }
        if let kind = options.kind, store.kind[i] != kind { return nil }
        let scoreNeeded = options.sort == .relevance
        var baseSum = 0, baseCount = 0, needleLength = 0
        for c in 0..<clauseCount {
            let clause = clauses[c]
            var any = false
            for a in clause.start..<(clause.start + clause.count) {
                let atom = atoms.advanced(by: a)
                let outcome = matchHot(atom, id: id, plan: plan, options: options, store: store, scratch: scratch, scoreNeeded: scoreNeeded, isCancelled: isCancelled)
                if outcome.aborted { return nil }
                if atom.pointee.negated ? !outcome.matched : outcome.matched { any = true }
                if scoreNeeded && outcome.matched && !atom.pointee.negated && outcome.baseScore > 0 { baseSum += outcome.baseScore; baseCount += 1; needleLength += outcome.needleLength }
                if any && !scoreNeeded { break }
            }
            if !any { return nil }
        }
        if !scoreNeeded { return Ranked(id: id, score: 0) }
        let nameLength = Int(store.nameOff[i+1] - store.nameOff[i])
        var score = baseCount == 0 ? 400 : baseSum / baseCount - 2 * min(max(0, nameLength - needleLength), 64)
        if flags & SiftFlag.userArea != 0 && flags & (SiftFlag.noise | SiftFlag.inPackage | SiftFlag.hidden) == 0 { score += 60 }
        if store.kind[i] == 2 { score += 150 }
        if store.kind[i] == 1 { score += 20 }
        let age = now >= store.mtime[i] ? now - store.mtime[i] : 0
        if age <= 86_400 { score += 60 } else if age <= 604_800 { score += 45 } else if age <= 2_592_000 { score += 30 } else if age <= 31_536_000 { score += 10 }
        if flags & SiftFlag.noise != 0 { score -= 350 }
        if flags & SiftFlag.inPackage != 0 { score -= 300 }
        if flags & SiftFlag.hidden != 0 { score -= 200 }
        score -= 5 * min(Int(store.depth[i]), 16)
        let value = Int32(clamping: score)
        return Ranked(id: id, score: value)
    }
    private static func matchHot(_ pointer: UnsafePointer<HotAtom>, id: UInt32, plan: SearchPlan, options: SearchOptions, store: IndexStore, scratch: SearchScratch, scoreNeeded: Bool, isCancelled: () -> Bool) -> AtomMatch {
        let atom = pointer.pointee, i = Int(id)
        // Reject cheap SoA filters before loading offsets or touching name bytes.
        switch atom.tag {
        case .ext:
            if atom.extKindMask != 0 && atom.extKindMask & (1 << store.kind[i]) == 0 {
                return AtomMatch(matched: false, baseScore: 0, needleLength: 0)
            }
        case .path:
            if let mask = atom.pathMask { return AtomMatch(matched: mask[i] != 0, baseScore: 0, needleLength: 0) }
        case .kind: return AtomMatch(matched: store.kind[i] == UInt8(atom.lower), baseScore: 0, needleLength: 0)
        case .filesOnly: return AtomMatch(matched: store.kind[i] != 1, baseScore: 0, needleLength: 0)
        case .foldersOnly: return AtomMatch(matched: store.kind[i] == 1, baseScore: 0, needleLength: 0)
        default: break
        }
        let name = UnsafeBufferPointer(start: store.names.advanced(by: Int(store.nameOff[i])), count: Int(store.nameOff[i+1] - store.nameOff[i]))
        switch atom.tag {
        case .name:
            let match = matchNameHot(name, needle: UnsafeBufferPointer(start: atom.bytes, count: atom.length), cs: atom.flag, ascii: atom.ascii, id: id, pinyin: options.pinyin, store: store, scratch: scratch, scoreNeeded: scoreNeeded)
            if atom.excludesAncestors && !match.0 {
                if atom.excludesRootAncestor || sift_has_ancestor(id, store.parent, store.names, store.nameOff, atom.bytes, atom.length) != 0 {
                    return AtomMatch(matched: true, baseScore: 0, needleLength: 0)
                }
                if !atom.ascii {
                    var parent = store.parent[i]
                    while parent != 0 {
                        let begin = lowerBound(store.altOwner, store.altCount, parent), end = lowerBound(store.altOwner, store.altCount, parent &+ 1)
                        for a in begin..<end where Int(store.altOff[a+1] - store.altOff[a]) == atom.length {
                            if sift_equals(store.altNames.advanced(by: Int(store.altOff[a])), atom.length, atom.bytes, atom.length, 0) != 0 { return AtomMatch(matched: true, baseScore: 0, needleLength: 0) }
                        }
                        parent = store.parent[Int(parent)]
                    }
                }
            }
            return AtomMatch(matched: match.0, baseScore: match.1, needleLength: match.2)
        case .fileName:
            if store.kind[i] == 1 { return AtomMatch(matched: false, baseScore: 0, needleLength: 0) }
            let match = matchNameHot(name, needle: UnsafeBufferPointer(start: atom.bytes, count: atom.length), cs: false, ascii: atom.ascii, id: id, pinyin: options.pinyin, store: store, scratch: scratch, scoreNeeded: scoreNeeded)
            return AtomMatch(matched: match.0, baseScore: match.1, needleLength: match.2)
        case .folderName:
            if store.kind[i] != 1 { return AtomMatch(matched: false, baseScore: 0, needleLength: 0) }
            let match = matchNameHot(name, needle: UnsafeBufferPointer(start: atom.bytes, count: atom.length), cs: false, ascii: atom.ascii, id: id, pinyin: options.pinyin, store: store, scratch: scratch, scoreNeeded: scoreNeeded)
            return AtomMatch(matched: match.0, baseScore: match.1, needleLength: match.2)
        case .path: return AtomMatch(matched: atom.pathMask.map { $0[i] != 0 } ?? matchPathHot(atom.components, atom.componentCount, id: id, store: store), baseScore: 0, needleLength: 0)
        case .glob:
            if atom.flag { buildPath(id, store: store, root: plan.rootBytes, into: &scratch.path) }
            let hit = atom.flag ? scratch.path.withUnsafeBufferPointer { sift_glob_match(atom.bytes, atom.length, $0.baseAddress, $0.count, 0) != 0 } : sift_glob_match(atom.bytes, atom.length, name.baseAddress, name.count, 0) != 0
            return AtomMatch(matched: hit, baseScore: 0, needleLength: 0)
        case .regex:
            if atom.flag { buildPath(id, store: store, root: plan.rootBytes, into: &scratch.path) }
            if atom.length > 0 {
                let hasPrefix = atom.flag ? scratch.path.withUnsafeBufferPointer { sift_has_prefix($0.baseAddress, $0.count, atom.bytes, atom.length, 1) != 0 } : sift_has_prefix(name.baseAddress, name.count, atom.bytes, atom.length, 1) != 0
                if !hasPrefix { return AtomMatch(matched: false, baseScore: 0, needleLength: 0) }
            }
            let value = atom.flag ? String(decoding: scratch.path, as: UTF8.self) : String(decoding: name, as: UTF8.self)
            let regex = plan.regexes[atom.regexIndex]
            let started = DispatchTime.now().uptimeNanoseconds
            var matched = false, stopped = false
            regex.enumerateMatches(in: value, options: [.reportProgress], range: NSRange(value.startIndex..., in: value)) { result, _, stop in
                if isCancelled() || DispatchTime.now().uptimeNanoseconds &- started >= 20_000_000 {
                    stopped = true
                    stop.pointee = true
                    return
                }
                if result != nil {
                    matched = true
                    stop.pointee = true
                }
            }
            if stopped || isCancelled() || DispatchTime.now().uptimeNanoseconds &- started >= 20_000_000 { return AtomMatch(matched: false, baseScore: 0, needleLength: 0, aborted: true) }
            return AtomMatch(matched: matched, baseScore: 0, needleLength: 0)
        case .ext:
            let key = Classifier.extensionKey(name)
            for j in 0..<atom.extCount { if atom.extKeys![j] == key { return AtomMatch(matched: true, baseScore: 0, needleLength: 0) } }
            return AtomMatch(matched: false, baseScore: 0, needleLength: 0)
        case .kind: return AtomMatch(matched: store.kind[i] == UInt8(atom.lower), baseScore: 0, needleLength: 0)
        case .filesOnly: return AtomMatch(matched: store.kind[i] != 1, baseScore: 0, needleLength: 0)
        case .foldersOnly: return AtomMatch(matched: store.kind[i] == 1, baseScore: 0, needleLength: 0)
        case .size: let size = store.size(id); return AtomMatch(matched: size >= atom.lower && size <= atom.upper, baseScore: 0, needleLength: 0)
        case .modified: let time = UInt64(store.mtime[i]); return AtomMatch(matched: time >= atom.lower && time <= atom.upper, baseScore: 0, needleLength: 0)
        }
    }
    private static func matchNameHot(_ name: UnsafeBufferPointer<UInt8>, needle: UnsafeBufferPointer<UInt8>, cs: Bool, ascii: Bool, id: UInt32, pinyin: Bool, store: IndexStore, scratch: SearchScratch, scoreNeeded: Bool) -> (Bool, Int, Int) {
        let quality = scoreNeeded ? sift_match_quality(name.baseAddress, name.count, needle.baseAddress, needle.count, cs ? 1 : 0) : (sift_contains(name.baseAddress, name.count, needle.baseAddress, needle.count, cs ? 1 : 0) != 0 ? 1 : 0)
        if quality > 0 { return (true, scoreNeeded ? Int(quality) * 200 + 200 : 0, needle.count) }
        if cs { return (false, 0, 0) }
        var nonASCII = false
        for byte in name where byte >= 128 { nonASCII = true; break }
        if !nonASCII { return (false, 0, 0) }
        if pinyin && ascii && Pinyin.shared.keys(for: name, full: &scratch.full, initials: &scratch.initials) {
            let full = scratch.full.withUnsafeBufferPointer { sift_contains($0.baseAddress, $0.count, needle.baseAddress, needle.count, 0) != 0 }
            let initials = scratch.initials.withUnsafeBufferPointer { sift_contains($0.baseAddress, $0.count, needle.baseAddress, needle.count, 0) != 0 }
            if full || initials {
                let prefix = scratch.full.withUnsafeBufferPointer { sift_has_prefix($0.baseAddress, $0.count, needle.baseAddress, needle.count, 0) != 0 } || scratch.initials.withUnsafeBufferPointer { sift_has_prefix($0.baseAddress, $0.count, needle.baseAddress, needle.count, 0) != 0 }
                return (true, scoreNeeded ? (prefix ? 500 : 350) : 0, needle.count)
            }
        }
        if !ascii {
            let a0 = lowerBound(store.altOwner, store.altCount, id), a1 = lowerBound(store.altOwner, store.altCount, id &+ 1)
            for a in a0..<a1 {
                let start = Int(store.altOff[a]), length = Int(store.altOff[a+1] - store.altOff[a])
                if sift_contains(store.altNames.advanced(by: start), length, needle.baseAddress, needle.count, 0) != 0 { return (true, scoreNeeded ? 350 : 0, needle.count) }
            }
        }
        return (false, 0, 0)
    }
    internal static func pathMatchesByWalking(_ components: [[UInt8]], id: UInt32, in store: IndexStore) -> Bool {
        let plan = SearchPlan()
        return matchPathHot(plan.spans(components), components.count, id: id, store: store)
    }
    private static func matchPathHot(_ components: UnsafePointer<ByteSpan>?, _ count: Int, id: UInt32, store: IndexStore) -> Bool {
        guard let components, count > 0 else { return false }
        if count == 1 {
            var e = id
            while true {
                let name = store.nameBytes(e)
                if sift_contains(name.baseAddress, name.count, components[0].bytes, components[0].count, 0) != 0 { return true }
                if e == 0 { return false }
                e = store.parent[Int(e)]
            }
        }
        var end = id
        while true {
            var e = end, okay = true
            for k in stride(from: count-1, through: 0, by: -1) {
                let component = components[k]
                if component.count > 0 {
                    let name = store.nameBytes(e)
                    let hit: Bool
                    if k == 0 { hit = sift_has_suffix(name.baseAddress, name.count, component.bytes, component.count, 0) != 0 }
                    else if k == count-1 { hit = sift_has_prefix(name.baseAddress, name.count, component.bytes, component.count, 0) != 0 }
                    else { hit = sift_equals(name.baseAddress, name.count, component.bytes, component.count, 0) != 0 }
                    if !hit { okay = false; break }
                }
                if k > 0 { if e == 0 { okay = false; break }; e = store.parent[Int(e)] }
            }
            if okay { return true }
            if end == 0 { return false }
            end = store.parent[Int(end)]
        }
    }

    private static func buildPath(_ id: UInt32, store: IndexStore, root: [UInt8], into out: inout [UInt8]) {
        if id == 0 { out.removeAll(keepingCapacity: true); out.append(contentsOf: root); return }
        let rootLength = store.rootPath == "/" ? 0 : root.count
        var total = rootLength, e = id
        while e != 0 { total += 1 + Int(store.nameOff[Int(e)+1] - store.nameOff[Int(e)]); e = store.parent[Int(e)] }
        out.removeAll(keepingCapacity: true)
        out.append(contentsOf: repeatElement(UInt8(0), count: total))
        out.withUnsafeMutableBufferPointer { bytes in
            var cursor = total, current = id
            while current != 0 {
                let name = store.nameBytes(current)
                cursor -= name.count
                if name.count > 0 { bytes.baseAddress!.advanced(by: cursor).update(from: name.baseAddress!, count: name.count) }
                cursor -= 1; bytes[cursor] = 47
                current = store.parent[Int(current)]
            }
            if rootLength > 0 { root.withUnsafeBufferPointer { bytes.baseAddress!.update(from: $0.baseAddress!, count: rootLength) } }
        }
    }

    private static func better(_ a: Ranked, _ b: Ranked, options: SearchOptions, store: IndexStore) -> Bool {
        switch options.sort {
        case .relevance: return a.score == b.score ? a.id < b.id : a.score > b.score
        case .name:
            let x = store.nameBytes(a.id), y = store.nameBytes(b.id)
            let cmp = sift_name_compare(x.baseAddress, x.count, y.baseAddress, y.count)
            return cmp == 0 ? a.id < b.id : (options.ascending ? cmp < 0 : cmp > 0)
        case .modified:
            let x = store.mtime[Int(a.id)], y = store.mtime[Int(b.id)]
            return x == y ? a.id < b.id : (options.ascending ? x < y : x > y)
        case .size:
            let x = store.size(a.id), y = store.size(b.id)
            return x == y ? a.id < b.id : (options.ascending ? x < y : x > y)
        }
    }
    private struct MergeHead { var block: Int; var position: Int; var entry: Ranked }
    private static func mergeTop(_ results: UnsafePointer<ChunkResult>, count: Int, limit: Int = 5000, options: SearchOptions, store: IndexStore) -> [Ranked] {
        var heap: [MergeHead] = [], top: [Ranked] = []
        heap.reserveCapacity(count); top.reserveCapacity(limit)
        func entry(_ block: Int, _ position: Int) -> Ranked {
            let result = results[block]
            return Ranked(id: result.items[position], score: result.scores.isEmpty ? 0 : result.scores[position])
        }
        for block in 0..<count where results[block].sortedCount > 0 {
            heap.append(MergeHead(block: block, position: 0, entry: entry(block, 0)))
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                if !better(heap[child].entry, heap[parent].entry, options: options, store: store) { break }
                heap.swapAt(child, parent); child = parent
            }
        }
        while !heap.isEmpty && top.count < limit {
            let head = heap[0]
            top.append(head.entry)
            let next = head.position + 1
            if next < min(limit, results[head.block].sortedCount) {
                heap[0] = MergeHead(block: head.block, position: next, entry: entry(head.block, next))
            } else {
                heap.swapAt(0, heap.count - 1); heap.removeLast()
            }
            var parent = 0
            while parent * 2 + 1 < heap.count {
                var child = parent * 2 + 1
                if child + 1 < heap.count && better(heap[child+1].entry, heap[child].entry, options: options, store: store) { child += 1 }
                if !better(heap[child].entry, heap[parent].entry, options: options, store: store) { break }
                heap.swapAt(parent, child); parent = child
            }
        }
        return top
    }
    private static func pushTop(_ entry: Ranked, limit: Int, heap: inout [Ranked], options: SearchOptions, store: IndexStore) {
        if heap.count < limit {
            heap.append(entry); var i = heap.count - 1
            while i > 0 { let parent = (i - 1) / 2; if !better(heap[parent], heap[i], options: options, store: store) { break }; heap.swapAt(parent, i); i = parent }
        } else if better(entry, heap[0], options: options, store: store) {
            heap[0] = entry; var i = 0
            while i * 2 + 1 < heap.count {
                var child = i * 2 + 1
                if child + 1 < heap.count && better(heap[child], heap[child+1], options: options, store: store) { child += 1 }
                if !better(heap[i], heap[child], options: options, store: store) { break }
                heap.swapAt(i, child); i = child
            }
        }
    }
    private static func bestK(_ entries: [Ranked], count: Int, options: SearchOptions, store: IndexStore, heap: inout [Ranked]) {
        heap.removeAll(keepingCapacity: true)
        heap.reserveCapacity(count)
        for entry in entries { pushTop(entry, limit: count, heap: &heap, options: options, store: store) }
        heap.sort { better($0, $1, options: options, store: store) }
    }
}
