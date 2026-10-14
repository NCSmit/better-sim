import AVFoundation
import AppKit
import CoreImage
import CoreMediaIO
import os

private let log = Logger(subsystem: "local.bettersim", category: "mirror")

enum MirrorError: LocalizedError, Equatable {
    case cameraAccessDenied
    case screenNotFound(String)
    case screenInUse(String)
    case noPicture
    case cannotRecord
    case notRecording

    var errorDescription: String? {
        switch self {
        case .cameraAccessDenied:
            "macOS treats a connected device's screen as a camera. Allow BetterSim in System Settings › Privacy & Security › Camera."
        case .screenNotFound(let name):
            "BetterSim can't see the screen of \(name). Connect it with a USB cable, unlock it, and tap Trust if it asks."
        case .screenInUse(let name):
            "The screen of \(name) is in use by another app, such as QuickTime Player."
        case .noPicture:
            "The device hasn't sent a picture yet. Wake it up and try again."
        case .cannotRecord:
            "This device's screen can't be recorded."
        case .notRecording:
            "Nothing is being recorded."
        }
    }
}

/// iPhones and iPads connected with a cable can be used like cameras, which is how QuickTime Player records them,
/// once a process opts in to screen capture devices.
@MainActor
enum ScreenCaptureDevices {
    static func enable() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        let status = CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow
        )
        if status != 0 { log.error("could not allow screen capture devices: \(status)") }
    }

    /// Matches the screen by the device's UDID, written with or without its dash, or else by the device's name.
    nonisolated static func isScreen(uniqueID: String, name: String, of device: PhysicalDevice) -> Bool {
        let plain = { (text: String) in text.replacingOccurrences(of: "-", with: "").uppercased() }
        if let udid = device.udid, !udid.isEmpty, plain(uniqueID) == plain(udid) { return true }
        return name == device.name
    }

    /// Opting in makes a device on USB reconnect to offer its screen, which takes a few seconds, so this waits for it.
    /// That reconnect can interrupt a debugging session, which is why it only happens when asked to mirror.
    static func find(_ device: PhysicalDevice, timeout: Duration = .seconds(10)) async -> AVCaptureDevice? {
        enable()
        let deadline = ContinuousClock.now + timeout
        repeat {
            let screens = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: nil, position: .unspecified).devices
            if let screen = screens.first(where: { isScreen(uniqueID: $0.uniqueID, name: $0.localizedName, of: device) }) {
                return screen
            }
            try? await Task.sleep(for: .milliseconds(250))
        } while ContinuousClock.now < deadline
        return nil
    }

    static func requestAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            NSApp.activate()
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw MirrorError.cameraAccessDenied }
        default:
            throw MirrorError.cameraAccessDenied
        }
    }
}

