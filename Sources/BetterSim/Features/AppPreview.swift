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
        let frames = frameCount(duration: timeRange.duration.seconds)
        let length = Double(frames) / Double(frameRate)
        var silence = try SilentAudio(seconds: length)
        var pending = source.copyNextSampleBuffer()
        var current: CVPixelBuffer?
        var frame = 0

        func appendFrame() {
            defer {
                frame += 1
                if frame == frames { videoInput.markAsFinished() }
            }
            let time = timeRange.start.seconds + Double(frame) / Double(frameRate)
            while let sample = pending, current == nil || CMSampleBufferGetPresentationTimeStamp(sample).seconds <= time + 0.0001 {
                current = CMSampleBufferGetImageBuffer(sample)
                pending = source.copyNextSampleBuffer()
            }
            guard let current, let pool = adaptor.pixelBufferPool else { return }
            var scaled: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &scaled)
            guard let scaled else { return }
            let image = CIImage(cvPixelBuffer: current)
            context.render(
                image.transformed(by: CGAffineTransform(scaleX: size.width / image.extent.width, y: size.height / image.extent.height)),
                to: scaled
            )
            adaptor.append(scaled, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: frameRate))
        }

        // The writer interleaves the two tracks and holds back whichever one gets ahead, sometimes until the other
        // has been encoded. Waiting on one track can then wait forever, so each pass feeds whichever track is ready,
        // the one further behind first.
        while frame < frames || !silence.isDone {
            let videoIsBehind = frame < frames && (silence.isDone || Double(frame) / Double(frameRate) <= silence.seconds)
            if videoIsBehind, videoInput.isReadyForMoreMediaData {
                appendFrame()
            } else if !silence.isDone, audioInput.isReadyForMoreMediaData {
                try silence.appendChunk(to: audioInput)
            } else if frame < frames, videoInput.isReadyForMoreMediaData {
                appendFrame()
            } else {
                guard writer.status == .writing else {
                    throw writer.error ?? Failure(errorDescription: "The app preview couldn't be written.")
                }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        reader.cancelReading()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? Failure(errorDescription: "The app preview couldn't be written.") }
        return length
    }

    /// The silent stereo track that goes with the video.
    private struct SilentAudio {
        static let rate = 44_100.0
        static let chunk = 1024
        private let format: CMAudioFormatDescription
        private let total: Int
        private var written = 0

        init(seconds: Double) throws {
            var description = AudioStreamBasicDescription(
                mSampleRate: Self.rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0
            )
            var format: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
            guard let format else { throw Failure(errorDescription: "The audio track couldn't be made.") }
            self.format = format
            total = Int((seconds * Self.rate).rounded())
        }

        var isDone: Bool { written >= total }
        var seconds: Double { Double(written) / Self.rate }

        mutating func appendChunk(to input: AVAssetWriterInput) throws {
            let frames = min(Self.chunk, total - written)
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
            input.append(sample)
            written += frames
            if isDone { input.markAsFinished() }
        }
    }
}
