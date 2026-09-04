# Swift Claude Code Hooks

The pure, testable core for integrating with [Claude Code](https://docs.anthropic.com/en/docs/claude-code) hooks — a lenient event parser and a non-destructive `settings.local.json` installer. Foundation only, zero dependencies. The transport (how you receive events) is left to the host; this package is the parsing + settings logic worth unit-testing.

## What are Claude Code hooks?

Claude Code runs user-configured shell commands on lifecycle events (`PostToolUse`, `Stop`, `Notification`) and hands each one a JSON event on stdin. A tool can register itself as such a hook to react — live — to what the agent does (e.g. "the agent just edited this file", "the agent is waiting on you").

## Features

- 🧩 **Lenient event parsing** — `HookEvent.parse(_ data:)` decodes a hook's stdin JSON into a typed `HookEvent` (`.fileEdited(HookFileEdit)` / `.agentStopped(HookAttention)`). Tolerant of missing/unknown fields (malformed → nil, never a crash); pulls the edited path from `file_path` / `notebook_path` / nested `edits[]`; forward-compatible with renamed events that still carry an edit `tool_input`
- 🔧 **Non-destructive installer** — `HookSettings.install/uninstall/isInstalled` merge a hook into a project's `.claude/settings.local.json` (the untracked, per-project local override). The shell command and an inert `# …` marker tag are **injected by the caller**, so the package stays free of any app's binary path:
  - **Merges** into existing hooks — a user's own hooks and unrelated keys survive
  - **Idempotent** — re-installing strips prior tagged entries first, so it never duplicates
  - **Reversible** — uninstall removes *exactly* the tagged entries (pruning emptied groups) and nothing else; a no-op when nothing is installed
- 🔒 **Local only** — writes only the machine-local `settings.local.json`; no network, no globals
- 🪶 **Zero dependencies** — Foundation only
- 🧪 **Tested** — parse across every event/tool shape + malformed input, and the full install → merge → idempotency → uninstall roundtrip preserving user hooks

## Requirements

- macOS 10.15+
- Swift 5.9+

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/Sidewatch/swift-claude-code-hooks.git", from: "1.0.0")
]
```

## Usage

```swift
import ClaudeCodeHooks

// Parse an event a hook received on stdin.
if let event = HookEvent.parse(stdinData) {
    switch event {
    case .fileEdited(let e):   openInEditor(e.fileURL)          // reveal the live edit
    case .agentStopped(let a): if a.isNotification { ping() }   // agent needs you
    }
}

// Register this tool as a hook for a project (command + marker injected by you).
let marker = "# myapp-hook"
let command = "\(myBinaryPathQuoted) --hook \(marker)"
try HookSettings.install(projectRoot: repo, command: command, marker: marker)

// Later, cleanly remove exactly what you added.
try HookSettings.uninstall(projectRoot: repo, marker: marker)
```

## Notes

- **Transport is not here.** How events reach your process — a Unix-domain socket, a named pipe, an HTTP endpoint — is a host concern (and often platform-specific). This package parses the bytes and manages the settings file; wire the delivery yourself.
- The command string you pass to `install` is expected to already contain the `marker`, so the installer can detect its own entries for idempotent re-install and exact uninstall.

## For agents

Read `CONTRIBUTING.md` first: the folder layout and the PR rules. `swift test` is the whole
check, and a new test must fail before the change it covers. `CLAUDE.md` / `AGENTS.md` carry a
module map.

