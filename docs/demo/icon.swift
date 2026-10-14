// Draws the Trails demo app's icon into the app bundle given as the first argument.
import AppKit

let bundle = URL(fileURLWithPath: CommandLine.arguments[1])
for (name, size) in [("AppIcon60x60@2x.png", 120), ("AppIcon60x60@3x.png", 180)] {
    let s = CGFloat(size)
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        CGColor(srgbRed: 0.98, green: 0.84, blue: 0.55, alpha: 1), CGColor(srgbRed: 0.42, green: 0.78, blue: 0.62, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(sky, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    context.setFillColor(CGColor(srgbRed: 1, green: 0.97, blue: 0.88, alpha: 1))
    context.fillEllipse(in: CGRect(x: s * 0.58, y: s * 0.56, width: s * 0.22, height: s * 0.22))
    func mountain(_ points: [(CGFloat, CGFloat)], _ color: CGColor) {
        context.setFillColor(color)
        context.move(to: CGPoint(x: 0, y: 0))
        for (x, y) in points { context.addLine(to: CGPoint(x: x * s, y: y * s)) }
        context.addLine(to: CGPoint(x: s, y: 0))
        context.closePath()
        context.fillPath()
    }
    mountain([(0, 0.35), (0.3, 0.62), (0.52, 0.42), (0.78, 0.66), (1, 0.4)], CGColor(srgbRed: 0.18, green: 0.55, blue: 0.42, alpha: 1))
    mountain([(0, 0.18), (0.22, 0.4), (0.45, 0.22), (0.7, 0.44), (1, 0.2)], CGColor(srgbRed: 0.08, green: 0.36, blue: 0.3, alpha: 1))
    let image = NSBitmapImageRep(cgImage: context.makeImage()!)
    try! image.representation(using: .png, properties: [:])!.write(to: bundle.appendingPathComponent(name))
}
