import AppKit
import AVFoundation
import CoreImage
import CoreText
import ImageIO
import Network
import UniformTypeIdentifiers

enum SimulatorCameraError: LocalizedError {
    case missingLibrary

    var errorDescription: String? {
        "BetterSim can't find \(SimulatorCamera.libraryName).dylib. Build the app with build.sh."
    }
}

/// Streams a camera into simulator apps relaunched with BetterSimCamera.dylib. Each app connects to 127.0.0.1 and
/// reads frames, each a 4-byte big-endian length and a JPEG. The Mac's camera only runs while an app is reading.
@MainActor
final class SimulatorCamera: ObservableObject {
    enum Source: Hashable, Identifiable {
        case mac(id: String, name: String)
        case testPattern

        static let testPatternID = "test-pattern"

        var id: String {
            switch self {
            case .mac(let id, _): id
            case .testPattern: Self.testPatternID
            }
        }

        var name: String {
            switch self {
            case .mac(_, let name): name
            case .testPattern: "Test Pattern"
            }
        }
    }

    nonisolated static let libraryName = "BetterSimCamera"
    nonisolated static let frameSize = CGSize(width: 1280, height: 720)

    @Published var source: Source { didSet { sourceChanged() } }
    @Published private(set) var cameras: [Source] = []
    @Published private(set) var port: UInt16?
    @Published private(set) var viewers = 0

    private let hub = FrameHub()
    private let defaults: UserDefaults
    private var listener: NWListener?
    private var waiters: [CheckedContinuation<UInt16, any Error>] = []
    private var producer: (any FrameProducer)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        source = .testPattern
        refreshCameras()
        let saved = defaults.string(forKey: "simulatorCamera")
        source = cameras.first { $0.id == saved } ?? (saved == Source.testPatternID ? .testPattern : cameras.first ?? .testPattern)
        hub.viewersChanged = { [weak self] count in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.viewersChanged(count) } }
        }
    }

    func refreshCameras() {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified)
        cameras = discovery.devices.map { .mac(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Starts listening if it isn't already, and returns the port once it's ready.
    @discardableResult
    func start() async throws -> UInt16 {
        if let port { return port }
        if listener == nil {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            parameters.acceptLocalOnly = true
            let listener = try NWListener(using: parameters)
            let hub = hub
            listener.newConnectionHandler = { connection in hub.add(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.listenerChanged(state) }
            }
            self.listener = listener
            listener.start(queue: .main)
        }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        hub.disconnectAll()
        resume(with: .failure(CancellationError()))
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue
            if let port { resume(with: .success(port)) }
        case .failed(let error):
            listener = nil
            port = nil
            resume(with: .failure(error))
        default:
            break
        }
    }

    private func resume(with result: Result<UInt16, any Error>) {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume(with: result) }
    }

    private func viewersChanged(_ count: Int) {
        viewers = count
        if count > 0, producer == nil { startProducer() }
        if count == 0 {
            producer?.stop()
            producer = nil
        }
    }

    private func sourceChanged() {
        defaults.set(source.id, forKey: "simulatorCamera")
        restartProducer()
    }

    private func restartProducer() {
        producer?.stop()
        producer = nil
        if viewers > 0 { startProducer() }
    }

    private func startProducer() {
        let hub = hub
        let emit: @Sendable (Data) -> Void = { hub.send($0) }
        switch source {
        case .testPattern:
            producer = TestPatternProducer(emit: emit)
        case .mac(let id, let name):
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                producer = MacCameraProducer(deviceID: id, emit: emit) ?? TestPatternProducer(note: "\(name) isn't available", emit: emit)
            case .notDetermined:
                producer = TestPatternProducer(note: "Waiting for camera access", emit: emit)
                Task {
                    if await AVCaptureDevice.requestAccess(for: .video) { restartProducer() }
                }
            default:
                producer = TestPatternProducer(note: "Allow BetterSim in Privacy & Security > Camera", emit: emit)
            }
        }
    }
}

/// The apps reading frames. A frame only goes to an app that has taken the last one, so a slow app skips frames
/// instead of falling behind.
final class FrameHub: @unchecked Sendable {
    var viewersChanged: (@Sendable (Int) -> Void)?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "local.bettersim.camera.connections")
    private var connections: [ObjectIdentifier: (connection: NWConnection, busy: Bool)] = [:]

    var count: Int { lock.withLock { connections.count } }

    func add(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.remove(id)
            default: break
            }
        }
        lock.withLock { connections[id] = (connection, false) }
        connection.start(queue: queue)
        waitForHangUp(connection, id: id)
        viewersChanged?(count)
    }

    func send(_ jpeg: Data) {
        var length = UInt32(jpeg.count).bigEndian
        let message = Data(bytes: &length, count: 4) + jpeg
        let ready: [(ObjectIdentifier, NWConnection)] = lock.withLock {
            let idle = connections.filter { !$0.value.busy }.map { ($0.key, $0.value.connection) }
            for (id, _) in idle { connections[id]?.busy = true }
            return idle
        }
        for (id, connection) in ready {
            connection.send(content: message, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.lock.withLock { self.connections[id]?.busy = false }
                if error != nil { connection.cancel() }
            })
        }
    }

    func disconnectAll() {
        let all = lock.withLock { connections.values.map(\.connection) }
        for connection in all { connection.cancel() }
    }

    /// Apps never send anything, so the only thing to read is the end of the connection.
    private func waitForHangUp(_ connection: NWConnection, id: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                connection.cancel()
                self?.remove(id)
            } else {
                self?.waitForHangUp(connection, id: id)
            }
        }
    }

    private func remove(_ id: ObjectIdentifier) {
        let removed = lock.withLock { connections.removeValue(forKey: id) != nil }
        if removed { viewersChanged?(count) }
    }
}

