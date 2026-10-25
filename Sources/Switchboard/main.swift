import CoreImage
import SwiftUI
import Foundation
if let first = CommandLine.arguments.dropFirst().first, CLI.commands.contains(first) {
    exit(CLI.run(Array(CommandLine.arguments.dropFirst())))
}

if CommandLine.arguments.contains("--scan") {
    for e in Scanner.scan() {
        print("\(e.port)\t\(e.kind.rawValue)\t\(e.title)\t[\(e.group)]\tpid=\(e.pid.map(String.init) ?? "-")\tup=\(e.uptime ?? "-")\tweb=\(e.web.rawValue)\tlan=\(e.lanExposed)\troot=\(e.restart.map { String($0.rootPid) } ?? "-")\ttitle=\(e.pageTitle ?? "-")\ticon=\(e.iconPath ?? "-")\tmem=\((e.restart?.rootPid ?? e.pid).flatMap { Proc.usage(of: $0) }.map { Usage.memoryText($0.rss) } ?? "-")\t\(e.command.prefix(80))")
    }
    exit(0)
}
// Debug helper: `Switchboard --tip "text"` shows the tooltip bubble for a few seconds.
if let i = CommandLine.arguments.firstIndex(of: "--tip"), CommandLine.arguments.count > i + 1 {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        TipWindow.shared.show(CommandLine.arguments[i + 1], delay: 0)
        RunLoop.current.run(until: Date().addingTimeInterval(4))
    }
    exit(0)
}

