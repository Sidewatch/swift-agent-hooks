//
//  HookSocketTests.swift
//  AgentHooksTests
//
//  Tests for the hook forwarder and listener over a Unix socket: an edit event round-trips, and
//  Claude and Codex permission asks arrive intact.
//
//  Created by David Sherlock on 9/5/26.
//

import XCTest
@testable import AgentHooks

/// Tests for the hook forwarder and listener over a Unix socket: an edit event round-trips, and
/// Claude and Codex permission asks arrive intact.
final class HookSocketTests: XCTestCase {

    private func freshSocketURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hk-\(UUID().uuidString.prefix(8)).sock")
    }

    private let edit = #"{"hook_event_name":"PostToolUse","session_id":"s1","cwd":"/tmp/p","tool_name":"Edit","tool_input":{"file_path":"/tmp/p/a.swift","old_string":"a","new_string":"b"},"tool_response":{}}"#
    private let claudeAsk = #"{"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/tmp/p","tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"toolu_1","permission_suggestions":[]}"#
    private let codexAsk = #"{"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/tmp/p","tool_name":"Bash","tool_input":{"command":"ls"}}"#

    func testAnEditEventRoundTripsOverTheSocket() {
        let url = freshSocketURL()
        let delivered = expectation(description: "events delivered")
        nonisolated(unsafe) var received: [HookEvent] = []
        let listener = HookListener(socketURL: url, onEvents: { events in received = events; delivered.fulfill() })
        listener.start()
        defer { listener.stop() }
        XCTAssertTrue(listener.isListening)

        HookForwarder(socketURL: url).send(Data(edit.utf8))
        wait(for: [delivered], timeout: 5)
        XCTAssertFalse(received.isEmpty)
        XCTAssertTrue(received.contains { if case .fileEdited = $0 { return true } else { return false } },
                      "expected a fileEdited event among \(received)")
    }

    func testAPermissionRequestIsAnsweredOnTheSameConnection() {
        let url = freshSocketURL()
        let listener = HookListener(socketURL: url, onEvents: { _ in }, onPermissionRequest: { request, reply in
            XCTAssertTrue(request.isDecidable)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { reply(Data(#"{"decision":"allow"}"#.utf8)) }
            return true
        })
        listener.start()
        defer { listener.stop() }

        XCTAssertTrue(HookForwarder.isDecidablePermissionRequest(Data(claudeAsk.utf8)))
        let reply = HookForwarder(socketURL: url).sendAndAwaitReply(Data(claudeAsk.utf8), timeout: 5)
        XCTAssertEqual(reply.flatMap { String(data: $0, encoding: .utf8) }, #"{"decision":"allow"}"#)
    }

    func testADeclinedRequestIsClosedEmptyAtOnce() {
        let url = freshSocketURL()
        let listener = HookListener(socketURL: url, onEvents: { _ in }, onPermissionRequest: { _, _ in false })
        listener.start()
        defer { listener.stop() }

        let started = Date()
        let reply = HookForwarder(socketURL: url).sendAndAwaitReply(Data(claudeAsk.utf8), timeout: 5)
        XCTAssertNil(reply)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the fast path must not wait out the timeout")
    }

    func testCodexPermissionRequestsAreNotDecidable() {
        XCTAssertFalse(HookForwarder.isDecidablePermissionRequest(Data(codexAsk.utf8)))
        XCTAssertFalse(HookForwarder.isDecidablePermissionRequest(Data(edit.utf8)))
    }

    func testAStaleSocketFileIsReclaimed() throws {
        let url = freshSocketURL()
        try Data().write(to: url)                           // a leftover nothing answers
        let listener = HookListener(socketURL: url, onEvents: { _ in })
        listener.start()
        defer { listener.stop() }
        XCTAssertTrue(listener.isListening)
    }

    func testASecondListenerDefersToTheLiveOne() {
        let url = freshSocketURL()
        let first = HookListener(socketURL: url, onEvents: { _ in })
        first.start()
        defer { first.stop() }
        let second = HookListener(socketURL: url, onEvents: { _ in })
        second.start()
        XCTAssertTrue(first.isListening)
        XCTAssertFalse(second.isListening, "the first running instance owns the socket")
    }

    func testSendingWithNoListenerReturnsAtOnce() {
        let started = Date()
        HookForwarder(socketURL: freshSocketURL()).send(Data(edit.utf8))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }
}
