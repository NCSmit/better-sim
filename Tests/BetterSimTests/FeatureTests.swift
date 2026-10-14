import Foundation
import AVFoundation
import ImageIO
import Testing
@testable import BetterSim

struct PushPayloadTests {
    @Test func acceptsEveryTemplate() {
        for template in PushPayload.templates {
            #expect((try? PushPayload.validate(template.json).get()) != nil, "\(template.name)")
        }
    }

    @Test func explainsWhatIsWrong() {
        #expect(PushPayload.validate("{ nope").failure == .notJSON)
        #expect(PushPayload.validate("[1, 2]").failure == .notAnObject)
        #expect(PushPayload.validate(#"{ "alert": "hi" }"#).failure == .missingAPS)
        let huge = #"{ "aps": { "alert": ""# + String(repeating: "x", count: 5000) + #"" } }"#
        #expect(PushPayload.validate(huge).failure == .tooLarge(huge.utf8.count))
    }
}

struct DeviceSettingsTests {
    @Test func noticesStatusBarOverrides() {
        #expect(!DeviceSettings.hasStatusBarOverrides("Current Status Bar Overrides:\n============================="))
        #expect(DeviceSettings.hasStatusBarOverrides("Current Status Bar Overrides:\n=====\nTime: 9:41\n"))
        #expect(!DeviceSettings.hasStatusBarOverrides(""))
    }

    @Test func cleanStatusBarFlagsComeInPairs() {
        #expect(DeviceSettings.cleanStatusBar.count % 2 == 0)
        #expect(stride(from: 0, to: DeviceSettings.cleanStatusBar.count, by: 2).allSatisfy { DeviceSettings.cleanStatusBar[$0].hasPrefix("--") })
    }

    @Test func readsCoordinatesTheWayPeopleTypeThem() {
        #expect(Coordinate("52.37, 4.89") == Coordinate(latitude: 52.37, longitude: 4.89))
        #expect(Coordinate("-33.86 151.2") == Coordinate(latitude: -33.86, longitude: 151.2))
        #expect(Coordinate("95, 10") == nil)
        #expect(Coordinate("Amsterdam") == nil)
        #expect(Coordinate(latitude: 1.5, longitude: -2).argument == "1.500000,-2.000000")
    }
}

struct CaptureTests {
    @Test func gifFramesCoverTheWholeVideo() {
        #expect(GIFExporter.frameTimes(duration: 1, fps: 4) == [0, 0.25, 0.5, 0.75])
        #expect(GIFExporter.frameTimes(duration: 0.1, fps: 4) == [0])
        #expect(GIFExporter.frameTimes(duration: 0, fps: 15).isEmpty)
    }

    @Test func captureNamesNeverOverwriteEachOther() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let device = SimDevice(udid: "A", name: "iPhone 17 Pro", state: "Booted", deviceTypeIdentifier: "", runtime: "iOS 26.5")
        let date = Date(timeIntervalSince1970: 0)
        let first = CaptureFiles.url(for: device, in: folder, extension: "png", date: date)
        try Data().write(to: first)
        let second = CaptureFiles.url(for: device, in: folder, extension: "png", date: date)
        #expect(first.lastPathComponent.hasPrefix("iPhone 17 Pro "))
        #expect(second.lastPathComponent.hasSuffix(" 2.png"))
    }
}

