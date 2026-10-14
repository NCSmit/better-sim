import AppKit
import ApplicationServices
import MapKit

enum AppFolder: String, CaseIterable, Identifiable {
    case documents = "Documents"
    case library = "Library"
    case caches = "Caches"
    case preferences = "Preferences"
    case temporary = "tmp"
    case container = "Data Container"
    case bundle = "App Bundle"

    var id: String { rawValue }

    static func url(_ folder: AppFolder, bundleID: String, udid: String) async throws -> URL {
        if folder == .bundle { return try await AppActions.appBundle(bundleID, on: udid) }
        let data = try await AppActions.dataContainer(bundleID, on: udid)
        switch folder {
        case .documents: return data.appending(path: "Documents")
        case .library: return data.appending(path: "Library")
        case .caches: return data.appending(path: "Library/Caches")
        case .preferences: return data.appending(path: "Library/Preferences")
        case .temporary: return data.appending(path: "tmp")
        case .container, .bundle: return data
        }
    }

    /// `simctl get_app_container … groups` prints one "identifier<tab>path" line per App Group.
    static func parseGroups(_ listing: String) -> [(id: String, url: URL)] {
        listing.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (parts[0], URL(filePath: parts[1]))
        }
    }

    static func groups(bundleID: String, udid: String) async -> [(id: String, url: URL)] {
        parseGroups((try? await Simctl.output(["get_app_container", udid, bundleID, "groups"])) ?? "")
    }
}

/// Simulator builds Xcode left in DerivedData, newest first.
struct RecentBuild: Identifiable, Hashable {
    let app: URL
    let name: String
    let bundleID: String
    let configuration: String
    let built: Date

    var id: URL { app }

