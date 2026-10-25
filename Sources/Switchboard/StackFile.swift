import Foundation

/// `switchboard.json`: a project's stack, meant to be committed so everyone on the team gets the same one-click start.
/// It holds commands and dependencies only. Never environment variables, so there is nothing secret in it.
struct StackFile: Codable {
    var version = 1
    var name: String?
    var services: [Service]

    struct Service: Codable {
        var name: String
        var port: Int
        var command: String?        // run in a login shell, so node, php and friends resolve like in your terminal
        var cwd: String?            // relative to the folder holding the file; default "."
        var dependsOn: [String]?    // names of other services that must be up first
        var container: String?      // a Docker container to start instead of running a command
    }

    static let fileName = "switchboard.json"

    // MARK: Finding and reading

    /// The nearest folder at or above `path` that holds a switchboard.json.
    static func find(from path: String) -> String? {
        var dir = path
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: dir + "/" + fileName) { return dir }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent == "/" { break }
            dir = parent
        }
        return nil
    }

    static func load(root: String) -> StackFile? {
        guard let data = FileManager.default.contents(atPath: root + "/" + fileName) else { return nil }
        return try? JSONDecoder().decode(StackFile.self, from: data)
    }

    func write(to root: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(self).write(to: URL(fileURLWithPath: root + "/" + Self.fileName), options: .atomic)
    }

    // MARK: File to servers

    /// The servers this file declares, as stopped rows with a Start button. Keys match what the scanner produces
    /// for a running server (`<project folder>:<port>`), so a running server and its declaration merge into one row.
    func servers(root: String) -> [KnownServer] {
        let group = (root as NSString).lastPathComponent
        let keyOf = Dictionary(services.map { ($0.name, "\(root):\($0.port)") }, uniquingKeysWith: { a, _ in a })
        return services.map { s in
            var start: KnownStart?
            if let command = s.command, !command.isEmpty {
                let cwd = Self.insideRoot(s.cwd, root: root)
                start = KnownStart(exec: "/bin/zsh", argv: ["zsh", "-lc", command], cwd: cwd)
            }
            return KnownServer(key: "\(root):\(s.port)", port: s.port, title: s.name, group: group, projectPath: root, start: start,
                               containerID: s.container, lastSeen: Date(), uses: (s.dependsOn ?? []).compactMap { keyOf[$0] })
        }
    }

    /// The service's folder, kept inside the project. `../..` or an absolute path falls back to the project folder.
    static func insideRoot(_ cwd: String?, root: String) -> String {
        guard let c = cwd, !c.isEmpty, c != "." else { return root }
        guard !c.hasPrefix("/"), !c.hasPrefix("~") else { return root }
        let full = URL(fileURLWithPath: root + "/" + c).standardizedFileURL.path
        return full == root || full.hasPrefix(root + "/") ? full : root
    }

    // MARK: Servers to file

    /// Builds the file from servers Switchboard has seen in this project.
    static func export(root: String, servers: [KnownServer], containerNames: [String: String] = [:]) -> StackFile {
        let mine = servers.filter { $0.projectPath == root && $0.canStart }.sorted { $0.port < $1.port }
        var taken = Set<String>()
        var nameOf: [String: String] = [:]
        for k in mine {
            var base: String
            if let cwd = k.start?.cwd, cwd != root, cwd.hasPrefix(root + "/") { base = (cwd as NSString).lastPathComponent }
            else { base = k.title.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined() }
            if taken.contains(base) { base += "-\(k.port)" }
            taken.insert(base)
            nameOf[k.key] = base
        }
        let services = mine.map { k -> Service in
            var cwd: String?
            if let c = k.start?.cwd, c != root, c.hasPrefix(root + "/") { cwd = String(c.dropFirst(root.count + 1)) }
            return Service(name: nameOf[k.key]!, port: k.port,
                           command: k.start.map { portableCommand($0, root: root) },
                           cwd: cwd,
                           dependsOn: (k.uses ?? []).compactMap { nameOf[$0] }.sorted().nilIfEmpty,
                           container: k.containerName ?? k.containerID.map { containerNames[$0] ?? $0 })
        }
        return StackFile(name: (root as NSString).lastPathComponent, services: services)
    }

    static let redacted = "<redacted>"
    private static let secretName = try! NSRegularExpression(pattern: "(token|secret|passw|api[-_]?key|auth|credential|bearer|private[-_]?key)", options: .caseInsensitive)
    private static func looksSecret(_ s: String) -> Bool { secretName.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    /// The value of `--token abc`, `--token=abc` or `TOKEN=abc` is replaced, so a secret never ends up in a committed file.
    static func redactSecrets(_ args: [String]) -> [String] {
        var out: [String] = [], hideNext = false
        for a in args {
            if hideNext { out.append(redacted); hideNext = false; continue }
            if let eq = a.firstIndex(of: "="), looksSecret(String(a[..<eq])) { out.append(String(a[..<eq]) + "=" + redacted); continue }
            if a.hasPrefix("-"), looksSecret(a) { hideNext = true }
            out.append(a)
        }
        return out
    }

    /// A command that works on another machine: `node /Users/me/.nvm/.../npm-cli.js run dev` becomes `npm run dev`.
    static func portableCommand(_ s: KnownStart, root: String) -> String {
        var tool = (s.exec as NSString).lastPathComponent
        var args = Array(s.argv.dropFirst())
        if let first = args.first {
            let f = first.lowercased()
            if f.hasSuffix("npm-cli.js") { tool = "npm"; args.removeFirst() }
            else if f.hasSuffix("npx-cli.js") { tool = "npx"; args.removeFirst() }
            else if f.contains("/pnpm") { tool = "pnpm"; args.removeFirst() }
            else if f.contains("/yarn") { tool = "yarn"; args.removeFirst() }
        }
        let home = NSHomeDirectory()
        let parts = ([tool] + redactSecrets(args)).map { a -> String in
            var v = a
            if v.hasPrefix(root + "/") { v = "./" + v.dropFirst(root.count + 1) }
            else if v == root { v = "." }
            else if v.hasPrefix(home + "/") { v = "~" + v.dropFirst(home.count) }
            return v.range(of: #"^[A-Za-z0-9_@%+=:,./~-]+$"#, options: .regularExpression) != nil ? v : shellQuote(v)
        }
        return parts.joined(separator: " ")
    }
}

private extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
