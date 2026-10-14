import AppKit
import AVFoundation
import os

private let log = Logger(subsystem: "local.bettersim", category: "model")

/// Everything the panel shows about the booted devices, and the actions it runs on them.
@MainActor
final class SimulatorModel: ObservableObject {
    @Published private(set) var devices: [SimDevice] = []
    @Published private(set) var selectedUDID: String?
    @Published private(set) var apps: [InstalledApp] = []
    @Published var selectedBundleID: String?
    @Published private(set) var profile: DeviceProfile?

    @Published private(set) var appearance: String?
    @Published private(set) var textSize: String?
    @Published private(set) var increasedContrast = false
    @Published private(set) var cleanStatusBar = false
    @Published private(set) var accessibility: Set<AccessibilityToggle> = []
    @Published private(set) var network: NetworkCondition? = NetworkThrottle.isActive ? nil : .normal
    @Published private(set) var findings: [AccessibilityAudit.Finding] = []
    @Published private(set) var elements: [AuditElement] = []
    @Published private(set) var focusedElement: Int?
    @Published var speaksElements = true
    /// Reads the accessibility elements on the device screen, in device points. Set up by the app delegate.
    var readElements: @MainActor () async throws -> [AuditElement] = {
        throw SimulatorMenu.Failure(errorDescription: "Allow Accessibility for BetterSim to read the screen.")
    }
    /// Points out an element on the device screen, or clears the highlight with nil.
    var highlight: @MainActor (CGRect?) -> Void = { _ in }
    private let speech = AVSpeechSynthesizer()
    /// Relaunches apps with the network monitor or the camera loaded. Set up by the app delegate.
    var injector: AppInjector?
    var openNetworkMonitor: @MainActor () -> Void = {}
    var openPhysicalDevices: @MainActor () -> Void = {}

    @Published private(set) var recordingSince: Date?
    @Published private(set) var recordingKind: CaptureKind?
    @Published private(set) var captures: [URL] = []
    @Published private(set) var appIcon: NSImage?
    @Published private(set) var appGroups: [(id: String, url: URL)] = []
    @Published private(set) var recentBuilds: [RecentBuild] = []
    @Published private(set) var buildRecords: [BuildRecord] = []
    @Published private(set) var scenarios: [String] = []
    @Published private(set) var defaults: [(key: String, value: DefaultsValue)] = []
    /// Which defaults the editor shows: nil for the app's own, or an App Group identifier.
    @Published var defaultsGroup: String? { didSet { loadDefaults() } }
    private var group: (id: String, url: URL)? { appGroups.first { $0.id == defaultsGroup } }
    /// Called with each new screenshot or recording, to show it in the corner of the screen.
    var onCapture: @MainActor (URL) -> Void = { _ in }
    @Published private(set) var isWorking = false
    @Published private(set) var message: Message?

    enum CaptureKind: String, CaseIterable, Identifiable {
        case gif = "GIF"
        case mp4 = "MP4"
        case png = "PNG"

        var id: String { rawValue }
    }

    struct Message: Equatable {
        let text: String
        let isError: Bool
        let id = UUID()
    }

    let preferences: Preferences
    let library: Library
    /// Where the device screen is right now, with a top-left origin. The panel controller keeps this up to date.
    var screenRect: @MainActor () -> CGRect? = { nil }
    private let recorder = Recorder()
    private let editor = RecordingEditor()
    private var highFrameRateRecorder: HighFrameRateRecorder?
    /// The Simulator window the panel is docked to. The panel controller keeps this up to date.
    var simulatorWindow: @MainActor () -> SimulatorWindow? = { nil }
    private lazy var touchTracker = TouchTracker { [weak self] in self?.screenRect() }
    private var deviceTypes: [String: URL] = [:]
    private var profiles: [String: DeviceProfile] = [:]
    private var messageTask: Task<Void, Never>?

    init(preferences: Preferences, library: Library) {
        self.preferences = preferences
        self.library = library
    }

