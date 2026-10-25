import SwiftUI

/// The app's own palette, taken from the icon: indigo for actions, mint for "running". Red is kept for danger.
enum Brand {
    private static func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    // Button fills are the same in both modes: white text on them is 5:1 or better. Text and icons on the popover adapt.
    static let primary = Color(red: 0.31, green: 0.27, blue: 0.90)
    static let green = Color(red: 0.08, green: 0.50, blue: 0.27)
    static let red = Color(red: 0.82, green: 0.16, blue: 0.22)
    static let primaryText = adaptive(NSColor(red: 0.22, green: 0.18, blue: 0.72, alpha: 1), NSColor(red: 0.65, green: 0.67, blue: 0.99, alpha: 1))
    static let mint = adaptive(NSColor(red: 0.06, green: 0.56, blue: 0.31, alpha: 1), NSColor(red: 0.30, green: 0.84, blue: 0.52, alpha: 1))
    static let orange = adaptive(NSColor(red: 0.78, green: 0.38, blue: 0.0, alpha: 1), NSColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1))
    static let alert = adaptive(NSColor(red: 0.82, green: 0.16, blue: 0.22, alpha: 1), NSColor(red: 0.98, green: 0.45, blue: 0.47, alpha: 1))
}

/// Color tells you what a button is for: blue is the main action, green brings something back, red stops something.
enum Tone {
    case open, start, quiet, copied, stop

    var fill: Color {
        switch self {
        case .open: return Brand.primary
        case .start: return Brand.green
        case .stop: return Brand.red
        case .quiet: return Brand.primary.opacity(0.14)
        case .copied: return Brand.green.opacity(0.18)
        }
    }
    var text: Color {
        switch self {
        case .open, .start, .stop: return .white
        case .quiet: return Brand.primaryText
        case .copied: return Brand.green
        }
    }
}

