//
//  HookInstallerTests.swift
//  AgentHooksTests
//
//  Tests for `HookInstaller`: project and global installs round-trip, the marker keeps the
//  wrapper idempotent, and uninstall leaves other hooks alone.
//
//  Created by David Sherlock on 9/5/26.
//

import XCTest
@testable import AgentHooks

/// Tests for `HookInstaller`: project and global installs round-trip, the marker keeps the
/// wrapper idempotent, and uninstall leaves other hooks alone.
final class HookInstallerTests: XCTestCase {

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let marker = "# test-hook"

    func testProjectInstallRoundTrip() throws {
        let project = try temporaryFolder()
        let installer = HookInstaller(marker: marker) { "'/Applications/App' --hook # test-hook" }
        XCTAssertFalse(installer.isInstalled(projectRoot: project))
        XCTAssertTrue(try installer.install(projectRoot: project))
        XCTAssertTrue(installer.isInstalled(projectRoot: project))
        XCTAssertFalse(installer.refreshIfStale(projectRoot: project), "a current install is left alone")
        XCTAssertTrue(try installer.uninstall(projectRoot: project))
        XCTAssertFalse(installer.isInstalled(projectRoot: project))
    }

    func testAnUnavailableCommandInstallsNothing() throws {
        let project = try temporaryFolder()
        let installer = HookInstaller(marker: marker) { nil }
        XCTAssertFalse(try installer.install(projectRoot: project))
        XCTAssertFalse(installer.isInstalled(projectRoot: project))
    }

    func testAMovedBinaryRefreshesTheProjectInstall() throws {
        let project = try temporaryFolder()
        try HookInstaller(marker: marker) { "'/old/App' --hook # test-hook" }.install(projectRoot: project)
        let moved = HookInstaller(marker: marker) { "'/new/App' --hook # test-hook" }
        XCTAssertTrue(moved.refreshIfStale(projectRoot: project))
        let commands = HookSettings.installedCommands(at: moved.settingsURL(projectRoot: project), marker: marker)
        XCTAssertEqual(commands, ["'/new/App' --hook # test-hook"])
        XCTAssertFalse(moved.refreshIfStale(projectRoot: project), "now current")
    }

    func testUserLevelInstallsForEachAgent() throws {
        let home = try temporaryFolder()
        let installer = HookInstaller(marker: marker) { "'/Applications/App' --hook # test-hook" }
        for agent in [UserLevelHookInstaller.claude(home: home, installer: installer),
                      .codex(home: home, installer: installer),
                      .gemini(home: home, installer: installer)] {
            XCTAssertFalse(agent.isInstalled, agent.name)
            XCTAssertTrue(try agent.install(), agent.name)
            XCTAssertTrue(agent.isInstalled, agent.name)
            XCTAssertTrue(agent.file.path.hasPrefix(home.path), agent.name)
            XCTAssertFalse(agent.refreshIfStale(), "\(agent.name): current")
            XCTAssertTrue(try agent.uninstall(), agent.name)
            XCTAssertFalse(agent.isInstalled, agent.name)
        }
    }

    func testAMovedBinaryRefreshesAUserLevelInstall() throws {
        let home = try temporaryFolder()
        try UserLevelHookInstaller.codex(home: home, installer: HookInstaller(marker: marker) { "'/old/App' --hook # test-hook" }).install()
        let moved = UserLevelHookInstaller.codex(home: home, installer: HookInstaller(marker: marker) { "'/new/App' --hook # test-hook" })
        XCTAssertTrue(moved.refreshIfStale())
        XCTAssertEqual(HookSettings.installedCommands(at: moved.file, marker: marker), ["'/new/App' --hook # test-hook"])
    }
}