    static var derivedData: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Developer/Xcode/DerivedData")
    }

    static func scan(in derivedData: URL = derivedData, limit: Int = 12) -> [RecentBuild] {
        let fileManager = FileManager.default
        let projects = (try? fileManager.contentsOfDirectory(at: derivedData, includingPropertiesForKeys: nil)) ?? []
        let builds = projects.flatMap { project -> [RecentBuild] in
            let products = project.appending(path: "Build/Products")
            let folders = (try? fileManager.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? []
            return folders.filter { $0.lastPathComponent.hasSuffix("-iphonesimulator") }.flatMap { folder -> [RecentBuild] in
                let apps = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                return apps.filter { $0.pathExtension == "app" }.compactMap { app in
                    guard let info = NSDictionary(contentsOf: app.appending(path: "Info.plist")) as? [String: Any],
                          let bundleID = info["CFBundleIdentifier"] as? String
                    else { return nil }
                    let built = (try? app.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return RecentBuild(
                        app: app,
                        name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? app.deletingPathExtension().lastPathComponent,
                        bundleID: bundleID,
                        configuration: folder.lastPathComponent.replacingOccurrences(of: "-iphonesimulator", with: ""),
                        built: built
                    )
                }
            }
        }
        return Array(builds.sorted { $0.built > $1.built }.prefix(limit))
    }
}

/// Presses items in the Simulator's own menus, for the actions simctl doesn't offer. Needs Accessibility access.
enum SimulatorMenu {
    enum Action: String, CaseIterable, Identifiable {
        case shake = "Shake"
        case memoryWarning = "Memory Warning"
        case slowAnimations = "Slow Animations"

        var id: String { rawValue }

        var path: (menu: String, item: String) {
            switch self {
            case .shake: ("Device", "Shake")
            case .memoryWarning: ("Debug", "Simulate Memory Warning")
            case .slowAnimations: ("Debug", "Slow Animations")
            }
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static func press(_ action: Action) throws {
        guard AXIsProcessTrusted() else {
            throw Failure(errorDescription: "Allow Accessibility for BetterSim to use \(action.rawValue).")
        }
        guard let simulator = SimulatorWindows.app else { throw Failure(errorDescription: "The Simulator isn't running.") }
        let app = AXUIElementCreateApplication(simulator.processIdentifier)
        guard let menuBar = value(app, kAXMenuBarAttribute) as! AXUIElement?,
              let menu = child(of: menuBar, titled: action.path.menu),
              let items = (value(menu, kAXChildrenAttribute) as? [AXUIElement])?.first,
              let item = child(of: items, titled: action.path.item)
        else { throw Failure(errorDescription: "The Simulator has no \(action.path.item) menu item.") }
        guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
            throw Failure(errorDescription: "The Simulator didn't respond to \(action.path.item).")
        }
    }

    private static func child(of element: AXUIElement, titled title: String) -> AXUIElement? {
        (value(element, kAXChildrenAttribute) as? [AXUIElement])?.first {
            (value($0, kAXTitleAttribute) as? String)?.hasPrefix(title) == true
        }
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
}

/// What to do with a file dropped on the panel.
enum DroppedFile: Equatable {
    case push(URL)
    case install(URL)
    case media(URL)
    case certificate(URL)
    case unsupported(URL)

    init(_ url: URL) {
        switch url.pathExtension.lowercased() {
        case "apns", "json": self = .push(url)
        case "app": self = .install(url)
        case "png", "jpg", "jpeg", "heic", "gif", "mov", "mp4", "m4v", "vcf": self = .media(url)
        case "cer", "crt", "der", "pem": self = .certificate(url)
        default: self = .unsupported(url)
        }
    }
}

enum LocationScenarios {
    /// Reads the table `simctl location list` prints: a header, a rule, then one "Name   Description" row each.
    static func parse(_ listing: String) -> [String] {
        listing.split(separator: "\n").dropFirst(2).compactMap { line in
            let name = line.components(separatedBy: "  ").first?.trimmingCharacters(in: .whitespaces) ?? ""
            return name.isEmpty ? nil : name
        }
    }

    static func all(udid: String) async -> [String] {
        parse((try? await Simctl.output(["location", udid, "list"])) ?? "")
    }

    static func run(_ name: String, udid: String) async throws {
        try await Simctl.run(["location", udid, "run", name])
    }
}

/// Simulates travelling a real route from Apple Maps.
enum LocationRoute {
    enum Travel: String, CaseIterable, Identifiable {
        case walking = "Walking"
        case cycling = "Cycling"
        case driving = "Driving"

        var id: String { rawValue }

        var metresPerSecond: Double {
            switch self {
            case .walking: 1.4
            case .cycling: 5
            case .driving: 14
            }
        }

        var transport: MKDirectionsTransportType {
            self == .driving ? .automobile : .walking
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static func waypoints(from start: String, to end: String, travel: Travel) async throws -> [Coordinate] {
        let request = MKDirections.Request()
        request.source = try await mapItem(start)
        request.destination = try await mapItem(end)
        request.transportType = travel.transport
        guard let route = try await MKDirections(request: request).calculate().routes.first else {
            throw Failure(errorDescription: "Apple Maps found no route.")
        }
        let polyline = route.polyline
        var points = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
        polyline.getCoordinates(&points, range: NSRange(location: 0, length: polyline.pointCount))
        return points.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
    }

    static func start(_ waypoints: [Coordinate], travel: Travel, udid: String) async throws {
        guard waypoints.count >= 2 else { throw Failure(errorDescription: "A route needs at least two points.") }
        let lines = waypoints.map(\.argument).joined(separator: "\n") + "\n"
        try await Simctl.run(
            ["location", udid, "start", "--speed=\(travel.metresPerSecond)", "--interval=1", "-"],
            input: Data(lines.utf8)
        )
    }

    private static func mapItem(_ query: String) async throws -> MKMapItem {
        if let coordinate = Coordinate(query) {
            return MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)))
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        guard let item = try await MKLocalSearch(request: request).start().mapItems.first else {
            throw Failure(errorDescription: "Apple Maps couldn't find \"\(query)\".")
        }
        return item
    }
}

struct StatusBarStyle: Equatable {
    var time = "9:41"
    var batteryLevel = 100.0
    var batteryState = "charged"
    var network = "wifi"
    var wifiBars = 3.0
    var cellularBars = 4.0
    var carrier = ""

    static let networks = ["wifi", "5g", "lte", "4g", "3g", "hide"]
    static let batteryStates = ["charged", "charging", "discharging"]

    var arguments: [String] {
        [
            "--time", time,
            "--dataNetwork", network,
            "--wifiMode", "active", "--wifiBars", String(Int(wifiBars)),
            "--cellularMode", "active", "--cellularBars", String(Int(cellularBars)),
            "--operatorName", carrier,
            "--batteryState", batteryState, "--batteryLevel", String(Int(batteryLevel)),
        ]
    }
}

enum Housekeeping {
    /// Moves DerivedData to the Trash, so it can still be recovered.
    static func trashDerivedData() throws -> Int {
        let folder = RecentBuild.derivedData
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for item in items { try FileManager.default.trashItem(at: item, resultingItemURL: nil) }
        return items.count
    }

    static func clearPreviewSimulators() async throws {
        try await Simctl.run(["--set", "previews", "delete", "all"])
    }
}

enum TimeZones {
    static let common = [
        "America/Los_Angeles", "America/New_York", "America/Sao_Paulo", "Europe/London", "Europe/Amsterdam",
        "Europe/Copenhagen", "Africa/Johannesburg", "Asia/Dubai", "Asia/Kolkata", "Asia/Tokyo",
        "Australia/Sydney", "Pacific/Auckland",
    ]

    static func name(_ identifier: String) -> String {
        let zone = TimeZone(identifier: identifier)
        let city = identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? identifier
        return zone.map { "\(city) (\($0.abbreviation() ?? ""))" } ?? city
    }
}
