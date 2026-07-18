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
    }

    func testUnknownEventWithFilePathStillSurfacesEdit() {
        // Forward-compat: a renamed event that still carries an edit tool_input.
        let e = HookEvent.parse(data(#"{"hook_event_name":"FutureEvent","tool_name":"Write","tool_input":{"file_path":"/p/x.swift"}}"#))
        guard case .fileEdited(let edit)? = e else { return XCTFail("expected fileEdited") }
        XCTAssertEqual(edit.fileURL.path, "/p/x.swift")
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

    func testUninstallNoOpWhenNotInstalled() throws {
        let p = try makeProject(); defer { try? FileManager.default.removeItem(at: p) }
        try seedUserSettings(p)
        let before = settingsText(p)
        let changed = try HookSettings.uninstall(projectRoot: p, marker: marker)
        XCTAssertFalse(changed)                            // nothing installed → no rewrite
        XCTAssertEqual(settingsText(p), before)
    }
}
