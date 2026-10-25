import Foundation
import AppKit

struct ReleaseInfo: Equatable {
    var version: String
    var notes: String
    var page: URL
}

/// Asks GitHub whether a newer release exists. One request to a public endpoint, with nothing about the user in it.
enum Updates {
    static let endpoint = URL(string: "https://api.github.com/repos/destucr/Switchboard/releases/latest")!

    enum Failure: Error, Equatable {
        case offline, rateLimited, unexpected
        var text: String {
            switch self {
            case .offline: return "Can't reach GitHub. Check your connection."
            case .rateLimited: return "GitHub is limiting requests right now. Try again later."
            case .unexpected: return "GitHub sent something Switchboard doesn't understand."
            }
        }
    }

    /// Numeric comparison, so 1.10.0 is newer than 1.9.0. A leading "v" is ignored. Anything that isn't a plain version is never newer.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int]? {
            let t = s.hasPrefix("v") ? String(s.dropFirst()) : s
            let p = t.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            return p.isEmpty || p.contains(where: { $0 == nil }) ? nil : p.map { $0! }
        }
        guard var a = parts(candidate), var b = parts(current) else { return false }
        while a.count < b.count { a.append(0) }
        while b.count < a.count { b.append(0) }
        return a.lexicographicallyPrecedes(b) ? false : a != b
    }

    static func parse(_ data: Data) -> ReleaseInfo? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String, !tag.isEmpty,
              j["draft"] as? Bool != true, j["prerelease"] as? Bool != true,
              let html = j["html_url"] as? String, let page = URL(string: html),
              page.scheme == "https", page.host == "github.com" else { return nil }
        return ReleaseInfo(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, notes: (j["body"] as? String) ?? "", page: page)
    }

    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    static func latest() async -> Result<ReleaseInfo, Failure> {
        var req = URLRequest(url: endpoint, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Switchboard/\(current)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 403 || code == 429 { return .failure(.rateLimited) }
            guard code == 200, let info = parse(data) else { return .failure(.unexpected) }
            return .success(info)
        } catch { return .failure(.offline) }
    }

    // MARK: Installing

    /// Homebrew installed this copy if its cask is in the Caskroom.
    static var brew: String? {
        guard ["/opt/homebrew/Caskroom/switchboard", "/usr/local/Caskroom/switchboard"].contains(where: { FileManager.default.fileExists(atPath: $0) }) else { return nil }
        return ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `brew upgrade` off the main thread. Returns an error message, or nil when the installed app now has the new version.
    static func upgrade(using brew: String, to version: String) async -> String? {
        await Task.detached {
            let r = runCapture(brew, ["upgrade", "--cask", "destucr/tap/switchboard"], timeout: 300)
            let installed = (NSDictionary(contentsOfFile: "/Applications/Switchboard.app/Contents/Info.plist")?["CFBundleShortVersionString"] as? String) ?? ""
            if installed == version || isNewer(installed, than: version) { return nil }   // a newer release may have landed since the check
            if r.status != 0 {
                let last = r.out.split(separator: "\n").last.map(String.init) ?? ""
                return "Homebrew could not update it. \(last)".trimmingCharacters(in: .whitespaces)
            }
            return "Homebrew does not have \(version) yet. Try again in a minute."
        }.value
    }

    /// Starts the new copy after this one has quit.
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open /Applications/Switchboard.app"]
        try? p.run()
        NSApp.terminate(nil)
    }
}
