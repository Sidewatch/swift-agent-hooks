//
//  HookForwarder.swift
//  AgentHooks
//
//  The client half of the hook socket, run by the app's `--hook` process — a throwaway spawned
//  by the agent for every event.
//
//  Created by David Sherlock on 9/5/26.
//

import Foundation
import Darwin

/// The client half of the hook socket, run by the app's `--hook` process — a throwaway spawned
/// by the agent for every event. It reads the event JSON from stdin, connects to the running
/// app's local socket within a hard ~250 ms budget, writes the bytes, and returns.
///
/// CONTRACT (a misbehaving hook degrades the user's agent session, so this is absolute): never
/// blocks, never hangs, never throws, never writes stderr. The caller always exits 0 regardless
/// of what happens here.
public struct HookForwarder: Sendable {

    /// The local listener socket. Local only — never a network endpoint.
    public let socketURL: URL

    public init(socketURL: URL) { self.socketURL = socketURL }

    /// Reads stdin and fire-and-forgets it to the app. A decidable permission request instead
    /// keeps the connection open for up to `replyTimeout` seconds and prints whatever the app
    /// answers as the hook's stdout; the app closes it empty at once when it will not decide,
    /// so the fast path stays fast. Silent on every failure (app not running, socket absent,
    /// malformed JSON, timeout).
    public func forwardStandardInput(replyTimeout: TimeInterval) {
        // The agent writes the JSON then closes the pipe, so this returns promptly.
        let data = (try? FileHandle.standardInput.readToEnd()) ?? Data()
        guard !data.isEmpty else { return }
        if Self.isDecidablePermissionRequest(data) {
            if let reply = sendAndAwaitReply(data, timeout: replyTimeout), !reply.isEmpty {
                FileHandle.standardOutput.write(reply)
            }
            return
        }
        send(data)
    }

    /// Claude Code's PermissionRequest payload, which the app may answer. Codex's shares the
    /// event name but has no `tool_use_id` / `prompt_id`, and its answer protocol is not this one.
    public static func isDecidablePermissionRequest(_ data: Data) -> Bool {
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              dict["hook_event_name"] as? String == "PermissionRequest" else { return false }
        return dict["tool_use_id"] != nil || dict["prompt_id"] != nil
    }

    /// Sends `data`, half-closes, then reads the app's reply until it closes — at most `timeout`
    /// seconds. Nil when the app is absent, the connect or write fails, or the reply is empty.
    public func sendAndAwaitReply(_ data: Data, timeout: TimeInterval) -> Data? {
        guard let fd = connect(sending: data) else { return nil }
        defer { close(fd) }
        guard SocketIO.writeAll(data, to: fd, deadline: Date().addingTimeInterval(0.5)) else { return nil }
        _ = shutdown(fd, SHUT_WR)   // EOF for the app's reader; our read side stays open
        let reply = SocketIO.drain(fd, until: Date().addingTimeInterval(timeout))
        return reply.isEmpty ? nil : reply
    }

    /// Fire-and-forgets `data` within the hard ~250 ms budget. A partial or failed write is
    /// silently abandoned: better a missed event than a stalled agent.
    public func send(_ data: Data) {
        guard let fd = connect(sending: data) else { return }
        defer { close(fd) }
        _ = SocketIO.writeAll(data, to: fd, deadline: Date().addingTimeInterval(0.25))
    }

    /// The connected fd for a non-empty payload, or nil when there is nothing to send, the
    /// socket path is unusable, or no app answers within 250 ms.
    private func connect(sending data: Data) -> Int32? {
        guard !data.isEmpty, let address = SocketIO.address(for: socketURL) else { return nil }
        return SocketIO.open(address, timeoutMS: 250)
    }
}
