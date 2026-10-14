import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Puts a screenshot inside the device bezel that Xcode's Simulator draws, read from the DeviceKit files on this Mac.
enum Framer {
    static func frame(_ screenshot: CGImage, profile: DeviceProfile) -> CGImage? {
        guard let composite = profile.composite else { return nil }
        let pixels = CGSize(width: screenshot.width, height: screenshot.height)
        guard abs(pixels.width / pixels.height - profile.screenPoints.width / profile.screenPoints.height) < 0.01 else {
            return nil
        }
        let scale = pixels.width / profile.screenPoints.width
        let size = profile.deviceSize
        guard let context = CGContext(
            data: nil,
            width: Int((size.width * scale).rounded()),
            height: Int((size.height * scale).rounded()),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        // Lay things out top-down, the way the chrome files describe them.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)

        let body = CGRect(origin: CGPoint(x: profile.padding.left, y: profile.padding.top), size: profile.compositeSize)
        for button in profile.buttons where !button.onTop {
            drawUpright(button.image, in: rect(for: button, around: body), context: context)
        }
        drawUpright(composite, in: body, context: context)
        let inset = profile.screenInset
        let screen = CGRect(origin: CGPoint(x: body.minX + inset.width, y: body.minY + inset.height), size: profile.screenPoints)
        context.saveGState()
        context.translateBy(x: screen.minX, y: screen.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(screenshot, in: CGRect(origin: .zero, size: screen.size))
        context.restoreGState()
        for button in profile.buttons where button.onTop {
            drawUpright(button.image, in: rect(for: button, around: body), context: context)
        }
        return context.makeImage()
    }

    static func rect(for button: ChromeButton, around body: CGRect) -> CGRect {
        let size = PDFArt.size(of: button.image) ?? .zero
        switch button.anchor {
        case "right":
            return CGRect(x: body.maxX + button.offset.x, y: body.minY + button.offset.y, width: size.width, height: size.height)
        case "top":
            let x = button.offset.x < 0 ? body.maxX + button.offset.x - size.width : body.minX + button.offset.x
            return CGRect(x: x, y: body.minY + button.offset.y - size.height, width: size.width, height: size.height)
        case "bottom":
            let x = button.offset.x < 0 ? body.maxX + button.offset.x - size.width : body.minX + button.offset.x
            return CGRect(x: x, y: body.maxY + button.offset.y, width: size.width, height: size.height)
        default:
            return CGRect(x: body.minX + button.offset.x - size.width, y: body.minY + button.offset.y, width: size.width, height: size.height)
        }
    }

    private static func drawUpright(_ pdf: URL, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        PDFArt.draw(pdf, in: context, rect: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}

enum Backdrop {
    struct Style: Equatable {
        var background = ScreenshotBackground.none
        var ratio = ScreenshotRatio.automatic
        var title = ""

        var isPlain: Bool { background == .none && ratio == .automatic && title.isEmpty }
    }

    /// Puts a framed screenshot on a background with a soft shadow, at an aspect ratio and with an optional title,
    /// ready for slides and store pages.
    static func apply(_ style: Style, to image: CGImage) -> CGImage? {
        guard !style.isPlain else { return image }
        let device = CGSize(width: image.width, height: image.height)
        let padding = (device.width * 0.14).rounded()
        let titleSize = (device.width * 0.075).rounded()
        let titleHeight = style.title.isEmpty ? 0 : (titleSize * 2.6).rounded()
        var size = CGSize(width: device.width + padding * 2, height: device.height + padding * 2 + titleHeight)
        if let ratio = style.ratio.value {
            if size.width / size.height < ratio {
                size.width = (size.height * ratio).rounded()
            } else {
                size.height = (size.width / ratio).rounded()
            }
        }
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        fill(style.background, in: CGRect(origin: .zero, size: size), context: context)
        let contentHeight = device.height + titleHeight
        let deviceOrigin = CGPoint(x: ((size.width - device.width) / 2).rounded(), y: ((size.height - contentHeight) / 2).rounded())
        if !style.title.isEmpty {
            let titleBox = CGRect(x: padding / 2, y: deviceOrigin.y + device.height, width: size.width - padding, height: titleHeight)
            draw(style.title, in: titleBox, size: titleSize, dark: style.background == .white || style.background == .none, context: context)
        }
        if style.background != .none {
            context.setShadow(offset: CGSize(width: 0, height: -padding * 0.12), blur: padding * 0.45, color: CGColor(gray: 0, alpha: 0.4))
        }
        context.draw(image, in: CGRect(origin: deviceOrigin, size: device))
        return context.makeImage()
    }

    private static func fill(_ background: ScreenshotBackground, in bounds: CGRect, context: CGContext) {
        switch background {
        case .white:
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds)
        case .black:
            context.setFillColor(CGColor(gray: 0.04, alpha: 1))
            context.fill(bounds)
        case .gradient:
            let colors = [CGColor(srgbRed: 0.36, green: 0.27, blue: 0.95, alpha: 1), CGColor(srgbRed: 0.05, green: 0.6, blue: 0.95, alpha: 1)]
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: bounds.height), end: CGPoint(x: bounds.width, y: 0), options: [])
            }
        case .none:
            break
        }
    }

    private static func draw(_ title: String, in box: CGRect, size: CGFloat, dark: Bool, context: CGContext) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: dark ? NSColor(white: 0.08, alpha: 1) : NSColor.white,
            .paragraphStyle: paragraph,
        ])
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let height = text.boundingRect(with: CGSize(width: box.width, height: box.height), options: [.usesLineFragmentOrigin]).height
        text.draw(with: CGRect(x: box.minX, y: box.midY - height / 2, width: box.width, height: height), options: [.usesLineFragmentOrigin])
        NSGraphicsContext.current = previous
    }
}

enum ImageFile {
    /// Decodes straight away, because callers often delete the file as soon as it's loaded.
    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    static func removingAlpha(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
