//
//  SocketIO.swift
//  AgentHooks
//
//  POSIX plumbing shared by `HookForwarder` and `HookListener`.
//
//  Created by David Sherlock on 9/5/26.
//

import Foundation
import Darwin

/// POSIX plumbing shared by `HookForwarder` and `HookListener`. Every wait is bounded, so a
/// dead peer costs milliseconds, never a hang — a hook that stalls degrades the agent session.
enum SocketIO {

    /// The `sockaddr_un` for `url`, or nil when the path exceeds the fixed `sun_path` capacity
    /// (104 bytes on Darwin): an over-long home path disables the socket rather than
    /// corrupting memory.
    static func address(for url: URL) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return nil }   // room for the NUL
        withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
            tuple.withMemoryRebound(to: UInt8.self, capacity: capacity) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = b }
                dst[bytes.count] = 0
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    /// A non-blocking connect to `address` within `timeoutMS`: the connected fd, or nil. A
    /// missing socket file (ENOENT) or a stale one nobody answers (ECONNREFUSED) fails at once.
    static func open(_ address: sockaddr_un, timeoutMS: Int32) -> Int32? {
        var addr = address
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setNonBlocking(fd)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        if rc != 0 {
            guard errno == EINPROGRESS, waitWritable(fd, timeoutMS: timeoutMS) else { close(fd); return nil }
            var soError: Int32 = 0
            var soLen = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soLen) == 0, soError == 0 else { close(fd); return nil }
        }
        return fd
    }

    /// Marks `fd` non-blocking so `connect`/`write` never park the caller.
    static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// Waits up to `timeoutMS` for `fd` to become writable; false on timeout or error.
    static func waitWritable(_ fd: Int32, timeoutMS: Int32) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let r = poll(&pfd, 1, timeoutMS)
        return r > 0 && (pfd.revents & Int16(POLLOUT)) != 0
    }

    /// Waits up to `timeoutMS` for `fd` to become readable (or hung up); false on timeout or error.
    static func waitReadable(_ fd: Int32, timeoutMS: Int32) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let r = poll(&pfd, 1, timeoutMS)
        return r > 0 && (pfd.revents & Int16(POLLIN | POLLHUP)) != 0
    }

    /// Writes all of `data` to a non-blocking `fd` before `deadline`, waiting up to 100 ms per
    /// chunk. False on a partial write — silently abandoned by the callers.
    static func writeAll(_ data: Data, to fd: Int32, deadline: Date) -> Bool {
        var offset = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            while offset < data.count, Date() < deadline {
                guard waitWritable(fd, timeoutMS: 100) else { break }
                let n = Darwin.write(fd, base + offset, data.count - offset)
                if n > 0 { offset += n }
                else if n < 0, errno == EAGAIN || errno == EINTR { continue }
                else { break }
            }
        }
        return offset == data.count
    }

    /// Writes all of `data` to a blocking `fd` (the listener's reply path); a broken pipe ends it.
    static func writeAllBlocking(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(fd, base + offset, data.count - offset)
                if n > 0 { offset += n } else if n < 0, errno == EINTR { continue } else { break }
            }
        }
    }

    /// Reads a blocking `fd` to EOF (payloads are tiny). Bounded by the `SO_RCVTIMEO` set on it:
    /// a timed-out read returns an error and ends here.
    static func readToEnd(_ fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n > 0 { data.append(buffer, count: n) }
            else if n == 0 { break }                        // EOF
            else if errno == EINTR { continue }
            else { break }                                  // error or RCVTIMEO
        }
        return data
    }

    /// Reads a non-blocking `fd` until the peer closes or `deadline` passes, polling 250 ms at a time.
    static func drain(_ fd: Int32, until deadline: Date) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            guard waitReadable(fd, timeoutMS: 250) else { continue }
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n > 0 { data.append(buffer, count: n) }
            else if n == 0 { break }                        // the peer closed: done
            else if errno == EAGAIN || errno == EINTR { continue }
            else { break }
        }
        return data
    }
}
