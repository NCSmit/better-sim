import AppKit
import SwiftUI

@main
enum BetterSimApp {
    static func main() {
        if let arguments = CommandLineTool.arguments(from: CommandLine.arguments) {
            CommandLineTool.runAndExit(arguments)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let preferences = Preferences()
    private let library = Library()
    private let overlay = OverlayModel()
    private let thumbnail = ThumbnailWindow()
    private let networkMonitor = NetworkMonitor()
    private let camera = SimulatorCamera()
    private lazy var networkWindow = NetworkWindow(monitor: networkMonitor)
    private lazy var model = SimulatorModel(preferences: preferences, library: library)
    private lazy var shortcuts = Shortcuts { [weak self] action in self?.perform(action) }
    private lazy var settings = SettingsWindow(preferences: preferences, shortcuts: shortcuts)
    private lazy var physicalDevices = DevicesWindow(preferences: preferences) { [weak self] url in
        self?.thumbnail.show(url, near: nil)
    }
    private var panel: PanelController?
    private var agentServer: AgentServer?
    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        if let folder = environment["BETTERSIM_DOC_IMAGES"], let udid = environment["BETTERSIM_DOC_UDID"] {
            Task {
                do {
                    try await DocImages.make(into: URL(filePath: folder), udid: udid, api: environment["BETTERSIM_DOC_API"])
                } catch {
                    FileHandle.standardError.write(Data("Couldn't make the images: \(error.localizedDescription)\n".utf8))
                }
                NSApp.terminate(nil)
            }
            return
        }
        if let folder = ProcessInfo.processInfo.environment["BETTERSIM_SNAPSHOT"] {
            Task { await snapshotPanel(into: URL(filePath: folder)) }
            return
        }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if others.contains(where: { $0 != .current }) {
            NSApp.terminate(nil)
            return
        }
        let panel = PanelController(model: model, overlayModel: overlay)
        panel.start()
        self.panel = panel
        let commands = AgentCommands { [weak panel] window in
            panel?.simulatorWindow == window ? panel?.currentScreen : nil
        }
        commands.camera = { [weak self] on, bundleID, source, udid in
            guard let self else { throw AgentFailure(.failed, "BetterSim is quitting.") }
            return try await self.model.cameraCommand(on: on, bundleID: bundleID, source: source, udid: udid)
        }
        agentServer = AgentServer.start(commands: commands)
        model.onCapture = { [weak self] url in self?.thumbnail.show(url, near: self?.panel?.simulatorWindow) }
        model.highlight = { [weak self] rect in self?.overlay.highlight = rect }
        model.readElements = { [weak self] in
            guard let self, let device = self.model.device else { return [] }
            let target = try await DeviceTarget.locate(device: device) { [weak panel] window in
                panel?.simulatorWindow == window ? panel?.currentScreen : nil
            }
            return try DeviceElements.read(simulator: target.simulator, window: target.window.frame, screen: target.screen)
                .map { AuditElement(role: $0.role, label: $0.label ?? "", frame: $0.frame.rect) }
        }
        model.injector = AppInjector(network: networkMonitor, camera: camera)
        model.openNetworkMonitor = { [weak self] in self?.networkWindow.show() }
        model.openPhysicalDevices = { [weak self] in self?.physicalDevices.show() }
        Task { [networkMonitor] in _ = try? await networkMonitor.start() }
        _ = shortcuts

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: "BetterSim")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        NotificationCenter.default.addObserver(forName: .openBetterSimSettings, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settings.show() }
        }
        Task { await model.refresh() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, SimulatorWindows.app != nil else { return }
                Task { await self.model.refresh() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopRecordingNow()
        agentServer?.stop()
        model.restoreNetwork()
    }

    private func perform(_ action: Shortcuts.Action) {
        switch action {
        case .screenshot: model.capture(.png)
        case .recordMP4: model.capture(model.recordingKind ?? .mp4)
        case .recordGIF: model.capture(model.recordingKind ?? .gif)
        case .togglePanel: panel?.isPinnedOpen.toggle()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let toggle = NSMenuItem(title: "Show Panel Next to Simulator", action: #selector(togglePanel), keyEquivalent: "")
        toggle.state = panel?.isPinnedOpen == true ? .on : .off
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        menu.addItem(item("Take Screenshot", #selector(screenshot)))
        if let kind = model.recordingKind {
            menu.addItem(item("Stop \(kind.rawValue) Recording", #selector(recordMP4)))
        } else {
            menu.addItem(item("Record MP4", #selector(recordMP4)))
            menu.addItem(item("Record GIF", #selector(recordGIF)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Network Monitor…", #selector(openNetwork)))
        menu.addItem(item("Open Simulator", #selector(openSimulator)))
        menu.addItem(item("Physical Devices…", #selector(openPhysicalDevices)))
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Install Command-Line Tool…", #selector(installCommandLineTool)))
        menu.addItem(.separator())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let about = NSMenuItem(title: "BetterSim \(version)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        menu.addItem(item("Quit BetterSim", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func togglePanel() { panel?.isPinnedOpen.toggle() }
    @objc private func screenshot() { model.capture(.png) }
    @objc private func recordMP4() { model.capture(model.recordingKind ?? .mp4) }
    @objc private func recordGIF() { model.capture(model.recordingKind ?? .gif) }
    @objc private func openSettings() { settings.show() }
    @objc private func installCommandLineTool() { CommandLineInstaller.installFromMenu() }
    @objc private func openNetwork() { networkWindow.show() }
    @objc private func openPhysicalDevices() { physicalDevices.show() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openSimulator() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SimulatorWindows.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Renders each tab of the panel to a PNG and quits. Used for the README images and to check layout changes.
    private func snapshotPanel(into folder: URL) async {
        await model.refresh()
        model.refreshRecentBuilds()
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: Theme.width + 40, height: 1100), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        let backdrop = LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.55), Color(red: 0.05, green: 0.07, blue: 0.2)], startPoint: .top, endPoint: .bottom)
        window.contentView = NSHostingView(rootView: PanelView(model: model, overlay: overlay, layout: PanelLayout())
            .environment(\.blursBehindPanel, false)
            .padding(20)
            .frame(width: Theme.width + 40, height: 1100, alignment: .top)
            .background(backdrop))
        window.orderFrontRegardless()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var shots: [(tab: PanelView.Tab, section: AppTab.Section?)] = PanelView.Tab.allCases.map { ($0, nil) }
        shots += AppTab.Section.allCases.dropFirst().map { (.app, $0) }
        for shot in shots {
            UserDefaults.standard.set(shot.tab.rawValue, forKey: "panelTab")
            UserDefaults.standard.set((shot.section ?? .actions).rawValue, forKey: "appTab")
            try? await Task.sleep(for: .milliseconds(500))
            guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let name = shot.section.map { "app-\($0)" } ?? "\(shot.tab)"
            try? bitmap.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(name).png"))
        }
        NSApp.terminate(nil)
    }
}

extension Notification.Name {
    static let openBetterSimSettings = Notification.Name("BetterSimOpenSettings")
}
