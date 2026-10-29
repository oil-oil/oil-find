import Foundation
import CryptoKit
import Security

public protocol UpdateFileOperations {
    func isWritableApplication(_ app: URL) -> Bool
    func createWorkspace(beside app: URL) throws -> URL
    func verifyArchive(_ archive: URL, manifest: UpdateManifest) throws
    func extractArchive(_ archive: URL, into workspace: URL) throws -> URL
    func version(of app: URL) throws -> UpdateVersion
    func move(_ source: URL, to destination: URL) throws
    func remove(_ url: URL) throws
    func writeReceipt(_ installation: UpdateInstallation, manifest: UpdateManifest) throws
}

public protocol UpdateSignatureValidating {
    func validate(_ app: URL) throws
}

public struct UpdateInstallation {
    public let target: URL
    public let workspace: URL
    public var backup: URL { workspace.appendingPathComponent("previous.app") }
}

public final class UpdateInstaller {
    private let files: UpdateFileOperations
    private let signature: UpdateSignatureValidating
    public let current: UpdateVersion
    public let application: URL
    public init(application: URL, current: UpdateVersion, files: UpdateFileOperations = SystemUpdateFiles(), signature: UpdateSignatureValidating = SystemUpdateSignature()) {
        self.application = application; self.current = current; self.files = files; self.signature = signature
    }
    public func install(archive: URL, manifest: UpdateManifest) throws -> UpdateInstallation {
        guard manifest.release > current else { throw UpdateFailure.other }
        try files.verifyArchive(archive, manifest: manifest)
        guard files.isWritableApplication(application) else { throw UpdateFailure.permission }
        let workspace: URL
        do { workspace = try files.createWorkspace(beside: application) }
        catch { throw UpdateFailure.permission }
        let installation = UpdateInstallation(target: application, workspace: workspace)
        var preserve = false, movedOld = false
        defer { if !preserve { try? files.remove(workspace) } }
        do {
            let candidate = try files.extractArchive(archive, into: workspace)
            try signature.validate(candidate)
            let version = try files.version(of: candidate)
            guard version > current, version == manifest.release else { throw UpdateFailure.other }
            // Persist the receipt before the first destructive operation.
            try files.writeReceipt(installation, manifest: manifest)
            try files.move(application, to: installation.backup); movedOld = true
            try files.move(candidate, to: application)
            preserve = true
            return installation
        } catch {
            if movedOld {
                do { try files.move(installation.backup, to: application) }
                catch { preserve = true; throw UpdateFailure.other }
            }
            throw (error as? UpdateFailure) ?? .other
        }
    }
    public func rollback(_ installation: UpdateInstallation) throws {
        let rejected = installation.workspace.appendingPathComponent("rejected.app")
        try files.move(installation.target, to: rejected)
        do { try files.move(installation.backup, to: installation.target) }
        catch {
            try? files.move(rejected, to: installation.target)
            throw UpdateFailure.other
        }
        try? files.remove(installation.workspace)
    }
}

protocol UpdateCodeSigning {
    func runningDesignatedRequirement() -> SecRequirement?
    func requirement(from source: String) -> SecRequirement?
    func validate(_ app: URL, against requirement: SecRequirement) -> Bool
}

struct SystemUpdateCodeSigning: UpdateCodeSigning {
    func runningDesignatedRequirement() -> SecRequirement? {
        var running: SecCode?, runningStatic: SecStaticCode?, requirement: SecRequirement?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &runningStatic) == errSecSuccess, let runningStatic,
              SecCodeCopyDesignatedRequirement(runningStatic, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }
    func requirement(from source: String) -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(source as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }
    func validate(_ app: URL, against requirement: SecRequirement) -> Bool {
        var candidate: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate else { return false }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(candidate, flags, requirement) == errSecSuccess
    }
}

public final class SystemUpdateSignature: UpdateSignatureValidating {
    static let developerIDRequirement = "identifier \"com.oiloil.find\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = \"4NZ3X494AF\""
    private let codeSigning: UpdateCodeSigning
    public init() { codeSigning = SystemUpdateCodeSigning() }
    init(codeSigning: UpdateCodeSigning) { self.codeSigning = codeSigning }
    public func validate(_ app: URL) throws {
        if let running = codeSigning.runningDesignatedRequirement(), codeSigning.validate(app, against: running) { return }
        guard let developerID = codeSigning.requirement(from: Self.developerIDRequirement),
              codeSigning.validate(app, against: developerID) else { throw UpdateFailure.signature }
    }
}

