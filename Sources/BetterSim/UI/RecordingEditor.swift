import AppKit
import AVKit
import SwiftUI

/// Lets you trim a new recording, and pick MP4 or GIF, before it's saved. Trimming uses AVKit's own trim bar.
@MainActor
final class RecordingEditor: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var finished = false
    private var onCancel: @MainActor () -> Void = {}

    func edit(
        _ movie: URL,
        kind: SimulatorModel.CaptureKind,
        save: @escaping @MainActor (CMTimeRange?, SimulatorModel.CaptureKind) -> Void,
        cancel: @escaping @MainActor () -> Void
    ) {
        window?.close()
        finished = false
        onCancel = cancel
        let player = AVPlayer(url: movie)
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .floating
        let root = EditorView(playerView: playerView, kind: kind) { [weak self] chosen in
            guard let self else { return }
            self.finished = true
            save(Self.trimmedRange(of: player.currentItem), chosen)
            self.window?.close()
        } cancel: { [weak self] in
            self?.window?.close()
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Trim Recording"
        window.styleMask = [.titled, .closable, .resizable]
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 420, height: 760))
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        Task { await Self.startTrimming(playerView) }
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        if !finished { onCancel() }
        finished = true
    }

    /// The trim bar can only open once the movie has loaded, so keep trying for a moment.
    private static func startTrimming(_ view: AVPlayerView) async {
        for _ in 0..<40 {
            if view.canBeginTrimming {
                _ = await view.beginTrimming()
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    static func trimmedRange(of item: AVPlayerItem?) -> CMTimeRange? {
        guard let item else { return nil }
        let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
        guard end.isValid, end.isNumeric, end > start else { return nil }
        return CMTimeRange(start: start, end: end)
    }
}

private struct EditorView: View {
    let playerView: AVPlayerView
    @State var kind: SimulatorModel.CaptureKind
    let save: (SimulatorModel.CaptureKind) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            PlayerView(view: playerView)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 8) {
                Segments(options: [(.mp4, "MP4"), (.gif, "GIF")], selection: $kind)
                    .frame(width: 140)
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save \(kind.rawValue)") { save(kind) }
                    .keyboardShortcut(.defaultAction)
            }
            Text("Drag the yellow handles to trim, then press Trim in the player before saving.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(minWidth: 360, minHeight: 560)
    }
}

private struct PlayerView: NSViewRepresentable {
    let view: AVPlayerView

    func makeNSView(context: Context) -> AVPlayerView { view }
    func updateNSView(_ view: AVPlayerView, context: Context) {}
}