    var device: SimDevice? { devices.first { $0.udid == selectedUDID } }
    var app: InstalledApp? { apps.first { $0.bundleID == selectedBundleID } }

    // MARK: Devices

    func refresh() async {
        do {
            devices = try await SimDevice.all().filter(\.isBooted)
        } catch {
            log.error("could not list devices: \(error.localizedDescription)")
            devices = []
        }
        guard let first = devices.first else {
            selectedUDID = nil
            apps = []
            profile = nil
            return
        }
        let candidates = [SimulatorWindows.currentDeviceUDID, selectedUDID].compactMap { $0 }
        let wanted = candidates.first { udid in devices.contains { $0.udid == udid } } ?? first.udid
        if wanted != selectedUDID {
            await select(wanted)
        } else {
            await refreshApps()
        }
    }

    /// Follows the device in the Simulator's frontmost window.
    func followSimulator() async {
        guard let current = SimulatorWindows.currentDeviceUDID, current != selectedUDID else { return }
        if !devices.contains(where: { $0.udid == current }) {
            await refresh()
        } else {
            await select(current)
        }
    }

    func select(_ udid: String) async {
        selectedUDID = udid
        guard let device else { return }
        profile = await loadProfile(device)
        apps = (try? await InstalledApp.all(on: udid)) ?? []
        if selectedBundleID.map({ id in !apps.contains { $0.bundleID == id } }) ?? true {
            selectedBundleID = apps.first?.bundleID
        }
        loadAppIcon()
        await refreshSettings()
    }

    func selectApp(_ bundleID: String) {
        selectedBundleID = bundleID
        defaultsGroup = nil
        loadAppIcon()
    }

    private func loadAppIcon() {
        appIcon = app?.iconFile.flatMap(NSImage.init(contentsOf:))
        guard let bundleID = selectedBundleID, let udid = selectedUDID else { return appGroups = [] }
        Task { appGroups = await AppFolder.groups(bundleID: bundleID, udid: udid) }
    }

    func refreshApps() async {
        guard let udid = selectedUDID else { return }
        apps = (try? await InstalledApp.all(on: udid)) ?? apps
    }

    private func loadProfile(_ device: SimDevice) async -> DeviceProfile? {
        if let cached = profiles[device.deviceTypeIdentifier] { return cached }
        if deviceTypes.isEmpty { deviceTypes = (try? await DeviceTypes.bundles()) ?? [:] }
        guard let bundle = deviceTypes[device.deviceTypeIdentifier], let profile = DeviceProfile.load(deviceTypeBundle: bundle) else {
            return nil
        }
        profiles[device.deviceTypeIdentifier] = profile
        return profile
    }

    // MARK: Capture

    func takeScreenshot() {
        guard let device else { return }
        run("Screenshot saved") { [self] in
            let url = preferences.appStoreMode
                ? try await Screenshotter.captureForAppStore(device, folder: preferences.saveFolder)
                : try await Screenshotter.capture(
                    device,
                    profile: profile,
                    framed: preferences.framesScreenshots,
                    style: preferences.backdrop,
                    folder: preferences.saveFolder
                )
            add(url)
        }
    }

    func capture(_ kind: CaptureKind) {
        switch kind {
        case .png: takeScreenshot()
        case .gif, .mp4: recordingKind == nil ? startRecording(kind) : stopRecording()
        }
    }

    func toggleRecording() {
        recordingKind == nil ? startRecording(.mp4) : stopRecording()
    }

