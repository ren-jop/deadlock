import Foundation
import Darwin

public enum SocketError: Error, CustomStringConvertible {
    case system(String)
    case protocolError(String)

    public var description: String {
        switch self {
        case .system(let s), .protocolError(let s): return s
        }
    }
}

private func makeAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let maxLen = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < maxLen else { throw SocketError.protocolError("Socket path is too long") }
    path.withCString { src in
        withUnsafeMutablePointer(to: &address.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                _ = strlcpy(dst, src, maxLen)
            }
        }
    }
    return address
}

private func socketLength(_ address: sockaddr_un) -> socklen_t {
    return socklen_t(MemoryLayout<sockaddr_un>.size)
}

private func readExactly(_ fd: Int32, count: Int) throws -> Data {
    var data = Data(count: count)
    var done = 0
    try data.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return }
        while done < count {
            let n = Darwin.read(fd, base.advanced(by: done), count - done)
            if n == 0 { throw SocketError.protocolError("Unexpected EOF") }
            if n < 0 {
                if errno == EINTR { continue }
                throw SocketError.system(String(cString: strerror(errno)))
            }
            done += n
        }
    }
    return data
}

private func writeExactly(_ fd: Int32, data: Data) throws {
    var done = 0
    try data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        while done < data.count {
            let n = Darwin.write(fd, base.advanced(by: done), data.count - done)
            if n < 0 {
                if errno == EINTR { continue }
                throw SocketError.system(String(cString: strerror(errno)))
            }
            done += n
        }
    }
}

public enum FramedJSON {
    public static func send<T: Encodable>(_ value: T, to fd: Int32) throws {
        let payload = try JSONEncoder().encode(value)
        guard payload.count <= 1_048_576 else { throw SocketError.protocolError("Message too large") }
        var length = UInt32(payload.count).bigEndian
        let header = Data(bytes: &length, count: 4)
        try writeExactly(fd, data: header)
        try writeExactly(fd, data: payload)
    }

    public static func receive<T: Decodable>(_ type: T.Type, from fd: Int32) throws -> T {
        let header = try readExactly(fd, count: 4)
        let length = header.withUnsafeBytes { raw -> UInt32 in
            raw.load(as: UInt32.self).bigEndian
        }
        guard length <= 1_048_576 else { throw SocketError.protocolError("Message too large") }
        let payload = try readExactly(fd, count: Int(length))
        return try JSONDecoder().decode(type, from: payload)
    }
}

public enum UnixSocketClient {
    public static func request(_ request: IPCRequest, path: String = DeadlockPaths.socket) throws -> IPCResponse {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system(String(cString: strerror(errno))) }
        defer { Darwin.close(fd) }
        var address = try makeAddress(path)
        let addressLength = socketLength(address)
        let rc = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, addressLength)
            }
        }
        guard rc == 0 else { throw SocketError.system(String(cString: strerror(errno))) }
        try FramedJSON.send(request, to: fd)
        return try FramedJSON.receive(IPCResponse.self, from: fd)
    }
}

public final class UnixSocketServer: @unchecked Sendable {
    public let fd: Int32
    public let path: String

    public init(path: String = DeadlockPaths.socket) throws {
        self.path = path
        _ = unlink(path)
        let s = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw SocketError.system(String(cString: strerror(errno))) }
        var address = try makeAddress(path)
        let addressLength = socketLength(address)
        let rc = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(s, $0, addressLength)
            }
        }
        guard rc == 0 else {
            Darwin.close(s)
            throw SocketError.system(String(cString: strerror(errno)))
        }
        _ = chmod(path, 0o666)
        guard Darwin.listen(s, 16) == 0 else {
            Darwin.close(s)
            throw SocketError.system(String(cString: strerror(errno)))
        }
        self.fd = s
    }

    deinit {
        Darwin.close(fd)
        _ = unlink(path)
    }

    public func acceptClient() throws -> Int32 {
        while true {
            let c = Darwin.accept(fd, nil, nil)
            if c >= 0 { return c }
            if errno == EINTR { continue }
            throw SocketError.system(String(cString: strerror(errno)))
        }
    }

    public static func peerUID(_ fd: Int32) -> uid_t? {
        var euid: uid_t = 0
        var egid: gid_t = 0
        return getpeereid(fd, &euid, &egid) == 0 ? euid : nil
    }
}
