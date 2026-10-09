import AppKit
import Combine
import CryptoKit
import LocalAuthentication
import OilFindCore
import Security
import UniformTypeIdentifiers

enum ClipboardContent: Equatable {
    case text(String), files([String])
}

private enum ClipboardContentKey: Hashable {
    case text(Data), files([Data])
}

struct ClipboardEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let copiedAt: Date
    let sourceBundleID: String?
    let sourceName: String?
    // Optional for decoding text-only archives written before file capture existed.
    let filePaths: [String]?

    var content: ClipboardContent { filePaths.map(ClipboardContent.files) ?? .text(text) }
    var fileURLs: [URL] { (filePaths ?? []).map { URL(fileURLWithPath: $0) } }
    fileprivate var contentKey: ClipboardContentKey {
        if let filePaths { return .files(filePaths.map { Data($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }) }
        return .text(Data(text.utf8))
    }
    var storageBytes: Int {
        text.utf8.count + (filePaths?.reduce(0) { $0 + $1.utf8.count + 32 } ?? 0)
            + (sourceBundleID?.utf8.count ?? 0) + (sourceName?.utf8.count ?? 0) + 256
    }
    var displayTitle: String {
        guard let filePaths else { return text.replacingOccurrences(of: "\n", with: " ⏎ ") }
        let names = filePaths.prefix(3).map { ($0 as NSString).lastPathComponent }
        if filePaths.count == 1 { return names.first ?? "" }
        return L10n.text("clipboard.files", Presentation.countText(filePaths.count)) + " · " + names.joined(separator: ", ")
    }
    var locationSummary: String? {
        guard let filePaths, let first = filePaths.first else { return nil }
        let parent = (first as NSString).deletingLastPathComponent
        if filePaths.allSatisfy({ ($0 as NSString).deletingLastPathComponent == parent }) {
            return Presentation.abbreviate(path: parent, home: NSHomeDirectory())
        }
        return L10n.text("clipboard.multipleLocations")
    }
    func matches(_ query: String) -> Bool {
        matches(words: query.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    }
    func matches(words: [String]) -> Bool {
        words.allSatisfy { value in
            return text.localizedStandardContains(value)
                || (sourceName?.localizedStandardContains(value) ?? false)
                || (sourceBundleID?.localizedStandardContains(value) ?? false)
        }
    }

    init(id: UUID = UUID(), text: String, copiedAt: Date = Date(),
         sourceBundleID: String? = nil, sourceName: String? = nil) {
        self.id = id
        self.text = text
        self.copiedAt = copiedAt
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.filePaths = nil
    }

    init(id: UUID = UUID(), content: ClipboardContent, copiedAt: Date = Date(),
         sourceBundleID: String? = nil, sourceName: String? = nil) {
        self.id = id; self.copiedAt = copiedAt
        self.sourceBundleID = sourceBundleID; self.sourceName = sourceName
        switch content {
        case .text(let text): self.text = text; filePaths = nil
        case .files(let paths): text = paths.joined(separator: "\n"); filePaths = paths
        }
    }
}

enum ClipboardFailure: String, Error, LocalizedError {
    case keyUnavailable, keychainUnavailable, corruptArchive, archiveTooLarge
    case preservedArchive, storageUnavailable, copyFailed, invalidText, missingFiles, validationTimedOut, snapshotOnly

    var errorDescription: String? {
        L10n.text("clipboard.failure.\(rawValue)")
    }
}

enum ClipboardCopyOutcome: Equatable { case copied, failed, cancelled }

// Cancellation is checked between filesystem calls. A slow mount may keep one
// call blocked, but it cannot block the main thread or authorize a late write.
private final class ClipboardCopyRequest {
    private let lock = NSLock()
    private var cancelled = false
    var timer: Timer?
    let completion: (ClipboardCopyOutcome) -> Void
    init(completion: @escaping (ClipboardCopyOutcome) -> Void) { self.completion = completion }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

// Pure value storage. Exact deduplication uses UTF-8 bytes rather than Swift's
// canonically equivalent String equality. Newest entries are always first.
struct ClipboardHistoryStore {
    static let maximumTextBytes = 256 * 1024
    static let maximumFileCount = 1_000
    static let maximumTotalBytes = 32 * 1024 * 1024
    static let defaultExcludedAppIDs = [
        "com.agilebits.onepassword7", "com.1password.1password", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.dashlane.Dashlane", "com.lastpass.LastPass",
        "org.keepassxc.keepassxc", "com.apple.Passwords", "com.enpass.Enpass", "com.apple.keychainaccess"
    ]

    private(set) var entries: [ClipboardEntry] = []
    private(set) var retentionDays: Int
    private(set) var maxItems: Int
    private(set) var excludedAppIDs: [String]

    init(entries: [ClipboardEntry] = [], retentionDays: Int = 7, maxItems: Int = 500,
         excludedAppIDs: [String] = Self.defaultExcludedAppIDs, now: Date = Date()) {
        self.retentionDays = min(365, max(1, retentionDays))
        self.maxItems = min(10_000, max(1, maxItems))
        self.excludedAppIDs = Self.normalizedExclusions(excludedAppIDs)
        self.entries = entries
        prune(now: now)
    }

    static func normalizedExclusions(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })).sorted()
    }

    func excludes(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        let candidate = bundleID.lowercased()
        return excludedAppIDs.contains { candidate == $0 || candidate.hasPrefix($0 + ".") }
    }

    static func accepts(_ entry: ClipboardEntry) -> Bool {
        guard !entry.text.isEmpty && entry.text.utf8.count <= maximumTextBytes
            && (entry.sourceBundleID?.utf8.count ?? 0) <= 1024
            && (entry.sourceName?.utf8.count ?? 0) <= 1024
            && entry.copiedAt.timeIntervalSinceReferenceDate.isFinite else { return false }
        guard let paths = entry.filePaths else { return true }
        return !paths.isEmpty && paths.count <= maximumFileCount
            && paths.allSatisfy { $0.hasPrefix("/") && !$0.utf8.contains(0) }
            && Set(paths.map { Data($0.utf8) }).count == paths.count
            && Data(entry.text.utf8) == Data(paths.joined(separator: "\n").utf8)
    }

    @discardableResult
    mutating func record(_ entry: ClipboardEntry, now: Date) -> Bool {
        guard Self.accepts(entry), !excludes(entry.sourceBundleID) else { return false }
        let key = entry.contentKey
        let storedID = entries.first { $0.contentKey == key }?.id ?? entry.id
        let storedEntry = ClipboardEntry(id: storedID, content: entry.content, copiedAt: entry.copiedAt,
                                         sourceBundleID: entry.sourceBundleID, sourceName: entry.sourceName)
        entries.removeAll { $0.contentKey == key || $0.id == entry.id }
        entries.insert(storedEntry, at: 0)
        prune(now: now)
        return entries.contains { $0.id == storedID }
    }

    mutating func configure(days: Int, items: Int, exclusions: [String], now: Date) {
        retentionDays = min(365, max(1, days))
        maxItems = min(10_000, max(1, items))
        excludedAppIDs = Self.normalizedExclusions(exclusions)
        prune(now: now)
    }

    @discardableResult
    mutating func prune(now: Date) -> Bool {
        let previous = entries
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        var contents = Set<ClipboardContentKey>(), ids = Set<UUID>(), byteCount = 0, itemCount = 0
        entries = entries.enumerated().sorted {
            $0.element.copiedAt == $1.element.copiedAt
                ? $0.offset < $1.offset : $0.element.copiedAt > $1.element.copiedAt
        }.compactMap { indexed in
            let entry = indexed.element
            guard Self.accepts(entry), entry.copiedAt >= cutoff, entry.copiedAt <= now,
                  !excludes(entry.sourceBundleID), ids.insert(entry.id).inserted else { return nil }
            guard contents.insert(entry.contentKey).inserted else { return nil }
            // Include bounded metadata and a per-entry allowance in the memory budget.
            let size = entry.storageBytes
            guard itemCount < maxItems, byteCount + size <= Self.maximumTotalBytes else { return nil }
            byteCount += size
            itemCount += 1
            return entry
        }
        return previous != entries
    }

    func search(_ query: String) -> [ClipboardEntry] {
        guard !query.isEmpty else { return entries }
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return entries.filter { $0.matches(words: words) }
    }

    mutating func remove(_ id: UUID) { entries.removeAll { $0.id == id } }
    mutating func clear() { entries.removeAll() }
}

