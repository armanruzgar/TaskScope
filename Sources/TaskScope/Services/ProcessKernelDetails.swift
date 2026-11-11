import Darwin
import Foundation
import Security

/// The per-process kernel reads behind Process Detail. None runs a child
/// process. libproc refuses most of them for other users' processes.
enum ProcessKernelDetails {
    /// Why a libproc read failed, worded for the sheet.
    static func reason(forErrno code: Int32) -> String {
        switch code {
        case EPERM, EACCES: "macOS shows this only for your own processes."
        case ESRCH: "The process has exited."
        default: "It could not be read (\(String(cString: strerror(code))))."
        }
    }

    static func threadCount(pid: Int32) -> ProcessDetailValue<Int> {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        guard read == size else { return .unavailable(reason(forErrno: read <= 0 ? errno : EIO)) }
        return .available(Int(info.pti_threadnum))
    }

    /// The descriptor count and listening ports, from one descriptor list.
    static func openFiles(pid: Int32) -> ProcessDetailValue<ProcessOpenFiles> {
        switch fileDescriptors(pid: pid) {
        case .success(let descriptors):
            return .available(ProcessOpenFiles(
                descriptorCount: descriptors.count,
                listeningPorts: listeningPorts(pid: pid, descriptors: descriptors)
            ))
        case .failure(let failure):
            return .unavailable(reason(forErrno: failure.errno))
        }
    }

    /// The process's open file descriptors (files, sockets, pipes and others).
    static func fileDescriptors(pid: Int32) -> Result<[proc_fdinfo], ProcessDetailFailure> {
        let stride = MemoryLayout<proc_fdinfo>.stride
        for _ in 0..<3 {
            let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard needed > 0 else { return .failure(ProcessDetailFailure(errno: errno)) }
            // Room for descriptors opened between the two calls.
            var list = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 32)
            let filled = list.withUnsafeMutableBytes {
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
            }
            guard filled > 0 else { return .failure(ProcessDetailFailure(errno: errno)) }
            let count = Int(filled) / stride
            if count < list.count { return .success(Array(list.prefix(count))) }
        }
        return .failure(ProcessDetailFailure(errno: EAGAIN))
    }

    /// TCP sockets in the listening state and bound UDP sockets with no peer.
    static func listeningPorts(pid: Int32, descriptors: [proc_fdinfo]) -> [ListeningPort] {
        var ports = Set<ListeningPort>()
        for descriptor in descriptors where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { continue }
            if info.psi.soi_kind == Int32(SOCKINFO_TCP) {
                let tcp = info.psi.soi_proto.pri_tcp
                guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
                ports.insert(ListeningPort(transport: .tcp, port: port(tcp.tcpsi_ini.insi_lport)))
            } else if info.psi.soi_kind == Int32(SOCKINFO_IN), info.psi.soi_protocol == IPPROTO_UDP {
                let udp = info.psi.soi_proto.pri_in
                guard udp.insi_lport != 0, udp.insi_fport == 0 else { continue }
                ports.insert(ListeningPort(transport: .udp, port: port(udp.insi_lport)))
            }
        }
        return ports.sorted()
    }

    /// Ports are stored in network byte order in the low 16 bits.
    private static func port(_ value: Int32) -> Int {
        Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: value)))
    }

    /// The signing identifier and Team ID of the code the PID runs, from the
    /// code-signing information the kernel holds for it. It does not check
    /// the signature and never uses the network.
    static func codeSignature(pid: Int32) -> ProcessCodeSignature {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        if guestStatus == errSecCSUnsigned { return .unsigned }
        guard guestStatus == errSecSuccess, let code else { return .unavailable(signatureReason(guestStatus)) }
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        if staticStatus == errSecCSUnsigned { return .unsigned }
        guard staticStatus == errSecSuccess, let staticCode else { return .unavailable(signatureReason(staticStatus)) }
        var information: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        if infoStatus == errSecCSUnsigned { return .unsigned }
        guard infoStatus == errSecSuccess, let values = information as? [String: Any] else {
            return .unavailable(signatureReason(infoStatus))
        }
        guard let identifier = values[kSecCodeInfoIdentifier as String] as? String else { return .unsigned }
        let flags = (values[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return .signed(
            identifier: identifier,
            teamID: values[kSecCodeInfoTeamIdentifier as String] as? String,
            isPlatformBinary: values[kSecCodeInfoPlatformIdentifier as String] != nil,
            isAdHoc: flags & SecCodeSignatureFlags.adhoc.rawValue != 0
        )
    }

    private static func signatureReason(_ status: OSStatus) -> String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return "macOS did not return it (\(message))."
    }
}

struct ProcessDetailFailure: Error, Equatable {
    var errno: Int32
}

/// The kernel reads behind Process Detail's extra rows, as properties whose
/// defaults are the real ones, so tests can script them.
struct ProcessDetailKernelReads: Sendable {
    var entry: @Sendable (Int32) -> KernelProcessTable.Lookup = { KernelProcessTable.entry(for: $0) }
    var executablePath: @Sendable (Int32) -> String? = { ProcessListReader.executablePath(for: $0) }
    var threadCount: @Sendable (Int32) -> ProcessDetailValue<Int> = { ProcessKernelDetails.threadCount(pid: $0) }
    var openFiles: @Sendable (Int32) -> ProcessDetailValue<ProcessOpenFiles> = { ProcessKernelDetails.openFiles(pid: $0) }
    var codeSignature: @Sendable (Int32) -> ProcessCodeSignature = { ProcessKernelDetails.codeSignature(pid: $0) }

    static let live = ProcessDetailKernelReads()
}
