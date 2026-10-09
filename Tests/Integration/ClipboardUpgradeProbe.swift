// Standalone integration probe; never built through the application's SwiftPM target.
import Foundation
import Security
import CryptoKit

private struct ProbeFailure: Error { let check: String }
private func require(_ condition: @autoclosure () throws -> Bool, _ check: String) throws {
    if try !condition() { throw ProbeFailure(check: check) }
}
private func checked(_ status: OSStatus, _ operation: String) throws {
    if status != errSecSuccess { throw ProbeFailure(check: "\(operation):OSStatus=\(status)") }
}
private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
private func openKeychain(_ path: String) throws -> SecKeychain {
    var keychain: SecKeychain?
    try checked(SecKeychainOpen(path, &keychain), "open-isolated-keychain")
    guard let keychain else { throw ProbeFailure(check: "missing-keychain-reference") }
    return keychain
}

#if KEYCHAIN_ADMIN
// The signing SPI is resolved at runtime so an unavailable symbol is a safe failure.
// Signing in this process makes SecKeychainSetUserInteractionAllowed(false) apply
// to private-key use too. The codesign CLI has no equivalent no-UI switch.
private func signingSymbol(_ name: String) throws -> UnsafeMutableRawPointer {
    guard let library = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
          let symbol = dlsym(library, name) else { throw ProbeFailure(check: "unavailable-signing-SPI") }
    return symbol
}
private func signingKey(_ name: String) throws -> String {
    let pointer = try signingSymbol(name).assumingMemoryBound(to: CFString.self)
    return pointer.pointee as String
}
private func sign(_ executable: String, keychain: SecKeychain, identifier: String) throws {
    let query: [String: Any] = [kSecClass as String: kSecClassIdentity,
        kSecMatchSearchList as String: [keychain], kSecReturnRef as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne]
    var identity: CFTypeRef?
    try checked(SecItemCopyMatching(query as CFDictionary, &identity), "isolated-signing-identity")
    guard let identity else { throw ProbeFailure(check: "missing-signing-identity") }
    let parameters: [String: Any] = [
        try signingKey("kSecCodeSignerIdentity"): identity,
        try signingKey("kSecCodeSignerIdentifier"): identifier,
        try signingKey("kSecCodeSignerRequireTimestamp"): false]
    typealias Create = @convention(c) (CFDictionary, UInt32, UnsafeMutablePointer<CFTypeRef?>) -> OSStatus
    typealias Add = @convention(c) (CFTypeRef, SecStaticCode, UInt32) -> OSStatus
    let create = unsafeBitCast(try signingSymbol("SecCodeSignerCreate"), to: Create.self)
    let add = unsafeBitCast(try signingSymbol("SecCodeSignerAddSignature"), to: Add.self)
    var signer: CFTypeRef?, code: SecStaticCode?
    try checked(create(parameters as CFDictionary, 0, &signer), "create-signer")
    try checked(SecStaticCodeCreateWithPath(URL(fileURLWithPath: executable) as CFURL, [], &code), "open-code")
    guard let signer, let code else { throw ProbeFailure(check: "missing-signer-or-code") }
    try checked(add(signer, code, 0), "noninteractive-sign")
}
private func admin(_ arguments: [String]) throws {
    try require(arguments.count >= 3, "admin-arguments")
    let command = arguments[1], path = arguments[2]
    if command == "create" {
        try require(arguments.count == 4, "create-arguments")
        let password = try Data(contentsOf: URL(fileURLWithPath: arguments[3]))
        var keychain: SecKeychain?
        try password.withUnsafeBytes { bytes in
            try checked(SecKeychainCreate(path, UInt32(bytes.count), bytes.baseAddress, false, nil, &keychain),
                        "create-private-keychain")
        }
    } else if command == "import-sign" {
        try require(arguments.count == 8, "import-sign-arguments")
        let keychain = try openKeychain(path)
        let data = try Data(contentsOf: URL(fileURLWithPath: arguments[3]))
        var format = SecExternalFormat.formatPKCS12
        var itemType = SecExternalItemType.itemTypeAggregate
        var parameters = SecItemImportExportKeyParameters()
        parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
        let passphrase = try String(contentsOfFile: arguments[7], encoding: .utf8)
            .trimmingCharacters(in: .newlines) as CFString
        parameters.passphrase = Unmanaged.passUnretained(passphrase)
        // Use the importer-owned default initial ACL. Never read or edit any ACL.
        try checked(SecItemImport(data as CFData, "p12" as CFString, &format, &itemType, [],
                                  &parameters, keychain, nil), "import-isolated-identity")
        try sign(arguments[4], keychain: keychain, identifier: arguments[6])
        try sign(arguments[5], keychain: keychain, identifier: arguments[6])
    } else if command == "delete" {
        try checked(SecKeychainDelete(try openKeychain(path)), "delete-owned-keychain")
    } else { throw ProbeFailure(check: "unknown-admin-command") }
    print("PASS admin-\(command)")
}
#else
import AppKit

