import AppKit
import SwiftUI

/// Renders the README images from the real views, using the Trails demo app on a throwaway simulator.
/// See docs/make-images.sh. Nothing here runs unless BETTERSIM_DOC_IMAGES is set.
@MainActor
enum DocImages {
    static let demoApp = "com.example.trails"
    static let english = Language(code: "en", locale: "en_US")

    /// Uses its own preferences and library, so nothing from the person running it ends up in the images.
    static func make(into folder: URL, udid: String, api: String?) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "local.bettersim.docs"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        defaults.set("/Users/you/Desktop", forKey: "saveFolder")
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let library = Library(file: FileManager.default.temporaryDirectory.appending(path: "bettersim-docs-\(UUID().uuidString).json"))
        for link in ["https://trails.example/invite/{ARG}", "trails://saved", "trails://trail/{ARG}"] {
            library.remember(link, for: demoApp)
        }
        let model = SimulatorModel(preferences: preferences, library: library)
        let camera = SimulatorCamera(defaults: defaults)
        camera.source = .testPattern
        model.injector = AppInjector(network: NetworkMonitor(), camera: camera)
        await model.refresh()
        await model.select(udid)
        model.selectApp(demoApp)

        try await DeviceSettings.setCleanStatusBar(true, on: udid)
        try await DeviceSettings.setAppearance("light", on: udid)
        try await AppActions.relaunch(demoApp, on: udid, in: english)
        let light = try await drawnScreen(of: udid)
        try await DeviceSettings.setAppearance("dark", on: udid)
        try await Task.sleep(for: .seconds(2))
        let dark = try await screen(of: udid)
        try await DeviceSettings.setAppearance("light", on: udid)
        try await Task.sleep(for: .seconds(1))
        await model.refreshSettings()
        guard let profile = model.profile, let framed = Framer.frame(light, profile: profile) else { return }

