// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
import ArgumentParser
import Foundation
import HarmonyBackend
@testable import SimUseCore
import Testing

@Suite("Harmony explicit routing")
struct HarmonyRoutingTests {
    private static let serial = "TESTHARMONY000001"

    @Test("hdc membership wins over Android serial shape")
    func membership() throws {
        var probes = 0
        let result = try PlatformRouter.resolve(udid: Self.serial, harmonyMembershipProbe: {
            probes += 1
            return $0 == Self.serial
        })
        #expect(result == .harmony)
        #expect(probes == 1)
    }

    @Test("adb-only serial retains Android routing")
    func adbOnly() throws {
        #expect(try PlatformRouter.resolve(udid: "emulator-5554", harmonyMembershipProbe: { $0 == Self.serial }) == .android)
    }

    @Test("No hook, including Linux and unavailable hdc, preserves old routing")
    func noHook() throws {
        #expect(try PlatformRouter.resolve(udid: Self.serial, harmonyMembershipProbe: nil) == .android)
        #expect(try PlatformRouter.resolve(udid: "emulator-5554", harmonyMembershipProbe: nil) == .android)
    }

    private enum ProbeFailure: String, LocalizedError {
        case failed = "hdc failed (7): discovery unavailable"
        case zeroExitFailure = "hdc failed (0): [Fail] discovery unavailable"
        case timedOut = "hdc timed out after 3.0 seconds"

        var errorDescription: String? { rawValue }
    }

