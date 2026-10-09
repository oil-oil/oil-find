import AppKit
import SwiftUI

/// Optional application integration, outside the search and indexing hot paths.
public protocol ApplicationExtension: AnyObject {
    #if DEBUG
    func prepareArguments(_ arguments: inout [String]) throws
    #endif
    func start(chinese: Bool, showSettings: @escaping () -> Void)
    func stop()
    func languageDidChange(chinese: Bool)
    func handle(_ url: URL)
    func settingsSection(window: @escaping () -> NSWindow?) -> AnyView
}

#if DEBUG
public extension ApplicationExtension {
    func prepareArguments(_ arguments: inout [String]) throws { }
}
#endif