// Debug helpers: `Switchboard --plan <group>` prints the start order; `--act start-stack <group>` runs it.
func loadKnown() -> [KnownServer] {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Switchboard/state.json")
    struct S: Codable { var known: [String: KnownServer] }
    guard let data = try? Data(contentsOf: url), let st = try? JSONDecoder().decode(S.self, from: data) else { return [] }
    let running = Set(Scanner.scan().map(\.key))
    return st.known.values.filter { !running.contains($0.key) }
}
if let i = CommandLine.arguments.firstIndex(of: "--plan"), CommandLine.arguments.count > i + 1 {
    let stopped = loadKnown()
    let levels = StartPlan.levels(startable: stopped.filter { $0.group == CommandLine.arguments[i + 1] && $0.canStart }, pool: stopped)
    for (n, tier) in levels.enumerated() { print("tier \(n + 1): " + tier.map { "\($0.title) :\($0.port) [\($0.group)]" }.joined(separator: ", ")) }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--act"), CommandLine.arguments.count > i + 2, CommandLine.arguments[i + 1] == "start-stack" {
    let stopped = loadKnown()
    let levels = StartPlan.levels(startable: stopped.filter { $0.group == CommandLine.arguments[i + 2] && $0.canStart }, pool: stopped)
    print("plan:", StartPlan.describe(levels))
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        let failed = await StartPlan.run(levels) { key, text in if let text { print("  \(key.split(separator: "/").last ?? ""): \(text)") } }
        print(failed.map { "FAILED: \($0.title) :\($0.port)" } ?? "all up")
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// Debug helper: `Switchboard --diagnose-test` runs the "why did it stop?" engine against real processes.
if CommandLine.arguments.contains("--diagnose-test") {
    let tmp = NSTemporaryDirectory() + "sbdiag-\(getpid())"
    try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    func entry(pid: Int32, exec: String) -> PortEntry {
        PortEntry(id: "t", port: 9999, host: "127.0.0.1", lanExposed: false, kind: .dev, title: "Test", pid: pid, command: exec, projectName: "t",
                  projectPath: nil, group: "t", uptime: nil, container: nil, web: .none, restart: nil)
    }
    func launch(_ exe: String, _ args: [String], log: String? = nil) -> Process {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        if let log { FileManager.default.createFile(atPath: log, contents: nil); let h = FileHandle(forWritingAtPath: log); p.standardOutput = h; p.standardError = h }
        p.terminationHandler = { ExitRegistry.record(pid: $0.processIdentifier, status: $0.terminationStatus, signaled: $0.terminationReason == .uncaughtSignal) }
        try! p.run(); return p
    }
    func show(_ title: String, _ d: Diagnosis) {
        print("== \(title)\n   reason: \(d.reason)"); for f in d.facts { print("   - \(f)") }
        if !d.logLines.isEmpty { print("   log: \(d.logLines.last!)") }
    }

    let killed = launch("/bin/sleep", ["60"]); usleep(200_000); kill(killed.processIdentifier, SIGKILL); killed.waitUntilExit(); usleep(200_000)
    show("kill -9", Diagnose.run(entry: entry(pid: killed.processIdentifier, exec: "/bin/sleep"), byUser: false, logPath: nil, shellPid: nil, takenOverBy: nil))

    let termed = launch("/bin/sleep", ["60"]); usleep(200_000); kill(termed.processIdentifier, SIGTERM); termed.waitUntilExit(); usleep(200_000)
    show("kill (SIGTERM)", Diagnose.run(entry: entry(pid: termed.processIdentifier, exec: "/bin/sleep"), byUser: false, logPath: nil, shellPid: nil, takenOverBy: nil))

    let log1 = tmp + "/a.log"
    let crashed = launch("/bin/sh", ["-c", "echo 'starting'; echo \"Error: Cannot find module 'left-pad'\"; exit 1"], log: log1); crashed.waitUntilExit(); usleep(200_000)
    show("exit 1 with a module error", Diagnose.run(entry: entry(pid: crashed.processIdentifier, exec: "/bin/sh"), byUser: false, logPath: log1, shellPid: nil, takenOverBy: nil))

    let log2 = tmp + "/b.log"
    try? "listening...\nError: listen EADDRINUSE: address already in use :::3000\n".write(toFile: log2, atomically: true, encoding: .utf8)
    show("port clash in the log", Diagnose.run(entry: entry(pid: 1, exec: "node"), byUser: false, logPath: log2, shellPid: nil, takenOverBy: nil))

    let log3 = tmp + "/c.log"
    try? "FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory\n".write(toFile: log3, atomically: true, encoding: .utf8)
    show("heap out of memory in the log", Diagnose.run(entry: entry(pid: 1, exec: "node"), byUser: false, logPath: log3, shellPid: nil, takenOverBy: nil))

    let reports = tmp + "/reports"; try? FileManager.default.createDirectory(atPath: reports, withIntermediateDirectories: true)
    try? "{\"app_name\":\"node\"}\n{\"pid\":4242,\"exception\":{\"type\":\"EXC_BAD_ACCESS\",\"signal\":\"SIGSEGV\"}}".write(toFile: reports + "/node-2026-10-21-101010.ips", atomically: true, encoding: .utf8)
    show("macOS crash report", Diagnose.run(entry: entry(pid: 4242, exec: "/opt/homebrew/bin/node"), byUser: false, logPath: nil, shellPid: nil, takenOverBy: nil, reportsDir: reports))

    show("you pressed Stop", Diagnose.run(entry: entry(pid: 1, exec: "node"), byUser: true, logPath: nil, shellPid: nil, takenOverBy: nil))
    show("no evidence at all", Diagnose.run(entry: entry(pid: 999999, exec: "node"), byUser: false, logPath: nil, shellPid: nil, takenOverBy: nil))
    try? FileManager.default.removeItem(atPath: tmp)
    exit(0)
}

// Debug helper: `Switchboard --nav-test` checks the arrow-key selection logic.
if CommandLine.arguments.contains("--nav-test") {
    MainActor.assumeIsolated {
        func e(_ port: Int, _ group: String, _ title: String) -> PortEntry {
            PortEntry(id: "\(port)", port: port, host: "127.0.0.1", lanExposed: false, kind: .dev, title: title, pid: 1, command: "", projectName: group,
                      projectPath: "/p/\(group)", group: group, uptime: nil, container: nil, web: .page, restart: nil)
        }
        let stopped = KnownServer(key: "/p/b:4000", port: 4000, title: "Storybook", group: "b", projectPath: "/p/b", start: nil, containerID: nil, lastSeen: Date())
        let s = Store(sample: [e(5173, "a", "Vite"), e(3000, "b", "Next.js"), e(3001, "b", "Node.js")], stopped: [stopped])
        func name(_ k: String?) -> String { k.map { ($0 as NSString).lastPathComponent } ?? "none" }
        print("order:", s.navKeys.map(name).joined(separator: " → "))
        print("start: selected=\(name(s.selectedKey)) active=\(name(s.activeKey))")
        s.moveSelection(1); print("down:  selected=\(name(s.selectedKey)) active=\(name(s.activeKey))")
        s.moveSelection(1); s.moveSelection(1); print("down x2: selected=\(name(s.selectedKey))")
        s.moveSelection(1); s.moveSelection(1); s.moveSelection(1); print("down past the end: selected=\(name(s.selectedKey)) (should stay on the last)")
        s.moveSelection(-1); print("up:    selected=\(name(s.selectedKey))")
        s.setHover("/p/a:5173", true); print("pointer enters Vite: keyboardMode=\(s.keyboardMode) active=\(name(s.activeKey))")
        s.moveSelection(-1); print("up again: keyboardMode=\(s.keyboardMode) active=\(name(s.activeKey))")
        s.clearSelection(); print("esc:   selected=\(name(s.selectedKey)) keyboardMode=\(s.keyboardMode)")
        s.query = "next"; print("filter 'next': order =", s.navKeys.map(name).joined(separator: ", "))
        s.moveSelection(-1); print("up with filter: selected=\(name(s.selectedKey)) (first press from nothing goes to the last match)")
    }
    exit(0)
}

// Debug helper: `Switchboard --declared-test <folder>` shows what a switchboard.json gives a machine that has never run the project.
if let i = CommandLine.arguments.firstIndex(of: "--declared-test"), CommandLine.arguments.count > i + 1 {
    MainActor.assumeIsolated {
        let root = (CommandLine.arguments[i + 1] as NSString).expandingTildeInPath
        guard let file = StackFile.load(root: root) else { print("no file"); return }
        let declared = Dictionary(file.servers(root: root).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let rows = Store.merge(known: [:], declared: declared, running: [])   // a fresh machine: nothing known, nothing running
        print("stopped rows:", rows.sorted { $0.port < $1.port }.map { "\($0.title) :\($0.port) [\($0.group)] start=\($0.canStart)" }.joined(separator: " | "))
        let levels = StartPlan.levels(startable: rows.filter(\.canStart), pool: rows)
        print("start order:", StartPlan.describe(levels))
        print("command for api:", rows.first { $0.title == "api" }?.start.map { "cd \(abbreviateHome($0.cwd)) && \($0.exec) \($0.argv.dropFirst().joined(separator: " "))" } ?? "-")
    }
    exit(0)
}

// Debug helper: `Switchboard --drag-test` sends a real mouse press, drag and release into the map and reports whether the node moved.
if CommandLine.arguments.contains("--drag-test") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        func node(_ port: Int, _ title: String, _ type: StackType) -> StackNode {
            StackNode(id: "/p/a:\(port)", role: .server, port: port, title: title, project: "a", status: 200, entryID: nil, type: type)
        }
        let nodes = [node(3000, "Next.js", .web), node(8000, "Laravel", .api), node(5432, "PostgreSQL", .database)]
        let edges = [StackEdge(from: "/p/a:3000", to: "/p/a:8000", count: 2, hint: nil, configured: false, broken: false),
                     StackEdge(from: "/p/a:8000", to: "/p/a:5432", count: 1, hint: nil, configured: false, broken: false)]
        let map = StackMap(nodes: nodes, edges: edges)
        let store = Store(sample: [], stack: map, showMap: true)

        let size = CGSize(width: 470, height: 440)
        let host = NSHostingView(rootView: StackMapView().environmentObject(store).frame(width: size.width, height: size.height))
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: 200, y: 200))
        win.orderFront(nil)
        win.makeKey()
        func spin(_ t: Double = 0.08) { RunLoop.current.run(until: Date().addingTimeInterval(t)) }
        spin(0.8)

        let layout = StackMapView.Layout(map: map, size: CGSize(width: size.width, height: size.height - 16), stripHeight: 78)
        let key = "/p/a:8000"
        let p = layout.point[key]!
        let startView = CGPoint(x: p.x, y: p.y + 17 + 8)            // node centre: layout point + label offset + the map's 8pt padding
        let start = NSPoint(x: startView.x, y: size.height - startView.y)   // AppKit window coordinates start at the bottom
        func send(_ type: NSEvent.EventType, _ pt: NSPoint) {
            let e = NSEvent.mouseEvent(with: type, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            win.sendEvent(e); spin(0.03)
        }
        print("node \(key) is at view (\(Int(startView.x)), \(Int(startView.y)))")
        send(.leftMouseDown, start)
        var last = start
        for i in 1...12 { last = NSPoint(x: start.x + CGFloat(i) * 5, y: start.y - CGFloat(i) * 4); send(.leftMouseDragged, last) }
        send(.leftMouseUp, last)
        spin(0.2)
        print("dragged by (+60, +48) -> saved offset:", store.mapOffsets[key].map { "(\(Int($0.width)), \(Int($0.height)))" } ?? "NONE: the drag did nothing")

        // a plain click elsewhere must not move anything
        let other = NSPoint(x: 400, y: 60)
        send(.leftMouseDown, other); send(.leftMouseUp, other); spin(0.1)
        print("offsets after a plain click:", store.mapOffsets.count, "(should still be 1) pan:", store.mapPan)

        // dragging empty space pans the whole map; the node offsets stay as they were
        let empty = NSPoint(x: 420, y: 330)
        send(.leftMouseDown, empty)
        var e2 = empty
        for i in 1...10 { e2 = NSPoint(x: empty.x - CGFloat(i) * 4, y: empty.y + CGFloat(i) * 3); send(.leftMouseDragged, e2) }
        send(.leftMouseUp, e2); spin(0.2)
        print("dragged empty space by (-40, -30) in view terms -> pan:", "(\(Int(store.mapPan.width)), \(Int(store.mapPan.height)))", "node offsets still:", store.mapOffsets.count)
        store.setMapView(pan: store.mapPan, zoom: 1.4); print("zoom set:", store.mapZoom, "customised:", store.mapIsCustomised)
        store.resetMapLayout(); print("after reset: customised =", store.mapIsCustomised, "offsets =", store.mapOffsets.count)
    }
    exit(0)
}

