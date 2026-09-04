import Foundation

/// Writes (and removes) a Claude Code hook registration in a project's
/// `.claude/settings.local.json` — the untracked, per-project local override, so
/// the install is reversible, never committed, and never a shared/global change.
///
/// Non-destructive + idempotent + reversible: it merges into any existing hooks,
/// tags its own entries with a caller-supplied `marker` (an inert `# …` shell
/// comment on the command), and keys every operation off that tag so re-installing
/// can't duplicate and uninstall removes *exactly* what it added — leaving the
/// user's other hooks untouched.
///
/// The `command` (the shell line Claude Code runs) and `marker` are injected by the
/// caller, so this stays pure Foundation with no dependency on any particular app's
/// binary path. The command string is expected to already contain the marker.
public enum HookSettings {
    /// `<projectRoot>/.claude/settings.local.json`.
    public static func settingsURL(projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(".claude/settings.local.json")
    }

    /// Whether a hook tagged with `marker` is currently installed for `projectRoot`.
    /// One event registration: the event name and an optional matcher.
    public struct Entry: Equatable, Sendable {
        public let event: String
        public let matcher: String?
        /// Per-entry hook timeout (the installer's unit); nil takes the install call's default.
        /// PermissionRequest needs minutes — the hook is the one waiting for a human.
        public let timeout: Int?
        public init(_ event: String, matcher: String? = nil, timeout: Int? = nil) {
            self.event = event; self.matcher = matcher; self.timeout = timeout
        }
    }

    /// Claude Code's entries: file edits, turn clock, subagents, turn finished, needs you,
    /// and the permission prompt itself. Timeouts in seconds.
    public static let claudeEntries: [Entry] = [
        // Every tool, not just the editing ones: the Terminals rail shows what the agent is
        // doing ("Bash ./scripts/test.sh") from PreToolUse, and PostToolUse still carries the
        // file edits. UserPromptSubmit starts the turn clock; Subagent* feed the child rows.
        Entry("PreToolUse"),
        Entry("PostToolUse"),
        Entry("UserPromptSubmit"),
        Entry("SubagentStart"),
        Entry("SubagentStop"),
        Entry("Stop"),
        Entry("Notification"),
        // The Approval Inbox: Claude holds its own prompt while this hook runs and honours the
        // decision it prints. 300 s covers the inbox's 280 s hold plus the client's grace; the
        // default 5 s would have killed the hook before anyone could click. (Missing until
        // 4 Sep 2026 — the inbox was harness-proven but never registered with real Claude.)
        Entry("PermissionRequest", timeout: 300),
    ]

    public static func isInstalled(projectRoot: URL, marker: String) -> Bool {
        isInstalled(at: settingsURL(projectRoot: projectRoot), marker: marker)
    }