// Presentation-only shims; storage, AES, Keychain, load, copy and flush are production code.
enum L10n {
    static func text(_ key: String, _ values: CVarArg...) -> String { key }
}
enum Presentation {
    static func countText(_ count: Int) -> String { String(count) }
    static func abbreviate(path: String, home: String) -> String { path }
}
private final class SyntheticPasteboard: ClipboardPasteboardReading {
    private(set) var changeCount = 0
    let canReadWithoutPrompt = true
    var content: ClipboardContent?
    func readText() -> String? { if case .text(let text)? = content { return text }; return nil }
    func writeText(_ text: String) -> Bool { writeContent(.text(text)) }
    func readContent() -> ClipboardContent? { content }
    func writeContent(_ value: ClipboardContent) -> Bool { content = value; changeCount += 1; return true }
}
private struct LegacyEntry: Codable {
    let id: UUID
    let text: String
    let copiedAt: Date
    let sourceBundleID: String
    let sourceName: String
}
private struct LegacyArchive: Codable { let version: Int; let entries: [LegacyEntry] }
private struct Manifest: Codable { let entries: [ClipboardEntry] }
private let legacyID = UUID(uuidString: "E15A5AD0-7777-4444-AAAA-000000000001")!
private let textID = UUID(uuidString: "E15A5AD0-7777-4444-AAAA-000000000002")!
private let fileID = UUID(uuidString: "E15A5AD0-7777-4444-AAAA-000000000003")!
private let legacyText = "synthetic-legacy-body-clipboard-upgrade-\u{1F680}"
private let newText = "synthetic-new-body-clipboard-upgrade-\u{4E2D}\u{6587}"
private let sourceID = "test.oilfind.clipboard-upgrade"
private func waitFor(_ condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(10)
    while !condition(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    try require(condition(), "async-deadline")
}
private func history(_ root: URL, storage: ClipboardHistoryPersisting,
                     pasteboard: SyntheticPasteboard) throws -> ClipboardHistory {
    // A unique suite never writes preferences into the user's standard defaults.
    guard let defaults = UserDefaults(suiteName: "test.oilfind.clipboard-upgrade.\(UUID().uuidString)")
    else { throw ProbeFailure(check: "isolated-defaults") }
    let result = ClipboardHistory(defaults: defaults, storage: storage, pasteboard: pasteboard,
                                  source: { (sourceID, "Synthetic") }, saveDelay: 3600,
                                  recoveryStorage: { storage })
    result.start()
    return result
}
private func inspect(_ url: URL, entries: [ClipboardEntry]) throws {
    let bytes = try Data(contentsOf: url)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    try require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "archive-mode-0600")
    for entry in entries {
        try require(bytes.range(of: Data(entry.text.utf8)) == nil, "ciphertext-no-UTF8-body")
        try require(bytes.range(of: entry.text.data(using: .utf16LittleEndian)!) == nil, "ciphertext-no-UTF16-body")
        for path in entry.filePaths ?? [] {
            try require(bytes.range(of: Data(path.utf8)) == nil, "ciphertext-no-file-path")
        }
    }
    print("PASS disk-ciphertext mode=0600 count=\(entries.count) sha256=\(digest(bytes))")
}
private func probe(_ arguments: [String]) throws {
    try require(arguments.count == 4, "probe-arguments")
    let command = arguments[1], root = URL(fileURLWithPath: arguments[2], isDirectory: true)
    let keychain = try openKeychain(arguments[3])
    let archiveURL = root.appendingPathComponent("history.encrypted")
    let io = ClipboardArchiveFile(url: archiveURL)
    let keys = ClipboardKeychain(service: sourceID, keychain: keychain)
    let storage = ClipboardEncryptedStorage(io: io, keys: keys)
    let manifestURL = root.appendingPathComponent("manifest.plist")
    let board = SyntheticPasteboard()
    if command == "createlegacy" {
        #if UPGRADE_V1
        let entry = LegacyEntry(id: legacyID, text: legacyText, copiedAt: Date().addingTimeInterval(-1),
                                sourceBundleID: sourceID, sourceName: "Synthetic")
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let plaintext = try encoder.encode(LegacyArchive(version: 1, entries: [entry]))
        let plist = try PropertyListSerialization.propertyList(from: plaintext, options: [], format: nil) as! [String: Any]
        let values = plist["entries"] as! [[String: Any]]
        try require(values[0]["filePaths"] == nil, "legacy-omits-filePaths")
        let key = try keys.key(createIfMissing: true)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: Data("OilFindClipboard.v1".utf8))
        try io.writeAtomically(sealed.combined!)
        try require(try storage.load().first?.id == legacyID, "legacy-real-storage-readback")
        try inspect(archiveURL, entries: [ClipboardEntry(id: legacyID, text: legacyText)])
        print("PASS createlegacy version=1 count=1")
        #else
        throw ProbeFailure(check: "createlegacy-requires-v1-binary")
        #endif
    } else if command == "upgrade" {
        #if UPGRADE_V1
        throw ProbeFailure(check: "upgrade-requires-v2-binary")
        #else
        let original = try Data(contentsOf: archiveURL)
        let result = try history(root, storage: storage, pasteboard: board)
        try waitFor { !result.entries.isEmpty || result.error != nil }
        try require(result.error == nil && result.entries.count == 1, "v2-legacy-load")
        try require(result.entries[0].id == legacyID && result.entries[0].text == legacyText
                    && result.entries[0].filePaths == nil, "v2-legacy-ID-content")
        let fileURL = root.appendingPathComponent("synthetic-reference.txt")
        try Data("synthetic-file-body-never-captured".utf8).write(to: fileURL)
        let text = ClipboardEntry(id: textID, text: newText, sourceBundleID: sourceID, sourceName: "Synthetic")
        let files = ClipboardEntry(id: fileID, content: .files([fileURL.path, root.path]),
                                   sourceBundleID: sourceID, sourceName: "Synthetic")
        var textOutcome: ClipboardCopyOutcome?
        result.copy(text, isCurrent: { true }) { textOutcome = $0 }
        try require(textOutcome == .copied, "text-copy-synchronous")
        var filesOutcome: ClipboardCopyOutcome?
        result.copy(files, isCurrent: { true }) { filesOutcome = $0 }
        try waitFor { filesOutcome != nil }
        try require(filesOutcome == .copied && board.content == files.content, "files-copy-asynchronous")
        try require(result.entries.count == 3 && result.error == nil, "v2-memory-entries")
        // The one-hour debounce means only stop() may persist these edits.
        try require(try Data(contentsOf: archiveURL) == original, "archive-unchanged-before-stop")
        let expected = result.entries
        try PropertyListEncoder().encode(Manifest(entries: expected)).write(to: manifestURL, options: .atomic)
        result.stop()
        try require(result.error == nil, "stop-flush-success")
        try require(try Data(contentsOf: archiveURL) != original, "stop-flush-wrote-disk")
        try inspect(archiveURL, entries: expected)
        print("PASS upgrade stop-flush count=3")
        #endif
    } else if command == "restore" {
        let expected = try PropertyListDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL)).entries
        let result = try history(root, storage: storage, pasteboard: board)
        try waitFor { !result.entries.isEmpty || result.error != nil }
        try require(result.error == nil && result.entries == expected, "cross-process-all-IDs-content-metadata")
        try require(Set(result.entries.map(\.id)) == Set([legacyID, textID, fileID]), "restore-three-IDs")
        result.stop()
        try inspect(archiveURL, entries: expected)
        print("PASS restore independent-process count=3")
    } else if command == "missing" || command == "corrupt" || command == "denied" {
        let original = try Data(contentsOf: archiveURL)
        let failureKeys = command == "missing"
            ? ClipboardKeychain(service: sourceID + ".absent", keychain: keychain) : keys
        if command == "missing" || command == "denied" {
            do {
                _ = try failureKeys.key(createIfMissing: false)
                throw ProbeFailure(check: "expected-real-keychain-denial")
            } catch let failure as ClipboardFailure {
                try require(failure == (command == "missing" ? .keyUnavailable : .keychainUnavailable),
                            "expected-keychain-failure-kind")
            }
        }
        let protected = ClipboardEncryptedStorage(io: io, keys: failureKeys)
        let result = try history(root, storage: protected, pasteboard: board)
        try waitFor { result.error != nil }
        let expectedFailure: ClipboardFailure = command == "missing" ? .keyUnavailable
            : command == "corrupt" ? .corruptArchive : .keychainUnavailable
        try require(result.error == expectedFailure.localizedDescription, "history-failure-kind")
        result.clear()
        var outcome: ClipboardCopyOutcome?
        result.copy(ClipboardEntry(text: newText)) { outcome = $0 }
        try require(outcome == .copied, "failure-memory-only-edit")
        result.stop()
        try require(try Data(contentsOf: archiveURL) == original, "failure-keeps-original-file")
        do {
            try protected.save([])
            throw ProbeFailure(check: "protected-save-must-fail")
        } catch let failure as ClipboardFailure {
            try require(failure == .preservedArchive, "protected-save-rejection")
        }
        print("PASS \(command) original-preserved sha256=\(digest(original))")
    } else { throw ProbeFailure(check: "unknown-probe-command") }
}
#endif

@main private enum Main {
    static func main() {
        do {
            // Never restore interaction to true; this process must remain unable to prompt.
            try checked(SecKeychainSetUserInteractionAllowed(false), "disable-security-UI")
            #if KEYCHAIN_ADMIN
            try admin(CommandLine.arguments)
            #else
            try probe(CommandLine.arguments)
            #endif
        } catch {
            let check = (error as? ProbeFailure)?.check ?? "operation-failed"
            fputs("FAIL \(check) (no UI/ACL/trust fallback)\n", stderr)
            exit(1)
        }
    }
}
