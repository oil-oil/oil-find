import AppKit

/// Installation checks never launch an agent or treat leftover conversation data as an installation.
enum AITopicInstallation {
    static let bundleIdentifiers: [AITopicProvider: String] = [
        .claude: "com.anthropic.claudefordesktop", .codex: "com.openai.codex",
        .workbuddy: "com.tencent.workbuddy.mac"
    ]

    static func installed(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          environment: [String: String] = ProcessInfo.processInfo.environment,
                          application: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
                          executable: (URL) -> Bool = { url in
                              FileManager.default.isExecutableFile(atPath: url.path) && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                          }) -> Set<AITopicProvider> {
        let files = FileManager.default
        var result = Set(AITopicProvider.allCases.filter { provider in
            guard let id = bundleIdentifiers[provider], let url = application(id),
                  files.fileExists(atPath: url.path),
                  !url.resolvingSymlinksInPath().pathComponents.contains(where: { $0 == ".Trash" || $0 == ".Trashes" }) else { return false }
            return Bundle(url: url)?.bundleIdentifier == id
        })
        // Claude Code and Codex may be installed as CLIs without their desktop applications.
        guard !result.contains(.claude) || !result.contains(.codex) else { return result }
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        directories += [".local/bin", ".bun/bin", ".volta/bin", ".npm-global/bin", ".npm/bin", "bin"].map { home.appendingPathComponent($0).path }
        // GUI applications often inherit a PATH that omits Node version-manager installations.
        for (directory, suffix) in [(".nvm/versions/node", "bin"), (".local/share/fnm/node-versions", "installation/bin")] {
            let root = home.appendingPathComponent(directory)
            if let versions = try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                directories += versions.map { $0.appendingPathComponent(suffix).path }
            }
        }
        for (provider, command) in [(AITopicProvider.claude, "claude"), (.codex, "codex")] where !result.contains(provider) {
            if Set(directories).contains(where: { directory in
                let url = URL(fileURLWithPath: directory).appendingPathComponent(command).resolvingSymlinksInPath()
                return executable(url)
            }) { result.insert(provider) }
        }
        return result
    }
}
