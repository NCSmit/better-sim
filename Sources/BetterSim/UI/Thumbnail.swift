import AppKit
import SwiftUI

/// A small preview of the newest capture in the corner of the screen, like the one macOS shows for screenshots.
/// Drag it into another app, click it to open, or use its buttons. It goes away on its own unless the pointer is on it.
@MainActor
final class ThumbnailWindow {
    private let panel: NSPanel
    private var hideTask: Task<Void, Never>?
    private var hovering = false

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
    }

    func show(_ url: URL, near window: CGRect?) {
        let view = ThumbnailView(url: url) { [weak self] in self?.hide() } hover: { [weak self] inside in
            self?.hovering = inside
            if !inside { self?.scheduleHide() }
        }
        panel.contentView = NSHostingView(rootView: view)
        let size = panel.contentView?.fittingSize ?? NSSize(width: 180, height: 240)
        let screen = window.flatMap { frame in NSScreen.screens.first { $0.frame.intersects(SimulatorWindows.appKitFrame(frame)) } }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: visible.maxX - size.width - 16, y: visible.minY + 16, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        scheduleHide()
    }

    func hide() {
        hideTask?.cancel()
        panel.orderOut(nil)
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, !self.hovering else { return }
            self.hide()
        }
    }
}

private struct ThumbnailView: View {
    let url: URL
    let close: () -> Void
    let hover: (Bool) -> Void
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            preview
                .frame(maxWidth: 150, maxHeight: 210)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                .onTapGesture { NSWorkspace.shared.open(url) }
                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            if isHovering {
                VStack(spacing: 6) {
                    button("xmark", "Close", action: close)
                    button("doc.on.doc", "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([url as NSURL])
                    }
                    button("folder", "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    button("trash", "Move to Trash") {
                        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                        close()
                    }
                }
                .padding(6)
            }
        }
        .padding(14)
        .onHover { inside in
            isHovering = inside
            hover(inside)
        }
    }

    @ViewBuilder private var preview: some View {
        if let image = NSImage(contentsOf: url), url.pathExtension.lowercased() != "mp4" {
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            VStack(spacing: 6) {
                Image(systemName: "film").font(.system(size: 28))
                Text(url.pathExtension.uppercased()).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(width: 110, height: 150)
            .background(VisualEffect())
        }
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .background(.black.opacity(0.65), in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
