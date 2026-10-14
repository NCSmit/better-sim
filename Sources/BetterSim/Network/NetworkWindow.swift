import AppKit
import SwiftUI

/// Lists the requests of apps relaunched with network monitoring.
@MainActor
final class NetworkWindow {
    private var window: NSWindow?
    private let monitor: NetworkMonitor

    init(monitor: NetworkMonitor) {
        self.monitor = monitor
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Network"
            window.titlebarAppearsTransparent = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: NetworkView(monitor: monitor))
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("BetterSimNetwork")
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct NetworkView: View {
    @ObservedObject var monitor: NetworkMonitor
    @State private var filter = ""
    @State private var selection: NetworkEvent.ID?

    var body: some View {
        let events = monitor.events.filter { $0.matches(filter) }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                FilterField(text: $filter)
                Text(events.count == monitor.events.count ? count(events.count) : "\(events.count) of \(count(monitor.events.count))")
                    .font(Theme.font)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Pill(title: "Clear", symbol: "trash") {
                    monitor.clear()
                    selection = nil
                }
                .fixedSize()
                .disabled(monitor.events.isEmpty)
                .opacity(monitor.events.isEmpty ? 0.45 : 1)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            HSplitView {
                List(events, selection: $selection) { event in
                    RequestRow(event: event)
                        .contextMenu {
                            Button("Copy as cURL") { NetworkPasteboard.copy(event.curlCommand) }
                            Button("Copy URL") { NetworkPasteboard.copy(event.url) }
                        }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(minWidth: 280, idealWidth: 400, maxWidth: 640)
                Group {
                    if let event = monitor.events.first(where: { $0.id == selection }) {
                        RequestDetail(event: event).equatable().id(event.id)
                    } else {
                        placeholder
                    }
                }
                .frame(minWidth: 340, idealWidth: 580, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 680, minHeight: 380)
        .background(VisualEffect().ignoresSafeArea())
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "network").font(.system(size: 26)).foregroundStyle(.secondary)
            Text(monitor.events.isEmpty ? "No requests yet" : "Select a request").font(.system(size: 13, weight: .semibold))
            if monitor.events.isEmpty {
                Text("Relaunch an app with network monitoring to see its requests here.")
                    .font(Theme.font)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
    }

    private func count(_ number: Int) -> String {
        number == 1 ? "1 request" : "\(number) requests"
    }
}

private struct FilterField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
            TextField("Filter", text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(Theme.font)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.09)))
        .frame(maxWidth: 320)
    }
}

private struct RequestRow: View {
    let event: NetworkEvent

    var body: some View {
        HStack(spacing: 8) {
            Text(event.method)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 46, alignment: .leading)
            StatusBadge(event: event)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.path).font(Theme.font).lineLimit(1).truncationMode(.middle)
                Text(event.host).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text(NetworkFormat.duration(event.duration))
                Text(NetworkFormat.size(event.responseBodySize)).foregroundStyle(.secondary)
            }
            .font(.system(size: 10.5).monospacedDigit())
        }
        .padding(.vertical, 2)
    }
}

private struct StatusBadge: View {
    let event: NetworkEvent

    var body: some View {
        Text(event.status.map(String.init) ?? "Failed")
            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(event.statusClass.colour)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(event.statusClass.colour.opacity(0.18)))
    }
}

private extension NetworkEvent.StatusClass {
    var colour: Color {
        switch self {
        case .success: .green
        case .redirect: .cyan
        case .clientError: .orange
        case .serverError, .failed: .red
        case .informational: .secondary
        }
    }
}

private struct RequestDetail: View, Equatable {
    let event: NetworkEvent
    @State private var copied = false

    nonisolated static func == (lhs: RequestDetail, rhs: RequestDetail) -> Bool {
        lhs.event == rhs.event
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Card {
                    HStack(spacing: 8) {
                        Text(event.method).font(.system(size: 12, weight: .bold, design: .monospaced))
                        StatusBadge(event: event)
                        Spacer(minLength: 8)
                        Pill(title: copied ? "Copied" : "Copy as cURL", symbol: "terminal") { copyCurl() }
                            .fixedSize()
                    }
                    Text(event.url)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = event.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.font)
                            .foregroundStyle(.orange)
                    }
                }
                Card(spacing: 4) {
                    CardHeader(text: "Timing")
                    Row(label: "Started") {
                        Text(event.startedAt.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))))
                    }
                    Row(label: "Duration") { Text(NetworkFormat.duration(event.duration)) }
                    Row(label: "Response size") { Text(NetworkFormat.size(event.responseBodySize)) }
                    if let app = event.bundleID {
                        Row(label: "App") { Text(app).textSelection(.enabled) }
                    }
                }
                HeadersCard(title: "Request Headers", headers: event.requestHeaders)
                if event.requestBodySize > 0 {
                    BodyCard(title: "Request Body", data: event.requestBody, size: event.requestBodySize)
                }
                HeadersCard(title: "Response Headers", headers: event.responseHeaders)
                if event.responseBodySize > 0 {
                    BodyCard(title: "Response Body", data: event.responseBody, size: event.responseBodySize)
                }
            }
            .padding(10)
        }
    }

    private func copyCurl() {
        NetworkPasteboard.copy(event.curlCommand)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

private struct HeadersCard: View {
    let title: String
    let headers: [String: String]

    var body: some View {
        Card(spacing: 6) {
            CardHeader(text: title)
            if headers.isEmpty {
                Text("None").font(Theme.font).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                    ForEach(headers.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }, id: \.key) { header in
                        GridRow {
                            Text(header.key).foregroundStyle(.secondary)
                            Text(header.value)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.system(size: 11, design: .monospaced))
            }
        }
    }
}

private struct BodyCard: View {
    let title: String
    let data: Data?
    let size: Int

    var body: some View {
        let kept = data?.count ?? 0
        let text = NetworkFormat.text(data, truncated: kept < size)
        Card(spacing: 6) {
            HStack {
                CardHeader(text: title)
                Spacer()
                if let text {
                    Button("Copy") { NetworkPasteboard.copy(text) }
                        .buttonStyle(.plain)
                        .font(Theme.smallFont)
                        .foregroundStyle(Color.accentColor)
                }
            }
            if let text {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("\(NetworkFormat.size(size)) of binary data").font(Theme.font).foregroundStyle(.secondary)
            }
            if kept < size {
                Text("Showing the first \(NetworkFormat.size(kept)) of \(NetworkFormat.size(size)).")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

enum NetworkFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.2f s", seconds)
    }

    static func size(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file, spellsOutZero: false))
    }

    /// JSON comes back pretty-printed and other text as it is. Nil means the body isn't text.
    static func text(_ data: Data?, truncated: Bool = false) -> String? {
        guard let data, !data.isEmpty, !data.contains(0) else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any] || object is [Any],
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            return String(decoding: pretty, as: UTF8.self)
        }
        // A body cut off at the size limit can end partway through a character.
        for dropped in 0...(truncated ? 3 : 0) {
            if let text = String(data: data.dropLast(dropped), encoding: .utf8) { return text }
        }
        return nil
    }
}

enum NetworkPasteboard {
    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
