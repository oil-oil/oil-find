import Foundation
import Darwin

public enum CoverageReason: String, Codable, CaseIterable {
    case noAccess, dependency, packages, library, system, userExcluded, cloud, volumes
    public var scopeKey: String? {
        switch self {
        case .dependency: return "dependency"
        case .packages: return "packages"
        case .library: return "library"
        case .system: return "system"
        default: return nil
        }
    }
}
public struct CoverageBucket: Codable, Equatable {
    public var count: UInt64 = 0
    public var examples: [String] = []
    public init(count: UInt64 = 0, examples: [String] = []) { self.count = count; self.examples = Array(examples.prefix(5)) }
}
public struct CoverageStats: Codable, Equatable {
    public var buckets: [CoverageReason: CoverageBucket] = [:]
    public init() {}
    public subscript(_ reason: CoverageReason) -> CoverageBucket { buckets[reason] ?? CoverageBucket() }
    public var scopeCount: UInt64 { CoverageReason.allCases.filter { $0.scopeKey != nil }.reduce(0) { $0 + self[$1].count } }
    public mutating func record(_ reason: CoverageReason, path: UnsafeBufferPointer<UInt8>) {
        var bucket = self[reason]
        bucket.count &+= 1
        // Only the first five examples allocate Strings; all other observations are counters.
        if bucket.examples.count < 5 {
            let example = String(decoding: path, as: UTF8.self)
            if !bucket.examples.contains(example) { bucket.examples.append(example) }
        }
        buckets[reason] = bucket
    }
    public mutating func record(_ reason: CoverageReason, parent: UnsafeBufferPointer<UInt8>, name: UnsafeBufferPointer<UInt8>) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: parent.count + name.count + 1) { path in
            path.baseAddress!.update(from: parent.baseAddress!, count: parent.count)
            var length = parent.count
            if length == 0 || path[length - 1] != 47 { path[length] = 47; length += 1 }
            path.baseAddress!.advanced(by: length).update(from: name.baseAddress!, count: name.count)
            record(reason, path: UnsafeBufferPointer(start: path.baseAddress, count: length + name.count))
        }
    }
    public mutating func merge(_ other: CoverageStats) {
        for reason in CoverageReason.allCases {
            let incoming = other[reason]
            guard incoming.count > 0 else { continue }
            var bucket = self[reason]; bucket.count &+= incoming.count
            for example in incoming.examples where bucket.examples.count < 5 && !bucket.examples.contains(example) { bucket.examples.append(example) }
            buckets[reason] = bucket
        }
    }
    public mutating func refreshVolumes(excluding indexedRoots: Set<String> = []) {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        var paths: [String] = []
        if let mounts {
            for i in 0..<Int(count) {
                var mount = mounts[i]
                withUnsafeBytes(of: &mount.f_mntonname) { raw in
                    let bytes = raw.bindMemory(to: UInt8.self).prefix(while: { $0 != 0 })
                    if bytes.starts(with: "/Volumes/".utf8) {
                        paths.append(String(decoding: bytes, as: UTF8.self))
                    }
                }
            }
        }
        refreshVolumes(mountPaths: paths, excluding: indexedRoots)
    }
    mutating func refreshVolumes(mountPaths: [String], excluding indexedRoots: Set<String>) {
        var bucket = CoverageBucket()
        for path in mountPaths where path.hasPrefix("/Volumes/") && !indexedRoots.contains(path) {
            bucket.count += 1
            if bucket.examples.count < 5 { bucket.examples.append(path) }
        }
        buckets[.volumes] = bucket
    }
}
public enum CoverageExplanation: Equatable {
    case indexed, scope(CoverageReason), userExcluded(String), noAccess, volume, cloud, pending
}
public enum Coverage {
    // Cold, single-path inspection. All filesystem work stays outside the index lock.
    public static func explain(path: String, config: IndexConfig, store: IndexStore?) -> CoverageExplanation {
        let path = path.precomposedStringWithCanonicalMapping
        if store?.read({ store!.containsPath(path) }) == true { return .indexed }
        let root = config.rootPath.precomposedStringWithCanonicalMapping
        let withinVolumeRoot = root.hasPrefix("/Volumes/") && (path == root || path.hasPrefix(root + "/"))
        if (path == "/Volumes" || path.hasPrefix("/Volumes/")) && !withinVolumeRoot { return .volume }
        for excluded in config.userExcludedPaths where path == excluded || path.hasPrefix(excluded == "/" ? "/" : excluded + "/") { return .userExcluded(excluded) }
        var info = stat()
        let exists = path.withCString { lstat($0, &info) == 0 }
        let reason = Array(path.utf8).withUnsafeBufferPointer { config.exclusionReason(path: $0, isDirectory: !exists || info.st_mode & S_IFMT == S_IFDIR) }
        if let reason {
            if reason == .noAccess { return .noAccess }
            if reason.scopeKey != nil { return .scope(reason) }
        }
        if !exists && (errno == EPERM || errno == EACCES) { return .noAccess }
        var ancestor = exists && info.st_mode & S_IFMT == S_IFDIR ? path : (path as NSString).deletingLastPathComponent
        while !ancestor.isEmpty {
            var s = stat()
            let result = ancestor.withCString { lstat($0, &s) }
            if result != 0 && (errno == EPERM || errno == EACCES) { return .noAccess }
            if result == 0 && s.st_flags & UInt32(SF_DATALESS) != 0 { return .cloud }
            let fd = ancestor.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
            if fd >= 0 { close(fd) }
            else if errno == EPERM || errno == EACCES { return .noAccess }
            if ancestor == "/" { break }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        return .pending
    }
}
