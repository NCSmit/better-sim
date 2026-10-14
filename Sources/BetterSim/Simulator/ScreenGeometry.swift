import CoreGraphics

/// Works out where the device screen is inside a Simulator window, from the window's frame alone.
///
/// The Simulator scales the device art (the bezel when "Show Device Bezels" is on, otherwise just the screen) to the
/// window's width and puts its title bar above it. So the zoom comes from the width, and whatever height is left over
/// is title bar. Of the two layouts, the one that leaves a believable title bar wins.
enum ScreenGeometry {
    static let titleBarRange: ClosedRange<CGFloat> = 0...90
    static let typicalTitleBar: CGFloat = 52

    struct Layout: Equatable {
        let screen: CGRect
        let zoom: CGFloat
        let titleBar: CGFloat
        let showsBezel: Bool
    }

    /// `window` and the result use a top-left origin, like CGWindowList.
    static func layout(window: CGRect, profile: DeviceProfile) -> Layout? {
        let landscape = window.width > window.height
        var candidates = [bareLayout(window: window, profile: profile, landscape: landscape)]
        if profile.hasChrome {
            candidates.append(bezelLayout(window: window, profile: profile, landscape: landscape))
        }
        return candidates
            .filter { titleBarRange.contains($0.titleBar) }
            .min { abs($0.titleBar - typicalTitleBar) < abs($1.titleBar - typicalTitleBar) }
    }

    private static func bareLayout(window: CGRect, profile: DeviceProfile, landscape: Bool) -> Layout {
        let screen = rotated(profile.screenPoints, landscape)
        return fit(window: window, art: screen, screenOrigin: .zero, screen: screen, showsBezel: false)
    }

    private static func bezelLayout(window: CGRect, profile: DeviceProfile, landscape: Bool) -> Layout {
        let inset = profile.screenInset
        let origin = landscape
            ? CGPoint(x: profile.padding.top + inset.height, y: profile.padding.left + inset.width)
            : CGPoint(x: profile.padding.left + inset.width, y: profile.padding.top + inset.height)
        return fit(
            window: window,
            art: rotated(profile.deviceSize, landscape),
            screenOrigin: origin,
            screen: rotated(profile.screenPoints, landscape),
            showsBezel: true
        )
    }

    private static func fit(window: CGRect, art: CGSize, screenOrigin: CGPoint, screen: CGSize, showsBezel: Bool) -> Layout {
        let zoom = window.width / art.width
        let titleBar = window.height - art.height * zoom
        return Layout(
            screen: CGRect(
                x: window.minX + screenOrigin.x * zoom,
                y: window.minY + titleBar + screenOrigin.y * zoom,
                width: screen.width * zoom,
                height: screen.height * zoom
            ),
            zoom: zoom,
            titleBar: titleBar,
            showsBezel: showsBezel
        )
    }

    private static func rotated(_ size: CGSize, _ landscape: Bool) -> CGSize {
        landscape ? CGSize(width: size.height, height: size.width) : size
    }
}
