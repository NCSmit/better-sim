import SwiftUI
import UniformTypeIdentifiers

// MARK: - Capture

struct CaptureTab: View {
    @ObservedObject var model: SimulatorModel
    @ObservedObject var preferences: Preferences
    @State private var editingStatusBar = false

    var body: some View {
        Card {
            SwitchRow(label: "Device frame", isOn: $preferences.framesScreenshots)
                .disabled(model.profile?.hasChrome != true)
            Row(label: "Background") {
                CompactMenu(title: preferences.background.rawValue) {
                    ForEach(ScreenshotBackground.allCases) { background in
                        Button(background.rawValue) { preferences.background = background }
                    }
                }
            }
            Row(label: "Ratio") {
                CompactMenu(title: preferences.ratio.rawValue) {
                    ForEach(ScreenshotRatio.allCases) { ratio in
                        Button(ratio.rawValue) { preferences.ratio = ratio }
                    }
                }
            }
            TextField("Title above the device", text: $preferences.screenshotTitle)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            CardDivider()
            SwitchRow(label: "Touches", isOn: $preferences.showsTouches)
                .help("Show where you click in recordings")
            SwitchRow(label: "120 fps with sound", isOn: $preferences.highFrameRate)
                .help("Record the Simulator window at up to 120 fps with its audio. Needs Screen Recording access.")
            SwitchRow(label: "Trim before saving", isOn: $preferences.trimsRecordings)
                .help("Open each recording in a trim editor before it's saved")
            SwitchRow(label: "App Store Connect", isOn: $preferences.appStoreMode)
                .help("Screenshots without frames or transparency, and MP4s as 30 fps app previews at Apple's accepted sizes")
            Row(label: "GIF width") {
                CompactMenu(title: "\(Int(preferences.gifWidth)) px") {
                    ForEach([320.0, 480, 640, 800], id: \.self) { width in
                        Button("\(Int(width)) px") { preferences.gifWidth = width }
                    }
                }
            }
            Row(label: "Save to") {
                CompactMenu(title: preferences.saveFolder.lastPathComponent) {
                    Button("Choose Folder…") { preferences.chooseSaveFolder() }
                    Button("Show in Finder") { NSWorkspace.shared.open(preferences.saveFolder) }
                }
            }
            CardDivider()
            if let kind = model.recordingKind, let since = model.recordingSince {
                Button { model.capture(kind) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                        TimelineView(.periodic(from: since, by: 1)) { context in
                            Text("Stop \(kind.rawValue) · \(Duration.seconds(context.date.timeIntervalSince(since)).formatted(.time(pattern: .minuteSecond)))")
                                .monospacedDigit()
                        }
                    }
                }
                .buttonStyle(PillButtonStyle(isOn: true, tint: .red))
            } else {
                HStack(spacing: 6) {
                    ForEach(SimulatorModel.CaptureKind.allCases) { kind in
                        Button(kind.rawValue) { model.capture(kind) }
                            .buttonStyle(PillButtonStyle())
                            .help(kind == .png ? "Take a screenshot" : "Start recording a \(kind.rawValue)")
                    }
                }
            }
        }
        Card(padding: 6) {
            HStack(spacing: 6) {
                Pill(title: "9:41", symbol: "clock", isOn: model.cleanStatusBar) {
                    model.setCleanStatusBar(!model.cleanStatusBar)
                }
                .help("Show a clean status bar: 9:41, full battery and signal")
                Pill(title: "Custom", symbol: "slider.horizontal.3") { editingStatusBar = true }
                    .help("Choose the status bar's time, battery and signal")
                    .popover(isPresented: $editingStatusBar, arrowEdge: .trailing) {
                        StatusBarEditor(model: model)
                    }
                Pill(
                    title: model.appearance == "dark" ? "Dark" : "Light",
                    symbol: model.appearance == "dark" ? "moon.fill" : "sun.max.fill"
                ) { model.toggleAppearance() }
                .help("Switch between light and dark mode")
            }
        }
        if !model.captures.isEmpty {
            Card {
                CardHeader(text: "RECENT")
                HStack(spacing: 6) {
                    ForEach(model.captures.prefix(4), id: \.self) { url in
                        CaptureThumbnail(url: url)
                    }
                }
                Text("Drag into any app, or click to show in Finder.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct StatusBarEditor: View {
    @ObservedObject var model: SimulatorModel
    @State private var style = StatusBarStyle()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Row(label: "Time") {
                TextField("9:41", text: $style.time).textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 90)
            }
            Row(label: "Battery \(Int(style.batteryLevel))%") {
                PanelSlider(value: $style.batteryLevel, range: 0...100, step: 5).frame(width: 110)
            }
            Row(label: "Charging") {
                Picker("Charging", selection: $style.batteryState) {
                    ForEach(StatusBarStyle.batteryStates, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .labelsHidden().controlSize(.small).frame(width: 110)
            }
            Row(label: "Network") {
                Picker("Network", selection: $style.network) {
                    ForEach(StatusBarStyle.networks, id: \.self) { Text($0 == "wifi" ? "Wi-Fi" : $0.uppercased()).tag($0) }
                }
                .labelsHidden().controlSize(.small).frame(width: 110)
            }
            Row(label: "Wi-Fi bars \(Int(style.wifiBars))") {
                PanelSlider(value: $style.wifiBars, range: 0...3, step: 1).frame(width: 110)
            }
            Row(label: "Cell bars \(Int(style.cellularBars))") {
                PanelSlider(value: $style.cellularBars, range: 0...4, step: 1).frame(width: 110)
            }
            Row(label: "Carrier") {
                TextField("None", text: $style.carrier).textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 110)
            }
            HStack(spacing: 6) {
                Pill(title: "Clear") { model.setCleanStatusBar(false) }
                Pill(title: "Apply", isOn: true) { model.setStatusBar(style) }
            }
        }
        .padding(12)
        .frame(width: 250)
    }
}

struct CaptureThumbnail: View {
    let url: URL

