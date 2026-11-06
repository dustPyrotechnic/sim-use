// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import Testing
@testable import HarmonyBackend
@testable import SimUse

@Suite("Harmony gesture consumer contracts")
struct HarmonyGestureContractTests {
    private static let serial = "TESTHARMONY000001"

    @Test("Both scroll entrypoints default to down and 0.4 seconds with identical success output")
    func scrollDefaultsAndOutput() throws {
        let arguments = ["--device", Self.serial]
        let top = try Scroll.parse(arguments)
        let namespace = try HarmonyScrollCommand.parse(arguments)
        #expect(top.direction == "down")
        #expect(namespace.direction == "down")
        #expect(top.duration == 0.4)
        #expect(namespace.duration == 0.4)
        let result = HarmonyScrollCommand.ExecutionResult(startX: 500, startY: 900, endX: 500, endY: 100)
        #expect(top.format(result) == namespace.format(result))
    }

    @Test("Both scroll entrypoints reject invalid direction, distance, and duration", arguments: [
        ["--direction", "diagonal"], ["--distance", "0"], ["--distance", "-1"],
        ["--distance", "1000001"], ["--duration", "0"], ["--duration", "-0.1"],
        ["--duration", "nan"],
        ["--duration", "inf"], ["--duration", "-inf"], ["--duration", "1e300"],
    ])
    func invalidScrollOptions(options: [String]) {
        let arguments = options + ["--device", Self.serial]
        #expect(throws: (any Error).self) { _ = try Scroll.parse(arguments) }
        #expect(throws: (any Error).self) { _ = try HarmonyScrollCommand.parse(arguments) }
    }

    @Test("Scroll seconds become representable native milliseconds", arguments: [
        ("0.4", 400), ("0.1256", 126), ("0.00001", 1), ("10", 10000), ("400", 400000),
    ])
    func secondsConversion(seconds: String, expectedMilliseconds: Int) throws {
        let arguments = ["--duration", seconds, "--device", Self.serial]
        let top = try Scroll.parse(arguments)
        let namespace = try HarmonyScrollCommand.parse(arguments)
        let topMilliseconds = try HarmonyScrollCommand.validateOptions(
            direction: top.direction, distance: top.distance, duration: top.duration
        )
        let namespaceMilliseconds = try HarmonyScrollCommand.validateOptions(
            direction: namespace.direction, distance: namespace.distance, duration: namespace.duration
        )
        #expect(topMilliseconds == expectedMilliseconds)
        #expect(namespaceMilliseconds == expectedMilliseconds)
        if expectedMilliseconds == 400 {
            // 800 pixels over 0.4 seconds must yield 2000 px/s, not a 400-second gesture.
            #expect(try UITestClient.swipeVelocity(
                startX: 500, startY: 900, endX: 500, endY: 100, durationMs: topMilliseconds
            ) == 2000)
        }
    }


    @Test("Harmony namespace rejects delta while cross-platform parsing retains it")
    func deltaOptions() throws {
        #expect(throws: (any Error).self) {
            _ = try HarmonySwipeCommand.parse(["--from", "100,200", "--to", "300,400", "--delta", "20", "--device", Self.serial])
        }
        #expect(try Swipe.parse(["--from", "100,200", "--to", "300,400", "--delta", "20", "--device", Self.serial]).delta == 20)
    }

    @Test("Top-level Harmony swipe rejects delta before device input")
    @MainActor
    func topLevelDeltaRejection() async throws {
        var probes = 0
        try await withHarmonyRoutingProbe({ serial in
            guard serial == Self.serial else { return false }
            probes += 1
            return true
        }) {
            var command = try Swipe.parse([
                "--from", "100,200", "--to", "300,400", "--delta", "20", "--device", Self.serial, "--json",
            ])
            try command.resolveDeferredArguments()
            do {
                _ = try await command.execute()
                Issue.record("Expected --delta to be rejected before device input")
            } catch {
                #expect(error.localizedDescription == "--delta is not supported on HarmonyOS.")
            }
        }
        #expect(probes == 1)
    }
}
