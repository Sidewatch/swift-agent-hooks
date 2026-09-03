//
//  ClaudeCodeHooksTests.swift
//  Tests for HookEvent.parse (lenient JSON → typed event) and HookSettings
//  (non-destructive, idempotent, reversible settings.local.json merge) — the pure
//  core the app's --hook-selftest exercises end-to-end.
//

import XCTest
@testable import ClaudeCodeHooks

final class ClaudeCodeHooksTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - HookEvent.parse

    func testParsesPostToolUseEdit() {
        let e = HookEvent.parse(data(#"{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"/p/main.swift"}}"#))
        guard case .fileEdited(let edit)? = e else { return XCTFail("expected fileEdited") }
        XCTAssertEqual(edit.fileURL.path, "/p/main.swift")
        XCTAssertEqual(edit.sessionID, "s1")
        XCTAssertEqual(edit.tool, "Edit")
    }

    func testParsesNotebookPath() {
        let e = HookEvent.parse(data(#"{"hook_event_name":"PostToolUse","tool_name":"NotebookEdit","tool_input":{"notebook_path":"/p/n.ipynb"}}"#))
        guard case .fileEdited(let edit)? = e else { return XCTFail("expected fileEdited") }
        XCTAssertEqual(edit.fileURL.path, "/p/n.ipynb")
    }

    func testParsesNestedEditsArrayFilePath() {
        let e = HookEvent.parse(data(#"{"hook_event_name":"PostToolUse","tool_name":"MultiEdit","tool_input":{"edits":[{"file_path":"/p/a.swift"}]}}"#))
        guard case .fileEdited(let edit)? = e else { return XCTFail("expected fileEdited") }
        XCTAssertEqual(edit.fileURL.path, "/p/a.swift")
    }

    func testParsesStopAsAttention() {
        let e = HookEvent.parse(data(#"{"session_id":"s2","hook_event_name":"Stop","last_assistant_message":"Done."}"#))
        guard case .agentStopped(let a)? = e else { return XCTFail("expected agentStopped") }
        XCTAssertEqual(a.message, "Done.")
        XCTAssertFalse(a.isNotification)
    }

    func testParsesNotificationAsAttention() {
        let e = HookEvent.parse(data(#"{"hook_event_name":"Notification","message":"Needs permission"}"#))
        guard case .agentStopped(let a)? = e else { return XCTFail("expected agentStopped") }
        XCTAssertEqual(a.message, "Needs permission")
        XCTAssertTrue(a.isNotification)
        XCTAssertNil(a.cwd)
    }

    func testAttentionCarriesCwd() {
        // `cwd` is the strongest attribution signal in the payload — a consumer can compare it
        // to a terminal's directory as a plain path, with no lossy transcript-name encoding.
        // Both attention shapes must surface it verbatim.
        let stop = HookEvent.parse(data(
            #"{"session_id":"s3","cwd":"/Users/x/Developer/FSS Migration","hook_event_name":"Stop","stop_hook_active":false}"#))
        guard case .agentStopped(let s)? = stop else { return XCTFail("expected agentStopped") }
        XCTAssertEqual(s.cwd, "/Users/x/Developer/FSS Migration")
        let notif = HookEvent.parse(data(
            #"{"session_id":"s3","cwd":"/tmp/my_project","hook_event_name":"Notification","message":"m"}"#))
        guard case .agentStopped(let n)? = notif else { return XCTFail("expected agentStopped") }
        XCTAssertEqual(n.cwd, "/tmp/my_project")
    }

    func testUnknownEventWithFilePathStillSurfacesEdit() {
        // Forward-compat: a renamed event that still carries an edit tool_input.
        let e = HookEvent.parse(data(#"{"hook_event_name":"FutureEvent","tool_name":"Write","tool_input":{"file_path":"/p/x.swift"}}"#))
        guard case .fileEdited(let edit)? = e else { return XCTFail("expected fileEdited") }
        XCTAssertEqual(edit.fileURL.path, "/p/x.swift")
    }

    func testInstalledCommandsReportWhatIsWrittenAndFollowARefresh() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: project) }
        XCTAssertEqual(HookSettings.installedCommands(projectRoot: project, marker: "# m"), [])
        _ = try HookSettings.install(projectRoot: project, command: "'/old/App' --hook # m", marker: "# m")
        XCTAssertEqual(HookSettings.installedCommands(projectRoot: project, marker: "# m"), ["'/old/App' --hook # m"])
        // A refresh with the new path replaces every tagged entry: one command, the new one.
        _ = try HookSettings.install(projectRoot: project, command: "'/new/App' --hook # m", marker: "# m")
        XCTAssertEqual(HookSettings.installedCommands(projectRoot: project, marker: "# m"), ["'/new/App' --hook # m"])
        // Someone else's hook is never reported as ours.
        XCTAssertEqual(HookSettings.installedCommands(projectRoot: project, marker: "# other"), [])
    }

    // MARK: - Codex CLI (payloads per codex-rs/hooks + core/tools/hook_names.rs)

    func testCodexApplyPatchYieldsOneEditPerTouchedFileRelativeToCwd() {
        let patch = "*** Begin Patch\n*** Update File: src/a.swift\n@@\n-x\n+y\n*** Add File: docs/new.md\n+hello\n*** Delete File: old.txt\n*** Update File: lib/b.swift\n*** Move to: lib/c.swift\n*** End Patch\n"
        let json: [String: Any] = ["session_id": "s1", "turn_id": "t1", "cwd": "/tmp/proj",
                                   "hook_event_name": "PostToolUse", "tool_name": "apply_patch",
                                   "tool_input": ["command": patch], "tool_response": "ok"]
        let events = HookEvent.parseAll(try! JSONSerialization.data(withJSONObject: json))
        let urls = events.compactMap { if case .fileEdited(let e) = $0 { return e.fileURL.path } else { return nil } }
        XCTAssertEqual(urls, ["/tmp/proj/src/a.swift", "/tmp/proj/docs/new.md", "/tmp/proj/lib/c.swift"],
                       "Update and Add surface, Delete does not, Move renames the Update")
        if case .fileEdited(let e) = events[0] { XCTAssertEqual(e.tool, "apply_patch"); XCTAssertEqual(e.sessionID, "s1") } else { XCTFail() }
    }

    func testCodexBashPostToolUseIsNotAnEdit() {
        let json: [String: Any] = ["session_id": "s1", "cwd": "/tmp/proj", "hook_event_name": "PostToolUse",
                                   "tool_name": "Bash", "tool_input": ["command": "ls"], "tool_response": "a b"]
        XCTAssertEqual(HookEvent.parseAll(try! JSONSerialization.data(withJSONObject: json)), [])
    }

    func testCodexPermissionRequestIsNeedsYou() {
        let json: [String: Any] = ["session_id": "s1", "cwd": "/tmp/proj", "hook_event_name": "PermissionRequest",
                                   "tool_name": "Bash", "tool_input": ["command": "rm -rf build"], "permission_mode": "default"]
        guard case .agentStopped(let a)? = HookEvent.parse(try! JSONSerialization.data(withJSONObject: json)) else { return XCTFail() }
        XCTAssertTrue(a.isNotification)
        XCTAssertEqual(a.cwd, "/tmp/proj")
        XCTAssertEqual(a.message, "Approval needed: Bash")
    }

    func testApplyPatchParserHandlesCRLFAndBlankPaths() {
        let touches = ApplyPatch.touchedFiles(in: "*** Begin Patch\r\n*** Update File: a.txt\r\n*** Add File: \r\n*** End Patch\r\n")
        XCTAssertEqual(touches, [ApplyPatch.Touch(path: "a.txt", kind: .update)])
    }

    // MARK: - Gemini CLI (payloads per packages/core/src/hooks/types.ts)

    func testGeminiAfterToolWriteFileAndReplaceAreEdits() {
        for (tool, input) in [("write_file", ["file_path": "/tmp/proj/x.py", "content": "print(1)"]),
                              ("replace", ["file_path": "/tmp/proj/y.py", "old_string": "a", "new_string": "b"])] {
            let json: [String: Any] = ["session_id": "g1", "transcript_path": "/tmp/t.json", "cwd": "/tmp/proj",
                                       "hook_event_name": "AfterTool", "timestamp": "2026-09-03T00:00:00Z",
                                       "tool_name": tool, "tool_input": input, "tool_response": ["llmContent": "ok"]]
            guard case .fileEdited(let e)? = HookEvent.parse(try! JSONSerialization.data(withJSONObject: json)) else { return XCTFail(tool) }
            XCTAssertEqual(e.fileURL.path, input["file_path"]!)
            XCTAssertEqual(e.tool, tool)
        }
    }

    func testGeminiShellToolIsNotAnEdit() {
        let json: [String: Any] = ["session_id": "g1", "cwd": "/tmp/proj", "hook_event_name": "AfterTool",
                                   "tool_name": "run_shell_command", "tool_input": ["command": "ls"], "tool_response": ["llmContent": "a"]]
        XCTAssertNil(HookEvent.parse(try! JSONSerialization.data(withJSONObject: json)))
    }

    func testGeminiNotificationAndAfterAgent() {
        let notif: [String: Any] = ["session_id": "g1", "cwd": "/tmp/proj", "hook_event_name": "Notification",
                                    "notification_type": "ToolPermission", "message": "Allow write_file?", "details": [:]]
        guard case .agentStopped(let a)? = HookEvent.parse(try! JSONSerialization.data(withJSONObject: notif)) else { return XCTFail() }
        XCTAssertTrue(a.isNotification); XCTAssertEqual(a.message, "Allow write_file?")
        let done: [String: Any] = ["session_id": "g1", "cwd": "/tmp/proj", "hook_event_name": "AfterAgent",
                                   "prompt": "fix it", "prompt_response": "Fixed.", "stop_hook_active": false]
        guard case .agentStopped(let d)? = HookEvent.parse(try! JSONSerialization.data(withJSONObject: done)) else { return XCTFail() }
        XCTAssertFalse(d.isNotification); XCTAssertEqual(d.message, "Fixed."); XCTAssertEqual(d.cwd, "/tmp/proj")
    }

    // MARK: - Generic installer (Codex hooks.json / Gemini settings.json shapes)

    func testInstallAtURLWritesEntriesWithTheCallersTimeoutAndRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(".gemini/settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"theme":"dark","hooks":{"AfterTool":[{"matcher":"read_.*","hooks":[{"type":"command","command":"mine.sh"}]}]}}"#.utf8).write(to: file)
        let entries = [HookSettings.Entry("AfterTool", matcher: "write_file|replace"), HookSettings.Entry("Notification"), HookSettings.Entry("AfterAgent")]
        try HookSettings.install(at: file, entries: entries, command: "'/App' --hook # m", marker: "# m", timeout: 5000)
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        XCTAssertEqual(root["theme"] as? String, "dark", "unrelated settings survive")
        let hooks = root["hooks"] as! [String: Any]
        let after = hooks["AfterTool"] as! [[String: Any]]
        XCTAssertEqual(after.count, 2, "the user's own AfterTool group survives beside ours")
        let ours = (after[1]["hooks"] as! [[String: Any]])[0]
        XCTAssertEqual(ours["timeout"] as? Int, 5000)
        XCTAssertEqual(after[1]["matcher"] as? String, "write_file|replace")
        XCTAssertNotNil(hooks["Notification"]); XCTAssertNotNil(hooks["AfterAgent"])
        XCTAssertTrue(HookSettings.isInstalled(at: file, marker: "# m"))
        XCTAssertEqual(HookSettings.installedCommands(at: file, marker: "# m"), ["'/App' --hook # m"])
        try HookSettings.install(at: file, entries: entries, command: "'/App' --hook # m", marker: "# m", timeout: 5000)
        XCTAssertEqual(((try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any])["hooks"] as! [String: Any])["AfterTool"].map { ($0 as! [Any]).count }, 2, "idempotent")
        try HookSettings.uninstall(at: file, marker: "# m")
        let final = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        XCTAssertEqual(((final["hooks"] as! [String: Any])["AfterTool"] as! [Any]).count, 1, "only ours removed")
        XCTAssertNil((final["hooks"] as! [String: Any])["AfterAgent"])
    }

    func testPostToolUseWithoutFilePathIsDropped() {
        XCTAssertNil(HookEvent.parse(data(#"{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#)))
    }

    func testMalformedAndEmptyDropped() {
        XCTAssertNil(HookEvent.parse(data("")))
        XCTAssertNil(HookEvent.parse(data("not json")))
        XCTAssertNil(HookEvent.parse(data("[]")))          // array, not object
    }

    // MARK: - HookSettings (non-destructive merge)

    private let marker = "# sidewatch-hook"
    private var command: String { "/Apps/Sidewatch --hook \(marker)" }

    private func makeProject() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cchooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func seedUserSettings(_ project: URL) throws {
        let url = HookSettings.settingsURL(projectRoot: project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let seed = #"{"permissions":{"allow":["Bash(ls:*)"]},"hooks":{"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"my-own-hook.sh"}]}]}}"#
        try Data(seed.utf8).write(to: url)
    }

    private func settingsText(_ project: URL) -> String {
        (try? String(contentsOf: HookSettings.settingsURL(projectRoot: project), encoding: .utf8)) ?? ""
    }

    func testInstallOntoEmptyProject() throws {
        let p = try makeProject(); defer { try? FileManager.default.removeItem(at: p) }
        XCTAssertFalse(HookSettings.isInstalled(projectRoot: p, marker: marker))
        try HookSettings.install(projectRoot: p, command: command, marker: marker)
        XCTAssertTrue(HookSettings.isInstalled(projectRoot: p, marker: marker))
        // Three tagged commands: PostToolUse + Stop + Notification.
        XCTAssertEqual(settingsText(p).components(separatedBy: marker).count - 1, 3)
    }

    func testInstallPreservesUserHooksAndPermissions() throws {
        let p = try makeProject(); defer { try? FileManager.default.removeItem(at: p) }
        try seedUserSettings(p)
        try HookSettings.install(projectRoot: p, command: command, marker: marker)
        let text = settingsText(p)
        XCTAssertTrue(text.contains("my-own-hook.sh"))     // user's own hook survives
        XCTAssertTrue(text.contains("Bash(ls:*)"))         // unrelated key survives
        XCTAssertTrue(text.contains(marker))               // ours added
    }

    func testInstallIsIdempotent() throws {
        let p = try makeProject(); defer { try? FileManager.default.removeItem(at: p) }
        try seedUserSettings(p)
        try HookSettings.install(projectRoot: p, command: command, marker: marker)
        let afterFirst = settingsText(p)
        try HookSettings.install(projectRoot: p, command: command, marker: marker)
        let afterSecond = settingsText(p)
        XCTAssertEqual(afterFirst, afterSecond)            // no duplication
        XCTAssertEqual(afterSecond.components(separatedBy: marker).count - 1, 3)
    }

    func testUninstallRemovesOnlyOurs() throws {
        let p = try makeProject(); defer { try? FileManager.default.removeItem(at: p) }
        try seedUserSettings(p)
        try HookSettings.install(projectRoot: p, command: command, marker: marker)
        try HookSettings.uninstall(projectRoot: p, marker: marker)
        let text = settingsText(p)
        XCTAssertFalse(text.contains(marker))              // ours gone
        XCTAssertTrue(text.contains("my-own-hook.sh"))     // user's hook kept
        XCTAssertTrue(text.contains("Bash(ls:*)"))
        XCTAssertFalse(HookSettings.isInstalled(projectRoot: p, marker: marker))
    }

    func testInstallThrowsOnMalformedSettingsAndLeavesFileUntouched() throws {
        // A file that exists but can't be parsed must abort the install — treating
        // it as "no settings" would rewrite it with only our hooks, destroying the
        // user's permissions/hooks.
        let broken = [
            #"{"permissions":{"allow":["Bash(ls:*)"]}} // trailing comment"#,
            #"{"permissions":{"allow":["Bash(ls:*)"#,   // truncated (interrupted write)
            #"[{"hooks":{}}]"#,                          // top-level array, not an object
        ]
        for contents in broken {
            let p = try makeProject(); defer { try? FileManager.default.removeItem(at: p) }
            let url = HookSettings.settingsURL(projectRoot: p)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
            XCTAssertThrowsError(try HookSettings.install(projectRoot: p, command: command, marker: marker)) {
                XCTAssertEqual($0 as? HookSettings.SettingsError, .malformedSettings(url))
            }
            XCTAssertEqual(settingsText(p), contents)   // byte-for-byte untouched
        }
    }

    func testInstallOntoAbsentOrEmptyFileStillWorks() throws {
        // Absent (covered above) and EMPTY files are "no settings", not malformed.
        let p = try makeProject(); defer { try? FileManager.default.removeItem(at: p) }
        let url = HookSettings.settingsURL(projectRoot: p)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        try HookSettings.install(projectRoot: p, command: command, marker: marker)
        XCTAssertTrue(HookSettings.isInstalled(projectRoot: p, marker: marker))
    }

    func testUninstallNeverRewritesMalformedSettings() throws {
        let p = try makeProject(); defer { try? FileManager.default.removeItem(at: p) }
        let url = HookSettings.settingsURL(projectRoot: p)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let contents = #"{"oops": // not json"#
        try Data(contents.utf8).write(to: url)
        XCTAssertFalse(try HookSettings.uninstall(projectRoot: p, marker: marker))
        XCTAssertEqual(settingsText(p), contents)
    }

    func testUninstallNoOpWhenNotInstalled() throws {
        let p = try makeProject(); defer { try? FileManager.default.removeItem(at: p) }
        try seedUserSettings(p)
        let before = settingsText(p)
        let changed = try HookSettings.uninstall(projectRoot: p, marker: marker)
        XCTAssertFalse(changed)                            // nothing installed → no rewrite
        XCTAssertEqual(settingsText(p), before)
    }
}