    var body: some View {
        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
            ZStack(alignment: .bottomTrailing) {
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "film").foregroundStyle(.secondary)
                }
                Text(url.pathExtension.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                    .padding(2)
            }
            .frame(width: 50, height: 70)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(url.lastPathComponent)
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
    }
}

// MARK: - Compare

struct CompareTab: View {
    @ObservedObject var model: SimulatorModel
    @ObservedObject var overlay: OverlayModel
    @State private var isTargeted = false
    @State private var showsAdvanced = false
    @AppStorage("colourFormat") private var colourFormat = ColourFormat.hex

    var body: some View {
        Card(padding: 6) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                Pill(title: "Design", isOn: overlay.showsImage && overlay.image != nil) {
                    if overlay.image == nil { overlay.chooseImage() } else { overlay.showsImage.toggle() }
                }
                Pill(title: "Grid", isOn: overlay.showsGrid) { overlay.showsGrid.toggle() }
                Pill(title: "Rulers", isOn: overlay.showsRulers) { overlay.showsRulers.toggle() }
                    .help("Show rulers and the pointer's position, in points")
                Pill(title: "Measure", isOn: overlay.isMeasuring) { overlay.isMeasuring.toggle() }
                    .help("Drag across the screen to measure, in points")
            }
        }
        Card {
            CardHeader(text: "DESIGN")
            if let image = overlay.image {
                HStack(spacing: 8) {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: 26, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text(overlay.imageName ?? "Pasted image").font(Theme.font).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button { overlay.removeImage() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                Segments(options: OverlayModel.Mode.allCases.map { ($0, $0.rawValue) }, selection: $overlay.mode)
                if overlay.mode == .fade {
                    Row(label: "Opacity") {
                        PanelSlider(value: $overlay.opacity, range: 0.05...1).frame(width: 120)
                    }
                } else {
                    Row(label: "Divider") {
                        PanelSlider(value: $overlay.split).frame(width: 120)
                    }
                }
                SwitchRow(label: "Mirror", isOn: $overlay.flipped)
                DisclosureGroup(isExpanded: $showsAdvanced) {
                    VStack(spacing: 6) {
                        Row(label: "Zoom \(Int(overlay.zoom * 100))%") {
                            PanelSlider(value: $overlay.zoom, range: 0.5...2, step: 0.01).frame(width: 110)
                        }
                        Row(label: "X offset \(Int(overlay.offsetX)) pt") {
                            PanelSlider(value: $overlay.offsetX, range: -100...100, step: 1).frame(width: 110)
                        }
                        Row(label: "Y offset \(Int(overlay.offsetY)) pt") {
                            PanelSlider(value: $overlay.offsetY, range: -100...100, step: 1).frame(width: 110)
                        }
                        Pill(title: "Reset") {
                            overlay.zoom = 1
                            overlay.offsetX = 0
                            overlay.offsetY = 0
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Advanced").font(Theme.font)
                }
            } else {
                Button { overlay.chooseImage() } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 16))
                        Text("Drop a design here").font(Theme.font)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                            .foregroundStyle(isTargeted ? Color.accentColor : .white.opacity(0.25))
                    )
                }
                .buttonStyle(.plain)
                .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                    _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in overlay.load(url) }
                    }
                    return true
                }
            }
            HStack(spacing: 6) {
                Pill(title: "Paste", symbol: "doc.on.clipboard") { overlay.paste() }
                Pill(title: "Choose…", symbol: "folder") { overlay.chooseImage() }
            }
        }
        Card {
            CardHeader(text: "GRID")
            Row(label: "Spacing") {
                CompactMenu(title: "\(Int(overlay.gridSpacing)) pt") {
                    ForEach([4.0, 8, 16, 20, 44], id: \.self) { spacing in
                        Button("\(Int(spacing)) pt") { overlay.gridSpacing = spacing }
                    }
                }
            }
            Row(label: "Colour") {
                ColorPicker("Colour", selection: $overlay.gridColor).labelsHidden().controlSize(.small)
            }
        }
        Card {
            CardHeader(text: "COLOUR PICKER")
            Segments(options: ColourFormat.allCases.map { ($0, $0.rawValue) }, selection: $colourFormat)
            Pill(title: "Pick a Colour", symbol: "eyedropper") { model.pickColour(colourFormat) }
                .help("Magnify any part of the screen and copy the colour under the pointer")
        }
        if !AccessibilityScreenFinder.isTrusted {
            Card {
                Text("Overlays are placed from the window size. Allow Accessibility for an exact fit.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Pill(title: "Allow Accessibility…") { AccessibilityScreenFinder.requestAccess() }
            }
        }
    }
}

