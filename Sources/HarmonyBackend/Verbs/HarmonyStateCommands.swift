// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

public struct HarmonyTypeCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "type", abstract: "Type into the focused field or a target. Replaces the system pasteboard.",
        discussion: HarmonyTargetResolver.safetyHelp)
    @Argument(help: "Text to input (including Unicode).") public var text: String
    @Option(name: .customLong("target"), help: "Cached @N or #identifier target; use selectors or coordinates for other targets.") public var alias: String?
    @OptionGroup public var targeting: TapTargetingOptions
    @OptionGroup public var device: HarmonyDeviceOptions
    @OptionGroup public var json: JSONOutputOptions
    @Flag(name: .customLong("clear"), help: "Unsupported on Harmony; rejected before input.") public var clear = false
    public var jsonOutput: Bool { json.enabled }
    public var simulatorUDIDForDaemon: String? { device.resolved }
    public var daemonAllowsTransientRetry: Bool { false }
    public init() {}
    public struct ExecutionResult: Codable, CommandAdvisoryProviding {
        public init() {}
        public var commandAdvisory: CommandAdvisory? {
            CommandAdvisory(kind: .pasteboardReplaced,
                            message: "Harmony text input replaces the device's pasteboard. Previous pasteboard content cannot be restored by sim-use.")
        }
    }
    public func validate() throws {
        guard !clear else { throw ValidationError("Harmony does not support --clear.") }
        if HarmonyTargetResolver.hasTarget(alias: alias, targeting: targeting) { try targeting.validate(alias: alias) }
    }
    public mutating func resolveDeferredArguments() throws { try device.resolve() }
    public func execute() async throws -> ExecutionResult {
        try Self.performType(udid: device.resolved, text: text, clear: clear, alias: alias, targeting: targeting)
    }
    @discardableResult
    public static func performType(udid: String, text: String, clear: Bool, alias: String? = nil,
                                   targeting: TapTargetingOptions? = nil,
                                   controller: HarmonyDeviceController = .shared) throws -> ExecutionResult {
        guard !clear else { throw HarmonyError("Harmony does not support --clear; use the app's own clear control first.") }
        guard !text.contains("\0") else { throw HarmonyError("Text cannot contain NUL bytes.") }
        var target: (x: Int, y: Int)?
        let targeting = try targeting ?? TapTargetingOptions.parse([])
        if HarmonyTargetResolver.hasTarget(alias: alias, targeting: targeting) {
            target = try HarmonyTargetResolver.resolve(serial: udid, alias: alias, targeting: targeting, controller: controller)
        }
        try controller.client(serial: udid).type(text: text, target: target)
        return ExecutionResult()
    }
    public func format(_ result: ExecutionResult) -> CommandOutput { .line("✓ Text input completed successfully") }
}

public struct HarmonyButtonCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(commandName: "button", abstract: "Press home, back, or power on HarmonyOS.")
    @Argument(help: "home | back | power") public var button: String
    @OptionGroup public var device: HarmonyDeviceOptions
    @OptionGroup public var json: JSONOutputOptions
    public var jsonOutput: Bool { json.enabled }
    public var simulatorUDIDForDaemon: String? { device.resolved }
    public var daemonAllowsTransientRetry: Bool { false }
    public init() {}
    public struct ExecutionResult: Codable { public init() {} }
    public func validate() throws {
        guard ["home", "back", "power"].contains(button.lowercased()) else { throw ValidationError("Harmony supports home, back, and power only.") }
    }
    public mutating func resolveDeferredArguments() throws { try device.resolve() }
    public func execute() async throws -> ExecutionResult {
        try Self.performPress(udid: device.resolved, button: button)
        return ExecutionResult()
    }
    public static func performPress(udid: String, button: String) throws { try HarmonyDeviceController.shared.client(serial: udid).button(button) }
    public func format(_ result: ExecutionResult) -> CommandOutput { .line("✓ Button \(button) completed successfully") }
}

public struct HarmonyKeyboardStateCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(commandName: "keyboard-state", abstract: "Report soft or hidden; a failed WMS probe is an error, never hidden.")
    @OptionGroup public var device: HarmonyDeviceOptions
    @OptionGroup public var json: JSONOutputOptions
    public var jsonOutput: Bool { json.enabled }
    public var simulatorUDIDForDaemon: String? { device.resolved }
    public init() {}
    public struct ExecutionResult: Codable, Equatable {
        public let platform: String
        public let visible: Bool
        public var mode: String { visible ? "soft" : "hidden" }
        public init(visible: Bool) { platform = "harmony"; self.visible = visible }
    }
    public mutating func resolveDeferredArguments() throws { try device.resolve() }
    public func execute() async throws -> ExecutionResult { try Self.performKeyboardState(udid: device.resolved) }
    public static func performKeyboardState(udid: String) throws -> ExecutionResult {
        try ExecutionResult(visible: HarmonyDeviceController.shared.client(serial: udid).keyboardVisible())
    }
    public func format(_ result: ExecutionResult) -> CommandOutput { .line(result.mode) }
}

public struct HarmonyAppStateCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(commandName: "app-state", abstract: AppStateHelp.abstract)
    @OptionGroup public var device: HarmonyDeviceOptions
    @OptionGroup public var json: JSONOutputOptions
    @Option(name: .customLong("bundle-id"), help: "Query a main app process by bundle identifier.") public var bundleId: String?
    @Flag(name: .customLong("reset"), help: "Reset the daemon's process-liveness baseline.") public var reset = false
    public var jsonOutput: Bool { json.enabled }
    public var simulatorUDIDForDaemon: String? { device.resolved }
    public var managesLivenessState: Bool { true }
    public typealias ExecutionResult = AppStateReport.ExecutionResult
    public init() {}
    public mutating func resolveDeferredArguments() throws { try device.resolve() }
    public func execute() async throws -> ExecutionResult { try Self.performAppState(serial: device.resolved, bundleId: bundleId, reset: reset) }
    public static func performAppState(serial: String, bundleId: String?, reset: Bool) throws -> ExecutionResult {
        let snapshot = try HarmonyDeviceController.shared.appSnapshot(serial: serial)
        if reset { DaemonDispatch.processTracker.reset(to: snapshot, now: Date()) }
        return AppStateReport.buildResult(platform: "harmony", snapshot: snapshot, bundleId: bundleId, didReset: reset)
    }
    public func format(_ result: ExecutionResult) -> CommandOutput { AppStateReport.format(result) }
}
