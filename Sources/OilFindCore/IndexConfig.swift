import Foundation

public struct IndexConfig {
    public var rootPath: String
    public var excludedPaths: [String] { didSet { rebuildExcludedBytes() } }
    public var excludedNames: Set<String> { didSet { excludedNameBytes = excludedNames.map { Array($0.utf8) } } }
    public var limitedMode: Bool
    public var userExcludedPaths: [String] { didSet { rebuildExcludedBytes() } }
    public var indexDependencyDirs: Bool
    public var indexPackageContents: Bool
    public var indexUserLibrary: Bool
    public var indexSystemDirs: Bool
    static let dependencyNames = Set("node_modules site-packages .venv venv Pods DerivedData .git .svn .hg bower_components __pycache__ .gradle .cargo .rustup .npm .pnpm-store .yarn .cache .next .nuxt .build .swiftpm .tox .mypy_cache .pytest_cache .terraform".split(separator: " ").map(String.init))
    private static let dependencyBytes = dependencyNames.map { Array($0.utf8) }
    private let userLibraryBytes = Array((NSHomeDirectory() + "/Library").utf8)
    private static let systemBytes = Array("/System".utf8)
    private static let applicationsBytes = Array("/System/Applications".utf8)
    private static let systemRoots = ["/Library", "/usr", "/bin", "/sbin", "/private", "/opt"].map { Array($0.utf8) }
    var effectiveExcludedNames: Set<String> { indexDependencyDirs ? excludedNames : excludedNames.union(Self.dependencyNames) }
    private var excludedNameBytes: [[UInt8]]
    private var excludedPathBytes: [[UInt8]]
    private var userExcludedPathsBytes: [[UInt8]]
    private let restrictedBytes = ["Containers", "Group Containers", "Daemon Containers", "Mobile Documents", "CloudStorage"].map { Array((NSHomeDirectory() + "/Library/" + $0).utf8) }
    public init(rootPath: String = "/", excludedPaths: [String] = [], excludedNames: Set<String> = [], limitedMode: Bool = false, userExcludedPaths: [String] = [], indexDependencyDirs: Bool = false, indexPackageContents: Bool = false, indexUserLibrary: Bool = false, indexSystemDirs: Bool = false) {
        // Normalize components without Foundation's /private/var symlink rewriting.
        let absolute = rootPath.hasPrefix("/") ? rootPath : FileManager.default.currentDirectoryPath + "/" + rootPath
        var components: [Substring] = []
        for part in absolute.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !components.isEmpty { components.removeLast() } }
            else { components.append(part) }
        }
        self.rootPath = "/" + components.joined(separator: "/")
        self.excludedPaths = excludedPaths
        self.excludedNames = excludedNames
        self.limitedMode = limitedMode
        self.userExcludedPaths = userExcludedPaths
        self.indexDependencyDirs = indexDependencyDirs; self.indexPackageContents = indexPackageContents
        self.indexUserLibrary = indexUserLibrary; self.indexSystemDirs = indexSystemDirs
        self.excludedNameBytes = excludedNames.map { Array($0.utf8) }
        self.excludedPathBytes = excludedPaths.map { Array($0.utf8) }
        self.userExcludedPathsBytes = userExcludedPaths.map { Array($0.utf8) }
    }
    public static func standard(limited: Bool = false) -> IndexConfig {
        let home = NSHomeDirectory()
        var paths = ["/System/Volumes", "/Volumes", "/dev", "/cores", "/.vol", "/private/var/folders", "/private/var/db", "/private/var/vm", "/private/var/run", "/Library/Caches", "\(home)/Library/Caches", "\(home)/.Trash"]
        if limited { paths += ["Library/Containers", "Library/Group Containers", "Library/Daemon Containers", "Library/Mobile Documents", "Library/CloudStorage"].map { "\(home)/\($0)" } }
        return IndexConfig(excludedPaths: paths, excludedNames: Set(".Spotlight-V100 .fseventsd .DocumentRevisions-V100 .TemporaryItems .Trashes .MobileBackups".split(separator: " ").map(String.init)), limitedMode: limited)
    }
    public var fingerprint: UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        let parts = [rootPath, limitedMode ? "1" : "0", indexDependencyDirs ? "1" : "0", indexPackageContents ? "1" : "0", indexUserLibrary ? "1" : "0", indexSystemDirs ? "1" : "0"] + excludedPaths.sorted() + ["|"] + excludedNames.sorted() + ["|"] + userExcludedPaths.sorted()
        for part in parts { for b in part.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }; h = (h ^ 0xff) &* 0x100000001b3 }
        return h
    }
    // Catalog identity and relative exclusions remain stable after a volume rename.
    public func fingerprint(volumeUUID: String) -> UInt64 {
        var relative = self
        func canonical(_ path: String) -> String {
            if path == rootPath { return "/" }
            if path.hasPrefix(rootPath + "/") { return String(path.dropFirst(rootPath.count)) }
            return path
        }
        relative.rootPath = "/volume/" + volumeUUID
        relative.excludedPaths = excludedPaths.map(canonical)
        relative.userExcludedPaths = userExcludedPaths.map(canonical)
        return relative.fingerprint
    }
    internal func filtersFiles(inDirectory path: UnsafeBufferPointer<UInt8>) -> Bool {
        (!indexSystemDirs && path.elementsEqual(Self.systemBytes))
            || (!indexUserLibrary && path.elementsEqual(userLibraryBytes))
    }
    public func isExcluded(path: UnsafeBufferPointer<UInt8>, isDirectory: Bool = true) -> Bool {
        exclusionReason(path: path, isDirectory: isDirectory) != nil || isBuiltInExcluded(path: path, isDirectory: isDirectory)
    }
    public func exclusionReason(path: UnsafeBufferPointer<UInt8>, isDirectory: Bool = true) -> CoverageReason? {
        for bytes in userExcludedPathsBytes where starts(path, with: bytes) { return .userExcluded }
        if limitedMode {
            for bytes in restrictedBytes where starts(path, with: bytes) { return .noAccess }
        }
        if !indexSystemDirs {
            for root in Self.systemRoots where starts(path, with: root) { return .system }
            if starts(path, with: Self.systemBytes), path.count > 8, !starts(path, with: Self.applicationsBytes) { return .system }
        }
        if !indexUserLibrary && starts(path, with: userLibraryBytes) && path.count > userLibraryBytes.count {
            let start = userLibraryBytes.count + 1
            var end = start
            while end < path.count && path[end] != 47 { end += 1 }
            let child = UnsafeBufferPointer(start: path.baseAddress!.advanced(by: start), count: end - start)
            if !child.elementsEqual("Mobile Documents".utf8) && !child.elementsEqual("CloudStorage".utf8) { return .library }
        }
        var start = 0
        while start < path.count {
            if path[start] == 47 { start += 1; continue }
            var end = start
            while end < path.count && path[end] != 47 { end += 1 }
            let component = UnsafeBufferPointer(start: path.baseAddress!.advanced(by: start), count: end - start)
            if (end < path.count || isDirectory) && !indexDependencyDirs && Self.dependencyBytes.contains(where: { component.elementsEqual($0) }) { return .dependency }
            if !indexPackageContents && end < path.count && Classifier.isPackageExtension(component) { return .packages }
            start = end
        }
        return nil
    }
    private func isBuiltInExcluded(path: UnsafeBufferPointer<UInt8>, isDirectory: Bool) -> Bool {
        for bytes in excludedPathBytes where starts(path, with: bytes) { return true }
        var start = 0
        while start < path.count {
            if path[start] == 47 { start += 1; continue }
            var end = start
            while end < path.count && path[end] != 47 { end += 1 }
            let component = UnsafeBufferPointer(start: path.baseAddress!.advanced(by: start), count: end - start)
            if (end < path.count || isDirectory) && excludedNameBytes.contains(where: { component.elementsEqual($0) }) { return true }
            start = end
        }
        return false
    }
    private func starts(_ path: UnsafeBufferPointer<UInt8>, with prefix: [UInt8]) -> Bool {
        (prefix == [47] && path.first == 47) || path.count >= prefix.count && path.prefix(prefix.count).elementsEqual(prefix)
            && (path.count == prefix.count || path[prefix.count] == 47)
    }
    private mutating func rebuildExcludedBytes() {
        excludedPathBytes = excludedPaths.map { Array($0.utf8) }
        userExcludedPathsBytes = userExcludedPaths.map { Array($0.utf8) }
    }
}
