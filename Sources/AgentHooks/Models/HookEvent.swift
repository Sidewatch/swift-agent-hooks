//
//  HookEvent.swift
//  AgentHooks
//
//  A decoded Claude Code hook event.
//
//  Created by David Sherlock on 7/19/26.
//

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
        guard let payload = HookPayload(data) else { return [] }
        switch payload.eventName {
        case "PreToolUse", "BeforeTool":
            return payload.tool.isEmpty ? [] : [toolUse(payload, finished: false)]
        case "PostToolUse", "AfterTool":
            return edits(in: payload) + (payload.tool.isEmpty ? [] : [toolUse(payload, finished: true)])
        case "UserPromptSubmit", "BeforeAgent":
            return [.turnStarted(HookTurnStart(sessionID: payload.session, cwd: payload.cwd, prompt: payload.string("prompt")))]
        case "SubagentStart":
            return [.subagentStarted(subagent(payload))]
        case "SubagentStop":
            return [.subagentStopped(subagent(payload))]
        case "Stop":
            return [stopped(payload, message: payload.string("last_assistant_message"), isNotification: false)]
        case "AfterAgent":
            return [stopped(payload, message: payload.string("prompt_response"), isNotification: false)]
        case "Notification":
            return [stopped(payload, message: payload.string("message"), isNotification: true)]
        case "PermissionRequest":
            return [stopped(payload, message: payload.tool.isEmpty ? "Approval needed" : "Approval needed: \(payload.tool)", isNotification: true),
                    .permissionRequested(permissionRequest(payload))]
        default:
            // Unknown event name but it carries a file-editing tool_input → still surface the
            // edit; otherwise ignore. Keeps us forward-compatible if an agent renames events.
            return edits(in: payload)
        }
    }

    // MARK: - One parser per event shape

    private static func toolUse(_ p: HookPayload, finished: Bool) -> HookEvent {
        .toolUsed(HookToolUse(sessionID: p.session, cwd: p.cwd, tool: p.tool,
                              summary: HookToolUse.summary(tool: p.tool, input: p.toolInput, cwd: p.cwd),
                              isFinished: finished))
    }

    /// The file edits a tool call touched: Codex's `apply_patch` names several in its patch
    /// text; everyone else names one in `tool_input`.
    private static func edits(in p: HookPayload) -> [HookEvent] {
        if p.tool == "apply_patch", let input = p.toolInput as? [String: Any], let patch = input["command"] as? String {
            return ApplyPatch.touchedFiles(in: patch).filter { $0.kind != .delete }.compactMap { edit($0.path, in: p) }
        }
        guard let path = filePath(fromToolInput: p.toolInput), let e = edit(path, in: p) else { return [] }
        return [e]
    }

    private static func edit(_ path: String, in p: HookPayload) -> HookEvent? {
        guard let url = resolve(path, cwd: p.cwd) else { return nil }
        return .fileEdited(HookFileEdit(fileURL: url, sessionID: p.session, tool: p.tool))
    }

    private static func subagent(_ p: HookPayload) -> HookSubagent {
        HookSubagent(sessionID: p.session, cwd: p.cwd,
                     agentID: p.string("agent_id") ?? p.string("agent_transcript_path") ?? "",
                     agentType: p.string("agent_type"))
    }

    private static func stopped(_ p: HookPayload, message: String?, isNotification: Bool) -> HookEvent {
        .agentStopped(HookAttention(sessionID: p.session, cwd: p.cwd, message: message, isNotification: isNotification))
    }

    /// Claude Code's payload carries tool_use_id / prompt_id; Codex's does not, and Codex's
    /// answer protocol is not this one — so only Claude's requests are decidable. "Always
    /// allow" is only offered when there is an allow rule to persist.
    private static func permissionRequest(_ p: HookPayload) -> HookPermissionRequest {
        let allowRules = p.suggestedAllowRules
        return HookPermissionRequest(
            sessionID: p.session, cwd: p.cwd, tool: p.tool,
            summary: HookToolUse.summary(tool: p.tool, input: p.toolInput, cwd: p.cwd),
            toolUseID: p.string("tool_use_id"), promptID: p.string("prompt_id"),
            isDecidable: p.has("tool_use_id") || p.has("prompt_id"),
            canAlwaysAllow: !allowRules.isEmpty, suggestedAllowRules: allowRules)
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
