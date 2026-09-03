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

/// A decoded Claude Code hook event. Parsing is deliberately lenient
/// (`JSONSerialization`, tolerant of unknown/missing fields): a malformed or
/// unrecognized event yields nil and is silently dropped, never crashes.
///
/// Field names follow the Claude Code hooks contract — which Codex and Gemini share in
/// outline: `hook_event_name`,
/// `session_id`, `tool_name`, `tool_input.file_path`. This is a pure value —
/// how a host reacts (post a notification, open a file) is the host's concern.
public enum HookEvent: Equatable {
    case fileEdited(HookFileEdit)
    case agentStopped(HookAttention)

    /// Parses one event JSON blob (the bytes an agent writes to a hook's stdin) into
    /// the first event worth acting on — kept for callers that expect one; a Codex
    /// patch touching several files yields several, see ``parseAll(_:)``.
    public static func parse(_ data: Data) -> HookEvent? { parseAll(data).first }

    /// Every event worth acting on in one payload. Three agents speak here, and the
    /// payloads were read from their sources (3 Sep 2026), not their docs:
    /// - Claude Code: `PostToolUse` with `tool_input.file_path` / `notebook_path`,
    ///   `Stop` (turn finished), `Notification` (needs you).
    /// - Codex CLI: `PostToolUse` whose `tool_name` is `apply_patch` with the raw patch
    ///   in `tool_input.command` — one edit per Update/Add header, relative paths
    ///   joined to `cwd`; `PermissionRequest` (needs you, names the tool); `Stop`.
    /// - Gemini CLI: `AfterTool` with `tool_input.file_path` (write_file / replace),
    ///   `Notification` (ToolPermission → needs you), `AfterAgent` (turn finished).
    /// Session and working directory are the common `session_id` / `cwd`.
    public static func parseAll(_ data: Data) -> [HookEvent] {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return [] }

        let session = dict["session_id"] as? String
        let cwd = dict["cwd"] as? String
        let tool = dict["tool_name"] as? String ?? ""
        func edit(_ path: String) -> HookEvent? {
            guard let url = resolve(path, cwd: cwd) else { return nil }
            return .fileEdited(HookFileEdit(fileURL: url, sessionID: session, tool: tool))
        }
        func edits(fromToolInput input: Any?) -> [HookEvent] {
            if tool == "apply_patch", let dict = input as? [String: Any],
               let patch = dict["command"] as? String {
                return ApplyPatch.touchedFiles(in: patch).filter { $0.kind != .delete }.compactMap { edit($0.path) }
            }
            guard let path = filePath(fromToolInput: input), let e = edit(path) else { return [] }
            return [e]
        }
        switch dict["hook_event_name"] as? String {
        case "PostToolUse", "AfterTool":
            return edits(fromToolInput: dict["tool_input"])
        case "Stop":
            return [.agentStopped(HookAttention(
                sessionID: session, cwd: cwd, message: dict["last_assistant_message"] as? String,
                isNotification: false))]
        case "AfterAgent":
            return [.agentStopped(HookAttention(
                sessionID: session, cwd: cwd, message: dict["prompt_response"] as? String,
                isNotification: false))]
        case "Notification":
            return [.agentStopped(HookAttention(
                sessionID: session, cwd: cwd, message: dict["message"] as? String,
                isNotification: true))]
        case "PermissionRequest":
            return [.agentStopped(HookAttention(
                sessionID: session, cwd: cwd,
                message: tool.isEmpty ? "Approval needed" : "Approval needed: \(tool)",
                isNotification: true))]
        default:
            // Unknown event name but it carries a file-editing tool_input → still
            // surface the edit; otherwise ignore. Keeps us forward-compatible if an
            // agent renames events.
            return edits(fromToolInput: dict["tool_input"])
        }
    }

    /// Absolute for an absolute path; joined to `cwd` for a relative one (Codex patch
    /// headers, and any agent that sends project-relative paths); nil without either.
    private static func resolve(_ path: String, cwd: String?) -> URL? {
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        guard let cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).appendingPathComponent(path).standardizedFileURL
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
