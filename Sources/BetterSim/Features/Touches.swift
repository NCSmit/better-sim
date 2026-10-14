import AppKit
import AVFoundation
import CoreImage

/// One press on the device screen: where the pointer went, with each point's time since the recording started.
/// Positions are fractions of the screen's width and height, measured from its top-left corner.
struct Touch: Equatable, Sendable {
    var points: [Point]

    struct Point: Equatable, Sendable {
        let time: Double
        let x: Double
        let y: Double
    }
}

/// Follows clicks and drags over the device screen while a recording runs. Mouse events don't need any permission.
@MainActor
final class TouchTracker {
    private var monitor: Any?
    private var start = Date()
    private var current: Touch?
    private(set) var touches: [Touch] = []
    private let screen: @MainActor () -> CGRect?

    /// `screen` returns where the device screen is, with a top-left origin, like the window list.
    init(screen: @escaping @MainActor () -> CGRect?) {
        self.screen = screen
    }

    func begin(at start: Date) {
        self.start = start
        touches = []
        current = nil
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.record(type) }
        }
    }

    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let current { touches.append(current) }
        current = nil
    }

    /// The touches timed from when the first video frame was really captured, which is a little after recording began.
    func touches(alignedTo firstFrame: Date?) -> [Touch] {
        let offset = firstFrame.map { $0.timeIntervalSince(start) } ?? 0
        return touches.map { Touch(points: $0.points.map { Touch.Point(time: $0.time - offset, x: $0.x, y: $0.y) }) }
    }

    private func record(_ type: NSEvent.EventType) {
        guard let rect = screen(), rect.width > 0, rect.height > 0 else { return }
        let mouse = NSEvent.mouseLocation
        let top = (NSScreen.screens.first?.frame.height ?? 0) - mouse.y
        let point = Touch.Point(
            time: Date().timeIntervalSince(start),
            x: (mouse.x - rect.minX) / rect.width,
            y: (top - rect.minY) / rect.height
        )
        switch type {
        case .leftMouseDown:
            guard (0...1).contains(point.x), (0...1).contains(point.y) else { return }
            current = Touch(points: [point])
        case .leftMouseDragged:
            current?.points.append(point)
        default:
            guard var touch = current else { return }
            touch.points.append(point)
            touches.append(touch)
            current = nil
        }
    }
}

/// Burns touch indicators into a recording, drawing each frame's dots with Core Image.
enum TouchCompositor {
    struct Failure: LocalizedError {
        var errorDescription: String? { "The touches couldn't be added to the recording." }
    }

    static let fadeOut = 0.25

    static func burn(_ touches: [Touch], into video: URL, output: URL, fileType: AVFileType = .mov) async throws {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure() }
        let size = try await track.load(.naturalSize)
        let diameter = (size.width * 0.11).rounded()
        guard let dot = dotImage(diameter: diameter) else { throw Failure() }
        let touches = touches.filter { !$0.points.isEmpty }
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let time = request.compositionTime.seconds
            var frame = request.sourceImage
            for touch in touches {
                guard let state = state(of: touch, at: time) else { continue }
                let faded = dot.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: state.opacity),
                ])
                let origin = CGPoint(x: state.x * size.width - diameter / 2, y: (1 - state.y) * size.height - diameter / 2)
                frame = faded.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y)).composited(over: frame)
            }
            request.finish(with: frame.cropped(to: request.sourceImage.extent), context: nil)
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { throw Failure() }
        session.videoComposition = composition
        if #available(macOS 15, *) {
            try await session.export(to: output, as: fileType)
        } else {
            session.outputURL = output
            session.outputFileType = fileType
            await session.export()
            if session.status != .completed { throw session.error ?? Failure() }
        }
    }

    /// Where a touch's dot is at `time` and how visible it is: fully while pressed, then fading out.
    static func state(of touch: Touch, at time: Double) -> (x: Double, y: Double, opacity: Double)? {
        guard let first = touch.points.first, let last = touch.points.last, time >= first.time else { return nil }
        if time > last.time + fadeOut { return nil }
        let opacity = time <= last.time ? 1 : 1 - (time - last.time) / fadeOut
        guard let next = touch.points.firstIndex(where: { $0.time >= time }) else { return (last.x, last.y, opacity) }
        guard next > 0 else { return (first.x, first.y, opacity) }
        let a = touch.points[next - 1]
        let b = touch.points[next]
        let progress = b.time > a.time ? (time - a.time) / (b.time - a.time) : 1
        return (a.x + (b.x - a.x) * progress, a.y + (b.y - a.y) * progress, opacity)
    }

    private static func dotImage(diameter: CGFloat) -> CIImage? {
        let border = max(2, diameter / 16)
        let size = Int(diameter)
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let circle = CGRect(x: 0, y: 0, width: diameter, height: diameter).insetBy(dx: border / 2, dy: border / 2)
        context.setFillColor(CGColor(gray: 1, alpha: 0.45))
        context.fillEllipse(in: circle)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        context.setLineWidth(border)
        context.strokeEllipse(in: circle)
        return context.makeImage().map { CIImage(cgImage: $0) }
    }
}
