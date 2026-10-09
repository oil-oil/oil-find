import AppKit
import UniformTypeIdentifiers
import OilFindCore

final class IconProvider {
    private let paths = NSCache<NSString, NSImage>()
    private var extensions: [String: NSImage] = [:]
    private var pending: [String: [(NSImage) -> Void]] = [:]
    private let queue = DispatchQueue(label: "com.oiloil.find.icons", qos: .utility)
    var isIdle: Bool { pending.isEmpty }
    init() { paths.countLimit = 500 }
    func icon(name: String, path: String, flags: UInt8, kind: UInt8, completion: @escaping (NSImage) -> Void) -> NSImage {
        precondition(Thread.isMainThread)
        let directory = flags & SiftFlag.dir != 0, package = flags & SiftFlag.package != 0
        let key: String
        let type: UTType
        if kind == 2 { key = "/application"; type = .application }
        else if package { key = "/package"; type = .package }
        else if directory { key = "/folder"; type = .folder }
        else {
            key = (name as NSString).pathExtension.lowercased()
            type = UTType(filenameExtension: key) ?? .data
        }
        let generic: NSImage
        if let cached = extensions[key] { generic = cached }
        else { generic = NSWorkspace.shared.icon(for: type); extensions[key] = generic }
        guard directory || package || kind == 2 else { return generic }
        if let image = paths.object(forKey: path as NSString) { return image }
        if pending[path] != nil { pending[path]!.append(completion); return generic }
        pending[path] = [completion]
        queue.async { [weak self] in
            let image = NSWorkspace.shared.icon(forFile: path)
            DispatchQueue.main.async {
                guard let self else { return }
                self.paths.setObject(image, forKey: path as NSString)
                let callbacks = self.pending.removeValue(forKey: path) ?? []
                callbacks.forEach { $0(image) }
            }
        }
        return generic
    }
}
