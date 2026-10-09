import Foundation
import Darwin

public final class IndexStore {
    public internal(set) var rootPath: String
    public let caseSensitiveNames: Bool
    public internal(set) var count: Int, namesLen: Int, altCount: Int, altLen: Int
    public internal(set) var capacity: Int, namesCapacity: Int, altCapacity: Int, altNamesCapacity: Int
    public internal(set) var configFingerprint: UInt64
    public var homeIndex: UInt32, deletedCount: UInt32 = 0, liveCount: Int
    public var version: UInt64 = 0, lastEventId: UInt64 = 0, scanFinishedAt: UInt64
    public var coverage = CoverageStats()
    public var fsEventsUUID: String = ""
    public internal(set) var nameOff: UnsafeMutablePointer<UInt32>, parent: UnsafeMutablePointer<UInt32>
    public internal(set) var sizeC: UnsafeMutablePointer<UInt32>, mtime: UnsafeMutablePointer<UInt32>
    public internal(set) var flags: UnsafeMutablePointer<UInt8>, depth: UnsafeMutablePointer<UInt8>, kind: UnsafeMutablePointer<UInt8>
    public internal(set) var names: UnsafeMutablePointer<UInt8>
    public internal(set) var altOff: UnsafeMutablePointer<UInt32>, altOwner: UnsafeMutablePointer<UInt32>, altNames: UnsafeMutablePointer<UInt8>
    public internal(set) var table: UnsafeMutablePointer<UInt32>?
    public internal(set) var tableCapacity = 0
    // Read under the store lock, as with other store properties.
    public var hashReady: Bool { table != nil }
    internal var tableUsed = 0
    internal var fullKey: [UInt8] = [], initialKey: [UInt8] = []
    private var rwlock = pthread_rwlock_t()
    private static func alloc<T>(_ type: T.Type, _ count: Int) -> UnsafeMutablePointer<T> {
        let ptr = malloc(max(1, count) * MemoryLayout<T>.stride)!
        return ptr.bindMemory(to: T.self, capacity: max(1, count))
    }
    init(rootPath: String, count: Int, namesLen: Int, altCount: Int, altLen: Int, fingerprint: UInt64, homeIndex: UInt32, finishedAt: UInt64, caseSensitiveNames: Bool = false) {
        self.rootPath = rootPath; self.count = count; self.namesLen = namesLen; self.altCount = altCount; self.altLen = altLen
        self.capacity = count + count / 4; self.namesCapacity = namesLen + namesLen / 4
        self.altCapacity = altCount + altCount / 4; self.altNamesCapacity = altLen + altLen / 4
        self.configFingerprint = fingerprint; self.homeIndex = homeIndex; self.scanFinishedAt = finishedAt; self.liveCount = count
        self.caseSensitiveNames = caseSensitiveNames
        nameOff = Self.alloc(UInt32.self, capacity + 1); parent = Self.alloc(UInt32.self, capacity)
        sizeC = Self.alloc(UInt32.self, capacity); mtime = Self.alloc(UInt32.self, capacity)
        flags = Self.alloc(UInt8.self, capacity); depth = Self.alloc(UInt8.self, capacity); kind = Self.alloc(UInt8.self, capacity)
        names = Self.alloc(UInt8.self, namesCapacity); altOff = Self.alloc(UInt32.self, altCapacity + 1)
        altOwner = Self.alloc(UInt32.self, altCapacity); altNames = Self.alloc(UInt8.self, altNamesCapacity)
        pthread_rwlock_init(&rwlock, nil)
    }
    deinit {
        free(nameOff); free(parent); free(sizeC); free(mtime)
        free(flags); free(depth); free(kind); free(names)
        free(table); free(altOff); free(altOwner); free(altNames)
        pthread_rwlock_destroy(&rwlock)
    }
    public func read<T>(_ body: () throws -> T) rethrows -> T { pthread_rwlock_rdlock(&rwlock); defer { pthread_rwlock_unlock(&rwlock) }; return try body() }
    public func write<T>(_ body: () throws -> T) rethrows -> T { pthread_rwlock_wrlock(&rwlock); defer { pthread_rwlock_unlock(&rwlock) }; return try body() }
    // Called only on a newly loaded store, before publishing it to readers.
    internal func rebase(to root: String) {
        let delta = root.split(separator: "/").count - rootPath.split(separator: "/").count
        if delta != 0 { for i in 0..<count { depth[i] = UInt8(clamping: Int(depth[i]) + delta) } }
        rootPath = root
    }
    public func nameBytes(_ i: UInt32) -> UnsafeBufferPointer<UInt8> {
        let n = Int(i); return UnsafeBufferPointer(start: names.advanced(by: Int(nameOff[n])), count: Int(nameOff[n+1] - nameOff[n]))
    }
    public func name(_ i: UInt32) -> String { String(decoding: nameBytes(i), as: UTF8.self) }
    public func path(_ i: UInt32) -> String {
        if i == 0 { return rootPath }
        var chain: [UInt32] = []; var e = i
        while e != 0 { chain.append(e); e = parent[Int(e)] }
        let root = rootPath == "/" ? "" : rootPath
        let length = root.utf8.count + chain.reduce(0) { $0 + 1 + Int(nameOff[Int($1)+1] - nameOff[Int($1)]) }
        return String(unsafeUninitializedCapacity: length) { out in
            var p = 0
            for b in root.utf8 { out[p] = b; p += 1 }
            for e in chain.reversed() { out[p] = 47; p += 1; for b in nameBytes(e) { out[p] = b; p += 1 } }
            return p
        }
    }
    public func parentPath(_ i: UInt32) -> String { path(parent[Int(i)]) }
    public static func encodeSize(_ size: UInt64) -> UInt32 { size < 0x80000000 ? UInt32(size) : 0x80000000 | UInt32(min(size >> 12, 0x7fffffff)) }
    public static func decodeSize(_ c: UInt32) -> UInt64 { c & 0x80000000 == 0 ? UInt64(c) : UInt64(c & 0x7fffffff) << 12 }
    public func size(_ i: UInt32) -> UInt64 { Self.decodeSize(sizeC[Int(i)]) }
    public func modified(_ i: UInt32) -> Date { Date(timeIntervalSince1970: TimeInterval(mtime[Int(i)])) }
    public func isLive(_ i: UInt32) -> Bool { flags[Int(i)] & SiftFlag.deleted == 0 }
    public var allocatedBytes: Int { (capacity + 1) * 4 + capacity * 4 * 3 + capacity * 3 + namesCapacity + (altCapacity + 1) * 4 + altCapacity * 4 + altNamesCapacity + tableCapacity * 4 }
}
