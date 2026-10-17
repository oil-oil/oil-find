import AppKit

enum AITopicActions {
    static func desktopURL(_ topic: AITopic) -> URL? {
        if topic.provider == .codex { return topic.codexURL }
        if topic.provider == .workbuddy { return topic.workbuddyURL }
        guard topic.provider == .claude else { return nil }
        // The desktop's local session IDs are distinct from CLI UUIDs.
        guard topic.desktopID.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil else { return nil }
        // This route opens the local session directly, including archived sessions.
        var url = URLComponents(); url.scheme = "claude"; url.host = "claude.ai"; url.path = "/epitaxy/" + topic.desktopID
        return url.url
    }
    static func copyResume(_ topic: AITopic) {
        guard !topic.resumeCommand.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(topic.resumeCommand, forType: .string)
    }
    static func open(_ topic: AITopic) -> Bool {
        if let url = desktopURL(topic), NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            return NSWorkspace.shared.open(url)
        }
        if topic.provider == .workbuddy { return false }
        // A user's explicit Open action resumes the CLI in Terminal; it sends no prompt.
        guard UUID(uuidString: topic.id) != nil else { return false }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oilfind-resume", isDirectory: true)
        let script = directory.appendingPathComponent(UUID().uuidString + ".command")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let body = "#!/bin/zsh -l\n/bin/rm -- \"$0\"\n" + topic.resumeCommand + "\n"
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let opened = NSWorkspace.shared.open(script)
            if !opened { try? FileManager.default.removeItem(at: script) }
            return opened
        } catch { try? FileManager.default.removeItem(at: script); return false }
    }
}

final class AITopicIcons {
    private var images: [AITopicProvider: NSImage] = [:]
    static func bundledImage(_ provider: AITopicProvider, directories: [URL]? = nil) -> NSImage? {
        // SwiftPM's generated accessor misses Contents/Resources in a packaged macOS app.
        // Resolve both installed and SwiftPM layouts without its fatal build-path fallback.
        let locations = directories ?? [Bundle.main.resourceURL, Bundle.main.bundleURL,
                                       Bundle(for: AITopicIcons.self).bundleURL.deletingLastPathComponent()].compactMap { $0 }
        for directory in locations {
            let url = directory.appendingPathComponent("OilFind_OilFindApp.bundle")
            if let bundle = Bundle(url: url),
               let imageURL = bundle.url(forResource: provider.rawValue, withExtension: "png", subdirectory: "Resources/TopicIcons"),
               let image = NSImage(contentsOf: imageURL) { return image }
        }
        return nil
    }
    func image(_ provider: AITopicProvider) -> NSImage {
        if let image = images[provider] { return image }
        let identifier = AITopicInstallation.bundleIdentifiers[provider]!
        let image: NSImage
        if provider != .codex, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            image = NSWorkspace.shared.icon(forFile: app.path)
        } else if let asset = Self.bundledImage(provider) {
            image = asset
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            image = NSWorkspace.shared.icon(forFile: app.path)
        } else { image = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: provider.name)! }
        images[provider] = image; return image
    }
}
