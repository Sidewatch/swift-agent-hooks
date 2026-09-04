//
//  HookToolUse.swift
//  AgentHooks
//

import Foundation

/// What a tool call is, in one short line: the file for an edit, the command for a shell
/// call, the pattern for a search. A status row shows "claude · Edit main.swift" from it.
public struct HookToolUse: Equatable, Sendable {
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
