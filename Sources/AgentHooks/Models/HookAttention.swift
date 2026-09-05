//
//  HookAttention.swift
//  AgentHooks
//
//  The agent's idle/attention signal (from a `Stop` or `Notification` event).
//
//  Created by David Sherlock on 9/5/26.
//

import Foundation

/// The agent's idle/attention signal (from a `Stop` or `Notification` event).
public struct HookAttention: Equatable, Sendable {
    /// Claude Code session id, if present.
    public let sessionID: String?
    /// The session's working directory when the event fired (`cwd`), if present.
    ///
    /// The strongest attribution signal the payload carries: a consumer can compare
    /// it to a terminal's directory as a plain path. The session-id route (via the
    /// transcript's encoded directory name under `~/.claude/projects`) is lossy —
    /// the encoding folds `/`, ` `, `.` and `_` all onto `-` — so it should only
    /// ever be a fallback for payloads that omit this field.
    public let cwd: String?
    /// The prompt text for a `Notification` event (permission/attention), or the
    /// last assistant message for a `Stop` event; nil when absent.
    public let message: String?
    /// True for a `Notification` event (needs attention), false for `Stop`
    /// (turn finished) — lets a consumer treat "waiting on you" differently
    /// from "done".
    public let isNotification: Bool

    public init(sessionID: String?, cwd: String?, message: String?, isNotification: Bool) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.message = message
        self.isNotification = isNotification
    }
}
