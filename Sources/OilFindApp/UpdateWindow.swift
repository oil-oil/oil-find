import AppKit
import SwiftUI
import OilFindCore

private struct UpdateView: View {
    @ObservedObject var model: UpdateManager
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 20, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if case .latest = model.state {
                Text(L10n.text("update.latest.body", model.runningVersion.version.text)).foregroundStyle(.secondary)
            } else if let manifest = model.manifest {
                Text(L10n.text("update.available.current", model.runningVersion.version.text)).foregroundStyle(.secondary)
                let notes = L10n.chinese ? manifest.notes.zh : manifest.notes.en
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                            HStack(alignment: .top, spacing: 9) {
                                Text("•"); Text(note).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: notesHeight)
            }
            if case .failed(let reason) = model.state {
                Text(L10n.text("update.failed", L10n.text("update.reason." + reason.rawValue)))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if model.state.installing {
                VStack(alignment: .leading, spacing: 8) {
                    if case .downloading(let fraction) = model.state {
                        ProgressView(value: fraction)
                        Text(L10n.text("update.downloading", UpdateManager.percent(fraction))).foregroundStyle(.secondary)
                    } else {
                        ProgressView(value: 1)
                        Text(L10n.text("update.installing")).foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack {
                    if case .available = model.state { Button(L10n.text("update.skip"), action: model.skip).buttonStyle(.link) }
                    Spacer()
                    Button(L10n.text("update.later"), action: model.dismiss).keyboardShortcut(.cancelAction)
                    if case .available = model.state {
                        Button(L10n.text("update.install"), action: model.install).keyboardShortcut(.defaultAction)
                    } else if case .failed = model.state {
                        Button(L10n.text("update.openWebsite"), action: model.openWebsite).keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .font(.system(size: 13)).padding(24).frame(width: 520, height: contentHeight)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    private var title: String {
        if case .latest = model.state { return L10n.text("update.latest.title") }
        return model.manifest.map { L10n.text("update.available.title", $0.version) } ?? L10n.text("update.check")
    }
    private var notesHeight: CGFloat {
        let notes = model.manifest.map { L10n.chinese ? $0.notes.zh : $0.notes.en } ?? []
        guard notes.count > 2 else { return 96 }
        let visible = notes.prefix(6)
        let height = visible.reduce(CGFloat(0)) { result, note in
            let text = NSAttributedString(string: note, attributes: [.font: NSFont.systemFont(ofSize: 13)])
            return result + ceil(text.boundingRect(with: NSSize(width: 458, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        } + CGFloat(max(0, visible.count - 1)) * 10
        return min(260, height)
    }
    private var contentHeight: CGFloat {
        guard model.manifest != nil else { return 220 }
        if case .failed = model.state { return max(342, notesHeight + 246) }
        return max(330, notesHeight + 200)
    }
}

final class UpdateWindowController: NSWindowController, NSWindowDelegate {
    private let model: UpdateManager
    private var languageObserver: NSObjectProtocol?
    init(model: UpdateManager) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 330), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.text("update.check"); window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: UpdateView(model: model)); window.delegate = self
        languageObserver = NotificationCenter.default.addObserver(forName: L10n.changed, object: nil, queue: .main) { [weak self] _ in
            self?.window?.title = L10n.text("update.check")
            self?.model.objectWillChange.send()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() { window?.center(); window?.makeKeyAndOrderFront(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.state.installing }
    deinit { if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) } }
}
