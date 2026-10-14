import AppKit
import SwiftUI

/// The design image and grid drawn over the device screen.
@MainActor
final class OverlayModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case fade = "Fade"
        case split = "Split"

        var id: String { rawValue }
    }

    @Published var image: NSImage?
    @Published var imageName: String?
    @Published var showsImage = true
    @Published var mode = Mode.fade
    @Published var opacity = 0.5
    @Published var split = 0.5
    @Published var flipped = false
    @Published var showsGrid = false
    @Published var gridSpacing = 8.0
    @Published var gridColor = Color.pink.opacity(0.6)
    @Published var isMeasuring = false
    @Published var showsRulers = false
    /// An element to point out, in device points, for the audit and the VoiceOver navigator.
    @Published var highlight: CGRect?
    /// Where the pointer is over the device screen, in the overlay's own points, while the rulers are shown.
    @Published var pointer: CGPoint?
    @Published var zoom = 1.0
    @Published var offsetX = 0.0
    @Published var offsetY = 0.0

    var isVisible: Bool { (showsImage && image != nil) || showsGrid || isMeasuring || showsRulers || highlight != nil }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.prompt = "Overlay"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    func load(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        show(image, named: url.lastPathComponent)
    }

    /// Takes an image copied from a design tool, or an image file copied in Finder.
    func paste() {
        let pasteboard = NSPasteboard.general
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first,
           let image = NSImage(contentsOf: url) {
            show(image, named: url.lastPathComponent)
        } else if let image = NSImage(pasteboard: pasteboard) {
            show(image, named: nil)
        }
    }

    func removeImage() {
        image = nil
        imageName = nil
    }

    private func show(_ image: NSImage, named name: String?) {
        self.image = image
        imageName = name
        showsImage = true
    }
}

