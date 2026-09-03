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
    /// A tool is starting (`PreToolUse` / `BeforeTool`) or has finished (`PostToolUse` /
    /// `AfterTool`) — what the agent is doing right now, for a status row.
    case toolUsed(HookToolUse)
    /// The user submitted a prompt (`UserPromptSubmit` / `BeforeAgent`): a turn began.
    case turnStarted(HookTurnStart)
    /// Claude Code `SubagentStart` / `SubagentStop`.
    case subagentStarted(HookSubagent)
    case subagentStopped(HookSubagent)
    /// A `PermissionRequest`: the agent is asking to run a tool. Emitted ALONGSIDE the
    /// `.agentStopped(waiting)` attention so a host can both flag the terminal and, when it
    /// has the payload's decision protocol (Claude Code), answer from its own UI.
    case permissionRequested(HookPermissionRequest)

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
        let toolUse: (Bool) -> HookEvent = { finished in
            .toolUsed(HookToolUse(sessionID: session, cwd: cwd, tool: tool,
                                  summary: HookToolUse.summary(tool: tool, input: dict["tool_input"], cwd: cwd),
                                  isFinished: finished))
        }
        switch dict["hook_event_name"] as? String {
        case "PreToolUse", "BeforeTool":
            guard !tool.isEmpty else { return [] }
            return [toolUse(false)]
        case "PostToolUse", "AfterTool":
            return edits(fromToolInput: dict["tool_input"]) + (tool.isEmpty ? [] : [toolUse(true)])
        case "UserPromptSubmit", "BeforeAgent":
            return [.turnStarted(HookTurnStart(sessionID: session, cwd: cwd, prompt: dict["prompt"] as? String))]
        case "SubagentStart", "SubagentStop":
            let sub = HookSubagent(sessionID: session, cwd: cwd,
                                   agentID: (dict["agent_id"] as? String) ?? (dict["agent_transcript_path"] as? String) ?? "",
                                   agentType: dict["agent_type"] as? String)
            return [dict["hook_event_name"] as? String == "SubagentStart" ? .subagentStarted(sub) : .subagentStopped(sub)]
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
            let suggestions = dict["permission_suggestions"] as? [String: Any]
            let request = HookPermissionRequest(
                sessionID: session, cwd: cwd, tool: tool,
                summary: HookToolUse.summary(tool: tool, input: dict["tool_input"], cwd: cwd),
                toolUseID: dict["tool_use_id"] as? String,
                promptID: dict["prompt_id"] as? String,
                // Claude Code's payload carries tool_use_id / prompt_id; Codex's does not, and
                // Codex's answer protocol is not this one — so only Claude's are decidable.
                isDecidable: dict["tool_use_id"] != nil || dict["prompt_id"] != nil,
                canAlwaysAllow: (suggestions?["always_allow"] as? Bool) ?? false)
            return [.agentStopped(HookAttention(
                        sessionID: session, cwd: cwd,
                        message: tool.isEmpty ? "Approval needed" : "Approval needed: \(tool)",
                        isNotification: true)),
                    .permissionRequested(request)]
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


/// What a tool call is, in one short line: the file for an edit, the command for a shell
/// call, the pattern for a search. A status row shows "claude · Edit main.swift" from it.
public struct HookToolUse: Equatable {
    public let sessionID: String?
    public let cwd: String?
    /// The agent's own tool name (`Edit`, `Bash`, `apply_patch`, `write_file`…).
    public let tool: String
    /// The argument worth showing — empty when the tool takes nothing showable.
    public let summary: String
    /// False for `PreToolUse`/`BeforeTool` (running now), true for `PostToolUse`/`AfterTool`.
    public let isFinished: Bool

    public init(sessionID: String?, cwd: String?, tool: String, summary: String, isFinished: Bool) {
        self.sessionID = sessionID; self.cwd = cwd; self.tool = tool; self.summary = summary; self.isFinished = isFinished
    }

    /// The showable argument of a tool call, from its `tool_input`, across the three agents'
    /// tool vocabularies. Paths are shown relative to `cwd` when they live under it; commands
    /// are their first line, cut at 80 characters. Unknown tools yield "".
    public static func summary(tool: String, input: Any?, cwd: String?) -> String {
        let dict = input as? [String: Any] ?? [:]
        func str(_ keys: String...) -> String? {
            for k in keys { if let v = dict[k] as? String, !v.isEmpty { return v } }
            return nil
        }
        func short(_ path: String) -> String {
            if let cwd, !cwd.isEmpty, path.hasPrefix(cwd + "/") { return String(path.dropFirst(cwd.count + 1)) }
            return path
        }
        func firstLine(_ s: String) -> String {
            let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.count > 80 ? String(trimmed.prefix(79)) + "…" : trimmed
        }
        switch tool {
        case "Edit", "Write", "MultiEdit", "NotebookEdit", "Read",
             "write_file", "replace", "read_file", "edit_file", "edit", "write", "read":
            if let p = str("file_path", "notebook_path", "path") { return short(p) }
            if let edits = dict["edits"] as? [[String: Any]], let p = edits.first?["file_path"] as? String { return short(p) }
            return ""
        case "Bash", "shell", "shell_command", "run_shell_command", "exec_command", "execute", "bash", "local_shell":
            if let c = str("command", "cmd") { return firstLine(c) }
            if let parts = dict["command"] as? [String] { return firstLine(parts.joined(separator: " ")) }
            return ""
        case "apply_patch":
            let files = ApplyPatch.touchedFiles(in: str("command", "patch") ?? "")
            return files.count == 1 ? files[0].path : (files.isEmpty ? "" : "\(files.count) files")
        case "Grep", "Glob", "search_file_content", "glob", "grep", "list_directory", "ls":
            return str("pattern", "query", "path", "dir_path") ?? ""
        case "WebFetch", "WebSearch", "web_fetch", "google_web_search", "web_search":
            return str("url", "query", "prompt") ?? ""
        case "Task", "Agent", "task":
            return str("description", "subagent_type", "prompt").map(firstLine) ?? ""
        default:
            return str("file_path", "path", "command", "query", "pattern", "url").map { firstLine(short($0)) } ?? ""
        }
    }
}

/// A prompt was submitted: the turn the status row's clock starts on.
public struct HookTurnStart: Equatable {
    public let sessionID: String?
    public let cwd: String?
    public let prompt: String?
    public init(sessionID: String?, cwd: String?, prompt: String?) {
        self.sessionID = sessionID; self.cwd = cwd; self.prompt = prompt
    }
}

/// A Claude Code subagent starting or stopping. `agentID` is Claude's `agent_id`;
/// `agentType` its `agent_type` ("Explore", "general-purpose", a custom name).
public struct HookSubagent: Equatable {
    public let sessionID: String?
    public let cwd: String?
    public let agentID: String
    public let agentType: String?
    public init(sessionID: String?, cwd: String?, agentID: String, agentType: String?) {
        self.sessionID = sessionID; self.cwd = cwd; self.agentID = agentID; self.agentType = agentType
    }
}


/// A permission request, with what a host needs to show it and — for Claude Code — to
/// answer it: the decision travels back on the hook's stdout (``PermissionDecision``).
public struct HookPermissionRequest: Equatable {
    public let sessionID: String?
    public let cwd: String?
    public let tool: String
    /// One-line argument summary, as for ``HookToolUse``.
    public let summary: String
    public let toolUseID: String?
    public let promptID: String?
    /// True when the payload is Claude Code's, whose hook may print a decision. Codex's
    /// PermissionRequest is display-only here.
    public let isDecidable: Bool
    /// Whether Claude offered "always allow" for this request (`permission_suggestions`).
    public let canAlwaysAllow: Bool

    public init(sessionID: String?, cwd: String?, tool: String, summary: String, toolUseID: String?,
                promptID: String?, isDecidable: Bool, canAlwaysAllow: Bool) {
        self.sessionID = sessionID; self.cwd = cwd; self.tool = tool; self.summary = summary
        self.toolUseID = toolUseID; self.promptID = promptID; self.isDecidable = isDecidable
        self.canAlwaysAllow = canAlwaysAllow
    }

    /// "Bash npm test" — the tool alone when it took nothing showable.
    public var label: String { summary.isEmpty ? tool : "\(tool) \(summary)" }
}

/// What a `PermissionRequest` hook prints to decide (Claude Code hooks reference, 2026):
/// `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":"allow"|"deny"|"always_allow","decisionReason":"…"}}`.
/// Printing nothing leaves the decision to Claude's own prompt.
public enum PermissionDecision: String, Equatable, Sendable {
    case allow
    case deny
    case alwaysAllow = "always_allow"

    /// The bytes for the hook's stdout, newline-terminated.
    public func hookOutput(reason: String? = nil) -> Data {
        var inner: [String: Any] = ["hookEventName": "PermissionRequest", "decision": rawValue]
        if let reason, !reason.isEmpty { inner["decisionReason"] = reason }
        let object: [String: Any] = ["hookSpecificOutput": inner]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return data + Data("\n".utf8)
    }

    /// Reads a decision back out of hook output — for the host's self-test.
    public static func parse(_ data: Data) -> PermissionDecision? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = object["hookSpecificOutput"] as? [String: Any],
              inner["hookEventName"] as? String == "PermissionRequest",
              let raw = inner["decision"] as? String else { return nil }
        return PermissionDecision(rawValue: raw)
    }
}
