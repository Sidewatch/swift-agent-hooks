//
//  HookTurnStart.swift
//  AgentHooks
//
//  A prompt was submitted: the turn the status row's clock starts on.
//
//  Created by David Sherlock on 9/5/26.
//

import Foundation

/// A prompt was submitted: the turn the status row's clock starts on.
public struct HookTurnStart: Equatable, Sendable {
    public let sessionID: String?
    public let cwd: String?
    public let prompt: String?
    public init(sessionID: String?, cwd: String?, prompt: String?) {
        self.sessionID = sessionID; self.cwd = cwd; self.prompt = prompt
    }
}