protocol FrameProducer: AnyObject, Sendable {
    func stop()
}

/// A moving test card, so the camera can be tried without turning on the Mac's camera.
final class TestPatternProducer: FrameProducer, @unchecked Sendable {
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "local.bettersim.camera.pattern"))
    private var frame = 0

    init(note: String? = nil, emit: @escaping @Sendable (Data) -> Void) {
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            guard let self, let jpeg = Self.draw(frame: self.frame, note: note) else { return }
            self.frame += 1
            emit(jpeg)
        }
        timer.resume()
    }

    func stop() {
        timer.cancel()
    }

    static func draw(frame: Int, note: String?, date: Date = .now) -> Data? {
        let width = Int(SimulatorCamera.frameSize.width), height = Int(SimulatorCamera.frameSize.height)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let colors = [CGColor(red: 0.13, green: 0.16, blue: 0.42, alpha: 1), CGColor(red: 0.36, green: 0.16, blue: 0.48, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])
        }

        let bars: [(CGFloat, CGFloat, CGFloat)] = [(1, 1, 1), (1, 0.85, 0.1), (0.1, 0.85, 0.95), (0.2, 0.8, 0.3), (0.9, 0.2, 0.75), (0.95, 0.25, 0.2), (0.15, 0.35, 0.95)]
        let barWidth = CGFloat(width) / CGFloat(bars.count)
        for (index, bar) in bars.enumerated() {
            context.setFillColor(CGColor(red: bar.0, green: bar.1, blue: bar.2, alpha: 1))
            context.fill(CGRect(x: CGFloat(index) * barWidth, y: CGFloat(height) - 90, width: barWidth, height: 90))
        }

        // A phone held upright only shows the middle of the frame, so everything that matters stays in that column.
        let middle = CGFloat(width) / 2
        let phase = Double(frame % 90) / 90
        let sweep = phase < 0.5 ? phase * 2 : (1 - phase) * 2
        context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.2, alpha: 1))
        context.fillEllipse(in: CGRect(x: middle - 130 + sweep * 200, y: 110, width: 60, height: 60))

        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "HH:mm:ss"
        Self.text("BetterSim", size: 44, weight: .bold, center: CGPoint(x: middle, y: CGFloat(height) / 2 + 95), in: context)
        Self.text(clock.string(from: date), size: 64, weight: .semibold, center: CGPoint(x: middle, y: CGFloat(height) / 2 + 20), in: context)
        Self.text(note ?? "Frame \(frame)", size: 24, weight: .medium, center: CGPoint(x: middle, y: CGFloat(height) / 2 - 50), in: context)

        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func text(_ string: String, size: CGFloat, weight: NSFont.Weight, center: CGPoint, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(x: center.x - bounds.width / 2 - bounds.minX, y: center.y - bounds.height / 2 - bounds.minY)
        CTLineDraw(line, context)
    }
}

/// One of the Mac's cameras, filled into 1280 × 720.
final class MacCameraProducer: NSObject, FrameProducer, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "local.bettersim.camera.capture")
    private let context = CIContext()
    private let emit: @Sendable (Data) -> Void

    init?(deviceID: String, emit: @escaping @Sendable (Data) -> Void) {
        guard let device = AVCaptureDevice(uniqueID: deviceID), let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        self.emit = emit
        super.init()
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(output) else { return nil }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        queue.async { self.session.startRunning() }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let jpeg = context.jpegRepresentation(
                  of: Self.fill(CIImage(cvPixelBuffer: buffer), to: SimulatorCamera.frameSize),
                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                  options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.8]
              )
        else { return }
        emit(jpeg)
    }

    static func fill(_ image: CIImage, to size: CGSize) -> CIImage {
        let scale = max(size.width / image.extent.width, size.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let x = scaled.extent.minX + (scaled.extent.width - size.width) / 2
        let y = scaled.extent.minY + (scaled.extent.height - size.height) / 2
        return scaled.cropped(to: CGRect(x: x, y: y, width: size.width, height: size.height))
            .transformed(by: CGAffineTransform(translationX: -x, y: -y))
    }
}