protocol ClipboardKeyProviding {
    func key(createIfMissing: Bool) throws -> SymmetricKey
}

struct ClipboardKeychain: ClipboardKeyProviding {
    var service = "com.oiloil.find.clipboard-history"
    var account = "aes-gcm-v1"
    var allowsInteraction = false
    // Tests may use an isolated keychain without changing the user's search list.
    var keychain: SecKeychain?
    private static let interactionLock = NSRecursiveLock()

    func key(createIfMissing: Bool) throws -> SymmetricKey {
        // LAContext does not suppress prompts for legacy macOS keychain items.
        // Limit this process-wide switch to the serialized request and restore it.
        Self.interactionLock.lock()
        defer { Self.interactionLock.unlock() }
        var interactionAllowed: DarwinBoolean = false
        if !allowsInteraction {
            guard SecKeychainGetUserInteractionAllowed(&interactionAllowed) == errSecSuccess,
                  SecKeychainSetUserInteractionAllowed(false) == errSecSuccess
            else { throw ClipboardFailure.keychainUnavailable }
        }
        defer { if !allowsInteraction { SecKeychainSetUserInteractionAllowed(interactionAllowed.boolValue) } }
        let context = LAContext()
        context.interactionNotAllowed = !allowsInteraction
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context
        ]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        if let keychain { lookup[kSecMatchSearchList as String] = [keychain] }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess {
            guard let bytes = result as? Data, bytes.count == 32 else { throw ClipboardFailure.keyUnavailable }
            return SymmetricKey(data: bytes)
        }
        guard status == errSecItemNotFound else { throw ClipboardFailure.keychainUnavailable }
        guard createIfMissing else { throw ClipboardFailure.keyUnavailable }
        let generated = SymmetricKey(size: .bits256)
        var addition = query
        if let keychain { addition[kSecUseKeychain as String] = keychain }
        addition[kSecValueData as String] = generated.withUnsafeBytes { Data($0) }
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addition[kSecAttrSynchronizable as String] = false
        let added = SecItemAdd(addition as CFDictionary, nil)
        if added == errSecDuplicateItem { return try key(createIfMissing: false) }
        guard added == errSecSuccess else { throw ClipboardFailure.keychainUnavailable }
        return generated
    }
}

