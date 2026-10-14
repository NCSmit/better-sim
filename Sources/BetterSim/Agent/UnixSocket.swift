import Foundation

/// Listens on a Unix domain socket and answers one request per connection: the client writes its request and closes
/// its side, then the server writes one reply and closes the connection.
final class UnixSocketServer: @unchecked Sendable {
    typealias Handler = @Sendable (Data) async -> Data

    static let requestLimit = 1 << 20

    let path: String
    private let descriptor: Int32
    private let inode: ino_t
    private let source: DispatchSourceRead
    private let handler: Handler

    init(path: String, handler: @escaping Handler) throws {
        var address = try UnixSocket.address(path)
        try UnixSocket.removeStaleSocket(at: path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw UnixSocket.failure("BetterSim couldn't create its agent socket") }
        // Connections inherit this. Setting it once accepted is too late when the client has already hung up: macOS
        // then refuses the option, and the reply would raise SIGPIPE and end the app.
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 16) == 0 else {
            let failure = UnixSocket.failure("BetterSim couldn't listen at \(path)")
            close(descriptor)
            throw failure
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var info = stat()
        lstat(path, &info)
        self.path = path
        self.descriptor = descriptor
        self.inode = info.st_ino
        self.handler = handler
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "local.bettersim.agent-socket"))
        source.setEventHandler { [weak self] in self?.acceptWaitingClients() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    /// Stops listening, and removes the socket file unless another server has replaced it since.
    func stop() {
        source.cancel()
        var info = stat()
        if lstat(path, &info) == 0, info.st_ino == inode { unlink(path) }
    }

    private func acceptWaitingClients() {
        while true {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            guard UnixSocket.peerIsCurrentUser(client) else {
                close(client)
                continue
            }
            UnixSocket.prepare(client, timeout: 10)
            let handler = handler
            DispatchQueue.global(qos: .userInitiated).async {
                guard let request = try? UnixSocket.readAll(client, limit: Self.requestLimit) else {
                    close(client)
                    return
                }
                Task {
                    let reply = await handler(request)
                    DispatchQueue.global(qos: .userInitiated).async {
                        try? UnixSocket.writeAll(reply, to: client)
                        close(client)
                    }
                }
            }
        }
    }
}

enum UnixSocket {
    static let replyLimit = 64 << 20

    /// Sends one request and waits up to `timeout` seconds for the reply.
    static func exchange(_ request: Data, path: String, timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    let descriptor = try connect(to: path, timeout: timeout)
                    defer { close(descriptor) }
                    try writeAll(request, to: descriptor)
                    shutdown(descriptor, SHUT_WR)
                    return try readAll(descriptor, limit: replyLimit)
                })
            }
        }
    }

    static func connect(to path: String, timeout: TimeInterval) throws -> Int32 {
        var address = try address(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw failure("Couldn't create a socket") }
        prepare(descriptor, timeout: timeout)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let code = errno
            close(descriptor)
            if code == ENOENT || code == ECONNREFUSED { throw AgentFailure.appNotRunning }
            throw failure("Couldn't reach BetterSim at \(path)", code: code)
        }
        return descriptor
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw AgentFailure(.failed, "The socket path \(path) is too long. Unix sockets allow \(MemoryLayout.size(ofValue: address.sun_path) - 1) bytes.")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    /// Clears a socket file left behind by a server that has quit, but never one that still answers or isn't a socket.
    static func removeStaleSocket(at path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFSOCK else {
            throw AgentFailure(.failed, "Something that isn't a socket is in the way at \(path).")
        }
        if let descriptor = try? connect(to: path, timeout: 1) {
            close(descriptor)
            throw AgentFailure(.failed, "Another BetterSim is already listening at \(path).")
        }
        unlink(path)
    }

    static func prepare(_ descriptor: Int32, timeout: TimeInterval) {
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) & ~O_NONBLOCK)
    }

    static func peerIsCurrentUser(_ descriptor: Int32) -> Bool {
        var user = uid_t()
        var group = gid_t()
        return getpeereid(descriptor, &user, &group) == 0 && user == geteuid()
    }

    static func readAll(_ descriptor: Int32, limit: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw AgentFailure(.timeout, "BetterSim didn't answer in time.")
                }
                throw failure("Couldn't read from the agent socket")
            }
            data.append(contentsOf: buffer[0..<count])
            guard data.count <= limit else { throw AgentFailure(.failed, "The message on the agent socket was too large.") }
        }
    }

    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, base + offset, bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw failure("Couldn't write to the agent socket")
                }
                offset += written
            }
        }
    }

    static func failure(_ text: String, code: Int32 = errno) -> AgentFailure {
        AgentFailure(.failed, "\(text): \(String(cString: strerror(code))).")
    }
}
