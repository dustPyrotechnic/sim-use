// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

public struct HarmonyCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "harmony", abstract: "Control an explicitly selected HarmonyOS device with hdc and uitest.",
        subcommands: [HarmonyDevicesCommand.self, HarmonyDescribeUICommand.self, HarmonyTapCommand.self,
                      HarmonyLongPressCommand.self, HarmonySwipeCommand.self, HarmonyScrollCommand.self,
                      HarmonyTypeCommand.self, HarmonyButtonCommand.self, HarmonyScreenshotCommand.self,
                      HarmonyAppStateCommand.self, HarmonyKeyboardStateCommand.self])
    public init() {}
}

public struct HarmonyDeviceOptions: ParsableArguments {
    @Option(name: .customLong("device"), help: "Explicit hdc target identifier; never selected automatically.")
    public var device: String?
    @Option(name: .customLong("udid"), help: "Deprecated alias for --device.")
    public var udid: String?
    public var resolved = ""
    public init() {}
    public mutating func resolve() throws {
        resolved = try Self.select(device: device, udid: udid)
    }
    public static func select(device: String?, udid: String?,
                              environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        let flag = try DeviceOptions.selectExplicit(device: device, udid: udid)
        let envDevice = environment["SIM_USE_DEVICE"]?.trimmingCharacters(in: .whitespaces)
        let envUDID = environment["SIM_USE_UDID"]?.trimmingCharacters(in: .whitespaces)
        let d = envDevice.flatMap { $0.isEmpty ? nil : $0 }
        let u = envUDID.flatMap { $0.isEmpty ? nil : $0 }
        if flag == nil, d != nil, u != nil { throw DeviceResolver.ResolutionError.conflictingEnvVars }
        guard let explicit = flag ?? d ?? u else {
            throw HarmonyError("Harmony requires --device <hdc-target> or SIM_USE_DEVICE; no implicit target is selected.")
        }
        try Hdc.validateSerial(explicit)
        return explicit
    }
}

public struct HarmonyDevicesCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(commandName: "devices", abstract: "List connected HarmonyOS targets.")
    @OptionGroup public var json: JSONOutputOptions
    public var jsonOutput: Bool { json.enabled }
    public init() {}
    public struct ExecutionResult: Codable {
        public let devices: [Device]
    }
    public func execute() async throws -> ExecutionResult {
        ExecutionResult(devices: try HarmonyDeviceController.shared.listUnifiedDevices())
    }
    public func format(_ result: ExecutionResult) -> CommandOutput {
        .lines(result.devices.isEmpty ? ["No HarmonyOS devices connected."] : result.devices.map { "\($0.udid)  \($0.name)  \($0.state)" })
    }
}

public struct HarmonyDescribeUICommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(commandName: "describe-ui", abstract: "Describe the HarmonyOS UI and cache @N aliases.", aliases: ["ui"])
    @OptionGroup public var device: HarmonyDeviceOptions
    @OptionGroup public var json: JSONOutputOptions
    @Flag(name: .customLong("include-offscreen"), help: "Include hidden, offscreen and keyboard-filtered elements for diagnostics.")
    public var includeOffscreen = false
    @Flag(name: .customLong("no-raw"), help: "Omit the raw layout from JSON output.")
    public var noRaw = false
    public var jsonOutput: Bool { json.enabled }
    public var simulatorUDIDForDaemon: String? { device.resolved }
    public init() {}
    public mutating func resolveDeferredArguments() throws { try device.resolve() }
    public func execute() async throws -> DescribeUIResult {
        try Self.performDescribeUI(udid: device.resolved, includeOffscreen: includeOffscreen, includeRaw: jsonOutput && !noRaw)
    }
    public static func performDescribeUI(udid: String, includeOffscreen: Bool = false, includeRaw: Bool = true) throws -> DescribeUIResult {
        try HarmonyDeviceController.shared.describeUI(serial: udid, options: .init(filterOffscreen: !includeOffscreen), includeRaw: includeRaw)
    }
    public func format(_ result: DescribeUIResult) -> CommandOutput { .line(result.outline) }
}
