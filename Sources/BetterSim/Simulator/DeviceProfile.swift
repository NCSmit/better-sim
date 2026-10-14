import CoreGraphics
import Foundation

struct EdgeInsets: Hashable, Sendable {
    var top: CGFloat = 0
    var left: CGFloat = 0
    var bottom: CGFloat = 0
    var right: CGFloat = 0
}

struct ChromeButton: Hashable, Sendable {
    let image: URL
    let anchor: String
    let offset: CGPoint
    let onTop: Bool
}

/// What the Simulator draws for a device type: the screen size, and the bezel ("chrome") Xcode ships in DeviceKit.
struct DeviceProfile: Hashable, Sendable {
    let screenPixels: CGSize
    let scale: CGFloat
    let composite: URL?
    let compositeSize: CGSize
    let padding: EdgeInsets
    let cornerRadius: CGFloat
    let buttons: [ChromeButton]

    static let chromeFolder = URL(filePath: "/Library/Developer/DeviceKit/Chrome")

    var screenPoints: CGSize { CGSize(width: screenPixels.width / scale, height: screenPixels.height / scale) }
    var hasChrome: Bool { composite != nil }

    /// Where the screen sits inside the composite bezel image, in points.
    var screenInset: CGSize {
        guard hasChrome else { return .zero }
        return CGSize(
            width: (compositeSize.width - screenPoints.width) / 2,
            height: (compositeSize.height - screenPoints.height) / 2
        )
    }

    /// The size of everything the Simulator draws for the device: the bezel plus room for the side buttons.
    var deviceSize: CGSize {
        guard hasChrome else { return screenPoints }
        return CGSize(
            width: compositeSize.width + padding.left + padding.right,
            height: compositeSize.height + padding.top + padding.bottom
        )
    }

    static func load(deviceTypeBundle: URL) -> DeviceProfile? {
        let profileURL = deviceTypeBundle.appending(path: "Contents/Resources/profile.plist")
        guard let data = try? Data(contentsOf: profileURL),
              let profile = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let width = (profile["mainScreenWidth"] as? NSNumber)?.doubleValue,
              let height = (profile["mainScreenHeight"] as? NSNumber)?.doubleValue,
              let scale = (profile["mainScreenScale"] as? NSNumber)?.doubleValue, scale > 0
        else { return nil }
        let screen = CGSize(width: width, height: height)
        let chromeID = (profile["chromeIdentifier"] as? String)?.split(separator: ".").last.map(String.init)
        let chrome = chromeID.flatMap { loadChrome(chromeFolder.appending(path: "\($0).devicechrome/Contents/Resources")) }
        return DeviceProfile(
            screenPixels: screen,
            scale: scale,
            composite: chrome?.composite,
            compositeSize: chrome?.size ?? CGSize(width: width / scale, height: height / scale),
            padding: chrome?.padding ?? EdgeInsets(),
            cornerRadius: chrome?.cornerRadius ?? 0,
            buttons: chrome?.buttons ?? []
        )
    }

    private struct Chrome {
        let composite: URL
        let size: CGSize
        let padding: EdgeInsets
        let cornerRadius: CGFloat
        let buttons: [ChromeButton]
    }

    private static func loadChrome(_ folder: URL) -> Chrome? {
        guard let data = try? Data(contentsOf: folder.appending(path: "chrome.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = json["images"] as? [String: Any],
              let compositeName = images["composite"] as? String
        else { return nil }
        let composite = folder.appending(path: "\(compositeName).pdf")
        guard let size = PDFArt.size(of: composite) else { return nil }
        let padding = images["devicePadding"] as? [String: Any] ?? [:]
        let border = (json["paths"] as? [String: Any])?["simpleOutsideBorder"] as? [String: Any]
        let buttons = (json["inputs"] as? [[String: Any]] ?? []).compactMap { input -> ChromeButton? in
            guard let image = input["image"] as? String,
                  let offsets = (input["offsets"] as? [String: Any])?["normal"] as? [String: Any]
            else { return nil }
            return ChromeButton(
                image: folder.appending(path: "\(image).pdf"),
                anchor: input["anchor"] as? String ?? "left",
                offset: CGPoint(x: number(offsets["x"]), y: number(offsets["y"])),
                onTop: input["onTop"] as? Bool ?? false
            )
        }
        return Chrome(
            composite: composite,
            size: size,
            padding: EdgeInsets(
                top: number(padding["top"]),
                left: number(padding["left"]),
                bottom: number(padding["bottom"]),
                right: number(padding["right"])
            ),
            cornerRadius: number(border?["cornerRadiusX"]),
            buttons: buttons
        )
    }

    private static func number(_ value: Any?) -> CGFloat {
        CGFloat((value as? NSNumber)?.doubleValue ?? 0)
    }
}

enum DeviceTypes {
    static func bundles() async throws -> [String: URL] {
        struct List: Decodable {
            struct DeviceType: Decodable {
                let identifier: String
                let bundlePath: String
            }
            let devicetypes: [DeviceType]
        }
        let list = try JSONDecoder().decode(List.self, from: try await Simctl.run(["list", "devicetypes", "--json"]))
        return Dictionary(list.devicetypes.map { ($0.identifier, URL(filePath: $0.bundlePath)) }) { first, _ in first }
    }
}

enum PDFArt {
    static func size(of url: URL) -> CGSize? {
        guard let page = CGPDFDocument(url as CFURL)?.page(at: 1) else { return nil }
        return page.getBoxRect(.mediaBox).size
    }

    static func draw(_ url: URL, in context: CGContext, rect: CGRect) {
        guard let page = CGPDFDocument(url as CFURL)?.page(at: 1) else { return }
        let box = page.getBoxRect(.mediaBox)
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / box.width, y: rect.height / box.height)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        context.restoreGState()
    }
}
