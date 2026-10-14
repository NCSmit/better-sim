import AVFoundation
import CoreImage

/// Re-encodes a recording the way App Store Connect accepts app previews: H.264 at no more than 30 frames a second,
/// at one of Apple's accepted sizes, with a stereo AAC audio track (silent, since Simulator recordings have none).
enum AppPreviewExporter {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static let frameRate: Int32 = 30
    static let lengths: ClosedRange<Double> = 15...30

    /// The accepted size for a device screen of `pixels`, from Apple's app preview specifications.
    static func size(for pixels: CGSize) -> CGSize {
        let landscape = pixels.width > pixels.height
        let short = min(pixels.width, pixels.height)
        let long = max(pixels.width, pixels.height)
        let ratio = short / long
        let portrait: CGSize = switch ratio {
        case ..<0.5: CGSize(width: 886, height: 1920)
        case ..<0.6: long <= 1334 ? CGSize(width: 750, height: 1334) : CGSize(width: 1080, height: 1920)
        default: long <= 1024 ? CGSize(width: 900, height: 1200) : CGSize(width: 1200, height: 1600)
        }
        return landscape ? CGSize(width: portrait.height, height: portrait.width) : portrait
    }

    /// The output frame times for a clip of `duration` seconds.
    static func frameCount(duration: Double) -> Int {
        max(1, Int((duration * Double(frameRate)).rounded(.down)))
    }

    @discardableResult
    static func export(video: URL, to output: URL, range: CMTimeRange? = nil) async throws -> Double {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure(errorDescription: "The recording has no video.") }
        let natural = try await track.load(.naturalSize)
        let assetDuration = try await asset.load(.duration)
        let timeRange = range ?? CMTimeRange(start: .zero, duration: assetDuration)
        let size = size(for: natural)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange
        let source = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(source)

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 11_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264High40,
                AVVideoExpectedSourceFrameRateKey: frameRate,
            ],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
        ])
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256_000,
        ])
        writer.add(videoInput)
        writer.add(audioInput)
        guard reader.startReading(), writer.startWriting() else {
            throw Failure(errorDescription: reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "The app preview couldn't be written.")
        }
        writer.startSession(atSourceTime: .zero)

        let context = CIContext()
        let duration = timeRange.duration.seconds
        let frames = frameCount(duration: duration)
        var silence = try SilentAudio()
        var pending = source.copyNextSampleBuffer()
        var current: CVPixelBuffer?
        for frame in 0..<frames {
            let time = timeRange.start.seconds + Double(frame) / Double(frameRate)
            while let sample = pending, current == nil || CMSampleBufferGetPresentationTimeStamp(sample).seconds <= time + 0.0001 {
                current = CMSampleBufferGetImageBuffer(sample)
                pending = source.copyNextSampleBuffer()
            }
            guard let current, let pool = adaptor.pixelBufferPool else { continue }
            var scaled: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &scaled)
            guard let scaled else { continue }
            let image = CIImage(cvPixelBuffer: current)
            context.render(
                image.transformed(by: CGAffineTransform(scaleX: size.width / image.extent.width, y: size.height / image.extent.height)),
                to: scaled
            )
            try await waitUntilReady(videoInput, of: writer)
            adaptor.append(scaled, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: frameRate))
            try await silence.append(until: Double(frame + 1) / Double(frameRate), to: audioInput, of: writer)
        }
        videoInput.markAsFinished()
        try await silence.append(until: Double(frames) / Double(frameRate), to: audioInput, of: writer)
        audioInput.markAsFinished()
        reader.cancelReading()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? Failure(errorDescription: "The app preview couldn't be written.") }
        return Double(frames) / Double(frameRate)
    }

    /// An input never becomes ready again once the writer has failed, so waiting has to watch for that too.
    private static func waitUntilReady(_ input: AVAssetWriterInput, of writer: AVAssetWriter) async throws {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else {
                throw writer.error ?? Failure(errorDescription: "The app preview couldn't be written.")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// The silent audio track, appended alongside the video. The writer interleaves the two tracks and stops taking
    /// video once the audio falls about two seconds behind, so writing all the video first never finishes.
    private struct SilentAudio {
        static let rate = 44_100.0
        private let format: CMAudioFormatDescription
        private var written = 0

        init() throws {
            var description = AudioStreamBasicDescription(
                mSampleRate: Self.rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0
            )
            var format: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
            guard let format else { throw Failure(errorDescription: "The audio track couldn't be made.") }
            self.format = format
        }

        mutating func append(until seconds: Double, to input: AVAssetWriterInput, of writer: AVAssetWriter) async throws {
            let end = Int((seconds * Self.rate).rounded())
            while written < end {
                let frames = min(1024, end - written)
                var block: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(
                    allocator: nil, memoryBlock: nil, blockLength: frames * 4, blockAllocator: nil, customBlockSource: nil,
                    offsetToData: 0, dataLength: frames * 4, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
                )
                guard let block else { throw Failure(errorDescription: "The audio track couldn't be made.") }
                CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: frames * 4)
                var sample: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                    allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
                    presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(Self.rate)),
                    packetDescriptions: nil, sampleBufferOut: &sample
                )
                guard let sample else { throw Failure(errorDescription: "The audio track couldn't be made.") }
                try await waitUntilReady(input, of: writer)
                input.append(sample)
                written += frames
            }
        }
    }
}
