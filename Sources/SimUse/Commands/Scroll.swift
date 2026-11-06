// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import HarmonyBackend

/// Phase-one scroll is available on Harmony; other platforms retain their gesture verbs.
struct Scroll: SimUseExecutableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scroll",
        abstract: "Scroll a Harmony device with a directional swipe."
    )

    @Option(help: "Scroll direction: up, down, left or right (default down).")
    var direction: String = "down"

    @Option(help: "Center of the swipe in display pixels (x,y). Defaults to the screen center.")
    var center: CoordinatePair?

    @Option(help: "Swipe distance in display pixels.")
    var distance: Int = 800

    @Option(help: "Duration in seconds (default 0.4); converted to native velocity.")
    var duration: Double = 0.4

    @OptionGroup var device: DeviceOptions
    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }
    var simulatorUDIDForDaemon: String? { device.resolved }
    typealias ExecutionResult = HarmonyScrollCommand.ExecutionResult

    func validate() throws {
        _ = try HarmonyScrollCommand.validateOptions(direction: direction, distance: distance, duration: duration)
    }

    mutating func resolveDeferredArguments() throws {
        try device.resolve(allowPhysical: true)
    }

    func execute() async throws -> ExecutionResult {
        guard try PlatformRouter.resolve(udid: device.resolved) == .harmony else {
            throw CLIError(errorDescription: "`scroll` is Harmony-only; use `gesture scroll-up` / `gesture scroll-down` or `swipe` on iOS and Android.")
        }
        let durationMs = try HarmonyScrollCommand.validateOptions(direction: direction, distance: distance, duration: duration)
        return try HarmonyScrollCommand.performScroll(
            udid: device.resolved, direction: direction, center: center,
            distance: distance, durationMs: durationMs
        )
    }

    func format(_ result: ExecutionResult) -> CommandOutput {
        HarmonyScrollCommand.successOutput(direction: direction)
    }
}
