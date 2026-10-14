import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PanelLayout: ObservableObject {
    @Published var height: CGFloat = 300
}

struct PanelView: View {
    @ObservedObject var model: SimulatorModel
    @ObservedObject var overlay: OverlayModel
    @ObservedObject var layout: PanelLayout
    var hidePanel: () -> Void = {}
    @AppStorage("panelTab") private var tab = Tab.capture
    @State private var isDropTargeted = false

    enum Tab: String, CaseIterable, Identifiable {
        case capture = "Capture"
        case compare = "Compare"
        case app = "App Actions"
        case device = "Device Settings"
        case accessibility = "Accessibility"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .capture: "camera.aperture"
            case .compare: "square.split.2x1"
            case .app: "app.badge"
            case .device: "switch.2"
            case .accessibility: "accessibility"
            }
        }
    }

    var body: some View {
        VStack(spacing: Theme.spacing) {
            Card(padding: 4) {
                HStack(spacing: 0) {
                    IconTabs(tabs: Tab.allCases, selection: $tab, symbol: \.symbol, title: \.rawValue)
                    Spacer(minLength: 0)
                    if model.isWorking {
                        ProgressView().controlSize(.mini).padding(.trailing, 4)
                    }
                    moreMenu
                }
            }
            if model.device == nil {
                Card {
                    Label("Boot a simulator to get started.", systemImage: "iphone.slash")
                        .font(Theme.font)
                        .foregroundStyle(.secondary)
                }
            } else {
                // The old tab goes at once and the new one fades in, so the two never overlap.
                VStack(spacing: Theme.spacing) {
                    switch tab {
                    case .capture: CaptureTab(model: model, preferences: model.preferences)
                    case .compare: CompareTab(model: model, overlay: overlay)
                    case .app: AppTab(model: model, library: model.library)
                    case .device: DeviceTab(model: model)
                    case .accessibility: AccessibilityTab(model: model)
                    }
                }
                .id(tab)
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .frame(width: Theme.width)
        // Messages float over the bottom of the panel instead of making it taller for a few seconds.
        .overlay(alignment: .bottom) {
            if let message = model.message {
                MessageCard(message: message)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    .overlay(Text("Drop to send to the simulator").font(.system(size: 12, weight: .semibold)))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let fileURL = URL(dataRepresentation: url, relativeTo: nil) {
                        urls.append(fileURL)
                    }
                }
                model.handleDrop(urls)
            }
            return true
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: HeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(HeightKey.self) { height in
            MainActor.assumeIsolated { layout.height = height }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.snappy(duration: Theme.motion), value: model.message)
    }

    private var moreMenu: some View {
        Menu {
            if model.devices.count > 1 {
                Menu("Device") {
                    ForEach(model.devices) { device in
                        Button(device.title) { Task { await model.select(device.udid) } }
                    }
                }
                Divider()
            }
            Button("Network Monitor…") { model.openNetworkMonitor() }
            Button("Physical Devices…") { model.openPhysicalDevices() }
            Divider()
            Button("Settings…") { NotificationCenter.default.post(name: .openBetterSimSettings, object: nil) }
            Button("Save Captures To…") { model.preferences.chooseSaveFolder() }
            if !AccessibilityScreenFinder.isTrusted {
                Button("Allow Accessibility…") { AccessibilityScreenFinder.requestAccess() }
            }
            Divider()
            Button("Hide Panel", action: hidePanel)
            Button("Quit BetterSim") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private struct HeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
}

struct MessageCard: View {
    let message: SimulatorModel.Message

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(message.isError ? .orange : .green)
            Text(message.text).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(Theme.font)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
