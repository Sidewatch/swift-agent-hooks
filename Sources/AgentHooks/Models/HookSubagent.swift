//
//  HookSubagent.swift
//  AgentHooks
//

import Foundation

/// A Claude Code subagent starting or stopping. `agentID` is Claude's `agent_id`;
/// `agentType` its `agent_type` ("Explore", "general-purpose", a custom name).
public struct HookSubagent: Equatable, Sendable {
    public let sessionID: String?
    public let cwd: String?
    public let agentID: String
    public let agentType: String?
    public init(sessionID: String?, cwd: String?, agentID: String, agentType: String?) {
        self.sessionID = sessionID; self.cwd = cwd; self.agentID = agentID; self.agentType = agentType
    }
}