    private func startRecording(_ kind: CaptureKind) {
        guard let device else { return }
        let url = FileManager.default.temporaryDirectory.appending(path: "BetterSim-\(UUID().uuidString).mov")
        if preferences.highFrameRate {
            return startHighFrameRateRecording(kind, to: url)
        }
        do {
            try recorder.start(device, to: url)
            began(kind)
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    private func began(_ kind: CaptureKind) {
        recordingKind = kind
        recordingSince = .now
        if preferences.showsTouches { touchTracker.begin(at: .now) }
    }

    private func startHighFrameRateRecording(_ kind: CaptureKind, to url: URL) {
        guard let window = simulatorWindow(), let screen = screenRect() else {
            return show("Show the Simulator window to record at 120 fps.", isError: true)
        }
        let crop = screen.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        let scale = NSScreen.screens.first { $0.frame.intersects(SimulatorWindows.appKitFrame(window.frame)) }?.backingScaleFactor ?? 2
        let recorder = HighFrameRateRecorder()
        highFrameRateRecorder = recorder
        began(kind)
        Task {
            do {
                try await recorder.start(window: window.id, screen: crop, scale: scale, to: url)
            } catch {
                recordingKind = nil
                recordingSince = nil
                highFrameRateRecorder = nil
                if preferences.showsTouches { touchTracker.end() }
                show("Recording at 120 fps needs Screen Recording access for BetterSim in System Settings. (\(error.localizedDescription))", isError: true)
            }
        }
    }

    private func stopRecording() {
        guard let kind = recordingKind, let device else { return }
        recordingKind = nil
        recordingSince = nil
        let withTouches = preferences.showsTouches
        let trims = preferences.trimsRecordings
        if withTouches { touchTracker.end() }
        run(nil) { [self] in
            let recording: (url: URL, firstFrame: Date?)
            if let highFrameRate = highFrameRateRecorder {
                highFrameRateRecorder = nil
                recording = try await highFrameRate.stop()
            } else {
                guard let result = await recorder.stop() else { throw CocoaError(.fileWriteUnknown) }
                recording = (result.url, result.firstFrame)
            }
            var movie = recording.url
            let touches = withTouches ? touchTracker.touches(alignedTo: recording.firstFrame) : []
            if !touches.isEmpty {
                let burned = movie.deletingPathExtension().appendingPathExtension("touches.mov")
                try await TouchCompositor.burn(touches, into: movie, output: burned)
                try? FileManager.default.removeItem(at: movie)
                movie = burned
            }
            let finished = movie
            guard trims else { return try await save(finished, as: kind, range: nil, device: device) }
            editor.edit(finished, kind: kind) { [self] range, chosen in
                run(nil) { [self] in try await save(finished, as: chosen, range: range, device: device) }
            } cancel: {
                try? FileManager.default.removeItem(at: finished)
            }
        }
    }

    /// Turns a finished recording into the chosen file, then removes the recording.
    private func save(_ movie: URL, as kind: CaptureKind, range: CMTimeRange?, device: SimDevice) async throws {
        defer { try? FileManager.default.removeItem(at: movie) }
        let output = CaptureFiles.url(for: device, in: preferences.saveFolder, extension: kind.rawValue.lowercased())
        if kind == .gif {
            try await GIFExporter.export(video: movie, to: output, maxWidth: preferences.gifWidth, range: range)
        } else if preferences.appStoreMode {
            let length = try await AppPreviewExporter.export(video: movie, to: output, range: range)
            add(output)
            if !AppPreviewExporter.lengths.contains(length) {
                return show("App preview saved, but it's \(Int(length.rounded())) seconds. App Store Connect needs 15 to 30.", isError: true)
            }
            return show("App preview saved")
        } else {
            try await MP4Exporter.export(video: movie, to: output, range: range)
        }
        add(output)
        show("\(kind.rawValue) saved")
    }

    func stopRecordingNow() {
        recorder.stopNow()
    }

    /// Puts the Mac's network back to normal when BetterSim quits, so it never stays slow by accident.
    func restoreNetwork() {
        guard network != .normal else { return }
        try? NetworkThrottle.apply(.normal)
    }

    private func add(_ url: URL) {
        captures.insert(url, at: 0)
        captures = Array(captures.prefix(9))
        if preferences.showsThumbnail { onCapture(url) }
        guard preferences.copiesCaptures else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }

    // MARK: App

    func launchApp() { appAction("Launched") { try await AppActions.launch($0, on: $1) } }
    func relaunchApp() { appAction("Relaunched") { try await AppActions.relaunch($0, on: $1) } }
    func terminateApp() { appAction("Terminated") { await AppActions.terminate($0, on: $1) } }

    func relaunch(in language: Language) {
        appAction("Relaunched in \(language.name)") { try await AppActions.relaunch($0, on: $1, in: language) }
    }

    func setPermission(_ action: PermissionAction, _ service: (id: String, name: String)) {
        let done = "\(service.name): \(action == .grant ? "granted" : action == .revoke ? "revoked" : "reset")"
        appAction(done) { try await AppActions.setPermission(action, service.id, for: $0, on: $1) }
    }

    func syncPasteboard(toMac: Bool) {
        guard let udid = selectedUDID else { return }
        run(toMac ? "Copied the simulator's clipboard to your Mac" : "Copied your Mac's clipboard to the simulator") {
            try await AppActions.syncPasteboard(toMac: toMac, udid: udid)
        }
    }

    /// Shows the app's requests, relaunching it with the monitor first unless it's already running with it.
    func monitorNetwork() {
        guard let injector, let bundleID = selectedBundleID, let udid = selectedUDID else { return }
        let features = injector.features(of: bundleID, on: udid)
        if features.contains(.network) {
            openNetworkMonitor()
            return
        }
        appAction("Relaunched. Its requests now show in the network monitor.") { [self] bundleID, udid in
            try await injector.relaunch(bundleID, on: udid, with: features.union(.network))
            openNetworkMonitor()
        }
    }

    /// Whether the selected app is running with the simulator camera.
    var usesCamera: Bool {
        guard let injector, let bundleID = selectedBundleID, let udid = selectedUDID else { return false }
        return injector.features(of: bundleID, on: udid).contains(.camera)
    }

    /// What `bettersim camera` does: picks what the camera shows, then relaunches an app with the camera or without it.
    /// Without an app it uses the one selected in the panel.
    func cameraCommand(on: Bool?, bundleID: String?, source: String?, udid: String?) async throws -> String {
        guard let injector else { throw AgentFailure(.failed, "This copy of BetterSim can't run the simulator camera.") }
        let camera = injector.camera
        camera.refreshCameras()
        let choices = camera.cameras + [.testPattern]
        if let source {
            let wantsPattern = source.localizedCaseInsensitiveContains("test") || source.localizedCaseInsensitiveContains("pattern")
            guard let match = wantsPattern ? .testPattern : camera.cameras.first(where: { $0.name.localizedCaseInsensitiveContains(source) }) else {
                throw AgentFailure(.notFound, "There's no camera called \(source). Choose from: \(choices.map(\.name).joined(separator: ", ")).")
            }
            camera.source = match
        }
        guard let on else {
            return "The simulator camera shows \(camera.source.name). Cameras: \(choices.map(\.name).joined(separator: ", "))."
        }
        let device = try await DeviceResolver.resolve(udid ?? selectedUDID)
        guard let app = bundleID ?? selectedBundleID else { throw AgentFailure(.usage, "Say which app with --app BUNDLE_ID.") }
        let features = injector.features(of: app, on: device.udid)
        try await injector.relaunch(app, on: device.udid, with: on ? features.union(.camera) : features.subtracting(.camera))
        objectWillChange.send()
        return on
            ? "Relaunched \(app) on \(device.name) with the simulator camera, showing \(camera.source.name)."
            : "Relaunched \(app) on \(device.name) without the simulator camera."
    }

    /// Relaunches the selected app with the simulator camera, or without it when it already has it.
    func toggleCamera() {
        guard let injector, let bundleID = selectedBundleID, let udid = selectedUDID else { return }
        let features = injector.features(of: bundleID, on: udid)
        let name = app?.name ?? "The app"
        let adding = !features.contains(.camera)
        appAction(adding ? "\(name) now has a camera." : "\(name) no longer has the camera.") { [self] bundleID, udid in
            try await injector.relaunch(bundleID, on: udid, with: adding ? features.union(.camera) : features.subtracting(.camera))
            objectWillChange.send()
        }
    }

    func openAppBundle() {
        appAction(nil) { bundleID, udid in
            NSWorkspace.shared.activateFileViewerSelecting([try await AppActions.appBundle(bundleID, on: udid)])
        }
    }
    func resetPermissions() { appAction("Permissions reset") { try await AppActions.resetPermissions($0, on: $1) } }
    func clearDefaults() { appAction("UserDefaults cleared") { try await AppActions.clearDefaults($0, on: $1) } }

    func openDataFolder() {
        appAction(nil) { bundleID, udid in
            NSWorkspace.shared.open(try await AppActions.dataContainer(bundleID, on: udid))
        }
    }

    func uninstallApp() {
        appAction("Uninstalled") { [self] bundleID, udid in
            try await AppActions.uninstall(bundleID, on: udid)
            await refreshApps()
            selectApp(apps.first?.bundleID ?? "")
        }
    }

    /// Opens `link`, and saves `template` (the link before any {ARG} was filled in) for next time.
    func open(link: String, remembering template: String? = nil) {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let udid = selectedUDID, !link.isEmpty else { return }
        let bundleID = selectedBundleID
        run("Opened \(link)") { [self] in
            try await AppActions.open(link, on: udid)
            if let bundleID { library.remember(template ?? link, for: bundleID) }
        }
    }

    func sendPush(_ text: String) {
        guard let bundleID = selectedBundleID, let udid = selectedUDID else { return }
        switch PushPayload.validate(text) {
        case .failure(let problem):
            show(problem.localizedDescription, isError: true)
        case .success(let payload):
            run("Notification sent") { [self] in
                try await AppActions.push(payload, to: bundleID, on: udid)
                library.remember(payload: text, for: bundleID)
            }
        }
    }

    private func appAction(_ done: String?, _ action: @escaping (String, String) async throws -> Void) {
        guard let bundleID = selectedBundleID, let udid = selectedUDID else { return }
        run(done) { try await action(bundleID, udid) }
    }

    // MARK: Settings on the device

    func refreshSettings() async {
        guard let udid = selectedUDID else { return }
        async let appearance = DeviceSettings.appearance(udid)
        async let textSize = DeviceSettings.textSize(udid)
        async let contrast = DeviceSettings.increasedContrast(udid)
        async let statusBar = DeviceSettings.statusBarIsClean(udid)
        async let toggles = AccessibilityToggle.enabled(on: udid)
        (self.appearance, self.textSize, increasedContrast, cleanStatusBar, accessibility) = await (appearance, textSize, contrast, statusBar, toggles)
    }

    func setAppearance(_ style: String) {
        guard let udid = selectedUDID else { return }
        appearance = style
        run(nil) { try await DeviceSettings.setAppearance(style, on: udid) }
    }

    func setTextSize(_ size: String) {
        guard let udid = selectedUDID, size != textSize else { return }
        textSize = size
        run(nil) { try await DeviceSettings.setTextSize(size, on: udid) }
    }

    func setIncreasedContrast(_ on: Bool) {
        guard let udid = selectedUDID else { return }
        increasedContrast = on
        run(nil) { try await DeviceSettings.setIncreasedContrast(on, on: udid) }
    }

    func toggleAppearance() {
        setAppearance(appearance == "dark" ? "light" : "dark")
    }

    func set(_ toggle: AccessibilityToggle, _ on: Bool) {
        guard let udid = selectedUDID else { return }
        if on { accessibility.insert(toggle) } else { accessibility.remove(toggle) }
        run(nil) { try await toggle.set(on, on: udid) }
    }

    /// Slows the whole Mac's network down, since the Simulator shares it. nil means it was left on by an earlier run.
    func setNetwork(_ condition: NetworkCondition) {
        do {
            try NetworkThrottle.apply(condition)
            network = condition
            show(condition == .normal ? "Network back to normal" : "Your Mac's network now behaves like \(condition.rawValue)")
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    func setCleanStatusBar(_ on: Bool) {
        guard let udid = selectedUDID else { return }
        cleanStatusBar = on
        run(nil) { try await DeviceSettings.setCleanStatusBar(on, on: udid) }
    }

    func setLocation(_ coordinate: Coordinate, name: String) {
        guard let udid = selectedUDID else { return }
        run("Location set to \(name)") { try await DeviceSettings.setLocation(coordinate, on: udid) }
    }

    func clearLocation() {
        guard let udid = selectedUDID else { return }
        run("Location cleared") { try await DeviceSettings.clearLocation(on: udid) }
    }

    // MARK: More app and simulator tools

    func open(_ folder: AppFolder) {
        appAction(nil) { bundleID, udid in
            let url = try await AppFolder.url(folder, bundleID: bundleID, udid: udid)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        }
    }

    func openGroup(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func relaunch(inTimeZone timeZone: String) {
        appAction("Relaunched in \(TimeZones.name(timeZone))") {
            try await AppActions.relaunch($0, on: $1, inTimeZone: timeZone)
        }
    }

    func resetKeychain() {
        guard let udid = selectedUDID else { return }
        run("Keychain reset") { try await AppActions.resetKeychain(on: udid) }
    }

    func refreshRecentBuilds() {
        Task.detached(priority: .utility) {
            let builds = RecentBuild.scan()
            let records = BuildInsights.scan()
            await MainActor.run {
                self.recentBuilds = builds
                self.buildRecords = records
            }
        }
    }

    func install(_ build: RecentBuild) {
        guard let udid = selectedUDID else { return }
        run("Installed \(build.name)") { [self] in
            try await AppActions.install(build.app, on: udid)
            try await AppActions.launch(build.bundleID, on: udid)
            await refreshApps()
            selectApp(build.bundleID)
        }
    }

    func press(_ action: SimulatorMenu.Action) {
        do {
            try SimulatorMenu.press(action)
            show(action == .slowAnimations ? "Slow animations toggled" : "\(action.rawValue) sent")
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    func restartDevice() {
        guard let udid = selectedUDID else { return }
        run("Simulator restarted") { try await AppActions.restart(udid) }
    }

    /// Files dropped on the panel: payloads are sent, apps installed, photos and videos added, certificates trusted.
    func handleDrop(_ urls: [URL]) {
        guard let udid = selectedUDID else { return }
        let files = urls.map(DroppedFile.init)
        let media = files.compactMap { if case .media(let url) = $0 { url } else { nil } }
        if !media.isEmpty {
            run("Added \(media.count) item\(media.count == 1 ? "" : "s") to Photos") { try await AppActions.addMedia(media, on: udid) }
        }
        for file in files {
            switch file {
            case .push(let url):
                if let text = try? String(contentsOf: url, encoding: .utf8) { sendPush(text) }
            case .install(let url):
                run("Installed \(url.deletingPathExtension().lastPathComponent)") { [self] in
                    try await AppActions.install(url, on: udid)
                    await refreshApps()
                }
            case .certificate(let url):
                run("Trusted \(url.lastPathComponent)") { try await AppActions.trustCertificate(url, on: udid) }
            case .unsupported(let url):
                show("BetterSim can't use \(url.lastPathComponent).", isError: true)
            case .media:
                break
            }
        }
    }

    func loadScenarios() {
        guard let udid = selectedUDID, scenarios.isEmpty else { return }
        Task { scenarios = await LocationScenarios.all(udid: udid) }
    }

    func runScenario(_ name: String) {
        guard let udid = selectedUDID else { return }
        run("Running \(name)") { try await LocationScenarios.run(name, udid: udid) }
    }

    func startRoute(from start: String, to end: String, travel: LocationRoute.Travel) {
        guard let udid = selectedUDID else { return }
        run("\(travel.rawValue) from \(start) to \(end)") {
            let points = try await LocationRoute.waypoints(from: start, to: end, travel: travel)
            try await LocationRoute.start(points, travel: travel, udid: udid)
        }
    }

    func setStatusBar(_ style: StatusBarStyle) {
        guard let udid = selectedUDID else { return }
        cleanStatusBar = true
        run("Status bar set") { try await DeviceSettings.setStatusBar(style, on: udid) }
    }

    func trashDerivedData() {
        run(nil) { [self] in
            let count = try Housekeeping.trashDerivedData()
            show("Moved \(count) DerivedData folder\(count == 1 ? "" : "s") to the Trash")
            refreshRecentBuilds()
        }
    }

    func clearPreviewSimulators() {
        run("SwiftUI preview simulators deleted") { try await Housekeeping.clearPreviewSimulators() }
    }

    // MARK: Accessibility audit and VoiceOver navigator

    func runAudit() {
        guard let device else { return }
        let scale = profile?.scale ?? 3
        run(nil) { [self] in
            let elements = try await readElements()
            let file = FileManager.default.temporaryDirectory.appending(path: "BetterSim-audit-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: file) }
            try await Simctl.run(["io", device.udid, "screenshot", "--type=png", "--mask=ignored", file.path])
            findings = AccessibilityAudit.run(elements, screenshot: ImageFile.load(file), scale: scale)
            show(findings.isEmpty ? "No accessibility issues found on this screen" : "Found \(findings.count) issue\(findings.count == 1 ? "" : "s")")
        }
    }

    func point(at element: AuditElement) {
        highlight(element.frame)
    }

    func loadElements() {
        run(nil) { [self] in
            elements = try await readElements()
            focusedElement = nil
            show("\(elements.count) elements, in the order VoiceOver reads them")
        }
    }

    func moveFocus(by step: Int) {
        guard !elements.isEmpty else { return loadElements() }
        let next = min(max((focusedElement ?? -1) + step, 0), elements.count - 1)
        focusedElement = next
        let element = elements[next]
        highlight(element.frame)
        if speaksElements {
            speech.stopSpeaking(at: .immediate)
            speech.speak(AVSpeechUtterance(string: [element.label, AccessibilityAudit.name(of: element.role)].filter { !$0.isEmpty }.joined(separator: ", ")))
        }
    }

    func clearHighlight() {
        focusedElement = nil
        highlight(nil)
    }

    // MARK: UserDefaults

    func loadDefaults() {
        guard let bundleID = selectedBundleID, let udid = selectedUDID else { return defaults = [] }
        let group = group
        Task {
            do {
                defaults = try await AppDefaults.load(bundleID, udid: udid, group: group)
            } catch {
                defaults = []
                show(error.localizedDescription, isError: true)
            }
        }
    }

    func setDefault(_ key: String, to value: DefaultsValue) {
        let group = group
        appAction("Saved \(key)") { [self] bundleID, udid in
            try await AppDefaults.write(value, for: key, bundleID: bundleID, udid: udid, group: group)
            defaults = try await AppDefaults.load(bundleID, udid: udid, group: group)
        }
    }

    func deleteDefault(_ key: String) {
        let group = group
        appAction("Deleted \(key)") { [self] bundleID, udid in
            try await AppDefaults.delete(key, bundleID: bundleID, udid: udid, group: group)
            defaults = try await AppDefaults.load(bundleID, udid: udid, group: group)
        }
    }

    func pickColour(_ format: ColourFormat) {
        ColourPicker.pick(as: format) { [weak self] text in self?.show("Copied \(text)") }
    }

    // MARK: Feedback

    func show(_ text: String, isError: Bool = false) {
        message = Message(text: text, isError: isError)
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(isError ? 6 : 2.5))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    private func run(_ done: String?, _ work: @escaping () async throws -> Void) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await work()
                if let done { show(done) }
            } catch {
                log.error("action failed: \(error.localizedDescription)")
                show(error.localizedDescription, isError: true)
            }
        }
    }
}
