import Foundation
import Darwin
import CoreServices

private final class WatchContext {
    let roots: [String]
    let deviceRoot: String?
    let handler: ([FSChange], Bool) -> Void
    let lock = NSLock()
    var latest: UInt64, replayed = 0, historyDone = false, dataPrefix = false
    init(roots: [String], since: UInt64, deviceRoot: String?, handler: @escaping ([FSChange], Bool) -> Void) {
        self.roots = roots; self.deviceRoot = deviceRoot; latest = since; self.handler = handler
    }
    func receive(count: Int, paths: UnsafeMutableRawPointer, flags: UnsafePointer<FSEventStreamEventFlags>, ids: UnsafePointer<FSEventStreamEventId>) {
        let paths = unsafeBitCast(paths, to: NSArray.self)
        var changes: [FSChange] = [], rescan = false
        changes.reserveCapacity(count)
        lock.lock()
        for i in 0..<count {
            let rawPath = paths[i] as! String, f = flags[i]
            let path: String
            if let deviceRoot, rawPath != deviceRoot, !rawPath.hasPrefix(deviceRoot + "/") {
                let relative = rawPath.drop(while: { $0 == "/" })
                path = relative.isEmpty ? deviceRoot : deviceRoot + (deviceRoot == "/" ? "" : "/") + relative
            } else { path = rawPath }
            latest = max(latest, ids[i])
            if f & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { historyDone = true }
            if f == UInt32(kFSEventStreamEventFlagHistoryDone) { continue }
            if !historyDone { replayed += 1 }
            if path == "/System/Volumes/Data" || path.hasPrefix("/System/Volumes/Data/") { dataPrefix = true }
            let canonical = path == "/System/Volumes/Data" ? "/" : path.hasPrefix("/System/Volumes/Data/") ? String(path.dropFirst("/System/Volumes/Data".count)) : path
            let rootEvent = roots.contains { $0 == path || ($0 == "/" && canonical == "/") }
            if f & UInt32(kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged) != 0 || (rootEvent && f & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0) { rescan = true }
            changes.append(FSChange(path: path, flags: f, eventId: ids[i]))
        }
        lock.unlock()
        handler(changes, rescan)
    }
}
public final class FSWatcher {
    private let device: dev_t?
    private let context: WatchContext, queue: DispatchQueue, latency: TimeInterval
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    public init(paths: [String], sinceWhen: UInt64, latency: TimeInterval = 0.15, device: dev_t? = nil, queue: DispatchQueue,
                handler: @escaping ([FSChange], Bool) -> Void) {
        self.device = device
        context = WatchContext(roots: paths, since: sinceWhen, deviceRoot: device == nil ? nil : paths.first, handler: handler); self.queue = queue; self.latency = latency
    }
    public func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if stream != nil { return true }
        var c = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(context).toOpaque(), retain: { pointer in
            guard let pointer else { return nil }
            _ = Unmanaged<WatchContext>.fromOpaque(pointer).retain(); return pointer
        }, release: { pointer in
            if let pointer { Unmanaged<WatchContext>.fromOpaque(pointer).release() }
        }, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        let callback: FSEventStreamCallback = { _, info, n, paths, flags, ids in
            guard let info else { return }
            Unmanaged<WatchContext>.fromOpaque(info).takeUnretainedValue().receive(count: n, paths: paths, flags: flags, ids: ids)
        }
        let created: FSEventStreamRef?
        if let device {
            created = FSEventStreamCreateRelativeToDevice(nil, callback, &c, device, [""] as CFArray, context.latest, latency, flags)
        } else {
            created = FSEventStreamCreate(nil, callback, &c, context.roots as CFArray, context.latest, latency, flags)
        }
        guard let s = created else { return false }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else { FSEventStreamInvalidate(s); FSEventStreamRelease(s); return false }
        stream = s; return true
    }
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard let s = stream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil
    }
    deinit { stop() }
    public var latestEventId: UInt64 { context.lock.lock(); defer { context.lock.unlock() }; return context.latest }
    public var replayedEventCount: Int { context.lock.lock(); defer { context.lock.unlock() }; return context.replayed }
    public var reportedDataPrefix: Bool { context.lock.lock(); defer { context.lock.unlock() }; return context.dataPrefix }
    public static func currentEventId() -> UInt64 { FSEventsGetCurrentEventId() }
    public static func currentEventId(forDevice device: dev_t) -> UInt64 {
        FSEventsGetLastEventIdForDeviceBeforeTime(device, Date().timeIntervalSince1970 + 1)
    }
    public static func uuid(forDevice dev: dev_t) -> String? {
        guard let uuid = FSEventsCopyUUIDForDevice(dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
