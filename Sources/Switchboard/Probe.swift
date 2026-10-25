import Darwin
import Foundation

/// What a listening port answers when asked for `GET /` over plain HTTP.
enum WebKind: String {
    case page   // serves HTML, worth opening in a browser
    case api    // speaks HTTP but not HTML (JSON API, 404 JSON, ...)
    case none   // not HTTP, or not probed (databases)
}

struct ProbeResult {
    var kind: WebKind
    var status: Int?
    var ms: Int?
    var title: String? = nil   // the page's <title>
    var icon: String? = nil    // where its icon lives on this server, like /favicon.svg
}

enum Probe {
    private static let pageReadLimit = 16_384
    private static let lock = NSLock()
    private static var cache: [String: (result: ProbeResult, at: Date)] = [:]

    static func check(pid: Int32?, port: Int, host: String) -> ProbeResult {
        if port == 443 || port == 8443 { return ProbeResult(kind: .page, status: nil, ms: nil) }
        let key = "\(pid ?? 0):\(port)"
        lock.lock(); let hit = cache[key]; lock.unlock()
        if let hit, Date().timeIntervalSince(hit.at) < (hit.result.kind == .none ? 5 : 8) { return hit.result }
        let r = request(port: port, host: host)
        lock.lock(); cache[key] = (r, Date()); lock.unlock()
        return r
    }

    /// True if something accepts connections on this port (any protocol).
    static func isListening(_ port: Int) -> Bool {
        for v6 in [false, true] { if let fd = connectLoopback(port: port, v6: v6) { close(fd); return true } }
        return false
    }

    private static func request(port: Int, host: String) -> ProbeResult {
        let order = host.contains("::1") ? [true, false] : [false, true]
        for v6 in order {
            let t0 = DispatchTime.now()
            guard let fd = connectLoopback(port: port, v6: v6) else { continue }
            defer { close(fd) }
            let req = "GET / HTTP/1.0\r\nHost: localhost:\(port)\r\nAccept: text/html,*/*\r\nUser-Agent: Switchboard\r\nConnection: close\r\n\r\n"
            guard send(fd, req, req.utf8.count, 0) > 0 else { return ProbeResult(kind: .none, status: nil, ms: nil) }

            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            var firstByte: DispatchTime?
            var headerDone = false, isPage = false
            // Headers are enough for an API. A page is read until the end of its <head>, so the title and icon are in view.
            while data.count < Self.pageReadLimit {
                let n = recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                if firstByte == nil { firstByte = .now() }
                data.append(buf, count: n)
                if !headerDone, data.range(of: Data("\r\n\r\n".utf8)) != nil {
                    headerDone = true
                    isPage = classify(String(decoding: data, as: UTF8.self)).0 == .page
                }
                if headerDone && !isPage { break }
                if headerDone && String(decoding: data, as: UTF8.self).lowercased().contains("</head>") { break }
            }
            let text = String(decoding: data, as: UTF8.self)
            let (kind, status) = classify(text)
            let ms = firstByte.map { Int(($0.uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000) }
            var r = ProbeResult(kind: kind, status: status, ms: kind == .none ? nil : ms)
            if kind == .page, let split = text.range(of: "\r\n\r\n") {
                let info = pageInfo(String(text[split.upperBound...]))
                r.title = info.title
                r.icon = info.icon.flatMap { iconPath($0, port: port) }
            }
            return r
        }
        return ProbeResult(kind: .none, status: nil, ms: nil)
    }

    // MARK: Page details

    /// The page's title and the icon it points to. The text comes from a local server, so it is cleaned before anyone sees it.
    static func pageInfo(_ html: String) -> (title: String?, icon: String?) {
        var title: String?
        if let m = try? NSRegularExpression(pattern: "<title[^>]*>(.*?)</title>", options: [.caseInsensitive, .dotMatchesLineSeparators]),
           let r = m.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), let range = Range(r.range(at: 1), in: html) {
            title = cleanTitle(String(html[range]))
        }
        return (title, iconHref(html))
    }