// `Switchboard --selftest` checks the pure logic and touches no state, so the release script can run it. Exits 1 on any failure.
if CommandLine.arguments.contains("--selftest") {
    var passed = 0, failed = 0
    func check(_ name: String, _ ok: Bool) { if ok { passed += 1 } else { failed += 1; print("FAIL", name) } }
    func rw(_ argv: [String], old: Int = 3000, env: [String: String] = [:]) -> (String, [String: String]) {
        let r = PortRewrite.apply(argv: argv, env: env, old: old, new: 4000); return (r.argv.joined(separator: " "), r.env)
    }
    check("flag value", rw(["node", "vite", "--port", "3000"]).0 == "node vite --port 4000")
    check("flag equals", rw(["php", "artisan", "serve", "--port=3000"]).0 == "php artisan serve --port=4000")
    check("short flag", rw(["node", "next", "dev", "-p", "3000"]).0 == "node next dev -p 4000")
    check("host and port", rw(["php", "-S", "localhost:3000"]).0 == "php -S localhost:4000")
    check("python positional", rw(["python3", "-m", "http.server", "3000"]).0 == "python3 -m http.server 4000")
    check("vite without a port gets a strict one", rw(["node", "vite"]).0 == "node vite --port 4000 --strictPort")
    check("next without a port", rw(["node", "next", "dev"]).0 == "node next dev -p 4000")
    check("unknown command falls back to PORT", rw(["node", "server.js"]).1["PORT"] == "4000")
    check("PORT in env is replaced", rw(["node", "server.js"], env: ["PORT": "3000"]).1["PORT"] == "4000")
    check("numbers that are not ports are left alone", rw(["node", "server.js", "--workers", "3000"]).0 == "node server.js --workers 3000")

    func server(_ key: String, _ port: Int, uses: [String] = []) -> KnownServer {
        KnownServer(key: key, port: port, title: key, group: "g", projectPath: "/p", start: KnownStart(exec: "/bin/echo", argv: ["echo"], cwd: "/"), containerID: nil, lastSeen: Date(), uses: uses)
    }
    let db = server("db", 5432), api = server("api", 8000, uses: ["db"]), web = server("web", 3000, uses: ["api"])
    let order = StartPlan.levels(startable: [web, api, db], pool: [web, api, db]).map { $0.map(\.key) }
    check("start order follows dependencies", order == [["db"], ["api"], ["web"]])

    // The port check must not call a just-stopped server's port "in use" (TIME_WAIT), and must see a real listener.
    do {
        func sock() -> Int32 { socket(AF_INET, SOCK_STREAM, 0) }
        func addr(_ port: UInt16) -> sockaddr_in {
            var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
            a.sin_port = port.bigEndian; a.sin_addr.s_addr = UInt32(0x7f000001).bigEndian; return a
        }
        func bindTo(_ fd: Int32, _ port: UInt16) -> Bool {
            var a = addr(port); return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
        }
        let port: UInt16 = 8763
        var one: Int32 = 1
        let srv = sock(); setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(4))
        check("selftest port bind", bindTo(srv, port)); listen(srv, 4)
        check("a listening port is not free", !Ports.isFree(Int(port)))
        let cli = sock(); var ca = addr(port)
        _ = withUnsafePointer(to: &ca) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(cli, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        let conn = accept(srv, nil, nil)
        close(conn); usleep(200_000); close(cli); close(srv)   // the server closes first, which leaves TIME_WAIT behind
        check("a just-stopped port is free", Ports.isFree(Int(port)))
    }

    // Log tail: whole lines only, colour codes removed, odd bytes and cut files survive.
    MainActor.assumeIsolated {
        let path = NSTemporaryDirectory() + "sb-selftest-\(getpid()).log"
        defer { try? FileManager.default.removeItem(atPath: path) }
        func write(_ d: Data, append: Bool = true) {
            if append, let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(d); try? h.close() } else { try? d.write(to: URL(fileURLWithPath: path)) }
        }
        write(Data("one\n\u{1B}[31mred error\u{1B}[0m\nhalf".utf8), append: false)
        let t = LogTail(source: .file(path), title: "t", key: "k")
        t.start()
        check("log tail reads whole lines only", t.lines.map(\.text) == ["one", "red error"])
        check("log tail strips colour codes and flags errors", t.lines.last?.kind == .error)
        let snow = Array("é".utf8)   // two bytes, written one at a time
        write(Data(" line\n".utf8.prefix(0)) + Data([snow[0]]))
        t.stop(); t.start()
        write(Data([snow[1]]) + Data("\n".utf8))
        t.stop(); t.start()
        check("log tail finishes a line and never splits a character", t.lines.last?.text == "halfé")
        write(Data("fresh\n".utf8), append: false)
        t.stop(); t.start()
        check("log tail notices a file that was reset", t.lines.last?.text == "fresh")
        try? FileManager.default.removeItem(atPath: path)
        t.stop(); t.start()
        check("log tail says when the file is gone", t.note != nil)
        t.stop()
    }

    // Errors-only filter combines with the text filter.
    MainActor.assumeIsolated {
        let t = LogTail(source: .file("/nonexistent"), title: "t", key: "k")
        t.preload("ok line\nwarn: slow\nError: boom\nfine again")
        t.problemsOnly = true
        check("errors only keeps errors and warnings", t.shown.map(\.text) == ["warn: slow", "Error: boom"])
        t.query = "boom"
        check("errors only works with the text filter", t.shown.map(\.text) == ["Error: boom"])
        t.problemsOnly = false; t.query = ""
        check("everything shows again", t.shown.count == 4 && !t.filtering)
    }

    // Editing in the row: bad input keeps the field open, good input or nothing closes it.
    MainActor.assumeIsolated {
        func row(_ port: Int, restartable: Bool) -> PortEntry {
            PortEntry(id: "\(port)", port: port, host: "127.0.0.1", lanExposed: false, kind: .dev, title: "Vite", pid: 1, command: "", projectName: "a",
                      projectPath: "/p/a", group: "a", uptime: nil, container: nil, web: .page, restart: restartable ? RestartSpec(exec: "/bin/true", argv: [], env: [:], cwd: "/p/a", rootPid: 1) : nil)
        }
        let a = row(5173, restartable: true), b = row(3000, restartable: false)
        let s = Store(sample: [a, b])
        s.beginEdit(b, .port)
        check("a port that can't change does not open a field", s.editing == nil)
        s.beginEdit(a, .port)
        check("a port opens a field", s.editing?.field == .port)
        check("letters are refused and the field stays", !s.commitPort(a, text: "abc") && s.editing != nil)
        check("a low port is refused", !s.commitPort(a, text: "80") && s.editing != nil)
        check("a huge port is refused", !s.commitPort(a, text: "70000") && s.editing != nil)
        check("a negative port is refused", !s.commitPort(a, text: "-3000") && s.editing != nil)
        check("an empty field closes without changing", s.commitPort(a, text: "  ") && s.editing == nil)
        s.beginEdit(a, .port)
        check("the same port closes without changing", s.commitPort(a, text: "5173 ") && s.editing == nil)
        s.beginEdit(a, .port); s.beginEdit(b, .name)
        s.cancelEdit(key: a.key, field: .port)
        check("an old field losing focus does not cancel the new edit", s.editing == .init(key: b.key, field: .name))
        s.commitName(b, text: "  Shop  ")
        check("a name is trimmed and saved", s.names[b.key] == "Shop" && s.editing == nil)
        s.beginEdit(b, .name); s.commitName(b, text: "")
        check("an empty name goes back to the original", s.names[b.key] == nil)
        s.beginEdit(b, .name); s.commitName(b, text: "Vite")
        check("the original name is not stored as a custom one", s.names[b.key] == nil)
    }

    let plain = PortEntry(id: "c", port: 3000, host: "127.0.0.1", lanExposed: false, kind: .dev, title: "x", pid: 1, command: "", projectName: "p", projectPath: "/p", group: "p", uptime: nil, container: nil, web: .page, restart: nil)
    check("copy as curl", plain.curl == "curl -i http://localhost:3000")

    // Two processes sharing one listening socket are one row.
    do {
        func entry(_ pid: Int32, root: Int32) -> PortEntry {
            PortEntry(id: "\(pid):8000", port: 8000, host: "127.0.0.1", lanExposed: false, kind: .dev, title: "Uvicorn", pid: pid, command: "", projectName: "api",
                      projectPath: "/p/api", group: "api", uptime: nil, container: nil, web: .page,
                      restart: RestartSpec(exec: "/bin/true", argv: [], env: [:], cwd: "/p/api", rootPid: root))
        }
        let one = Scanner.oneRowPerPort([entry(43186, root: 435), entry(435, root: 435)])
        check("a shared socket is one row", one.count == 1)
        check("the process that started the others wins", one.first?.pid == 435)
        check("different ports stay separate", Scanner.oneRowPerPort([entry(1, root: 1), { var e = entry(2, root: 2); e.port = 8001; e.projectPath = "/p/api2"; return e }()]).count == 2)
    }

    // Page title and icon: parsed from the head, cleaned, and only read from the same server.
    check("title is read", Probe.pageInfo("<html><head><title>Acme Dashboard</title></head>").title == "Acme Dashboard")
    check("title tag is case blind and may have attributes", Probe.pageInfo("<TITLE data-x=\"1\">Shop</TITLE>").title == "Shop")
    check("title entities and spaces are tidied", Probe.pageInfo("<title>\n  Tom &amp; Jerry\n   &quot;Live&quot;  </title>").title == "Tom & Jerry \"Live\"")
    check("no title is no title", Probe.pageInfo("<html><head></head>").title == nil && Probe.pageInfo("<title>  </title>").title == nil)
    check("control characters are removed", Probe.pageInfo("<title>a\u{7}b\u{202E}c</title>").title == "a b c")
    check("a long title is cut", (Probe.pageInfo("<title>" + String(repeating: "x", count: 200) + "</title>").title?.count ?? 0) == 81)
    check("icon link is found", Probe.iconHref("<link rel=\"icon\" type=\"image/svg+xml\" href=\"/vite.svg\" />") == "/vite.svg")
    check("icon link works with other order and quotes", Probe.iconHref("<link href='/a.png' rel='shortcut icon'>") == "/a.png")
    check("a plain icon beats a touch icon", Probe.iconHref("<link rel=\"apple-touch-icon\" href=\"/t.png\"><link rel=\"icon\" href=\"/i.png\">") == "/i.png")
    check("a stylesheet is not an icon", Probe.iconHref("<link rel=\"stylesheet\" href=\"/a.css\">") == nil)
    check("a relative icon becomes a path", Probe.iconPath("img/f.png", port: 3000) == "/img/f.png" && Probe.iconPath("./f.png", port: 3000) == "/f.png")
    check("an icon on the same server is kept", Probe.iconPath("http://localhost:3000/f.ico?v=2", port: 3000) == "/f.ico?v=2")
    check("an icon on another host is ignored", Probe.iconPath("https://cdn.example.com/f.ico", port: 3000) == nil && Probe.iconPath("//cdn.example.com/f.ico", port: 3000) == nil)
    check("an icon on another local port is ignored", Probe.iconPath("http://localhost:9999/f.ico", port: 3000) == nil)
    check("odd icon links are ignored", Probe.iconPath("data:image/png;base64,AAAA", port: 3000) == nil && Probe.iconPath("/a b", port: 3000) == nil && Probe.iconPath("file:///etc/passwd", port: 3000) == nil)
    do {   // a real local server: a page with a title, an icon, and no /favicon.ico
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 8)
        var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = Int(UInt16(bigEndian: bound.sin_port))
        let page = "<!doctype html><html><head><title>Acme &amp; Co</title><link rel=\"icon\" href=\"/logo.png\"></head><body>hi</body></html>"
        let server = Thread {
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { break }
                var buf = [UInt8](repeating: 0, count: 2048)
                let n = recv(c, &buf, buf.count, 0)
                let line = n > 0 ? String(decoding: buf.prefix(n), as: UTF8.self).split(separator: "\r\n").first.map(String.init) ?? "" : ""
                let reply: String
                if line.hasPrefix("GET / ") { reply = "HTTP/1.0 200 OK\r\nContent-Type: text/html\r\n\r\n" + page }
                else if line.hasPrefix("GET /logo.png ") { reply = "HTTP/1.0 200 OK\r\nContent-Type: image/png\r\n\r\nPNGDATA" }
                else { reply = "HTTP/1.0 404 Not Found\r\nContent-Type: text/plain\r\n\r\nnope" }
                _ = reply.withCString { send(c, $0, strlen($0), 0) }
                close(c)
            }
        }
        server.start()
        let r = Probe.check(pid: nil, port: port, host: "127.0.0.1")
        check("a real page gives its title", r.kind == .page && r.title == "Acme & Co")
        check("a real page gives its icon path", r.icon == "/logo.png")
        check("the icon is fetched", Probe.fetchIcon(port: port, host: "127.0.0.1", path: "/logo.png") == Data("PNGDATA".utf8))
        check("a missing icon is nil, not an error page", Probe.fetchIcon(port: port, host: "127.0.0.1", path: "/favicon.ico") == nil)
        check("the page itself is not taken as an icon", Probe.fetchIcon(port: port, host: "127.0.0.1", path: "/") == nil)
        close(fd)
    }

    // CPU and memory.
    check("cpu share over two seconds", abs(Usage.cpuPercent(from: 1_000_000_000, to: 2_000_000_000, seconds: 2) - 50) < 0.001)
    check("cpu never goes negative", Usage.cpuPercent(from: 5, to: 1, seconds: 3) == 0 && Usage.cpuPercent(from: 1, to: 9, seconds: 0) == 0)
    check("memory in MB", Usage.memoryText(120 * 1_048_576) == "120 MB")
    check("memory in GB", Usage.memoryText(1_610_612_736) == "1.5 GB")
    check("a busy server is flagged", Usage(cpu: 80, memory: 0).busy && !Usage(cpu: 4, memory: 0).busy)
    do {
        let me = Proc.usage(of: getpid())
        check("usage of this process", (me?.rss ?? 0) > 0)
        let kid = Process()
        kid.executableURL = URL(fileURLWithPath: "/bin/sleep"); kid.arguments = ["3"]
        try? kid.run()
        check("children are found", Proc.children(getpid()).contains(kid.processIdentifier))
        kid.terminate()
        check("a missing process has no usage", Proc.usage(of: 999_999) == nil)
        // The parent only waits; the child burns CPU. The parent's usage has to include the child.
        let busy = Process()
        busy.executableURL = URL(fileURLWithPath: "/bin/sh"); busy.arguments = ["-c", "while :; do :; done & wait"]
        try? busy.run()
        usleep(300_000)
        if let a = Proc.usage(of: busy.processIdentifier) {
            let t0 = Date(); usleep(800_000)
            if let b = Proc.usage(of: busy.processIdentifier) {
                let pct = Usage.cpuPercent(from: a.cpuNs, to: b.cpuNs, seconds: Date().timeIntervalSince(t0))
                check("a busy child shows up in its parent's cpu", pct > 25)
            } else { check("usage is read twice", false) }
        } else { check("usage of the busy parent", false) }
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/pkill"), arguments: ["-P", String(busy.processIdentifier)])
        busy.terminate()
    }

    // Update check: numeric version order, and only real releases count.
    check("1.10.0 is newer than 1.9.0", Updates.isNewer("1.10.0", than: "1.9.0"))
    check("the same version is not newer", !Updates.isNewer("v1.7.0", than: "1.7.0"))
    check("an older version is not newer", !Updates.isNewer("1.6.9", than: "1.7.0"))
    check("garbage is never newer", !Updates.isNewer("nightly", than: "1.7.0") && !Updates.isNewer("1.7.0", than: "dev"))
    check("a release is read from GitHub's reply", Updates.parse(Data(#"{"tag_name":"v1.8.0","html_url":"https://github.com/x/y/releases/tag/v1.8.0","body":"hi"}"#.utf8))?.version == "1.8.0")
    check("a prerelease is ignored", Updates.parse(Data(#"{"tag_name":"v2.0.0","prerelease":true,"html_url":"https://x.y"}"#.utf8)) == nil)
    check("a broken reply is ignored", Updates.parse(Data("<html>".utf8)) == nil)

    print(failed == 0 ? "selftest passed (\(passed) checks)" : "selftest FAILED (\(failed) of \(passed + failed))")
    exit(failed == 0 ? 0 : 1)
}

// Debug helper: `Switchboard --start-e2e` starts a stopped server on another port while its own port is held.
if CommandLine.arguments.contains("--start-e2e") {
    MainActor.assumeIsolated {
        let dir = NSHomeDirectory() + "/Projects/_starttest"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? "require('http').createServer((q,r)=>r.end('ok')).listen(process.env.PORT||8741)".write(toFile: dir + "/s.js", atomically: true, encoding: .utf8)
        let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/env"
        let blocker = Process()
        blocker.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        blocker.arguments = ["-m", "http.server", "8741", "--directory", dir]
        blocker.standardOutput = FileHandle.nullDevice; blocker.standardError = FileHandle.nullDevice
        try! blocker.run()
        func spin(until cond: () -> Bool, timeout: Double = 15) -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end { if cond() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            return cond()
        }
        print("1. port 8741 held by someone else:", spin(until: { Probe.isListening(8741) }, timeout: 6), "| isFree:", Ports.isFree(8741))
        let k = KnownServer(key: "\(dir):8741", port: 8741, title: "Node.js", group: "_starttest", projectPath: dir,
                            start: KnownStart(exec: node == "/usr/bin/env" ? "/usr/bin/env" : node, argv: node == "/usr/bin/env" ? ["env", "node", "s.js"] : [node, "s.js"], cwd: dir), containerID: nil, lastSeen: Date())
        Task { try? await Actions.start(k, port: 8742) }
        print("2. same server started on :8742:", spin(until: { Probe.isListening(8742) }))
        blocker.terminate()
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/pkill"), arguments: ["-f", "_starttest"])
        _ = try? Process.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "kill $(lsof -tiTCP:8742 -sTCP:LISTEN) 2>/dev/null"])
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/Library/Logs/Switchboard/_starttest-8742.log")
    }
    exit(0)
}

// Debug helper: `Switchboard --port-e2e` moves a real server to another port and back, and checks the rewriter on common commands.
if CommandLine.arguments.contains("--port-e2e") {
    MainActor.assumeIsolated {
        func rw(_ argv: [String], _ old: Int = 3000) -> String { let r = PortRewrite.apply(argv: argv, env: [:], old: old, new: 4000, cwd: NSHomeDirectory() + "/Projects/_scripts"); return r.argv.joined(separator: " ") + (r.env["PORT"].map { "  PORT=\($0)" } ?? "") }
        let sd = NSHomeDirectory() + "/Projects/_scripts"
        try? FileManager.default.createDirectory(atPath: sd, withIntermediateDirectories: true)
        try? "{\"scripts\":{\"dev\":\"vite\",\"start\":\"node server.js\"}}".write(toFile: sd + "/package.json", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: sd) }
        for c in [["node", "vite", "--port", "3000"], ["node", "vite"], ["npm", "run", "dev"], ["pnpm", "dev"], ["npm", "start"], ["node", "next", "dev", "-p", "3000"], ["node", "next", "dev"],
                  ["php", "artisan", "serve", "--port=3000"], ["php", "artisan", "serve"], ["python3", "-m", "http.server", "3000"], ["php", "-S", "localhost:3000"], ["node", "server.js"]] {
            print(c.joined(separator: " "), "→", rw(c))
        }
        _ = NSApplication.shared
        let dir = NSHomeDirectory() + "/Projects/_porttest"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? "{\"name\":\"porttest\"}".write(toFile: dir + "/package.json", atomically: true, encoding: .utf8)
        try? "require('http').createServer((q,r)=>r.end('ok')).listen(process.env.PORT||8731)".write(toFile: dir + "/s.js", atomically: true, encoding: .utf8)
        let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/env"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = node == "/usr/bin/env" ? ["node", "s.js"] : ["s.js"]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try! p.run()
        func spin(until cond: () -> Bool, timeout: Double = 25) -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end { if cond() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            return cond()
        }
        let store = Store.shared
        _ = spin(until: { Probe.isListening(8731) }, timeout: 6)
        Task { await store.refresh() }
        _ = spin(until: { store.entries.contains { $0.port == 8731 } })
        guard let entry = store.entries.first(where: { $0.port == 8731 }) else { print("server not seen"); exit(1) }
        store.rename(entry: entry, to: "porttest-api")
        store.changePort(entry, to: 8732)
        let moved = spin(until: { Probe.isListening(8732) && !Probe.isListening(8731) })
        print("1. moved to :8732, old port closed:", moved, "| message:", store.message ?? "-")
        _ = spin(until: { store.undo != nil })
        let renamed = store.entries.first { $0.port == 8732 }.map { store.displayName($0) }
        print("2. Undo offered:", store.undo != nil, "| name carried over:", renamed ?? "-")
        store.runUndo()
        let back = spin(until: { Probe.isListening(8731) && !Probe.isListening(8732) })
        print("3. Undo moved it back to :8731:", back)
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/pkill"), arguments: ["-f", "_porttest"])
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        if let k = store.stopped.first(where: { $0.port == 8731 || $0.port == 8732 }) { store.forget(k) }
        try? FileManager.default.removeItem(atPath: dir)
        for port in [8731, 8732] { try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/Library/Logs/Switchboard/_porttest-\(port).log") }
    }
    exit(0)
}

// Debug helper: `Switchboard --move-e2e 8899 8898` moves the real server on the first port to the second, like a double click on its port.
if let i = CommandLine.arguments.firstIndex(of: "--move-e2e"), CommandLine.arguments.count > i + 2,
   let from = Int(CommandLine.arguments[i + 1]), let to = Int(CommandLine.arguments[i + 2]) {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let store = Store.shared
        func spin(until cond: () -> Bool, timeout: Double = 25) -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end { if cond() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            return cond()
        }
        Task { await store.refresh() }
        _ = spin(until: { store.entries.contains { $0.port == from } })
        guard let entry = store.entries.first(where: { $0.port == from }) else { print("nothing on :\(from)"); exit(1) }
        print("before: pid", entry.pid.map(String.init) ?? "-", "root", entry.restart.map { String($0.rootPid) } ?? "-")
        store.changePort(entry, to: to)
        _ = spin(until: { Probe.isListening(to) && !Probe.isListening(from) }, timeout: 15)
        print("new port up:", Probe.isListening(to), "| old port closed:", !Probe.isListening(from), "| message:", store.message ?? "-")
        _ = spin(until: { false }, timeout: 4)   // let the follow-up refreshes run, then show the list as the popover would
        Task { await store.refresh() }
        _ = spin(until: { false }, timeout: 2)
        for g in store.groups { print("list:", g.name, "running", g.running.map(\.port), "stopped", g.stopped.map(\.port)) }
    }
    exit(0)
}

// Debug helper: `Switchboard --undo-e2e` stops a real server through the Stop path, presses Undo, and checks it comes back.
if CommandLine.arguments.contains("--undo-e2e") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let dir = NSHomeDirectory() + "/Projects/_undotest"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? "{\"name\":\"undotest\"}".write(toFile: dir + "/package.json", atomically: true, encoding: .utf8)
        try? "require('http').createServer((q,r)=>r.end('ok')).listen(8721)".write(toFile: dir + "/s.js", atomically: true, encoding: .utf8)
        let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/env"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = node == "/usr/bin/env" ? ["node", "s.js"] : ["s.js"]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try! p.run()

        func spin(until cond: () -> Bool, timeout: Double = 25) -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end { if cond() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            return cond()
        }
        let store = Store.shared
        var listening: Bool { Probe.isListening(8721) }
        _ = spin(until: { listening }, timeout: 6)
        Task { await store.refresh() }
        let seen = spin(until: { store.entries.contains { $0.port == 8721 } })
        print("1. server seen by the app:", seen)
        guard let entry = store.entries.first(where: { $0.port == 8721 }) else { exit(1) }

        store.kill(entry)   // exactly what the Stop button does
        let undoShown = spin(until: { store.undo != nil })
        print("2. stopped, Undo bar shown:", undoShown, "| message:", store.message ?? "-", "| still listening:", listening)

        store.runUndo()     // exactly what the Undo button does
        let back = spin(until: { listening })
        print("3. after Undo the server is listening again:", back)

        // clean up
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/pkill"), arguments: ["-f", "_undotest"])
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        if let k = store.stopped.first(where: { $0.port == 8721 }) { store.forget(k) }
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/Library/Logs/Switchboard/_undotest-8721.log")
    }
    exit(0)
}

