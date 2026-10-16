import Foundation
import Darwin

/// Vnode notifications cover repeated SQLite WAL writes that FSEvents can coalesce until close.
final class AITopicFileWatcher {
    private var paths: [String]
    private let queue: DispatchQueue
    private let handler: () -> Void
    private let lock = NSLock()
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var stopped = false

    init(paths: [String], queue: DispatchQueue, handler: @escaping () -> Void) {
        self.paths = paths; self.queue = queue; self.handler = handler; rescan()
    }
    func rescan(paths updated: [String]? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        if let updated {
            paths = updated
            for path in Array(sources.keys) where !updated.contains(path) {
                sources.removeValue(forKey: path)?.cancel()
            }
        }
        installMissing()
    }
    private func installMissing() {
        for path in paths where sources[path] == nil {
            let descriptor = Darwin.open(path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue)
            source.setEventHandler { [weak self] in self?.changed(path) }
            source.setCancelHandler { Darwin.close(descriptor) }
            sources[path] = source; source.resume()
        }
    }
    private func changed(_ path: String) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        if let source = sources[path], !source.data.intersection([.rename, .delete]).isEmpty {
            sources.removeValue(forKey: path); source.cancel()
        }
        installMissing()
        lock.unlock()
        handler()
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        for source in sources.values { source.cancel() }
        sources.removeAll()
    }
    deinit { stop() }
}
