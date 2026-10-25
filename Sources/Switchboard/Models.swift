import Foundation

enum EntryKind: String {
    case dev, database, docker, other

    var symbol: String {
        switch self {
        case .dev: return "terminal"
        case .database: return "cylinder.split.1x2"
        case .docker: return "shippingbox"
        case .other: return "gearshape"
        }
    }
}

struct DockerContainer: Hashable {
    var id: String
    var name: String
    var image: String
    var service: String?
}

/// Everything needed to bring a process back after killing it.
struct RestartSpec: Hashable {
    var exec: String
    var argv: [String]
    var env: [String: String]
    var cwd: String
    var rootPid: Int32
}

struct PortEntry: Identifiable, Hashable {
    var id: String
    var port: Int
    var host: String
    var lanExposed: Bool
    var kind: EntryKind
    var title: String
    var pid: Int32?
    var command: String
    var projectName: String?
    var projectPath: String?
    var group: String
    var uptime: String?
    var container: DockerContainer?
    var web: WebKind
    var restart: RestartSpec?
    var status: Int? = nil   // HTTP status of GET /
    var ms: Int? = nil       // response time of GET /
    var pageTitle: String? = nil   // the page's <title>
    var iconPath: String? = nil    // where its icon lives on the same server

    /// Stable identity across restarts and PID changes.
    var key: String { "\(projectPath ?? container?.name ?? title):\(port)" }

    /// What Copy puts on the clipboard, and what the row shows so you can see it first.
    var address: String {
        if web != .none { return localURL.absoluteString }
        let t = (title + " " + (container?.image ?? "")).lowercased()
        let schemes = ["postgres": "postgresql", "mysql": "mysql", "mariadb": "mysql", "mongo": "mongodb", "redis": "redis", "valkey": "redis"]
        if let scheme = schemes.first(where: { t.contains($0.key) })?.value { return "\(scheme)://localhost:\(port)" }
        return "localhost:\(port)"
    }

    /// A command that fetches the page. A local https server usually has a certificate curl doesn't trust, so those get -k.
    var curl: String { "curl -i\(localURL.scheme == "https" ? "k" : "") \(localURL.absoluteString)" }

    var copyLabel: String { address.contains("://") ? "Copy URL" : "Copy address" }

    var localURL: URL { URL(string: "\(port == 443 || port == 8443 ? "https" : "http")://localhost:\(port)")! }
}

/// How to start a server again. Deliberately has no environment variables, so no secrets reach the disk.
struct KnownStart: Codable, Hashable {
    var exec: String
    var argv: [String]
    var cwd: String
}

/// A server we saw running before. Shown as a grey row with a Start button once it stops.
struct KnownServer: Codable, Hashable, Identifiable {
    var key: String
    var port: Int
    var title: String
    var group: String
    var projectPath: String?
    var start: KnownStart?
    var containerID: String?
    var lastSeen: Date
    var uses: [String]? = nil   // servers this one was seen talking to; decides the start order
    var containerName: String? = nil   // a name works on any machine; an id does not
    var stopReason: String? = nil   // why it stopped, in one line
    var stoppedAt: Date? = nil
    var id: String { key }
    var canStart: Bool { start != nil || containerID != nil }
    /// Started from a folder that has since been deleted or moved, so it can never start again.
    var folderMissing: Bool { containerID == nil && start.map { !FileManager.default.fileExists(atPath: $0.cwd) } == true }
}

struct ProjectGroup: Identifiable {
    var name: String
    var path: String?
    var running: [PortEntry]
    var stopped: [KnownServer]
    var id: String { name }
}
