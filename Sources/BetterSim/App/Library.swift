import AppKit
import Foundation
import os

private let log = Logger(subsystem: "local.bettersim", category: "library")

/// Deep links and push payloads the user saved, kept as JSON in Application Support.
@MainActor
final class Library: ObservableObject {
    struct Contents: Codable, Equatable {
        var deepLinks: [String: [String]] = [:]
        var payloads: [String: String] = [:]
    }

    @Published private(set) var contents: Contents
    let file: URL

    init(file: URL = Library.defaultFile) {
        self.file = file
        contents = (try? JSONDecoder().decode(Contents.self, from: Data(contentsOf: file))) ?? Contents()
    }

    static var defaultFile: URL {
        URL.applicationSupportDirectory.appending(path: "BetterSim/library.json")
    }

    func deepLinks(for bundleID: String) -> [String] {
        contents.deepLinks[bundleID] ?? []
    }

    func remember(_ link: String, for bundleID: String) {
        var links = deepLinks(for: bundleID).filter { $0 != link }
        links.insert(link, at: 0)
        contents.deepLinks[bundleID] = Array(links.prefix(20))
        save()
    }

    func forget(_ link: String, for bundleID: String) {
        contents.deepLinks[bundleID] = deepLinks(for: bundleID).filter { $0 != link }
        save()
    }

    func payload(for bundleID: String) -> String? {
        contents.payloads[bundleID]
    }

    func remember(payload: String, for bundleID: String) {
        guard contents.payloads[bundleID] != payload else { return }
        contents.payloads[bundleID] = payload
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(contents).write(to: file, options: .atomic)
        } catch {
            log.error("could not save the library: \(error.localizedDescription)")
        }
    }
}

enum ScreenshotBackground: String, CaseIterable, Identifiable {
    case none = "None"
    case white = "White"
    case black = "Black"
    case gradient = "Gradient"

    var id: String { rawValue }
}

enum ScreenshotRatio: String, CaseIterable, Identifiable {
    case automatic = "Auto"
    case square = "1:1"
    case fourThree = "4:3"
    case threeTwo = "3:2"
    case sixteenNine = "16:9"
    case portrait = "9:16"

    var id: String { rawValue }

    var value: CGFloat? {
        switch self {
        case .automatic: nil
        case .square: 1
        case .fourThree: 4.0 / 3
        case .threeTwo: 3.0 / 2
        case .sixteenNine: 16.0 / 9
        case .portrait: 9.0 / 16
        }
    }
}

enum PanelSide: String, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case right = "Right"
    case left = "Left"

    var id: String { rawValue }
}

@MainActor
final class Preferences: ObservableObject {
    @Published var framesScreenshots: Bool { didSet { defaults.set(framesScreenshots, forKey: "framesScreenshots") } }
    @Published var copiesCaptures: Bool { didSet { defaults.set(copiesCaptures, forKey: "copiesCaptures") } }
    @Published var gifWidth: Double { didSet { defaults.set(gifWidth, forKey: "gifWidth") } }
    @Published var showsTouches: Bool { didSet { defaults.set(showsTouches, forKey: "showsTouches") } }
    @Published var showsThumbnail: Bool { didSet { defaults.set(showsThumbnail, forKey: "showsThumbnail") } }
    @Published var background: ScreenshotBackground {
        didSet { defaults.set(background.rawValue, forKey: "screenshotBackground") }
    }
    @Published var panelSide: PanelSide { didSet { defaults.set(panelSide.rawValue, forKey: "panelSide") } }
    @Published var ratio: ScreenshotRatio { didSet { defaults.set(ratio.rawValue, forKey: "screenshotRatio") } }
    @Published var trimsRecordings: Bool { didSet { defaults.set(trimsRecordings, forKey: "trimsRecordings") } }
    @Published var appStoreMode: Bool { didSet { defaults.set(appStoreMode, forKey: "appStoreMode") } }
    @Published var highFrameRate: Bool { didSet { defaults.set(highFrameRate, forKey: "highFrameRate") } }
    @Published var screenshotTitle: String { didSet { defaults.set(screenshotTitle, forKey: "screenshotTitle") } }

    var backdrop: Backdrop.Style {
        Backdrop.Style(background: background, ratio: ratio, title: screenshotTitle.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    @Published private(set) var saveFolder: URL

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        framesScreenshots = defaults.object(forKey: "framesScreenshots") as? Bool ?? true
        copiesCaptures = defaults.object(forKey: "copiesCaptures") as? Bool ?? true
        gifWidth = defaults.object(forKey: "gifWidth") as? Double ?? 480
        showsTouches = defaults.object(forKey: "showsTouches") as? Bool ?? true
        showsThumbnail = defaults.object(forKey: "showsThumbnail") as? Bool ?? true
        background = defaults.string(forKey: "screenshotBackground").flatMap(ScreenshotBackground.init) ?? .none
        panelSide = defaults.string(forKey: "panelSide").flatMap(PanelSide.init) ?? .automatic
        ratio = defaults.string(forKey: "screenshotRatio").flatMap(ScreenshotRatio.init) ?? .automatic
        trimsRecordings = defaults.object(forKey: "trimsRecordings") as? Bool ?? false
        appStoreMode = defaults.object(forKey: "appStoreMode") as? Bool ?? false
        highFrameRate = defaults.object(forKey: "highFrameRate") as? Bool ?? false
        screenshotTitle = defaults.string(forKey: "screenshotTitle") ?? ""
        saveFolder = defaults.string(forKey: "saveFolder").map { URL(filePath: $0) } ?? URL.desktopDirectory
    }

    func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveFolder
        panel.prompt = "Save Here"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveFolder = url
        defaults.set(url.path, forKey: "saveFolder")
    }
}
