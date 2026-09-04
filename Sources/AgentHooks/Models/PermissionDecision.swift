//
//  PermissionDecision.swift
//  AgentHooks
//

import Foundation

/// What a `PermissionRequest` hook prints to decide (code.claude.com hooks reference, read
/// 4 Sep 2026): `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":
/// "allow"|"deny"|"allowAndDontAskAgain","message":"…","updatedPermissions":[{"type":"allow",
/// "rule":"…"}]}}`. Exit code 2 is NOT honoured for this event; only this JSON decides.
/// Printing nothing leaves the decision to Claude's own prompt. (The first version invented
/// `always_allow` / `decisionReason` and would have been ignored by real Claude.)
public enum PermissionDecision: String, Equatable, Sendable {
    case allow
    case deny
    case alwaysAllow = "allowAndDontAskAgain"

    /// The bytes for the hook's stdout, newline-terminated. `updatedPermissions` are the allow
    /// rules to persist — pass the request's `suggestedAllowRules` with `.alwaysAllow`.
    public func hookOutput(reason: String? = nil, updatedPermissions: [String] = []) -> Data {
        var inner: [String: Any] = ["hookEventName": "PermissionRequest", "decision": rawValue]
        if let reason, !reason.isEmpty { inner["message"] = reason }
        if !updatedPermissions.isEmpty {
            inner["updatedPermissions"] = updatedPermissions.map { ["type": "allow", "rule": $0] }
        }
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
