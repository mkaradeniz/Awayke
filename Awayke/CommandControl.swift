import Foundation
import Darwin

nonisolated enum ControlCommand: String, CaseIterable, Sendable {
    case on, off, status
}

nonisolated struct ControlStatus: Codable, Sendable {
    let active: Bool
    let intent: Bool
    let suspendedForBattery: Bool
    let batteryOverride: Bool
    let batteryThreshold: Int
    let session: String
    let remainingSeconds: Int?
    let helper: String
    let busy: Bool
}

nonisolated struct ControlReply: Codable, Sendable {
    let ok: Bool
    var status: ControlStatus? = nil
    var error: String? = nil
}

nonisolated enum ControlSocket {
    static var path: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/daemonphantom.Awayke/control.sock").path
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "Awayke.Control", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func systemError(_ operation: String) -> NSError {
        failure("\(operation): \(String(cString: strerror(errno)))")
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw failure("The Awayke control socket path is too long.")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            bytes.withUnsafeBytes { target.copyBytes(from: $0) }
        }
        return address
    }

    static func configure(_ descriptor: Int32, timeout: Int = 30) {
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        var interval = timeval(tv_sec: timeout, tv_usec: 0)
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            setsockopt(descriptor, SOL_SOCKET, option, &interval, socklen_t(MemoryLayout.size(ofValue: interval)))
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }

    static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw systemError("Cannot write Awayke command") }
                offset += count
            }
        }
    }

    static func readLine(from descriptor: Int32) throws -> Data {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < 8192 {
            let count = Darwin.read(descriptor, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw failure("Awayke closed the connection or did not reply before the timeout. Check status before retrying a change.")
            }
            if byte == 10 { return data }
            data.append(byte)
        }
        throw failure("The Awayke control message is too large.")
    }

    static func request(_ command: ControlCommand, path: String = path) throws -> ControlReply {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw systemError("Cannot create Awayke connection") }
        defer { close(descriptor) }
        configure(descriptor)
        var address = try address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw failure("Cannot connect to Awayke. Start the installed app with `open -a Awayke`, then retry.")
        }
        try write(Data("\(command.rawValue)\n".utf8), to: descriptor)
        return try JSONDecoder().decode(ControlReply.self, from: readLine(from: descriptor))
    }
}

/// The private directory and peer UID keep control within the current login.
/// A lifetime lock prevents a second app instance from replacing the socket.
nonisolated final class CommandServer {
    typealias Handler = @MainActor (ControlCommand, @escaping (ControlReply) -> Void) -> Void
    private let source: DispatchSourceRead
    private let path: String
    private let lock: Int32

    init(path: String = ControlSocket.path, handler: @escaping Handler) throws {
        self.path = path
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        lock = Darwin.open(path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw ControlSocket.systemError("Cannot open Awayke control lock") }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            throw ControlSocket.failure("Another Awayke instance already owns the control socket.")
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            close(lock)
            throw ControlSocket.systemError("Cannot create Awayke control socket")
        }
        do {
            var address = try ControlSocket.address(path)
            unlink(path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0, chmod(path, 0o600) == 0, listen(descriptor, 8) == 0,
                  fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
                throw ControlSocket.systemError("Cannot listen for Awayke commands")
            }
        } catch {
            close(descriptor)
            close(lock)
            unlink(path)
            throw error
        }
        ControlSocket.configure(descriptor)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                ControlSocket.configure(client, timeout: 5)
                var uid: uid_t = 0
                var gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else {
                    close(client)
                    continue
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    func reply(_ response: ControlReply) {
                        defer { close(client) }
                        if var data = try? JSONEncoder().encode(response) {
                            data.append(10)
                            try? ControlSocket.write(data, to: client)
                        }
                    }
                    do {
                        let data = try ControlSocket.readLine(from: client)
                        guard let text = String(data: data, encoding: .utf8),
                              let command = ControlCommand(rawValue: text) else {
                            reply(ControlReply(ok: false, error: "Expected on, off, or status."))
                            return
                        }
                        DispatchQueue.main.async { handler(command, reply) }
                    } catch {
                        reply(ControlReply(ok: false, error: error.localizedDescription))
                    }
                }
            }
        }
        let lock = lock
        source.setCancelHandler {
            close(descriptor)
            unlink(path)
            close(lock)
        }
        source.resume()
    }

    deinit { source.cancel() }
}

nonisolated enum ControlCLI {
    static func run(arguments: [String]) -> Int32 {
        if arguments == ["--help"] || arguments == ["-h"] {
            print("Usage: awayke on|off|status\nCommands control the running Awayke app and return JSON.")
            return 0
        }
        guard arguments.count == 1, let command = ControlCommand(rawValue: arguments[0]) else {
            FileHandle.standardError.write(Data("Usage: awayke on|off|status\n".utf8))
            return 2
        }
        do {
            let reply = try ControlSocket.request(command)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(reply)
            data.append(10)
            (reply.ok ? FileHandle.standardOutput : FileHandle.standardError).write(data)
            return reply.ok ? 0 : 1
        } catch {
            FileHandle.standardError.write(Data("awayke: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
