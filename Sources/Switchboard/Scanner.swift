import Foundation

enum Scanner {
    private struct Listener { var pid: Int32; var host: String; var port: Int }

    static func scan() -> [PortEntry] {
        let listeners = parseListeners()
        let docker = Docker.list()
        let dockerPorts = Set(docker.flatMap { $0.ports.map(\.hostPort) })
        let now = Int(Date().timeIntervalSince1970)

        var entries: [PortEntry] = []
        var seen = Set<String>()
        var infoCache: [Int32: PortEntry] = [:]

        for l in listeners {
            let key = "\(l.pid):\(l.port)"
            guard seen.insert(key).inserted else { continue }
            let base: PortEntry
            if let cached = infoCache[l.pid] {
                base = cached
            } else {
                base = describe(pid: l.pid, now: now)
                infoCache[l.pid] = base
            }
            var e = base
            e.id = key
            e.port = l.port
            e.host = l.host
            e.lanExposed = !(l.host.hasPrefix("127.") || l.host == "[::1]" || l.host == "localhost")
            // Docker's own proxy process owns the host port; the container row replaces it.
            if dockerPorts.contains(l.port), e.kind == .other { continue }
            entries.append(e)
        }

        entries = oneRowPerPort(entries)

        for d in docker {
            let image = d.container.image.split(separator: "/").last.map(String.init) ?? d.container.image
            let isDB = Detector.flavor(exec: image, argv: [image.split(separator: ":").first.map(String.init) ?? image], cwd: nil, project: nil).kind == .database
            var seenPorts = Set<Int>()
            for p in d.ports where seenPorts.insert(p.hostPort).inserted {
                let groupName = d.project ?? "Docker"
                entries.append(PortEntry(
                    id: "docker:\(d.container.id):\(p.hostPort)", port: p.hostPort,
                    host: p.loopbackOnly ? "127.0.0.1" : "*", lanExposed: !p.loopbackOnly,
                    kind: .docker, title: image, pid: nil,
                    command: "docker \(d.container.name)",
                    projectName: d.project, projectPath: d.workdir, group: groupName,
                    uptime: nil, container: d.container, web: isDB ? .none : .page, restart: nil))
            }
        }

        probeWebKinds(&entries)
        return entries.sorted { ($0.group.lowercased(), $0.port) < ($1.group.lowercased(), $1.port) }
    }

    /// Two processes can hold the same listening socket, for example a uvicorn parent and the worker it forked.
    /// That is one server on one port, so it gets one row. The process that started the others wins, then the lowest pid.
    static func oneRowPerPort(_ list: [PortEntry]) -> [PortEntry] {
        func isRoot(_ e: PortEntry) -> Bool { e.pid != nil && e.pid == e.restart?.rootPid }
        var best: [String: PortEntry] = [:], order: [String] = []
        for e in list {
            if let cur = best[e.key] {
                let better = isRoot(e) != isRoot(cur) ? isRoot(e) : (e.pid ?? .max) < (cur.pid ?? .max)
                if better { best[e.key] = e }
            } else {
                best[e.key] = e
                order.append(e.key)
            }
        }
        return order.compactMap { best[$0] }
    }

    /// Ask each candidate port what it serves, in parallel (≤ ~1s total).
    private static func probeWebKinds(_ entries: inout [PortEntry]) {
        let jobs = entries.indices.filter { entries[$0].web != .none }.map { ($0, entries[$0].pid, entries[$0].port, entries[$0].host) }
        var results = [ProbeResult](repeating: ProbeResult(kind: .none, status: nil, ms: nil), count: jobs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: jobs.count) { n in
            let j = jobs[n]
            let r = Probe.check(pid: j.1, port: j.2, host: j.3)
            lock.lock(); results[n] = r; lock.unlock()
        }
        for (n, j) in jobs.enumerated() {
            entries[j.0].web = results[n].kind
            entries[j.0].status = results[n].status
            entries[j.0].ms = results[n].ms
        }
    }

    // MARK: lsof

    private static func parseListeners() -> [Listener] {
        let r = runCapture("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"], timeout: 8)
        var out: [Listener] = []
        var pid: Int32 = 0
        for line in r.out.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let body = line.dropFirst()
            if tag == "p" { pid = Int32(body) ?? 0 }
            else if tag == "n", pid > 0, let colon = body.lastIndex(of: ":"), let port = Int(body[body.index(after: colon)...]) {
                out.append(Listener(pid: pid, host: String(body[..<colon]), port: port))
            }
        }
        return out
    }

    // MARK: Per-process description

    static func describe(pid: Int32, now: Int) -> PortEntry {
        let ae = Proc.argsEnv(pid)
        let exec = ae?.exec ?? Proc.path(pid) ?? "?"
        let argv = ae?.argv ?? [exec]
        let cwd = Proc.cwd(pid)
        let project = Detector.project(cwd: cwd)
        var flavor = Detector.flavor(exec: exec, argv: argv, cwd: cwd, project: project)
        if flavor.kind != .database, Detector.isSystemOrApp(exec: exec) || cwd == "/" || cwd == nil {
            flavor.kind = .other
        }

        var uptime: String?
        if let b = Proc.bsd(pid) { uptime = formatDuration(now - Int(b.pbi_start_tvsec)) }

        let group: String
        switch flavor.kind {
        case .database: group = project?.name ?? "Services"
        case .other: group = "System & apps"
        default: group = project?.name ?? "No project"
        }

        return PortEntry(
            id: "", port: 0, host: "", lanExposed: false, kind: flavor.kind, title: flavor.name,
            pid: pid, command: argv.map { abbreviateHome($0) }.joined(separator: " "),
            projectName: project?.name, projectPath: project?.path, group: group,
            uptime: uptime, container: nil, web: flavor.isWeb ? .page : .none,
            restart: flavor.kind == .other ? nil : restartSpec(pid: pid, cwd: cwd, exec: exec, argv: argv, env: ae?.env))
    }

    private static let wrapperNames: Set<String> = [
        "node", "npm", "npx", "yarn", "pnpm", "bun", "bunx", "composer", "php", "python", "python3", "ruby", "deno", "turbo",
    ]
    private static let shellNames: Set<String> = ["sh", "bash", "zsh"]

    /// Climb through wrappers (`npm run dev` → `sh -c vite` → `node vite`) so a restart relaunches the whole thing.
    private static func restartSpec(pid: Int32, cwd: String?, exec: String, argv: [String], env: [String: String]?) -> RestartSpec? {
        guard let cwd, let env else { return nil }
        var spec = RestartSpec(exec: exec, argv: argv, env: env, cwd: cwd, rootPid: pid)
        var cur = pid
        while let b = Proc.bsd(cur) {
            let parent = Int32(b.pbi_ppid)
            guard parent > 1, Proc.cwd(parent) == cwd, let pae = Proc.argsEnv(parent) else { break }
            let name = (pae.exec as NSString).lastPathComponent
            let isShellWrapper = shellNames.contains(name) && pae.argv.contains("-c")
            guard wrapperNames.contains(name) || name.hasPrefix("python") || isShellWrapper else { break }
            spec = RestartSpec(exec: pae.exec, argv: pae.argv, env: pae.env, cwd: cwd, rootPid: parent)
            cur = parent
        }
        return spec
    }
}