    static func cleanTitle(_ raw: String) -> String? {
        var t = raw
        for (entity, ch) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            t = t.replacingOccurrences(of: entity, with: ch)
        }
        t = t.unicodeScalars.map { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format ? " " : String($0) }.joined()
        t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if t.count > 80 { t = String(t.prefix(80)) + "…" }
        return t.isEmpty ? nil : t
    }

    /// The href of the best <link rel="icon">. A plain icon beats an Apple touch icon.
    static func iconHref(_ html: String) -> String? {
        guard let tags = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive),
              let attr = try? NSRegularExpression(pattern: "([a-zA-Z-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))") else { return nil }
        var best: (rank: Int, href: String)?
        for m in tags.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let tr = Range(m.range, in: html) else { continue }
            let tag = String(html[tr])
            var rel = "", href = ""
            for a in attr.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
                guard let nr = Range(a.range(at: 1), in: tag) else { continue }
                let value = (2...4).compactMap { Range(a.range(at: $0), in: tag).map { String(tag[$0]) } }.first ?? ""
                switch tag[nr].lowercased() { case "rel": rel = value.lowercased(); case "href": href = value; default: break }
            }
            let words = rel.split(separator: " ").map(String.init)
            guard !href.isEmpty, words.contains(where: { $0.hasSuffix("icon") }), !words.contains("mask-icon") else { continue }
            let rank = words.contains("icon") ? 0 : 1
            if best == nil || rank < best!.rank { best = (rank, href) }
        }
        return best?.href
    }

    /// A path on this same server, or nil. Icons on other hosts are ignored, so a page can't make Switchboard call out.
    static func iconPath(_ href: String, port: Int) -> String? {
        let h = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, h.count <= 512, !h.hasPrefix("data:"), !h.hasPrefix("//"),
              h.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else { return nil }
        if h.hasPrefix("http://") || h.hasPrefix("https://") {
            guard let u = URL(string: h), let host = u.host?.lowercased(), ["localhost", "127.0.0.1", "::1"].contains(host),
                  (u.port ?? (h.hasPrefix("https") ? 443 : 80)) == port else { return nil }
            let path = u.path.isEmpty ? "/" : u.path
            return u.query.map { path + "?" + $0 } ?? path
        }
        if h.contains("://") { return nil }
        return h.hasPrefix("/") ? h : "/" + (h.hasPrefix("./") ? String(h.dropFirst(2)) : h)
    }

    /// An icon file from this server, or nil. Only a plain 200 under 256 KB that is not a page counts.
    static func fetchIcon(port: Int, host: String, path: String) -> Data? {
        guard port != 443, port != 8443, path.hasPrefix("/") else { return nil }
        let order = host.contains("::1") ? [true, false] : [false, true]
        for v6 in order {
            guard let fd = connectLoopback(port: port, v6: v6) else { continue }
            defer { close(fd) }
            let req = "GET \(path) HTTP/1.0\r\nHost: localhost:\(port)\r\nAccept: image/*\r\nUser-Agent: Switchboard\r\nConnection: close\r\n\r\n"
            guard send(fd, req, req.utf8.count, 0) > 0 else { return nil }
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 16_384)
            while data.count <= 262_144 + 4096 {
                let n = recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let head = String(decoding: data[..<split.lowerBound], as: UTF8.self).lowercased()
            let body = data[split.upperBound...]
            guard head.hasPrefix("http/"), head.split(separator: " ").dropFirst().first == "200", !body.isEmpty, body.count <= 262_144,
                  !head.contains("content-type: text/html") else { return nil }
            return Data(body)
        }
        return nil
    }

    static func classify(_ response: String) -> (WebKind, Int?) {
        guard response.hasPrefix("HTTP/") else { return (.none, nil) }
        let status = response.split(separator: " ", maxSplits: 2).dropFirst().first.flatMap { Int($0) }
        let lower = response.lowercased()
        let headEnd = lower.range(of: "\r\n\r\n")?.lowerBound ?? lower.endIndex
        let headers = lower[..<headEnd]
        if headers.contains("content-type:") {
            let line = headers.components(separatedBy: "\r\n").first { $0.hasPrefix("content-type:") } ?? ""
            return (line.contains("html") ? .page : .api, status)
        }
        let body = lower[headEnd...].drop { $0.isWhitespace }
        return (body.hasPrefix("<!doctype html") || body.hasPrefix("<html") ? .page : .api, status)
    }

    private static func connectLoopback(port: Int, v6: Bool) -> Int32? {
        let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var tv = timeval(tv_sec: 0, tv_usec: 800_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        let rc: Int32
        if v6 {
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = UInt16(port).bigEndian
            a.sin6_addr = in6addr_loopback
            rc = withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = UInt16(port).bigEndian
            a.sin_addr.s_addr = inet_addr("127.0.0.1")
            rc = withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        if rc != 0 { close(fd); return nil }
        return fd
    }
}
