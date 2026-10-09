import Foundation
import Darwin
import COilFind

public struct ScanBuffer {
    public init() {}
    public var ids: [UInt32] = [], parents: [UInt32] = [], sizes: [UInt32] = [], mtimes: [UInt32] = []
    public var flags: [UInt8] = [], depths: [UInt8] = [], kinds: [UInt8] = []
    public var nameLens: [UInt32] = [], nameBytes: [UInt8] = []
    mutating func append(id: UInt32, parent: UInt32, size: UInt32, mtime: UInt32, flags: UInt8, depth: UInt8, kind: UInt8, name: UnsafeBufferPointer<UInt8>) {
        ids.append(id); parents.append(parent); sizes.append(size); mtimes.append(mtime)
        self.flags.append(flags); depths.append(depth); kinds.append(kind)
        nameLens.append(UInt32(name.count)); nameBytes.append(contentsOf: name)
    }
}
public struct ScanOutput {
    public init(buffers: [ScanBuffer], count: Int, homeIndex: UInt32, elapsed: Double, finishedAt: UInt64, coverage: CoverageStats = CoverageStats()) {
        self.buffers = buffers; self.count = count; self.homeIndex = homeIndex; self.elapsed = elapsed; self.finishedAt = finishedAt; self.coverage = coverage
    }
    public let buffers: [ScanBuffer]
    public let count: Int
    public let homeIndex: UInt32
    public let elapsed: Double
    public let finishedAt: UInt64
    public var coverage = CoverageStats()
}
private struct DirTask {
    var path: [UInt8], name: [UInt8], parentName: [UInt8], grandparentName: [UInt8]
    var fileid: UInt64, dev: Int32
    var id: UInt32, depth: UInt8, inherited: UInt8
}
private struct Candidate {
    var path: [UInt8]?, namePtr: UnsafePointer<UInt8>, nameLen: Int, normalized: [UInt8]?
    var fileid: UInt64, dev: Int32
    var type: UInt32, bsdFlags: UInt32, size: UInt64, mtime: Int64, parent: UInt32, depth: UInt8, inherited: UInt8
    func withName<T>(_ body: (UnsafeBufferPointer<UInt8>) -> T) -> T {
        if let normalized { return normalized.withUnsafeBufferPointer(body) }
        return body(UnsafeBufferPointer(start: namePtr, count: nameLen))
    }
}
// Each worker owns one slot, and snapshots are read only after concurrentPerform joins.
private final class ScanBufferSlots: @unchecked Sendable {
    private let pointer: UnsafeMutablePointer<ScanBuffer>
    private let count: Int
    init(count: Int) {
        self.count = count
        pointer = UnsafeMutablePointer<ScanBuffer>.allocate(capacity: count)
        pointer.initialize(repeating: ScanBuffer(), count: count)
    }
    deinit { pointer.deinitialize(count: count); pointer.deallocate() }
    subscript(index: Int) -> ScanBuffer {
        get { pointer[index] }
        set { pointer[index] = newValue }
    }
    func snapshot() -> [ScanBuffer] { Array(UnsafeBufferPointer(start: pointer, count: count)) }
}
private final class DirectoryOpenHook: @unchecked Sendable {
    let body: (String) -> Void
    init(_ body: @escaping (String) -> Void) { self.body = body }
    func call(_ path: String) { body(path) }
}
// Synchronize close with each syscall so cancellation cannot race descriptor reuse.
internal final class DirectoryDescriptor {
    private let lock = NSLock()
    private var fd: Int32
    init(_ fd: Int32) { self.fd = fd }
    func use<T>(_ body: (Int32) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(fd) }
    func close() { lock.lock(); defer { lock.unlock() }; if fd >= 0 { Darwin.close(fd); fd = -1 } }
    deinit { close() }
}
public final class Scanner {
    public let config: IndexConfig
    public let threads: Int
    private let condition = NSCondition()
    private var tasks: [DirTask] = []
    private let descriptorLock = NSLock()
    private var descriptors: [DirectoryDescriptor] = []
    private var active = 0, nextId: UInt32 = 1
    private var cancelled = false
    private var runStarted = false
    private var coverage = CoverageStats()
    private let coverageLock = NSLock()
    private var home: UInt32 = UInt32.max
    private let homeBytes = Array(NSHomeDirectory().utf8)
    private let rootPathLength: Int
    private let excludedNameBytes: [[UInt8]]
    private var allowedDevices = Set<Int32>()
    private var directoryOpenHook: DirectoryOpenHook?, directoryCompletionHook: DirectoryOpenHook?
    private let directoryOpenHookLock = NSLock()
    public init(config: IndexConfig, threads: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.config = config; self.threads = max(1, threads)
        rootPathLength = config.rootPath.utf8.count
        excludedNameBytes = config.effectiveExcludedNames.map { Array($0.utf8) }
    }
    internal func installDirectoryOpenHook(_ hook: ((String) -> Void)?) {
        condition.lock(); defer { condition.unlock() }
        precondition(!runStarted, "the directory-open hook must be installed before run")
        directoryOpenHook = hook.map { DirectoryOpenHook($0) }
    }
    internal func installDirectoryCompletionHook(_ hook: ((String) -> Void)?) {
        condition.lock(); defer { condition.unlock() }
        precondition(!runStarted, "the directory-completion hook must be installed before run")
        directoryCompletionHook = hook.map { DirectoryOpenHook($0) }
    }
    public var scannedCount: Int { condition.lock(); defer { condition.unlock() }; return Int(nextId) }
    public func cancel() {
        condition.lock(); cancelled = true; condition.broadcast()
        descriptorLock.lock(); let handles = descriptors; descriptorLock.unlock()
        condition.unlock()
        for handle in handles { handle.close() }
    }
    private func register(_ fd: Int32) -> DirectoryDescriptor? {
        let handle = DirectoryDescriptor(fd)
        condition.lock(); defer { condition.unlock() }
        guard !cancelled else { handle.close(); return nil }
        descriptorLock.lock(); descriptors.append(handle); descriptorLock.unlock()
        return handle
    }
    private func release(_ handle: DirectoryDescriptor) {
        handle.close()
        descriptorLock.lock(); descriptors.removeAll { $0 === handle }; descriptorLock.unlock()
    }
    private func device(_ path: String) -> Int32? { var s = stat(); return path.withCString { stat($0, &s) == 0 ? Int32(s.st_dev) : nil } }
    private func record(_ reason: CoverageReason, _ path: UnsafeBufferPointer<UInt8>) {
        coverageLock.lock(); coverage.record(reason, path: path); coverageLock.unlock()
    }
    private func excluded(_ path: [UInt8]) -> Bool {
        path.withUnsafeBufferPointer {
            let excluded = config.isExcluded(path: $0)
            if excluded, let reason = config.exclusionReason(path: $0) { record(reason, $0) }
            return excluded
        }
    }
    public func run() -> ScanOutput? {
        condition.lock()
        guard !runStarted && !cancelled else { condition.unlock(); return nil }
        runStarted = true
        let directoryOpenHook = self.directoryOpenHook, directoryCompletionHook = self.directoryCompletionHook
        condition.unlock()
        let start = CFAbsoluteTimeGetCurrent()
        if config.rootPath == "/" { coverage.refreshVolumes() }
        let rootFD = config.rootPath.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard rootFD >= 0 else { return nil }
        var rootStat = stat()
        let rootValid = fstat(rootFD, &rootStat) == 0 && (rootStat.st_mode & S_IFMT) == S_IFDIR
        close(rootFD)
        guard rootValid else { return nil }
        let rootDev = Int32(rootStat.st_dev)
        allowedDevices = [rootDev]
        if config.rootPath == "/", let dataDev = device("/System/Volumes/Data") { allowedDevices.insert(dataDev) }
        condition.lock()
        guard !cancelled else { condition.unlock(); return nil }
        var rootTaskPath = Array(config.rootPath.utf8); rootTaskPath.append(0)
        let rootIsPackage = Array((config.rootPath as NSString).lastPathComponent.utf8).withUnsafeBufferPointer { Classifier.isPackageExtension($0) }
        tasks = (excluded(Array(config.rootPath.utf8)) || (!config.indexPackageContents && rootIsPackage)) ? [] : [DirTask(path: rootTaskPath, name: [], parentName: [], grandparentName: [], fileid: UInt64(rootStat.st_ino), dev: rootDev, id: 0, depth: UInt8(min(config.rootPath.split(separator: "/").count, 255)), inherited: 0)]
        home = config.rootPath == NSHomeDirectory() ? 0 : UInt32.max
        condition.unlock()
        let bufferSlots = ScanBufferSlots(count: threads)
        DispatchQueue.concurrentPerform(iterations: threads) { worker in
            var local = ScanBuffer()
            let scratchSize = 256 * 1024
            let scratch = UnsafeMutableRawPointer.allocate(byteCount: scratchSize, alignment: 8)
            let entries = UnsafeMutablePointer<oilfind_dirent>.allocate(capacity: scratchSize / 32)
            defer { scratch.deallocate(); entries.deallocate(); bufferSlots[worker] = local }
            while true {
                condition.lock()
                while tasks.isEmpty && active > 0 && !cancelled { condition.wait() }
                if cancelled || (tasks.isEmpty && active == 0) { condition.unlock(); break }
                let task = tasks.removeLast(); active += 1; condition.unlock()
                var children: [DirTask] = []
                do {
                    if let directoryOpenHook {
                        let relative = task.path[rootPathLength..<(task.path.count - 1)].drop(while: { $0 == 47 })
                        directoryOpenHookLock.lock()
                        directoryOpenHook.call(String(decoding: relative, as: UTF8.self))
                        directoryOpenHookLock.unlock()
                    }
                    condition.lock(); let shouldStop = cancelled; condition.unlock()
                    if shouldStop { condition.lock(); active -= 1; condition.broadcast(); condition.unlock(); continue }
                    let fd = task.path.withUnsafeBufferPointer {
                        open(UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    }
                    if fd >= 0 {
                        guard let handle = register(fd) else { condition.lock(); active -= 1; condition.broadcast(); condition.unlock(); continue }
                        defer { release(handle) }
                        var opened = stat()
                        guard handle.use({ fstat($0, &opened) }) == 0, opened.st_mode & S_IFMT == S_IFDIR, UInt64(opened.st_ino) == task.fileid, Int32(opened.st_dev) == task.dev, allowedDevices.contains(Int32(opened.st_dev)) else { condition.lock(); active -= 1; condition.broadcast(); condition.unlock(); continue }
                        let filterFiles = task.path.withUnsafeBufferPointer { config.filtersFiles(inDirectory: UnsafeBufferPointer(start: $0.baseAddress, count: $0.count - 1)) }
                        let isHome = task.path.dropLast().elementsEqual(homeBytes)
                        let inherited = task.name.withUnsafeBufferPointer { n in task.grandparentName.withUnsafeBufferPointer { p in Classifier.inheritedForChildren(dirFlags: task.id == 0 ? SiftFlag.dir : task.inherited, dirName: n, dirDepth: task.depth, parentName: p, isHome: isHome) } }
                        while true {
                            condition.lock(); let beforeRead = cancelled; condition.unlock()
                            if beforeRead { break }
                            let n = handle.use { sift_read_dir($0, scratch, scratchSize, entries, Int32(scratchSize / 32)) }
                            condition.lock(); let stop = cancelled; condition.unlock()
                            if stop { break }
                            if n <= 0 { if n < 0 && (errno == EPERM || errno == EACCES) { task.path.dropLast().withContiguousStorageIfAvailable { record(.noAccess, $0) } }; break }
                            var batch: [Candidate] = []
                            batch.reserveCapacity(Int(n))
                            for i in 0..<Int(n) {
                                let e = entries[i]
                                if e.name_len == 0 { continue }
                                if e.error != 0 {
                                    if e.error == EPERM || e.error == EACCES {
                                        let name = UnsafeBufferPointer(start: UnsafeRawPointer(e.name).assumingMemoryBound(to: UInt8.self), count: Int(e.name_len))
                                        coverageLock.lock()
                                        task.path.dropLast().withContiguousStorageIfAvailable { coverage.record(.noAccess, parent: $0, name: name) }
                                        coverageLock.unlock()
                                    }
                                    continue
                                }
                                let raw = UnsafeBufferPointer(start: UnsafeRawPointer(e.name).assumingMemoryBound(to: UInt8.self), count: Int(e.name_len))
                                if raw.elementsEqual([46]) || raw.elementsEqual([46, 46]) { continue }
                                let normalized = raw.contains(where: { $0 >= 128 }) ? Array(String(decoding: raw, as: UTF8.self).precomposedStringWithCanonicalMapping.utf8) : nil
                                let isDir = e.type == 1

                                if !isDir && (filterFiles || !config.userExcludedPaths.isEmpty) {
                                    let isExcluded = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: task.path.count + (normalized?.count ?? raw.count)) { path in
                                        let prefixCount = task.path.count - 1
                                        task.path.withUnsafeBufferPointer { path.baseAddress!.update(from: $0.baseAddress!, count: prefixCount) }
                                        var length = prefixCount
                                        if length == 0 || path[length - 1] != 47 { path[length] = 47; length += 1 }
                                        if let normalized {
                                            normalized.withUnsafeBufferPointer { path.baseAddress!.advanced(by: length).update(from: $0.baseAddress!, count: $0.count) }
                                            length += normalized.count
                                        } else {
                                            path.baseAddress!.advanced(by: length).update(from: raw.baseAddress!, count: raw.count)
                                            length += raw.count
                                        }
                                        let span = UnsafeBufferPointer(start: path.baseAddress, count: length)
                                        let excluded = config.isExcluded(path: span, isDirectory: false)
                                        if excluded, let reason = config.exclusionReason(path: span, isDirectory: false) { record(reason, span) }
                                        return excluded
                                    }
                                    if isExcluded { continue }
                                }
                                var childPath: [UInt8]? = nil
                                if isDir {
                                    if !allowedDevices.contains(e.dev) { continue }
                                    var path = Array(task.path.dropLast())
                                    if path.last != 47 { path.append(47) }
                                    if let normalized { path.append(contentsOf: normalized) } else { path.append(contentsOf: raw) }
                                    if excluded(path) { continue }
                                    path.append(0)
                                    childPath = path
                                }
                                batch.append(Candidate(path: childPath, namePtr: raw.baseAddress!, nameLen: raw.count, normalized: normalized, fileid: e.fileid, dev: e.dev, type: e.type, bsdFlags: e.bsd_flags, size: e.size, mtime: e.mtime, parent: task.id, depth: UInt8(min(Int(task.depth) + 1, 255)), inherited: inherited))
                            }
                            condition.lock(); let base = nextId; nextId &+= UInt32(batch.count); condition.unlock()
                            for (offset, item) in batch.enumerated() {
                                let id = base + UInt32(offset)
                                let f = item.withName { Classifier.flags(name: $0, type: item.type, bsdFlags: item.bsdFlags, inherited: item.inherited) }
                                let k = item.withName { Classifier.kind(name: $0, flags: f) }
                                let size = item.type == 1 ? UInt32(0) : IndexStore.encodeSize(item.size)
                                item.withName { local.append(id: id, parent: item.parent, size: size, mtime: UInt32(clamping: item.mtime), flags: f, depth: item.depth, kind: k, name: $0) }
                                if let path = item.path {
                                    if path.dropLast().elementsEqual(homeBytes) { condition.lock(); home = id; condition.unlock() }
                                    if item.bsdFlags & UInt32(SF_DATALESS) != 0 { path.dropLast().withContiguousStorageIfAvailable { record(.cloud, $0) } }
                                    else if !config.indexPackageContents && f & SiftFlag.package != 0 { path.dropLast().withContiguousStorageIfAvailable { record(.packages, $0) } }
                                    else { children.append(DirTask(path: path, name: item.withName(Array.init), parentName: task.name, grandparentName: task.parentName, fileid: item.fileid, dev: item.dev, id: id, depth: item.depth, inherited: f)) }
                                }
                            }
                        }
                    } else if errno == EPERM || errno == EACCES {
                        task.path.dropLast().withContiguousStorageIfAvailable { record(.noAccess, $0) }
                    }
                }
                if let directoryCompletionHook {
                    let relative = task.path[rootPathLength..<(task.path.count - 1)].drop(while: { $0 == 47 })
                    directoryCompletionHook.call(String(decoding: relative, as: UTF8.self))
                }
                condition.lock(); tasks.append(contentsOf: children); active -= 1; condition.broadcast(); condition.unlock()
            }
        }
        condition.lock(); let wasCancelled = cancelled, count = Int(nextId), homeIndex = home; condition.unlock()
        if wasCancelled { return nil }
        let buffers = bufferSlots.snapshot()
        return ScanOutput(buffers: buffers, count: count, homeIndex: homeIndex, elapsed: CFAbsoluteTimeGetCurrent() - start, finishedAt: UInt64(Date().timeIntervalSince1970), coverage: coverage)
    }
}
