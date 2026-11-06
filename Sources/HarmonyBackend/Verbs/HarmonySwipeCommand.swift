// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

public struct HarmonySwipeCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(commandName: "swipe", abstract: "Swipe in HarmonyOS device pixels; duration is converted to native velocity.")
    @OptionGroup public var device: HarmonyDeviceOptions
    @OptionGroup public var coordinates: SwipeCoordinateOptions
    @OptionGroup public var json: JSONOutputOptions
    @Option(name: .customLong("duration"), help: "Swipe duration in seconds (default 0.3).") public var duration: Double = 0.3
    @Option(name: .customLong("coordinate-space"), help: "Harmony coordinates are always device pixels.") public var coordinateSpace: CoordinateSpace = .ui
    @Option(name: .customLong("pre-delay"), help: "Delay before input, in seconds.") public var preDelay: Double?
    @Option(name: .customLong("post-delay"), help: "Delay after input, in seconds.") public var postDelay: Double?
    public var jsonOutput: Bool { json.enabled }
    public var simulatorUDIDForDaemon: String? { device.resolved }
    public var daemonAllowsTransientRetry: Bool { false }
    public init() {}
    public struct ExecutionResult: Codable { public let coordinates: SwipeCoordinates }
    public func validate() throws {
        _ = try coordinates.resolve()
        guard duration.isFinite, duration > 0, duration <= 10 else { throw ValidationError("--duration must be greater than 0 and at most 10 seconds.") }
        for delay in [preDelay, postDelay].compactMap({ $0 }) {
            guard delay.isFinite, (0...10).contains(delay) else { throw ValidationError("Delays must be between 0 and 10 seconds.") }
        }
    }
    public mutating func resolveDeferredArguments() throws { try device.resolve() }
    public func execute() async throws -> ExecutionResult {
        let points = try coordinates.resolve()
        if let preDelay { try await Task.sleep(nanoseconds: UInt64(preDelay * 1_000_000_000)) }
        try Self.performSwipe(udid: device.resolved, startX: points.roundedStartX, startY: points.roundedStartY,
                              endX: points.roundedEndX, endY: points.roundedEndY, durationMs: Int((duration * 1000).rounded()))
        if let postDelay { try await Task.sleep(nanoseconds: UInt64(postDelay * 1_000_000_000)) }
        return ExecutionResult(coordinates: points)
    }
    public static func performSwipe(udid: String, startX: Int, startY: Int, endX: Int, endY: Int, durationMs: Int) throws {
        try HarmonyDeviceController.shared.client(serial: udid).swipe(startX: startX, startY: startY, endX: endX, endY: endY, durationMs: durationMs)
    }
    public func format(_ result: ExecutionResult) -> CommandOutput { .line("✓ Swipe \(result.coordinates.displaySummary) completed successfully") }
}

public struct HarmonyScrollCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(commandName: "scroll", abstract: "Scroll HarmonyOS content in the requested direction.")
    @OptionGroup public var device: HarmonyDeviceOptions
    @OptionGroup public var json: JSONOutputOptions
    @Option(name: .customLong("direction"), help: "Content direction: up, down, left, or right (default down).") public var direction: String = "down"
    @Option(name: .customLong("center"), help: "Gesture center as x,y; defaults to the screen center.") public var center: CoordinatePair?
    @Option(name: .customLong("distance"), help: "Distance in pixels.") public var distance: Int = 800
    @Option(name: .customLong("duration"), help: "Duration in seconds (default 0.4); converted to native velocity.") public var duration: Double = 0.4
    public var jsonOutput: Bool { json.enabled }
    public var simulatorUDIDForDaemon: String? { device.resolved }
    public var daemonAllowsTransientRetry: Bool { false }
    public init() {}
    public struct ExecutionResult: Codable, Equatable {
        public let startX: Int
        public let startY: Int
        public let endX: Int
        public let endY: Int
    }
    public func validate() throws {
        _ = try Self.validateOptions(direction: direction, distance: distance, duration: duration)
    }
    public static func validateOptions(direction: String, distance: Int, duration: Double) throws -> Int {
        guard ["up", "down", "left", "right"].contains(direction) else {
            throw ValidationError("--direction must be up, down, left or right.")
        }
        guard (1...1_000_000).contains(distance) else {
            throw ValidationError("--distance must be between 1 and 1000000 pixels.")
        }
        guard duration.isFinite, duration > 0 else {
            throw ValidationError("--duration must be a finite positive number of seconds.")
        }
        let milliseconds = (duration * 1000).rounded()
        guard milliseconds < Double(Int.max) else {
            throw ValidationError("--duration exceeds the supported millisecond range.")
        }
        return max(1, Int(milliseconds))
    }
    public mutating func resolveDeferredArguments() throws { try device.resolve() }
    public func execute() async throws -> ExecutionResult {
        let durationMs = try Self.validateOptions(direction: direction, distance: distance, duration: duration)
        return try Self.performScroll(udid: device.resolved, direction: direction, center: center, distance: distance, durationMs: durationMs)
    }
    public static func performScroll(udid: String, direction: String, center: CoordinatePair?, distance: Int, durationMs: Int) throws -> ExecutionResult {
        guard ["up", "down", "left", "right"].contains(direction), (1...1_000_000).contains(distance), durationMs > 0 else {
            throw HarmonyError("Scroll requires up/down/left/right, a positive pixel distance, and a positive duration.")
        }
        let point: (x: Int, y: Int)
        if let center { point = try HarmonyTargetResolver.integerPoint(x: center.x, y: center.y) }
        else {
            let screen = try HarmonyDeviceController.shared.describeUI(serial: udid, includeRaw: false).screen
            point = (screen.width / 2, screen.height / 2)
        }
        let half = max(1, distance / 2)
        let result: ExecutionResult
        switch direction {
        case "down": result = .init(startX: point.x, startY: point.y + half, endX: point.x, endY: point.y - half)
        case "up": result = .init(startX: point.x, startY: point.y - half, endX: point.x, endY: point.y + half)
        case "right": result = .init(startX: point.x + half, startY: point.y, endX: point.x - half, endY: point.y)
        default: result = .init(startX: point.x - half, startY: point.y, endX: point.x + half, endY: point.y)
        }
        try HarmonySwipeCommand.performSwipe(udid: udid, startX: result.startX, startY: result.startY,
                                             endX: result.endX, endY: result.endY, durationMs: durationMs)
        return result
    }
    public static func successOutput(direction: String) -> CommandOutput {
        .line("✓ Scroll \(direction) completed successfully")
    }
    public func format(_ result: ExecutionResult) -> CommandOutput { Self.successOutput(direction: direction) }
}