        try await hero(device: framed, model: model, folder: folder)
        try await tabs(model: model, folder: folder)
        try styles(framed, folder: folder)
        try await compare(light: light, dark: dark, profile: profile, folder: folder)
        try await appSections(model: model, udid: udid, folder: folder)
        try await network(udid: udid, api: api, folder: folder)
        try await settings(preferences: preferences, defaults: defaults, folder: folder)
        try await cameraImage(model: model, udid: udid, profile: profile, folder: folder)
    }

    private static func screen(of udid: String) async throws -> CGImage {
        let file = FileManager.default.temporaryDirectory.appending(path: "bettersim-doc-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try await Simctl.run(["io", udid, "screenshot", "--type=png", "--mask=alpha", file.path])
        guard let image = ImageFile.load(file) else { throw CocoaError(.fileReadCorruptFile) }
        return image
    }

    /// A freshly booted device takes a while to draw an app's first frame, so wait until the screen isn't black.
    private static func drawnScreen(of udid: String) async throws -> CGImage {
        var image = try await screen(of: udid)
        for _ in 0..<30 where brightness(of: image) < 0.3 {
            try await Task.sleep(for: .seconds(1))
            image = try await screen(of: udid)
        }
        try await Task.sleep(for: .seconds(1))
        return try await screen(of: udid)
    }

    private static func brightness(of image: CGImage) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drawn ? (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / (3 * 255) : 0
    }

    // MARK: Images

    private static func hero(device: CGImage, model: SimulatorModel, folder: URL) async throws {
        UserDefaults.standard.set(PanelView.Tab.capture.rawValue, forKey: "panelTab")
        let deviceHeight: CGFloat = 640
        let deviceWidth = deviceHeight * CGFloat(device.width) / CGFloat(device.height)
        let view = ZStack {
            Wallpaper()
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 14) {
                    SimulatorTitle(width: deviceWidth * 0.94)
                    Image(nsImage: NSImage(cgImage: device, size: .zero))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: deviceWidth, height: deviceHeight)
                        .shadow(color: .black.opacity(0.45), radius: 28, y: 16)
                }
                PanelView(model: model, overlay: OverlayModel(), layout: PanelLayout())
                    .environment(\.blursBehindPanel, false)
                    .padding(.top, 2)
            }
            .padding(.top, 10)
        }
        try await save(view, size: CGSize(width: 980, height: 780), to: folder.appending(path: "hero.png"), width: 1440)
    }

    private static func tabs(model: SimulatorModel, folder: URL) async throws {
        let order: [PanelView.Tab] = [.capture, .compare, .app, .device, .accessibility]
        var panels: [NSImage] = []
        for tab in order {
            UserDefaults.standard.set(tab.rawValue, forKey: "panelTab")
            UserDefaults.standard.set(AppTab.Section.actions.rawValue, forKey: "appTab")
            panels.append(try await panel(model: model))
        }
        try await strip(panels, to: folder.appending(path: "tabs.png"))
    }

    private static func styles(_ framed: CGImage, folder: URL) throws {
        let looks: [(String, Backdrop.Style)] = [
            ("style-gradient.png", Backdrop.Style(background: .gradient, ratio: .portrait, title: "Find your next trail")),
            ("style-white.png", Backdrop.Style(background: .white, ratio: .portrait, title: "Plan every climb")),
            ("style-black.png", Backdrop.Style(background: .black, ratio: .portrait, title: "Hike after dark")),
        ]
        for (name, style) in looks {
            guard let image = Backdrop.apply(style, to: framed) else { continue }
            try write(image, to: folder.appending(path: name), width: 540)
        }
    }

    private static func compare(light: CGImage, dark: CGImage, profile: DeviceProfile, folder: URL) async throws {
        let size = profile.screenPoints
        let split = OverlayModel()
        split.image = NSImage(cgImage: dark, size: .zero)
        split.mode = .split
        split.split = 0.5
        let rulers = OverlayModel()
        rulers.showsGrid = true
        rulers.gridColor = Color.pink.opacity(0.45)
        rulers.showsRulers = true
        rulers.pointer = CGPoint(x: size.width * 0.58, y: size.height * 0.4)
        for (name, overlay) in [("compare-split.png", split), ("compare-rulers.png", rulers)] {
            let view = ZStack {
                Image(nsImage: NSImage(cgImage: light, size: .zero)).resizable()
                OverlayView(overlay: overlay, pointsPerDevicePoint: 1)
            }
            let rep = try await render(view, size: size)
            guard let screen = rep.cgImage, let framed = Framer.frame(masked(screen, like: light), profile: profile) else { continue }
            try write(framed, to: folder.appending(path: name), width: 520)
        }
    }

    private static func appSections(model: SimulatorModel, udid: String, folder: URL) async throws {
        for (key, value) in [
            ("units", DefaultsValue.string("metric")), ("onboardingComplete", .bool(true)), ("dailyGoalKm", .integer(10)),
            ("mapStyle", .string("terrain")), ("lastOpenedTrail", .integer(4)), ("showsSunsetAlerts", .bool(false)),
        ] {
            try await AppDefaults.write(value, for: key, bundleID: demoApp, udid: udid)
        }
        model.loadDefaults()
        try await Task.sleep(for: .seconds(1))
        UserDefaults.standard.set(PanelView.Tab.app.rawValue, forKey: "panelTab")
        var panels: [NSImage] = []
        for section in [AppTab.Section.links, .push, .defaults] {
            UserDefaults.standard.set(section.rawValue, forKey: "appTab")
            panels.append(try await panel(model: model))
        }
        UserDefaults.standard.set(AppTab.Section.actions.rawValue, forKey: "appTab")
        try await strip(panels, to: folder.appending(path: "app.png"))
    }

    private static func network(udid: String, api: String?, folder: URL) async throws {
        guard let api, let library = NetworkMonitor.bundledLibrary else { return }
        let monitor = NetworkMonitor()
        let port = try await monitor.start()
        var environment = NetworkMonitor.launchEnvironment(port: port, dylib: library)
        environment["SIMCTL_CHILD_TRAILS_API"] = api
        try await Simctl.run(
            ["launch", "--terminate-running-process", udid, demoApp, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"],
            environment: environment
        )
        for _ in 0..<60 where monitor.events.count < 4 {
            try await Task.sleep(for: .milliseconds(250))
        }
        let selected = monitor.events.first { $0.method == "POST" }?.id
        let window = WindowChrome(title: "Network", glass: true) {
            NetworkView(monitor: monitor, selection: selected)
        }
        .environment(\.blursBehindPanel, false)
        .frame(width: 900, height: 540)
        let view = ZStack { Wallpaper(); window }
        try await save(view, size: CGSize(width: 1000, height: 640), to: folder.appending(path: "network.png"), width: 1640)
    }

    private static func settings(preferences: Preferences, defaults: UserDefaults, folder: URL) async throws {
        let shortcuts = Shortcuts(defaults: defaults) { _ in }
        _ = shortcuts.set(Shortcut(keyCode: 1, modifiers: UInt32(0x0100 | 0x0800)), for: .screenshot)
        defer { _ = shortcuts.set(nil, for: .screenshot) }
        let form = SettingsView(preferences: preferences, shortcuts: shortcuts)
        let height = NSHostingView(rootView: form).fittingSize.height
        let window = WindowChrome(title: "BetterSim Settings") { form }
        let rep = try await render(window, size: CGSize(width: 480, height: height + 28), key: true)
        guard let image = rep.cgImage else { return }
        try write(image, to: folder.appending(path: "settings.png"), width: 960)
    }

    // MARK: Pieces

    private struct Wallpaper: View {
        var body: some View {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.1, green: 0.13, blue: 0.4), Color(red: 0.3, green: 0.18, blue: 0.56)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [Color(red: 0.2, green: 0.55, blue: 1).opacity(0.45), .clear],
                    center: UnitPoint(x: 0.15, y: 0.1), startRadius: 0, endRadius: 520
                )
                RadialGradient(
                    colors: [Color(red: 0.95, green: 0.4, blue: 0.75).opacity(0.35), .clear],
                    center: UnitPoint(x: 0.9, y: 0.95), startRadius: 0, endRadius: 560
                )
            }
        }
    }

    private static let trafficLights = [
        Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25),
    ]

    /// The Simulator's own title bar, which sits above the device in Xcode 26.
    private struct SimulatorTitle: View {
        let width: CGFloat

        var body: some View {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(DocImages.trafficLights.indices, id: \.self) {
                        Circle().fill(DocImages.trafficLights[$0]).frame(width: 11, height: 11)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("iPhone 17 Pro").font(.system(size: 11.5, weight: .semibold))
                    Text("iOS 26.5").font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
                .padding(.leading, 6)
                Spacer()
                ForEach(["house", "camera", "rotate.right"], id: \.self) {
                    Image(systemName: $0).font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 14)
            .frame(width: width, height: 40)
            .background(Color(white: 0.16).opacity(0.92), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        }
    }

    /// A plain macOS window frame, with traffic lights and a title, around a view.
    /// A window frame for views drawn off screen. A `glass` window is see-through like the panel, and its content draws
    /// its own surface.
    private struct WindowChrome<Content: View>: View {
        let title: String
        var glass = false
        @ViewBuilder let content: Content

        var body: some View {
            VStack(spacing: 0) {
                ZStack {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(DocImages.trafficLights.indices, id: \.self) {
                            Circle().fill(DocImages.trafficLights[$0]).frame(width: 12, height: 12)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                }
                .frame(height: 28)
                .frame(maxWidth: .infinity)
                .background { if glass { PanelSurface() } }
                content
            }
            .background(glass ? Color.clear : Color(white: 0.15))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.1)))
        }
    }

    // MARK: Rendering

    /// The panel on its own, cut down to its cards.
    private static func panel(model: SimulatorModel) async throws -> NSImage {
        try await cutOut(PanelView(model: model, overlay: OverlayModel(), layout: PanelLayout()))
    }

    /// Part of the panel on its own, cut down to its cards.
    private static func cutOut<V: View>(_ view: V) async throws -> NSImage {
        let rep = try await render(
            view.environment(\.blursBehindPanel, false).frame(width: Theme.width).padding(14).frame(maxHeight: .infinity, alignment: .top),
            size: CGSize(width: Theme.width + 28, height: 1000)
        )
        guard let image = trimmed(rep) else { return NSImage() }
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
    }

    /// Trails' camera screen with the simulator camera on, showing the test pattern and a photo just taken with it.
    private static func cameraImage(model: SimulatorModel, udid: String, profile: DeviceProfile, folder: URL) async throws {
        guard let injector = model.injector else { return }
        try await AppDefaults.write(.bool(true), for: "openScanner", bundleID: demoApp, udid: udid)
        try await injector.relaunch(demoApp, on: udid, with: .camera)
        try await Task.sleep(for: .seconds(4))
        let shot = try await screen(of: udid)
        let card = try await cutOut(SimulatorCameraCard(model: model, camera: injector.camera))
        try await AppDefaults.delete("openScanner", bundleID: demoApp, udid: udid)
        try await injector.relaunch(demoApp, on: udid, with: [])
        injector.camera.stop()
        guard let framed = Framer.frame(shot, profile: profile) else { return }
        let deviceHeight: CGFloat = 560
        let view = ZStack {
            Wallpaper()
            HStack(alignment: .center, spacing: 36) {
                Image(nsImage: NSImage(cgImage: framed, size: .zero))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: deviceHeight * CGFloat(framed.width) / CGFloat(framed.height), height: deviceHeight)
                    .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
                Image(nsImage: card).resizable().frame(width: card.size.width, height: card.size.height)
            }
        }
        try await save(view, size: CGSize(width: 820, height: 640), to: folder.appending(path: "camera.png"), width: 1240)
    }

    /// Panels side by side on the wallpaper.
    private static func strip(_ panels: [NSImage], to url: URL) async throws {
        let width = panels.map(\.size.width).reduce(0, +) + CGFloat(panels.count + 1) * 12
        let height = (panels.map(\.size.height).max() ?? 0) + 24
        let view = ZStack(alignment: .top) {
            Wallpaper()
            HStack(alignment: .top, spacing: 12) {
                ForEach(panels.indices, id: \.self) { index in
                    Image(nsImage: panels[index]).resizable().frame(width: panels[index].size.width, height: panels[index].size.height)
                }
            }
            .padding(12)
        }
        try await save(view, size: CGSize(width: width, height: height), to: url, width: 1640)
    }

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    /// Draws a view off screen. With `key`, the window is made key first, so system controls show their active colours.
    private static func render<V: View>(_ view: V, size: CGSize, key: Bool = false) async throws -> NSBitmapImageRep {
        let window = KeyWindow(contentRect: NSRect(x: -8000, y: 0, width: size.width, height: size.height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        if key {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(800))
        guard let content = window.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        return rep
    }

    private static func save<V: View>(_ view: V, size: CGSize, to url: URL, width: CGFloat) async throws {
        let rep = try await render(view, size: size)
        guard let image = rep.cgImage else { throw CocoaError(.fileWriteUnknown) }
        try write(image, to: url, width: width)
    }

    /// Writes a PNG no wider than `width` pixels, so the README stays quick to load.
    private static func write(_ image: CGImage, to url: URL, width: CGFloat) throws {
        let scale = min(1, width / CGFloat(image.width))
        let size = CGSize(width: (CGFloat(image.width) * scale).rounded(), height: (CGFloat(image.height) * scale).rounded())
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        guard let scaled = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        try ImageFile.writePNG(scaled, to: url)
    }

    /// Cuts away the empty rows below the panel's last card.
    private static func trimmed(_ rep: NSBitmapImageRep) -> CGImage? {
        guard let image = rep.cgImage else { return nil }
        var bottom = rep.pixelsHigh - 1
        while bottom > 0 {
            let filled = stride(from: 0, to: rep.pixelsWide, by: 3).contains { (rep.colorAt(x: $0, y: bottom)?.alphaComponent ?? 0) > 0.02 }
            if filled { break }
            bottom -= 1
        }
        let height = min(rep.pixelsHigh, bottom + 1 + 28)
        return image.cropping(to: CGRect(x: 0, y: 0, width: rep.pixelsWide, height: height))
    }

    /// Cuts the rounded screen corners back out, using the transparency of the original screenshot.
    private static func masked(_ screen: CGImage, like original: CGImage) -> CGImage {
        guard let context = CGContext(
            data: nil, width: original.width, height: original.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return screen }
        let bounds = CGRect(x: 0, y: 0, width: original.width, height: original.height)
        context.draw(screen, in: bounds)
        context.setBlendMode(.destinationIn)
        context.draw(original, in: bounds)
        return context.makeImage() ?? screen
    }
}
