#if DEBUG
import AppKit
import OilFindCore

// An isolated exercise uses the production client, verifier, installer and relauncher.
enum UpdateExercise {
    static func handles(_ arguments: [String]) -> Bool {
        arguments.contains("--update-e2e") || arguments.contains("--update-e2e-restarted")
    }
    static func start(_ arguments: [String]) throws {
        func value(_ flag: String) throws -> String {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { throw UpdateFailure.other }
            return arguments[index + 1]
        }
        let restarted = arguments.contains("--update-e2e-restarted")
        let output = URL(fileURLWithPath: try value(restarted ? "--update-e2e-restarted" : "--update-e2e"))
        let application = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
        guard application.path.hasPrefix(temporary), output.resolvingSymlinksInPath().path.hasPrefix(temporary) else { throw UpdateFailure.permission }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if restarted {
            SystemUpdateFiles().registerLaunch(application: application, current: UpdateManager.current)
            if arguments.contains("--fail-new-startup"), UpdateManager.current.version.text == "1.3.0" { exit(23) }
            let failure = SystemUpdateFiles().cleanupAfterLaunch(application: application, current: UpdateManager.current)
            try write(output, phase: "restarted", failure: failure)
            exit(0)
        }
        guard let url = URL(string: try value("--manifest")) else { throw UpdateFailure.other }
        Task { @MainActor in
            var archive: URL?
            defer { if let archive { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) } }
            do {
                let client = UpdateClient(version: UpdateManager.current.version.text, manifestURL: url, allowLocalhost: true)
                let manifest = try await client.check()
                // Do not bypass eligibility to exercise an older manifest.
                guard manifest.release > UpdateManager.current, manifest.supports(ProcessInfo.processInfo.operatingSystemVersion) else { throw UpdateFailure.other }
                let downloaded = try await client.download(manifest) { _ in }
                archive = downloaded
                let installation = try await Task.detached {
                    try UpdateInstaller(application: application, current: UpdateManager.current).install(archive: downloaded, manifest: manifest)
                }.value
                do {
                    var restartArguments = ["--update-e2e-restarted", output.path]
                    if arguments.contains("--fail-new-startup") { restartArguments.append("--fail-new-startup") }
                    try UpdateRelauncher().startWaiting(for: ProcessInfo.processInfo.processIdentifier, installation: installation, arguments: restartArguments)
                } catch {
                    try UpdateInstaller(application: application, current: UpdateManager.current).rollback(installation)
                    throw UpdateFailure.other
                }
                try write(output, phase: "restarting")
            } catch {
                try? write(output, phase: "failed", failure: (error as? UpdateFailure) ?? .other)
            }
            if let archive { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
            archive = nil
            app.terminate(nil)
        }
    }
    private static func write(_ output: URL, phase: String, failure: UpdateFailure? = nil) throws {
        var record: [String: Any] = ["phase": phase, "version": UpdateManager.current.version.text, "build": UpdateManager.current.build,
                                   "pid": ProcessInfo.processInfo.processIdentifier]
        if let failure { record["reason"] = failure.rawValue }
        record["signatureValid"] = (try? SystemUpdateSignature().validate(Bundle.main.bundleURL)) != nil
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
    }
}
#endif