// Debug helper: `Switchboard --stack` prints who talks to whom.
if CommandLine.arguments.contains("--stack") {
    let m = Scanner.stack(entries: Scanner.scan())
    for n in m.nodes { print("node \(n.id)\t\(n.role)\t:\(n.port.map(String.init) ?? "-")\t\(n.title)\t[\(n.project ?? "-")]") }
    for e in m.edges { print("edge \(e.from) -> \(e.to)\tconns=\(e.count)\tconfigured=\(e.configured)\tbroken=\(e.broken)\t\(e.hint ?? "")") }
    print("layers:", m.layers().sorted { $0.key < $1.key }.map { "\($0.key.split(separator: ":").last ?? ""):\($0.value)" }.joined(separator: " "))
    exit(0)
}

// Debug helper: `Switchboard --contrast` prints the extra tint chosen for a few wallpapers.
if CommandLine.arguments.contains("--contrast") { Backdrop.report(); exit(0) }

// Build helper: `Switchboard --icon out.png` draws the app icon.
if let i = CommandLine.arguments.firstIndex(of: "--icon"), CommandLine.arguments.count > i + 1 {
    _ = NSApplication.shared
    try? IconArt.appIcon().representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

// Debug helper: `Switchboard --act start <port>` starts a remembered (stopped) server from the saved state.
if let i = CommandLine.arguments.firstIndex(of: "--act"), CommandLine.arguments.count > i + 2,
   CommandLine.arguments[i + 1] == "start", let port = Int(CommandLine.arguments[i + 2]) {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Switchboard/state.json")
    struct S: Codable { var known: [String: KnownServer] }
    guard let data = try? Data(contentsOf: url), let st = try? JSONDecoder().decode(S.self, from: data),
          let k = st.known.values.first(where: { $0.port == port }) else { print("nothing remembered for \(port)"); exit(1) }
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do { try await Actions.start(k); print("start ok") } catch { print("error: \(error.localizedDescription)") }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// Debug helper: `Switchboard --act kill|restart <port>`
if let i = CommandLine.arguments.firstIndex(of: "--act"), CommandLine.arguments.count > i + 2,
   let port = Int(CommandLine.arguments[i + 2]) {
    let verb = CommandLine.arguments[i + 1]
    guard let e = Scanner.scan().first(where: { $0.port == port }) else { print("no listener on \(port)"); exit(1) }
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do { if verb == "kill" { try await Actions.kill(e) } else { try await Actions.restart(e) }; print("\(verb) ok") }
        catch { print("error: \(error.localizedDescription)") }
        sem.signal()
    }
    sem.wait()
    if let log = Actions.logFile(for: e) { print("log:", log) }
    exit(0)
}
// Debug helper: `Switchboard --screenshot out.png [dark]` renders the popover with sample data.
if let i = CommandLine.arguments.firstIndex(of: "--screenshot"), CommandLine.arguments.count > i + 1 {
    let outPath = CommandLine.arguments[i + 1]
    let dark = CommandLine.arguments.contains("dark")
    MainActor.assumeIsolated {
        func e(_ port: Int, _ title: String, _ group: String, _ kind: EntryKind = .dev, up: String, web: WebKind = .page,
               lan: Bool = false, ms: Int? = nil, status: Int? = 200) -> PortEntry {
            PortEntry(id: "\(port)", port: port, host: "127.0.0.1", lanExposed: lan, kind: kind, title: title, pid: 1,
                      command: "", projectName: group, projectPath: "/Users/dev/\(group)", group: group, uptime: up,
                      container: nil, web: web, restart: nil, status: ms == nil ? nil : status, ms: ms)
        }
        var list = [
            e(5173, "Vite", "storefront", up: "2h 14m", ms: 8),
            e(3000, "Next.js", "dashboard", up: "41m", ms: 31),
            e(3001, "Node.js", "dashboard", up: "41m", lan: true, ms: 12),
            e(8000, "Laravel", "billing-api", up: "5h 3m", web: .api, ms: 120, status: 500),
            e(5432, "PostgreSQL", "billing-api", .database, up: "3d 2h", web: .none),
            e(6379, "Redis", "billing-api", .database, up: "3d 2h", web: .none),
        ]
        for (i, t) in [0: "Northwind Store", 1: "Dashboard", 2: "Admin console"] { list[i].pageTitle = t }
        // Stand-ins for the icons the pages would serve.
        func favicon(_ letter: String, _ color: NSColor) -> NSImage {
            NSImage(size: NSSize(width: 32, height: 32), flipped: false) { r in
                color.setFill(); NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
                let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20, weight: .bold), .foregroundColor: NSColor.white]
                let sz = letter.size(withAttributes: a)
                letter.draw(at: NSPoint(x: (r.width - sz.width) / 2, y: (r.height - sz.height) / 2), withAttributes: a)
                return true
            }
        }
        let sampleIcons = [list[0].key: favicon("N", NSColor(red: 0.96, green: 0.45, blue: 0.1, alpha: 1)),
                           list[1].key: favicon("D", NSColor(red: 0.31, green: 0.27, blue: 0.9, alpha: 1)),
                           list[2].key: favicon("A", NSColor(red: 0.06, green: 0.6, blue: 0.5, alpha: 1))]
        let stoppedServer = KnownServer(key: "/Users/dev/dashboard:4000", port: 4000, title: "Storybook", group: "dashboard",
                                        projectPath: "/Users/dev/dashboard",
                                        start: KnownStart(exec: "/usr/bin/true", argv: [], cwd: "/tmp"), containerID: nil, lastSeen: Date())
        // A sample stack for the map: three front ends call the API, the API uses Postgres and Redis, and a .env points at a port nobody listens on.
        func k(_ group: String, _ port: Int) -> String { "/Users/dev/\(group):\(port)" }
        var nodes = list.map { StackNode(id: $0.key, role: .server, port: $0.port, title: $0.title, project: "billing", status: $0.status, entryID: $0.id,
                                         type: StackType.classify(title: $0.title, web: $0.web, isContainer: $0.container != nil)) }
        nodes.append(StackNode(id: "client:1", role: .client, port: nil, title: "Queue worker", project: "billing", status: nil, entryID: nil, type: .worker))
        nodes.append(StackNode(id: "missing:9200", role: .missing, port: 9200, title: "Nothing here", project: nil, status: nil, entryID: nil, type: .missing))
        func edge(_ f: String, _ t: String, _ n: Int) -> StackEdge { StackEdge(from: f, to: t, count: n, hint: nil, configured: false, broken: false) }
        let sampleStack = StackMap(nodes: nodes, edges: [
            edge(k("storefront", 5173), k("billing-api", 8000), 3), edge(k("dashboard", 3000), k("billing-api", 8000), 2),
            edge(k("dashboard", 3001), k("billing-api", 8000), 1), edge(k("billing-api", 8000), k("billing-api", 5432), 4),
            edge(k("billing-api", 8000), k("billing-api", 6379), 2), edge("client:1", k("billing-api", 5432), 2),
            edge("client:1", k("billing-api", 6379), 1),
            StackEdge(from: k("billing-api", 8000), to: "missing:9200", count: 0, hint: "ELASTIC_PORT in .env", configured: true, broken: true),
        ])
        let docs = KnownServer(key: "/Users/dev/dashboard:4100", port: 4100, title: "Docusaurus", group: "dashboard",
                               projectPath: "/Users/dev/dashboard", start: KnownStart(exec: "/usr/bin/true", argv: [], cwd: "/tmp"), containerID: nil, lastSeen: Date())
        let store = Store(sample: list, stopped: [stoppedServer, docs], names: ["/Users/dev/dashboard:3001": "Admin app"],
                          pinned: [], stack: sampleStack, showMap: CommandLine.arguments.contains("map"),
                          usage: Dictionary(uniqueKeysWithValues: zip(list.map(\.key), [(3.0, 142), (91.0, 318), (1.0, 96), (6.0, 214), (0.0, 64), (2.0, 780), (0.0, 38), (4.0, 120)]
                              .map { Usage(cpu: $0.0, memory: UInt64($0.1) * 1_048_576) })),
                          icons: sampleIcons)
        if CommandLine.arguments.contains("logs") {
            let t = LogTail(source: .file("/Users/dev/billing-api/storage/logs/laravel.log"), title: "Laravel :8000", key: list[3].key)
            t.preload("""
            --- started Tue Oct 20 09:14:02 2026 ---
            09:14:03 INFO  Booting the application
            09:14:03 INFO  Listening on http://127.0.0.1:8000
            09:14:21 GET  /api/invoices 200 41ms
            09:14:22 GET  /api/customers/42 200 18ms
            09:14:30 WARN  Slow query on invoices took 912ms
            09:14:31 GET  /api/invoices?page=2 200 953ms
            09:14:44 POST /api/payments 500 120ms
            09:14:44 ERROR Payments gateway refused the connection
            09:14:44 ERROR Could not reach payments.internal:9200
            09:14:52 GET  /health 200 2ms
            09:15:07 POST /api/payments 200 64ms
            09:15:19 GET  /api/invoices 200 37ms
            """)
            store.logs = t
        }
        if CommandLine.arguments.contains("toast") { store.flash("Stopped Next.js :3000", undo: UndoAction(label: "Undo") {}) }
        _ = NSApplication.shared
        Theme.flat = true
        let look = NSAppearance(named: dark ? .darkAqua : .aqua)
        var size = CGSize.zero

        func render(_ matte: Color) -> CGImage? {
            Theme.matte = matte
            let host = NSHostingView(rootView: RootView().environmentObject(store))
            host.appearance = look
            size = host.fittingSize
            let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = look
            win.contentView = host
            win.setFrameOrigin(NSPoint(x: -4000, y: -4000))
            win.orderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: rep)
            win.orderOut(nil)
            return rep.cgImage
        }
        func rgba(_ cg: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            data.withUnsafeMutableBytes { p in
                CGContext(data: p.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            }
            return data
        }
        /// Render on white and on black; the difference tells us each pixel's real transparency.
        func transparentContent() -> CGImage? {
            guard let onWhite = render(.white), let onBlack = render(.black) else { return nil }
            let w = rgba(onWhite), k = rgba(onBlack)
            var out = [UInt8](repeating: 0, count: w.count)
            for i in stride(from: 0, to: w.count, by: 4) {
                let d = (Int(w[i]) - Int(k[i]) + Int(w[i + 1]) - Int(k[i + 1]) + Int(w[i + 2]) - Int(k[i + 2])) / 3
                let alpha = max(0, min(255, 255 - d))
                out[i] = min(k[i], UInt8(alpha)); out[i + 1] = min(k[i + 1], UInt8(alpha)); out[i + 2] = min(k[i + 2], UInt8(alpha))
                out[i + 3] = UInt8(alpha)
            }
            let width = onWhite.width, height = onWhite.height
            return out.withUnsafeMutableBytes { p in
                CGContext(data: p.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
            }
        }

        if let content = transparentContent() {
            // Fake what macOS does live: a wallpaper behind, blurred, tinted, then the popover content on top.
            let scale: CGFloat = 2, pad: CGFloat = 56
            let w = size.width + pad * 2, h = size.height + pad * 2
            func bitmap() -> NSBitmapImageRep {
                let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                r.size = NSSize(width: w, height: h)
                return r
            }
            func draw(into r: NSBitmapImageRep, _ body: () -> Void) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: r)
                body()
                NSGraphicsContext.restoreGraphicsState()
            }
            let canvas = NSRect(x: 0, y: 0, width: w, height: h)
            let card = NSRect(x: pad, y: pad, width: size.width, height: size.height)
            let path = NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12)

            // 1. wallpaper
            let wall = bitmap()
            draw(into: wall) {
                let (c1, c2) = dark
                    ? (NSColor(red: 0.08, green: 0.10, blue: 0.22, alpha: 1), NSColor(red: 0.02, green: 0.03, blue: 0.08, alpha: 1))
                    : (NSColor(red: 0.80, green: 0.88, blue: 0.99, alpha: 1), NSColor(red: 0.70, green: 0.76, blue: 0.95, alpha: 1))
                NSGradient(starting: c1, ending: c2)!.draw(in: canvas, angle: -50)
                let blobs: [(CGFloat, CGFloat, CGFloat, NSColor)] = dark
                    ? [(0.15, 0.80, 0.55, NSColor(red: 0.30, green: 0.20, blue: 0.80, alpha: 0.85)),
                       (0.85, 0.25, 0.60, NSColor(red: 0.05, green: 0.55, blue: 0.65, alpha: 0.75)),
                       (0.55, 0.60, 0.40, NSColor(red: 0.75, green: 0.20, blue: 0.55, alpha: 0.45))]
                    : [(0.12, 0.85, 0.55, NSColor(red: 0.98, green: 0.62, blue: 0.80, alpha: 0.90)),
                       (0.88, 0.22, 0.60, NSColor(red: 0.45, green: 0.80, blue: 0.95, alpha: 0.90)),
                       (0.55, 0.55, 0.40, NSColor(red: 0.70, green: 0.60, blue: 0.98, alpha: 0.60))]
                for (x, y, r, c) in blobs {
                    let rad = max(w, h) * r
                    NSGradient(colors: [c, c.withAlphaComponent(0)])!
                        .draw(fromCenter: NSPoint(x: w * x, y: h * y), radius: 0, toCenter: NSPoint(x: w * x, y: h * y), radius: rad, options: [])
                }
            }

            // 2. blurred copy of the wallpaper for the card area
            let out = bitmap()
            draw(into: out) { wall.draw(in: canvas) }
            if let cg = wall.cgImage {
                let blurred = CIImage(cgImage: cg).clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 28 * scale])
                    .cropped(to: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                if let bcg = CIContext().createCGImage(blurred, from: blurred.extent) {
                    draw(into: out) {
                        NSGraphicsContext.saveGraphicsState()
                        let shadow = NSShadow()
                        shadow.shadowBlurRadius = 30
                        shadow.shadowOffset = NSSize(width: 0, height: -12)
                        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.55 : 0.30)
                        shadow.set()
                        NSColor.black.setFill()
                        path.fill()
                        NSGraphicsContext.restoreGraphicsState()

                        NSGraphicsContext.saveGraphicsState()
                        path.addClip()
                        NSImage(cgImage: bcg, size: NSSize(width: w, height: h)).draw(in: canvas)
                        // 3. the material tint, then the content
                        (dark ? NSColor(white: 0.10, alpha: 0.62) : NSColor(white: 1.0, alpha: 0.66)).setFill()
                        NSBezierPath(rect: card).fill()
                        NSImage(cgImage: content, size: size).draw(in: card)
                        NSGraphicsContext.restoreGraphicsState()

                        (dark ? NSColor.white.withAlphaComponent(0.20) : NSColor.white.withAlphaComponent(0.70)).setStroke()
                        path.lineWidth = 0.75
                        path.stroke()
                    }
                }
            }
            try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: outPath))
            print("wrote \(outPath)")
        }
    }
    exit(0)
}
Migration.run()
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
