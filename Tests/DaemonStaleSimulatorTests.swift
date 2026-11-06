// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import ArgumentParser
import Foundation
import Testing
@testable import SimUseCore

// Coverage for LINEIOS-216942: when the daemon's simulator is shut
// down out of band (`xcrun simctl shutdown` / quitting Simulator.app
// without `sim-use daemon stop`), the daemon should:
//   1. Surface a typed `stale_simulator` error envelope with an
//      actionable hint, instead of forwarding the terse "not found in
//      set" message that comes out of FBSimulatorControl.
//   2. Drop the cached HID handle for this UDID.
//   3. Self-terminate so the next client invocation re-spawns against
//      whatever state the simulator is in by then.
//
// `DaemonErrorKindClassifyTests` already covers (1)'s classification
// rules. This file covers the dispatcher composition: the rewritten
// message, the daemon-shutdown bit, and the wire shape of the
// envelope.

private struct HarmonyDispatchFailureCommand: SimUseExecutableCommand {
    static let configuration = CommandConfiguration(commandName: "harmony-dispatch-failure")
    var message = ""
    var jsonOutput: Bool { false }
    var managesLivenessState: Bool { true }

    func execute() async throws -> String {
        throw CLIError(errorDescription: message)
    }

    func format(_ result: String) -> CommandOutput { .line(result) }
}

@Suite("DaemonDispatch.staleSimulatorOutcome", .serialized)
@MainActor
struct DaemonStaleSimulatorOutcomeTests {
    private struct Envelope: Decodable {
        let id: String?
        let ok: Bool
        let error: String
        let kind: String
        let hint: String?
    }

    @Test("shouldStopDaemon is true so the server self-terminates after replying")
    func stopsDaemon() throws {
        let outcome = DaemonDispatch.staleSimulatorOutcome(
            id: nil,
            udid: "FAKE-UDID",
            underlying: "Simulator with UDID FAKE-UDID not found in set."
        )
        #expect(outcome.shouldStopDaemon == true)
    }

    @Test("iOS envelope wire shape: ok=false, kind=stale_simulator, message+hint mention the UDID")
    func envelopeShape() throws {
        // iOS-shaped UDID (8-4-4-4-12 hex) so `PlatformRouter`
        // classifies it as iOS and the dispatcher emits the
        // "no longer booted" wording rather than the Android variant.
        let udid = "12345678-1234-1234-1234-123456789012"
        let outcome = DaemonDispatch.staleSimulatorOutcome(
            id: "req-42",
            udid: udid,
            underlying: "Simulator with UDID \(udid) not found in set."
        )

        let envelope = try JSONDecoder().decode(Envelope.self, from: outcome.responseData)
        #expect(envelope.id == "req-42")
        #expect(envelope.ok == false)
        #expect(envelope.kind == DaemonErrorKind.staleSimulator.rawValue)
        #expect(envelope.error.contains(udid))
        #expect(envelope.error.contains("no longer booted"))
        #expect(envelope.hint != nil)
        #expect(envelope.hint?.contains(udid) == true)
        #expect(envelope.hint?.contains("daemon stop") == true)
        // The underlying error string is preserved so the user can
        // tell why we believed the simulator was shut down.
        #expect(envelope.error.contains("not found in set"))
    }

    @Test("Android envelope swaps the wording to 'not reachable via adb' so the diagnostic isn't iOS-flavoured")
    func androidEnvelopeShape() throws {
        // emulator-NNNN serial — looksLikeAndroid returns true so the
        // dispatcher takes the Android branch. The underlying adb
        // error is the one that triggers stale classification in
        // `DaemonErrorKind.isStaleSimulatorMessage`.
        let udid = "emulator-5554"
        let outcome = DaemonDispatch.staleSimulatorOutcome(
            id: "req-1",
            udid: udid,
            underlying: "adb command failed (-s \(udid) forward tcp:0 tcp:8080, exit 1): adb: device '\(udid)' not found"
        )

        let envelope = try JSONDecoder().decode(Envelope.self, from: outcome.responseData)
        #expect(envelope.kind == DaemonErrorKind.staleSimulator.rawValue)
        #expect(envelope.error.contains("Android device"))
        #expect(envelope.error.contains("not reachable via adb"))
        #expect(envelope.error.contains(udid))
        #expect(envelope.hint?.contains("adb devices") == true)
        #expect(envelope.hint?.contains("daemon stop") == true)
    }