struct PillButton: ButtonStyle {
    let tone: Tone
    var width: CGFloat = 78
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tone.text)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)   // the label sets the width, so long ones like "Copy address" are never cut
            .padding(.horizontal, 8)
            .frame(minWidth: width, minHeight: 22)
            .background(tone.fill.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

enum Theme {
    /// Screenshots are rendered offscreen where there is nothing to blur, so they use a flat tint instead.
    static var flat = false
    /// Screenshot only: a solid color behind everything, used to recover transparency.
    static var matte: Color?
}

/// Project header bands: translucent, so rows blur underneath as they scroll past.
struct BandBackground: View {
    var body: some View {
        if Theme.flat {
            Color.primary.opacity(0.07)
        } else {
            // The thinnest material keeps the blur but stays see-through; the tint separates the band from the rows.
            Rectangle().fill(.ultraThinMaterial).overlay(Color.primary.opacity(0.05))
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @FocusState private var filterFocused: Bool
    @Environment(\.colorScheme) private var scheme

    // Fixed so the popover never changes size while you filter or toggle.
    private let listHeight: CGFloat = 440

    var body: some View {
        ScrollViewReader { proxy in
        VStack(spacing: 0) {
            if let t = store.logs {
                LogView(tail: t).frame(height: listHeight + 41).clipped().transition(Motion.reduced ? .opacity : .move(edge: .trailing))
            } else {
            header
            Divider()
            VStack(spacing: 0) {
                if store.showMap {
                    StackMapView().transition(Motion.reduced ? .opacity : .move(edge: .trailing))
                } else {
                VStack(spacing: 0) {
                if let port = store.portQuery { PortCard(port: port) }
                if store.groups.isEmpty {
                    if store.portQuery == nil {
                        EmptyState()
                    } else {
                        Spacer(minLength: 0)
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(store.groups) { g in
                                Section {
                                    ForEach(g.running) { RowView(entry: $0).id($0.key).transition(.rowIn) }
                                    ForEach(g.stopped) { StoppedRow(server: $0).id($0.key).transition(.stoppedIn) }
                                } header: {
                                    GroupHeader(group: g)
                                }
                            }
                        }
                    }
                }
                }
                .transition(Motion.reduced ? .opacity : .move(edge: .leading))
                }
            }
            .frame(height: listHeight)
            .clipped()
            .animation(Motion.anim, value: store.showMap)
            .overlay(alignment: .bottom) {
                if let m = store.message {
                    HStack(spacing: 10) {
                        Text(m).font(.caption).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
                        if let u = store.undo { Button(u.label) { store.runUndo() }.buttonStyle(PillButton(tone: .quiet, width: 56)) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.94), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .padding(8)
                    .transition(.sheet(from: .bottom))
                }
            }
            .animation(Motion.pop, value: store.message)
            }
            Divider()
            footer
        }
        .frame(width: 470)
        .tint(Brand.primaryText)   // the brighter lavender in dark mode, so tinted icons stay visible
        .background { if !Theme.flat { Rectangle().fill(scheme == .dark ? Color(white: 0.10) : Color.white).opacity(store.backdropTint) } }
        .background { if let m = Theme.matte { Rectangle().fill(m) } }
        .onReceive(NotificationCenter.default.publisher(for: .popoverDidShow)) { _ in
            store.query = ""
            store.clearSelection()
            filterFocused = true
        }
        .onChange(of: store.selectedKey) { _, k in
            if let k { withAnimation(Motion.anim) { proxy.scrollTo(k, anchor: .center) } }
        }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter, or type a port (3000)", text: $store.query)
                .textFieldStyle(.plain)
                .focused($filterFocused)
                .onSubmit { store.activate() }
            Picker("View", selection: $store.showMap) {
                Image(systemName: "list.bullet").tag(false)
                Image(systemName: "point.3.connected.trianglepath.dotted").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 78)
            .tip(store.showMap ? "Show the list" : "Show the map")
            Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).tip("Rescan")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let tip = store.tip {
                    Text(tip).font(.caption.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                } else if let hint = store.hoverHint {
                    Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("\(store.count) running").font(.caption).foregroundStyle(.secondary)
                    if !store.stopped.isEmpty {
                        Button(store.showStopped ? "Hide stopped" : "Show \(store.stopped.count) stopped") { store.showStopped.toggle() }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(Brand.primaryText)
                    }
                }
                Spacer()
                Menu {
                    if let u = store.update {
                        Button(store.updating ? "Updating…" : "Update to \(u.version)…") { store.installUpdate() }.disabled(store.updating)
                        Divider()
                    }
                    Button("About Switchboard \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")") {
                        NSApp.activate(ignoringOtherApps: true)
                        NSApp.orderFrontStandardAboutPanel(nil)
                    }
                    Text("Shortcut: \(AppDelegate.shortcutLabel)")
                    Divider()
                    Button("Add project folder…") { store.addProject() }
                    Toggle("Show stopped servers", isOn: $store.showStopped)
                    Toggle("Notify when a server stops", isOn: $store.notifyOnStop)
                    Toggle("Show system & apps", isOn: $store.showAll)
                    Picker("Terminal for logs", selection: Binding(get: { store.logTerminal }, set: { store.setLogTerminal($0) })) {
                        ForEach(store.terminals) { Text($0.name).tag($0) }
                    }
                    Toggle("Check for updates", isOn: $store.checkForUpdates)
                    Button("Check for updates now") { store.checkUpdate(force: true) }
                    Toggle("Launch at login", isOn: Binding(get: { store.launchAtLogin }, set: { store.launchAtLogin = $0 }))
                    Divider()
                    Button("Quit Switchboard") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
                } label: {
                    Image(systemName: "gearshape")
                        .overlay(alignment: .topTrailing) { if store.update != nil { Circle().fill(Brand.primaryText).frame(width: 7, height: 7).offset(x: 3, y: -2) } }
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
    }
}

/// Shown when the list is empty: nothing running yet, or the filter matches nothing.
struct EmptyState: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 7) {
                ForEach(0..<2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.5)
                        .frame(width: 70, height: 28)
                        .overlay(alignment: .leading) {
                            HStack(spacing: 8) {
                                Circle().strokeBorder(Color.secondary.opacity(0.8), lineWidth: 1.5).frame(width: 8, height: 8)
                                Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 28, height: 3)
                            }.padding(.leading, 12)
                        }
                }
            }
            if store.query.isEmpty {
                Text("Nothing is running").font(.system(size: 14, weight: .semibold))
                Text("Start a dev server and it shows up here.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("No match for “\(store.query)”").font(.system(size: 14, weight: .semibold))
                Button("Clear filter") { store.query = "" }.controlSize(.small)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "Is port N free? Who has it? What's the next one?" Shown when the filter is a port number.
struct PortCard: View {
    @EnvironmentObject var store: Store
    let port: Int

    var body: some View {
        let owners = store.entries.filter { $0.port == port }
        let inUse = !owners.isEmpty || !Ports.isFree(port)
        let next = Ports.nextFree(after: port, taken: Set(store.entries.map(\.port)))
        HStack(spacing: 10) {
            Image(systemName: inUse ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(inUse ? Brand.orange : Brand.green).font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(inUse ? "Port \(String(port)) is in use" : "Port \(String(port)) is free").font(.system(size: 13, weight: .semibold))
                Text(!inUse ? "Go ahead and start your server"
                     : owners.isEmpty ? "Held by a process Switchboard can't see. Next free port is \(String(next))."
                     : "Stop it below to free the port. Next free port is \(String(next)).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if inUse {
                Button("Copy \(String(next))") { Actions.copy(String(next)); store.flash("Copied \(next), the next free port") }
                    .buttonStyle(PillButton(tone: .quiet, width: 74)).tip("Copy the next free port")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background((inUse ? Brand.orange : Brand.green).opacity(0.12))
    }
}

struct GroupHeader: View {
    @EnvironmentObject var store: Store
    let group: ProjectGroup

    private var restartable: Int { group.running.filter { $0.container != nil || $0.restart != nil }.count }
    private var stoppable: Int { group.running.filter { $0.kind != .other }.count }
    private var startable: Int { group.stopped.filter(\.canStart).count }

    var body: some View {
        HStack(spacing: 6) {
            if group.name == "Pinned" { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.secondary) }
            Text(group.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            if startable > 1 {
                Button("Start stack") { store.startAll(group) }
                    .buttonStyle(PillButton(tone: .start, width: 84))
                    .hoverTip("Start everything here, in order", tint: Brand.green)
            }
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary).frame(width: 24, height: 20).contentShape(Rectangle())
                    .hoverTip("Project actions", tint: Brand.primary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BandBackground())
        .contextMenu { actions }
    }

    @ViewBuilder private var actions: some View {
        if let path = group.path {
            ForEach(Editors.installed, id: \.name) { ed in
                Button("Open in \(ed.name)") { store.openProject(path, in: ed.url) }
            }
            Button("Open Terminal here") { Editors.openTerminal(at: path) }
            Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            Divider()
        }
        if group.path != nil { Button("Save stack file…") { store.saveStackFile(group) } }
        if let p = group.path, store.projects.contains(p) { Button("Remove project") { store.removeProject(p) } }
        if startable > 0 { Button(startable > 1 ? "Start stack in order (\(startable))" : "Start 1 stopped") { store.startAll(group) } }
        if restartable > 0 { Button("Restart \(restartable) running") { store.restartAll(group) } }
        if stoppable > 0 { Button("Stop all \(stoppable)…") { store.stopAll(group) } }
    }
}

struct RowView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var tunnels: TunnelManager
    let entry: PortEntry
    @State private var hover = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    init(entry: PortEntry) {
        self.entry = entry
        _tunnels = ObservedObject(wrappedValue: Store.shared.tunnels)
    }

    private var active: Bool { store.keyboardMode ? store.selectedKey == entry.key : hover }
    private var armed: Bool { store.armedKill == entry.id }
    private var busyLabel: String? { store.busy[entry.key] }
    private var copied: Bool { store.copiedID == entry.id }
    private var canRestart: Bool { entry.container != nil || entry.restart != nil }
    private var editingPort: Bool { store.editing == .init(key: entry.key, field: .port) }
    private var editingName: Bool { store.editing == .init(key: entry.key, field: .name) }

    /// A text field in place of the label. Return saves, Esc or clicking away cancels.
    private func editor(_ field: Store.InlineEdit.Field, width: CGFloat?, size: CGFloat, weight: Font.Weight, commit: @escaping (String) -> Void) -> some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain).font(.system(size: size, weight: weight)).monospacedDigit()
            .focused($fieldFocused)
            .onSubmit { commit(draft) }
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Brand.primary, lineWidth: 1))
            .frame(width: width)
            .onAppear {
                DispatchQueue.main.async {
                    fieldFocused = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }   // typing replaces the old value
                }
            }
            .onChange(of: fieldFocused) { _, on in if !on { store.cancelEdit(key: entry.key, field: field) } }
    }

    @ViewBuilder private var portLabel: some View {
        if editingPort {
            editor(.port, width: 58, size: 15, weight: .semibold) { _ = store.commitPort(entry, text: $0) }
        } else {
            Text(String(entry.port))
                .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                .frame(width: 58, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { draft = String(entry.port); store.beginEdit(entry, .port) }
                .tip(canRestart && entry.container == nil ? "Double click to change the port" : "PID \(entry.pid.map(String.init) ?? "-")")
        }
    }

    /// The page's own icon, when it has one.
    @ViewBuilder private var pageIcon: some View {
        if let image = store.icons[entry.key] {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: 13, height: 13).clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
    }

    /// What the page calls itself, unless that only repeats the name already shown.
    private var pageTitleLine: String? {
        guard entry.web == .page, let t = entry.pageTitle else { return nil }
        let known = [store.displayName(entry), entry.title].map { $0.lowercased() }
        return known.contains(t.lowercased()) ? nil : t
    }

    @ViewBuilder private var nameLabel: some View {
        if editingName {
            editor(.name, width: 160, size: 13, weight: .regular) { store.commitName(entry, text: $0) }
        } else {
            Text(store.displayName(entry)).font(.system(size: 13)).lineLimit(1).layoutPriority(2)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { draft = store.names[entry.key] ?? entry.title; store.beginEdit(entry, .name) }
        }
    }

    private var content: some View {
        HStack(spacing: 10) {
            Circle().fill(Brand.mint).frame(width: 7, height: 7)
            portLabel
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    pageIcon
                    nameLabel
                    if store.isRenamed(entry) {
                        Text(entry.title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if entry.web == .api {
                        Text("API").font(.system(size: 9, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.secondary.opacity(0.2), in: Capsule()).foregroundStyle(.secondary)
                            .tip("API: no web page")
                    }
                    health
                    if entry.lanExposed {
                        Image(systemName: "wifi").font(.system(size: 9)).foregroundStyle(Brand.orange)
                            .tip("Open to your network")
                    }
                    if store.isPinned(entry.key) { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.secondary) }
                }
                // Show exactly what the button will copy, so there is nothing to guess.
                if entry.web != .page {
                    Text(entry.address).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                }
                if let t = pageTitleLine {
                    Text(verbatim: t).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                if let t = tunnels.tunnels[entry.port] { TunnelLine(tunnel: t) }
            }
            .layoutPriority(1)
            .tip("PID \(entry.pid.map(String.init) ?? "-")\n\(entry.command)\nDouble click the name to rename")
            Spacer(minLength: 4)
            if let label = busyLabel {
                Text(label).font(.caption).foregroundStyle(.secondary)
                ProgressView().controlSize(.small)
            } else {
                if armed {
                    Text("Stop \(entry.title)?").font(.caption).foregroundStyle(Brand.alert)
                } else if active {
                    secondaryActions
                } else if let up = entry.uptime {
                    uptimeLabel(up)
                }
                mainButton
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .frame(height: 44)
        .background(store.recent.contains(entry.key) ? Brand.mint.opacity(0.20)
                    : (store.keyboardMode && active ? Brand.primary.opacity(0.14) : (active ? Color.primary.opacity(0.07) : .clear)))
        .overlay(alignment: .leading) { if store.keyboardMode && active { Rectangle().fill(Brand.primary).frame(width: 3) } }
        .onHover { hover = $0; store.setHover(entry.key, $0) }
    }

    var body: some View {
        content
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(store.displayName(entry)), port \(entry.port)\(entry.web == .api ? ", API" : ""), running\(entry.uptime.map { " for \($0)" } ?? "")\(entry.status.map { $0 >= 500 ? ", returning error \($0)" : "" } ?? "")")
        .accessibilityHint(entry.web == .page ? "Opens in your browser" : "Copies \(entry.address)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { store.primary(entry) }
        .accessibilityAction(named: "Restart") { if canRestart { store.restart(entry) } }
        .accessibilityAction(named: "Change port") { draft = String(entry.port); store.beginEdit(entry, .port) }
        .accessibilityAction(named: "Rename") { draft = store.names[entry.key] ?? entry.title; store.beginEdit(entry, .name) }
        .accessibilityAction(named: "Show logs") { store.tail(entry) }
        .accessibilityAction(named: "Copy \(entry.address)") { store.copyLocal(entry) }
        .accessibilityAction(named: "Stop") { store.kill(entry) }
        .accessibilityAction(named: store.isPinned(entry.key) ? "Unpin" : "Pin") { store.togglePin(entry) }
        .contextMenu { ServerMenu(entry: entry) }
    }

    /// "up 5m · 120 MB", with the CPU share shown in orange only when the server is busy.
    private func uptimeLabel(_ up: String) -> some View {
        let u = store.usage[entry.key]
        return HStack(spacing: 4) {
            if let u, u.busy { Text(u.cpuText).foregroundStyle(Brand.orange) }
            Text(u.map { "up \(up) · \($0.memoryText)" } ?? "up \(up)").foregroundStyle(.secondary)
        }
        .font(.caption).lineLimit(1).fixedSize()
        .tip(u.map { "Running for \(up)\nCPU \(Int($0.cpu.rounded()))% of one core, memory \($0.memoryText)\nCounts the processes it started too" } ?? "Running for \(up)")
    }

    @ViewBuilder private var health: some View {
        if let s = entry.status, let ms = entry.ms {
            if s >= 500 {
                Text("\(s)").font(.system(size: 10, weight: .bold)).foregroundStyle(Brand.alert).tip("Server returned HTTP \(s)")
            } else {
                Text("\(ms) ms").font(.system(size: 10)).foregroundStyle(.secondary).tip("HTTP \(s) in \(ms) ms")
            }
        }
    }

    @ViewBuilder private var mainButton: some View {
        if armed {
            Button { store.kill(entry) } label: { Text("Yes, stop") }
                .buttonStyle(PillButton(tone: .stop))
        } else if entry.web == .page {
            Button { store.open(entry) } label: { Text("Open") }
                .buttonStyle(PillButton(tone: .open))
                .hoverTip("Open in browser  (⌘O)", tint: Brand.primary)
        } else {
            Button { store.copyLocal(entry) } label: {
                Text(copied ? "Copied ✓" : entry.copyLabel).animation(Motion.anim, value: copied)
            }
            .buttonStyle(PillButton(tone: copied ? .copied : .quiet))
            .hoverTip("\(entry.copyLabel)  (⌘C)", tint: Brand.primary)
        }
    }

    private var secondaryActions: some View {
        HStack(spacing: 0) {
            if entry.web == .page {
                IconButton(symbol: "doc.on.doc", help: "Copy link  (⌘C)") { store.copyLocal(entry) }
            }
            IconButton(symbol: "arrow.clockwise", help: canRestart ? "Restart  (⌘R)" : "Can't restart this one")
                { store.restart(entry) }
                .disabled(!canRestart)
            IconButton(symbol: "text.alignleft", help: "Logs  (⌘L)") { store.tail(entry) }
            shareMenu
            IconButton(symbol: "stop.fill", help: "Stop  (⌘⌫)", tint: Brand.alert) { store.kill(entry) }
            moreMenu
        }
    }

    private var shareMenu: some View {
        let lan = Actions.lanAddress().map { "http://\($0):\(entry.port)" } ?? "no network found"
        return Menu {
            Button("Copy link for this Mac:  \(entry.address)") { store.copyLocal(entry) }
            Button(entry.lanExposed ? "Copy link for your Wi-Fi:  \(lan)" : "Copy link for your Wi-Fi (won't work, localhost only)") {
                store.copyLAN(entry)
            }
            if entry.web != .none { Button("Copy as curl") { store.copyCurl(entry) } }
            Button("Show QR code to open on your phone…") { store.showQR(entry) }
            Divider()
            if tunnels.tunnels[entry.port] != nil {
                Button("Stop the internet link") { store.toggleTunnel(entry) }
            } else if let p = TunnelManager.provider {
                Button("Get a temporary internet link (via \(p.name))") { store.toggleTunnel(entry) }
            } else {
                Button("Get an internet link (needs cloudflared: brew install cloudflared)") { store.toggleTunnel(entry) }
            }
        } label: {
            Image(systemName: "square.and.arrow.up").frame(width: 24, height: 24).contentShape(Rectangle())
                .hoverTip(entry.web == .none ? "Can't share: not a web server" : "Share", tint: Brand.primary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(entry.web == .none)
    }

    private var moreMenu: some View {
        Menu {
            Button(store.isPinned(entry.key) ? "Unpin  (⌘P)" : "Pin to top  (⌘P)") { store.togglePin(entry) }
            Button("Rename…") { store.rename(entry) }
            Button("Change port…") { store.askPort(entry) }.disabled(entry.container != nil || entry.restart == nil)
            if entry.web == .api { Button("Open \(entry.address) in browser") { store.open(entry) } }
            if let path = entry.projectPath {
                Divider()
                ForEach(Editors.installed, id: \.name) { ed in Button("Open project in \(ed.name)") { store.openProject(path, in: ed.url) } }
                Button("Open Terminal in project") { Editors.openTerminal(at: path) }
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 24, height: 24).contentShape(Rectangle())
                .hoverTip("More", tint: Brand.primary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}

/// A server that ran before and is not running now.
struct StoppedRow: View {
    @EnvironmentObject var store: Store
    let server: KnownServer
    @State private var hover = false

    private var active: Bool { store.keyboardMode ? store.selectedKey == server.key : hover }

    private var stoppedLine: String {
        if server.folderMissing { return "its folder was deleted or moved" }
        guard let reason = server.stopReason else { return "stopped" }
        let ago = server.stoppedAt.map { formatDuration(Int(Date().timeIntervalSince($0))) + " ago · " } ?? ""
        return "stopped \(ago)\(reason)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle().strokeBorder(Color.secondary, lineWidth: 1).frame(width: 7, height: 7)
            Text(String(server.port)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.names[server.key] ?? server.title).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    Text(stoppedLine).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    if server.stopReason != nil {
                        Button("Why?") { store.explain(server) }
                            .buttonStyle(.plain).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Brand.primaryText)
                            .hoverTip("Why it stopped", tint: Brand.primary)
                    }
                }
            }
            Spacer(minLength: 4)
            if let label = store.busy[server.key] {
                Text(label).font(.caption).foregroundStyle(.secondary)
                ProgressView().controlSize(.small)
            } else {
                if active {
                    IconButton(symbol: store.isPinned(server.key) ? "pin.slash" : "pin", help: store.isPinned(server.key) ? "Unpin" : "Pin to top") { store.togglePin(server) }
                    IconButton(symbol: "xmark", help: "Forget  (⌘⌫)") { store.forget(server) }
                }
                if server.folderMissing {
                    Button { store.forget(server) } label: { Text("Forget") }
                        .buttonStyle(PillButton(tone: .quiet))
                        .hoverTip("Remove it from the list. Its folder is gone, so it can't start.", tint: Brand.primary)
                } else if server.canStart {
                    Button { store.start(server) } label: { Text("Start") }
                        .buttonStyle(PillButton(tone: .start))
                        .hoverTip("Start  (⌘R)", tint: Brand.green)
                } else {
                    Text("not running").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .frame(height: 44)
        .background(store.keyboardMode && active ? Brand.primary.opacity(0.14) : (active ? Color.primary.opacity(0.07) : .clear))
        .overlay(alignment: .leading) { if store.keyboardMode && active { Rectangle().fill(Brand.primary).frame(width: 3) } }
        .onHover { hover = $0; store.setHover(server.key, $0) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(store.names[server.key] ?? server.title), port \(server.port), stopped\(server.stopReason.map { ". \($0)" } ?? "")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if server.canStart { store.start(server) } }
        .accessibilityAction(named: "Start") { if server.canStart { store.start(server) } }
        .accessibilityAction(named: "Why did it stop") { store.explain(server) }
        .accessibilityAction(named: "Forget") { store.forget(server) }
        .contextMenu {
            if server.canStart { Button("Start") { store.start(server) } }
            if server.stopReason != nil { Button("Why it stopped…") { store.explain(server) } }
            Divider()
            Button(store.isPinned(server.key) ? "Unpin" : "Pin to top") { store.togglePin(server) }
            Button("Forget") { store.forget(server) }
        }
    }
}

struct TunnelLine: View {
    @ObservedObject var tunnel: Tunnel
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "globe").font(.caption2)
            switch tunnel.state {
            case .starting: Text("Creating public link…")
            case .running(let url):
                Button(url) { Actions.copy(url); Store.shared.flash("Public link copied: \(url)") }
                    .buttonStyle(.plain).underline().tip("Copy public link")
            case .failed(let why): Text("Public link failed (\(why))")
            }
        }
        .font(.caption).foregroundStyle(Brand.primaryText).lineLimit(1)
    }
}

/// Hover feedback that does not depend on system tooltips (they often stay hidden in a menu bar popover):
/// the button lights up and the footer says what it does.
struct HoverTip: ViewModifier {
    @EnvironmentObject var store: Store
    let text: String
    var tint: Color = .primary
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover ? tint.opacity(0.16) : .clear))
            .onHover { hover = $0; store.setTip($0 ? text : nil); $0 ? TipWindow.shared.show(text) : TipWindow.shared.hide() }
            .onDisappear { if hover { store.setTip(nil); TipWindow.shared.hide() } }
    }
}

extension View {
    func hoverTip(_ text: String, tint: Color = .primary) -> some View { modifier(HoverTip(text: text, tint: tint)) }
}

/// Borderless look with a small press-in, so a click is felt before anything else changes.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color?
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 24).contentShape(Rectangle())
                .foregroundStyle(tint ?? (enabled ? Color.primary : Color.secondary.opacity(0.5)))
        }
        .buttonStyle(PressStyle())
        .hoverTip(help, tint: tint ?? Brand.primary)
    }
}

