import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Metadata about a live process used to enrich a parsed `PortItem`.
public struct ProcessMetadata: Sendable, Equatable {
    public let executablePath: String?
    public let ramBytes: Int64?
    public let parentPID: pid_t?
    public let startedAt: Date?

    public init(
        executablePath: String? = nil,
        ramBytes: Int64? = nil,
        parentPID: pid_t? = nil,
        startedAt: Date? = nil
    ) {
        self.executablePath = executablePath
        self.ramBytes = ramBytes
        self.parentPID = parentPID
        self.startedAt = startedAt
    }
}

/// Abstracts Darwin proc lookups so scanners stay testable without hitting real processes.
public protocol ProcessInfoProvider: Sendable {
    func metadata(for pid: pid_t) -> ProcessMetadata
}

/// Default provider using `libproc` APIs.
///
/// RAM is read from `proc_pid_rusage` (`ri_phys_footprint` in bytes), which is the closest
/// per-PID equivalent to Activity Monitor's memory figure. The docs mention `ru_maxrss`, but
/// `rusage_info_v0` exposes `ri_phys_footprint` instead; we use that and fall back to `ps`.
///
/// Parent PID and start time come from `proc_pidinfo(PROC_PIDTBSDINFO)`. Path comes from
/// `proc_pidpath`. These calls require no special entitlements and only work for processes
/// owned by the current user, which is exactly the security boundary we want.
public struct RealProcessInfoProvider: ProcessInfoProvider {
    public init() {}

    public func metadata(for pid: pid_t) -> ProcessMetadata {
        guard pid > 0 else { return ProcessMetadata() }
        return ProcessMetadata(
            executablePath: executablePath(for: pid),
            ramBytes: ramBytes(for: pid),
            parentPID: parentPID(for: pid),
            startedAt: startedAt(for: pid)
        )
    }
}

#if canImport(Darwin)
private extension RealProcessInfoProvider {
    func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes: [UInt8] = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8)
    }

    func ramBytes(for pid: pid_t) -> Int64? {
        var info = rusage_info_v0()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { typed in
                proc_pid_rusage(pid, RUSAGE_INFO_V0, typed)
            }
        }
        if result == 0 {
            return Int64(info.ri_phys_footprint)
        }
        return ramBytesViaPS(pid: pid)
    }

    func ramBytesViaPS(pid: pid_t) -> Int64? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "rss=", "-p", String(pid)]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let kilobytes = Int64(text) else {
            return nil
        }
        return kilobytes * 1024
    }

    func parentPID(for pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    func startedAt(for pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }
}
#else
private extension RealProcessInfoProvider {
    func executablePath(for pid: pid_t) -> String? { nil }
    func ramBytes(for pid: pid_t) -> Int64? { nil }
    func parentPID(for pid: pid_t) -> pid_t? { nil }
    func startedAt(for pid: pid_t) -> Date? { nil }
}
#endif