    /// Whether any entry tagged `marker` exists in the hooks file at `url`.
    public static func isInstalled(at url: URL, marker: String) -> Bool {
        let root = readSettings(url)
        guard let hooks = root["hooks"] as? [String: Any] else { return false }
        for value in hooks.values {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                guard let inner = group["hooks"] as? [[String: Any]] else { continue }
                if inner.contains(where: { isTagged($0["command"] as? String, marker: marker) }) {
                    return true
                }
            }
        }
        return false
    }

    /// The tagged commands currently written for `projectRoot` — what an installer
    /// compares against the command it would write today, to notice that the binary
    /// the entries point at has moved since they were installed.
    public static func installedCommands(projectRoot: URL, marker: String) -> Set<String> {
        installedCommands(at: settingsURL(projectRoot: projectRoot), marker: marker)
    }

    /// The event names that carry a tagged hook at `url` — so a host can tell that an
    /// install predates events it has since started listening for, and refresh it.
    public static func installedEvents(at url: URL, marker: String) -> Set<String> {
        let root = readSettings(url)
        var out = Set<String>()
        guard let hooks = root["hooks"] as? [String: Any] else { return out }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                guard let inner = group["hooks"] as? [[String: Any]] else { continue }
                if inner.contains(where: { isTagged($0["command"] as? String, marker: marker) }) { out.insert(event) }
            }
        }
        return out
    }

    public static func installedCommands(at url: URL, marker: String) -> Set<String> {
        let root = readSettings(url)
        var out = Set<String>()
        guard let hooks = root["hooks"] as? [String: Any] else { return out }
        for value in hooks.values {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                guard let inner = group["hooks"] as? [[String: Any]] else { continue }
                for hook in inner {
                    if let command = hook["command"] as? String, isTagged(command, marker: marker) { out.insert(command) }
                }
            }
        }
        return out
    }

    /// Installs (or refreshes) the hook for `projectRoot`. First strips any prior
    /// entries tagged with `marker` (so a moved binary's path is corrected and
    /// nothing duplicates), then appends fresh PostToolUse / Stop / Notification
    /// hooks running `command`. Merges into and preserves any other hooks. Throws
    /// on a filesystem/serialization failure, or ``SettingsError/malformedSettings(_:)``
    /// when an existing settings file can't be parsed (rewriting it would destroy
    /// whatever it held).
    ///
    /// - Parameters:
    ///   - command: the full shell line to run (must contain `marker`).
    ///   - marker: the inert `# …` tag identifying this tool's own entries.
    @discardableResult
    public static func install(projectRoot: URL, command: String, marker: String) throws -> Bool {
        try install(at: settingsURL(projectRoot: projectRoot), entries: claudeEntries, command: command, marker: marker)
    }

    /// Installs (or refreshes) `entries` into the hooks file at `url`, tagged with
    /// `marker`. The same JSON shape serves Claude Code (`.claude/settings.local.json`),
    /// Codex CLI (`.codex/hooks.json`) and Gemini CLI (`.gemini/settings.json`):
    /// `{"hooks": {Event: [{"matcher": …, "hooks": [{"type": "command", …}]}]}}` —
    /// only the timeout's unit differs (seconds for Claude and Codex, milliseconds
    /// for Gemini), hence `timeout` is the caller's. Strips prior tagged entries first,
    /// so a re-install never duplicates and a moved binary's path is corrected.
    @discardableResult
    public static func install(at url: URL, entries: [Entry], command: String, marker: String, timeout: Int = 5) throws -> Bool {
        var root = stripTaggedHooks(try readSettingsForMerge(url), marker: marker)
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]

        for entry in entries {
            let cmdObject: [String: Any] = ["type": "command", "command": command, "timeout": entry.timeout ?? timeout]
            var group: [String: Any] = ["hooks": [cmdObject]]
            if let matcher = entry.matcher { group["matcher"] = matcher }
            var groups = (hooks[entry.event] as? [[String: Any]]) ?? []
            groups.append(group)
            hooks[entry.event] = groups
        }

        root["hooks"] = hooks
        try writeSettings(root, to: url)
        return true
    }

    /// Removes exactly the entries tagged with `marker` for `projectRoot` (pruning
    /// any now-empty groups/events) and leaves everything else intact. No-op
    /// (returns false) when nothing is installed, so it never rewrites an untouched
    /// file.
    @discardableResult
    public static func uninstall(projectRoot: URL, marker: String) throws -> Bool {
        try uninstall(at: settingsURL(projectRoot: projectRoot), marker: marker)
    }

    @discardableResult
    public static func uninstall(at url: URL, marker: String) throws -> Bool {
        guard isInstalled(at: url, marker: marker) else { return false }
        try writeSettings(stripTaggedHooks(readSettings(url), marker: marker), to: url)
        return true
    }

    // MARK: Internals

    /// Whether a command string carries `marker`.
    private static func isTagged(_ command: String?, marker: String) -> Bool {
        command?.contains(marker) ?? false
    }

    /// Reads a settings.json into a mutable dictionary. Absent, empty, or malformed
    /// all yield `[:]` — safe for the read-only queries (`isInstalled` treats a
    /// hand-broken file as "nothing installed" and never rewrites it). Anything
    /// that writes the file back must use ``readSettingsForMerge(_:)`` instead.
    private static func readSettings(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return [:] }
        return dict
    }

    /// Reads settings that are about to be merged into and rewritten. Absent or
    /// empty yields `[:]`, but a present-yet-unparseable file (a stray `//`
    /// comment, a truncated write, a non-object root) throws — treating user data
    /// as "no settings" and overwriting would silently destroy it.
    private static func readSettingsForMerge(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw SettingsError.malformedSettings(url)
        }
        return dict
    }

    /// Pretty-prints the settings back to disk atomically, creating `.claude/` if
    /// needed. Sorted keys + unescaped slashes keep the file stable and readable.
    private static func writeSettings(_ root: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    /// Returns `root` with every hook entry tagged `marker` removed and any group or
    /// event left empty by that removal pruned — the shared core of uninstall and of
    /// install's dedup. Untagged entries and unrecognized shapes are preserved.
    private static func stripTaggedHooks(_ root: [String: Any], marker: String) -> [String: Any] {
        var root = root
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        for event in Array(hooks.keys) {                    // snapshot keys — we mutate `hooks`
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            for i in groups.indices {
                guard var inner = groups[i]["hooks"] as? [[String: Any]] else { continue }
                inner.removeAll { isTagged($0["command"] as? String, marker: marker) }
                groups[i]["hooks"] = inner
            }
            groups.removeAll { (($0["hooks"] as? [[String: Any]])?.isEmpty ?? false) }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return root
    }
}
