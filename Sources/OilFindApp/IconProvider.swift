import AppKit
import ImageIO
import UniformTypeIdentifiers
import OilFindCore

final class IconProvider {
    private let paths = NSCache<NSString, NSImage>()
    private var extensions: [String: NSImage] = [:]
    private var pending: [String: [(NSImage) -> Void]] = [:]
    private let queue = DispatchQueue(label: "com.oiloil.find.icons", qos: .utility)
    var isIdle: Bool { pending.isEmpty }
    init() { paths.countLimit = 500 }
    func thumbnail(path: String, modified: Date, completion: @escaping (NSImage) -> Void) {
        let key = "thumbnail:" + path + String(modified.timeIntervalSince1970)
        if let cached = paths.object(forKey: key as NSString) { completion(cached); return }
        if pending[key] != nil { pending[key]!.append(completion); return }
        pending[key] = [completion]
        queue.async { [weak self] in
            let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            let cg = source.flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary) }
            DispatchQueue.main.async {
                guard let self else { return }
                let callbacks = self.pending.removeValue(forKey: key) ?? []
                guard let cg else { return }
                let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                self.paths.setObject(image, forKey: key as NSString); callbacks.forEach { $0(image) }
            }
        }
    }
    func icon(name: String, path: String, flags: UInt8, kind: UInt8, resolveFileIcon: Bool = true, completion: @escaping (NSImage) -> Void) -> NSImage {
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
        guard resolveFileIcon, directory || package || kind == 2 else { return generic }
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
