import AppKit
import SwiftUI
import OilFindCore

public struct ApplicationMenuItem {
    public let title: String
    public let isVisible: Bool
    public let action: () -> Void

    public init(title: String, isVisible: Bool = true, action: @escaping () -> Void) {
        self.title = title; self.isVisible = isVisible; self.action = action
    }
}

/// Optional application integration, outside the search and indexing hot paths.
public protocol ApplicationExtension: AnyObject {
    #if DEBUG
    func prepareArguments(_ arguments: inout [String]) throws
    #endif
    func start(chinese: Bool, showSettings: @escaping () -> Void)
    func searchSources() -> [SearchSource]
    var supplementarySearchProvider: SupplementarySearchProvider? { get }
    var onSearchSourcesChange: (() -> Void)? { get set }
    var settingsMenuItem: ApplicationMenuItem? { get }
    var onSettingsMenuItemChange: (() -> Void)? { get set }
    func stop()
    func languageDidChange(chinese: Bool)
    func handle(_ url: URL)
    func settingsSection(window: @escaping () -> NSWindow?) -> AnyView
}

public extension ApplicationExtension {
    var settingsMenuItem: ApplicationMenuItem? { nil }
    var onSettingsMenuItemChange: (() -> Void)? { get { nil } set { } }
    var supplementarySearchProvider: SupplementarySearchProvider? { nil }
    func searchSources() -> [SearchSource] { [] }
    var onSearchSourcesChange: (() -> Void)? { get { nil } set { } }
}

#if DEBUG
public extension ApplicationExtension {
    func prepareArguments(_ arguments: inout [String]) throws { }
}
#endif
