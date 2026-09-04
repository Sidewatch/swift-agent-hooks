import Foundation

/// A hook install at USER level: one settings file in the home directory rather than a
/// project's. Claude Code reads settings only from the directory it was launched in (no
/// walk-up outside a git repo), so a project-level install at a site's root does nothing for a
/// Claude started in a subfolder; Codex and Gemini have no untracked per-project file at all,
/// and our entries embed this machine's binary path, which must never land in a repo. The
/// receiver attributes every event by `cwd`, so a user-level install still reaches the right
/// terminal. Same hook command, same marker, same non-destructive merge; the payload
/// differences live in `HookEvent`.
public struct UserLevelHookInstaller {
    /// The agent's display name, for menus and alerts.
    public let name: String
    /// The settings file: `~/.claude/settings.json`, `~/.codex/hooks.json`, `~/.gemini/settings.json`.
    public let file: URL
    public let entries: [HookSettings.Entry]
    /// Seconds for Claude and Codex, MILLISECONDS for Gemini — the one place the formats differ.
    public let timeout: Int
    /// Supplies the command and the marker.
    public let installer: HookInstaller

    public init(name: String, file: URL, entries: [HookSettings.Entry], timeout: Int, installer: HookInstaller) {
        self.name = name
        self.file = file
        self.entries = entries
        self.timeout = timeout
        self.installer = installer
    }

    /// Claude Code, all projects: the same entries the per-project install writes. Seconds.
    public static func claude(home: URL, installer: HookInstaller) -> UserLevelHookInstaller {
        UserLevelHookInstaller(name: "Claude Code", file: home.appendingPathComponent(".claude/settings.json"),
                               entries: HookSettings.claudeEntries, timeout: 5, installer: installer)
    }

    /// Codex: `apply_patch` edits surface under the Edit/Write matcher aliases; Stop;
    /// PermissionRequest (needs you, names the tool). Read from `codex-rs/hooks`. Seconds.
    public static func codex(home: URL, installer: HookInstaller) -> UserLevelHookInstaller {
        UserLevelHookInstaller(name: "Codex", file: home.appendingPathComponent(".codex/hooks.json"),
                               // No matcher on PostToolUse: Codex's editing tool is `apply_patch`,
                               // which an "Edit|Write" matcher never fired for, and a status rail
                               // wants every tool for its "what is it doing" line anyway.
                               entries: [HookSettings.Entry("PostToolUse"),
                                         HookSettings.Entry("UserPromptSubmit"),
                                         HookSettings.Entry("Stop"),
                                         HookSettings.Entry("PermissionRequest")],
                               timeout: 5, installer: installer)
    }

    /// Gemini: `write_file` / `replace` carry `file_path`; Notification (ToolPermission);
    /// AfterAgent (turn finished). Read from `packages/core/src/hooks`. Milliseconds.
    public static func gemini(home: URL, installer: HookInstaller) -> UserLevelHookInstaller {
        UserLevelHookInstaller(name: "Gemini CLI", file: home.appendingPathComponent(".gemini/settings.json"),
                               entries: [HookSettings.Entry("BeforeTool"),
                                         HookSettings.Entry("AfterTool"),
                                         HookSettings.Entry("BeforeAgent"),
                                         HookSettings.Entry("Notification"),
                                         HookSettings.Entry("AfterAgent")],
                               timeout: 5000, installer: installer)
    }

    public var isInstalled: Bool { HookSettings.isInstalled(at: file, marker: installer.marker) }

    /// Installs (or refreshes) the entries, creating the settings folder if needed.
    @discardableResult
    public func install() throws -> Bool {
        guard let command = installer.command() else { return false }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try HookSettings.install(at: file, entries: entries, command: command,
                                        marker: installer.marker, timeout: timeout)
    }

    @discardableResult
    public func uninstall() throws -> Bool { try HookSettings.uninstall(at: file, marker: installer.marker) }

    /// The moved-app rule, as `HookInstaller.refreshIfStale(projectRoot:)`.
    @discardableResult
    public func refreshIfStale() -> Bool {
        installer.refreshIfStale(at: file, entries: entries) { try install() }
    }
}
