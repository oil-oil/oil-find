import Foundation
import Darwin
import CoreServices
import COilFind

public struct FSChange {
    public var path: String, flags: UInt32, eventId: UInt64
    public init(path: String, flags: UInt32 = 0, eventId: UInt64 = 0) { self.path = path; self.flags = flags; self.eventId = eventId }
}
public struct ApplySummary {
    public var inserted: Int = 0, updated: Int = 0, removed: Int = 0, scannedDirs: Int = 0, elapsedMs: Double = 0, mutationMs: Double = 0
    public init() {}
}
private struct DiskChange {
    var bytes: [UInt8], flags: UInt32, attrs: EntryAttrs?, nameStart: Int
}
private struct ScanRequest { var change: Int, end: Int, reconcile: Bool }
private final class Subtree {
    var count = 0, namesLen = 0
    private var capacity = 256, namesCapacity = 4096
    var parent: UnsafeMutablePointer<UInt32>, nameOff: UnsafeMutablePointer<UInt32>
    var type: UnsafeMutablePointer<UInt32>, bsdFlags: UnsafeMutablePointer<UInt32>
    var fileid: UnsafeMutablePointer<UInt64>, dev: UnsafeMutablePointer<Int32>
    var size: UnsafeMutablePointer<UInt64>, mtime: UnsafeMutablePointer<Int64>, names: UnsafeMutablePointer<UInt8>
    private static func alloc<T>(_ t: T.Type, _ n: Int) -> UnsafeMutablePointer<T> {
        malloc(n * MemoryLayout<T>.stride)!.bindMemory(to: t, capacity: n)
    }
    init() {
        parent = Self.alloc(UInt32.self, 256); nameOff = Self.alloc(UInt32.self, 257)
        type = Self.alloc(UInt32.self, 256); bsdFlags = Self.alloc(UInt32.self, 256)
        fileid = Self.alloc(UInt64.self, 256); dev = Self.alloc(Int32.self, 256)
        size = Self.alloc(UInt64.self, 256); mtime = Self.alloc(Int64.self, 256); names = Self.alloc(UInt8.self, 4096)
        nameOff[0] = 0
    }
    deinit { free(parent); free(nameOff); free(type); free(bsdFlags); free(fileid); free(dev); free(size); free(mtime); free(names) }
    private func grow<T>(_ p: inout UnsafeMutablePointer<T>, _ n: Int) {
        p = realloc(p, n * MemoryLayout<T>.stride)!.bindMemory(to: T.self, capacity: n)
    }
    func append(parent p: Int, name: UnsafeBufferPointer<UInt8>, attrs: EntryAttrs, fileid: UInt64 = 0, dev: Int32 = 0) {
        if count == capacity {
            capacity += capacity / 2
            grow(&parent, capacity); grow(&nameOff, capacity+1); grow(&type, capacity)
            grow(&bsdFlags, capacity); grow(&self.fileid, capacity); grow(&self.dev, capacity); grow(&size, capacity); grow(&mtime, capacity)
        }
        if namesLen + name.count > namesCapacity {
            namesCapacity = max(namesLen + name.count, namesCapacity + namesCapacity / 2); grow(&names, namesCapacity)
        }
        self.fileid[count] = fileid; self.dev[count] = dev
        parent[count] = UInt32(p); type[count] = attrs.type; bsdFlags[count] = attrs.bsdFlags
        size[count] = attrs.size; mtime[count] = attrs.mtime
        if !name.isEmpty { names.advanced(by: namesLen).update(from: name.baseAddress!, count: name.count) }
        namesLen += name.count; count += 1; nameOff[count] = UInt32(namesLen)
    }
    func attrs(_ i: Int) -> EntryAttrs { EntryAttrs(type: type[i], bsdFlags: bsdFlags[i], size: size[i], mtime: mtime[i]) }
    func name(_ i: Int) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(start: names.advanced(by: Int(nameOff[i])), count: Int(nameOff[i+1]-nameOff[i]))
    }
}

