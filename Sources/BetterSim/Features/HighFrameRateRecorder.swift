import AVFoundation
import ScreenCaptureKit

/// Records the device screen at up to 120 frames a second, with the Simulator's sound, by capturing the Simulator's
/// window with ScreenCaptureKit. simctl records at about 30, and without audio. This needs Screen Recording access,
/// and the result has the window's on-screen resolution rather than the device's.
final class HighFrameRateRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    private let queue = DispatchQueue(label: "local.bettersim.capture")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var started = false
    private(set) var firstFrame: Date?
    private var output: URL?

    /// `screen` is where the device screen is inside the window, in the window's points.
    func start(window id: CGWindowID, screen: CGRect, scale: CGFloat, to url: URL, fps: Int32 = 120) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw Failure(errorDescription: "The Simulator window isn't on screen.")
        }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = screen
        configuration.width = Int((screen.width * scale).rounded(.down)) & ~1
        configuration.height = Int((screen.height * scale).rounded(.down)) & ~1
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.queueDepth = 8

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
        ])
        video.expectsMediaDataInRealTime = true
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ])
        audio.expectsMediaDataInRealTime = true
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? Failure(errorDescription: "The recording couldn't start.") }

        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        queue.sync {
            self.writer = writer
            self.video = video
            self.audio = audio
            self.started = false
            self.firstFrame = nil
            self.output = url
        }
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async throws -> (url: URL, firstFrame: Date?) {
        try await stream?.stopCapture()
        stream = nil
        let (writer, url, firstFrame) = queue.sync { () -> (AVAssetWriter?, URL?, Date?) in
            video?.markAsFinished()
            audio?.markAsFinished()
            return (self.writer, self.output, self.firstFrame)
        }
        guard let writer, let url else { throw Failure(errorDescription: "Nothing was recorded.") }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure(errorDescription: "The recording couldn't be saved.") }
        return (url, firstFrame)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid, let writer, writer.status == .writing else { return }
        switch type {
        case .screen:
            guard Self.isCompleteFrame(sample), let video, video.isReadyForMoreMediaData else { return }
            if !started {
                writer.startSession(atSourceTime: sample.presentationTimeStamp)
                started = true
                firstFrame = Date()
            }
            video.append(sample)
        case .audio:
            guard started, let audio, audio.isReadyForMoreMediaData else { return }
            audio.append(sample)
        default:
            break
        }
    }

    /// ScreenCaptureKit also delivers status-only buffers, for example when nothing on screen changed.
    private static func isCompleteFrame(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }
}
