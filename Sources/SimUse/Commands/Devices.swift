// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import AndroidBackend
import HarmonyBackend
import iOSSimBackend
import iOSDeviceBackend

/// Cross-platform device listing. Successor to the legacy
/// `list-simulators` (iOS-only) and `android devices` verbs, which
/// remain available for now but redirect users here.
struct Devices: SimUseExecutableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "List iOS Simulators, physical iPhones/iPads, Android and HarmonyOS devices.",
        discussion: """
        Aggregates `xcrun simctl list devices` (iOS Simulators),
        `adb devices` (Android), `hdc list targets` (HarmonyOS) and
        FBDeviceControl discovery (physical iPhones / iPads over USB)
        into a unified table. `kind` distinguishes the carrier — simulator,
        emulator or physical — orthogonally to the platform.

        Default lists only devices sim-use can talk to right now
        (iOS `Booted`, Android/Harmony `device`). Pass `--all` to include
        shutdown sims and offline / unauthorised adb entries — useful
        when picking which simulator to boot.

        A physical iPhone may be listed by ECID rather than UDID until
        a session has opened (AMDevice publishes the lockdown UDID
        lazily); either identifier is accepted by the ios-device verbs.

        Examples:
          sim-use devices                          # currently usable devices, all targets
          sim-use devices --all                    # also include shutdown / offline
          sim-use devices --platform ios           # iOS only (simulators + physical)
          sim-use devices --platform harmony       # HarmonyOS only
          sim-use devices --no-physical-ios        # skip FBDeviceControl discovery entirely
          sim-use devices --json                   # structured output (Viewer, scripts, agents)

        JSON envelope (--json):
          {
            "ok": true,
            "data": {
              "devices": [
                {"deviceId": "...",
                 "name": "...", "platform": "ios|android|harmony",
                 "kind": "simulator|emulator|physical",
                 "state": "Booted|Shutdown|device|offline|...", "runtime": "iOS 18.6|Android|..."},
                ...
              ]
            }
          }
        """
    )

    @Flag(name: .customLong("all"), help: "Include devices that aren't currently usable (iOS Shutdown sims, Android offline / unauthorised devices). Default is booted-only.")
    var includeAll: Bool = false

    @Flag(name: .customLong("no-physical-ios"), help: "Skip physical iPhone/iPad discovery (FBDeviceControl). Saves ~1 s on hosts with no device attached; simulators and Android are unaffected. Used by consumers that need capabilities physical iOS doesn't carry, e.g. the Viewer (coordinate taps, video streaming).")
    var noPhysicalIOS: Bool = false

    @Option(name: .customLong("platform"), help: "Restrict the list to one platform.")
    var platform: Device.Platform?

    @Flag(name: .customLong("json"), help: "Emit a JSON envelope `{ok, data: {devices: [...]}}` instead of the aligned text table.")
    var jsonOutput: Bool = false

    struct ExecutionResult: Codable {
        let devices: [Device]
    }

    func execute() async throws -> ExecutionResult {
        // The simctl and adb queries are cheap (~50–200ms each); the
        // physical-iOS discovery costs ~0.4 s with a device attached and
        // ~1 s when none is (the empty-grace bail). Fire all three in
        // parallel so the combined latency is the slowest side rather
        // than their sum. Errors fall through per side so a missing adb
        // (Android not configured) doesn't kill iOS listing and vice
        // versa.
        async let iosFuture = listIOS()
        async let androidFuture = listAndroid()
        async let physicalFuture = listPhysicalIOS()
        async let harmonyFuture = listHarmony()
        let iosResult = await iosFuture
        let androidResult = await androidFuture
        let physicalResult = await physicalFuture
        let harmonyResult = await harmonyFuture

        var combined: [Device] = []
        if platform == nil || platform == .ios { combined.append(contentsOf: iosResult.devices + physicalResult.devices) }
        if platform == nil || platform == .android { combined.append(contentsOf: androidResult.devices) }
        if platform == nil || platform == .harmony { combined.append(contentsOf: harmonyResult.devices) }

        if !includeAll {
            combined = combined.filter { $0.isUsable }
        }

        // Within a platform, virtual carriers (simulator / emulator)
        // sort before physical hardware — they never coexist on one
        // platform, so a plain "physical last" rank expresses it.
        func kindRank(_ device: Device) -> Int { device.kind == .physical ? 1 : 0 }
        combined.sort { lhs, rhs in
            if lhs.platform != rhs.platform     { return lhs.platform.rawValue < rhs.platform.rawValue }
            if kindRank(lhs) != kindRank(rhs)   { return kindRank(lhs) < kindRank(rhs) }
            if lhs.runtime != rhs.runtime       { return (lhs.runtime ?? "") < (rhs.runtime ?? "") }
            if lhs.name != rhs.name             { return lhs.name < rhs.name }
            return lhs.udid < rhs.udid
        }

        // Unavailable Harmony tooling is optional, not a successful empty
        // listing that should suppress the original backends' failure summary.
        if combined.isEmpty, shouldWarnAllListingsFailed(
            ios: iosResult, android: androidResult, physicalIOS: physicalResult, harmony: harmonyResult
        ) {
            FileHandle.standardError.write(Data(
                "warning: all platform listings failed; pass --platform ios|android|harmony to scope, or install the missing tooling.\n".utf8
            ))
        }
        return ExecutionResult(devices: combined)
    }

    enum SideResult {
        case skipped
        case succeeded([Device])
        case failed

        var devices: [Device] {
            if case .succeeded(let devices) = self { return devices }
            return []
        }
    }

    func shouldWarnAllListingsFailed(
        ios: SideResult, android: SideResult, physicalIOS: SideResult, harmony: SideResult
    ) -> Bool {
        guard platform == nil, case .failed = ios, case .failed = android,
              case .failed = physicalIOS else { return false }
        if case .succeeded = harmony { return false }
        return true
    }

    private func listIOS() async -> SideResult {
        // If --platform=android, skip the simctl call entirely.
        if let platform, platform != .ios { return .skipped }
        do {
            // We always fetch the full list (not `simctl ... booted`)
            // because the `--all` flag changes intent at runtime and
            // the cost of the wider query is small compared to the
            // process spawn itself.
            let devices = try SimctlDeviceLister.listDevices(bootedOnly: false)
            return .succeeded(devices)
        } catch {
            FileHandle.standardError.write(Data("warning: iOS device listing failed: \(error.localizedDescription)\n".utf8))
            return .failed
        }
    }

    private func listAndroid() async -> SideResult {
        if let platform, platform != .android { return .skipped }
        do {
            // adb may simply be unavailable on hosts that don't do
            // Android work; that's not an error worth derailing the
            // iOS listing for.
            let devices = try AndroidDeviceController().listUnifiedDevices()
            return .succeeded(devices)
        } catch {
            FileHandle.standardError.write(Data("warning: Android device listing failed: \(error.localizedDescription)\n".utf8))
            return .failed
        }
    }

    private func listPhysicalIOS() async -> SideResult {
        if (platform != nil && platform != .ios) || noPhysicalIOS { return .skipped }
        do {
            // FBDeviceControl discovery pumps the main run loop until the
            // attachment set quiesces (~0.4 s attached, ~1 s empty-grace
            // bail) — accepted as the cost of physical devices appearing
            // in the one listing everyone runs. Only USB-attached devices
            // are discoverable; paired-but-unplugged ones don't appear.
            let devices = try await DeviceSession.connectedDevices()
            return .succeeded(devices.map(\.unifiedDevice))
        } catch {
            FileHandle.standardError.write(Data("warning: physical iOS device listing failed: \(error.localizedDescription)\n".utf8))
            return .failed
        }
    }

    func listHarmony(
        isAvailable: Bool = Hdc.isAvailable,
        listDevices: () throws -> [Device] = { try HarmonyDeviceController.shared.listUnifiedDevices() }
    ) async -> SideResult {
        if let platform, platform != .harmony { return .skipped }
        guard isAvailable else { return .skipped }
        do {
            return .succeeded(try listDevices())
        } catch {
            FileHandle.standardError.write(Data("warning: Harmony device listing failed: \(error.localizedDescription)\n".utf8))
            return .failed
        }
    }

    func format(_ result: ExecutionResult) -> CommandOutput {
        guard !result.devices.isEmpty else {
            return .line("No devices found. Pass --all to include shutdown / offline entries.")
        }
        return .line(renderTable(result.devices))
    }

    /// Column-aligned text table. Computed widths so an emulator serial
    /// (~14 chars) doesn't waste space alongside an iOS UDID (36).
    private func renderTable(_ devices: [Device]) -> String {
        let headers = ["PLATFORM", "KIND", "STATE", "NAME", "UDID", "RUNTIME"]
        let rows: [[String]] = devices.map { d in
            [d.platform.rawValue, d.kind.rawValue, d.state, d.name, d.udid, d.runtime ?? "-"]
        }
        let widths: [Int] = (0..<headers.count).map { col in
            ([headers[col]] + rows.map { $0[col] }).map(\.count).max() ?? 0
        }
        func line(_ cells: [String]) -> String {
            cells.enumerated()
                .map { i, cell in cell.padding(toLength: widths[i], withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
                .trimmingCharacters(in: .whitespaces)
        }
        var out = [line(headers)]
        out.append(contentsOf: rows.map(line))
        return out.joined(separator: "\n")
    }
}

extension Device.Platform: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}