    @Test("Failed membership preserves Android routing and warns once per invocation")
    func probeFailures() throws {
        for failure in [ProbeFailure.failed, .zeroExitFailure, .timedOut] {
            var probes = 0
            var warnings: [String] = []
            let invocation = PlatformRouter.Invocation(command: "keyboard-state", warning: { warnings.append($0) })
            let probe: (String) throws -> Bool = { _ in
                probes += 1
                throw failure
            }
            for serial in [Self.serial, "emulator-5554", "R5CT1ABCD12"] {
                #expect(try PlatformRouter.resolve(
                    udid: serial, harmonyMembershipProbe: probe, invocation: invocation
                ) == .android)
            }
            #expect(probes == 1)
            #expect(warnings.count == 1)
            #expect(warnings.first?.contains(failure.localizedDescription) == true)
            #expect(warnings.first?.contains("sim-use harmony keyboard-state") == true)
        }
    }

    @Test("A new invocation retries membership after a failed invocation")
    func failedProbeDoesNotPoisonNextInvocation() throws {
        var probes = 0
        let probe: (String) throws -> Bool = { _ in
            probes += 1
            if probes == 1 { throw ProbeFailure.failed }
            return true
        }
        let first = PlatformRouter.Invocation(command: "keyboard-state", warning: { _ in })
        #expect(try PlatformRouter.resolve(udid: Self.serial, harmonyMembershipProbe: probe, invocation: first) == .android)
        #expect(try PlatformRouter.resolve(udid: Self.serial, harmonyMembershipProbe: probe, invocation: first) == .android)
        let second = PlatformRouter.Invocation(command: "keyboard-state", warning: { _ in })
        #expect(try PlatformRouter.resolve(udid: Self.serial, harmonyMembershipProbe: probe, invocation: second) == .harmony)
        #expect(probes == 2)
    }

    @Test("An unavailable hdc hook leaves an Android-shaped target on Android")
    @MainActor
    func unavailableHookForwarding() async throws {
        try await withHarmonyRoutingProbe(nil) {
            var command = try Button.parse(["apple-pay", "--device", Self.serial, "--json"])
            try command.resolveDeferredArguments()
            do {
                _ = try await command.execute()
                Issue.record("Expected the Android capability rejection")
            } catch {
                #expect(error.localizedDescription.contains("not supported on Android"))
                #expect(!error.localizedDescription.contains("Harmony"))
            }
        }
    }

    @Test("Successful empty discovery retains Android routing without a warning", arguments: ["", "[Empty]\n"])
    func emptyDiscovery(output: String) throws {
        let targets = try Hdc.parseTargets(output)
        var warnings: [String] = []
        let invocation = PlatformRouter.Invocation(command: "button", warning: { warnings.append($0) })
        #expect(try PlatformRouter.resolve(
            udid: Self.serial, harmonyMembershipProbe: { targets.contains($0) }, invocation: invocation
        ) == .android)
        #expect(warnings.isEmpty)
    }

    @Test("Failed discovery is shared by daemon platform resolution and command forwarding")
    @MainActor
    func failingProbeForwarding() async throws {
        for failure in [ProbeFailure.failed, .zeroExitFailure, .timedOut] {
            var probes = 0
            var warnings: [String] = []
            try await withHarmonyRoutingProbe({ serial in
                guard serial == Self.serial else { return false }
                probes += 1
                throw failure
            }) {
                let invocation = PlatformRouter.Invocation(command: "button", warning: { warnings.append($0) })
                try await PlatformRouter.$currentInvocation.withValue(invocation) {
                    var command = try Button.parse(["apple-pay", "--device", Self.serial, "--json"])
                    try command.resolveDeferredArguments()
                    #expect(try DaemonClient.platformForInvocation(command: "button", udid: Self.serial) == .android)
                    do {
                        _ = try await command.execute()
                        Issue.record("Expected the Android capability rejection after routing fallback")
                    } catch {
                        #expect(error.localizedDescription.contains("not supported on Android"))
                    }
                }
            }
            #expect(probes == 1)
            #expect(warnings.count == 1)
            #expect(warnings.first?.contains(failure.localizedDescription) == true)
            #expect(warnings.first?.contains("sim-use harmony button") == true)
        }
    }

    @Test("Failed discovery preserves explicit serial, emulator and environment-selected Android routes")
    func selectedAndroidFallback() throws {
        for selection in ["R5CT1ABCD12", "emulator-5554", nil] {
            let serial = try DeviceResolver.resolve(
                explicit: selection, environment: ["SIM_USE_DEVICE": "ENVHARMONY0001"],
                bootedListProvider: { Issue.record("Explicit selection must not enumerate simulators"); return [] },
                daemonListProvider: { Issue.record("Explicit selection must not enumerate daemons"); return [] }
            )
            #expect(serial == (selection ?? "ENVHARMONY0001"))
            var probes: [String] = []
            let invocation = PlatformRouter.Invocation(command: "app-state", warning: { _ in })
            #expect(try PlatformRouter.resolve(
                udid: serial,
                harmonyMembershipProbe: { probes.append($0); throw ProbeFailure.failed },
                invocation: invocation
            ) == .android)
            #expect(probes == [serial])
        }
    }

    private struct FailureEnvelope: Decodable {
        let ok: Bool
        let error: String
        let hint: String?
    }

    @Test("Harmony hint preserves the original error and hint only for top-level hdc-enabled clients")
    func disconnectedHintGates() {
        let original = DaemonClientError.remote(
            message: "adb: device '\(Self.serial)' not found",
            kind: .staleSimulator,
            hint: "Keep the original reconnect advice."
        )
        for (available, override) in [
            (true, nil as Platform?), (false, nil), (true, .android), (true, .harmony),
        ] {
            let decorated = PlatformRouter.errorWithHarmonyHint(
                original, command: "keyboard-state",
                harmonyAvailable: available, platformOverride: override
            )
            #expect(decorated.localizedDescription == original.localizedDescription)
            let hint = (decorated as? HintProviding)?.hint ?? ""
            if available && override == nil {
                #expect(hint.hasSuffix("Keep the original reconnect advice."))
            } else {
                #expect(hint == "Keep the original reconnect advice.")
            }
            #expect(hint.contains("hdc list targets") == (available && override == nil))
            #expect(hint.contains("sim-use harmony keyboard-state") == (available && override == nil))
        }
        let unrelated = CLIError(errorDescription: "adb: device offline")
        let unchanged = PlatformRouter.errorWithHarmonyHint(
            unrelated, command: "keyboard-state", harmonyAvailable: true, platformOverride: nil
        )
        #expect(unchanged.localizedDescription == unrelated.localizedDescription)
        #expect((unchanged as? HintProviding)?.hint == nil)
    }

    @Test("Harmony hint recognizes adb device diagnostics without treating missing tools as devices", arguments: [
        ("adb: device 'TEST0001' not found", true),
        ("adb: error: device 'TEST0001' not found", true),
        ("adb command failed (-s TEST0001 forward tcp:0 tcp:8765, exit 1): error: device 'TEST0001' not found", true),
        ("adb: command not found", false),
        ("adb is not on PATH", false),
        ("adb command failed (-s TEST0001 shell uitest, exit 127): /bin/sh: uitest: not found", false),
        ("error: device 'TEST0001' not found", false),
        ("hdc failed (1): device 'TEST0001' not found", false),
        ("adb: device 'TEST0001' offline", false),
    ])
    func disconnectedHintDiagnostics(message: String, expectedHint: Bool) {
        let error = CLIError(errorDescription: message)
        let decorated = PlatformRouter.errorWithHarmonyHint(
            error, command: "keyboard-state", harmonyAvailable: true, platformOverride: nil
        )
        #expect(decorated.localizedDescription == message)
        #expect(((decorated as? HintProviding)?.hint != nil) == expectedHint)
    }

    @Test("Client Harmony hint survives the daemon stale-device shutdown envelope")
    @MainActor
    func daemonStaleHint() async throws {
        try await withHarmonyRoutingProbe(nil) {
            let outcome = DaemonDispatch.staleSimulatorOutcome(
                id: "routing-test", udid: Self.serial,
                underlying: "adb: device '\(Self.serial)' not found"
            )
            #expect(outcome.shouldStopDaemon)
            let envelope = try JSONDecoder().decode(FailureEnvelope.self, from: outcome.responseData)
            #expect(!envelope.ok)
            let original = DaemonClientError.remote(message: envelope.error, kind: .staleSimulator, hint: envelope.hint)
            let decorated = PlatformRouter.errorWithHarmonyHint(
                original, command: "keyboard-state", harmonyAvailable: true, platformOverride: nil
            )
            #expect(decorated.localizedDescription == envelope.error)
            let hint = (decorated as? HintProviding)?.hint ?? ""
            let originalHint = try #require(envelope.hint)
            #expect(hint.hasSuffix(originalHint))
            #expect(hint.contains("adb devices"))
            #expect(hint.contains("sim-use daemon stop"))
            #expect(hint.contains("hdc list targets"))
            #expect(hint.contains("sim-use harmony keyboard-state"))
        }
    }

    @Test("Only Android-shaped explicit identifiers reach the membership probe")
    func shapeGate() throws {
        var probes = 0
        let probe: (String) -> Bool = { _ in probes += 1; return true }
        #expect(try PlatformRouter.resolve(udid: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", harmonyMembershipProbe: probe) == .iOSSim)
        #expect(try PlatformRouter.resolve(udid: "00008130-00066D2A10EB8D3A", harmonyMembershipProbe: probe) == .iOSDevice)
        #expect(try PlatformRouter.resolve(udid: "", harmonyMembershipProbe: probe) == nil)
        #expect(try PlatformRouter.resolve(udid: "typo", harmonyMembershipProbe: probe) == nil)
        #expect(probes == 0)
    }

    @Test("Implicit Android daemon routing never probes hdc")
    func implicitFastPath() throws {
        var probes = 0
        let result = try PlatformRouter.resolve(
            udid: "emulator-5554",
            harmonyMembershipProbe: { _ in probes += 1; throw ProbeFailure.failed },
            implicitDevice: "emulator-5554"
        )
        #expect(result == .android)
        #expect(probes == 0)
    }

    @Test("Namespace and daemon platform pins bypass membership and shape")
    func explicitNamespace() throws {
        var probes = 0
        for platform in [Platform.harmony, .android, .iOSSim, .iOSDevice] {
            #expect(try PlatformRouter.resolve(
                udid: Self.serial,
                harmonyMembershipProbe: { _ in probes += 1; throw ProbeFailure.failed },
                platformOverride: platform
            ) == platform)
        }
        #expect(probes == 0)
        #expect(try DaemonClient.platformForInvocation(command: "harmony", udid: Self.serial) == .harmony)
        #expect(try DaemonClient.platformForInvocation(command: "android", udid: Self.serial) == .android)
        #expect(DaemonClient.daemonArguments(udid: Self.serial, platform: .harmony) == [
            "daemon", "start", "--udid", Self.serial, "--platform", "harmony",
        ])
    }

    @Test("hdc server identity restarts mismatched daemons and rejects mismatched requests")
    @MainActor
    func connectionIdentity() throws {
        let standard = Hdc.connectionIdentity(environment: [:])
        let other = Hdc.connectionIdentity(environment: ["OHOS_HDC_SERVER_PORT": "9876"])
        #expect(standard == Hdc.connectionIdentity(environment: ["OHOS_HDC_SERVER_PORT": "8710"]))
        #expect(standard != other)
        #expect(!DaemonClient.shouldRestartForConnection(daemon: standard, current: standard))
        #expect(DaemonClient.shouldRestartForConnection(daemon: standard, current: other))
        #expect(DaemonClient.shouldRestartForConnection(daemon: nil, current: standard))
        #expect(DaemonClient.shouldRestartForConnection(daemon: "adb:legacy", current: standard))
        let snapshot = DaemonDispatch.Snapshot(pid: 123, startTime: Date(), udid: Self.serial, simUseVersion: "test", connectionIdentity: standard)
        #expect(DaemonDispatch.connectionMismatchOutcome(.init(cmd: "harmony", connectionIdentity: standard), snapshot: snapshot) == nil)
        #expect(DaemonDispatch.connectionMismatchOutcome(.init(cmd: "harmony", connectionIdentity: other), snapshot: snapshot) != nil)
    }

    @Test("Harmony device schema uses physical kind and online state")
    func deviceSchema() throws {
        let data = Data(#"{"deviceId":"TESTHARMONY000001","name":"Harmony","platform":"harmony","state":"device"}"#.utf8)
        let device = try JSONDecoder().decode(Device.self, from: data)
        #expect(device.kind == .physical)
        #expect(device.isUsable)
    }

    @Test("Top-level unsupported verbs reject Harmony rather than invoking another backend", arguments: [
        "paste hello", "gesture scroll-up", "touch -x 1 -y 2 --down", "record-video", "stream-video",
        "multi-touch --x1 1 --y1 1 --x2 2 --y2 2 --x1-end 3 --y1-end 3 --x2-end 4 --y2-end 4",
    ])
    @MainActor
    func unsupportedVerbs(invocation: String) async throws {
        try await withHarmonyRoutingProbe({ $0 == Self.serial }) {
            // Streaming owns stdout and rejects --json during parsing.
            let outputFlags = invocation == "stream-video" ? [] : ["--json"]
            let arguments = invocation.split(separator: " ").map(String.init)
                + ["--device", Self.serial] + outputFlags
            let parsed = try SimUse.parseAsRoot(arguments)
            var command = try #require(parsed as? any SimUseExecutableCommand)
            try command.resolveDeferredArguments()
            do {
                _ = try await command.execute()
                Issue.record("Expected an unsupported Harmony capability")
            } catch {
                #expect(error.localizedDescription.contains("not supported on Harmony"))
                #expect(!error.localizedDescription.contains("adb"))
            }
        }
    }

    @Test("Top-level power and targeted text parse without changing old button names")
    func phaseOneArguments() throws {
        #expect(try Button.parse(["power", "--device", Self.serial]).buttonName == "power")
        #expect(try Button.parse(["back", "--device", Self.serial]).buttonType == .back)
        #expect(try Type.parse(["hello", "--target", "@2", "--device", Self.serial]).target == "@2")
        #expect(try Scroll.parse(["--direction", "down", "--device", Self.serial]).direction == "down")
        #expect(try Devices.parse(["--platform", "harmony"]).platform == .harmony)
    }
}

/// Share the existing global-hook gate with daemon tests. No subprocess startup
/// participates in routing semantics; real CLI stdout/daemon checks are offline smoke coverage.
/// Global routing callers need not take this gate: probes must ignore foreign
/// serials before accessing captured mutable state.
@MainActor
func withHarmonyRoutingProbe(
    _ probe: ((String) throws -> Bool)?,
    body: () async throws -> Void
) async throws {
    try await withExclusiveCommandParser({ try SimUse.parseAsRoot($0) }) {
        let savedProbe = PlatformRouter.harmonyMembershipProbe
        let savedPlatform = PlatformRouter.platformOverride
        let savedImplicit = PlatformRouter.implicitDevice
        defer {
            PlatformRouter.harmonyMembershipProbe = savedProbe
            PlatformRouter.platformOverride = savedPlatform
            PlatformRouter.implicitDevice = savedImplicit
        }
        PlatformRouter.harmonyMembershipProbe = probe
        PlatformRouter.platformOverride = nil
        PlatformRouter.implicitDevice = nil
        try await body()
    }
}
