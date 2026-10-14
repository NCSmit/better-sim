import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

private let log = Logger(subsystem: "local.bettersim", category: "devices")

/// The window that lists connected iPhones and iPads and runs actions on them.
@MainActor
final class DevicesWindow: NSObject, NSWindowDelegate {
    let model: PhysicalDevicesModel
    private var window: NSWindow?

    /// `onCapture` is called with each new screenshot or recording, to show it in the corner of the screen.
    init(preferences: Preferences, onCapture: @escaping @MainActor (URL) -> Void) {
        model = PhysicalDevicesModel(preferences: preferences, onCapture: onCapture)
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: DevicesView(model: model, preferences: model.preferences))
            let window = NSWindow(contentViewController: host)
            window.title = "Physical Devices"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        model.startWatching()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.stopWatching()
    }
}

@MainActor
final class PhysicalDevicesModel: ObservableObject {
    @Published private(set) var devices: [PhysicalDevice] = []
    @Published private(set) var hasLooked = false
    @Published private(set) var listProblem: String?
    @Published private(set) var selectedID: String?
    @Published private(set) var apps: [DeviceApp] = []
    @Published var selectedBundleID: String?
    @Published private(set) var chrome: PhysicalDeviceChrome?
    @Published private(set) var mirroredID: String?
    @Published private(set) var recordingSince: Date?
    @Published var playsSound = true { didSet { mirror?.playsSound = playsSound } }
    @Published private(set) var isWorking = false
    @Published private(set) var message: SimulatorModel.Message?

    let preferences: Preferences
    private let onCapture: @MainActor (URL) -> Void
    private var mirror: DeviceMirror?
    private var startingMirror: Task<DeviceMirror, Error>?
    private var deviceTypes: [SimulatorDeviceType]?
    private var watching: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var runningActions = 0

    init(preferences: Preferences, onCapture: @escaping @MainActor (URL) -> Void) {
        self.preferences = preferences
        self.onCapture = onCapture
    }

    var device: PhysicalDevice? { devices.first { $0.identifier == selectedID } }
    var app: DeviceApp? { apps.first { $0.bundleID == selectedBundleID } }
    var isMirroring: Bool { mirroredID != nil }

    // MARK: Devices