public struct SystemUpdateFiles: UpdateFileOperations {
    private let fm = FileManager.default
    public init() {}
    public func isWritableApplication(_ app: URL) -> Bool {
        fm.isWritableFile(atPath: app.path) && fm.isWritableFile(atPath: app.deletingLastPathComponent().path)
            && (try? app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
    }
    public func createWorkspace(beside app: URL) throws -> URL {
        let directory = app.deletingLastPathComponent().appendingPathComponent(".oilfind-update-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }
    public func verifyArchive(_ archive: URL, manifest: UpdateManifest) throws {
        guard let attributes = try? fm.attributesOfItem(atPath: archive.path),
              (attributes[.size] as? NSNumber)?.int64Value == manifest.size,
              let file = try? FileHandle(forReadingFrom: archive) else { throw UpdateFailure.integrity }
        defer { try? file.close() }
        var hash = SHA256()
        do {
            while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        } catch { throw UpdateFailure.integrity }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.sha256 else { throw UpdateFailure.integrity }
    }
    public func extractArchive(_ archive: URL, into workspace: URL) throws -> URL {
        // This app has no symlinks. Reject traversal and links before invoking ditto.
        let entries = try process("/usr/bin/zipinfo", ["-1", archive.path]).split(separator: "\n")
        guard !entries.isEmpty, entries.allSatisfy({ entry in
            let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
            return !entry.hasPrefix("/") && !parts.contains("..") && !entry.contains("\\")
                && (parts.first == "Oil Find.app" || parts.first == "__MACOSX")
        }), !((try process("/usr/bin/zipinfo", ["-l", archive.path])).split(separator: "\n").contains { $0.first == "l" }) else { throw UpdateFailure.integrity }
        let extraction = workspace.appendingPathComponent("unpacked", isDirectory: true)
        try fm.createDirectory(at: extraction, withIntermediateDirectories: false)
        _ = try process("/usr/bin/ditto", ["-x", "-k", archive.path, extraction.path])
        let app = extraction.appendingPathComponent("Oil Find.app", isDirectory: true)
        guard fm.fileExists(atPath: app.path), (try? app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { throw UpdateFailure.integrity }
        return app
    }
    public func version(of app: URL) throws -> UpdateVersion {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == "com.oiloil.find",
              let version = plist["CFBundleShortVersionString"] as? String,
              let buildText = plist["CFBundleVersion"] as? String, let build = Int(buildText),
              let release = UpdateVersion(version, build: build) else { throw UpdateFailure.signature }
        return release
    }
    public func move(_ source: URL, to destination: URL) throws { try fm.moveItem(at: source, to: destination) }
    public func remove(_ url: URL) throws { try fm.removeItem(at: url) }
    public func writeReceipt(_ installation: UpdateInstallation, manifest: UpdateManifest) throws {
        let previous = try version(of: installation.target)
        let receipt = Receipt(target: installation.target.path, version: manifest.version, build: manifest.build,
                              previousVersion: previous.version.text, previousBuild: previous.build)
        try JSONEncoder().encode(receipt).write(to: installation.workspace.appendingPathComponent("receipt.json"), options: .atomic)
    }
    private struct Receipt: Codable {
        let target: String; let version: String; let build: Int
        let previousVersion: String; let previousBuild: Int
    }
    public func registerLaunch(application: URL, current: UpdateVersion) {
        let parent = application.deletingLastPathComponent()
        guard let directories = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for directory in directories where directory.lastPathComponent.hasPrefix(".oilfind-update-") {
            guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                  let data = try? Data(contentsOf: directory.appendingPathComponent("receipt.json")),
                  let receipt = try? JSONDecoder().decode(Receipt.self, from: data), receipt.target == application.path,
                  UpdateVersion(receipt.version, build: receipt.build) == current else { continue }
            try? Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: directory.appendingPathComponent("launch.pid"), options: .atomic)
        }
    }
    @discardableResult public func cleanupAfterLaunch(application: URL, current: UpdateVersion) -> UpdateFailure? {
        let parent = application.deletingLastPathComponent()
        var failure: UpdateFailure?
        guard let directories = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else { return nil }
        for directory in directories where directory.lastPathComponent.hasPrefix(".oilfind-update-") {
            guard let properties = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]), properties.isSymbolicLink == false, properties.isDirectory == true,
                  let data = try? Data(contentsOf: directory.appendingPathComponent("receipt.json")),
                  let receipt = try? JSONDecoder().decode(Receipt.self, from: data), receipt.target == application.path else { continue }
            let restarted = UpdateVersion(receipt.version, build: receipt.build) == current
            let restored = UpdateVersion(receipt.previousVersion, build: receipt.previousBuild) == current
                && fm.fileExists(atPath: directory.appendingPathComponent("relaunch-failed").path)
            guard restarted || restored else { continue }
            if restarted {
                let confirmation = directory.appendingPathComponent("launch-confirmed")
                if !fm.fileExists(atPath: confirmation.path) {
                    // The helper owns first-launch cleanup after observing this acknowledgement.
                    do { try Data().write(to: confirmation, options: .atomic) }
                    catch { failure = .other }
                    continue
                }
            }
            if restored { failure = .other }
            // Retain the receipt and acknowledgement until all large payloads are removed.
            do {
                for name in ["previous.app", "unpacked", "rejected.app"] {
                    let item = directory.appendingPathComponent(name)
                    if fm.fileExists(atPath: item.path) { try fm.removeItem(at: item) }
                }
                try fm.removeItem(at: directory)
            } catch { /* Retry the retained receipt on the next launch. */ }
        }
        return failure
    }
    private func process(_ executable: String, _ arguments: [String]) throws -> String {
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
        task.standardInput = FileHandle.nullDevice; task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        try task.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw UpdateFailure.integrity }
        return String(decoding: output, as: UTF8.self)
    }
}

