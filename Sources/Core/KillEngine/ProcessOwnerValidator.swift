import Foundation
import Darwin

protocol ProcessOwnershipValidator {
    func ownerUID(of pid: pid_t) -> uid_t?
    func isOwnedByCurrentUser(pid: pid_t) -> Bool
}

struct ProcessOwnerValidator: ProcessOwnershipValidator {
    func ownerUID(of pid: pid_t) -> uid_t? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size)
        guard result == size else { return nil }
        return info.pbsi_uid
    }

    func isOwnedByCurrentUser(pid: pid_t) -> Bool {
        guard let uid = ownerUID(of: pid) else { return false }
        return uid == getuid()
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

private let PROC_PIDT_SHORTBSDINFO: Int32 = 13

@_silgen_name("proc_pidinfo")
private func proc_pidinfo(
    _ pid: Int32,
    _ flavor: Int32,
    _ arg: UInt64,
    _ buffer: UnsafeMutableRawPointer?,
    _ buffersize: Int32
) -> Int32
