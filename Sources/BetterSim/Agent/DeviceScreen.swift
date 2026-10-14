import AppKit
import ApplicationServices

/// Where the device screen is on the Mac, and how device points map onto it.
struct DeviceScreen: Equatable, Sendable {
    /// Top-left origin, in global screen points, like the window list, the Accessibility API and CGEvent.
    let frame: CGRect
    /// The screen's size in device points, turned the way the window shows it.
    let size: CGSize

    init(frame: CGRect, pointSize: CGSize) {
        self.frame = frame
        let long = max(pointSize.width, pointSize.height)
        let short = min(pointSize.width, pointSize.height)
        size = frame.width > frame.height ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
    }

    func screenPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: frame.minX + point.x * frame.width / size.width, y: frame.minY + point.y * frame.height / size.height)
    }

    func devicePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - frame.minX) * size.width / frame.width, y: (point.y - frame.minY) * size.height / frame.height)
    }

    func deviceRect(_ rect: CGRect) -> CGRect {
        let origin = devicePoint(rect.origin)
        return CGRect(x: origin.x, y: origin.y, width: rect.width * size.width / frame.width, height: rect.height * size.height / frame.height)
    }

    /// A point given as fractions of the screen's width and height, like a click on the browser preview.
    func devicePoint(fraction: CGPoint) -> CGPoint {
        CGPoint(x: min(max(fraction.x, 0), 1) * size.width, y: min(max(fraction.y, 0), 1) * size.height)
    }

    func contains(_ point: CGPoint) -> Bool {
        point.x >= 0 && point.y >= 0 && point.x < size.width && point.y < size.height
    }
}

/// A booted device, the Simulator window showing it, and where its screen is right now.
struct DeviceTarget: Sendable {
    let device: SimDevice
    let simulator: pid_t
    let window: SimulatorWindow
    let screen: DeviceScreen

    static func requireAccess() throws {
        guard AccessibilityScreenFinder.isTrusted else { throw AgentFailure.accessibilityNeeded }
    }

    /// `knownScreen` returns the screen rect the side panel already tracks for a window frame, if it has one.
    @MainActor
    static func locate(_ udid: String?, knownScreen: (CGRect) -> CGRect?) async throws -> DeviceTarget {
        try requireAccess()
        return try await locate(device: try await DeviceResolver.resolve(udid), knownScreen: knownScreen)
    }

    @MainActor
    static func locate(device: SimDevice, knownScreen: (CGRect) -> CGRect?) async throws -> DeviceTarget {
        try requireAccess()
        guard let simulator = SimulatorWindows.app?.processIdentifier else {
            throw AgentFailure(.noWindow, "The Simulator isn't open. Open it and show \(device.name), then try again.")
        }
        guard let profile = await DeviceProfiles.shared.profile(for: device) else {
            throw AgentFailure(.failed, "BetterSim couldn't read the screen size of \(device.name).")
        }
        let window = try DeviceWindows.window(for: device, in: SimulatorWindows.windows(), current: SimulatorWindows.currentDeviceUDID) {
            DeviceWindows.titles(simulator: simulator)
        }
        let frame = knownScreen(window.frame)
            ?? AccessibilityScreenFinder.screenFrame(in: window.frame, aspect: profile.screenPoints, pid: simulator)
            ?? ScreenGeometry.layout(window: window.frame, profile: profile)?.screen
        guard let frame, frame.width > 0, frame.height > 0 else {
            throw AgentFailure(.noWindow, "BetterSim couldn't find \(device.name)'s screen in its Simulator window.")
        }
        return DeviceTarget(device: device, simulator: simulator, window: window, screen: DeviceScreen(frame: frame, pointSize: profile.screenPoints))
    }
}

/// Picks the device a command is for.
enum DeviceResolver {
    static func resolve(_ udid: String?) async throws -> SimDevice {
        let devices: [SimDevice]
        do {
            devices = try await SimDevice.all()
        } catch {
            throw AgentFailure(.failed, "BetterSim couldn't list the simulators. \(error.localizedDescription)")
        }
        return try pick(udid, from: devices, current: SimulatorWindows.currentDeviceUDID)
    }

    static func pick(_ udid: String?, from devices: [SimDevice], current: String?) throws -> SimDevice {
        guard let udid else {
            guard let device = defaultDevice(in: devices, current: current) else {
                throw AgentFailure(.noDevice, "No simulator is booted. Boot one in the Simulator, then try again.")
            }
            return device
        }
        guard let device = devices.first(where: { $0.udid.caseInsensitiveCompare(udid) == .orderedSame }) else {
            throw AgentFailure(.noDevice, "No simulator has the UDID \(udid). Run bettersim devices to see them.")
        }
        guard device.isBooted else {
            throw AgentFailure(.noDevice, "\(device.name) isn't booted. Boot it in the Simulator, or run xcrun simctl boot \(device.udid).")
        }
        return device
    }

    /// The device the Simulator shows as current when it's booted, otherwise the first booted one.
    static func defaultDevice(in devices: [SimDevice], current: String?) -> SimDevice? {
        devices.first { $0.isBooted && $0.udid == current } ?? devices.first(where: \.isBooted)
    }
}

/// Screen sizes and bezels for each device type, read once.
actor DeviceProfiles {
    static let shared = DeviceProfiles()

    private var bundles: [String: URL]?
    private var profiles: [String: DeviceProfile] = [:]

    func profile(for device: SimDevice) async -> DeviceProfile? {
        if let cached = profiles[device.deviceTypeIdentifier] { return cached }
        if bundles == nil { bundles = try? await DeviceTypes.bundles() }
        guard let bundle = bundles?[device.deviceTypeIdentifier], let profile = DeviceProfile.load(deviceTypeBundle: bundle) else {
            return nil
        }
        profiles[device.deviceTypeIdentifier] = profile
        return profile
    }
}

/// Finds the Simulator window that shows a device. The frontmost window shows the current device; any other device's
/// window is found by its title.
enum DeviceWindows {
    static func window(
        for device: SimDevice,
        in windows: [SimulatorWindow],
        current: String?,
        titles: () -> [(title: String, frame: CGRect)]
    ) throws -> SimulatorWindow {
        guard let frontmost = windows.first else {
            throw AgentFailure(.noWindow, "No Simulator window is visible. Show \(device.name) in the Simulator, then try again.")
        }
        if device.udid == current { return frontmost }
        let named = titles().filter { shows(device.name, title: $0.title) }
        let matches = windows.filter { window in named.contains { AXTree.distance($0.frame, window.frame) < 4 } }
        guard let match = matches.first, matches.count == 1 else {
            throw AgentFailure(.noWindow, matches.isEmpty
                ? "\(device.name) has no visible Simulator window. Show it in the Simulator, then try again."
                : "More than one Simulator window shows a device named \(device.name). Bring the one you want to the front, then try again.")
        }
        return match
    }

    /// Simulator titles its windows with the device name, sometimes followed by the OS version.
    static func shows(_ name: String, title: String) -> Bool {
        title == name || [" – ", " - ", " ("].contains { title.hasPrefix(name + $0) }
    }

    static func titles(simulator: pid_t) -> [(title: String, frame: CGRect)] {
        AXTree.elements(AXUIElementCreateApplication(simulator), kAXWindowsAttribute).compactMap { window in
            guard let title = AXTree.string(window, kAXTitleAttribute), let frame = AXTree.frame(of: window) else { return nil }
            return (title, frame)
        }
    }
}
