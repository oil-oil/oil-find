import Foundation
import Darwin
import COilFind

public struct EntryAttrs {
    public var type: UInt32, bsdFlags: UInt32, size: UInt64, mtime: Int64
    public init(type: UInt32, bsdFlags: UInt32 = 0, size: UInt64 = 0, mtime: Int64 = 0) {
        self.type = type; self.bsdFlags = bsdFlags; self.size = size; self.mtime = mtime
    }
}

extension IndexStore {
    // All mutation methods require the caller to hold the write lock.
    public func buildHash() {
        let built = makeHash()
        installHash(built)
    }
    // Only the event queue writes while the private table is built; searches use SoA arrays.
    internal func makeHash() -> (pointer: UnsafeMutablePointer<UInt32>, capacity: Int) {
        let capacity = max(1024, count * 5 / 4)
        let pointer = malloc(capacity * 4)!.bindMemory(to: UInt32.self, capacity: capacity)
        sift_build_hash(pointer, capacity, parent, names, nameOff, count, caseSensitiveNames ? 1 : 0)
        return (pointer, capacity)
    }
    internal func installHash(_ built: (pointer: UnsafeMutablePointer<UInt32>, capacity: Int)) {
        free(table); table = built.pointer; tableCapacity = built.capacity; tableUsed = count
    }
    private func hashSlot(_ hash: UInt64) -> Int {
        Int(hash.multipliedFullWidth(by: UInt64(tableCapacity)).high)
    }
    public func lookup(parent p: UInt32, name: UnsafeBufferPointer<UInt8>) -> UInt32? {
        guard let table, tableCapacity > 0 else { return nil }
        var slot = hashSlot(sift_entry_hash(p, name.baseAddress, name.count, caseSensitiveNames ? 1 : 0))
        while table[slot] != UInt32.max {
            let i = table[slot], n = Int(i)
            if parent[n] == p && isLive(i) {
                let bytes = nameBytes(i)
                if sift_name_equal(bytes.baseAddress, bytes.count, name.baseAddress, name.count, caseSensitiveNames ? 1 : 0) != 0 { return i }
            }
            slot = slot + 1 == tableCapacity ? 0 : slot + 1
        }
        return nil
    }
    public func resolve(path: String) -> UInt32? {
        path.utf8.withContiguousStorageIfAvailable { resolve(bytes: $0) } ?? Array(path.utf8).withUnsafeBufferPointer { resolve(bytes: $0) }
    }
    // Loaded indexes can serve queries before their hash table has finished building.
    public func containsPath(_ path: String) -> Bool {
        if hashReady { return resolve(path: path) != nil }
        let root = rootPath == "/" ? "" : rootPath
        guard path == rootPath || path.hasPrefix(root + "/") else { return false }
        if path == rootPath { return isLive(0) }
        var current: UInt32 = 0
        for component in path.dropFirst(root.count).split(separator: "/") {
            let bytes = Array(component.utf8)
            var found: UInt32?
            bytes.withUnsafeBufferPointer { name in
                for i in (Int(current) + 1)..<count where parent[i] == current && isLive(UInt32(i)) {
                    let candidate = nameBytes(UInt32(i))
                    if sift_name_equal(candidate.baseAddress, candidate.count, name.baseAddress, name.count, caseSensitiveNames ? 1 : 0) != 0 { found = UInt32(i); break }
                }
            }
            guard let id = found else { return false }; current = id
        }
        return true
    }
    internal func resolve(bytes: UnsafeBufferPointer<UInt8>) -> UInt32? {
        let rootLen = rootPath.utf8.count
        guard bytes.count >= rootLen, bytes.prefix(rootLen).elementsEqual(rootPath.utf8),
              rootPath == "/" || bytes.count == rootLen || bytes[rootLen] == 47 else { return nil }
        guard isLive(0) else { return nil }
        var i: UInt32 = 0, pos = rootLen
        while pos < bytes.count {
            if bytes[pos] == 47 { pos += 1; continue }
            let begin = pos
            while pos < bytes.count && bytes[pos] != 47 { pos += 1 }
            guard flags[Int(i)] & SiftFlag.dir != 0,
                  let child = lookup(parent: i, name: UnsafeBufferPointer(start: bytes.baseAddress!.advanced(by: begin), count: pos - begin)) else { return nil }
            i = child
        }
        return i
    }
    private func grow<T>(_ pointer: inout UnsafeMutablePointer<T>, to n: Int) {
        pointer = realloc(pointer, max(1, n) * MemoryLayout<T>.stride)!.bindMemory(to: T.self, capacity: max(1, n))
    }
    private func ensureEntries() {
        if count < capacity { return }
        capacity = max(count + 1, capacity + max(1, capacity / 2))
        grow(&nameOff, to: capacity + 1); grow(&parent, to: capacity)
        grow(&sizeC, to: capacity); grow(&mtime, to: capacity)
        grow(&flags, to: capacity); grow(&depth, to: capacity); grow(&kind, to: capacity)
    }
    private func appendAlt(_ bytes: [UInt8], owner: UInt32) {
        if altCount == altCapacity {
            altCapacity = max(altCount + 1, altCapacity + max(1, altCapacity / 2))
            grow(&altOff, to: altCapacity + 1); grow(&altOwner, to: altCapacity)
        }
        if altLen + bytes.count > altNamesCapacity {
            altNamesCapacity = max(altLen + bytes.count, altNamesCapacity + max(1, altNamesCapacity / 2))
            grow(&altNames, to: altNamesCapacity)
        }
        altOff[altCount] = UInt32(altLen); altOwner[altCount] = owner
        bytes.withUnsafeBufferPointer { if !$0.isEmpty { altNames.advanced(by: altLen).update(from: $0.baseAddress!, count: $0.count) } }
        altCount += 1; altLen += bytes.count; altOff[altCount] = UInt32(altLen)
    }
    @discardableResult public func insert(parent p: UInt32, name: UnsafeBufferPointer<UInt8>, attrs: EntryAttrs) -> UInt32 {
        precondition(Int(p) < count && isLive(p) && flags[Int(p)] & SiftFlag.dir != 0)
        if table == nil { buildHash() }
        ensureEntries()
        if namesLen + name.count > namesCapacity {
            namesCapacity = max(namesLen + name.count, namesCapacity + max(1, namesCapacity / 2))
            grow(&names, to: namesCapacity)
        }
        let i = UInt32(count), n = count, pi = Int(p)
        let inherited = Classifier.inheritedForChildren(dirFlags: flags[pi], dirName: nameBytes(p), dirDepth: depth[pi], parentName: nameBytes(parent[Int(parent[pi])]), isHome: p == homeIndex)
        parent[n] = p; depth[n] = UInt8(min(Int(depth[pi]) + 1, 255))
        flags[n] = Classifier.flags(name: name, type: attrs.type, bsdFlags: attrs.bsdFlags, inherited: inherited)
        kind[n] = Classifier.kind(name: name, flags: flags[n])
        sizeC[n] = attrs.type == 1 ? 0 : Self.encodeSize(attrs.size); mtime[n] = UInt32(clamping: attrs.mtime)
        nameOff[n] = UInt32(namesLen)
        if !name.isEmpty { names.advanced(by: namesLen).update(from: name.baseAddress!, count: name.count) }
        namesLen += name.count; count += 1; nameOff[count] = UInt32(namesLen); liveCount += 1
        if name.contains(where: { $0 >= 128 }) {
            if Pinyin.shared.keys(for: name, full: &fullKey, initials: &initialKey) {
                appendAlt(fullKey, owner: i); appendAlt(initialKey, owner: i)
            } else {
                fullKey.removeAll(keepingCapacity: true)
                fullKey.append(contentsOf: String(decoding: name, as: UTF8.self).lowercased().utf8)
                var differs = fullKey.count != name.count
                if !differs { for j in name.indices { if fullKey[j] != (name[j] >= 65 && name[j] <= 90 ? name[j] | 32 : name[j]) { differs = true; break } } }
                if differs { appendAlt(fullKey, owner: i) }
            }
        }
        if (tableUsed + 1) * 100 > tableCapacity * 85 { buildHash() }
        else {
            var slot = hashSlot(sift_entry_hash(p, name.baseAddress, name.count, caseSensitiveNames ? 1 : 0))
            while table![slot] != UInt32.max { slot = slot + 1 == tableCapacity ? 0 : slot + 1 }
            table![slot] = i; tableUsed += 1
        }
        if homeIndex == UInt32.max && depth[n] == Self.homeDepth && name.elementsEqual(Self.homeName) && resolve(path: Self.homePath) == i { homeIndex = i }
        return i
    }
    private static let homePath = NSHomeDirectory()
    private static let homeName = Array((NSHomeDirectory() as NSString).lastPathComponent.utf8)
    private static let homeDepth = NSHomeDirectory().split(separator: "/").count
    public func update(_ i: UInt32, name: UnsafeBufferPointer<UInt8>, attrs: EntryAttrs) -> UInt32 {
        let n = Int(i)
        let newType: UInt8 = attrs.type == 1 ? SiftFlag.dir : attrs.type == 2 ? SiftFlag.symlink : 0
        if flags[n] & (SiftFlag.dir | SiftFlag.symlink) != newType {
            let p = parent[n]; _ = remove(i)
            return insert(parent: p, name: name, attrs: attrs)
        }
        let old = nameBytes(i)
        if !caseSensitiveNames && old.count == name.count && !old.elementsEqual(name) && sift_name_equal_folded(old.baseAddress, old.count, name.baseAddress, name.count) != 0 && !name.isEmpty {
            names.advanced(by: Int(nameOff[n])).update(from: name.baseAddress!, count: name.count)
        }
        sizeC[n] = attrs.type == 1 ? 0 : Self.encodeSize(attrs.size); mtime[n] = UInt32(clamping: attrs.mtime)
        let p = Int(parent[n])
        let inherited = Classifier.inheritedForChildren(dirFlags: flags[p], dirName: nameBytes(parent[n]), dirDepth: depth[p], parentName: nameBytes(parent[Int(parent[p])]), isHome: UInt32(p) == homeIndex)
        flags[n] = Classifier.flags(name: name, type: attrs.type, bsdFlags: attrs.bsdFlags, inherited: inherited)
        kind[n] = Classifier.kind(name: name, flags: flags[n])
        return i
    }
    @discardableResult public func remove(_ i: UInt32) -> Bool {
        let n = Int(i), dir = flags[n] & SiftFlag.dir != 0
        if isLive(i) { flags[n] |= SiftFlag.deleted; liveCount -= 1; deletedCount += 1 }
        return dir
    }
    public func sweep() {
        var removed: UInt32 = 0
        sift_sweep(flags, parent, count, &removed)
        liveCount -= Int(removed); deletedCount += removed
    }
    public var needsCompaction: Bool { Int(deletedCount) > max(100_000, count / 4) }
    public func compacted() -> IndexStore {
        precondition(isLive(0))
        let map = UnsafeMutablePointer<UInt32>.allocate(capacity: count)
        defer { map.deallocate() }
        var entries = 0, bytes = 0, keys = 0, keyBytes = 0
        for i in 0..<count {
            map[i] = UInt32.max
            if isLive(UInt32(i)) { map[i] = UInt32(entries); entries += 1; bytes += Int(nameOff[i+1] - nameOff[i]) }
        }
        for a in 0..<altCount where map[Int(altOwner[a])] != UInt32.max { keys += 1; keyBytes += Int(altOff[a+1] - altOff[a]) }
        let s = IndexStore(rootPath: rootPath, count: entries, namesLen: bytes, altCount: keys, altLen: keyBytes, fingerprint: configFingerprint, homeIndex: homeIndex == UInt32.max ? UInt32.max : map[Int(homeIndex)], finishedAt: scanFinishedAt, caseSensitiveNames: caseSensitiveNames)
        var pos = 0
        for i in 0..<count where map[i] != UInt32.max {
            let n = Int(map[i]), len = Int(nameOff[i+1] - nameOff[i])
            s.nameOff[n] = UInt32(pos); s.parent[n] = map[Int(parent[i])]
            s.sizeC[n] = sizeC[i]; s.mtime[n] = mtime[i]; s.flags[n] = flags[i]; s.depth[n] = depth[i]; s.kind[n] = kind[i]
            if len > 0 { s.names.advanced(by: pos).update(from: names.advanced(by: Int(nameOff[i])), count: len) }; pos += len
        }
        s.nameOff[entries] = UInt32(pos); pos = 0; var a = 0
        for j in 0..<altCount where map[Int(altOwner[j])] != UInt32.max {
            let len = Int(altOff[j+1] - altOff[j]); s.altOff[a] = UInt32(pos); s.altOwner[a] = map[Int(altOwner[j])]
            if len > 0 { s.altNames.advanced(by: pos).update(from: altNames.advanced(by: Int(altOff[j])), count: len) }; pos += len; a += 1
        }
        s.scopeFingerprint = scopeFingerprint
        s.coverage = coverage
        s.altOff[keys] = UInt32(pos); s.lastEventId = lastEventId; s.fsEventsUUID = fsEventsUUID; s.version = version; s.metadataVersion = metadataVersion
        s.buildHash(); return s
    }
}
