// A plain TCP connection to the fake Gmail server, standing in for the app's TLS one.
import Foundation
#if canImport(Glibc)
import Glibc
private let streamType = Int32(SOCK_STREAM.rawValue)
#else
import Darwin
private let streamType = SOCK_STREAM
#endif

/// A plain TCP connection with a receive timeout.
final class SocketTransport: IMAPTransport {
    private let fd: Int32
    init(port: UInt16, timeout: Int = 3) throws {
        fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else { throw IMAPError.offline }
        var limit = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { close(); throw IMAPError.offline }
    }
    func send(_ bytes: [UInt8]) throws {
        let sent = bytes.withUnsafeBytes { Glue.send(fd, $0.baseAddress, bytes.count) }
        guard sent == bytes.count else { throw IMAPError.offline }
    }
    func receive() throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, 4096, 0) }
        if count < 0 { throw IMAPError.offline }             // timed out
        return Array(buffer.prefix(count))
    }
    func close() { _ = Glue.close(fd) }
}
enum Glue {
    static func send(_ fd: Int32, _ pointer: UnsafeRawPointer?, _ count: Int) -> Int {
        #if canImport(Glibc)
        return Glibc.send(fd, pointer, count, Int32(MSG_NOSIGNAL))
        #else
        return Darwin.send(fd, pointer, count, 0)
        #endif
    }
    static func close(_ fd: Int32) -> Int32 {
        #if canImport(Glibc)
        return Glibc.close(fd)
        #else
        return Darwin.close(fd)
        #endif
    }
}