public final class IndexUpdater {
    private let cancellationLock = NSLock()
    private var cancelled = false
    private var descriptors: [DirectoryDescriptor] = []
    internal var isCancelled: Bool { cancellationLock.lock(); defer { cancellationLock.unlock() }; return cancelled }
    public func cancel() {
        cancellationLock.lock(); cancelled = true; let handles = descriptors; cancellationLock.unlock()
        for handle in handles { handle.close() }
    }
    private func register(_ fd: Int32) -> DirectoryDescriptor? {
        let handle = DirectoryDescriptor(fd)
        cancellationLock.lock(); defer { cancellationLock.unlock() }
        guard !cancelled else { handle.close(); return nil }
        descriptors.append(handle); return handle
    }
    private func release(_ handle: DirectoryDescriptor) {
        handle.close()
        cancellationLock.lock(); descriptors.removeAll { $0 === handle }; cancellationLock.unlock()
    }
    private var coverage = CoverageStats()
    private let config: IndexConfig
    private let devices: Set<dev_t>
    internal var onPhase3: (() -> Void)?
    internal var onReconcilePass: (() -> Void)?
    internal var onMergeChunk: (() -> Void)?
    internal var onSubtreeDirectoryOpen: ((UnsafeBufferPointer<UInt8>) -> Void)?
    // Only the path-normalization phase owns Strings; merge loops use byte spans.
    public init(config: IndexConfig) {
        self.config = config
        var s = stat(), d = Set<dev_t>()
        if stat(config.rootPath, &s) == 0 { d.insert(s.st_dev) }
        if config.rootPath == "/" && stat("/System/Volumes/Data", &s) == 0 { d.insert(s.st_dev) }
        devices = d
        _ = Pinyin.shared
    }
    private func allowed(_ bytes: UnsafeBufferPointer<UInt8>, isDirectory: Bool = true) -> Bool {
        let root = config.rootPath.utf8
        if bytes.count < root.count || !bytes.prefix(root.count).elementsEqual(root) { return false }
        if config.rootPath != "/" && bytes.count > root.count && bytes[root.count] != 47 { return false }
        if config.isExcluded(path: bytes, isDirectory: isDirectory) { return false }
        return true
    }
    private func attrs(_ path: [UInt8]) -> EntryAttrs? {
        guard !isCancelled else { return nil }
        var s = stat(), cpath = path; cpath.append(0)
        let ok = cpath.withUnsafeBufferPointer { lstat(UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self), &s) == 0 }
        if !ok && (errno == EPERM || errno == EACCES) {
            path.withUnsafeBufferPointer { coverage.record(.noAccess, path: $0) }
        }
        guard ok, devices.contains(s.st_dev) else { return nil }
        let t = s.st_mode & S_IFMT
        return EntryAttrs(type: t == S_IFDIR ? 1 : t == S_IFLNK ? 2 : t == S_IFREG ? 0 : 3, bsdFlags: s.st_flags, size: UInt64(max(0, s.st_size)), mtime: Int64(s.st_mtimespec.tv_sec))
    }
    public func apply(_ changes: [FSChange], to store: IndexStore) -> ApplySummary {
        apply(changes, to: store, mutationTime: nil)
    }
    // Internal timing excludes all disk I/O and measures exactly phases 2 and 4.
    internal func apply(_ changes: [FSChange], to store: IndexStore, mutationTime: ((Double) -> Void)?) -> ApplySummary {
        guard !isCancelled else { return ApplySummary() }
        let start = CFAbsoluteTimeGetCurrent()
        coverage = CoverageStats()
        var paths: [String: UInt32] = [:], maxId: UInt64 = 0
        var skippedPaths = Set<String>()
        for change in changes {
            if isCancelled { return ApplySummary() }
            maxId = max(maxId, change.eventId)
            var path = change.path
            if config.rootPath == "/" && (path == "/System/Volumes/Data" || path.hasPrefix("/System/Volumes/Data/")) {
                path.removeFirst("/System/Volumes/Data".count); if path.isEmpty { path = "/" }
            }
            while path.count > 1 && path.last == "/" { path.removeLast() }
            if path.utf8.contains(where: { $0 >= 128 }) { path = path.precomposedStringWithCanonicalMapping }
            let bytes = Array(path.utf8)
            let accepted = bytes.withUnsafeBufferPointer { span in
                if allowed(span) { return true }
                // Only a terminal excluded directory name needs a type check. File
                // deletions have no disk attrs and still need to reach the hash lookup.
                return allowed(span, isDirectory: false) && attrs(bytes)?.type != 1
            }
            if accepted { paths[path, default: 0] |= change.flags }
            else if skippedPaths.insert(path).inserted {
                bytes.withUnsafeBufferPointer { if let reason = config.exclusionReason(path: $0) { coverage.record(reason, path: $0) } }
            }
        }
        // FileEvents do not always include a separate parent-directory mtime event.
        // Refresh each immediate parent from disk in the same unlocked I/O phase.
        for path in Array(paths.keys) where path != config.rootPath {
            if let slash = path.lastIndex(of: "/") {
                let parent = slash == path.startIndex ? "/" : String(path[..<slash])
                if Array(parent.utf8).withUnsafeBufferPointer({ allowed($0) }) { paths[parent, default: 0] |= 0 }
            }
        }
        var actualName = [UInt8](repeating: 0, count: 1024)
        let disk = paths.keys.sorted().map { path -> DiskChange in
            var bytes = Array(path.utf8)
            let attributes = attrs(bytes), nameStart = (bytes.lastIndex(of: 47) ?? -1) + 1
            if attributes != nil && path != config.rootPath {
                let n = path.withCString { sift_actual_name($0, &actualName, actualName.count) }
                if n > 0 {
                    bytes.removeSubrange(nameStart...)
                    let raw = actualName.prefix(Int(n))
                    if raw.contains(where: { $0 >= 128 }) { bytes.append(contentsOf: String(decoding: raw, as: UTF8.self).precomposedStringWithCanonicalMapping.utf8) }
                    else { bytes.append(contentsOf: raw) }
                }
            }
            return DiskChange(bytes: bytes, flags: paths[path]!, attrs: attributes, nameStart: nameStart)
        }
        guard !isCancelled else { return ApplySummary() }
        var summary = ApplySummary(), requests: [ScanRequest] = [], mutationMs = 0.0
        requests.reserveCapacity(disk.count)
        var inheritedChanges = Set<UInt32>()
        func childInheritance(_ i: UInt32) -> UInt8 {
            let n = Int(i)
            return Classifier.inheritedForChildren(dirFlags: store.flags[n], dirName: store.nameBytes(i), dirDepth: store.depth[n], parentName: store.nameBytes(store.parent[Int(store.parent[n])]), isHome: i == store.homeIndex)
        }
        func update(_ i: UInt32, name: UnsafeBufferPointer<UInt8>, attrs: EntryAttrs) -> UInt32 {
            let wasDir = store.flags[Int(i)] & SiftFlag.dir != 0
            let before = wasDir ? childInheritance(i) : 0
            let result = store.update(i, name: name, attrs: attrs)
            if attrs.type == 1 && (!wasDir || result != i || childInheritance(result) != before) {
                inheritedChanges.insert(result)
            }
            return result
        }
        store.write {
            let begin = CFAbsoluteTimeGetCurrent(), beforeDeleted = store.deletedCount
            var sweep = false, changed = false
            for (ordinal, change) in disk.enumerated() {
                change.bytes.withUnsafeBufferPointer { path in
                    guard let attrs = change.attrs else {
                        if let i = store.resolve(bytes: path), i != 0 { sweep = store.remove(i) || sweep; changed = true }
                        return
                    }
                    if path.elementsEqual(config.rootPath.utf8) {
                        if attrs.type == 1 && change.flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 { requests.append(ScanRequest(change: ordinal, end: path.count, reconcile: true)) }
                        return
                    }
                    let parentEnd = change.nameStart == 1 ? 1 : change.nameStart - 1
                    let parentPath = UnsafeBufferPointer(start: path.baseAddress!, count: parentEnd)
                    guard let p = store.resolve(bytes: parentPath), store.flags[Int(p)] & SiftFlag.dir != 0 else {
                        var end = config.rootPath.utf8.count, ancestor: UInt32 = 0
                        while end < parentEnd {
                            if path[end] == 47 { end += 1 }
                            let a = end; while end < parentEnd && path[end] != 47 { end += 1 }
                            let name = UnsafeBufferPointer(start: path.baseAddress!.advanced(by: a), count: end-a)
                            guard let child = store.lookup(parent: ancestor, name: name), store.flags[Int(child)] & SiftFlag.dir != 0 else { break }
                            ancestor = child
                        }
                        requests.append(ScanRequest(change: ordinal, end: end, reconcile: false)); return
                    }
                    let name = UnsafeBufferPointer(start: path.baseAddress!.advanced(by: change.nameStart), count: path.count-change.nameStart)
                    if let i = store.lookup(parent: p, name: name) {
                        let n = update(i, name: name, attrs: attrs); changed = true
                        if n != i { summary.inserted += 1; sweep = true; if attrs.type == 1 { requests.append(ScanRequest(change: ordinal, end: path.count, reconcile: false)) } }
                        else { summary.updated += 1 }
                    } else {
                        _ = store.insert(parent: p, name: name, attrs: attrs); summary.inserted += 1; changed = true
                        if attrs.type == 1 { requests.append(ScanRequest(change: ordinal, end: path.count, reconcile: false)) }
                    }
                    if attrs.type == 1 && change.flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 { requests.append(ScanRequest(change: ordinal, end: path.count, reconcile: true)) }
                }
            }
            if sweep { store.sweep(); changed = true }
            if changed { store.version &+= 1 }
            summary.removed += Int(store.deletedCount - beforeDeleted)
            mutationMs += (CFAbsoluteTimeGetCurrent()-begin)*1000
        }
        var roots: [String: Bool] = [:]
        for request in requests {
            let path = String(decoding: disk[request.change].bytes.prefix(request.end), as: UTF8.self)
            roots[path] = (roots[path] ?? false) || request.reconcile
        }
        var outer: [(String, Bool)] = []
        for path in roots.keys.sorted() {
            if let i = outer.firstIndex(where: { path == $0.0 || path.hasPrefix($0.0 == "/" ? "/" : $0.0 + "/") }) {
                outer[i].1 = outer[i].1 || roots[path]!
            } else { outer.append((path, roots[path]!)) }
        }
        guard !isCancelled else { return summary }
        onPhase3?()
        let prepared = outer.compactMap { path, reconcile -> (root: [UInt8], isRoot: Bool, parentEnd: Int, reconcile: Bool, tree: Subtree)? in
            guard let tree = readSubtree(path) else { return nil }
            let bytes = Array(path.utf8), isRoot = path == config.rootPath
            let parentEnd = isRoot ? 0 : (bytes.lastIndex(of: 47) == 0 ? 1 : bytes.lastIndex(of: 47)!)
            return (bytes, isRoot, parentEnd, reconcile, tree)
        }
        guard !isCancelled else { return summary }
        summary.scannedDirs = prepared.count
        let ids = UnsafeMutablePointer<UInt32>.allocate(capacity: max(1, prepared.map { $0.tree.count }.max() ?? 0))
        defer { ids.deallocate() }
        let beforeDeleted = store.read { store.deletedCount }
        var reconcileRoots = Set<UInt32>()
        var reconcileBits: UnsafeMutablePointer<UInt8>?, bitsCapacity = 0
        defer { free(reconcileBits) }
        func mark(_ i: UInt32, bit: UInt8) {
            if Int(i) >= bitsCapacity {
                let capacity = store.capacity
                reconcileBits = realloc(reconcileBits, capacity)!.bindMemory(to: UInt8.self, capacity: capacity)
                reconcileBits!.advanced(by: bitsCapacity).initialize(repeating: 0, count: capacity - bitsCapacity)
                bitsCapacity = capacity
            }
            reconcileBits![Int(i)] |= bit
        }
        for item in prepared {
            if isCancelled { return summary }
            let tree = item.tree
            let rootParent = store.read {
                item.root.withUnsafeBufferPointer { store.resolve(bytes: UnsafeBufferPointer(start: $0.baseAddress, count: item.parentEnd)) }
            }
            guard item.isRoot || rootParent != nil else { continue }
            var j = 0
            while j < tree.count {
                if isCancelled { return summary }
                store.write {
                    let begin = CFAbsoluteTimeGetCurrent()
                    var changed = false
                    let end = min(tree.count, j + 20_000)
                    while j < end {
                        if j == 0 && item.isRoot { ids[j] = 0 }
                        else {
                            let p = j == 0 ? rootParent! : ids[Int(tree.parent[j])]
                            let name = tree.name(j), attrs = tree.attrs(j)
                            if let i = store.lookup(parent: p, name: name) {
                                ids[j] = update(i, name: name, attrs: attrs)
                                if ids[j] != i { summary.inserted += 1 } else { summary.updated += 1 }
                            } else {
                                ids[j] = store.insert(parent: p, name: name, attrs: attrs); summary.inserted += 1
                            }
                            changed = true
                        }
                        if item.reconcile { mark(ids[j], bit: 2) }
                        j += 1
                    }
                    if changed { store.version &+= 1 }
                    mutationMs += (CFAbsoluteTimeGetCurrent()-begin)*1000
                }
                onMergeChunk?()
            }
            if item.reconcile { reconcileRoots.insert(ids[0]); mark(ids[0], bit: 1) }
        }
        guard !isCancelled else { return summary }
        store.write {
            let begin = CFAbsoluteTimeGetCurrent()
            var changed = false
            if !reconcileRoots.isEmpty {
                // Mark all reconciliation roots together, then delete untouched descendants.
                // Non-reconciled merges may have grown the store after the last mark.
                mark(UInt32(store.count - 1), bit: 0)
                let bits = reconcileBits!
                onReconcilePass?()
                for i in 1..<store.count where bits[Int(store.parent[i])] & 1 != 0 { bits[i] |= 1 }
                onReconcilePass?()
                for i in 1..<store.count where bits[i] == 1 && store.isLive(UInt32(i)) {
                    _ = store.remove(UInt32(i)); changed = true
                }
            }
            if store.deletedCount != beforeDeleted { store.sweep(); changed = true }
            if !inheritedChanges.isEmpty {
                let affected = UnsafeMutablePointer<UInt8>.allocate(capacity: store.count)
                affected.initialize(repeating: 0, count: store.count)
                defer { affected.deallocate() }
                for i in inheritedChanges { affected[Int(i)] = 1 }
                let mask = SiftFlag.noise | SiftFlag.inPackage | SiftFlag.userArea
                for i in 1..<store.count {
                    let p = store.parent[i]
                    if affected[Int(p)] != 0 {
                        affected[i] = 1
                        store.flags[i] = (store.flags[i] & ~mask) | childInheritance(p)
                    }
                }
                changed = true
            }
            if !coverage.buckets.isEmpty { store.coverage.merge(coverage); changed = true }
            // Persist a changed event cursor even when the batch contains only excluded paths.
            if !changes.isEmpty && store.lastEventId != maxId { store.lastEventId = maxId; changed = true }
            if changed { store.version &+= 1 }
            summary.removed += Int(store.deletedCount - beforeDeleted)
            mutationMs += (CFAbsoluteTimeGetCurrent()-begin)*1000
        }
        if config.rootPath == "/" {
            var volumes = CoverageStats(); volumes.refreshVolumes()
            store.write {
                if store.coverage[.volumes] != volumes[.volumes] { store.coverage.buckets[.volumes] = volumes[.volumes]; store.version &+= 1 }
            }
        }
        summary.mutationMs = mutationMs
        mutationTime?(mutationMs)
        summary.elapsedMs = (CFAbsoluteTimeGetCurrent()-start)*1000
        return summary
    }
    private func readSubtree(_ root: String) -> Subtree? {
        guard !isCancelled else { return nil }
        var path = Array(root.utf8)
        // Capture the root identity before opening, just as queued children use bulk file IDs.
        var expected = stat()
        guard root.withCString({ lstat($0, &expected) }) == 0, expected.st_mode & S_IFMT == S_IFDIR,
              devices.contains(expected.st_dev), path.withUnsafeBufferPointer({ allowed($0) }) else { return nil }
        if let hook = onSubtreeDirectoryOpen { path.withUnsafeBufferPointer(hook) }
        guard !isCancelled else { return nil }
        let rootFD = root.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard rootFD >= 0 else { if errno == EPERM || errno == EACCES { path.withUnsafeBufferPointer { coverage.record(.noAccess, path: $0) } }; return nil }
        guard let rootHandle = register(rootFD) else { return nil }
        var opened = stat()
        guard rootHandle.use({ fstat($0, &opened) }) == 0, opened.st_mode & S_IFMT == S_IFDIR,
              opened.st_ino == expected.st_ino, opened.st_dev == expected.st_dev,
              devices.contains(opened.st_dev) else { release(rootHandle); return nil }
        let rootAttrs = EntryAttrs(type: 1, bsdFlags: opened.st_flags, size: UInt64(max(0, opened.st_size)), mtime: Int64(opened.st_mtimespec.tv_sec))
        let tree = Subtree()
        let rootName = root == config.rootPath ? [] : Array(path.suffix(from: (path.lastIndex(of: 47) ?? -1)+1))
        rootName.withUnsafeBufferPointer { tree.append(parent: 0, name: $0, attrs: rootAttrs) }
        let scratchSize = 256 * 1024
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: scratchSize, alignment: 8)
        let entries = UnsafeMutablePointer<oilfind_dirent>.allocate(capacity: scratchSize / 32)
        defer { scratch.deallocate(); entries.deallocate() }
        func descend(_ parent: Int, handle: DirectoryDescriptor) {
            defer { release(handle) }
            if isCancelled { return }
            if tree.bsdFlags[parent] & UInt32(SF_DATALESS) != 0 { path.withUnsafeBufferPointer { coverage.record(.cloud, path: $0) }; return }
            if !config.indexPackageContents {
                let isPackage = path.withUnsafeBufferPointer { bytes in
                    let start = (bytes.lastIndex(of: 47) ?? -1) + 1
                    return Classifier.isPackageExtension(UnsafeBufferPointer(start: bytes.baseAddress!.advanced(by: start), count: bytes.count - start))
                }
                if isPackage { path.withUnsafeBufferPointer { coverage.record(.packages, path: $0) }; return }
            }
            let filterFiles = path.withUnsafeBufferPointer { config.filtersFiles(inDirectory: $0) }
            let first = tree.count
            while true {
                if isCancelled { return }
                let n = handle.use { sift_read_dir($0, scratch, scratchSize, entries, Int32(scratchSize/32)) }
                if n <= 0 { if n < 0 && (errno == EPERM || errno == EACCES) { path.withUnsafeBufferPointer { coverage.record(.noAccess, path: $0) } }; break }
                for j in 0..<Int(n) {
                    let e = entries[j]
                    if e.name_len == 0 { continue }
                    if e.error != 0 {
                        if e.error == EPERM || e.error == EACCES {
                            let name = UnsafeBufferPointer(start: UnsafeRawPointer(e.name).assumingMemoryBound(to: UInt8.self), count: Int(e.name_len))
                            path.withUnsafeBufferPointer { coverage.record(.noAccess, parent: $0, name: name) }
                        }
                        continue
                    }
                    if !devices.contains(e.dev) { continue }
                    let raw = UnsafeBufferPointer(start: UnsafeRawPointer(e.name).assumingMemoryBound(to: UInt8.self), count: Int(e.name_len))
                    if raw.elementsEqual([46]) || raw.elementsEqual([46,46]) { continue }
                    func append(_ name: UnsafeBufferPointer<UInt8>) {
                        let length = path.count
                        if path.last != 47 { path.append(47) }; path.append(contentsOf: name)
                        defer { path.removeLast(path.count-length) }
                        if (e.type == 1 || filterFiles || !config.userExcludedPaths.isEmpty) && !path.withUnsafeBufferPointer({ allowed($0, isDirectory: e.type == 1) }) {
                            path.withUnsafeBufferPointer { if let reason = config.exclusionReason(path: $0, isDirectory: e.type == 1) { coverage.record(reason, path: $0) } }
                            return
                        }
                        tree.append(parent: parent, name: name, attrs: EntryAttrs(type: e.type, bsdFlags: e.bsd_flags, size: e.size, mtime: e.mtime), fileid: e.fileid, dev: e.dev)
                    }
                    if raw.contains(where: { $0 >= 128 }) { Array(String(decoding: raw, as: UTF8.self).precomposedStringWithCanonicalMapping.utf8).withUnsafeBufferPointer(append) }
                    else { append(raw) }
                }
            }
            let end = tree.count
            for child in first..<end where tree.type[child] == 1 {
                if isCancelled { return }
                let length = path.count
                if path.last != 47 { path.append(47) }
                path.append(contentsOf: tree.name(child))
                if let hook = onSubtreeDirectoryOpen { path.withUnsafeBufferPointer(hook) }
                if isCancelled { return }
                let childFD = withUnsafeTemporaryAllocation(of: CChar.self, capacity: path.count + 1) { cpath in
                    for i in path.indices { cpath[i] = CChar(bitPattern: path[i]) }
                    cpath[path.count] = 0
                    return open(cpath.baseAddress!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                if childFD >= 0 {
                    guard let childHandle = register(childFD) else { return }
                    var openedChild = stat()
                    if childHandle.use({ fstat($0, &openedChild) }) == 0 && openedChild.st_mode & S_IFMT == S_IFDIR && UInt64(openedChild.st_ino) == tree.fileid[child] && openedChild.st_dev == tree.dev[child] && devices.contains(openedChild.st_dev) {
                        descend(child, handle: childHandle)
                    } else { release(childHandle) }
                } else if errno == EPERM || errno == EACCES { path.withUnsafeBufferPointer { coverage.record(.noAccess, path: $0) } }
                path.removeLast(path.count-length)
            }
        }
        descend(0, handle: rootHandle); return isCancelled ? nil : tree
    }
}