// MARK: - App

struct AppTab: View {
    @ObservedObject var model: SimulatorModel
    @ObservedObject var library: Library
    @AppStorage("appTab") private var section = Section.actions

    enum Section: String, CaseIterable, Identifiable {
        case actions = "Actions"
        case links = "Deep Links"
        case push = "Push Notifications"
        case defaults = "UserDefaults"
        case builds = "Recent Builds"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .actions: "bolt"
            case .links: "link"
            case .push: "bell"
            case .defaults: "list.bullet.rectangle"
            case .builds: "hammer"
            }
        }
    }

    var body: some View {
        if model.apps.isEmpty && section != .builds {
            Card {
                Text("Install an app on this simulator to use app actions, or build one in Xcode.")
                    .font(Theme.font)
                    .foregroundStyle(.secondary)
                Pill(title: "Recent Builds", symbol: "hammer") { section = .builds }
            }
        } else {
            Card(spacing: 6) {
                if !model.apps.isEmpty {
                    AppHeader(model: model)
                    CardDivider()
                }
                HStack {
                    Spacer()
                    IconTabs(tabs: Section.allCases, selection: $section, symbol: \.symbol, title: \.rawValue)
                    Spacer()
                }
            }
            switch section {
            case .actions: AppActionsCard(model: model)
            case .links: DeepLinksCard(model: model, library: library)
            case .push: PushCard(model: model, library: library)
            case .defaults: DefaultsCard(model: model)
            case .builds: BuildsCard(model: model)
            }
        }
    }
}

struct AppHeader: View {
    @ObservedObject var model: SimulatorModel

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon = model.appIcon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.app?.name ?? "Choose an app").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(model.app?.versionText ?? "").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu {
                ForEach(model.apps) { app in
                    Button(app.name) { model.selectApp(app.bundleID) }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose another app")
        }
    }
}

struct AppActionsCard: View {
    @ObservedObject var model: SimulatorModel
    @State private var language = Language.common[2]
    @State private var timeZone = TimeZones.common[0]
    @State private var service = 0
    @State private var confirmingUninstall = false

