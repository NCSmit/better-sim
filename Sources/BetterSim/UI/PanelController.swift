import AppKit
import SwiftUI
import os

private let log = Logger(subsystem: "local.bettersim", category: "panel")

final class SidePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Keeps the side panel docked next to the Simulator's frontmost window, and the overlay over its screen.
@MainActor
final class PanelController {
    static let gap: CGFloat = 10

    let panel: SidePanel
    private let model: SimulatorModel
    private let overlayModel: OverlayModel
    private let overlay: OverlayWindow
    private let layout = PanelLayout()
    private var timer: Timer?
    private var tracked: SimulatorWindow?
    private var ticks = 0
    private var accessibilityScreen: (window: CGRect, screen: CGRect)?
    private var isTrusted = AccessibilityScreenFinder.isTrusted
    private var lastProbe = Date.distantPast
    private var dockLeft = false
    private var sideVotes = 0
    private var placed: NSRect?
    private var visibility = Visibility.hidden
    private var hiddenSince: Date?
    private(set) var currentScreen: CGRect?

    private enum Visibility { case hidden, fadingIn, shown, fadingOut }
    var isPinnedOpen = true { didSet { tick() } }

    init(model: SimulatorModel, overlayModel: OverlayModel) {
        self.model = model
        self.overlayModel = overlayModel
        overlay = OverlayWindow(overlay: overlayModel)
        panel = SidePanel(
            contentRect: NSRect(x: 0, y: 0, width: Theme.width, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        let root = PanelView(model: model, overlay: overlayModel, layout: layout) { [weak self] in
            self?.isPinnedOpen = false
        }
        panel.contentView = FirstClickHostingView(rootView: root)
        model.screenRect = { [weak self] in self?.currentScreen }
        model.simulatorWindow = { [weak self] in self?.tracked }
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// The Simulator window the panel is docked to, with a top-left origin.
    var simulatorWindow: CGRect? { tracked?.frame }

    private var shouldShow: Bool {
        guard isPinnedOpen else { return false }
        return SimulatorWindows.isFrontmost || NSApp.isActive || panel.isKeyWindow || model.recordingKind != nil
    }

    func tick() {
        guard shouldShow else {
            hide()
            return
        }
        ticks += 1
        if ticks % 120 == 0 { isTrusted = AccessibilityScreenFinder.isTrusted }
        // A full window scan finds the frontmost device window; between scans the tracked one is cheap to follow.
        if tracked == nil || ticks % 15 == 0 {
            let frontmost = SimulatorWindows.windows().first
            if frontmost?.id != tracked?.id {
                tracked = frontmost
                Task { await model.followSimulator() }
            } else {
                tracked = frontmost
            }
            if let frame = tracked?.frame { updateSide(for: frame) }
        } else if let current = tracked, let frame = Self.frame(of: current.id) {
            tracked = SimulatorWindow(id: current.id, frame: frame)
        } else {
            tracked = nil
        }
        guard let window = tracked else {
            currentScreen = nil
            hide()
            return
        }
        place(next: window.frame)
        placeOverlay(over: window.frame)
    }

    /// Waits a moment before fading out, so the panel doesn't blink while focus passes between the Simulator,
    /// the panel and its menus.
    private func hide() {
        guard visibility == .shown || visibility == .fadingIn else { return }
        let since = hiddenSince ?? .now
        hiddenSince = since
        guard Date.now.timeIntervalSince(since) > 0.25 else { return }
        visibility = .fadingOut
        overlay.hide()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.motion * 0.6
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibility == .fadingOut else { return }
                self.panel.orderOut(nil)
                self.visibility = .hidden
            }
        }
    }

    private func show() {
        hiddenSince = nil
        guard visibility == .hidden || visibility == .fadingOut else { return }
        if visibility == .hidden {
            panel.alphaValue = 0
            panel.orderFront(nil)
        }
        visibility = .fadingIn
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.motion * 0.75
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibility == .fadingIn else { return }
                self.visibility = .shown
            }
        }
    }

    private func place(next window: CGRect) {
        let simulator = SimulatorWindows.appKitFrame(window)
        let screen = NSScreen.screens.first { $0.frame.intersects(simulator) }?.visibleFrame ?? simulator
        let height = min(layout.height.rounded(.up), screen.height)
        let right = simulator.maxX + Self.gap
        let left = simulator.minX - Self.gap - Theme.width
        let x = dockLeft ? left : right
        let top = min(simulator.maxY, screen.maxY)
        let frame = NSRect(x: x, y: max(screen.minY, top - height), width: Theme.width, height: height)
        if frame != placed {
            let previous = placed
            placed = frame
            // When only the height changes, as it does between tabs, grow or shrink smoothly from the top.
            if let previous, visibility != .hidden, previous.minX == frame.minX, previous.maxY == frame.maxY {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Theme.motion
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().setFrame(frame, display: true)
                } completionHandler: { [weak self] in
                    MainActor.assumeIsolated { self?.panel.invalidateShadow() }
                }
            } else {
                panel.setFrame(frame, display: true)
                panel.invalidateShadow()
            }
        }
        show()
    }

    /// Changes sides only once the same answer has come back a few scans in a row, so a tool's panel fading in and
    /// out next to the Simulator doesn't make this one jump back and forth.
    private func updateSide(for window: CGRect) {
        let left = shouldDockLeft(of: window)
        guard left != dockLeft else { return sideVotes = 0 }
        sideVotes += 1
        if placed == nil || sideVotes >= 3 {
            dockLeft = left
            sideVotes = 0
        }
    }

    /// Docks on the right unless the setting says otherwise, there's no room, or another tool's floating panel is there.
    private func shouldDockLeft(of window: CGRect) -> Bool {
        let simulator = SimulatorWindows.appKitFrame(window)
        let screen = NSScreen.screens.first { $0.frame.intersects(simulator) }?.visibleFrame ?? simulator
        let fitsRight = simulator.maxX + Self.gap + Theme.width <= screen.maxX
        let fitsLeft = simulator.minX - Self.gap - Theme.width >= screen.minX
        switch model.preferences.panelSide {
        case .right: return false
        case .left: return true
        case .automatic:
            if !fitsRight { return fitsLeft }
            let rightSide = CGRect(x: window.maxX + Self.gap, y: window.minY, width: Theme.width, height: window.height)
            return fitsLeft && Self.otherPanelOverlaps(rightSide)
        }
    }

    private static func otherPanelOverlaps(_ rect: CGRect) -> Bool {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return info.contains { window in
            // Hidden panels count too: they come back each time the Simulator is in front.
            guard let layer = window[kCGWindowLayer as String] as? Int, (1...20).contains(layer),
                  window[kCGWindowOwnerPID as String] as? pid_t != ownPID,
                  let bounds = window[kCGWindowBounds as String],
                  let frame = CGRect(dictionaryRepresentation: bounds as! CFDictionary),
                  frame.width < 600
            else { return false }
            return frame.intersects(rect)
        }
    }

    private func placeOverlay(over window: CGRect) {
        guard let profile = model.profile else {
            currentScreen = nil
            return overlay.hide()
        }
        let exact = exactScreen(in: window, profile: profile)
        currentScreen = exact ?? ScreenGeometry.layout(window: window, profile: profile)?.screen
        guard overlayModel.isVisible, let screen = currentScreen else { return overlay.hide() }
        if overlayModel.showsRulers { trackPointer(over: screen) }
        let long = max(profile.screenPoints.width, profile.screenPoints.height)
        let zoom = screen.width / (screen.width > screen.height ? long : profile.screenPoints.width)
        overlay.show(over: screen, zoom: zoom)
    }

    private func trackPointer(over screen: CGRect) {
        let mouse = NSEvent.mouseLocation
        let top = (NSScreen.screens.first?.frame.height ?? 0) - mouse.y
        let point = CGPoint(x: mouse.x - screen.minX, y: top - screen.minY)
        let inside = point.x >= 0 && point.y >= 0 && point.x <= screen.width && point.y <= screen.height
        let pointer = inside ? point : nil
        if pointer != overlayModel.pointer { overlayModel.pointer = pointer }
    }

    /// Asks the accessibility tree once per window size, and at most twice a second while a window is resized,
    /// because walking the tree is too slow to do on every frame.
    private func exactScreen(in window: CGRect, profile: DeviceProfile) -> CGRect? {
        guard isTrusted, let pid = SimulatorWindows.app?.processIdentifier else { return nil }
        if let cached = accessibilityScreen, cached.window.size == window.size {
            return cached.screen.offsetBy(dx: window.minX - cached.window.minX, dy: window.minY - cached.window.minY)
        }
        guard Date.now.timeIntervalSince(lastProbe) > 0.5 else { return nil }
        lastProbe = .now
        guard let screen = AccessibilityScreenFinder.screenFrame(in: window, aspect: profile.screenPoints, pid: pid) else {
            return nil
        }
        accessibilityScreen = (window, screen)
        if let estimate = ScreenGeometry.layout(window: window, profile: profile) {
            log.info("screen estimate \(estimate.screen.debugDescription) title bar \(estimate.titleBar) vs accessibility \(screen.debugDescription)")
        }
        return screen
    }

    private static func frame(of id: CGWindowID) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let bounds = info.first?[kCGWindowBounds as String],
              info.first?[kCGWindowIsOnscreen as String] as? Bool == true
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds as! CFDictionary)
    }
}
