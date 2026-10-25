import Foundation
import Darwin

public protocol ProcessOwnershipValidator {
    func ownerUID(of pid: pid_t) -> uid_t?
    func isOwnedByCurrentUser(pid: pid_t) -> Bool
}

public protocol ProcessIdentityProvider {
    func identity(of pid: pid_t) -> ProcessIdentity?
}

public protocol ProcessNameProvider {
    func processName(of pid: pid_t) -> String?
}

public struct ProcessIdentity: Equatable {
    public let uid: uid_t
    public let startTime: Date

    public init(uid: uid_t, startTime: Date) {
        self.uid = uid
        self.startTime = startTime
    }
}

public struct ProcessOwnerValidator: ProcessOwnershipValidator, ProcessIdentityProvider, ProcessNameProvider {
    public init() {}

    public func ownerUID(of pid: pid_t) -> uid_t? {
        guard let info = shortInfo(pid: pid) else { return nil }
        return info.pbsi_uid
    }

    public func isOwnedByCurrentUser(pid: pid_t) -> Bool {
        guard let uid = ownerUID(of: pid) else { return false }
        return uid == getuid()
    }

    public func identity(of pid: pid_t) -> ProcessIdentity? {
        guard let short = shortInfo(pid: pid) else { return nil }
        guard let startTime = startTime(of: pid) else { return nil }
        return ProcessIdentity(uid: short.pbsi_uid, startTime: startTime)
    }

    private func shortInfo(pid: pid_t) -> proc_bsdshortinfo? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size)
        guard result == size else { return nil }
        return info
    }

    private func startTime(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard result == size else { return nil }
        let seconds = TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        return Date(timeIntervalSince1970: seconds)
    }

    public func processName(of pid: pid_t) -> String? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        var bytes = [Int8](repeating: 0, count: 16)
        _ = withUnsafeMutablePointer(to: &info.pbsi_comm) { commPtr in
            commPtr.withMemoryRebound(to: Int8.self, capacity: 16) { cPtr in
                memcpy(&bytes, cPtr, 16)
            }
        }
        let trimmed = bytes.prefix { $0 != 0 }
        return String(decoding: trimmed.map(UInt8.init), as: UTF8.self)
    }
}

// MARK: - libproc bindings

private struct proc_bsdshortinfo {
    var pbsi_pid: UInt32 = 0
    var pbsi_ppid: UInt32 = 0
    var pbsi_pgid: UInt32 = 0
    var pbsi_status: UInt32 = 0
    var pbsi_comm: (
        Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
        Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8
    ) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    var pbsi_flags: UInt32 = 0
    var pbsi_uid: uid_t = 0
    var pbsi_gid: gid_t = 0
    var pbsi_ruid: uid_t = 0
    var pbsi_rgid: gid_t = 0
    var pbsi_svuid: uid_t = 0
    var pbsi_svgid: gid_t = 0
    var pbsi_rfu: UInt32 = 0
}

private struct proc_bsdinfo {
    var pbi_flags: UInt32 = 0
    var pbi_status: UInt32 = 0
    var pbi_xstatus: UInt32 = 0
    var pbi_pid: UInt32 = 0
    var pbi_ppid: UInt32 = 0
    var pbi_uid: uid_t = 0
    var pbi_gid: gid_t = 0
    var pbi_ruid: uid_t = 0
    var pbi_rgid: gid_t = 0
    var pbi_svuid: uid_t = 0
    var pbi_svgid: gid_t = 0
    var rfu_1: UInt32 = 0
    var pbi_comm: Comm16 = zeros16
    var pbi_name: Name32 = zeros32
    var pbi_nfiles: UInt32 = 0
    var pbi_pgid: UInt32 = 0
    var pbi_pjobc: UInt32 = 0
    var e_tdev: UInt32 = 0
    var e_tpgid: UInt32 = 0
    var pbi_nice: Int32 = 0
    var pbi_start_tvsec: UInt64 = 0
    var pbi_start_tvusec: UInt64 = 0
}

private typealias Comm16 = (
    Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
    Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8
)
private typealias Name32 = (
    Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
    Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
    Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
    Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8
)
private let zeros16: Comm16 = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
private let zeros32: Name32 = (
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
)

private let PROC_PIDT_SHORTBSDINFO: Int32 = 13
private let PROC_PIDTBSDINFO: Int32 = 3

@_silgen_name("proc_pidinfo")
private func proc_pidinfo(
    _ pid: Int32,
    _ flavor: Int32,
    _ arg: UInt64,
    _ buffer: UnsafeMutableRawPointer?,
    _ buffersize: Int32
) -> Int32