    var body: some View {
        Card {
            CardHeader(text: "LIFECYCLE")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                Pill(title: "Launch") { model.launchApp() }
                Pill(title: "Relaunch") { model.relaunchApp() }
                Pill(title: "Terminate") { model.terminateApp() }
                Pill(title: "Uninstall") { confirmingUninstall = true }
            }
            .confirmationDialog("Uninstall \(model.app?.name ?? "this app") from the simulator?", isPresented: $confirmingUninstall) {
                Button("Uninstall", role: .destructive) { model.uninstallApp() }
            }
            CardHeader(text: "NETWORK")
            Pill(title: "Network Monitor", symbol: "antenna.radiowaves.left.and.right") { model.monitorNetwork() }
                .help("Show the app's network requests. If the app isn't being monitored yet, it's relaunched with the monitor first.")
            CardHeader(text: "LOCALE & TIME ZONE")
            HStack(spacing: 6) {
                Picker("Language", selection: $language) {
                    ForEach(Language.common) { Text($0.name).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                Pill(title: "Relaunch") { model.relaunch(in: language) }
                    .frame(width: 74)
            }
            HStack(spacing: 6) {
                Picker("Time zone", selection: $timeZone) {
                    ForEach(TimeZones.common, id: \.self) { Text(TimeZones.name($0)).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                Pill(title: "Relaunch") { model.relaunch(inTimeZone: timeZone) }
                    .frame(width: 74)
            }
            CardHeader(text: "PERMISSIONS")
            Picker("Permission", selection: $service) {
                ForEach(Permissions.services.indices, id: \.self) { Text(Permissions.services[$0].name).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            HStack(spacing: 6) {
                ForEach(PermissionAction.allCases, id: \.self) { action in
                    Pill(title: action.rawValue.capitalized) { model.setPermission(action, Permissions.services[service]) }
                }
            }
            CardHeader(text: "FILES")
            HStack(spacing: 6) {
                Menu {
                    ForEach(AppFolder.allCases) { folder in
                        Button(folder.rawValue) { model.open(folder) }
                    }
                    if !model.appGroups.isEmpty {
                        Divider()
                        ForEach(model.appGroups, id: \.id) { group in
                            Button(group.id) { model.openGroup(group.url) }
                        }
                    }
                } label: {
                    Label("Open Folder", systemImage: "folder").font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.button)
                .controlSize(.small)
                Pill(title: "Clear Defaults", symbol: "eraser") { model.clearDefaults() }
            }
            CardHeader(text: "KEYCHAIN & CLIPBOARD")
            Pill(title: "Reset Keychain", symbol: "key") { model.resetKeychain() }
            HStack(spacing: 6) {
                Pill(title: "To Mac") { model.syncPasteboard(toMac: true) }
                    .help("Copy the simulator's clipboard to your Mac")
                Pill(title: "To Simulator") { model.syncPasteboard(toMac: false) }
                    .help("Copy your Mac's clipboard to the simulator")
            }
        }
    }
}

struct DeepLinksCard: View {
    @ObservedObject var model: SimulatorModel
    @ObservedObject var library: Library
    @State private var link = ""
    @State private var argument = ""

    var body: some View {
        Card {
            HStack(spacing: 6) {
                TextField("myapp://path/{ARG}", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(openLink)
                Pill(title: "Open", action: openLink)
                    .frame(width: 54)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if link.contains("{ARG}") {
                TextField("Value for {ARG}", text: $argument)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(openLink)
            }
            let saved = library.deepLinks(for: model.selectedBundleID ?? "")
            if saved.isEmpty {
                Text("Links you open are kept here for this app. Put {ARG} in a link to fill it in each time.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(saved, id: \.self) { savedLink in
                HStack(spacing: 6) {
                    Button {
                        link = savedLink
                        if !savedLink.contains("{ARG}") { openLink() }
                    } label: {
                        Text(savedLink).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .font(Theme.font)
                    Button { library.forget(savedLink, for: model.selectedBundleID ?? "") } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func openLink() {
        let template = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else { return }
        let value = argument.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? argument
        model.open(link: template.replacingOccurrences(of: "{ARG}", with: value), remembering: template)
    }
}

struct PushCard: View {
    @ObservedObject var model: SimulatorModel
    @ObservedObject var library: Library
    @State private var payload = PushPayload.templates[0].json

    var body: some View {
        Card {
            HStack(spacing: 6) {
                CompactMenu(title: "Template") {
                    ForEach(PushPayload.templates, id: \.name) { template in
                        Button(template.name) { payload = template.json }
                    }
                }
                Spacer()
                Pill(title: "Send", symbol: "paperplane.fill", isOn: true) { model.sendPush(payload) }
                    .frame(width: 70)
            }
            TextEditor(text: $payload)
                .font(.system(size: 10.5, design: .monospaced))
                .frame(height: 150)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
            Text("Or drop an .apns file on the panel.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: loadPayload)
        .onChange(of: model.selectedBundleID) { loadPayload() }
    }

    private func loadPayload() {
        if let id = model.selectedBundleID, let saved = library.payload(for: id) { payload = saved }
    }
}

struct DefaultsCard: View {
    @ObservedObject var model: SimulatorModel
    @State private var search = ""
    @State private var editing: String?
    @State private var draft = ""
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var newType = "String"

    private var rows: [(key: String, value: DefaultsValue)] {
        search.isEmpty ? model.defaults : model.defaults.filter { $0.key.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Card {
            if !model.appGroups.isEmpty {
                Picker("Defaults", selection: $model.defaultsGroup) {
                    Text("Standard").tag(String?.none)
                    ForEach(model.appGroups, id: \.id) { group in
                        Text(group.id).tag(Optional(group.id))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .help("Show the app's own defaults, or those of one of its App Groups")
            }
            HStack(spacing: 6) {
                TextField("Search keys", text: $search).textFieldStyle(.roundedBorder).controlSize(.small)
                Button { model.loadDefaults() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(PillButtonStyle())
                    .frame(width: 30)
                    .help("Reload")
            }
            if rows.isEmpty {
                Text(model.defaults.isEmpty ? "This app hasn't saved any UserDefaults yet." : "No keys match.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(rows, id: \.key) { row in
                            defaultsRow(row.key, row.value)
                        }
                    }
                }
                .frame(height: min(CGFloat(rows.count) * 34, 300))
            }
            CardDivider()
            CardHeader(text: "ADD A KEY")
            TextField("Key", text: $newKey).textFieldStyle(.roundedBorder).controlSize(.small)
            HStack(spacing: 6) {
                Picker("Type", selection: $newType) {
                    ForEach(["String", "Integer", "Number", "Boolean"], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().controlSize(.small).frame(width: 84)
                TextField("Value", text: $newValue).textFieldStyle(.roundedBorder).controlSize(.small)
                Pill(title: "Add", action: addKey).frame(width: 44)
                    .disabled(newKey.isEmpty)
            }
        }
        .onAppear { model.loadDefaults() }
        .onChange(of: model.selectedBundleID) { model.loadDefaults() }
    }

    @ViewBuilder
    private func defaultsRow(_ key: String, _ value: DefaultsValue) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(key).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                Text(value.typeName).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                Button { model.deleteDefault(key) } label: { Image(systemName: "trash").font(.system(size: 10)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Delete this key")
            }
            if editing == key {
                HStack(spacing: 4) {
                    if case .bool(let flag) = value {
                        Toggle("Value", isOn: Binding(get: { flag }, set: { model.setDefault(key, to: .bool($0)) }))
                            .labelsHidden()
                            .toggleStyle(PanelSwitchStyle())
                        Spacer()
                    } else {
                        TextField("Value", text: $draft).textFieldStyle(.roundedBorder).controlSize(.small)
                            .onSubmit { save(key, value) }
                        Pill(title: "Save") { save(key, value) }.frame(width: 50)
                    }
                }
            } else {
                Button {
                    guard value.isEditable else { return }
                    editing = key
                    draft = value.summary
                } label: {
                    Text(value.summary)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help(value.isEditable ? "Click to edit" : "\(value.typeName) values can't be edited here")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(editing == key ? 0.08 : 0.03)))
    }

    private func save(_ key: String, _ value: DefaultsValue) {
        guard let updated = value.replaced(with: draft) else {
            return model.show("That isn't a valid \(value.typeName.lowercased()).", isError: true)
        }
        model.setDefault(key, to: updated)
        editing = nil
    }

    private func addKey() {
        let value: DefaultsValue? = switch newType {
        case "Integer": Int(newValue).map(DefaultsValue.integer)
        case "Number": Double(newValue).map(DefaultsValue.real)
        case "Boolean": DefaultsValue.bool(false).replaced(with: newValue.isEmpty ? "NO" : newValue)
        default: .string(newValue)
        }
        guard let value else { return model.show("That isn't a valid \(newType.lowercased()).", isError: true) }
        model.setDefault(newKey, to: value)
        newKey = ""
        newValue = ""
    }
}

struct BuildsCard: View {
    @ObservedObject var model: SimulatorModel
    @State private var confirmingDelete = false

    var body: some View {
        BuildInsightsCard(records: model.buildRecords)
        Card {
            if model.recentBuilds.isEmpty {
                Text("Simulator builds from Xcode show up here.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            ForEach(model.recentBuilds) { build in
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(build.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                        Text("\(build.configuration) · \(build.built.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Pill(title: "Install") { model.install(build) }
                        .frame(width: 58)
                        .help("Install this build on the simulator and launch it")
                }
            }
            CardDivider()
            HStack(spacing: 6) {
                Pill(title: "Delete DerivedData", symbol: "trash") { confirmingDelete = true }
                Button { model.refreshRecentBuilds() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(PillButtonStyle())
                    .frame(width: 30)
                    .help("Reload")
            }
            .confirmationDialog("Move all of DerivedData to the Trash?", isPresented: $confirmingDelete) {
                Button("Move to Trash", role: .destructive) { model.trashDerivedData() }
            }
            Pill(title: "Delete SwiftUI Preview Simulators", symbol: "rectangle.stack.badge.minus") { model.clearPreviewSimulators() }
        }
        .onAppear { model.refreshRecentBuilds() }
    }
}

struct BuildInsightsCard: View {
    let records: [BuildRecord]

    var body: some View {
        Card {
            CardHeader(text: "7-DAY AVERAGE BUILD TIME")
            if let summary = BuildInsights.summary(records) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(BuildInsights.format(summary.average)).font(.system(size: 22, weight: .semibold).monospacedDigit())
                    if let change = summary.change {
                        Text("\(change > 0 ? "↑" : "↓") \(Int(abs(change) * 100))%")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(change > 0 ? .red : .green)
                    }
                    Spacer()
                }
                Text("\(summary.count) builds · slowest \(BuildInsights.format(summary.slowest))\(summary.failures > 0 ? " · \(summary.failures) failed" : "")")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                let schemes = Dictionary(grouping: records.prefix(200), by: \.scheme)
                    .map { (name: $0.key, average: $0.value.map(\.duration).reduce(0, +) / Double($0.value.count)) }
                    .sorted { $0.average > $1.average }
                    .prefix(4)
                ForEach(Array(schemes), id: \.name) { scheme in
                    Row(label: scheme.name) {
                        Text(BuildInsights.format(scheme.average)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            } else {
                Text("Xcode records build times for builds you start in Xcode. Build there and your times show up here.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Device

struct DeviceTab: View {
    @ObservedObject var model: SimulatorModel
    @State private var coordinate = ""
    @State private var routeFrom = ""
    @State private var routeTo = ""
    @State private var travel = LocationRoute.Travel.driving

    var body: some View {
        Card {
            CardHeader(text: "APPEARANCE")
            Segments(
                options: [("light", "Light"), ("dark", "Dark")],
                selection: Binding(get: { model.appearance ?? "light" }, set: { model.setAppearance($0) })
            )
            SwitchRow(label: "9:41 status bar", isOn: Binding(get: { model.cleanStatusBar }, set: { model.setCleanStatusBar($0) }))
        }
        Card {
            CardHeader(text: "LOCATION")
            HStack(spacing: 6) {
                Menu {
                    ForEach(Coordinate.places, id: \.name) { place in
                        Button(place.name) { model.setLocation(place.coordinate, name: place.name) }
                    }
                } label: {
                    Label("Place", systemImage: "mappin").font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.button).controlSize(.small)
                Menu {
                    ForEach(model.scenarios, id: \.self) { scenario in
                        Button(scenario) { model.runScenario(scenario) }
                    }
                } label: {
                    Label("Scenario", systemImage: "figure.run").font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.button).controlSize(.small)
            }
            HStack(spacing: 6) {
                TextField("Lat, long", text: $coordinate)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(setCoordinate)
                Pill(title: "Set", action: setCoordinate)
                    .frame(width: 44)
                    .disabled(Coordinate(coordinate) == nil)
            }
            CardHeader(text: "ROUTE")
            TextField("From: a place or lat, long", text: $routeFrom).textFieldStyle(.roundedBorder).controlSize(.small)
            TextField("To", text: $routeTo).textFieldStyle(.roundedBorder).controlSize(.small)
            Segments(options: LocationRoute.Travel.allCases.map { ($0, $0.rawValue) }, selection: $travel)
            HStack(spacing: 6) {
                Pill(title: "Start Route", symbol: "location.north.line") { model.startRoute(from: routeFrom, to: routeTo, travel: travel) }
                    .disabled(routeFrom.isEmpty || routeTo.isEmpty)
                Pill(title: "Clear", symbol: "location.slash") { model.clearLocation() }
                    .frame(width: 70)
            }
        }
        .onAppear { model.loadScenarios() }
        Card {
            CardHeader(text: "NETWORK SPEED")
            Row(label: "Behaves like") {
                CompactMenu(title: model.network?.rawValue ?? "Slowed down") {
                    ForEach(NetworkCondition.allCases) { condition in
                        Button(condition.rawValue) { model.setNetwork(condition) }
                    }
                }
            }
            Text(model.network == .normal
                ? "Slows down your whole Mac's network, since the Simulator shares it. macOS asks for your password."
                : "Your whole Mac's network is slowed down. It goes back to normal when you quit BetterSim.")
                .font(.system(size: 10))
                .foregroundStyle(model.network == .normal ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        Card {
            CardHeader(text: "SIMULATOR")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(SimulatorMenu.Action.allCases) { action in
                    Pill(title: action.rawValue) { model.press(action) }
                }
                Pill(title: "Restart") { model.restartDevice() }
            }
            if !AccessibilityScreenFinder.isTrusted {
                Text("Shake, memory warnings and slow animations need Accessibility access.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func setCoordinate() {
        guard let value = Coordinate(coordinate) else { return }
        model.setLocation(value, name: coordinate)
    }

}

// MARK: - Accessibility

struct AccessibilityTab: View {
    @ObservedObject var model: SimulatorModel

    var body: some View {
        Card {
            CardHeader(text: "DISPLAY & TEXT")
            SwitchRow(label: "Increase contrast", isOn: Binding(get: { model.increasedContrast }, set: { model.setIncreasedContrast($0) }))
            ForEach(AccessibilityToggle.allCases) { toggle in
                SwitchRow(label: toggle.rawValue, isOn: Binding(
                    get: { model.accessibility.contains(toggle) },
                    set: { model.set(toggle, $0) }
                ))
            }
        }
        Card {
            let sizes = DeviceSettings.textSizes
            Row(label: "Text size") {
                Text(model.textSize.map(Self.label) ?? "Unknown").foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: "textformat.size.smaller").font(.system(size: 10)).foregroundStyle(.secondary)
                PanelSlider(
                    value: Binding<Double>(
                        get: { Double(sizes.firstIndex(of: model.textSize ?? "large") ?? 3) },
                        set: { model.setTextSize(sizes[Int($0.rounded())]) }
                    ),
                    range: 0...Double(sizes.count - 1),
                    step: 1
                )
                Image(systemName: "textformat.size.larger").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        Card {
            CardHeader(text: "AUDIT")
            Pill(title: "Audit This Screen", symbol: "checklist", isOn: true) { model.runAudit() }
            if !model.findings.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.findings) { finding in
                            Button { model.point(at: finding.element) } label: {
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: finding.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(finding.severity == .error ? .red : .orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(finding.title).font(.system(size: 11, weight: .semibold))
                                        Text(finding.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.04)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Show this element on the screen")
                        }
                    }
                }
                .frame(height: min(CGFloat(model.findings.count) * 58, 260))
            }
        }
        Card {
            CardHeader(text: "VOICEOVER NAVIGATOR")
            if let index = model.focusedElement, model.elements.indices.contains(index) {
                let element = model.elements[index]
                VStack(alignment: .leading, spacing: 2) {
                    Text(element.label.isEmpty ? "No label" : element.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(element.label.isEmpty ? .orange : .primary)
                    Text("\(AccessibilityAudit.name(of: element.role)) · \(index + 1) of \(model.elements.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Step through the screen in the order VoiceOver reads it.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Pill(title: "Previous", symbol: "chevron.left") { model.moveFocus(by: -1) }
                Pill(title: "Next", symbol: "chevron.right") { model.moveFocus(by: 1) }
            }
            SwitchRow(label: "Speak each element", isOn: $model.speaksElements)
            HStack(spacing: 6) {
                Pill(title: "Reload") { model.loadElements() }
                Pill(title: "Clear") { model.clearHighlight() }
            }
        }
    }

    static func label(_ size: String) -> String {
        size.replacingOccurrences(of: "accessibility-", with: "AX ")
            .replacingOccurrences(of: "extra-", with: "X")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }
}