protocol ClipboardArchiveIO {
    func read() throws -> Data?
    func writeAtomically(_ data: Data) throws
}

struct ClipboardArchiveFile: ClipboardArchiveIO {
    let url: URL
    // Binary plists can use UTF-16; bound disk reads before allocating or decrypting.
    static let maximumArchiveBytes = 72 * 1024 * 1024

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Oil Find", isDirectory: true)
            .appendingPathComponent("clipboard-history.encrypted")
    }

    func read() throws -> Data? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.intValue <= Self.maximumArchiveBytes else { throw ClipboardFailure.archiveTooLarge }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= Self.maximumArchiveBytes else { throw ClipboardFailure.archiveTooLarge }
            return data
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func writeAtomically(_ data: Data) throws {
        guard data.count <= Self.maximumArchiveBytes else { throw ClipboardFailure.archiveTooLarge }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

protocol ClipboardHistoryPersisting {
    func load() throws -> [ClipboardEntry]
    func save(_ entries: [ClipboardEntry]) throws
}

// Only used on the history's serial IO queue. A failed load permanently protects
// the original archive, including when clear() is invoked in memory-only mode.
final class ClipboardEncryptedStorage: ClipboardHistoryPersisting {
    private struct Archive: Codable { let version: Int; let entries: [ClipboardEntry] }
    private let io: ClipboardArchiveIO
    private let keys: ClipboardKeyProviding
    private let authentication = Data("OilFindClipboard.v1".utf8)
    private var loaded = false
    private var protected = false
    private var encryptionKey: SymmetricKey?

    init(io: ClipboardArchiveIO = ClipboardArchiveFile(url: ClipboardArchiveFile.defaultURL),
         keys: ClipboardKeyProviding = ClipboardKeychain()) {
        self.io = io
        self.keys = keys
    }

    func load() throws -> [ClipboardEntry] {
        guard !protected else { throw ClipboardFailure.preservedArchive }
        do {
            guard let data = try io.read() else { loaded = true; return [] }
            guard data.count <= ClipboardArchiveFile.maximumArchiveBytes else { throw ClipboardFailure.archiveTooLarge }
            let key = try keys.key(createIfMissing: false)
            let archive: Archive
            do {
                let sealed = try AES.GCM.SealedBox(combined: data)
                let plaintext = try AES.GCM.open(sealed, using: key, authenticating: authentication)
                archive = try PropertyListDecoder().decode(Archive.self, from: plaintext)
            } catch { throw ClipboardFailure.corruptArchive }
            guard archive.version == 1, archive.entries.count <= 10_000,
                  archive.entries.allSatisfy(ClipboardHistoryStore.accepts) else { throw ClipboardFailure.corruptArchive }
            let size = archive.entries.reduce(0) { $0 + $1.storageBytes }
            guard size <= ClipboardHistoryStore.maximumTotalBytes else { throw ClipboardFailure.archiveTooLarge }
            encryptionKey = key
            loaded = true
            return archive.entries
        } catch {
            protected = true
            throw error
        }
    }

    func save(_ entries: [ClipboardEntry]) throws {
        guard !protected else { throw ClipboardFailure.preservedArchive }
        if !loaded { _ = try load() }
        guard entries.count <= 10_000, entries.allSatisfy(ClipboardHistoryStore.accepts),
              entries.reduce(0, { $0 + $1.storageBytes }) <= ClipboardHistoryStore.maximumTotalBytes
        else { throw ClipboardFailure.archiveTooLarge }
        let key = try encryptionKey ?? keys.key(createIfMissing: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let plaintext = try encoder.encode(Archive(version: 1, entries: entries))
        guard let data = try AES.GCM.seal(plaintext, using: key, authenticating: authentication).combined
        else { throw ClipboardFailure.storageUnavailable }
        try io.writeAtomically(data)
        encryptionKey = key
    }
}

protocol ClipboardPasteboardReading {
    var changeCount: Int { get }
    var canReadWithoutPrompt: Bool { get }
    func readText() -> String?
    func writeText(_ text: String) -> Bool
    func readContent() -> ClipboardContent?
    func writeContent(_ content: ClipboardContent) -> Bool
    func requestAccess()
}

extension ClipboardPasteboardReading {
    func requestAccess() {}
    func readContent() -> ClipboardContent? { readText().map(ClipboardContent.text) }
    func writeContent(_ content: ClipboardContent) -> Bool {
        guard case .text(let text) = content else { return false }
        return writeText(text)
    }
}

final class ClipboardSystemPasteboard: ClipboardPasteboardReading {
    static let ownCopyType = NSPasteboard.PasteboardType("com.oiloil.find.clipboard-history.copy")
    private let suppliedPasteboard: NSPasteboard?
    // Resolve the general pasteboard lazily, only after opt-in or explicit Copy.
    private var pasteboard: NSPasteboard { suppliedPasteboard ?? .general }

    init(pasteboard: NSPasteboard? = nil) { suppliedPasteboard = pasteboard }
    var changeCount: Int { pasteboard.changeCount }
    var canReadWithoutPrompt: Bool {
        if #available(macOS 15.4, *) { return pasteboard.accessBehavior == .alwaysAllow }
        return true
    }

    func requestAccess() {
        if #available(macOS 15.4, *) {
            switch pasteboard.accessBehavior {
            case .default, .ask:
                // Only an explicit user action calls this. Discard pre-opt-in text.
                _ = pasteboard.string(forType: .string)
            default: break
            }
        }
    }

    func readText() -> String? {
        guard case .text(let text)? = readContent() else { return nil }
        return text
    }

    func readContent() -> ClipboardContent? {
        guard canReadWithoutPrompt, let items = pasteboard.pasteboardItems, !items.isEmpty,
              items.count <= ClipboardHistoryStore.maximumFileCount else { return nil }
        let forbidden = Set([
            Self.ownCopyType.rawValue, "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
            "org.nspasteboard.AutoGeneratedType", "org.nspasteboard.concealed",
            "org.nspasteboard.transient", "org.nspasteboard.autogenerated",
            "NSFilesPromisePboardType", "Apple files promise pasteboard type",
            "com.apple.pasteboard.promised-file-url", "com.apple.pasteboard.promised-file-content-type"
        ])
        guard !items.contains(where: { item in item.types.contains { forbidden.contains($0.rawValue) } }) else { return nil }
        if items.contains(where: { $0.types.contains(.fileURL) }) {
            // Reject mixed or malformed selections instead of recording partial file groups.
            var paths: [String] = [], bytes = 0
            for item in items {
                guard let data = item.data(forType: .fileURL), data.count <= ClipboardHistoryStore.maximumTextBytes * 4,
                      let value = String(data: data, encoding: .utf8), let url = URL(string: value), url.isFileURL,
                      url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
                      url.query == nil, url.fragment == nil, url.user == nil, url.password == nil else { return nil }
                let path = url.standardizedFileURL.path
                bytes += path.utf8.count + 1
                guard bytes - 1 <= ClipboardHistoryStore.maximumTextBytes else { return nil }
                paths.append(path)
            }
            let entry = ClipboardEntry(content: .files(paths))
            return ClipboardHistoryStore.accepts(entry) ? entry.content : nil
        }
        let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if items.contains(where: { $0.types.contains(filenames) }) {
            guard items.count == 1, let data = pasteboard.data(forType: filenames), data.count <= ClipboardHistoryStore.maximumTextBytes * 4,
                  let paths = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String],
                  paths.count <= ClipboardHistoryStore.maximumFileCount else { return nil }
            let entry = ClipboardEntry(content: .files(paths))
            return ClipboardHistoryStore.accepts(entry) ? entry.content : nil
        }
        guard items.count == 1, let item = items.first else { return nil }
        let types = item.types
        guard !types.contains(where: { type in
            if forbidden.contains(type.rawValue) { return true }
            guard let uti = UTType(type.rawValue) else { return false }
            return uti.conforms(to: .image) || uti.conforms(to: .fileURL) || uti.conforms(to: .pdf)
        }), types.contains(.string), let data = item.data(forType: .string),
              !data.isEmpty, data.count <= ClipboardHistoryStore.maximumTextBytes,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return .text(text)
    }

    func writeText(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= ClipboardHistoryStore.maximumTextBytes else { return false }
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string), item.setData(Data([1]), forType: Self.ownCopyType) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    func writeContent(_ content: ClipboardContent) -> Bool {
        if case .text(let text) = content { return writeText(text) }
        guard case .files(let paths) = content,
              ClipboardHistoryStore.accepts(ClipboardEntry(content: content)) else { return false }
        var items: [NSPasteboardItem] = []
        for path in paths {
            let item = NSPasteboardItem()
            guard item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL),
                  item.setString(path, forType: .string), item.setData(Data([1]), forType: Self.ownCopyType) else { return false }
            items.append(item)
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects(items)
    }
}

