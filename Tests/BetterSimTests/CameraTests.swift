import CoreImage
import Foundation
import ImageIO
import Testing
@testable import BetterSim

@MainActor
struct AppInjectorTests {
    @Test func readsTheProcessSimctlLaunched() {
        #expect(AppInjector.processIdentifier(launchOutput: "com.example.trails: 66929\n") == 66929)
        #expect(AppInjector.processIdentifier(launchOutput: "") == nil)
    }

    @Test func loadsNothingUntilItRelaunchesAnApp() {
        let injector = AppInjector(network: NetworkMonitor(), camera: SimulatorCamera(defaults: SimulatorCameraTests.scratchDefaults()))
        #expect(injector.features(of: "com.example.trails", on: "ABC").isEmpty)
    }

    @Test func onlyCountsProcessesInThatSimulator() {
        #expect(!AppInjector.isRunning(getpid(), on: "ABC"))
    }
}

@MainActor
struct SimulatorCameraTests {
    static func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "local.bettersim.tests.camera.\(UUID().uuidString)")!
    }

    static func size(of jpeg: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return (image.width, image.height)
    }

    @Test func drawsAMovingTestPattern() throws {
        let first = try #require(TestPatternProducer.draw(frame: 0, note: nil))
        let later = try #require(TestPatternProducer.draw(frame: 30, note: "Waiting for camera access"))
        #expect(first != later)
        #expect(Self.size(of: first).map { [$0.0, $0.1] } == [1280, 720])
    }

    @Test func fillsAnyCameraFrameTo720p() {
        let square = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 480, height: 480))
        #expect(MacCameraProducer.fill(square, to: SimulatorCamera.frameSize).extent == CGRect(x: 0, y: 0, width: 1280, height: 720))
    }

    @Test func remembersTheChosenCamera() {
        let defaults = Self.scratchDefaults()
        let camera = SimulatorCamera(defaults: defaults)
        camera.source = .testPattern
        #expect(defaults.string(forKey: "simulatorCamera") == SimulatorCamera.Source.testPatternID)
        #expect(SimulatorCamera(defaults: defaults).source == .testPattern)
    }

    @Test(.timeLimit(.minutes(1))) func streamsFramesOnlyWhileAnAppReads() async throws {
        let camera = SimulatorCamera(defaults: Self.scratchDefaults())
        camera.source = .testPattern
        let port = try await camera.start()
        defer { camera.stop() }
        #expect(camera.viewers == 0)
        let frames = try await Task.detached { try Self.readFrames(3, from: port) }.value
        #expect(frames.count == 3)
        #expect(frames.allSatisfy { Self.size(of: $0).map { [$0.0, $0.1] } == [1280, 720] })
        var attempts = 0
        while camera.viewers != 0, attempts < 100 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(camera.viewers == 0, "the camera stops once the last app hangs up")
    }

    /// Reads frames the way the library in the app does: a 4-byte big-endian length, then that many bytes of JPEG.
    nonisolated static func readFrames(_ count: Int, from port: UInt16) throws -> [Data] {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(connected == 0)
        func read(_ length: Int) throws -> Data {
            var data = Data(count: length)
            var done = 0
            while done < length {
                let count = data.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress! + done, length - done, 0) }
                try #require(count > 0, "the stream ended early")
                done += count
            }
            return data
        }
        return try (0..<count).map { _ in
            let header = try read(4)
            let length = header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
            return try read(Int(length))
        }
    }
}

/// Builds the camera library and a small tool that uses the camera the way an app would, and runs the tool on the
/// throwaway device named in BETTERSIM_CAMERA_SCRATCH_UDID with the library loaded and the test pattern streaming.
@MainActor
struct ScratchCameraTests {
    let udid = ProcessInfo.processInfo.environment["BETTERSIM_CAMERA_SCRATCH_UDID"]

    static let tool = #"""
    #import <AVFoundation/AVFoundation.h>
    #import <ImageIO/ImageIO.h>
    #import <QuartzCore/QuartzCore.h>

    @interface Receiver : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate>
    @property (atomic) NSInteger frames;
    @property (atomic) size_t width, height;
    @property (atomic) BOOL lit;
    @property (atomic) NSData *photo;
    @property (atomic) BOOL photoDone;
    @end