    /// Lists devices every few seconds while the window is open, so plugging one in shows up on its own.
    func startWatching() {
        guard watching == nil else { return }
        watching = Task { [weak self] in
            while !Task.isCancelled, let model = self {
                await model.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stopWatching() {
        watching?.cancel()
        watching = nil
    }

    func refresh() async {
        let before = device
        do {
            devices = try await PhysicalDevices.list()
            listProblem = nil
        } catch {
            log.error("could not list devices: \(error.localizedDescription, privacy: .public)")
            devices = []
            listProblem = error.localizedDescription
        }
        hasLooked = true
        if device == nil {
            selectedID = (devices.first { $0.connection.isReachable } ?? devices.first)?.identifier
        }
        let cameOnline = device?.connection.isReachable == true && before?.connection.isReachable != true
        if device?.identifier != before?.identifier || cameOnline {
            await deviceChanged()
        }
    }

    func select(_ id: String) {
        guard id != selectedID else { return }
        stopMirroring()
        selectedID = id
        Task { await deviceChanged() }
    }

    private func deviceChanged() async {
        apps = []
        chrome = nil
        guard let device else { return }
        if deviceTypes == nil { deviceTypes = (try? await SimulatorDeviceType.all()) ?? [] }
        guard device.identifier == selectedID else { return }
        chrome = PhysicalDeviceChrome.load(for: device, types: deviceTypes ?? [])
        await loadApps()
    }

    func loadApps() async {
        guard let device, device.connection.isReachable else { return apps = [] }
        do {
            let installed = try await PhysicalDevices.apps(on: device.identifier)
            guard device.identifier == selectedID else { return }
            apps = installed
            if selectedBundleID.map({ id in !installed.contains { $0.bundleID == id } }) ?? true {
                selectedBundleID = installed.first?.bundleID
            }
        } catch {
            guard device.identifier == selectedID else { return }
            apps = []
            show(error.localizedDescription, isError: true)
        }
    }

    // MARK: Screen

    func toggleMirroring() {
        if isMirroring {
            stopMirroring()
        } else {
            run(nil) { [self] in _ = try await startMirroring() }
        }
    }

    func stopMirroring() {
        mirror?.stop()
    }

    func takeScreenshot() {
        guard let device else { return }
        run("Screenshot saved") { [self] in
            let frame = try await startMirroring().screenImage()
            let url = try DeviceScreenshot.save(
                frame,
                deviceName: device.name,
                chrome: chrome,
                framed: preferences.framesScreenshots,
                style: preferences.backdrop,
                folder: preferences.saveFolder
            )
            add(url)
        }
    }

    func toggleRecording() {
        if let mirror, recordingSince != nil {
            finishRecording(from: mirror)
            return
        }
        run(nil) { [self] in
            let mirror = try await startMirroring()
            try await mirror.startRecording(to: FileManager.default.temporaryDirectory.appending(path: "BetterSim-\(UUID().uuidString).mov"))
            recordingSince = .now
        }
    }

    /// Starts mirroring the selected device, or returns the mirror that's already running.
    private func startMirroring() async throws -> DeviceMirror {
        if let mirror { return mirror }
        if let startingMirror { return try await startingMirror.value }
        guard let device else { throw MirrorError.screenNotFound("the device") }
        let starting = Task { [chrome] in try await DeviceMirror.start(device, screen: chrome?.profile.screenPixels) }
        startingMirror = starting
        defer { startingMirror = nil }
        let mirror = try await starting.value
        mirror.playsSound = playsSound
        mirror.onStop = { [weak self, weak mirror] in
            guard let self, let mirror else { return }
            mirrorStopped(mirror)
        }
        self.mirror = mirror
        mirroredID = device.identifier
        return mirror
    }

    private func mirrorStopped(_ stopped: DeviceMirror) {
        guard mirror === stopped else { return }
        mirror = nil
        mirroredID = nil
        // Closing the window or unplugging the device mid-recording still keeps what was recorded.
        if recordingSince != nil { finishRecording(from: stopped) }
    }

    private func finishRecording(from mirror: DeviceMirror) {
        recordingSince = nil
        let folder = preferences.saveFolder
        let name = mirror.device.name
        run("Recording saved") { [self] in
            let movie = try await mirror.stopRecording()
            defer { try? FileManager.default.removeItem(at: movie) }
            let mp4 = CaptureFiles.url(named: name, in: folder, extension: "mp4")
            do {
                try await MP4Exporter.export(video: movie, to: mp4)
                add(mp4)
            } catch {
                log.error("could not rewrap the recording as MP4: \(error.localizedDescription, privacy: .public)")
                try? FileManager.default.removeItem(at: mp4)
                let mov = CaptureFiles.url(named: name, in: folder, extension: "mov")
                try FileManager.default.moveItem(at: movie, to: mov)
                add(mov)
            }
        }
    }

    private func add(_ url: URL) {
        if preferences.showsThumbnail { onCapture(url) }
        guard preferences.copiesCaptures else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }

    // MARK: Apps

    func launchApp(relaunching: Bool = false) {
        guard let device, let app else { return }
        run("\(relaunching ? "Relaunched" : "Launched") \(app.name)") {
            try await PhysicalDevices.launch(app.bundleID, on: device.identifier, terminatingExisting: relaunching)
        }
    }

    func terminateApp() {
        guard let device, let app else { return }
        run(nil) { [self] in
            let stopped = try await PhysicalDevices.terminate(app.bundleID, on: device.identifier)
            show(stopped == 0 ? "\(app.name) isn't running" : "Terminated \(app.name)")
        }
    }

    func chooseAppToInstall() {
        guard let device else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle] + [UTType(filenameExtension: "ipa")].compactMap { $0 }
        panel.canChooseDirectories = false
        panel.message = "Choose an app built for \(device.name)."
        panel.prompt = "Install"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run("Installed \(url.deletingPathExtension().lastPathComponent)") { [self] in
            let bundleID = try await PhysicalDevices.install(url, on: device.identifier)
            await loadApps()
            if let bundleID, apps.contains(where: { $0.bundleID == bundleID }) { selectedBundleID = bundleID }
        }
    }

    /// devicectl has no "open URL" command, so the link goes to an app as it launches: the selected app, or Safari.
    func open(_ link: String, inSafari: Bool) {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let device, !link.isEmpty else { return }
        guard URL(string: link)?.scheme != nil else { return show("That isn't a link. Links start with a scheme, such as https://.", isError: true) }
        guard let bundleID = inSafari ? PhysicalDevices.safari : selectedBundleID else {
            return show("Choose the app that should open the link.", isError: true)
        }
        run("Opened \(link)") {
            try await PhysicalDevices.launch(bundleID, on: device.identifier, payloadURL: link)
        }
    }

    // MARK: Feedback

    func show(_ text: String, isError: Bool = false) {
        message = SimulatorModel.Message(text: text, isError: isError)
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(isError ? 6 : 2.5))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    private func run(_ done: String?, _ work: @escaping () async throws -> Void) {
        runningActions += 1
        isWorking = true
        Task {
            defer {
                runningActions -= 1
                isWorking = runningActions > 0
            }
            do {
                try await work()
                if let done { show(done) }
            } catch {
                log.error("device action failed: \(error.localizedDescription, privacy: .public)")
                show(error.localizedDescription, isError: true)
            }
        }
    }
}

// MARK: - Views

struct DevicesView: View {
    @ObservedObject var model: PhysicalDevicesModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 8) {
                DeviceListCard(model: model)
                if let message = model.message {
                    MessageCard(message: message)
                }
            }
            .frame(width: Theme.width)
            VStack(spacing: 8) {
                if let device = model.device {
                    ScreenCard(model: model, preferences: preferences, device: device)
                    DeviceAppCard(model: model, device: device)
                    OpenURLCard(model: model, device: device)
                } else {
                    Card {
                        Label("A device's screen and apps show up here.", systemImage: "iphone")
                            .font(Theme.font)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: Theme.width)
        }
        .padding(12)
        .fixedSize()
        .background(VisualEffect(material: .underWindowBackground).ignoresSafeArea())
        .animation(.snappy(duration: 0.18), value: model.message)
    }
}

private struct DeviceListCard: View {
    @ObservedObject var model: PhysicalDevicesModel

