import AppKit
import ServiceManagement
import SwiftUI

/// Everything worth remembering between launches. No environment variables, so no secrets.
private struct SavedState: Codable {
    var known: [String: KnownServer] = [:]
    var names: [String: String] = [:]
    var pinned: Set<String> = []
}

/// A button shown next to a message, for example "Undo" after Stop.
struct UndoAction {
    var label: String
    var run: @MainActor () -> Void
}

@MainActor
final class Store: ObservableObject {
    @Published private(set) var entries: [PortEntry] = []
    @Published private(set) var stopped: [KnownServer] = []
    @Published private(set) var projects: [String] = []          // folders added by hand
    @Published private(set) var declaredKeys: Set<String> = []   // servers that come from a switchboard.json
    @Published var query = ""
    @Published private(set) var stack = StackMap.empty
    @Published private(set) var mapOffsets: [String: CGSize] = [:]   // where you dragged map nodes
    @Published private(set) var mapPan: CGSize = .zero
    @Published private(set) var mapZoom: CGFloat = 1
    @Published var logs: LogTail?
    @Published private(set) var muxSessions: [TerminalApp] = []   // filled in the background, because finding them runs processes
    @Published private(set) var update: ReleaseInfo?   // set only when a newer release exists
    @Published private(set) var updating = false
    @Published var checkForUpdates: Bool {
        didSet { UserDefaults.standard.set(checkForUpdates, forKey: "checkForUpdates"); if checkForUpdates { checkUpdate(force: false) } else { update = nil } }
    }
    @Published var showMap: Bool { didSet { UserDefaults.standard.set(showMap, forKey: "showMap"); if showMap { Task { await refresh() } } } }
    @Published var showAll = false
    @Published var message: String?
    @Published private(set) var undo: UndoAction?
    @Published var busy: [String: String] = [:]   // row key → what it is doing, e.g. "Restarting…"
    @Published var copiedID: String?
    @Published private(set) var hoverKey: String?
    @Published private(set) var selectedKey: String?     // row chosen with the arrow keys
    @Published private(set) var keyboardMode = false      // true once the arrow keys were used, until the pointer moves in
    @Published private(set) var backdropTint: Double = 0.12   // extra tint so text stays readable over the wallpaper
    @Published private(set) var tip: String?   // what the hovered icon does, shown in the footer
    @Published private(set) var recent: Set<String> = []   // servers that just appeared
    private var knownRunningKeys: Set<String>?
    private var refreshTick = 0
    @Published var armedKill: String?
    @Published private(set) var usage: [String: Usage] = [:]   // row key → CPU and memory
    @Published private(set) var icons: [String: NSImage] = [:]   // row key → the page's icon
    private var iconAttempts = Set<String>()   // server and icon path already tried, so a missing icon is not asked for every 3 seconds
    private var cpuSamples: [Int32: (ns: UInt64, at: Date)] = [:]
    @Published private(set) var editing: InlineEdit?   // the port or name being edited in its row
    @Published private(set) var names: [String: String] = [:]
    @Published private(set) var pinned: Set<String> = []
    @Published var showStopped: Bool { didSet { UserDefaults.standard.set(showStopped, forKey: "showStopped") } }
    @Published var notifyOnStop: Bool {
        didSet { UserDefaults.standard.set(notifyOnStop, forKey: "notifyOnStop"); if notifyOnStop { Notifier.requestPermission() } }
    }

    static let shared = Store()
    let tunnels = TunnelManager()

    private var known: [String: KnownServer] = [:]
    private var declared: [String: KnownServer] = [:]
    private var declaredStamps: [String: Date] = [:]
    private var dirty = false
    private var lastSave = Date()
    private let persistent: Bool
    private var messageTask: Task<Void, Never>?

    // Crash detection
    private var watching: [String: Watch] = [:]
    private var diagnoses: [String: Diagnosis] = [:]   // in memory only: log lines can hold secrets
    private var missing: [String: Int] = [:]
    private var expectedStops: [String: Date] = [:]

    /// Fixed sample data, no polling, no disk. Used for README screenshots.
    init(sample: [PortEntry], stopped: [KnownServer] = [], names: [String: String] = [:], pinned: Set<String> = [], stack: StackMap = .empty, showMap: Bool = false, usage: [String: Usage] = [:], icons: [String: NSImage] = [:]) {
        persistent = false
        showStopped = true
        notifyOnStop = false
        checkForUpdates = false
        entries = sample
        self.stack = stack
        self.showMap = showMap
        self.stopped = stopped
        self.names = names
        self.pinned = pinned
        self.usage = usage
        self.icons = icons
    }

