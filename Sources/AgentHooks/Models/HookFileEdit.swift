//
//  HookFileEdit.swift
//  AgentHooks
//
//  A file the agent just touched (from a `PostToolUse` edit event).
//
//  Created by David Sherlock on 9/5/26.
//

import Foundation

/// A file the agent just touched (from a `PostToolUse` edit event).
public struct HookFileEdit: Equatable, Sendable {
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
