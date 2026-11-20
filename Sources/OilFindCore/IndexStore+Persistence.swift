import Foundation
import Darwin
import COilFind

public enum IndexPersistenceError: Error { case noSpace, io(Int32) }
extension IndexStore {
    private var fileLength: Int { 256 + rootPath.utf8.count + (count+1)*4 + count*4*3 + count*3 + namesLen + (altCount+1)*4 + altCount*4 + altLen }
    public func save(to path: String) throws {
        try read { try saveLocked(to: path) }
    }
    internal func saveSnapshot(to path: String) throws -> (version: UInt64, metadataVersion: UInt64) {
        try read { try saveLocked(to: path); return (version, metadataVersion) }
    }
    private func saveLocked(to path: String) throws {
        let coverageData = try JSONEncoder().encode(coverage)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var fs = statfs()
        if statfs(dir, &fs) != 0 { throw IndexPersistenceError.io(errno) }
        if UInt64(fs.f_bavail) * UInt64(fs.f_bsize) < UInt64(fileLength) * 2 { throw IndexPersistenceError.noSpace }
        let tmp = path + ".tmp.\(getpid())"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        if fd < 0 { throw IndexPersistenceError.io(errno) }
        defer { close(fd); unlink(tmp) }
        func writeBytes(_ pointer: UnsafeRawPointer, _ length: Int) throws {
            var offset = 0
            while offset < length {
                let n = Darwin.write(fd, pointer.advanced(by: offset), length - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { throw IndexPersistenceError.io(errno) }
                offset += n
            }
        }
        var header = [UInt8](repeating: 0, count: 256)
        header.replaceSubrange(0..<8, with: Array("SIFTIDX\0".utf8))
        func put32(_ n: UInt32, _ pos: Int) { for i in 0..<4 { header[pos+i] = UInt8(truncatingIfNeeded: n >> (i*8)) } }
        func put64(_ n: UInt64, _ pos: Int) { for i in 0..<8 { header[pos+i] = UInt8(truncatingIfNeeded: n >> (i*8)) } }
        put32(3, 8); put32(UInt32(coverageData.count), 116); put32(UInt32(count), 12); put64(UInt64(namesLen), 16); put32(UInt32(altCount), 24); put32(UInt32(rootPath.utf8.count), 28)
        put64(UInt64(altLen), 32); put64(lastEventId, 40); put64(configFingerprint, 48); put64(scanFinishedAt, 56)
        for (i,b) in fsEventsUUID.utf8.prefix(40).enumerated() { header[64+i] = b }
        put64(scopeFingerprint, 120)
        put32(homeIndex, 104); put32(deletedCount, 108); header[112] = caseSensitiveNames ? 1 : 0
        try header.withUnsafeBytes { try writeBytes($0.baseAddress!, 256) }
        let root = Array(rootPath.utf8); try root.withUnsafeBytes { try writeBytes($0.baseAddress!, root.count) }
        try writeBytes(nameOff, (count+1)*4); try writeBytes(parent, count*4); try writeBytes(sizeC, count*4); try writeBytes(mtime, count*4)
        try writeBytes(flags, count); try writeBytes(depth, count); try writeBytes(kind, count); try writeBytes(names, namesLen)
        try writeBytes(altOff, (altCount+1)*4); try writeBytes(altOwner, altCount*4); try writeBytes(altNames, altLen)
        try coverageData.withUnsafeBytes { try writeBytes($0.baseAddress!, $0.count) }
        if fsync(fd) != 0 { throw IndexPersistenceError.io(errno) }
        if rename(tmp, path) != 0 { throw IndexPersistenceError.io(errno) }
    }
    public static func load(from path: String) -> IndexStore? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe), data.count >= 256 else { return nil }
        return data.withUnsafeBytes { raw -> IndexStore? in
            let p = raw.bindMemory(to: UInt8.self)
            guard p.prefix(8).elementsEqual(Array("SIFTIDX\0".utf8)) else { return nil }
            func u32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(p[at+$1]) << ($1*8) } }
            func u64(_ at: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(p[at+$1]) << ($1*8) } }
            guard (u32(8) == 2 || u32(8) == 3), p[112] <= 1 else { return nil }
            guard let count = Int(exactly: u32(12)),
                  let namesLen = Int(exactly: u64(16)),
                  let altCount = Int(exactly: u32(24)),
                  let rootLen = Int(exactly: u32(28)),
                  let altLen = Int(exactly: u64(32)) else { return nil }
            guard count > 0, count <= 20_000_000, rootLen < 4096, altCount <= 40_000_000,
                  namesLen <= Int(UInt32.max), altLen <= Int(UInt32.max) else { return nil }
            func multiplied(_ lhs: Int, _ rhs: Int) -> Int? {
                let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
                return overflow ? nil : value
            }
            var expected = 256
            func addExpected(_ value: Int) -> Bool {
                let (sum, overflow) = expected.addingReportingOverflow(value)
                guard !overflow else { return false }
                expected = sum
                return true
            }
            guard let nameOffBytes = multiplied(count + 1, 4),
                  let entryWordBytes = multiplied(count, 12),
                  let entryFlagBytes = multiplied(count, 3),
                  let altOffBytes = multiplied(altCount + 1, 4),
                  let altOwnerBytes = multiplied(altCount, 4),
                  addExpected(rootLen), addExpected(nameOffBytes), addExpected(entryWordBytes),
                  addExpected(entryFlagBytes), addExpected(namesLen), addExpected(altOffBytes),
                  addExpected(altOwnerBytes), addExpected(altLen) else { return nil }
            let coverageLength = u32(8) == 3 ? Int(u32(116)) : 0
            guard coverageLength <= 200_000, addExpected(coverageLength) else { return nil }
            guard expected == data.count else { return nil }
            var pos = 256
            let root = String(decoding: p[pos..<(pos+rootLen)], as: UTF8.self); pos += rootLen
            let homeIndex = u32(104), deletedCount = u32(108)
            let caseSensitiveNames = p[112] == 1
            let s = IndexStore(rootPath: root, count: count, namesLen: namesLen, altCount: altCount, altLen: altLen, fingerprint: u64(48), homeIndex: homeIndex, finishedAt: u64(56), caseSensitiveNames: caseSensitiveNames)
            func copy(_ dst: UnsafeMutableRawPointer, _ n: Int) { if n > 0 { memcpy(dst, p.baseAddress!.advanced(by: pos), n) }; pos += n }
            copy(s.nameOff, (count+1)*4); copy(s.parent, count*4); copy(s.sizeC, count*4); copy(s.mtime, count*4)
            copy(s.flags, count); copy(s.depth, count); copy(s.kind, count); copy(s.names, namesLen)
            copy(s.altOff, (altCount+1)*4); copy(s.altOwner, altCount*4); copy(s.altNames, altLen)
            if coverageLength > 0 {
                guard let coverage = try? JSONDecoder().decode(CoverageStats.self, from: Data(p[pos..<(pos + coverageLength)])),
                      coverage.buckets.values.allSatisfy({ $0.examples.count <= 5 && $0.examples.allSatisfy { $0.utf8.count <= 4096 } }) else { return nil }
                s.coverage = coverage
            }
            guard sift_validate_index(s.nameOff, s.parent, s.kind, count, namesLen, s.altOff, s.altOwner, altCount, altLen, homeIndex, deletedCount) != 0 else { return nil }
            s.scopeFingerprint = u64(120)
            s.lastEventId = u64(40); s.deletedCount = deletedCount; s.liveCount = count - Int(deletedCount)
            s.fsEventsUUID = String(decoding: p[64..<104].prefix(while: { $0 != 0 }), as: UTF8.self)
            return s
        }
    }
}