/// The right-click menu for a running server, in the list and on the map.
struct ServerMenu: View {
    @EnvironmentObject var store: Store
    let entry: PortEntry

    var body: some View {
        if entry.web == .page { Button("Open in browser") { store.open(entry) } }
        Button(entry.copyLabel) { store.copyLocal(entry) }
        Divider()
        Button("Restart") { store.restart(entry) }.disabled(entry.container == nil && entry.restart == nil)
        Button("Show logs") { store.tail(entry) }
        Menu("Show logs in") { ForEach(store.terminals) { app in Button(app.name) { store.tailInTerminal(entry, app) } } }
        Button("Stop") { store.kill(entry) }
        Divider()
        Button(store.isPinned(entry.key) ? "Unpin" : "Pin to top") { store.togglePin(entry) }
        Button("Rename…") { store.rename(entry) }
        Button("Change port…") { store.askPort(entry) }.disabled(entry.container != nil || entry.restart == nil)
        if entry.web != .none {
            Button("Copy as curl") { store.copyCurl(entry) }
            Button("Copy Wi-Fi link") { store.copyLAN(entry) }
            Button("Show QR code for your phone…") { store.showQR(entry) }
        }
        if let path = entry.projectPath {
            Divider()
            ForEach(Editors.installed, id: \.name) { ed in Button("Open project in \(ed.name)") { store.openProject(path, in: ed.url) } }
            Button("Open Terminal in project") { Editors.openTerminal(at: path) }
        }
    }
}