@MainActor
struct LibraryTests {
    @Test func remembersRecentLinksFirstAndPayloadsPerApp() {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/library.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let library = Library(file: file)
        library.remember("app://one", for: "com.example")
        library.remember("app://two", for: "com.example")
        library.remember("app://one", for: "com.example")
        library.remember(payload: #"{"aps":{}}"#, for: "com.example")

        let reopened = Library(file: file)
        #expect(reopened.deepLinks(for: "com.example") == ["app://one", "app://two"])
        #expect(reopened.payload(for: "com.example") == #"{"aps":{}}"#)
        reopened.forget("app://two", for: "com.example")
        #expect(Library(file: file).deepLinks(for: "com.example") == ["app://one"])
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

/// Runs against a real booted simulator when BETTERSIM_LIVE_UDID is set. It only reads from the device.
@MainActor
struct LiveSimulatorTests {
    let udid = ProcessInfo.processInfo.environment["BETTERSIM_LIVE_UDID"]

    @Test func recordsAVideoAndTurnsItIntoAGIF() async throws {
        guard let udid else { return }
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let device = try #require(try await SimDevice.all().first { $0.udid == udid })

        let screenshot = try await Screenshotter.capture(device, profile: nil, framed: false, folder: folder)
        #expect(ImageFile.load(screenshot) != nil)

        let recorder = Recorder()
        let video = folder.appending(path: "clip.mov")
        try recorder.start(device, to: video)
        try await Task.sleep(for: .seconds(2.5))
        let saved = try #require(await recorder.stop()).url
        let gif = folder.appending(path: "clip.gif")
        try await GIFExporter.export(video: saved, to: gif, fps: 10, maxWidth: 200)
        let frames = CGImageSourceCreateWithURL(gif as CFURL, nil).map(CGImageSourceGetCount) ?? 0
        #expect(frames >= 10)
        if let keep = ProcessInfo.processInfo.environment["BETTERSIM_KEEP"] {
            for file in [screenshot, saved, gif] {
                try? FileManager.default.copyItem(at: file, to: URL(filePath: keep).appending(path: file.lastPathComponent))
            }
        }
    }

    @Test func readsTheDevicesSettingsAndApps() async throws {
        guard let udid else { return }
        #expect(await DeviceSettings.appearance(udid) != nil)
        #expect(DeviceSettings.textSizes.contains(await DeviceSettings.textSize(udid) ?? ""))
        _ = try await InstalledApp.all(on: udid)
    }
}

/// The tests below change the throwaway device named in BETTERSIM_SCRATCH_UDID. They share it, so they run one at a time.
@Suite(.serialized)
struct ScratchDeviceTests {}

extension ScratchDeviceTests {
    /// Changes settings on a throwaway device named in BETTERSIM_SCRATCH_UDID, and checks each change took.
    struct ScratchSimulatorTests {
        let udid = ProcessInfo.processInfo.environment["BETTERSIM_SCRATCH_UDID"]

        @Test func changesTheDevicesSettings() async throws {
            guard let udid else { return }
            try await DeviceSettings.setAppearance("dark", on: udid)
            #expect(await DeviceSettings.appearance(udid) == "dark")
            try await DeviceSettings.setAppearance("light", on: udid)
            #expect(await DeviceSettings.appearance(udid) == "light")

            try await DeviceSettings.setTextSize("accessibility-large", on: udid)
            #expect(await DeviceSettings.textSize(udid) == "accessibility-large")
            try await DeviceSettings.setTextSize("large", on: udid)

            try await DeviceSettings.setIncreasedContrast(true, on: udid)
            #expect(await DeviceSettings.increasedContrast(udid))
            try await DeviceSettings.setIncreasedContrast(false, on: udid)
            #expect(await !DeviceSettings.increasedContrast(udid))

            try await DeviceSettings.setCleanStatusBar(true, on: udid)
            #expect(await DeviceSettings.statusBarIsClean(udid))
            try await DeviceSettings.setCleanStatusBar(false, on: udid)
            #expect(await !DeviceSettings.statusBarIsClean(udid))

            try await DeviceSettings.setLocation(Coordinate.places[1].coordinate, on: udid)
            try await DeviceSettings.clearLocation(on: udid)
        }

        @Test func opensLinksSendsPushesAndClearsDefaults() async throws {
            guard let udid else { return }
            try await AppActions.open("https://example.com", on: udid)
            let payload = try PushPayload.validate(PushPayload.templates[0].json).get()
            try await AppActions.push(payload, to: "com.apple.mobilesafari", on: udid)
            try await AppActions.resetPermissions("com.apple.mobilesafari", on: udid)
            try await AppActions.clearDefaults("com.apple.mobilesafari", on: udid)
            let container = try await AppActions.dataContainer("com.apple.mobilesafari", on: udid)
            #expect(FileManager.default.fileExists(atPath: container.path))
        }
    }
}

struct TouchTests {
    @Test(.timeLimit(.minutes(1))) func burnsADotWhereAndWhenTheScreenWasTouched() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appending(path: "black.mov")
        try await Self.writeBlackVideo(to: video, size: CGSize(width: 200, height: 400), seconds: 2)

        let touch = Touch(points: [
            Touch.Point(time: 0.5, x: 0.5, y: 0.25),
            Touch.Point(time: 1.0, x: 0.5, y: 0.25),
        ])
        let burned = folder.appending(path: "touched.mov")
        try await TouchCompositor.burn([touch], into: video, output: burned)

        #expect(try await Self.brightness(of: burned, at: 0.2, x: 100, y: 100) < 0.1)
        #expect(try await Self.brightness(of: burned, at: 0.75, x: 100, y: 100) > 0.35)
        #expect(try await Self.brightness(of: burned, at: 0.75, x: 100, y: 300) < 0.1)
        #expect(try await Self.brightness(of: burned, at: 1.8, x: 100, y: 100) < 0.1)
    }

    @Test func followsTheDragAndFadesOutAfterRelease() throws {
        let drag = Touch(points: [Touch.Point(time: 1, x: 0, y: 0), Touch.Point(time: 2, x: 1, y: 0.5)])
        #expect(TouchCompositor.state(of: drag, at: 0.9) == nil)
        let middle = try #require(TouchCompositor.state(of: drag, at: 1.5))
        #expect(middle.x == 0.5 && middle.y == 0.25 && middle.opacity == 1)
        let fading = try #require(TouchCompositor.state(of: drag, at: 2 + TouchCompositor.fadeOut / 2))
        #expect(abs(fading.opacity - 0.5) < 0.0001)
        #expect(TouchCompositor.state(of: drag, at: 2 + TouchCompositor.fadeOut + 0.01) == nil)
    }

    static func writeBlackVideo(to url: URL, size: CGSize, seconds: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 30) {
            while !input.isReadyForMoreMediaData {
                try #require(writer.status == .writing, "\(writer.error?.localizedDescription ?? "The test video couldn't be written.")")
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt32.self)
            let count = CVPixelBufferGetDataSize(pixels) / 4
            for index in 0..<count { bytes[index] = UInt32(0xFF00_0000).littleEndian }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }

    static func brightness(of video: URL, at seconds: Double, x: Int, y: Int) async throws -> Double {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        let pixels = try #require(FramerTests.rgba(image))
        let index = (y * image.width + x) * 4
        return (Double(pixels[index]) + Double(pixels[index + 1]) + Double(pixels[index + 2])) / (3 * 255)
    }
}

extension ScratchDeviceTests {
    /// More changes on the throwaway device in BETTERSIM_SCRATCH_UDID.
    struct ScratchToolTests {
        let udid = ProcessInfo.processInfo.environment["BETTERSIM_SCRATCH_UDID"]

        @Test func editsAnAppsUserDefaults() async throws {
            guard let udid else { return }
            let app = "com.apple.mobilesafari"
            try await AppDefaults.write(.string("hello"), for: "BetterSimProbe", bundleID: app, udid: udid)
            try await AppDefaults.write(.integer(42), for: "BetterSimNumber", bundleID: app, udid: udid)
            var values = try await AppDefaults.load(app, udid: udid)
            #expect(values.first { $0.key == "BetterSimProbe" }?.value == .string("hello"))
            #expect(values.first { $0.key == "BetterSimNumber" }?.value == .integer(42))
            try await AppDefaults.delete("BetterSimProbe", bundleID: app, udid: udid)
            try await AppDefaults.delete("BetterSimNumber", bundleID: app, udid: udid)
            values = try await AppDefaults.load(app, udid: udid)
            #expect(!values.contains { $0.key.hasPrefix("BetterSim") })
        }

        @Test func addsMediaTrustsNothingBrokenAndRunsScenarios() async throws {
            guard let udid else { return }
            let image = FileManager.default.temporaryDirectory.appending(path: "bettersim-media.png")
            try ImageFile.writePNG(try #require(FramerTests.solidImage(width: 40, height: 40)), to: image)
            try await AppActions.addMedia([image], on: udid)
            try await AppActions.resetKeychain(on: udid)
            var style = StatusBarStyle()
            style.time = "10:10"
            style.batteryLevel = 42
            try await DeviceSettings.setStatusBar(style, on: udid)
            #expect(try await Simctl.output(["status_bar", udid, "list"]).contains("10:10"))
            try await DeviceSettings.setCleanStatusBar(false, on: udid)
            let scenarios = await LocationScenarios.all(udid: udid)
            #expect(scenarios.contains("City Run"))
            try await LocationScenarios.run("City Run", udid: udid)
            try await LocationRoute.start([Coordinate(latitude: 52.37, longitude: 4.89), Coordinate(latitude: 52.36, longitude: 4.88)], travel: .walking, udid: udid)
            try await DeviceSettings.clearLocation(on: udid)
            try await AppActions.relaunch("com.apple.mobilesafari", on: udid, inTimeZone: "Asia/Tokyo")
            try await AppActions.relaunch("com.apple.mobilesafari", on: udid, in: Language.common[3])
            let groups = await AppFolder.groups(bundleID: "com.apple.mobilesafari", udid: udid)
            #expect(!groups.isEmpty)
        }

        @Test func findsARouteOnAppleMaps() async throws {
            guard udid != nil else { return }
            let points = try await LocationRoute.waypoints(from: "Dam Square, Amsterdam", to: "Rijksmuseum, Amsterdam", travel: .walking)
            #expect(points.count > 2)
        }
    }
}

extension ScratchDeviceTests {
    struct ScratchAccessibilityTests {
        let udid = ProcessInfo.processInfo.environment["BETTERSIM_SCRATCH_UDID"]

        @Test func switchesAccessibilitySettings() async throws {
            guard let udid else { return }
            for toggle in AccessibilityToggle.allCases {
                try await toggle.set(true, on: udid)
            }
            #expect(await AccessibilityToggle.enabled(on: udid) == Set(AccessibilityToggle.allCases))
            for toggle in AccessibilityToggle.allCases {
                try await toggle.set(false, on: udid)
            }
            #expect(await AccessibilityToggle.enabled(on: udid).isEmpty)
        }
    }
}

struct ToolParsingTests {
    @Test func readsScenarioAndGroupListings() {
        let scenarios = "Name                 Description\n========\nCity Run             City Run\nFreeway Drive        Freeway Drive\n"
        #expect(LocationScenarios.parse(scenarios) == ["City Run", "Freeway Drive"])
        let groups = AppFolder.parseGroups("group.one\t/tmp/one\ngroup.two\t/tmp/two words\n")
        #expect(groups.map(\.id) == ["group.one", "group.two"])
        #expect(groups[1].url.path == "/tmp/two words")
    }

    @Test func sortsDroppedFiles() {
        #expect(DroppedFile(URL(filePath: "/x/payload.apns")) == .push(URL(filePath: "/x/payload.apns")))
        #expect(DroppedFile(URL(filePath: "/x/My App.app")) == .install(URL(filePath: "/x/My App.app")))
        #expect(DroppedFile(URL(filePath: "/x/photo.HEIC")) == .media(URL(filePath: "/x/photo.HEIC")))
        #expect(DroppedFile(URL(filePath: "/x/proxy.pem")) == .certificate(URL(filePath: "/x/proxy.pem")))
        #expect(DroppedFile(URL(filePath: "/x/notes.txt")) == .unsupported(URL(filePath: "/x/notes.txt")))
    }

    @Test func readsDefaultsTypesAndEdits() {
        let plist = try! PropertyListSerialization.data(fromPropertyList: [
            "flag": true, "count": 3, "ratio": 0.5, "name": "x", "list": [1, 2], "blob": Data([1, 2, 3]),
        ], format: .xml, options: 0)
        let values = Dictionary(uniqueKeysWithValues: AppDefaults.parse(plist).map { ($0.key, $0.value) })
        #expect(values["flag"] == .bool(true))
        #expect(values["count"] == .integer(3))
        #expect(values["ratio"] == .real(0.5))
        #expect(values["list"] == .array(2))
        #expect(values["blob"] == .data(3))
        #expect(DefaultsValue.integer(1).replaced(with: "seven") == nil)
        #expect(DefaultsValue.bool(false).replaced(with: "yes") == .bool(true))
        #expect(DefaultsValue.real(1).arguments == ["-float", "1.0"])
    }

    @Test func writesColoursAsCode() {
        #expect(ColourFormat.hex.text(red: 1, green: 0.5, blue: 0, alpha: 1) == "#FF8000")
        #expect(ColourFormat.swiftUI.text(red: 1, green: 0.5, blue: 0, alpha: 1) == "Color(red: 1.000, green: 0.500, blue: 0.000)")
        #expect(ColourFormat.uiKit.text(red: 0, green: 0, blue: 0, alpha: 0.5) == "UIColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 0.50)")
    }
}

struct BuildInsightsTests {
    static func manifest(_ builds: [(title: String, start: Double, seconds: Double, status: String)]) -> Data {
        var logs: [String: Any] = [:]
        for (index, build) in builds.enumerated() {
            logs["log-\(index)"] = [
                "title": build.title,
                "timeStartedRecording": build.start,
                "timeStoppedRecording": build.start + build.seconds,
                "schemeIdentifier-schemeName": "App",
                "primaryObservable": ["highLevelStatus": build.status],
            ] as [String: Any]
        }
        return try! PropertyListSerialization.data(fromPropertyList: ["logFormatVersion": 12, "logs": logs], format: .binary, options: 0)
    }

    @Test func readsBuildsAndSkipsCleans() {
        let now = Date.now.timeIntervalSinceReferenceDate
        let records = BuildInsights.parse(manifest: Self.manifest([
            ("Build App", now - 100, 12, "S"),
            ("Clean App", now - 90, 2, "S"),
            ("Build App", now - 50, 20, "E"),
        ]), project: "App")
        #expect(records.count == 2)
        #expect(records[0].duration == 20 && !records[0].succeeded)
        #expect(records[1].duration == 12 && records[1].succeeded)
    }

    @Test func summarisesTheLastWeekAgainstTheWeekBefore() throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let day = 86_400.0
        let records = [
            BuildRecord(project: "App", scheme: "App", started: now.addingTimeInterval(-1 * day), duration: 30, succeeded: true),
            BuildRecord(project: "App", scheme: "App", started: now.addingTimeInterval(-2 * day), duration: 10, succeeded: false),
            BuildRecord(project: "App", scheme: "App", started: now.addingTimeInterval(-9 * day), duration: 10, succeeded: true),
        ]
        let summary = try #require(BuildInsights.summary(records, now: now))
        #expect(summary.count == 2 && summary.average == 20 && summary.slowest == 30 && summary.failures == 1)
        #expect(summary.change == 1)
        #expect(BuildInsights.summary([], now: now) == nil)
    }

    @Test func namesProjectsAndDurations() {
        #expect(BuildInsights.projectName("WeatherApp-ahkjzrjadugnclgfrrxrniwzuqmn") == "WeatherApp")
        #expect(BuildInsights.projectName("ModuleCache.noindex") == "ModuleCache.noindex")
        #expect(BuildInsights.format(42) == "42s")
        #expect(BuildInsights.format(125) == "2m 5s")
    }
}

struct AppPreviewTests {
    @Test func picksApplesAcceptedSizes() {
        #expect(AppPreviewExporter.size(for: CGSize(width: 1206, height: 2622)) == CGSize(width: 886, height: 1920))
        #expect(AppPreviewExporter.size(for: CGSize(width: 2868, height: 1320)) == CGSize(width: 1920, height: 886))
        #expect(AppPreviewExporter.size(for: CGSize(width: 750, height: 1334)) == CGSize(width: 750, height: 1334))
        #expect(AppPreviewExporter.size(for: CGSize(width: 2064, height: 2752)) == CGSize(width: 1200, height: 1600))
    }

    /// Longer than two seconds, which is where writing one track at a time used to stall.
    @Test(.timeLimit(.minutes(1))) func writesH264At30FramesWithStereoAudio() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "phone.mov")
        try await TouchTests.writeBlackVideo(to: source, size: CGSize(width: 201, height: 437), seconds: 4)
        let preview = folder.appending(path: "preview.mp4")
        let length = try await AppPreviewExporter.export(video: source, to: preview)
        #expect(abs(length - 4) < 0.05)

        let asset = AVURLAsset(url: preview)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.naturalSize) == CGSize(width: 886, height: 1920))
        #expect(try await video.load(.nominalFrameRate) <= 30.5)
        let codec = try await video.load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType)
        #expect(codec == kCMVideoCodecType_H264)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let format = try await audio.load(.formatDescriptions).first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        #expect(format?.mChannelsPerFrame == 2)
        #expect(format?.mFormatID == kAudioFormatMPEG4AAC)
        #expect(abs(try await audio.load(.timeRange).duration.seconds - 4) < 0.1)
    }
}

