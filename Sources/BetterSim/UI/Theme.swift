import AppKit
import SwiftUI

enum Theme {
    static let width: CGFloat = 280
    static let cardRadius: CGFloat = 14
    static let cardPadding: CGFloat = 12
    static let spacing: CGFloat = 10
    static let font = Font.system(size: 12)
    static let smallFont = Font.system(size: 11, weight: .semibold)
    static let noteFont = Font.system(size: 11)
    /// How long the panel takes to grow, shrink or fade.
    static let motion: TimeInterval = 0.2
    /// The frosted material on its own barely darkens what's behind it. With this on top, the cards show the desktop
    /// at about 60% brightness, like RocketSim's side window.
    static let cardShade = Color.black.opacity(0.4)
}

extension EnvironmentValues {
    /// Images drawn off screen can't blur what's behind the window, so they turn this off and let the shade darken
    /// whatever the panel is drawn over.
    @Entry var blursBehindPanel = true
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// The dark frosted surface of the panel's cards and BetterSim's own windows.
struct PanelSurface: View {
    @Environment(\.blursBehindPanel) private var blursBehind

    var body: some View {
        ZStack {
            if blursBehind { VisualEffect() }
            Theme.cardShade
        }
    }
}

/// One floating, frosted card of the side panel.
struct Card<Content: View>: View {
    var padding = Theme.cardPadding
    var spacing = Theme.spacing
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PanelSurface())
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 1)
            )
    }
}

/// A label on the left and its control on the right.
struct Row<Control: View>: View {
    let label: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 8) {
            Text(label).lineLimit(1)
            Spacer(minLength: 4)
            control
        }
        .font(Theme.font)
        .frame(minHeight: 26)
    }
}

struct SwitchRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Row(label: label) {
            Toggle(label, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(PanelSwitchStyle())
        }
    }
}

struct CardHeader: View {
    let text: String

    var body: some View {
        Text(text).font(Theme.smallFont).foregroundStyle(.secondary)
    }
}

/// A short explanation under a control.
struct Note: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text).font(Theme.noteFont).foregroundStyle(tint).fixedSize(horizontal: false, vertical: true)
    }
}

struct CardDivider: View {
    var body: some View {
        Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.horizontal, -Theme.cardPadding)
    }
}

struct PillButtonStyle: ButtonStyle {
    var isOn = false
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .foregroundStyle(isOn ? .white : .primary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isOn ? tint : Color.white.opacity(configuration.isPressed ? 0.16 : 0.08))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct Pill: View {
    let title: String
    var symbol: String?
    var isOn = false
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
        }
        .buttonStyle(PillButtonStyle(isOn: isOn, tint: tint))
    }
}

/// A row of icon buttons where one is selected, marked in the accent colour with a short bar underneath.
struct IconTabs<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let symbol: (Tab) -> String
    let title: (Tab) -> String
    @Namespace private var marker

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                Button {
                    withAnimation(.snappy(duration: Theme.motion)) { selection = tab }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: symbol(tab))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(selection == tab ? Color.accentColor : .secondary)
                            .frame(height: 17)
                        ZStack {
                            if selection == tab {
                                Capsule().fill(Color.accentColor).matchedGeometryEffect(id: "marker", in: marker)
                            }
                        }
                        .frame(width: 16, height: 2)
                    }
                    .frame(width: 40, height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(title(tab))
            }
        }
    }
}

struct CompactMenu<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Text(title).font(Theme.font)
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
    }
}

/// The panel never becomes the active window, so system switches and sliders would stay grey. These stay blue.
struct PanelSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Track(isOn: configuration.isOn) { configuration.isOn.toggle() }
    }

    private struct Track: View {
        let isOn: Bool
        let toggle: () -> Void
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            Button(action: toggle) {
                Capsule()
                    .fill(isOn ? Color.accentColor : Color.white.opacity(0.18))
                    .frame(width: 28, height: 16)
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    }
                    .animation(.snappy(duration: 0.15), value: isOn)
            }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

struct PanelSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double?

    var body: some View {
        GeometryReader { proxy in
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? min(max((value - range.lowerBound) / span, 0), 1) : 0
            let knob: CGFloat = 14
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15)).frame(height: 4)
                Capsule().fill(Color.accentColor).frame(width: max(4, knob / 2 + (proxy.size.width - knob) * fraction), height: 4)
                if let step, span / step <= 20 {
                    HStack(spacing: 0) {
                        ForEach(0...Int((span / step).rounded()), id: \.self) { index in
                            if index > 0 { Spacer(minLength: 0) }
                            Circle().fill(.white.opacity(0.35)).frame(width: 2, height: 2)
                        }
                    }
                    .padding(.horizontal, knob / 2 - 1)
                }
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .offset(x: (proxy.size.width - knob) * fraction)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let position = min(max((drag.location.x - knob / 2) / max(proxy.size.width - knob, 1), 0), 1)
                var newValue = range.lowerBound + span * position
                if let step { newValue = range.lowerBound + ((newValue - range.lowerBound) / step).rounded() * step }
                if newValue != value { value = newValue }
            })
        }
        .frame(height: 18)
    }
}

/// A small segmented control drawn with the panel's own colours.
struct Segments<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button {
                    withAnimation(.snappy(duration: Theme.motion)) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .foregroundStyle(selection == option.value ? .white : .secondary)
                        .background {
                            if selection == option.value {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.accentColor)
                                    .matchedGeometryEffect(id: "highlight", in: highlight)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.08)))
    }
}