/// The capture session for one device's screen: it feeds the preview, keeps the newest frame for screenshots,
/// plays the device's sound and records movies. AVFoundation objects are set up in `init` and afterwards only
/// used on `queue`, or under `lock`, which is what makes sharing it safe.
final class ScreenCapture: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()
    /// The size of the screen in pixels, from the first frame on. It changes when the device rotates.
    let sizes: AsyncStream<CGSize>
    private let sizeContinuation: AsyncStream<CGSize>.Continuation
    private let queue = DispatchQueue(label: "local.bettersim.screen-capture")
    private let frameQueue = DispatchQueue(label: "local.bettersim.screen-frames")
    private let frameOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let soundOutput = AVCaptureAudioPreviewOutput()
    private let lock = NSLock()
    private var latestFrame: CVPixelBuffer?
    private var frameSize = CGSize.zero
    private var recording = Recording.idle

    private enum Recording {
        case idle
        case running
        case stopping(CheckedContinuation<URL, Error>)
        case finished(Result<URL, Error>)
    }

    init(device: AVCaptureDevice) throws {
        let (sizes, sizeContinuation) = AsyncStream.makeStream(of: CGSize.self, bufferingPolicy: .bufferingNewest(1))
        self.sizes = sizes
        self.sizeContinuation = sizeContinuation
        super.init()
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input) else { throw MirrorError.screenInUse(device.localizedName) }
        session.addInput(input)
        frameOutput.alwaysDiscardsLateVideoFrames = true
        frameOutput.setSampleBufferDelegate(self, queue: frameQueue)
        soundOutput.volume = 1
        for output in [frameOutput, movieOutput, soundOutput] as [AVCaptureOutput] {
            if session.canAddOutput(output) {
                session.addOutput(output)
            } else {
                log.error("could not add \(String(describing: type(of: output)), privacy: .public) to the session")
            }
        }
    }

    func start() async {
        await onQueue { $0.session.startRunning() }
    }

    func stop() async {
        await onQueue { capture in
            if capture.movieOutput.isRecording { capture.movieOutput.stopRecording() }
            capture.session.stopRunning()
            capture.frameOutput.setSampleBufferDelegate(nil, queue: nil)
        }
        sizeContinuation.finish()
    }

    func setVolume(_ volume: Float) {
        queue.async { self.soundOutput.volume = volume }
    }

    /// The newest frame. It's kept rather than waited for, because a screen that doesn't change sends few frames.
    func latestImage() -> CGImage? {
        guard let buffer = lock.withLock({ latestFrame }) else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        return CIContext().createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    func startRecording(to url: URL) async throws {
        let started = await onQueue { capture -> Bool in
            guard capture.movieOutput.connection(with: .video) != nil else { return false }
            let isIdle = capture.lock.withLock {
                switch capture.recording {
                case .running, .stopping: return false
                case .idle, .finished:
                    capture.recording = .running
                    return true
                }
            }
            if isIdle { capture.movieOutput.startRecording(to: url, recordingDelegate: capture) }
            return true
        }
        if !started { throw MirrorError.cannotRecord }
    }

    /// Finishes the movie and returns where it was written.
    func stopRecording() async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            queue.async {
                enum Next { case stop, answer(Result<URL, Error>) }
                let next: Next = self.lock.withLock {
                    switch self.recording {
                    case .running:
                        self.recording = .stopping(continuation)
                        return .stop
                    case .finished(let result):
                        self.recording = .idle
                        return .answer(result)
                    case .idle, .stopping:
                        return .answer(.failure(MirrorError.notRecording))
                    }
                }
                switch next {
                case .stop: self.movieOutput.stopRecording()
                case .answer(let result): continuation.resume(with: result)
                }
            }
        }
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable (ScreenCapture) -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work(self)) }
        }
    }
}

extension ScreenCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let resized = lock.withLock {
            latestFrame = buffer
            defer { frameSize = size }
            return frameSize != size
        }
        if resized { sizeContinuation.yield(size) }
    }
}

extension ScreenCapture: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        // Some errors, such as running out of room, still leave a finished, playable movie.
        let finished = error == nil || (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
        let result: Result<URL, Error> = finished ? .success(url) : .failure(error ?? MirrorError.cannotRecord)
        let waiting: CheckedContinuation<URL, Error>? = lock.withLock {
            if case .stopping(let continuation) = recording {
                recording = .idle
                return continuation
            }
            recording = .finished(result)
            return nil
        }
        waiting?.resume(with: result)
    }
}

/// Shows a connected device's screen in a window, and takes screenshots and recordings from it.
@MainActor
final class DeviceMirror {
    let device: PhysicalDevice
    private let capture: ScreenCapture
    private let window: MirrorWindow
    private var resizing: Task<Void, Never>?
    private var disconnection: NSObjectProtocol?
    private var isStopped = false
    private(set) var isRecording = false
    /// Called once mirroring stops, because the window was closed or the device went away.
    var onStop: () -> Void = {}
    var playsSound = true { didSet { capture.setVolume(playsSound ? 1 : 0) } }

    /// `screen` is the expected screen size in pixels, to size the window before the first frame arrives.
    static func start(_ device: PhysicalDevice, screen: CGSize?) async throws -> DeviceMirror {
        try await ScreenCaptureDevices.requestAccess()
        guard let captureDevice = await ScreenCaptureDevices.find(device) else { throw MirrorError.screenNotFound(device.name) }
        let mirror = try DeviceMirror(device: device, captureDevice: captureDevice, screen: screen ?? CGSize(width: 1179, height: 2556))
        await mirror.capture.start()
        return mirror
    }