// Integration methods and published properties are main-thread APIs, matching
// the application's other ObservableObjects. Storage/crypto run on a serial queue.
final class ClipboardHistory: ObservableObject {
    @Published var enabled: Bool { didSet { if enabled != oldValue { updateMonitoringPreference() } } }
    @Published var paused: Bool { didSet { if paused != oldValue { updateMonitoringPreference() } } }
    @Published var retentionDays: Int { didSet {
        let bounded = min(365, max(1, retentionDays))
        if retentionDays != bounded { retentionDays = bounded; return }
        updateStoreConfiguration()
    } }
    @Published var maxItems: Int { didSet {
        let bounded = min(10_000, max(1, maxItems))
        if maxItems != bounded { maxItems = bounded; return }
        updateStoreConfiguration()
    } }
    @Published var excludedAppIDs: [String] { didSet {
        let normalized = ClipboardHistoryStore.normalizedExclusions(excludedAppIDs)
        if excludedAppIDs != normalized { excludedAppIDs = normalized; return }
        updateStoreConfiguration()
    } }
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var error: String?
    @Published private(set) var needsAccess = false
    @Published private(set) var requestingPersistenceAccess = false

    private enum Preference {
        static let enabled = "clipboardHistoryEnabled", paused = "clipboardHistoryPaused"
        static let days = "clipboardHistoryRetentionDays", items = "clipboardHistoryMaxItems"
        static let exclusions = "clipboardHistoryExcludedAppIDs"
    }
    private let snapshot: Bool
    private let defaults: UserDefaults
    private let pasteboard: ClipboardPasteboardReading
    private var storage: ClipboardHistoryPersisting
    private let recoveryStorage: () -> ClipboardHistoryPersisting
    private let clock: () -> Date
    private let source: () -> (bundleID: String?, name: String?)
    private let queue = DispatchQueue(label: "com.oiloil.find.clipboard-storage", qos: .utility)
    private let saveDelay: TimeInterval
    private var store = ClipboardHistoryStore()
    private var timer: Timer?
    private var started = false
    private var lastChangeCount: Int?
    private var lastPruned: Date?
    private var loading = false, loaded = false, dirty = false
    private var removedDuringLoad = Set<UUID>()
    private var clearedDuringLoad = false
    private var storageError: String?
    private var saveWork: DispatchWorkItem?
    private var saveRevision = 0
    private var requestedAccess = false
    // Confined to queue; stop() can retrieve a completed load without waiting on
    // a main-queue callback, which would deadlock during application shutdown.
    private var loadResultOnQueue: Result<[ClipboardEntry], Error>?
    private let fileQueue = DispatchQueue(label: "OilFind.clipboard-file-validation", qos: .userInitiated)
    private let fileExists: (String) -> Bool
    private let validationTimeout: TimeInterval
    private var copyRequest: ClipboardCopyRequest?

