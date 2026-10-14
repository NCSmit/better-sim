import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CaptureFiles {
    static func url(for device: SimDevice, in folder: URL, extension ext: String, date: Date = .now) -> URL {
        url(named: device.name, in: folder, extension: ext, date: date)
    }

    static func url(named name: String, in folder: URL, extension ext: String, date: Date = .now) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "\(name) \(formatter.string(from: date))"
        var url = folder.appending(path: "\(base).\(ext)")
        var copy = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(base) \(copy).\(ext)")
            copy += 1
        }
        return url
    }
}

enum Screenshotter {
    static func capture(
        _ device: SimDevice,
        profile: DeviceProfile?,
        framed: Bool,
        style: Backdrop.Style = Backdrop.Style(),
        folder: URL
    ) async throws -> URL {
        let url = CaptureFiles.url(for: device, in: folder, extension: "png")
        try await Simctl.run(["io", device.udid, "screenshot", "--type=png", "--mask=alpha", url.path])
        guard framed || !style.isPlain, var image = ImageFile.load(url) else { return url }
        if framed, let profile, let framedImage = Framer.frame(image, profile: profile) { image = framedImage }
        if let styled = Backdrop.apply(style, to: image) { image = styled }
        try ImageFile.writePNG(image, to: url)
        return url
    }

    /// A full, square-cornered screenshot without transparency, which is what App Store Connect accepts.
    static func captureForAppStore(_ device: SimDevice, folder: URL) async throws -> URL {
        let url = CaptureFiles.url(for: device, in: folder, extension: "png")
        try await Simctl.run(["io", device.udid, "screenshot", "--type=png", "--mask=ignored", url.path])
        if let image = ImageFile.load(url), let opaque = ImageFile.removingAlpha(image) {
            try ImageFile.writePNG(opaque, to: url)
        }
        return url
    }
}

/// Records the device screen with `simctl io recordVideo`, which stops cleanly on SIGINT.
@MainActor
final class Recorder {
    struct Result {
        let url: URL
        /// When simctl reported the first frame, so touches can be lined up with the video.
        let firstFrame: Date?
    }

    private final class Running: @unchecked Sendable {
        let process: Process
        let url: URL
        private let lock = NSLock()
        private var started: Date?

        init(process: Process, url: URL) {
            self.process = process
            self.url = url
        }

        var firstFrame: Date? { lock.withLock { started } }

        func markFirstFrame() {
            lock.withLock { if started == nil { started = Date() } }
        }
    }

    private var running: Running?
    private(set) var startedAt: Date?

    var isRecording: Bool { running != nil }

    func start(_ device: SimDevice, to url: URL) throws {
        let process = Simctl.process(["io", device.udid, "recordVideo", "--codec=h264", "--force", url.path])
        let recording = Running(process: process, url: url)
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else if String(decoding: data, as: UTF8.self).contains("Recording started") {
                recording.markFirstFrame()
            }
        }
        try process.run()
        running = recording
        startedAt = .now
    }

    func stop() async -> Result? {
        guard let running else { return nil }
        self.running = nil
        startedAt = nil
        running.process.interrupt()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                running.process.waitUntilExit()
                continuation.resume()
            }
        }
        guard FileManager.default.fileExists(atPath: running.url.path) else { return nil }
        return Result(url: running.url, firstFrame: running.firstFrame)
    }

    func stopNow() {
        guard let running else { return }
        running.process.interrupt()
        running.process.waitUntilExit()
        self.running = nil
    }
}

enum MP4Exporter {
    struct Failure: LocalizedError {
        var errorDescription: String? { "The MP4 couldn't be written." }
    }

    /// Rewraps the Simulator's QuickTime movie as MP4 without re-encoding, so it's quick and loses nothing.
    static func export(video: URL, to mp4: URL, range: CMTimeRange? = nil) async throws {
        let asset = AVURLAsset(url: video)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw Failure()
        }
        if let range { session.timeRange = range }
        if #available(macOS 15, *) {
            try await session.export(to: mp4, as: .mp4)
        } else {
            session.outputURL = mp4
            session.outputFileType = .mp4
            await session.export()
            if session.status != .completed { throw session.error ?? Failure() }
        }
    }
}

enum GIFExporter {
    struct Failure: LocalizedError {
        var errorDescription: String? { "The GIF couldn't be written." }
    }

    static func frameTimes(duration: Double, fps: Double) -> [Double] {
        guard duration > 0, fps > 0 else { return [] }
        let count = max(1, Int((duration * fps).rounded(.down)))
        return (0..<count).map { Double($0) / fps }
    }

    static func export(video: URL, to gif: URL, fps: Double = 15, maxWidth: CGFloat = 480, range: CMTimeRange? = nil) async throws {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        let start = range?.start.seconds ?? 0
        let times = frameTimes(duration: (range?.duration.seconds ?? duration), fps: fps).map { $0 + start }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 600)
        guard !times.isEmpty,
              let destination = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, times.count, nil)
        else { throw Failure() }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frame = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: 1 / fps,
                kCGImagePropertyGIFUnclampedDelayTime: 1 / fps,
            ],
        ] as CFDictionary
        for await result in generator.images(for: times.map { CMTime(seconds: $0, preferredTimescale: 600) }) {
            if let image = try? result.image {
                CGImageDestinationAddImage(destination, image, frame)
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw Failure() }
    }
}
