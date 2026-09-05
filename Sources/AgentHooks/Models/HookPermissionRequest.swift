//
//  HookPermissionRequest.swift
//  AgentHooks
//
//  A permission request, with what a host needs to show it and — for Claude Code — to answer
//  it: the decision travels back on the hook's stdout (``PermissionDecision``).
//
//  Created by David Sherlock on 9/5/26.
//

import Foundation

/// A permission request, with what a host needs to show it and — for Claude Code — to
/// answer it: the decision travels back on the hook's stdout (``PermissionDecision``).
public struct HookPermissionRequest: Equatable, Sendable {
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
    /// Whether Claude offered "always allow" for this request (an allow rule in
    /// `permission_suggestions`).
    public let canAlwaysAllow: Bool
    /// The allow rules Claude suggested persisting (`"Bash(npm test:*)"`); sent back as
    /// `updatedPermissions` with an allow-and-don't-ask-again decision.
    public let suggestedAllowRules: [String]

    public init(sessionID: String?, cwd: String?, tool: String, summary: String, toolUseID: String?,
                promptID: String?, isDecidable: Bool, canAlwaysAllow: Bool, suggestedAllowRules: [String] = []) {
        self.sessionID = sessionID; self.cwd = cwd; self.tool = tool; self.summary = summary
        self.toolUseID = toolUseID; self.promptID = promptID; self.isDecidable = isDecidable
        self.canAlwaysAllow = canAlwaysAllow; self.suggestedAllowRules = suggestedAllowRules
    }

    /// "Bash npm test" — the tool alone when it took nothing showable.
    public var label: String { summary.isEmpty ? tool : "\(tool) \(summary)" }
}
