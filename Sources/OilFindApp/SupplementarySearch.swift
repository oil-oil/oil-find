import AppKit
import OilFindCore

/// Additional matches refer to entries in the captured source snapshot.
public struct SupplementaryHit {
    public let sourceID: String
    public let entryID: UInt32
    public let sourceVersion: UInt64?
    private let decoration: () -> (text: String, highlights: [NSRange])
    public var presentation: (text: String, highlights: [NSRange]) { decoration() }
    public var detail: String { decoration().text }
    public var highlights: [NSRange] { decoration().highlights }
    public let thumbnail: Bool
    public init(sourceID: String, entryID: UInt32, detail: String, highlights: [NSRange] = [], thumbnail: Bool = false, sourceVersion: UInt64? = nil) {
        self.sourceVersion = sourceVersion
        self.sourceID = sourceID; self.entryID = entryID; self.decoration = { (detail, highlights) }; self.thumbnail = thumbnail
    }
    public init(sourceID: String, entryID: UInt32, thumbnail: Bool = false, sourceVersion: UInt64? = nil, presentation: @escaping () -> (text: String, highlights: [NSRange])) {
        self.sourceVersion = sourceVersion
        self.sourceID = sourceID; self.entryID = entryID; self.thumbnail = thumbnail; decoration = presentation
    }
}
public protocol SupplementarySearchProvider: AnyObject {
    var isEnabled: Bool { get }
    /// Called on the main thread; returned work runs concurrently with the name search.
    func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit]
    func sourcesDidChange(_ sources: [SearchSource])
    func userActivity(visible: Bool, typing: Bool)
    /// Background work should yield while the primary index is loading or rebuilding.
    func backgroundIndexingChanged(_ busy: Bool)
}
public extension SupplementarySearchProvider {
    func backgroundIndexingChanged(_ busy: Bool) { }
}
