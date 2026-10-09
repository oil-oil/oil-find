import OilFindCore
import Foundation

/// A submitted query snapshot. The single-store path keeps its original arrays.
final class SearchPresentation {
    let single: SearchResult?
    let multiple: MultiSearchResult?
    let createdAt: Date
    init(_ result: SearchResult) { single = result; multiple = nil; createdAt = result.createdAt }
    init(_ result: MultiSearchResult) { single = nil; multiple = result; createdAt = result.createdAt }
    var query: Query { single?.query ?? multiple!.query }
    var total: Int { single?.total ?? multiple!.total }
    var sortedCount: Int { single?.sortedCount ?? multiple!.sortedCount }
    var elapsedMs: Double { single?.elapsedMs ?? multiple!.elapsedMs }
    var count: Int { single?.items.count ?? multiple!.items.count }
    var store: IndexStore { single?.store ?? multiple!.sources[0].store }
    var sources: [SearchSource] {
        single.map { [SearchSource(id: "startup", displayName: "", isOnline: true, store: $0.store)] } ?? multiple!.sources
    }
    func row(_ index: Int) -> (source: SearchSource, id: UInt32)? {
        guard index >= 0, index < count else { return nil }
        if let single { return (SearchSource(id: "startup", displayName: "", isOnline: true, store: single.store), single.items[index]) }
        let hit = multiple!.items[index]
        return (multiple!.sources[hit.sourceIndex], hit.entryID)
    }
    func index(sourceID: String, store: IndexStore, id: UInt32, path: String) -> Int? {
        guard let source = sources.first(where: { $0.id == sourceID }) else { return nil }
        let resolved: UInt32? = source.store === store ? id : source.store.read { source.store.hashReady ? source.store.resolve(path: path) : nil }
        guard let resolved else { return nil }
        if let single { return single.items.firstIndex(of: resolved) }
        return multiple!.items.firstIndex { multiple!.sources[$0.sourceIndex].id == sourceID && $0.entryID == resolved }
    }
    func sameRows(as other: SearchPresentation) -> Bool {
        if let single, let rhs = other.single { return single.store === rhs.store && single.items == rhs.items }
        guard count == other.count else { return false }
        for i in 0..<count {
            guard let a = row(i), let b = other.row(i), a.source.id == b.source.id, a.source.store === b.source.store, a.id == b.id else { return false }
        }
        return true
    }
    func sameMetadata(as other: SearchPresentation) -> Bool {
        let a = sources, b = other.sources
        guard a.count == b.count else { return false }
        let versions = single.map { [$0.storeVersion] } ?? multiple!.results.map(\.storeVersion)
        let rhs = other.single.map { [$0.storeVersion] } ?? other.multiple!.results.map(\.storeVersion)
        return zip(a, b).allSatisfy { $0.id == $1.id && $0.store === $1.store && $0.isOnline == $1.isOnline && $0.displayName == $1.displayName } && versions == rhs
    }
    func isCurrent(_ current: [SearchSource]) -> Bool {
        let captured = sources
        guard captured.count == current.count else { return false }
        let versions = single.map { [$0.storeVersion] } ?? multiple!.results.map(\.storeVersion)
        return captured.indices.allSatisfy { i in
            captured[i].id == current[i].id && captured[i].store === current[i].store && captured[i].isOnline == current[i].isOnline && captured[i].displayName == current[i].displayName && current[i].store.read { current[i].store.version == versions[i] }
        }
    }
}