struct NetworkThrottleTests {
    @Test func normalOnlyRemovesBetterSimsOwnRules() {
        let script = NetworkThrottle.script(for: .normal)
        #expect(script.contains("pfctl -q -a com.apple/bettersim -F all"))
        #expect(script.contains("pipe delete 81") && script.contains("pipe delete 82"))
        #expect(!script.contains("config"))
        #expect(!script.contains("dnctl -q flush"), "never flush other tools' pipes")
    }

    @Test func presetsBecomeDummynetPipes() {
        let script = NetworkThrottle.script(for: .threeG)
        #expect(script.contains("dnctl pipe 81 config bw 780Kbit/s delay 100 plr 0.00"))
        #expect(script.contains("dnctl pipe 82 config bw 330Kbit/s delay 100 plr 0.00"))
        #expect(script.contains("dummynet in quick proto { tcp, udp } from any to any pipe 81"))
        #expect(script.contains("pfctl -E"))
        #expect(NetworkThrottle.script(for: .offline).contains("plr 1.00"))
        #expect(!script.contains("\""), "the script goes inside an AppleScript string")
    }
}

struct AccessibilityAuditTests {
    @Test func flagsMissingLabelsSmallTargetsAndDuplicates() {
        let findings = AccessibilityAudit.run([
            AuditElement(role: "AXButton", label: "", frame: CGRect(x: 10, y: 10, width: 60, height: 60)),
            AuditElement(role: "AXButton", label: "Close", frame: CGRect(x: 10, y: 100, width: 20, height: 20)),
            AuditElement(role: "AXButton", label: "More", frame: CGRect(x: 10, y: 200, width: 50, height: 50)),
            AuditElement(role: "AXButton", label: "More", frame: CGRect(x: 80, y: 200, width: 50, height: 50)),
            AuditElement(role: "AXStaticText", label: "", frame: CGRect(x: 0, y: 0, width: 10, height: 10)),
        ])
        #expect(findings.first?.severity == .error)
        #expect(findings.first?.title == "Button has no label")
        #expect(findings.contains { $0.title == "Small tap target" && $0.element.label == "Close" })
        #expect(findings.contains { $0.title == "2 controls are called \"More\"" })
        #expect(!findings.contains { $0.element.role == "AXStaticText" })
    }