    init(snapshot: Bool = false, defaults: UserDefaults = .standard,
         storage: ClipboardHistoryPersisting? = nil,
         pasteboard: ClipboardPasteboardReading? = nil,
         clock: @escaping () -> Date = Date.init,
         source: @escaping () -> (bundleID: String?, name: String?) = {
             let app = NSWorkspace.shared.frontmostApplication
             return (app?.bundleIdentifier, app?.localizedName)
         }, saveDelay: TimeInterval = 0.5,
         recoveryStorage: (() -> ClipboardHistoryPersisting)? = nil,
         fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
         validationTimeout: TimeInterval = 2) {
        self.snapshot = snapshot
        self.defaults = defaults
        self.storage = storage ?? ClipboardEncryptedStorage()
        self.recoveryStorage = recoveryStorage ?? {
            storage ?? ClipboardEncryptedStorage(keys: ClipboardKeychain(allowsInteraction: true))
        }
        self.pasteboard = pasteboard ?? ClipboardSystemPasteboard()
        self.clock = clock
        self.source = source
        self.saveDelay = max(0, saveDelay)
        self.fileExists = fileExists
        self.validationTimeout = max(0.01, validationTimeout)
        enabled = !snapshot && defaults.bool(forKey: Preference.enabled)
        paused = !snapshot && defaults.bool(forKey: Preference.paused)
        retentionDays = snapshot ? 7 : min(365, max(1, (defaults.object(forKey: Preference.days) as? Int) ?? 7))
        maxItems = snapshot ? 500 : min(10_000, max(1, (defaults.object(forKey: Preference.items) as? Int) ?? 500))
        excludedAppIDs = snapshot ? ClipboardHistoryStore.defaultExcludedAppIDs
            : ClipboardHistoryStore.normalizedExclusions(defaults.stringArray(forKey: Preference.exclusions)
                ?? ClipboardHistoryStore.defaultExcludedAppIDs)
        store = ClipboardHistoryStore(retentionDays: retentionDays, maxItems: maxItems,
                                      excludedAppIDs: excludedAppIDs, now: clock())
    }

