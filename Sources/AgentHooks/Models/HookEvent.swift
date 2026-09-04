import Foundation

/// A decoded Claude Code hook event. Parsing is deliberately lenient
/// (`JSONSerialization`, tolerant of unknown/missing fields): a malformed or
/// unrecognized event yields nil and is silently dropped, never crashes.
///
/// Field names follow the Claude Code hooks contract — which Codex and Gemini share in
/// outline: `hook_event_name`,
/// `session_id`, `tool_name`, `tool_input.file_path`. This is a pure value —
/// how a host reacts (post a notification, open a file) is the host's concern.
public enum HookEvent: Equatable, Sendable {
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
            // `permission_suggestions` is an ARRAY of {type: allow|deny, rule} (hooks reference,
            // 2026) — the rules Claude would persist for "don't ask again". An "always allow"
            // is only offered when there is an allow rule to persist.
            let suggestions = (dict["permission_suggestions"] as? [[String: Any]]) ?? []
            let allowRules = suggestions.compactMap { $0["type"] as? String == "allow" ? $0["rule"] as? String : nil }
            let request = HookPermissionRequest(
                sessionID: session, cwd: cwd, tool: tool,
                summary: HookToolUse.summary(tool: tool, input: dict["tool_input"], cwd: cwd),
                toolUseID: dict["tool_use_id"] as? String,
                promptID: dict["prompt_id"] as? String,
                // Claude Code's payload carries tool_use_id / prompt_id; Codex's does not, and
                // Codex's answer protocol is not this one — so only Claude's are decidable.
                isDecidable: dict["tool_use_id"] != nil || dict["prompt_id"] != nil,
                canAlwaysAllow: !allowRules.isEmpty, suggestedAllowRules: allowRules)
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