    private init(device: PhysicalDevice, captureDevice: AVCaptureDevice, screen: CGSize) throws {
        self.device = device
        capture = try ScreenCapture(device: captureDevice)
        window = MirrorWindow(title: device.name, session: capture.session, screen: screen)
        window.onClose = { [weak self] in self?.stop() }
        resizing = Task { [weak self, sizes = capture.sizes] in
            for await size in sizes { self?.window.fit(screen: size) }
        }
        disconnection = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: captureDevice, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        window.show()
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        resizing?.cancel()
        if let disconnection { NotificationCenter.default.removeObserver(disconnection) }
        window.close()
        let capture = capture
        Task { await capture.stop() }
        onStop()
    }

    /// The screen as it is now. Right after mirroring starts there may not be a frame yet, so this waits a little.
    func screenImage() async throws -> CGImage {
        for _ in 0..<30 {
            if let image = capture.latestImage() { return image }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MirrorError.noPicture
    }

    func startRecording(to url: URL) async throws {
        try await capture.startRecording(to: url)
        isRecording = true
    }

    func stopRecording() async throws -> URL {
        isRecording = false
        return try await capture.stopRecording()
    }
}

/// A window with nothing but the live screen in it, shaped like the screen.
@MainActor
final class MirrorWindow: NSObject, NSWindowDelegate {
    var onClose: () -> Void = {}
    private let window: NSWindow
    private var screen: CGSize?
    private var isClosing = false

    init(title: String, session: AVCaptureSession, screen: CGSize) {
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspect
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = title
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.contentView = PreviewView(preview: preview)
        window.delegate = self
        fit(screen: screen)
        window.center()
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard !isClosing else { return }
        isClosing = true
        window.close()
    }

    /// Gives the window the screen's shape, keeping it centred where it was.
    func fit(screen size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if let screen, abs(screen.width / screen.height - size.width / size.height) < 0.01 { return }
        screen = size
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let content = MirrorLayout.contentSize(for: size, in: visible.size)
        let current = window.contentRect(forFrameRect: window.frame)
        let frame = window.frameRect(forContentRect: NSRect(
            x: current.midX - content.width / 2,
            y: current.midY - content.height / 2,
            width: content.width,
            height: content.height
        ))
        window.contentAspectRatio = size
        window.setFrame(window.constrainFrameRect(frame, to: window.screen), display: true, animate: window.isVisible)
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosing else { return }
        isClosing = true
        onClose()
    }
}

private final class PreviewView: NSView {
    init(preview: AVCaptureVideoPreviewLayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        preview.frame = bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(preview)
    }

    required init?(coder: NSCoder) { nil }
}

enum MirrorLayout {
    /// The window content size for a screen of `pixels`: as big as fits in most of the visible screen, same shape.
    static func contentSize(for pixels: CGSize, in visible: CGSize) -> CGSize {
        guard pixels.width > 0, pixels.height > 0 else { return CGSize(width: 360, height: 780) }
        let scale = min(visible.width * 0.85 / pixels.width, visible.height * 0.85 / pixels.height)
        return CGSize(width: (pixels.width * scale).rounded(), height: (pixels.height * scale).rounded())
    }
}

enum DeviceScreenshot {
    /// Cuts the screen's rounded corners out of a frame, the way the Simulator masks its own screenshots.
    static func rounded(_ frame: CGImage, mask: URL) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: frame.width, height: frame.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        PDFArt.draw(mask, in: context, rect: bounds)
        context.setBlendMode(.sourceIn)
        context.draw(frame, in: bounds)
        return context.makeImage()
    }

    /// A frame from the device as a finished screenshot. A frame only goes in the bezel when it's upright, like the Simulator's.
    static func compose(_ frame: CGImage, chrome: PhysicalDeviceChrome?, framed: Bool, style: Backdrop.Style) -> CGImage {
        var image = frame
        if framed, let chrome {
            let screen = chrome.screenMask.flatMap { rounded(frame, mask: $0) } ?? frame
            if let inBezel = Framer.frame(screen, profile: chrome.profile) { image = inBezel }
        }
        return Backdrop.apply(style, to: image) ?? image
    }

    static func save(
        _ frame: CGImage,
        deviceName: String,
        chrome: PhysicalDeviceChrome?,
        framed: Bool,
        style: Backdrop.Style,
        folder: URL
    ) throws -> URL {
        let url = CaptureFiles.url(named: deviceName, in: folder, extension: "png")
        try ImageFile.writePNG(compose(frame, chrome: chrome, framed: framed, style: style), to: url)
        return url
    }
}
