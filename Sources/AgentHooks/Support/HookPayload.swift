//
//  HookPayload.swift
//  AgentHooks
//
//  One hook's JSON payload with the fields every agent's schema shares, read once.
//
//  Created by David Sherlock on 9/5/26.
//

import Foundation

/// One hook's JSON payload with the fields every agent's schema shares, read once. The event
/// parsers ask this rather than digging in the dictionary, so a renamed field is one change.
struct HookPayload {
    let dict: [String: Any]

    init?(_ data: Data) {
        guard !data.isEmpty, let dict = JSONObject.parse(data) else { return nil }
        self.dict = dict
    }

    var eventName: String? { string("hook_event_name") }
    var session: String? { string("session_id") }
    var cwd: String? { string("cwd") }
    /// The tool name, or "" when the event carries none.
    var tool: String { string("tool_name") ?? "" }
    var toolInput: Any? { dict["tool_input"] }

    func string(_ key: String) -> String? { dict[key] as? String }
    func has(_ key: String) -> Bool { dict[key] != nil }

    /// `permission_suggestions` is an ARRAY of {type: allow|deny, rule}; these are the allow
    /// rules Claude would persist for "don't ask again".
    var suggestedAllowRules: [String] {
        ((dict["permission_suggestions"] as? [[String: Any]]) ?? [])
            .compactMap { $0["type"] as? String == "allow" ? $0["rule"] as? String : nil }
    }
}