    var body: some View {
        Card(spacing: 6) {
            HStack(spacing: 6) {
                CardHeader(text: "DEVICES")
                Spacer(minLength: 0)
                if model.isWorking {
                    ProgressView().controlSize(.mini)
                }
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Look for devices again")
            }
            if model.devices.isEmpty {
                Text(emptyText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.devices) { device in
                Button { model.select(device.identifier) } label: {
                    DeviceRow(device: device, isSelected: device.identifier == model.selectedID, isMirrored: device.identifier == model.mirroredID)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var emptyText: String {
        if let problem = model.listProblem { return problem }
        return model.hasLooked ? "Connect an iPhone or iPad with a USB cable, unlock it and tap Trust." : "Looking for devices…"
    }
}

private struct DeviceRow: View {
    let device: PhysicalDevice
    let isSelected: Bool
    let isMirrored: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: device.symbol)
                .font(.system(size: 17))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if isMirrored {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .help("Mirroring")
                    }
                    ConnectionBadge(connection: device.connection)
                }
                Text(device.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(device.identifier)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(device.identifier)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(isSelected ? 0.1 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ConnectionBadge: View {
    let connection: PhysicalDevice.Connection

    var body: some View {
        Text(connection.rawValue)
            .font(.system(size: 9, weight: .bold))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.18), in: Capsule())
    }

    private var color: Color {
        switch connection {
        case .usb: .green
        case .wifi: .cyan
        case .notPaired: .orange
        case .offline: .gray
        }
    }
}

private struct ScreenCard: View {
    @ObservedObject var model: PhysicalDevicesModel
    @ObservedObject var preferences: Preferences
    let device: PhysicalDevice

    var body: some View {
        Card {
            CardHeader(text: "SCREEN")
            // Keep the controls while mirroring, so a recording can always be stopped here.
            if device.connection == .usb || model.mirroredID == device.identifier {
                HStack(spacing: 6) {
                    Pill(title: model.isMirroring ? "Stop" : "Mirror", symbol: "rectangle.on.rectangle", isOn: model.isMirroring) {
                        model.toggleMirroring()
                    }
                    .help(model.isMirroring ? "Stop mirroring" : "Show the device's screen in a window")
                    Pill(title: "Screenshot", symbol: "camera") { model.takeScreenshot() }
                        .help("Save a screenshot of the device")
                }
                recordButton
                SwitchRow(label: "Device frame", isOn: $preferences.framesScreenshots)
                    .disabled(model.chrome?.profile.hasChrome != true)
                    .help(model.chrome?.profile.hasChrome == true ? "Put screenshots in the device's bezel" : "BetterSim has no frame for this model")
                SwitchRow(label: "Device sound", isOn: $model.playsSound)
                    .help("Play the device's sound on this Mac while mirroring")
            } else {
                Text(screenHint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var recordButton: some View {
        if let since = model.recordingSince {
            Button { model.toggleRecording() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text("Stop Recording · \(Duration.seconds(context.date.timeIntervalSince(since)).formatted(.time(pattern: .minuteSecond)))")
                            .monospacedDigit()
                    }
                }
            }
            .buttonStyle(PillButtonStyle(isOn: true, tint: .red))
        } else {
            Pill(title: "Record", symbol: "record.circle") { model.toggleRecording() }
                .help("Record the device's screen to an MP4")
        }
    }

    private var screenHint: String {
        switch device.connection {
        case .wifi: "Mirroring, screenshots and recordings need a USB cable. Apps work over Wi-Fi too."
        case .notPaired: "Unlock the device and tap Trust to pair it with this Mac."
        case .offline, .usb: "Connect the device with a USB cable to see its screen."
        }
    }
}

private struct DeviceAppCard: View {
    @ObservedObject var model: PhysicalDevicesModel
    let device: PhysicalDevice

    var body: some View {
        Card {
            CardHeader(text: "APP")
            HStack(spacing: 6) {
                Picker("App", selection: $model.selectedBundleID) {
                    if model.apps.isEmpty {
                        Text("No apps").tag(String?.none)
                    }
                    ForEach(model.apps) { app in
                        Text(app.name).tag(Optional(app.bundleID))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                Button { Task { await model.loadApps() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(PillButtonStyle())
                    .frame(width: 30)
                    .help("Reload the list of apps")
            }
            if let app = model.app {
                Text(app.versionText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                Group {
                    Pill(title: "Launch") { model.launchApp() }
                    Pill(title: "Relaunch") { model.launchApp(relaunching: true) }
                    Pill(title: "Terminate") { model.terminateApp() }
                }
                .disabled(model.app == nil)
                .opacity(model.app == nil ? 0.45 : 1)
                Pill(title: "Install App…") { model.chooseAppToInstall() }
                    .help("Install an .app or .ipa built for this device")
            }
        }
        .disabled(!device.connection.isReachable)
        .opacity(device.connection.isReachable ? 1 : 0.5)
    }
}

private struct OpenURLCard: View {
    @ObservedObject var model: PhysicalDevicesModel
    let device: PhysicalDevice
    @State private var link = ""
    @State private var inSafari = false

    var body: some View {
        Card {
            CardHeader(text: "OPEN URL")
            HStack(spacing: 6) {
                TextField("myapp://path or https://…", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(open)
                Pill(title: "Open", action: open)
                    .frame(width: 54)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                    .opacity(link.trimmingCharacters(in: .whitespaces).isEmpty ? 0.45 : 1)
            }
            Segments(options: [(false, "App"), (true, "Safari")], selection: $inSafari)
            Text("Opens in \(inSafari ? "Safari" : model.app?.name ?? "the app") as it launches.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .disabled(!device.connection.isReachable)
        .opacity(device.connection.isReachable ? 1 : 0.5)
    }

    private func open() {
        model.open(link, inSafari: inSafari)
    }
}
