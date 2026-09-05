//
//  HookListener.swift
//  AgentHooks
//
//  The server half of the hook socket, living inside the running app.
//
//  Created by David Sherlock on 9/5/26.
//

import Foundation
import Darwin

/// The server half of the hook socket, living inside the running app. Owns the local listening
/// socket, accepts the forwarder's connections on a background queue, parses each payload and
/// hands the events to `onEvents` on that queue. It never touches UI: the app hops to main.
///
/// Two-instance handling ("probe then claim"): if a live listener already answers the socket
/// (another running instance) this one defers to it and does not listen — the forwarder will
/// reach that instance. A socket file nothing answers (a crashed instance) is stale: unlinked
/// and reclaimed. The first running instance owns the socket and never wedges on a leftover.
///
/// `@unchecked Sendable`: `listenFD` and `started` are written by `start()`/`stop()`; the accept
/// loop owns everything else on its own queue.
public final class HookListener: @unchecked Sendable {

    /// Answers a parked permission request: the bytes to write back as the hook's stdout, or
    /// nil to close the connection empty. Called exactly once per parked request.
    public typealias Reply = @Sendable (Data?) -> Void

    /// Offered every decidable permission request. Return true to take the connection — the
    /// `Reply` must then be called eventually — or false to have it closed empty at once.
    public typealias PermissionHandler = @Sendable (HookPermissionRequest, @escaping Reply) -> Bool

    public let socketURL: URL
    private let onEvents: @Sendable ([HookEvent]) -> Void
    private let onPermissionRequest: PermissionHandler?

    nonisolated(unsafe) private var listenFD: Int32 = -1
    nonisolated(unsafe) private var started = false

    /// True once this instance owns the socket; false before `start()`, when another instance
    /// already owns it, or when the claim failed.
    public var isListening: Bool { listenFD >= 0 }

    public init(socketURL: URL,
                onEvents: @escaping @Sendable ([HookEvent]) -> Void,
                onPermissionRequest: PermissionHandler? = nil) {
        self.socketURL = socketURL
        self.onEvents = onEvents
        self.onPermissionRequest = onPermissionRequest
    }

    /// Claims the socket and starts accepting. Idempotent: a second call is a no-op.
    public func start() {
        guard !started else { return }
        started = true
        try? FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard var addr = SocketIO.address(for: socketURL) else { return }
        if isSocketLive(addr) { return }                    // another instance owns it
        _ = unlink(socketURL.path)                          // drop any stale socket file

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else { close(fd); return }
        guard listen(fd, 16) == 0 else { close(fd); _ = unlink(socketURL.path); return }
        _ = chmod(socketURL.path, 0o600)                    // owner-only: reinforce local-only
        listenFD = fd
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.acceptLoop(fd: fd) }
    }

    /// Releases the socket and removes its file; the accept loop ends. For tests and teardown —
    /// an app leaves its listener to the process's lifetime.
    public func stop() {
        guard listenFD >= 0 else { return }
        _ = shutdown(listenFD, SHUT_RDWR)                   // wakes the blocked accept
        close(listenFD)
        listenFD = -1
        _ = unlink(socketURL.path)
    }

    // MARK: - Accepting

    /// Blocking accept loop (background queue). Exits when the listen socket is closed.
    private func acceptLoop(fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                switch errno {
                case EINTR, ECONNABORTED:
                    continue                                // transient: a signal, or the peer gave up
                case EMFILE, ENFILE:
                    // Out of file descriptors: back off instead of hot-spinning, and keep the
                    // listener alive — exiting here would kill hook delivery for the session
                    // over a temporary fd squeeze elsewhere in the process.
                    usleep(100_000)
                    continue
                default:
                    return                                  // listen socket closed, or genuinely fatal
                }
            }
            handle(client: client)
        }
    }

    /// One connection: read it to EOF, parse, park it for a decision or close it, then deliver
    /// every event in the payload (a Codex patch touching three files is three edits).
    private func handle(client: Int32) {
        // Bound the read so a client that connects but never sends cannot wedge the loop (the
        // forwarder always writes then half-closes; this guards a rogue connector).
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let events = HookEvent.parseAll(SocketIO.readToEnd(client))
        let parked = decidableRequest(in: events).map { park(client, for: $0) } ?? false
        if !parked { close(client) }
        onEvents(events)
    }

    private func decidableRequest(in events: [HookEvent]) -> HookPermissionRequest? {
        for case .permissionRequested(let request) in events where request.isDecidable { return request }
        return nil
    }

    /// Offers the connection to the permission handler; true when it took it. The hook process
    /// is waiting on this connection for its stdout: the handler's reply writes the decision
    /// (or nothing) and closes it.
    private func park(_ client: Int32, for request: HookPermissionRequest) -> Bool {
        guard let onPermissionRequest else { return false }
        return onPermissionRequest(request) { bytes in
            if let bytes { SocketIO.writeAllBlocking(bytes, to: client) }
            close(client)
        }
    }

    /// Whether a live listener already answers the socket: a successful connect.
    private func isSocketLive(_ address: sockaddr_un) -> Bool {
        guard let fd = SocketIO.open(address, timeoutMS: 250) else { return false }
        close(fd)
        return true
    }
}