    deinit { timer?.invalidate(); copyRequest?.cancel(); copyRequest?.timer?.invalidate() }

    func start() {
        guard !snapshot, !started else { return }
        started = true
        ensureLoaded()
        refreshMonitoring()
    }

    func stop() {
        cancelCopy()
        started = false
        timer?.invalidate(); timer = nil
        lastChangeCount = nil
        needsAccess = false
        flush()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if value { requestAccess() }
    }
    func requestAccess() {
        guard !snapshot, started, enabled, !requestedAccess else { return }
        requestedAccess = true
        pasteboard.requestAccess()
        lastChangeCount = nil
        pollOnce()
    }

    // Only the settings button requests interactive access. A fresh storage
    // instance must successfully read the original archive before replacing it.
    func requestPersistenceAccess() {
        guard !snapshot, started, loaded, !loading, storageError != nil else { return }
        saveWork?.cancel(); saveWork = nil
        storage = recoveryStorage()
        loaded = false
        storageError = nil
        requestingPersistenceAccess = true
        error = L10n.text("clipboard.waitingForKeychain")
        ensureLoaded()
    }

    // Shutdown barrier. Normal edits remain asynchronously debounced. Call this
    // on the main thread before terminating; it never waits for a main callback.
    func flush() {
        saveWork?.cancel(); saveWork = nil
        guard !snapshot, !requestingPersistenceAccess, storageError == nil, dirty || loading else { return }
        if !loaded {
            let result = queue.sync { loadResultOnQueue ?? Result { try storage.load() } }
            acceptLoaded(result)
        }
        guard storageError == nil, dirty else { return }
        saveRevision += 1
        let values = entries
        let result = queue.sync { Result { try storage.save(values) } }
        switch result {
        case .success: dirty = false
        case .failure(let failure): disablePersistence(failure)
        }
    }
    func setPaused(_ value: Bool) { paused = value }
    func setRetention(days: Int, items: Int) { retentionDays = days; maxItems = items }
    func setExcludedApplications(_ values: [String]) { excludedAppIDs = values }

