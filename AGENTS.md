# Swift Agent Hooks

The pure, testable core for integrating with [Claude Code](https://docs.anthropic.com/en/docs/claude-code) hooks — a lenient event parser and a non-destructive `settings.local.json` installer. Foundation only, zero dependencies. The transport (how you receive events) is left to the host; this package is the parsing + settings logic worth unit-testing.

- Module `AgentHooks` in `Sources/AgentHooks`; tests in `Tests`; `swift test` is the whole check.
- Swift 6 language mode, tools 6.2, macOS 14+, no dependencies unless the README says so.
- Part of the Sidewatch package family; every package follows the same layout and PR rules.

## Module map

- `Errors/` — every Error type, one per file: HookSettings+SettingsError
- `Models/` — value types — the shape of a thing, nothing else: HookEvent
- `Settings/` — the engine: settings: HookSettings
- `Support/` — pure helpers: parsing, escaping, validation: ApplyPatch

## Rules

Read `CONTRIBUTING.md` before changing anything: it is the layout and PR rulebook for this package.
