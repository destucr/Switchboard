import Darwin
import Foundation

/// Thin wrappers over libproc / sysctl so we can inspect same-user processes without spawning `ps`.
enum Proc {
    static func path(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let p = cString(&info.pvi_cdir.vip_path)
        return p.isEmpty ? nil : p
    }

    static func bsd(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    /// Direct children of a process.
    static func children(_ pid: Int32) -> [Int32] {
        let cap = 256
        var buf = [Int32](repeating: 0, count: cap)
        let n = proc_listchildpids(pid, &buf, Int32(cap * MemoryLayout<Int32>.size))
        return n > 0 ? Array(buf.prefix(Int(n))) : []
    }

    /// Everything a process started, however deep.
    static func descendants(of root: Int32, limit: Int = 200) -> [Int32] {
        var queue = children(root), out: [Int32] = [], seen: Set<Int32> = [root]
        while let pid = queue.popLast(), out.count < limit {
            guard seen.insert(pid).inserted else { continue }
            out.append(pid)
            queue.append(contentsOf: children(pid))
        }
        return out
    }

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var t = mach_timebase_info_data_t(); mach_timebase_info(&t)
        return (UInt64(t.numer), UInt64(max(t.denom, 1)))
    }()

    /// CPU time used so far and memory in use, for a process and everything it started (so `npm run dev` counts its node).
    static func usage(of root: Int32) -> (cpuNs: UInt64, rss: UInt64)? {
        var queue = [root], seen = Set<Int32>(), cpu: UInt64 = 0, rss: UInt64 = 0, found = false
        while let pid = queue.popLast(), seen.count < 200 {
            guard seen.insert(pid).inserted else { continue }
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size {
                found = true
                cpu += (info.pti_total_user + info.pti_total_system) * timebase.numer / timebase.denom
                rss += info.pti_resident_size
            }
            queue.append(contentsOf: children(pid))
        }
        return found ? (cpu, rss) : nil
    }

    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Path behind a file descriptor if it is a vnode (regular file, tty, ...).
    static func fdPath(_ pid: Int32, fd: Int32) -> String? {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
        let p = cString(&info.pvip.vip_path)
        return p.isEmpty ? nil : p
    }

    /// Exec path, argv and environment (KERN_PROCARGS2).
    static func argsEnv(_ pid: Int32) -> (exec: String, argv: [String], env: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        buf = Array(buf.prefix(size))

        var argc: Int32 = 0
        memcpy(&argc, buf, 4)
        var i = 4

        func next() -> String? {
            guard i < buf.count else { return nil }
            var j = i
            while j < buf.count && buf[j] != 0 { j += 1 }
            let s = String(decoding: buf[i..<j], as: UTF8.self)
            i = j + 1
            return s
        }

        guard let exec = next() else { return nil }
        while i < buf.count && buf[i] == 0 { i += 1 }
        var argv: [String] = []
        for _ in 0..<Int(argc) { if let a = next() { argv.append(a) } }
        var env: [String: String] = [:]
        while let e = next(), !e.isEmpty {
            if let eq = e.firstIndex(of: "=") {
                env[String(e[..<eq])] = String(e[e.index(after: eq)...])
            }
        }
        return (exec, argv, env)
    }

    private static func cString<T>(_ tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }
}

/// Runs a command and captures stdout. Kills it if it exceeds `timeout`.
@discardableResult
func runCapture(_ exe: String, _ args: [String], timeout: TimeInterval = 6) -> (out: String, status: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return ("", -1) }
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    killer.cancel()
    return (String(decoding: data, as: UTF8.self), p.terminationStatus)
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func formatDuration(_ seconds: Int) -> String {
    let s = max(seconds, 0)
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
    return "\(s / 86400)d \(s % 86400 / 3600)h"
}

func abbreviateHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

/// What a server costs right now. CPU is a share of one core, so a busy multi-threaded server can pass 100.
struct Usage: Equatable {
    var cpu: Double
    var memory: UInt64

    static func cpuPercent(from before: UInt64, to now: UInt64, seconds: Double) -> Double {
        guard now >= before, seconds > 0.2 else { return 0 }
        return Double(now - before) / (seconds * 1_000_000_000) * 100
    }

    static func memoryText(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : "\(Int(mb.rounded())) MB"
    }

    var memoryText: String { Self.memoryText(memory) }
    var busy: Bool { cpu >= 50 }   // worth pointing out on the row
    var cpuText: String { "\(Int(cpu.rounded()))% CPU" }
}