    @Test func measuresTextContrastFromThePixels() throws {
        let image = try #require(Self.text(on: 1.0, ink: 0.67))
        let faint = try #require(AccessibilityAudit.contrast(in: CGRect(x: 0, y: 0, width: 30, height: 10), of: image, scale: 3))
        #expect(faint > 1.8 && faint < 3, "contrast \(faint)")
        let bold = try #require(Self.text(on: 1.0, ink: 0.0))
        let strong = try #require(AccessibilityAudit.contrast(in: CGRect(x: 0, y: 0, width: 30, height: 10), of: bold, scale: 3))
        #expect(strong > 20)
        let findings = AccessibilityAudit.run([AuditElement(role: "AXStaticText", label: "Hi", frame: CGRect(x: 0, y: 0, width: 30, height: 10))], screenshot: image)
        #expect(findings.map(\.title) == ["Low text contrast"])
    }

    /// A 90 × 30 pixel image, a third of it covered in "ink", like a line of text.
    static func text(on paper: CGFloat, ink: CGFloat) -> CGImage? {
        let context = CGContext(data: nil, width: 90, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(gray: paper, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 90, height: 30))
        context?.setFillColor(CGColor(gray: ink, alpha: 1))
        context?.fill(CGRect(x: 0, y: 10, width: 90, height: 10))
        return context?.makeImage()
    }
}
