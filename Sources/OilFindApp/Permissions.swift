import AppKit
import Darwin

enum Permissions {
    static func hasFullDiskAccess() -> Bool {
        let path = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        let descriptor = Darwin.open(path, O_RDONLY)
        if descriptor >= 0 { Darwin.close(descriptor); return true }
        guard errno == ENOENT else { return false }
        return (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/Library/Safari")) != nil
    }
    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}