    init() {
        persistent = true
        let d = UserDefaults.standard
        showMap = d.bool(forKey: "showMap")
        projects = d.stringArray(forKey: "projects") ?? []
        if let v = d.array(forKey: "mapView") as? [Double], v.count == 3 { mapPan = CGSize(width: v[0], height: v[1]); mapZoom = CGFloat(v[2]) }
        mapOffsets = (d.dictionary(forKey: "mapOffsets") as? [String: [Double]] ?? [:]).compactMapValues { $0.count == 2 ? CGSize(width: $0[0], height: $0[1]) : nil }
        showStopped = d.bool(forKey: "showStopped")
        notifyOnStop = d.object(forKey: "notifyOnStop") as? Bool ?? true
        checkForUpdates = d.object(forKey: "checkForUpdates") as? Bool ?? true
        load()
        Task { try? await Task.sleep(for: .seconds(6)); self.checkUpdate(force: false, minAge: 900) }   // at launch, unless it just asked
        if notifyOnStop { Notifier.requestPermission() }

        Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self, tunnels] _ in
            MainActor.assumeIsolated { tunnels.stopAll(); self?.persist(force: true) }
        }
    }

    // MARK: Derived lists

    var portQuery: Int? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, q.count <= 5, let n = Int(q), n > 0, n < 65536 else { return nil }
        return n
    }

    var visible: [PortEntry] {
        entries.filter { e in
            (showAll || e.kind != .other || portQuery == e.port) && matches(query, [displayName(e), e.title, e.group, e.command, String(e.port)])
        }
    }

    private func matches(_ q: String, _ fields: [String]) -> Bool {
        q.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(q) }
    }

    var count: Int { entries.filter { $0.kind != .other }.count }

    var groups: [ProjectGroup] {
        let running = visible
        let runningGroups = Set(running.map { pinned.contains($0.key) ? "Pinned" : $0.group })
        let stoppedVisible = stopped.filter { k in
            matches(query, [k.title, k.group, String(k.port)]) &&
            (showStopped || declaredKeys.contains(k.key) || runningGroups.contains(pinned.contains(k.key) ? "Pinned" : k.group))
        }

        var order: [String] = []
        var run: [String: [PortEntry]] = [:]
        var stop: [String: [KnownServer]] = [:]
        func name(_ key: String, _ group: String) -> String { pinned.contains(key) ? "Pinned" : group }

        for e in running { let g = name(e.key, e.group); if run[g] == nil { order.append(g) }; run[g, default: []].append(e) }
        for k in stoppedVisible { let g = name(k.key, k.group); if run[g] == nil && stop[g] == nil { order.append(g) }; stop[g, default: []].append(k) }

        order.sort { a, b in
            if a == "Pinned" { return true }
            if b == "Pinned" { return false }
            return false   // keep the scan's project order
        }
        return order.map { g in
            let path = g == "Pinned" ? nil : (run[g]?.first?.projectPath ?? stop[g]?.first?.projectPath)
            return ProjectGroup(name: g, path: path, running: run[g] ?? [], stopped: stop[g] ?? [])
        }
    }

    func displayName(_ e: PortEntry) -> String { names[e.key] ?? e.title }
    func isRenamed(_ e: PortEntry) -> Bool { names[e.key] != nil }
    func isPinned(_ key: String) -> Bool { pinned.contains(key) }

    // MARK: Refresh

    func refresh() async {
        let result = await Task.detached(priority: .utility) { Scanner.scan() }.value
        if result != entries { withAnimation(Motion.anim) { entries = result } }
        if let s = selectedKey, !navKeys.contains(s) { selectedKey = nil }
        if let ed = editing, !result.contains(where: { $0.key == ed.key }) || busy[ed.key] != nil { editing = nil }   // the server went away or got busy
        guard persistent else { return }
        refreshTick += 1
        if refreshTick % 20 == 0 { checkUpdate(force: false) }   // the app can run for days, so ask again while it runs
        if refreshTick % 4 == 1 { await refreshMux() }
        if showMap || (refreshTick % 5 == 0 && result.filter({ $0.kind != .other }).count >= 2) {
            let map = await Task.detached(priority: .utility) { Scanner.stack(entries: result) }.value
            if showMap { withAnimation(Motion.pop) { stack = map } }
            learn(map)
        }
        markNew(result)
        remember(result)
        detectStops(result)
        await sampleUsage(result)
        fetchIcons(result)
        persist()
    }

    /// One request per server for its icon, the one the page names or /favicon.ico. A restart or a newly found path tries again.
    private func fetchIcons(_ list: [PortEntry]) {
        let alive = Set(list.map(\.key))
        if icons.keys.contains(where: { !alive.contains($0) }) { icons = icons.filter { alive.contains($0.key) } }
        if iconAttempts.count > 500 { iconAttempts = [] }
        for e in list where e.web == .page && e.container == nil && e.kind != .other {
            let path = e.iconPath ?? "/favicon.ico"
            guard iconAttempts.insert("\(e.id)|\(path)").inserted else { continue }
            let (key, port, host) = (e.key, e.port, e.host)
            Task { [weak self] in
                let data = await Task.detached(priority: .utility) { Probe.fetchIcon(port: port, host: host, path: path) }.value
                guard let data, let image = NSImage(data: data), image.isValid else { return }
                self?.icons[key] = image
            }
        }
    }

    /// CPU needs two readings, so the first one for a server shows memory only. Containers have no process here and are skipped.
    private func sampleUsage(_ list: [PortEntry]) async {
        let roots: [(key: String, pid: Int32)] = list.filter { $0.kind != .other && $0.container == nil }
            .compactMap { e in (e.restart?.rootPid ?? e.pid).map { (e.key, $0) } }
        let readings = await Task.detached(priority: .utility) { roots.map { ($0.key, $0.pid, Proc.usage(of: $0.pid)) } }.value
        let now = Date()
        var next: [String: Usage] = [:], samples: [Int32: (ns: UInt64, at: Date)] = [:]
        for (key, pid, r) in readings {
            guard let r else { continue }
            samples[pid] = (r.cpuNs, now)
            let before = cpuSamples[pid]
            next[key] = Usage(cpu: before.map { Usage.cpuPercent(from: $0.ns, to: r.cpuNs, seconds: now.timeIntervalSince($0.at)) } ?? 0, memory: r.rss)
        }
        cpuSamples = samples
        if next != usage { usage = next }
    }

    /// Rows that show up after the first scan get a short green highlight.
    private func markNew(_ list: [PortEntry]) {
        let keys = Set(list.filter { $0.kind != .other }.map(\.key))
        defer { knownRunningKeys = keys }
        guard let before = knownRunningKeys else { return }
        let fresh = keys.subtracting(before)
        guard !fresh.isEmpty else { return }
        recent.formUnion(fresh)
        Task { try? await Task.sleep(for: .seconds(2)); withAnimation(Motion.anim) { recent.subtract(fresh) } }
    }

    /// Stopped servers: what we remember plus what each project's switchboard.json declares. The file wins on how to start.
    static func merge(known: [String: KnownServer], declared: [String: KnownServer], running: Set<String>) -> [KnownServer] {
        var all = known
        for (key, d) in declared {
            if var k = all[key] {
                k.title = d.title
                k.start = d.start ?? k.start
                k.containerID = d.containerID ?? k.containerID
                k.uses = Array(Set(k.uses ?? []).union(d.uses ?? [])).sorted()
                all[key] = k
            } else { all[key] = d }
        }
        return all.values.filter { !running.contains($0.key) }
    }

    /// Reads each project's switchboard.json when it changes.
    private func syncDeclared(roots: Set<String>) {
        for root in roots {
            let path = root + "/" + StackFile.fileName
            let stamp = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            if declaredStamps[root] == stamp { continue }
            declaredStamps[root] = stamp
            declared = declared.filter { $0.value.projectPath != root }
            if stamp != nil, let file = StackFile.load(root: root) { for k in file.servers(root: root) { declared[k.key] = k } }
        }
        let keys = Set(declared.keys)
        if keys != declaredKeys { declaredKeys = keys }
    }

    /// Remember who was seen using whom, so the right start order is known later when everything is down.
    private func learn(_ map: StackMap) {
        for e in map.edges where !e.broken && (e.count > 0 || e.configured) {
            guard var from = known[e.from], known[e.to] != nil else { continue }
            var uses = Set(from.uses ?? [])
            if uses.insert(e.to).inserted {
                from.uses = uses.sorted()
                known[e.from] = from
                dirty = true
            }
        }
    }

    private func remember(_ list: [PortEntry]) {
        let now = Date()
        let runningKeys = Set(list.map(\.key))

        for e in list where e.kind == .dev || e.kind == .docker {
            let k = KnownServer(key: e.key, port: e.port, title: e.title, group: e.group, projectPath: e.projectPath,
                                start: e.restart.map { KnownStart(exec: $0.exec, argv: $0.argv, cwd: $0.cwd) },
                                containerID: e.container?.id, lastSeen: now, uses: known[e.key]?.uses, containerName: e.container?.name)
            var old = known[e.key]
            old?.lastSeen = now
            if old != k { dirty = true }
            known[e.key] = k

            // Same server came back on another port (Vite does this): drop the old grey row.
            for (ok, o) in known where ok != e.key && !runningKeys.contains(ok) && o.title == e.title
                && o.projectPath == e.projectPath && o.start?.cwd == k.start?.cwd && k.start != nil {
                known[ok] = nil; dirty = true
            }
        }
        let cutoff = now.addingTimeInterval(-14 * 86400)
        for (k, v) in known where v.lastSeen < cutoff { known[k] = nil; dirty = true }

        syncDeclared(roots: Set(projects).union(known.values.compactMap(\.projectPath)).union(list.compactMap(\.projectPath)))
        let s = Self.merge(known: known, declared: declared, running: runningKeys)
            .sorted { ($0.group.lowercased(), $0.port) < ($1.group.lowercased(), $1.port) }
        if s != stopped { withAnimation(Motion.anim) { stopped = s } }
    }

    /// What we know about a server while it is alive, so we can explain it once it is gone.
    private struct Watch { var entry: PortEntry; var logPath: String?; var shellPid: Int32? }

    /// A server that was listening and is gone for two scans in a row. Works out why, before the evidence goes stale.
    private func detectStops(_ list: [PortEntry]) {
        let now = Set(list.filter { $0.kind != .other }.map(\.key))
        for k in now { missing[k] = nil }
        for (k, w) in Array(watching) where !now.contains(k) {
            let n = (missing[k] ?? 0) + 1
            guard n >= 2 else { missing[k] = n; continue }
            watching[k] = nil; missing[k] = nil

            let byUser = (expectedStops[k].map { Date().timeIntervalSince($0) < 120 } ?? false) || ExpectedStops.contains(k)
            let takenOver = list.first { $0.port == w.entry.port && $0.pid != w.entry.pid && $0.kind != .other }
            let d = Diagnose.run(entry: w.entry, byUser: byUser, logPath: w.logPath, shellPid: w.shellPid, takenOverBy: takenOver)
            diagnoses[k] = d
            if var kn = known[k] { kn.stopReason = d.reason; kn.stoppedAt = d.at; known[k] = kn; dirty = true }
            if notifyOnStop, !byUser {
                Notifier.post(title: "\(names[k] ?? w.entry.title) :\(w.entry.port) stopped", body: d.reason)
            }
        }
        for e in list where e.kind != .other {
            if watching[e.key]?.entry.pid != e.pid {
                watching[e.key] = Watch(entry: e, logPath: e.pid.flatMap { Proc.logFile($0) }, shellPid: e.pid.flatMap { Proc.ancestorShell($0) })
            } else {
                watching[e.key]?.entry = e
            }
        }
    }

    /// The "Why?" dialog for a stopped server.
    func explain(_ k: KnownServer) {
        let d = diagnoses[k.key]
        guard let reason = d?.reason ?? k.stopReason else { flash("Nothing was recorded about how this one stopped."); return }
        let when = (d?.at ?? k.stoppedAt).map { "Stopped \(formatDuration(Int(Date().timeIntervalSince($0)))) ago." } ?? ""
        var buttons: [ExplainChoice] = []
        if k.canStart { buttons.append(.start) }
        if d?.logPath != nil { buttons.append(.showLog) }
        if d?.reportPath != nil { buttons.append(.showReport) }
        switch Dialogs.explain(title: "Why \(k.title) :\(k.port) stopped", headline: reason, facts: d?.facts ?? [], lines: d?.logLines ?? [], when: when, buttons: buttons) {
        case .start: start(k)
        case .showLog: if let p = d?.logPath { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
        case .showReport: if let p = d?.reportPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
        case .close: break
        }
    }

    // MARK: Persistence

    private var stateURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Switchboard")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        known = s.known; names = s.names; pinned = s.pinned
    }

    private func persist(force: Bool = false) {
        guard persistent, dirty || force, force || Date().timeIntervalSince(lastSave) > 2 else { return }
        dirty = false; lastSave = Date()
        if let data = try? JSONEncoder().encode(SavedState(known: known, names: names, pinned: pinned)) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    // MARK: Messages

    func flash(_ text: String, undo: UndoAction? = nil) {
        message = text
        self.undo = undo
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(undo == nil ? 4 : 8))   // longer when there is something to click
            if !Task.isCancelled { self?.message = nil; self?.undo = nil }
        }
    }

    func runUndo() {
        let u = undo
        undo = nil
        message = nil
        u?.run()
    }

    /// Called each time the popover opens: read the wallpaper under it and set the tint that keeps text readable.
    func refreshBackdrop(screen: NSScreen?, dark: Bool) {
        let t = Backdrop.tint(screen: screen, dark: dark)
        if abs(t - backdropTint) > 0.005 { backdropTint = t }
    }

    // MARK: Shared stack file

    func addProject() {
        guard let picked = Dialogs.chooseFolder("Choose a project folder that has a switchboard.json") else { return }
        let root = StackFile.find(from: picked) ?? picked
        guard FileManager.default.fileExists(atPath: root + "/" + StackFile.fileName) else {
            flash("No switchboard.json in \(abbreviateHome(picked)). Use Save stack file on a running project, or run `switchboard export` there.")
            return
        }
        if !projects.contains(root) { projects.append(root); UserDefaults.standard.set(projects, forKey: "projects") }
        Task { await refresh() }
        flash("Added \((root as NSString).lastPathComponent). Press Start stack to bring it up.")
    }

    func removeProject(_ root: String) {
        projects.removeAll { $0 == root }
        UserDefaults.standard.set(projects, forKey: "projects")
        Task { await refresh() }
    }

    /// Writes switchboard.json into the project folder from what has been seen running there.
    func saveStackFile(_ g: ProjectGroup) {
        guard let root = g.path else { return }
        var servers = known
        for (k, d) in declared where servers[k] == nil { servers[k] = d }
        let file = StackFile.export(root: root, servers: Array(servers.values))
        guard !file.services.isEmpty else { flash("Nothing to save yet. Start this project's servers once so Switchboard can see them."); return }
        let path = root + "/" + StackFile.fileName
        if FileManager.default.fileExists(atPath: path),
           !Dialogs.confirm("Replace switchboard.json?", "\(abbreviateHome(path)) already exists. It will be rewritten from what Switchboard has seen.", ok: "Replace") { return }
        do {
            try file.write(to: root)
            flash("Saved \(file.services.count) service\(file.services.count == 1 ? "" : "s") to switchboard.json. Commit it so your team gets the same stack.")
        } catch { flash("Could not save: \(error.localizedDescription)") }
    }

    // MARK: Map layout

    func setMapOffset(_ id: String, _ size: CGSize) {
        mapOffsets[id] = size
        UserDefaults.standard.set(mapOffsets.mapValues { [Double($0.width), Double($0.height)] }, forKey: "mapOffsets")
    }

    func setMapView(pan: CGSize, zoom: CGFloat) {
        mapPan = CGSize(width: min(max(pan.width, -260), 260), height: min(max(pan.height, -260), 260))
        mapZoom = min(max(zoom, 0.5), 2.2)
        UserDefaults.standard.set([Double(mapPan.width), Double(mapPan.height), Double(mapZoom)], forKey: "mapView")
    }

    var mapIsCustomised: Bool { !mapOffsets.isEmpty || mapPan != .zero || abs(mapZoom - 1) > 0.01 }

    func resetMapLayout() {
        mapOffsets = [:]; mapPan = .zero; mapZoom = 1
        UserDefaults.standard.removeObject(forKey: "mapOffsets")
        UserDefaults.standard.removeObject(forKey: "mapView")
    }

    // MARK: Hover and shortcuts

    func setHover(_ key: String, _ on: Bool) {
        if on { hoverKey = key; if keyboardMode { keyboardMode = false } } else if hoverKey == key { hoverKey = nil }
    }

    /// The row shortcuts act on: the selected one while using the keyboard, otherwise the one under the pointer.
    var activeKey: String? { keyboardMode ? selectedKey : hoverKey }

    /// Every row in the order it appears on screen.
    var navKeys: [String] { groups.flatMap { $0.running.map(\.key) + $0.stopped.map(\.key) } }

    func moveSelection(_ delta: Int) {
        let keys = navKeys
        guard !keys.isEmpty else { return }
        keyboardMode = true
        setTip(nil)
        if let cur = selectedKey, let i = keys.firstIndex(of: cur) {
            selectedKey = keys[min(max(i + delta, 0), keys.count - 1)]
        } else {
            selectedKey = delta >= 0 ? keys.first : keys.last
        }
    }

    func clearSelection() { selectedKey = nil; keyboardMode = false }

    /// Return: do the main thing for the selected row, or for the first match if nothing is selected.
    func activate() {
        if let key = activeKey ?? (query.isEmpty ? nil : visible.first?.key) {
            if let e = entries.first(where: { $0.key == key }) { primary(e); return }
            if let k = stopped.first(where: { $0.key == key }), k.canStart { start(k); return }
        }
        if let first = visible.first { primary(first) }
    }

    func setTip(_ text: String?) { if tip != text { tip = text } }

    /// Shown in the footer while the pointer is on a row.
    var hoverHint: String? {
        guard let key = activeKey else { return nil }
        if let e = entries.first(where: { $0.key == key }) {
            return e.web == .page ? "⌘O Open · ⌘C Copy · ⌘R Restart · ⌘L Logs · ⌘⌫ Stop"
                                  : "⌘C Copy · ⌘R Restart · ⌘L Logs · ⌘⌫ Stop"
        }
        return stopped.contains { $0.key == key } ? "⌘R Start · ⌘⌫ Forget" : nil
    }

    /// ⌘ shortcuts act on the row under the pointer. Returns true if one was handled.
    func shortcut(_ ch: String, deleteKey: Bool) -> Bool {
        guard logs == nil, let key = activeKey else { return false }   // in the log screen ⌘C copies the selected text
        if let e = entries.first(where: { $0.key == key }) {
            if deleteKey { kill(e); return true }
            switch ch {
            case "o": e.web == .none ? copyLocal(e) : open(e)
            case "c": copyLocal(e)
            case "r": if e.container != nil || e.restart != nil { restart(e) } else { flash("Switchboard can't restart this one. It doesn't know how it was started.") }
            case "l": tail(e)
            case "p": togglePin(e)
            default: return false
            }
            return true
        }
        if let k = stopped.first(where: { $0.key == key }) {
            if deleteKey { forget(k); return true }
            switch ch {
            case "r", "s": if k.canStart { start(k) }
            case "p": togglePin(k)
            default: return false
            }
            return true
        }
        return false
    }

    // MARK: Row actions

    func open(_ e: PortEntry) { NSWorkspace.shared.open(e.localURL) }

    /// What Return does in the filter box: open pages, copy everything else.
    func primary(_ e: PortEntry) { e.web == .page ? open(e) : copyLocal(e) }

    func kill(_ e: PortEntry) {
        if e.kind == .database || e.kind == .other || e.container != nil, armedKill != e.id {
            armedKill = e.id
            Task { try? await Task.sleep(for: .seconds(3)); if armedKill == e.id { armedKill = nil } }
            return
        }
        armedKill = nil
        Task {
            // Magic moment: if other running servers are connected to this one, say so before pulling the plug.
            let snapshot = entries
            let map = await Task.detached(priority: .userInitiated) { Scanner.stack(entries: snapshot) }.value
            let live = map.usedBy(e.key, live: true).filter { $0.role != .missing }
            let named = map.usedBy(e.key, live: false).filter { $0.role != .missing }
            if !live.isEmpty || !named.isEmpty {
                func list(_ n: [StackNode]) -> String { n.map { "\($0.title)\($0.port.map { " :\($0)" } ?? "")" + ($0.project.map { "  (\($0))" } ?? "") }.joined(separator: "\n") }
                var title = "", body = ""
                if !live.isEmpty {
                    title = "\(live.count) running server\(live.count == 1 ? " is" : "s are") connected to \(displayName(e))"
                    body = list(live) + "\n\nThey will lose the connection if you stop it."
                    if !named.isEmpty { body += "\n\nThe .env files of these also point at it, but no connection was seen:\n" + list(named) }
                } else {
                    title = "Some projects point at \(displayName(e))"
                    body = list(named) + "\n\nTheir .env files use this port. Switchboard has not seen them connected, so stopping it may not affect them."
                }
                guard Dialogs.confirm(title, body, ok: "Stop anyway") else { return }
            }
            expectedStops[e.key] = Date()
            let again = known[e.key].flatMap { $0.canStart ? $0 : nil }
            perform(e.key, label: "Stopping…", success: "Stopped \(displayName(e)) :\(e.port)",
                    undo: again.map { k in UndoAction(label: "Undo") { self.start(k) } }) { try await Actions.kill(e) }
        }
    }

    func restart(_ e: PortEntry) {
        expectedStops[e.key] = Date()
        perform(e.key, label: "Restarting…",
                success: e.container == nil ? "Restarted :\(e.port). Its output is saved in ~/Library/Logs/Switchboard, so Logs works now." : "Restarted :\(e.port)") {
            try await Actions.restart(e)
        }
    }

    /// Asks for a port, then restarts the server there.
    // MARK: Editing in the row

    struct InlineEdit: Equatable { enum Field { case port, name }; var key: String; var field: Field }

    /// Double click on a port or a name. A port that can't be changed says why instead of opening a field that would fail.
    func beginEdit(_ e: PortEntry, _ field: InlineEdit.Field) {
        guard busy[e.key] == nil else { return }
        if field == .port && (e.container != nil || e.restart == nil) { flash("Switchboard can't restart this one, so it can't change its port."); return }
        editing = InlineEdit(key: e.key, field: field)
    }

    func cancelEdit() { editing = nil }

    /// A field that lost focus cancels only its own edit, so starting another row's edit is not undone by the old field.
    func cancelEdit(key: String, field: InlineEdit.Field) { if editing == InlineEdit(key: key, field: field) { editing = nil } }

    /// Returns false when the text is not usable, so the field stays open with the message showing.
    @discardableResult func commitPort(_ e: PortEntry, text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        if busy[e.key] != nil { editing = nil; return true }   // it started doing something else while the field was open
        if t.isEmpty || t == String(e.port) { editing = nil; return true }
        guard let port = Int(t), (1024...65535).contains(port) else { flash("Use a port between 1024 and 65535."); return false }
        guard Ports.isFree(port) else { flash("Port \(port) is already in use."); return false }
        editing = nil
        changePort(e, to: port)
        return true
    }

    func commitName(_ e: PortEntry, text: String) {
        editing = nil
        let t = text.trimmingCharacters(in: .whitespaces)
        let new: String? = (t.isEmpty || t == e.title) ? nil : t
        guard names[e.key] != new else { return }
        names[e.key] = new
        dirty = true; persist(force: true)
    }

    func askPort(_ e: PortEntry) {
        let suggestion = Ports.nextFree(after: e.port, taken: Set(entries.map(\.port)))
        guard let text = Dialogs.prompt("Change port of \(displayName(e))", "Restarts it on another port. It is on :\(e.port) now.", value: String(suggestion)),
              !text.isEmpty else { return }
        guard let port = Int(text), (1024...65535).contains(port) else { flash("Use a port between 1024 and 65535."); return }
        changePort(e, to: port)
    }

    func changePort(_ e: PortEntry, to port: Int) {
        guard e.container == nil, e.restart != nil else { flash("Switchboard can't restart this one, so it can't change its port."); return }
        guard port != e.port else { return }
        guard Ports.isFree(port) else { flash("Port \(port) is already in use."); return }
        let oldKey = e.key, newKey = String(e.key.dropLast(String(e.port).count)) + String(port)
        let oldKnown = known[oldKey]
        expectedStops[oldKey] = Date()
        busy[oldKey] = "Moving to :\(port)…"
        Task {
            defer { busy[oldKey] = nil }
            do { try await Actions.restart(e, port: port) } catch { flash(error.localizedDescription); return }
            for _ in 0..<60 where !Probe.isListening(port) { try? await Task.sleep(for: .milliseconds(250)) }
            await refresh()
            let back = UndoAction(label: "Undo") {
                if let now = self.entries.first(where: { $0.key == newKey }) { self.changePort(now, to: e.port) }
                else if let k = oldKnown { self.start(k) }
            }
            if Probe.isListening(port) {
                if let n = names[oldKey] { names[newKey] = n; names[oldKey] = nil }
                if pinned.contains(oldKey) { pinned.remove(oldKey); pinned.insert(newKey) }
                known[oldKey] = nil; stopped.removeAll { $0.key == oldKey }
                dirty = true; persist(force: true)
                flash("Moved \(displayName(e)) to :\(port).", undo: back)
            } else if entries.contains(where: { $0.key == oldKey }) {
                flash("It came back on :\(e.port). This server ignores the port setting, so it has to be changed in its own config.")
            } else {
                flash("Nothing is listening on :\(port) yet. It may be slow to start, or ignore the port setting.", undo: back)
            }
        }
    }

    /// Who holds the port a stopped server wants, or nil if it is free.
    private func holder(of k: KnownServer) -> String? {
        guard !Ports.isFree(k.port) else { return nil }
        if let e = entries.first(where: { $0.port == k.port }) { return "\(displayName(e))\(e.projectName.map { " (\($0))" } ?? "")" }
        return "another process"
    }

    func start(_ k: KnownServer) {
        if k.folderMissing, let cwd = k.start?.cwd {
            if Dialogs.confirm("\(k.title) can't start", "Its folder \(abbreviateHome(cwd)) was deleted or moved, so there is nothing to start. Remove it from the list?", ok: "Forget it") { forget(k) }
            return
        }
        if let who = holder(of: k) {
            guard k.containerID == nil, k.start != nil else {
                flash("Port \(k.port) is in use by \(who), and this one can't move to another port. Stop \(who) first.")
                return
            }
            let next = Ports.nextFree(after: k.port, taken: Set(entries.map(\.port)))
            guard Dialogs.confirm("Port \(k.port) is in use", "\(who) is using it, so \(k.title) would fail to start. Start it on :\(next) instead?", ok: "Start on :\(next)") else { return }
            startMoved(k, to: next)
            return
        }
        perform(k.key, label: "Starting…", success: "Starting \(k.title) on :\(k.port). It can take a few seconds to show up.", settle: 2.0) {
            try await Actions.start(k)
        }
    }

    private func startMoved(_ k: KnownServer, to port: Int) {
        let oldKey = k.key, newKey = String(k.key.dropLast(String(k.port).count)) + String(port)
        busy[oldKey] = "Starting on :\(port)…"
        Task {
            defer { busy[oldKey] = nil }
            do { try await Actions.start(k, port: port) } catch { flash(error.localizedDescription); return }
            for _ in 0..<60 where !Probe.isListening(port) { try? await Task.sleep(for: .milliseconds(250)) }
            await refresh()
            guard Probe.isListening(port) else { flash("Nothing is listening on :\(port) yet. It may be slow to start, or ignore the port setting."); return }
            if let n = names[oldKey] { names[newKey] = n; names[oldKey] = nil }
            if pinned.contains(oldKey) { pinned.remove(oldKey); pinned.insert(newKey) }
            known[oldKey] = nil; stopped.removeAll { $0.key == oldKey }
            dirty = true; persist(force: true)
            flash("Started \(k.title) on :\(port), because :\(k.port) was taken.")
        }
    }

    func forget(_ k: KnownServer) { known[k.key] = nil; stopped.removeAll { $0.key == k.key }; dirty = true; persist(force: true) }

    // MARK: Updates

    /// Quietly, at most every few hours. `force` is for the menu item: it always asks and always answers.
    func checkUpdate(force: Bool, minAge: TimeInterval = 10_800) {
        let d = UserDefaults.standard
        if !force {
            guard checkForUpdates, Updates.current != "dev" else { return }
            if let last = d.object(forKey: "lastUpdateCheck") as? Date, Date().timeIntervalSince(last) < minAge { return }
        }
        Task {
            switch await Updates.latest() {
            case .success(let r):
                d.set(Date(), forKey: "lastUpdateCheck")
                let newer = Updates.isNewer(r.version, than: Updates.current)
                if checkForUpdates || force { update = newer ? r : nil }
                if force { flash(newer ? "Version \(r.version) is available." : "You have the latest version, \(Updates.current).") }
            case .failure(let why):
                if force { flash(why.text) }   // a background check that fails stays silent and tries again later
            }
        }
    }

    func installUpdate() {
        guard let r = update, !updating else { return }
        let notes = r.notes.split(separator: "\n").prefix(8).joined(separator: "\n")
        guard let brew = Updates.brew else {
            if Dialogs.confirm("Version \(r.version) is available", "You installed Switchboard from a zip, so download the new one from GitHub and replace the old app.\n\n\(notes)", ok: "Open the download page") { NSWorkspace.shared.open(r.page) }
            return
        }
        guard Dialogs.confirm("Update to \(r.version)?", "Switchboard updates with Homebrew, then restarts. Your servers keep running.\n\n\(notes)", ok: "Update") else { return }
        updating = true
        flash("Updating to \(r.version). This can take a minute.")
        Task {
            let problem = await Updates.upgrade(using: brew, to: r.version)
            updating = false
            if let problem { flash(problem) } else { Updates.relaunch() }
        }
    }

    /// Logs open inside the popover. Terminal is still there for people who want it.
    func tail(_ e: PortEntry) {
        if logs?.key == e.key { return }
        do {
            let t = LogTail(source: try Actions.logSource(e), title: "\(displayName(e)) :\(e.port)", key: e.key)
            logs?.stop()
            t.start()
            withAnimation(Motion.anim) { logs = t }
        } catch { flash(error.localizedDescription) }
    }

    func closeLogs() {
        logs?.stop()
        withAnimation(Motion.anim) { logs = nil }
    }

    /// Terminal apps, then the tmux and zellij sessions open right now. Reads stored values only, so it is safe in a view.
    var terminals: [TerminalApp] { TerminalApp.apps + muxSessions }

    func refreshMux() async {
        let found = await Task.detached(priority: .utility) { Multiplexers.scan() }.value
        if found != muxSessions { muxSessions = found }
    }

    /// True once a terminal was picked and is still installed.
    var hasLogTerminal: Bool {
        guard let id = UserDefaults.standard.string(forKey: "logTerminal") else { return false }
        return terminals.contains { $0.id == id }
    }

    /// The terminal last used for logs, if it is still installed.
    var logTerminal: TerminalApp {
        let id = UserDefaults.standard.string(forKey: "logTerminal")
        return terminals.first { $0.id == id } ?? TerminalApp.apps.first ?? .fallback
    }

    /// Picked in the settings menu: remembered without opening anything.
    func setLogTerminal(_ app: TerminalApp) {
        UserDefaults.standard.set(app.id, forKey: "logTerminal")
        objectWillChange.send()
    }

    /// Hands a server's log to a terminal app and remembers the choice.
    func tailInTerminal(_ e: PortEntry, _ app: TerminalApp) {
        do { try Actions.tail(e, in: app); UserDefaults.standard.set(app.id, forKey: "logTerminal"); objectWillChange.send() }
        catch { flash(error.localizedDescription) }
    }

    func openLogsInTerminal(_ app: TerminalApp) {
        guard let e = entries.first(where: { $0.key == logs?.key }) else { flash("This server has stopped, so there is nothing to follow."); return }
        tailInTerminal(e, app)
    }

    /// Esc in the log screen: clear the filter first, then go back. Returns true if it did something.
    func escapeLogs() -> Bool {
        guard let t = logs else { return false }
        if !t.query.isEmpty { t.query = "" } else { closeLogs() }
        return true
    }

    private func perform(_ key: String, label: String, success: String, undo: UndoAction? = nil, settle: Double = 0.6, _ work: @escaping () async throws -> Void) {
        busy[key] = label
        Task {
            do { try await work(); flash(success, undo: undo) } catch { flash(error.localizedDescription) }
            try? await Task.sleep(for: .seconds(settle))
            await refresh()
            busy[key] = nil
        }
    }

    // MARK: Copy and share

    func copyLocal(_ e: PortEntry) {
        Actions.copy(e.address)
        flash("Copied \(e.address)")
        markCopied(e.id)
    }

    func copyCurl(_ e: PortEntry) {
        let cmd = e.curl
        Actions.copy(cmd)
        flash("Copied \(cmd)")
        markCopied(e.id)
    }

    func markCopied(_ id: String) {
        copiedID = id
        Task { try? await Task.sleep(for: .seconds(1.6)); if copiedID == id { copiedID = nil } }
    }

    func copyLAN(_ e: PortEntry) {
        guard let ip = Actions.lanAddress() else { flash("No network address found"); return }
        let url = "http://\(ip):\(e.port)"
        Actions.copy(url)
        flash(e.lanExposed ? "Copied \(url). Anyone on your Wi-Fi can open it." : "Copied \(url), but this server only listens on localhost, so other devices can't reach it.")
    }

    func showQR(_ e: PortEntry) {
        guard let ip = Actions.lanAddress() else { flash("No network address found. Connect to Wi-Fi first."); return }
        let url = "http://\(ip):\(e.port)"
        let note = e.lanExposed
            ? "Scan with your phone's camera. The phone must be on the same Wi-Fi."
            : "Heads up: this server only listens on localhost, so a phone can't reach it yet. Start it with a host option, for example --host 0.0.0.0."
        if Dialogs.qr(title: "Open \(displayName(e)) on your phone", url: url, note: note) { Actions.copy(url); flash("Copied \(url)") }
    }

    func toggleTunnel(_ e: PortEntry) {
        if tunnels.tunnels[e.port] != nil { tunnels.stop(port: e.port); return }
        do { try tunnels.start(port: e.port); flash("Starting a public link. It is copied as soon as it is ready.") } catch { flash(error.localizedDescription) }
    }

    // MARK: Names and pins

    func togglePin(_ e: PortEntry) { setPinned(e.key, !pinned.contains(e.key)) }
    func togglePin(_ k: KnownServer) { setPinned(k.key, !pinned.contains(k.key)) }

    private func setPinned(_ key: String, _ on: Bool) {
        if on { pinned.insert(key) } else { pinned.remove(key) }
        dirty = true; persist(force: true)
    }

    func rename(entry e: PortEntry, to name: String) { names[e.key] = name; dirty = true; persist(force: true) }

    func rename(_ e: PortEntry) {
        guard let new = Dialogs.prompt("Rename :\(e.port)", "Leave empty to go back to “\(e.title)”.", value: names[e.key] ?? "") else { return }
        names[e.key] = new.isEmpty ? nil : new
        dirty = true; persist(force: true)
    }

    // MARK: Whole project

    func stopAll(_ g: ProjectGroup) {
        let targets = g.running.filter { $0.kind != .other }
        guard !targets.isEmpty,
              Dialogs.confirm("Stop \(targets.count) server\(targets.count == 1 ? "" : "s") in \(g.name)?",
                              targets.map { "\(displayName($0)) :\($0.port)" }.joined(separator: "\n"), ok: "Stop all") else { return }
        flash("Stopping \(targets.count) server\(targets.count == 1 ? "" : "s")…")
        for e in targets { expectedStops[e.key] = Date(); busy[e.key] = "Stopping…" }
        Task {
            var failed = 0
            for e in targets { do { try await Actions.kill(e) } catch { failed += 1 } }
            try? await Task.sleep(for: .milliseconds(600))
            await refresh()
            for e in targets { busy[e.key] = nil }
            let back = targets.compactMap { known[$0.key] }.filter(\.canStart)
            flash(failed == 0 ? "Stopped everything in \(g.name)." : "\(failed) server\(failed == 1 ? "" : "s") could not be stopped.",
                  undo: back.isEmpty ? nil : UndoAction(label: "Undo") { self.startServers(back) })
        }
    }

    func restartAll(_ g: ProjectGroup) {
        let targets = g.running.filter { $0.container != nil || $0.restart != nil }
        guard !targets.isEmpty else { flash("Nothing here can be restarted."); return }
        flash("Restarting \(targets.count) server\(targets.count == 1 ? "" : "s")…")
        for e in targets { expectedStops[e.key] = Date(); busy[e.key] = "Restarting…" }
        Task {
            for e in targets { try? await Actions.restart(e) }
            try? await Task.sleep(for: .seconds(1))
            await refresh()
            for e in targets { busy[e.key] = nil }
            flash("Restarted everything in \(g.name).")
        }
    }

    /// Start everything that is stopped in this project, dependencies first, waiting for each tier to come up.
    func startAll(_ g: ProjectGroup) { startServers(g.stopped.filter(\.canStart)) }

    func startServers(_ all: [KnownServer]) {
        // Skip servers whose port someone else holds. Starting them would only fail after a minute of waiting.
        let blocked = all.filter { holder(of: $0) != nil }
        let startable = all.filter { k in !blocked.contains(where: { $0.key == k.key }) }
        if !blocked.isEmpty {
            let list = blocked.map { "\($0.title) :\($0.port), used by \(holder(of: $0) ?? "another process")" }.joined(separator: "\n")
            if startable.isEmpty { flash("Nothing started. \(blocked.count == 1 ? "Its port is" : "Their ports are") taken. Stop what holds \(blocked.count == 1 ? "it" : "them"), or use Change port."); return }
            guard Dialogs.confirm("\(blocked.count) port\(blocked.count == 1 ? " is" : "s are") taken", list + "\n\nStart the rest and skip \(blocked.count == 1 ? "this one" : "these")?", ok: "Start the rest") else { return }
        }
        guard !startable.isEmpty else { return }
        let levels = StartPlan.levels(startable: startable, pool: stopped + startable)
        let plan = StartPlan.describe(levels)
        flash(levels.count > 1 ? "Starting in order: \(plan)" : "Starting \(plan)…")
        Task {
            let failed = await StartPlan.run(levels) { key, text in Task { @MainActor in self.busy[key] = text } }
            try? await Task.sleep(for: .milliseconds(400))
            await refresh()
            if let f = failed {
                flash("\(f.title) :\(f.port) didn't come up within a minute, so nothing after it was started. Check ~/Library/Logs/Switchboard.")
            } else {
                flash(levels.count > 1 ? "Stack is up: \(plan)" : "\(plan) is up.")
            }
        }
    }

    func openProject(_ path: String, in app: URL) { Editors.open(path, with: app) }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { flash("Launch at login needs the app in /Applications (./build.sh install)") }
            objectWillChange.send()
        }
    }
}