public struct UpdateRelauncher {
    public init() {}
    public func startWaiting(for pid: Int32, installation: UpdateInstallation, arguments: [String] = []) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        // Paths are positional arguments, never interpolated into shell source.
        task.arguments = ["/bin/sh", "-c", """
        pid="$1"; app="$2"; work="$3"; shift 3
        while /bin/kill -0 "$pid" 2>/dev/null; do /bin/sleep 0.2; done
        /usr/bin/open -n -W "$app" --args "$@" &
        opener=$!; ticks=0
        while [ -d "$work" ] && [ ! -f "$work/launch-confirmed" ] && /bin/kill -0 "$opener" 2>/dev/null && [ "$ticks" -lt 300 ]; do
            /bin/sleep 0.2; ticks=$((ticks + 1))
        done
        if [ ! -d "$work" ] || [ -f "$work/launch-confirmed" ]; then
            /bin/kill "$opener" 2>/dev/null
            if /bin/rm -rf "$work/previous.app" "$work/unpacked" "$work/rejected.app"; then /bin/rm -rf "$work"; fi
            exit 0
        fi
        if [ -f "$work/launch.pid" ]; then
            launched=$(/bin/cat "$work/launch.pid")
            case "$launched" in ''|*[!0-9]*) exit 1 ;; esac
            command=$(/bin/ps -p "$launched" -o comm=)
            if [ "$command" = "$app/Contents/MacOS/OilFind" ]; then
                /bin/kill -TERM "$launched" 2>/dev/null
                ticks=0
                while /bin/kill -0 "$launched" 2>/dev/null && [ "$ticks" -lt 50 ]; do /bin/sleep 0.2; ticks=$((ticks + 1)); done
                if /bin/kill -0 "$launched" 2>/dev/null; then /bin/kill -KILL "$launched" 2>/dev/null; fi
            fi
        fi
        /bin/kill "$opener" 2>/dev/null
        if [ -d "$work" ]; then
            /bin/mv "$app" "$work/rejected.app" && /bin/mv "$work/previous.app" "$app" && /usr/bin/touch "$work/relaunch-failed" && /usr/bin/open -n "$app" --args "$@"
        fi
        """, "oilfind-update", String(pid), installation.target.path, installation.workspace.path] + arguments
        task.standardInput = FileHandle.nullDevice; task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try task.run()
    }
}
