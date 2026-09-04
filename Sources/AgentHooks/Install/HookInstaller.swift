import Foundation

/// Installs an app's hook command into a project's Claude Code settings
/// (`<project>/.claude/settings.local.json`). Supplies the command and the marker to
/// `HookSettings`, whose non-destructive, idempotent, reversible merge is pure and tested here.
public struct HookInstaller: Sendable {

    /// The trailing shell comment tagging every entry the app writes. Inert at runtime (the
    /// shell ignores `# …`), it lets uninstall remove exactly what install added and a
    /// re-install never duplicate — independent of the binary's path, which changes when the
    /// app moves.
    public let marker: String

    /// The command the agent will run: the running binary's absolute path (shell-quoted) plus
    /// its hook flag, tagged with `marker`. nil when the executable path is unavailable.
    public let command: @Sendable () -> String?

    public init(marker: String, command: @escaping @Sendable () -> String?) {
        self.marker = marker
        self.command = command
    }

    /// `<projectRoot>/.claude/settings.local.json`.
    public func settingsURL(projectRoot: URL) -> URL {
        HookSettings.settingsURL(projectRoot: projectRoot)
    }

    /// Whether the hook is currently installed for `projectRoot`.
    public func isInstalled(projectRoot: URL) -> Bool {
        HookSettings.isInstalled(projectRoot: projectRoot, marker: marker)
    }

    /// Installs (or refreshes) the hook for `projectRoot`. False when the command is unavailable.
    @discardableResult
    public func install(projectRoot: URL) throws -> Bool {
        guard let command = command() else { return false }
        return try HookSettings.install(projectRoot: projectRoot, command: command, marker: marker)
    }

    /// Removes exactly the marker-tagged entries for `projectRoot`.
    @discardableResult
    public func uninstall(projectRoot: URL) throws -> Bool {
        try HookSettings.uninstall(projectRoot: projectRoot, marker: marker)
    }

    /// The moved-app rule. Entries embed the binary's absolute path at install time, so an app
    /// moved since (the build folder → Applications) leaves every project's hooks pointing at a
    /// dead binary: the agent reports a failing hook on each edit and nothing says why. Rewrites
    /// the entries when they are installed and stale — the binary moved, or this build listens
    /// for events the install predates — and returns false when absent or current. Quiet on
    /// error: a malformed file surfaces on the next explicit toggle, not on every open.
    @discardableResult
    public func refreshIfStale(projectRoot: URL) -> Bool {
        refreshIfStale(at: settingsURL(projectRoot: projectRoot), entries: HookSettings.claudeEntries) {
            try install(projectRoot: projectRoot)
        }
    }

    /// The staleness rule shared with `UserLevelHookInstaller`: rewrite when what is written
    /// differs from what this binary would write now; never touch an absent or current install.
    func refreshIfStale(at url: URL, entries: [HookSettings.Entry], reinstall: () throws -> Bool) -> Bool {
        guard let current = command() else { return false }
        let installed = HookSettings.installedCommands(at: url, marker: marker)
        guard !installed.isEmpty else { return false }
        let events = HookSettings.installedEvents(at: url, marker: marker)
        guard installed != [current] || events != Set(entries.map(\.event)) else { return false }
        return (try? reinstall()) ?? false
    }
}
