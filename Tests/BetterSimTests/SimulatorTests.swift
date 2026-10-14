import CoreGraphics
import Foundation
import Testing
@testable import BetterSim

struct DeviceListTests {
    @Test func readsBootedDevicesFirstWithReadableRuntimes() throws {
        let json = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
              { "udid": "B", "name": "iPhone 17 Pro", "state": "Shutdown", "isAvailable": true,
                "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro" },
              { "udid": "A", "name": "iPhone 17 Pro Max", "state": "Booted", "isAvailable": true,
                "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max" }
            ],
            "com.apple.CoreSimulator.SimRuntime.watchOS-11-0": [
              { "udid": "C", "name": "Old Watch", "state": "Shutdown", "isAvailable": false }
            ]
          }
        }
        """
        let devices = try SimDevice.parseList(Data(json.utf8))
        #expect(devices.map(\.udid) == ["A", "B"])
        #expect(devices[0].title == "iPhone 17 Pro Max · iOS 26.5")
        #expect(devices[0].isBooted)
    }

    @Test func namesRuntimes() {
        #expect(SimDevice.runtimeName("com.apple.CoreSimulator.SimRuntime.iOS-18-3") == "iOS 18.3")
        #expect(SimDevice.runtimeName("com.apple.CoreSimulator.SimRuntime.xrOS-2-0") == "visionOS 2.0")
    }

    @Test func listsOnlyUserAppsFromTheOpenStepListing() throws {
        let listing = """
        {
            "com.apple.Bridge" = {
                ApplicationType = System;
                CFBundleDisplayName = Watch;
            };
            "com.example.zebra" = {
                ApplicationType = User;
                CFBundleName = Zebra;
                CFBundleShortVersionString = "2.1";
                DataContainer = "file:///tmp/zebra/";
            };
            "com.example.alpha" = {
                ApplicationType = User;
                CFBundleDisplayName = "Alpha App";
            };
        }
        """
        let apps = try InstalledApp.parseList(Data(listing.utf8))
        #expect(apps.map(\.name) == ["Alpha App", "Zebra"])
        #expect(apps[1].version == "2.1")
        #expect(apps[1].dataContainer?.path == "/tmp/zebra")
    }
}

struct ScreenGeometryTests {
    let profile = DeviceProfile(
        screenPixels: CGSize(width: 1206, height: 2622),
        scale: 3,
        composite: URL(filePath: "/dev/null"),
        compositeSize: CGSize(width: 436, height: 908),
        padding: EdgeInsets(top: 0, left: 9, bottom: 0, right: 9),
        cornerRadius: 80,
        buttons: []
    )

    @Test func findsTheScreenInsideTheBezel() throws {
        let window = CGRect(x: 100, y: 50, width: 454 * 0.8, height: 908 * 0.8 + 52)
        let layout = try #require(ScreenGeometry.layout(window: window, profile: profile))
        #expect(layout.showsBezel)
        #expect(abs(layout.zoom - 0.8) < 0.0001)
        #expect(abs(layout.titleBar - 52) < 0.0001)
        #expect(abs(layout.screen.minX - (100 + 26 * 0.8)) < 0.0001)
        #expect(abs(layout.screen.minY - (50 + 52 + 17 * 0.8)) < 0.0001)
        #expect(abs(layout.screen.width - 402 * 0.8) < 0.0001)
    }

    @Test func findsTheScreenWhenBezelsAreHidden() throws {
        let window = CGRect(x: 0, y: 0, width: 402 * 0.9, height: 874 * 0.9 + 28)
        let layout = try #require(ScreenGeometry.layout(window: window, profile: profile))
        #expect(!layout.showsBezel)
        #expect(abs(layout.screen.minY - 28) < 0.0001)
        #expect(abs(layout.screen.height - 874 * 0.9) < 0.0001)
    }

    @Test func handlesLandscapeWindows() throws {
        let window = CGRect(x: 0, y: 0, width: 908 * 0.5, height: 454 * 0.5 + 52)
        let layout = try #require(ScreenGeometry.layout(window: window, profile: profile))
        #expect(layout.screen.width > layout.screen.height)
        #expect(abs(layout.screen.width - 874 * 0.5) < 0.0001)
    }

    @Test func givesUpOnWindowsThatAreNotThisDevice() {
        #expect(ScreenGeometry.layout(window: CGRect(x: 0, y: 0, width: 400, height: 2000), profile: profile) == nil)
    }
}

struct FramerTests {
    @Test func framesAScreenshotWithTheSimulatorsOwnBezel() throws {
        let bundle = URL(filePath: "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone 17 Pro.simdevicetype")
        let profile = try #require(DeviceProfile.load(deviceTypeBundle: bundle), "needs Xcode's iPhone 17 Pro device type")
        let screenshot = try #require(Self.solidImage(width: Int(profile.screenPixels.width), height: Int(profile.screenPixels.height)))
        let framed = try #require(Framer.frame(screenshot, profile: profile))
        #expect(framed.width == Int((profile.deviceSize.width * 3).rounded()))
        #expect(framed.height == Int((profile.deviceSize.height * 3).rounded()))
        let pixels = try #require(Self.rgba(framed))
        let center = pixels[(framed.height / 2 * framed.width + framed.width / 2) * 4 ..< (framed.height / 2 * framed.width + framed.width / 2) * 4 + 4]
        #expect(Array(center) == [255, 0, 0, 255])
        #expect(pixels[3] == 0, "the corner outside the bezel stays transparent")

        if let sample = ProcessInfo.processInfo.environment["BETTERSIM_FRAME_SAMPLE"],
           let image = ImageFile.load(URL(filePath: sample)), let framedSample = Framer.frame(image, profile: profile) {
            try ImageFile.writePNG(framedSample, to: URL(filePath: sample).deletingPathExtension().appendingPathExtension("framed.png"))
        }
    }

    @Test func leavesScreenshotsOfOtherShapesAlone() throws {
        let bundle = URL(filePath: "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone 17 Pro.simdevicetype")
        let profile = try #require(DeviceProfile.load(deviceTypeBundle: bundle))
        let landscape = try #require(Self.solidImage(width: 2622, height: 1206))
        #expect(Framer.frame(landscape, profile: profile) == nil)
    }

    static func solidImage(width: Int, height: Int) -> CGImage? {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }

    static func rgba(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? pixels : nil
    }
}

struct BackdropTests {
    @Test func fitsTheRatioAndLeavesPlainScreenshotsAlone() throws {
        let image = try #require(FramerTests.solidImage(width: 300, height: 600))
        let plain = try #require(Backdrop.apply(Backdrop.Style(), to: image))
        #expect(plain.width == 300 && plain.height == 600)
        let square = try #require(Backdrop.apply(Backdrop.Style(background: .gradient, ratio: .square), to: image))
        #expect(square.width == square.height)
        let titled = try #require(Backdrop.apply(Backdrop.Style(background: .white, ratio: .portrait, title: "Hello"), to: image))
        #expect(abs(Double(titled.width) / Double(titled.height) - 9.0 / 16) < 0.01)

        if let sample = ProcessInfo.processInfo.environment["BETTERSIM_STYLE_SAMPLE"], let framed = ImageFile.load(URL(filePath: sample)) {
            let styled = try #require(Backdrop.apply(Backdrop.Style(background: .gradient, ratio: .portrait, title: "Find your next table"), to: framed))
            try ImageFile.writePNG(styled, to: URL(filePath: sample).deletingPathExtension().appendingPathExtension("styled.png"))
        }
    }
}
