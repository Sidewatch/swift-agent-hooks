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
    public static func isInstalled(projectRoot: URL, marker: String) -> Bool {
        let root = readSettings(settingsURL(projectRoot: projectRoot))
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

    /// Installs (or refreshes) the hook for `projectRoot`. First strips any prior
    /// entries tagged with `marker` (so a moved binary's path is corrected and
    /// nothing duplicates), then appends fresh PostToolUse / Stop / Notification
    /// hooks running `command`. Merges into and preserves any other hooks. Throws
    /// only on a filesystem/serialization failure.
    ///
    /// - Parameters:
    ///   - command: the full shell line to run (must contain `marker`).
    ///   - marker: the inert `# …` tag identifying this tool's own entries.
    @discardableResult
    public static func install(projectRoot: URL, command: String, marker: String) throws -> Bool {
        let url = settingsURL(projectRoot: projectRoot)
        var root = stripTaggedHooks(readSettings(url), marker: marker)
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]

        let cmdObject: [String: Any] = ["type": "command", "command": command, "timeout": 5]
        func append(_ event: String, matcher: String?) {
            var group: [String: Any] = ["hooks": [cmdObject]]
            if let matcher { group["matcher"] = matcher }
            var groups = (hooks[event] as? [[String: Any]]) ?? []
            groups.append(group)
            hooks[event] = groups
        }
        append("PostToolUse", matcher: "Edit|Write|MultiEdit|NotebookEdit")
        append("Stop", matcher: nil)            // no matcher → matches all
        append("Notification", matcher: nil)

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
        guard isInstalled(projectRoot: projectRoot, marker: marker) else { return false }
        let url = settingsURL(projectRoot: projectRoot)
        try writeSettings(stripTaggedHooks(readSettings(url), marker: marker), to: url)
        return true
    }

    // MARK: Internals

    /// Whether a command string carries `marker`.
    private static func isTagged(_ command: String?, marker: String) -> Bool {
        command?.contains(marker) ?? false
    }

    /// Reads a settings.json into a mutable dictionary. Absent, empty, or malformed
    /// all yield `[:]` — install then writes a minimal valid file rather than
    /// crashing (a hand-broken settings file is treated as no settings).
    private static func readSettings(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return [:] }
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
