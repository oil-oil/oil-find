import OilFindCore
import Foundation
import COilFind

/// A submitted query snapshot. The single-store path keeps its original arrays.
final class SearchPresentation {
    let single: SearchResult?
    let multiple: MultiSearchResult?
    private var supplementedRows: [(source: SearchSource, id: UInt32)]?
    private var details: [String: [UInt32: SupplementaryHit]] = [:]
    private var additionalItems: [AdditionalSearchItem] = []
    private var mixedRows: [Int]?
    private var additionalElapsedMs: Double = 0
    private let submittedQuery: Query
    let createdAt: Date
    init(_ result: SearchResult) { single = result; multiple = nil; submittedQuery = result.query; createdAt = result.createdAt }
    init(_ result: MultiSearchResult) { single = nil; multiple = result; submittedQuery = result.query; createdAt = result.createdAt }
    init(query: Query) { single = nil; multiple = nil; submittedQuery = query; createdAt = Date() }
    var query: Query { submittedQuery }
    private var fileCount: Int { supplementedRows?.count ?? single?.items.count ?? multiple?.items.count ?? 0 }
    var total: Int { (supplementedRows?.count ?? single?.total ?? multiple?.total ?? 0) + additionalItems.count }
    var sortedCount: Int { (supplementedRows?.count ?? single?.sortedCount ?? multiple?.sortedCount ?? 0) + additionalItems.count }
    var elapsedMs: Double { max(single?.elapsedMs ?? multiple?.elapsedMs ?? 0, additionalElapsedMs) }
    var count: Int { mixedRows?.count ?? fileCount }
    var store: IndexStore? { single?.store ?? multiple?.sources.first?.store }
    var sources: [SearchSource] {
        single.map { [SearchSource(id: "startup", displayName: "", isOnline: true, store: $0.store)] } ?? multiple?.sources ?? []
    }
    private func fileRow(_ index: Int) -> (source: SearchSource, id: UInt32)? {
        guard index >= 0, index < fileCount else { return nil }
        if let supplementedRows { return supplementedRows[index] }
        if let single { return (SearchSource(id: "startup", displayName: "", isOnline: true, store: single.store), single.items[index]) }
        guard let multiple else { return nil }
        let hit = multiple.items[index]
        return (multiple.sources[hit.sourceIndex], hit.entryID)
    }
    func row(_ index: Int) -> (source: SearchSource, id: UInt32)? {
        guard index >= 0, index < count else { return nil }
        return fileRow(mixedRows?[index] ?? index)
    }
    func additional(at index: Int) -> AdditionalSearchItem? {
        guard let mixedRows, mixedRows.indices.contains(index), mixedRows[index] < 0 else { return nil }
        return additionalItems[-mixedRows[index] - 1]
    }
    func index(additionalID: String) -> Int? {
        guard let i = additionalItems.firstIndex(where: { $0.id == additionalID }) else { return nil }
        return mixedRows?.firstIndex(of: -i - 1)
    }
    private func copyFiles() -> SearchPresentation {
        let result = single.map(SearchPresentation.init) ?? multiple.map(SearchPresentation.init) ?? SearchPresentation(query: query)
        result.supplementedRows = supplementedRows; result.details = details
        return result
    }
    func including(_ items: [AdditionalSearchItem], options: SearchOptions, elapsedMs: Double = 0) -> SearchPresentation {
        let result = copyFiles(); result.additionalElapsedMs = elapsedMs
        guard !items.isEmpty else { return result }
        let sort = query.isEmpty ? SortKey.modified : options.sort
        let ascending = !query.isEmpty && options.ascending
        var sourceScores: [String: [UInt32: Int32]] = [:]
        if sort == .relevance, let multiple {
            for (i, source) in multiple.sources.enumerated() {
                sourceScores[source.id] = Dictionary(uniqueKeysWithValues: zip(multiple.results[i].items, multiple.results[i].scores))
            }
        }
        func fileScore(_ i: Int) -> Int32 {
            if let single { return i < single.scores.count ? single.scores[i] : 0 }
            guard let row = fileRow(i) else { return 0 }; return sourceScores[row.source.id]?[row.id] ?? 0
        }
        func extraBefore(_ a: AdditionalSearchItem, _ b: AdditionalSearchItem) -> Bool {
            switch sort {
            case .name:
                let x = Array(a.title.utf8), y = Array(b.title.utf8)
                let cmp = x.withUnsafeBufferPointer { a in y.withUnsafeBufferPointer { b in sift_name_compare(a.baseAddress, a.count, b.baseAddress, b.count) } }
                if cmp != 0 { return ascending ? cmp < 0 : cmp > 0 }
            case .modified, .relevance:
                if sort == .relevance && a.relevance != b.relevance { return a.relevance > b.relevance }
                if a.modified != b.modified { return ascending ? a.modified < b.modified : a.modified > b.modified }
            case .size: break
            }
            return a.id < b.id
        }
        result.additionalItems = items.sorted(by: extraBefore)
        func beforeFile(_ extra: AdditionalSearchItem, _ i: Int) -> Bool {
            guard let row = fileRow(i) else { return true }
            return row.source.store.read {
                guard Int(row.id) < row.source.store.count, row.source.store.isLive(row.id) else { return false }
                switch sort {
                case .name:
                    let a = Array(extra.title.utf8), b = row.source.store.nameBytes(row.id)
                    let cmp = a.withUnsafeBufferPointer { sift_name_compare($0.baseAddress, $0.count, b.baseAddress, b.count) }
                    return ascending ? cmp < 0 : cmp > 0
                case .modified:
                    let time = row.source.store.modified(row.id)
                    return ascending ? extra.modified < time : extra.modified > time
                case .size: return ascending && row.source.store.size(row.id) > 0
                case .relevance: return extra.relevance > fileScore(i)
                }
            }
        }
        var rows: [Int] = []; rows.reserveCapacity(fileCount + items.count)
        var file = 0
        for (i, item) in result.additionalItems.enumerated() {
            while file < fileCount && !beforeFile(item, file) { rows.append(file); file += 1 }
            rows.append(-i - 1)
        }
        rows.append(contentsOf: file..<fileCount); result.mixedRows = rows
        return result
    }
    func withoutAdditional() -> SearchPresentation { copyFiles() }
    var hasAdditional: Bool { !additionalItems.isEmpty }
    func removingUnavailableAdditionalItems(using provider: AdditionalSearchProvider, options: SearchOptions) -> SearchPresentation? {
        guard hasAdditional else { return nil }
        let available = provider.availableItems(from: additionalItems)
        guard available.count < additionalItems.count else { return nil }
        return including(available, options: options)
    }
    func detail(at index: Int) -> SupplementaryHit? {
        guard let row = row(index) else { return nil }; return details[row.source.id]?[row.id]
    }
    func supplement(_ hits: [SupplementaryHit], options: SearchOptions) -> SearchPresentation {
        let captured = sources
        let versions = single.map { [$0.storeVersion] } ?? multiple?.results.map(\.storeVersion) ?? []
        let sourceVersions = Dictionary(uniqueKeysWithValues: zip(captured.map(\.id), versions))
        func mergeLocked(_ position: Int) -> SearchPresentation {
            if position < captured.count { return captured[position].store.read { mergeLocked(position + 1) } }
            let result = copyFiles()
            var rows = (0..<count).compactMap { row($0) }
            var seen = Dictionary(grouping: rows, by: { $0.source.id }).mapValues { Set($0.map(\.id)) }
            var extra: [(source: SearchSource, id: UInt32)] = []
            for hit in hits {
                if let version = hit.sourceVersion, sourceVersions[hit.sourceID] != version { continue }
                guard let source = sources.first(where: { $0.id == hit.sourceID }), Int(hit.entryID) < source.store.count && source.store.isLive(hit.entryID) else { continue }
                result.details[source.id, default: [:]][hit.entryID] = hit
                if seen[source.id, default: []].insert(hit.entryID).inserted { extra.append((source, hit.entryID)) }
            }
            func better(_ a: (source: SearchSource, id: UInt32), _ b: (source: SearchSource, id: UInt32)) -> Bool {
                switch options.sort {
                case .name:
                    let x = a.source.store.nameBytes(a.id), y = b.source.store.nameBytes(b.id)
                    let cmp = sift_name_compare(x.baseAddress, x.count, y.baseAddress, y.count)
                    if cmp != 0 { return options.ascending ? cmp < 0 : cmp > 0 }
                case .size:
                    let x = a.source.store.size(a.id), y = b.source.store.size(b.id)
                    if x != y { return options.ascending ? x < y : x > y }
                case .modified, .relevance:
                    let x = a.source.store.mtime[Int(a.id)], y = b.source.store.mtime[Int(b.id)]
                    if x != y { return options.sort != .relevance && options.ascending ? x < y : x > y }
                }
                return a.source.id == b.source.id ? a.id < b.id : a.source.id < b.source.id
            }
            extra.sort(by: better); rows.append(contentsOf: extra)
            if options.sort != .relevance { rows.sort(by: better) }
            result.supplementedRows = rows; return result
        }
        return mergeLocked(0)
    }
    var hasSupplements: Bool { supplementedRows != nil }
    func withoutSupplements() -> SearchPresentation {
        let base = single.map(SearchPresentation.init) ?? multiple.map(SearchPresentation.init) ?? SearchPresentation(query: query)
        return base.including(additionalItems, options: single?.options ?? multiple?.results.first?.options ?? SearchOptions())
    }
    func index(sourceID: String, store: IndexStore, id: UInt32, path: String) -> Int? {
        guard let source = sources.first(where: { $0.id == sourceID }) else { return nil }
        let resolved: UInt32? = source.store === store ? id : source.store.read { source.store.hashReady ? source.store.resolve(path: path) : nil }
        guard let resolved else { return nil }
        let position: Int?
        if let supplementedRows { position = supplementedRows.firstIndex { $0.source.id == sourceID && $0.id == resolved } }
        else if let single { position = single.items.firstIndex(of: resolved) }
        else { position = multiple?.items.firstIndex { multiple!.sources[$0.sourceIndex].id == sourceID && $0.entryID == resolved } }
        return position.flatMap { mixedRows?.firstIndex(of: $0) ?? $0 }

    }
    func sameRows(as other: SearchPresentation) -> Bool {
        if mixedRows == nil, other.mixedRows == nil, supplementedRows == nil, other.supplementedRows == nil, let single, let rhs = other.single { return single.store === rhs.store && single.items == rhs.items }
        guard count == other.count else { return false }
        for i in 0..<count {
            if let a = additional(at: i) { if a.id != other.additional(at: i)?.id { return false }; continue }
            guard let a = row(i), let b = other.row(i), a.source.id == b.source.id, a.source.store === b.source.store, a.id == b.id else { return false }
        }
        return true
    }
    func sameMetadata(as other: SearchPresentation) -> Bool {
        guard !hasAdditional && !other.hasAdditional && details.isEmpty && other.details.isEmpty else { return false }
        let a = sources, b = other.sources
        guard a.count == b.count else { return false }
        let versions = single.map { [$0.storeVersion] } ?? multiple?.results.map(\.storeVersion) ?? []
        let rhs = other.single.map { [$0.storeVersion] } ?? other.multiple?.results.map(\.storeVersion) ?? []
        return zip(a, b).allSatisfy { $0.id == $1.id && $0.store === $1.store && $0.isOnline == $1.isOnline && $0.displayName == $1.displayName } && versions == rhs
    }
    func isCurrent(_ current: [SearchSource]) -> Bool {
        if single == nil && multiple == nil { return true }
        let captured = sources
        guard captured.count == current.count else { return false }
        let versions = single.map { [$0.storeVersion] } ?? multiple?.results.map(\.storeVersion) ?? []
        return captured.indices.allSatisfy { i in
            captured[i].id == current[i].id && captured[i].store === current[i].store && captured[i].isOnline == current[i].isOnline && captured[i].displayName == current[i].displayName && current[i].store.read { current[i].store.version == versions[i] }
        }
    }
}