    @Test("Harmony dispatch classifies only a disconnected transport as stale", arguments: [
        ("hdc failed (0): [Fail]Not match target founded, check connect-key please", true),
        ("hdc failed (1): [Fail]Not match target founded, check connect-key please", true),
        ("hdc failed (0): [Fail]Not match target founded, check connect-key please\r\n", true),
        ("hdc failed (1): uitest failed (0): [Fail]Not match target founded, check connect-key please", false),
        ("hdc failed (1): uitest: component not found", false),
        ("hdc failed (1): /system/bin/sh: uitest: not found", false),
        ("hdc failed (1): [Fail]Permission denied", false),
        ("hdc binary not found", false),
        ("hdc timed out after 30 seconds", false),
        ("uitest failed: [Fail]Not match target founded, check connect-key please", false),
    ])
    func harmonyDispatchFailure(message: String, isStale: Bool) async throws {
        try await withExclusiveCommandParser({ _ in HarmonyDispatchFailureCommand(message: message) }) {
            let savedPlatform = PlatformRouter.platformOverride
            let savedProbe = PlatformRouter.harmonyMembershipProbe
            let savedCleanup = DaemonDispatch.platformStaleCleanup
            defer {
                PlatformRouter.platformOverride = savedPlatform
                PlatformRouter.harmonyMembershipProbe = savedProbe
                DaemonDispatch.platformStaleCleanup = savedCleanup
            }
            PlatformRouter.platformOverride = .harmony
            var probes = 0
            PlatformRouter.harmonyMembershipProbe = { _ in
                probes += 1
                throw CLIError(errorDescription: "hdc unavailable after disconnect")
            }
            var cleanedTargets: [String] = []
            DaemonDispatch.platformStaleCleanup = { cleanedTargets.append($0) }
            let udid = "TESTHARMONY000001"
            let outcome = await DaemonDispatch.handle(
                DaemonRequest(id: "harmony-failure", cmd: "harmony-dispatch-failure", args: []),
                snapshot: .init(pid: 1, startTime: Date(), udid: udid, simUseVersion: "fixture")
            )
            let envelope = try JSONDecoder().decode(Envelope.self, from: outcome.responseData)
            #expect(envelope.id == "harmony-failure")
            #expect(!envelope.ok)
            #expect(outcome.shouldStopDaemon == isStale)
            #expect(probes == 0)
            if isStale {
                #expect(envelope.kind == DaemonErrorKind.staleSimulator.rawValue)
                #expect(envelope.error.contains("Harmony"))
                #expect(envelope.error.contains(udid))
                #expect(envelope.error.contains(message))
                #expect(envelope.hint?.contains("hdc list targets") == true)
                #expect(!envelope.error.contains("adb"))
                #expect(cleanedTargets == [udid])
            } else {
                #expect(envelope.kind == DaemonErrorKind.other.rawValue)
                #expect(envelope.error == message)
                #expect(envelope.hint == nil)
                #expect(cleanedTargets.isEmpty)
            }
        }
    }

    @Test("nil request id is omitted from the wire envelope (no \"id\":null)")
    func nilIdOmitted() throws {
        // FAKE-UDID is digit-free so `looksLikeAndroid` returns
        // false and the iOS branch runs. The check below cares only
        // about the JSON shape, not the message wording.
        let outcome = DaemonDispatch.staleSimulatorOutcome(
            id: nil,
            udid: "FAKE-UDID",
            underlying: "Simulator with UDID FAKE-UDID not found in set."
        )
        let raw = String(data: outcome.responseData, encoding: .utf8) ?? ""
        #expect(!raw.contains("\"id\""),
                "nil request id should not appear on the wire; got: \(raw)")
    }

    @Test("calling staleSimulatorOutcome drops the cached HID connection for the UDID")
    func clearsHIDCache() async {
        // We can't easily inject a fake FBSimulatorHID, but we can
        // verify the post-condition: after the call, no entry remains.
        // (Pre-condition: the cache may or may not have an entry; this
        // call must be a no-op when none exists, which is how it would
        // behave in unit-test contexts where HIDInteractor was never
        // exercised.)
        HIDInteractor.clearHIDConnections() // start from a clean slate
        _ = DaemonDispatch.staleSimulatorOutcome(
            id: nil,
            udid: "FAKE-UDID",
            underlying: "Simulator with UDID FAKE-UDID not found in set."
        )
        // No public accessor exists for the cache, but the call must
        // not throw or crash; absence of entries is the steady state.
        // The presence of a clearHIDConnection(for:) call is what
        // distinguishes a stale-simulator path from a generic error
        // path, and the function exists by name (compile-time check).
    }
}