struct OverlayView: View {
    @ObservedObject var overlay: OverlayModel
    let pointsPerDevicePoint: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if overlay.showsImage, let image = overlay.image {
                    let design = Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(x: overlay.flipped ? -overlay.zoom : overlay.zoom, y: overlay.zoom)
                        .offset(x: overlay.offsetX * pointsPerDevicePoint, y: overlay.offsetY * pointsPerDevicePoint)
                    if overlay.mode == .fade {
                        design.opacity(overlay.opacity)
                    } else {
                        let divider = proxy.size.width * overlay.split
                        design.mask(alignment: .trailing) {
                            Rectangle().frame(width: proxy.size.width - divider)
                        }
                        Rectangle()
                            .fill(.white)
                            .frame(width: 1.5, height: proxy.size.height)
                            .shadow(radius: 2)
                            .offset(x: divider - 0.75)
                    }
                }
                if overlay.showsGrid {
                    Grid(spacing: overlay.gridSpacing * pointsPerDevicePoint)
                        .stroke(overlay.gridColor, lineWidth: 0.5)
                }
                if overlay.showsRulers {
                    Rulers(pointsPerDevicePoint: pointsPerDevicePoint, pointer: overlay.pointer)
                }
                if let highlight = overlay.highlight {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor, lineWidth: 2.5)
                        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                        .frame(width: highlight.width * pointsPerDevicePoint + 6, height: highlight.height * pointsPerDevicePoint + 6)
                        .offset(x: highlight.minX * pointsPerDevicePoint - 3, y: highlight.minY * pointsPerDevicePoint - 3)
                        .animation(.snappy(duration: 0.2), value: highlight)
                }
                if overlay.isMeasuring {
                    Measurement(pointsPerDevicePoint: pointsPerDevicePoint)
                }
            }
        }
        .clipped()
        .allowsHitTesting(overlay.isMeasuring)
    }

    /// Point rulers along the top and left edges, and a crosshair that follows the pointer with its position.
    struct Rulers: View {
        let pointsPerDevicePoint: CGFloat
        let pointer: CGPoint?

        var body: some View {
            Canvas { context, size in
                let ink = Color.yellow
                let step = 10 * pointsPerDevicePoint
                guard step >= 3 else { return }
                context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 14)), with: .color(.black.opacity(0.55)))
                context.fill(Path(CGRect(x: 0, y: 0, width: 14, height: size.height)), with: .color(.black.opacity(0.55)))
                var index = 0
                for x in stride(from: 0, through: size.width, by: step) {
                    let long = index % 5 == 0
                    context.fill(Path(CGRect(x: x, y: 0, width: 0.5, height: long ? 14 : 6)), with: .color(ink))
                    if long, index > 0 {
                        context.draw(Text("\(index * 10)").font(.system(size: 7, weight: .semibold)).foregroundColor(ink), at: CGPoint(x: x + 2, y: 9), anchor: .leading)
                    }
                    index += 1
                }
                index = 0
                for y in stride(from: 0, through: size.height, by: step) {
                    let long = index % 5 == 0
                    context.fill(Path(CGRect(x: 0, y: y, width: long ? 14 : 6, height: 0.5)), with: .color(ink))
                    if long, index > 0 {
                        context.draw(Text("\(index * 10)").font(.system(size: 7, weight: .semibold)).foregroundColor(ink), at: CGPoint(x: 8, y: y + 2), anchor: .top)
                    }
                    index += 1
                }
                guard let pointer else { return }
                context.fill(Path(CGRect(x: pointer.x, y: 0, width: 0.5, height: size.height)), with: .color(.cyan))
                context.fill(Path(CGRect(x: 0, y: pointer.y, width: size.width, height: 0.5)), with: .color(.cyan))
                let label = "\(Int((pointer.x / pointsPerDevicePoint).rounded())), \(Int((pointer.y / pointsPerDevicePoint).rounded())) pt"
                let flip = pointer.x > size.width - 90
                context.draw(
                    Text(label).font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundColor(.white),
                    at: CGPoint(x: pointer.x + (flip ? -6 : 6), y: max(pointer.y - 8, 22)),
                    anchor: flip ? .trailing : .leading
                )
            }
        }
    }

    /// Drag across the screen to see the size of what's under it, in device points.
    struct Measurement: View {
        let pointsPerDevicePoint: CGFloat
        @State private var start: CGPoint?
        @State private var end: CGPoint?

        var body: some View {
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                if let start, let end {
                    let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.18))
                        .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                    Text("\(Int((rect.width / pointsPerDevicePoint).rounded())) × \(Int((rect.height / pointsPerDevicePoint).rounded())) pt")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                        .offset(x: rect.minX, y: max(0, rect.minY - 22))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                start = drag.startLocation
                end = drag.location
            })
        }
    }

    struct Grid: Shape {
        let spacing: CGFloat

        func path(in rect: CGRect) -> Path {
            var path = Path()
            guard spacing >= 2 else { return path }
            for x in stride(from: rect.minX, through: rect.maxX, by: spacing) {
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            for y in stride(from: rect.minY, through: rect.maxY, by: spacing) {
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            return path
        }
    }
}

final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A window that sits exactly over the device screen in the Simulator. Clicks go through it, except while measuring.
@MainActor
final class OverlayWindow {
    private let window: NSPanel
    private let overlay: OverlayModel
    private let host: FirstClickHostingView<OverlayView>
    private var zoom: CGFloat = 1

    init(overlay: OverlayModel) {
        self.overlay = overlay
        host = FirstClickHostingView(rootView: OverlayView(overlay: overlay, pointsPerDevicePoint: 1))
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = host
    }

    /// `screen` uses a top-left origin. `zoom` is how many Mac points one device point takes up.
    func show(over screen: CGRect, zoom: CGFloat) {
        guard overlay.isVisible else { return hide() }
        window.ignoresMouseEvents = !overlay.isMeasuring
        if abs(self.zoom - zoom) > 0.0001 {
            self.zoom = zoom
            host.rootView = OverlayView(overlay: overlay, pointsPerDevicePoint: zoom)
        }
        let frame = SimulatorWindows.appKitFrame(screen)
        if window.frame != frame { window.setFrame(frame, display: true) }
        if !window.isVisible { window.orderFront(nil) }
    }

    func hide() {
        if window.isVisible { window.orderOut(nil) }
    }
}