    @implementation Receiver
    - (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
        CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
        size_t width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer);
        uint8_t *pixel = (uint8_t *)CVPixelBufferGetBaseAddress(buffer) + (height / 2) * row + (width / 2) * 4;
        self.lit = pixel[0] + pixel[1] + pixel[2] > 60;
        CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
        self.width = width;
        self.height = height;
        self.frames += 1;
    }
    - (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
        self.photo = photo.fileDataRepresentation;
    }
    - (void)captureOutput:(AVCapturePhotoOutput *)output didFinishCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)settings error:(NSError *)error {
        self.photoDone = YES;
    }
    @end

    static void Spin(double seconds, BOOL (^until)(void)) {
        NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
        while ([end timeIntervalSinceNow] > 0 && !(until && until())) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
    }

    int main(void) {
        setvbuf(stdout, NULL, _IONBF, 0);
        @autoreleasepool {
            AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionBack];
            printf("device %s\n", device.localizedName.UTF8String ?: "none");
            AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:nil];
            AVCaptureSession *session = [AVCaptureSession new];
            [session beginConfiguration];
            session.sessionPreset = AVCaptureSessionPresetPhoto;
            if ([session canAddInput:input]) [session addInput:input];
            AVCaptureVideoDataOutput *video = [AVCaptureVideoDataOutput new];
            video.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
            Receiver *receiver = [Receiver new];
            [video setSampleBufferDelegate:receiver queue:dispatch_queue_create("frames", DISPATCH_QUEUE_SERIAL)];
            if ([session canAddOutput:video]) [session addOutput:video];
            AVCapturePhotoOutput *photo = [AVCapturePhotoOutput new];
            if ([session canAddOutput:photo]) [session addOutput:photo];
            photo.highResolutionCaptureEnabled = YES;
            [session commitConfiguration];
            AVCaptureVideoPreviewLayer *preview = [AVCaptureVideoPreviewLayer layerWithSession:session];
            preview.frame = CGRectMake(0, 0, 390, 844);
            [session startRunning];
            printf("running %d\n", session.isRunning);
            Spin(10, ^BOOL { return receiver.frames >= 20; });
            printf("frames %s %zux%zu lit %d\n", receiver.frames >= 20 ? "yes" : "no", receiver.width, receiver.height, receiver.lit);
            CALayer *content = preview.sublayers.firstObject;
            printf("preview %s\n", content.contents ? "yes" : "no");
            [video connectionWithMediaType:AVMediaTypeVideo].videoOrientation = AVCaptureVideoOrientationPortrait;
            NSInteger before = receiver.frames;
            Spin(5, ^BOOL { return receiver.frames >= before + 10; });
            printf("portrait %zux%zu\n", receiver.width, receiver.height);
            [photo capturePhotoWithSettings:[AVCapturePhotoSettings photoSettingsWithFormat:@{AVVideoCodecKey: AVVideoCodecTypeJPEG}] delegate:receiver];
            Spin(5, ^BOOL { return receiver.photoDone; });
            CGImageSourceRef source = receiver.photo ? CGImageSourceCreateWithData((__bridge CFDataRef)receiver.photo, NULL) : NULL;
            CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
            printf("photo %zux%zu\n", image ? CGImageGetWidth(image) : 0, image ? CGImageGetHeight(image) : 0);
            if (image) CGImageRelease(image);
            if (source) CFRelease(source);
            [session stopRunning];
            printf("stopped %d\n", !session.isRunning);
        }
        return 0;
    }
    """#

    static let frameworks = ["AVFoundation", "CoreGraphics", "CoreImage", "CoreMedia", "CoreVideo", "ImageIO", "QuartzCore", "UIKit", "UniformTypeIdentifiers"]
        .flatMap { ["-framework", $0] }

    @Test(.timeLimit(.minutes(2))) func givesAToolOnTheSimulatorACamera() async throws {
        guard let udid else { return }
        let folder = FileManager.default.temporaryDirectory.appending(path: "bettersim-camera-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let packageRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let library = folder.appending(path: "\(SimulatorCamera.libraryName).dylib")
        try ScratchNetworkTests.buildForSimulator(
            packageRoot.appending(path: "Monitor/\(SimulatorCamera.libraryName).m"), to: library,
            extraArguments: ["-dynamiclib", packageRoot.appending(path: "Monitor/BetterSimCameraPicker.m").path(percentEncoded: false)] + Self.frameworks
        )
        let toolSource = folder.appending(path: "camera.m")
        try Self.tool.write(to: toolSource, atomically: true, encoding: .utf8)
        let tool = folder.appending(path: "camera")
        try ScratchNetworkTests.buildForSimulator(toolSource, to: tool, extraArguments: Self.frameworks)

        let camera = SimulatorCamera(defaults: SimulatorCameraTests.scratchDefaults())
        camera.source = .testPattern
        let port = try await camera.start()
        defer { camera.stop() }
        let output = String(decoding: try await Simctl.run(
            ["spawn", udid, tool.path(percentEncoded: false)],
            environment: [
                "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": library.path(percentEncoded: false),
                "SIMCTL_CHILD_BETTERSIM_CAMERA_PORT": String(port),
            ]
        ), as: UTF8.self)
        #expect(output.contains("device Back Camera"), "\(output)")
        #expect(output.contains("running 1"))
        #expect(output.contains("frames yes 1280x720 lit 1"))
        #expect(output.contains("preview yes"))
        #expect(output.contains("portrait 406x720"))
        #expect(output.contains("photo 1280x720"))
        #expect(output.contains("stopped 1"))
    }
}
