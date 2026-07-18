import Foundation

/// A file the agent just touched (from a `PostToolUse` edit event).
public struct HookFileEdit: Equatable {
    /// Absolute URL of the edited/written file (from `tool_input.file_path`).
    public let fileURL: URL
    /// Claude Code session id, if the event carried one (`session_id`).
    public let sessionID: String?
    /// The tool that produced the edit ("Edit" / "Write" / "MultiEdit" / "NotebookEdit").
    public let tool: String

    public init(fileURL: URL, sessionID: String?, tool: String) {
        self.fileURL = fileURL
        self.sessionID = sessionID
        self.tool = tool
    }
}

/// The agent's idle/attention signal (from a `Stop` or `Notification` event).
public struct HookAttention: Equatable {
    /// Claude Code session id, if present.
    public let sessionID: String?
    /// The prompt text for a `Notification` event (permission/attention), or the
    /// last assistant message for a `Stop` event; nil when absent.
    public let message: String?
    /// True for a `Notification` event (needs attention), false for `Stop`
    /// (turn finished) — lets a consumer treat "waiting on you" differently
    /// from "done".
    public let isNotification: Bool

    public init(sessionID: String?, message: String?, isNotification: Bool) {
        self.sessionID = sessionID
        self.message = message
        self.isNotification = isNotification
    }
}

/// A decoded Claude Code hook event. Parsing is deliberately lenient
/// (`JSONSerialization`, tolerant of unknown/missing fields): a malformed or
/// unrecognized event yields nil and is silently dropped, never crashes.
///
/// Field names follow the Claude Code hooks contract: `hook_event_name`,
/// `session_id`, `tool_name`, `tool_input.file_path`. This is a pure value —
/// how a host reacts (post a notification, open a file) is the host's concern.
public enum HookEvent: Equatable {
    case fileEdited(HookFileEdit)
    case agentStopped(HookAttention)

    /// Parses one event JSON blob (the bytes Claude Code writes to a hook's stdin).
    /// Returns nil for anything not worth acting on.
    public static func parse(_ data: Data) -> HookEvent? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return nil }

        let session = dict["session_id"] as? String
        switch dict["hook_event_name"] as? String {
        case "PostToolUse":
            guard let path = filePath(fromToolInput: dict["tool_input"]) else { return nil }
            let tool = dict["tool_name"] as? String ?? ""
            return .fileEdited(HookFileEdit(
                fileURL: URL(fileURLWithPath: path), sessionID: session, tool: tool))
        case "Stop":
            return .agentStopped(HookAttention(
                sessionID: session, message: dict["last_assistant_message"] as? String,
                isNotification: false))
        case "Notification":
            return .agentStopped(HookAttention(
                sessionID: session, message: dict["message"] as? String,
                isNotification: true))
        default:
            // Unknown event name but it carries a file-editing tool_input → still
            // surface the edit; otherwise ignore. Keeps us forward-compatible if
            // Claude Code renames events.
            guard let path = filePath(fromToolInput: dict["tool_input"]) else { return nil }
            let tool = dict["tool_name"] as? String ?? ""
            return .fileEdited(HookFileEdit(
                fileURL: URL(fileURLWithPath: path), sessionID: session, tool: tool))
        }
    }

    /// Extracts the edited file's absolute path from a `tool_input` object across
    /// the edit tools: `file_path` (Edit/Write/MultiEdit), `notebook_path`
    /// (NotebookEdit), and — defensively — a first `edits[].file_path` in case a
    /// variant nests it there.
    private static func filePath(fromToolInput input: Any?) -> String? {
        guard let dict = input as? [String: Any] else { return nil }
        if let p = dict["file_path"] as? String, !p.isEmpty { return p }
        if let p = dict["notebook_path"] as? String, !p.isEmpty { return p }
        if let edits = dict["edits"] as? [[String: Any]] {
            for e in edits where (e["file_path"] as? String)?.isEmpty == false {
                return e["file_path"] as? String
            }
        }
        return nil
    }
}
