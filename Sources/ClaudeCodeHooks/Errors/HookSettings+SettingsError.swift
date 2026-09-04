import Foundation

extension HookSettings {
    /// Thrown by ``install(projectRoot:command:marker:)`` when a settings file
    /// exists but cannot be parsed as a JSON object — merging would have to treat
    /// its contents (permissions, the user's other hooks) as absent and rewrite
    /// the file without them, so the install refuses instead.
    public enum SettingsError: Error, Equatable {
        case malformedSettings(URL)
    }
}