    func search(_ query: String) -> [ClipboardEntry] {
        pruneIfNeeded(force: true)
        return store.search(query)
    }

    func cancelCopy() {
        guard let request = copyRequest else { return }
        copyRequest = nil
        request.cancel(); request.timer?.invalidate(); request.timer = nil
        request.completion(.cancelled)
    }

    func copy(_ entry: ClipboardEntry, isCurrent: @escaping () -> Bool = { true },
              completion: @escaping (ClipboardCopyOutcome) -> Void) {
        precondition(Thread.isMainThread)
        cancelCopy()
        guard !snapshot else { report(ClipboardFailure.snapshotOnly); completion(.failed); return }
        guard ClipboardHistoryStore.accepts(entry) else { report(ClipboardFailure.invalidText); completion(.failed); return }
        guard isCurrent() else { completion(.cancelled); return }
        guard let paths = entry.filePaths else { completion(writeCopy(entry) ? .copied : .failed); return }
        let request = ClipboardCopyRequest(completion: completion)
        copyRequest = request
        let finish: (ClipboardFailure?) -> Void = { [weak self, weak request] failure in
            guard let self, let request, self.copyRequest === request else { return }
            self.copyRequest = nil
            request.cancel(); request.timer?.invalidate(); request.timer = nil
            // Recheck the caller's query, selection and panel before any write.
            guard isCurrent() else { request.completion(.cancelled); return }
            if let failure { self.report(failure); request.completion(.failed) }
            else { request.completion(self.writeCopy(entry) ? .copied : .failed) }
        }
        request.timer = Timer(timeInterval: validationTimeout, repeats: false) { _ in finish(.validationTimedOut) }
        if let timer = request.timer { RunLoop.main.add(timer, forMode: .common) }
        let exists = fileExists
        fileQueue.async {
            guard !request.isCancelled else { return }
            let valid = paths.allSatisfy { !request.isCancelled && exists($0) }
            guard !request.isCancelled else { return }
            DispatchQueue.main.async { finish(valid ? nil : .missingFiles) }
        }
    }

    private func writeCopy(_ entry: ClipboardEntry) -> Bool {
        guard pasteboard.writeContent(entry.content) else { report(ClipboardFailure.copyFailed); return false }
        lastChangeCount = pasteboard.changeCount
        let latest = ClipboardEntry(id: entry.id, content: entry.content, copiedAt: clock(),
                                    sourceBundleID: entry.sourceBundleID, sourceName: entry.sourceName)
        if store.record(latest, now: clock()) { changed() }
        error = requestingPersistenceAccess ? L10n.text("clipboard.waitingForKeychain") : storageError
        return true
    }

    func remove(_ id: UUID) {
        cancelCopy()
        removedDuringLoad.insert(id)
        store.remove(id)
        changed()
    }

    func clear() {
        cancelCopy()
        clearedDuringLoad = true
        store.clear()
        changed()
    }

    func prepareSnapshot(_ values: [ClipboardEntry], enabled: Bool? = nil, needsAccess: Bool = false) {
        guard snapshot else { return }
        store = ClipboardHistoryStore(entries: values, retentionDays: retentionDays, maxItems: maxItems,
                                      excludedAppIDs: excludedAppIDs, now: clock())
        entries = store.entries
        error = nil
        if let enabled { self.enabled = enabled }
        self.needsAccess = needsAccess
    }

