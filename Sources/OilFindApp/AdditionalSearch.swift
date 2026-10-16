import AppKit
import OilFindCore

public struct AdditionalSearchAction {
    public enum Kind { case open, copy, copyName }
    public let kind: Kind
    public let title: String
    public let perform: (@escaping (Bool) -> Void) -> Void
    public init(kind: Kind, title: String, perform: @escaping (@escaping (Bool) -> Void) -> Void) {
        self.kind = kind; self.title = title; self.perform = perform
    }
}

/// Non-file results share the host list without pretending to be filesystem entries.
public struct AdditionalSearchItem {
    public let id: String
    public let title: String
    public let detail: String
    public let location: String
    public let modified: Date
    public let icon: NSImage
    public let relevance: Int32
    /// Optional provider-owned scope used to remove items when only part of a provider is disabled.
    public let availabilityScope: String?
    private let preparedActions: [AdditionalSearchAction]
    private let actionBuilder: (() -> [AdditionalSearchAction])?
    public var actions: [AdditionalSearchAction] { actionBuilder?() ?? preparedActions }
    public init(id: String, title: String, detail: String, location: String, modified: Date, icon: NSImage,
                relevance: Int32 = 0, availabilityScope: String? = nil, actions: [AdditionalSearchAction]) {
        self.id = id; self.title = title; self.detail = detail; self.location = location
        self.modified = modified; self.icon = icon; self.relevance = relevance; self.availabilityScope = availabilityScope
        preparedActions = actions; actionBuilder = nil
    }
    init(id: String, title: String, detail: String, location: String, modified: Date, icon: NSImage,
         relevance: Int32 = 0, availabilityScope: String? = nil, actions: @escaping () -> [AdditionalSearchAction]) {
        self.id = id; self.title = title; self.detail = detail; self.location = location
        self.modified = modified; self.icon = icon; self.relevance = relevance; self.availabilityScope = availabilityScope
        preparedActions = []; actionBuilder = actions
    }
}

public protocol AdditionalSearchProvider: AnyObject {
    var isEnabled: Bool { get }
    var title: String { get }
    var placeholder: String { get }
    var status: String? { get }
    var onChange: (() -> Void)? { get set }
    /// Returns the currently available subset of a previously displayed result collection.
    func availableItems(from items: [AdditionalSearchItem]) -> [AdditionalSearchItem]
    /// Prepared on the main thread; work runs alongside file search and returns the complete matching collection.
    func prepareSearch(_ query: Query, isCancelled: @escaping () -> Bool) -> () throws -> [AdditionalSearchItem]
    func visibilityChanged(_ visible: Bool)
    func backgroundIndexingChanged(_ busy: Bool)
}
public extension AdditionalSearchProvider {
    var placeholder: String { title }
    var status: String? { nil }
    func availableItems(from items: [AdditionalSearchItem]) -> [AdditionalSearchItem] { isEnabled ? items : [] }
    func backgroundIndexingChanged(_ busy: Bool) { }
}