    // Internal deterministic seam: tests do not need to run a timer or a GUI app.
    func pollOnce() {
        guard !snapshot, started, enabled, !paused else { return }
        pruneIfNeeded()
        guard pasteboard.canReadWithoutPrompt else {
            needsAccess = true
            lastChangeCount = nil
            return
        }
        needsAccess = false
        let count = pasteboard.changeCount
        guard let previous = lastChangeCount else { lastChangeCount = count; return }
        guard count != previous else { return }
        lastChangeCount = count
        // The frontmost app is an approximation, not proof of clipboard ownership.
        let app = source()
        guard !store.excludes(app.bundleID), let content = pasteboard.readContent(),
              pasteboard.changeCount == count else { return }
        if store.record(ClipboardEntry(content: content, copiedAt: clock(), sourceBundleID: app.bundleID,
                                       sourceName: app.name), now: clock()) { changed() }
    }

    private func updateMonitoringPreference() {
        if !snapshot {
            defaults.set(enabled, forKey: Preference.enabled)
            defaults.set(paused, forKey: Preference.paused)
        }
        refreshMonitoring()
    }

    private func refreshMonitoring() {
        timer?.invalidate(); timer = nil
        lastChangeCount = nil
        needsAccess = false
        guard !snapshot, started, enabled, !paused else { return }
        pollOnce() // Establish a baseline; do not collect pre-opt-in contents.
        timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.pollOnce() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func updateStoreConfiguration() {
        guard !snapshot else {
            store.configure(days: retentionDays, items: maxItems, exclusions: excludedAppIDs, now: clock())
            entries = store.entries
            return
        }
        defaults.set(retentionDays, forKey: Preference.days)
        defaults.set(maxItems, forKey: Preference.items)
        defaults.set(excludedAppIDs, forKey: Preference.exclusions)
        store.configure(days: retentionDays, items: maxItems, exclusions: excludedAppIDs, now: clock())
        changed()
    }

    private func pruneIfNeeded(force: Bool = false) {
        let now = clock()
        guard force || lastPruned == nil || now.timeIntervalSince(lastPruned!) >= 60 else { return }
        lastPruned = now
        if store.prune(now: now) { changed() }
    }

    private func changed() {
        entries = store.entries
        guard !snapshot else { return }
        dirty = true
        ensureLoaded()
        scheduleSave()
    }

    private func ensureLoaded() {
        guard !snapshot, !loaded, !loading else { return }
        loading = true
        let storage = self.storage
        queue.async { [weak self] in
            let result = Result { try storage.load() }
            self?.loadResultOnQueue = result
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.loaded else { return }
                self.acceptLoaded(result)
                if self.dirty { self.scheduleSave(immediate: !self.started) }
            }
        }
    }

    private func acceptLoaded(_ result: Result<[ClipboardEntry], Error>) {
        loading = false
        loaded = true
        requestingPersistenceAccess = false
        switch result {
        case .success(let restored):
            error = storageError
            let retained = clearedDuringLoad ? [] : restored.filter { !removedDuringLoad.contains($0.id) }
            store = ClipboardHistoryStore(entries: store.entries + retained,
                retentionDays: retentionDays, maxItems: maxItems,
                excludedAppIDs: excludedAppIDs, now: clock())
            entries = store.entries
            if store.entries != restored { dirty = true }
            removedDuringLoad.removeAll()
            clearedDuringLoad = false
        case .failure(let failure): disablePersistence(failure)
        }
    }

    private func scheduleSave(immediate: Bool = false) {
        guard !snapshot, loaded, storageError == nil, dirty else { return }
        saveWork?.cancel()
        saveRevision += 1
        let revision = saveRevision, values = entries, storage = self.storage
        let work = DispatchWorkItem { [weak self] in
            let result = Result { try storage.save(values) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success:
                    if self.saveRevision == revision { self.dirty = false; self.saveWork = nil }
                case .failure(let failure): self.disablePersistence(failure)
                }
            }
        }
        saveWork = work
        queue.asyncAfter(deadline: .now() + (immediate ? 0 : saveDelay), execute: work)
    }

    private func disablePersistence(_ failure: Error) {
        saveWork?.cancel(); saveWork = nil
        storageError = ((failure as? ClipboardFailure) ?? .storageUnavailable).localizedDescription
        error = storageError
    }

    private func report(_ failure: ClipboardFailure) {
        error = storageError.map { $0 + " " + failure.localizedDescription } ?? failure.localizedDescription
    }
}
