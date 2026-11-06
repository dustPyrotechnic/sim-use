// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The target backends: iOS Simulator, Android, physical iOS (restricted
/// accessibility audit capabilities), and HarmonyOS.
public enum Platform: String, Codable, Equatable, Sendable {
    case iOSSim
    case android
    case iOSDevice
    case harmony
}

/// Centralises the UDID-shape heuristics used to decide which backend
/// owns a command invocation. Top-level forwarders ask
/// `PlatformRouter.resolve(udid:)` instead of carrying their own
/// `looksLikeAndroid` checks (the pattern that grew to ~17 sites and
/// motivated this module).
///
/// Resolution layers, in priority order:
///   1. Explicit namespace or the daemon's pinned startup platform.
///   2. hdc membership for an Android-shaped explicit identifier (macOS hook).
///   3. Identifier-shape inference, unchanged when no hook is installed.
public enum PlatformRouter {
    /// Installed by the macOS executable only. Missing hdc leaves routing unchanged.
    /// Discovery failure warns once per invocation and preserves Android shape routing.
    nonisolated(unsafe) public static var harmonyMembershipProbe: ((String) throws -> Bool)?

    /// A daemon pins its platform at startup; namespaces can also override shape.
    nonisolated(unsafe) public static var platformOverride: Platform?

    /// Default resolution must not probe hdc for an implicitly selected device.
    nonisolated(unsafe) public static var implicitDevice: String?

    /// Failure suppression belongs to a client invocation, not the membership cache.
    /// Child tasks share it; a later invocation gets a fresh probe opportunity.
    @TaskLocal static var currentInvocation: Invocation?

    public final class Invocation: @unchecked Sendable {
        private let lock = NSLock()
        private var membershipFailed = false
        private let command: String
        private let warning: (String) -> Void

        public init(
            command: String,
            warning: @escaping (String) -> Void = {
                FileHandle.standardError.write(Data(($0 + "\n").utf8))
            }
        ) {
            self.command = command
            self.warning = warning
        }

        fileprivate func contains(_ udid: String, probe: (String) throws -> Bool) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !membershipFailed else { return false }
            do {
                return try probe(udid)
            } catch {
                membershipFailed = true
                warning(
                    "Warning: hdc membership probe failed: \(error.localizedDescription) "
                        + "Continuing with Android routing; for Harmony use `sim-use harmony \(command)`."
                )
                return false
            }
        }
    }

    /// Classify a UDID into a target platform. Returns `nil` when the
    /// shape doesn't fit any known platform; callers can choose to fail
    /// fast or fall back to a default.
    ///
    /// Physical iOS devices listed by ECID (AMDevice publishes the
    /// lockdown UDID lazily) are invisible to shape-based routing — a
    /// bare ECID resolves as `.android` or `nil`, never `.iOSDevice`.
    /// Documented non-goal (#115); the `ios-device` namespace accepts
    /// ECIDs directly.
    public static func resolve(udid: String) throws -> Platform? {
        try resolve(
            udid: udid, harmonyMembershipProbe: harmonyMembershipProbe,
            platformOverride: platformOverride, implicitDevice: implicitDevice,
            invocation: currentInvocation
        )
    }

    /// Injectable classification keeps routing tests independent of host tooling.
    public static func resolve(
        udid: String,
        harmonyMembershipProbe: ((String) throws -> Bool)?,
        platformOverride: Platform? = nil,
        implicitDevice: String? = nil,
        invocation: Invocation? = nil
    ) throws -> Platform? {
        if let platformOverride { return platformOverride }
        let trimmed = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if looksLikeAndroid(trimmed) {
            if trimmed != implicitDevice, let harmonyMembershipProbe,
               (invocation ?? Invocation(command: "<verb>")).contains(trimmed, probe: harmonyMembershipProbe) {
                return .harmony
            }
            return .android
        }
        if looksLikeIOSSim(trimmed) { return .iOSSim }
        if looksLikePhysicalIOSDevice(trimmed) { return .iOSDevice }
        return nil
    }

    /// Decorate only the final client error. A stale daemon includes its original
    /// adb diagnostic, so this also works after shutdown without another probe.
    public static func errorWithHarmonyHint(
        _ error: Error,
        command: String,
        harmonyAvailable: Bool,
        platformOverride: Platform?
    ) -> Error {
        let message = error.localizedDescription
        guard harmonyAvailable, platformOverride == nil, message.contains("' not found"),
              message.contains("adb: device '")
                || message.contains("adb: error: device '")
                || (message.contains("adb command failed (") && message.contains("): error: device '")) else {
            return error
        }
        let addition = "If this is a Harmony device, it is not currently listed by `hdc list targets`; "
            + "check the connection or use `sim-use harmony \(command)` explicitly."
        let originalHint = (error as? HintProviding)?.hint
        return RoutingError(
            errorDescription: message,
            hint: originalHint.map { "\(addition) \($0)" } ?? addition
        )
    }

    private struct RoutingError: LocalizedError, HintProviding {
        let errorDescription: String?
        let hint: String?
    }

    /// `true` when the UDID looks like an iOS Simulator UDID
    /// (8-4-4-4-12 hex, as emitted by `simctl list`).
    public static func looksLikeIOSSim(_ udid: String) -> Bool {
        let pattern = "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
        return udid.range(of: pattern, options: .regularExpression) != nil
    }

    /// `true` when the UDID looks like a physical iOS device identifier:
    /// modern 8-16 hex (`00008130-00066D2A10EB8D3A`, iPhone XS and later)
    /// or legacy 40-hex (iPhone X and earlier). `resolve` maps both
    /// shapes to `.iOSDevice`; the standalone predicate also guards the
    /// Android heuristic (so the modern shape is never misread as an
    /// adb serial) and the daemon-dispatch exclusion (physical targets
    /// run in-process until #120).
    public static func looksLikePhysicalIOSDevice(_ udid: String) -> Bool {
        let trimmed = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        let modern = "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}$"
        let legacy = "^[0-9A-Fa-f]{40}$"
        return trimmed.range(of: modern, options: .regularExpression) != nil
            || trimmed.range(of: legacy, options: .regularExpression) != nil
    }

    /// `true` when the UDID looks like an Android serial.
    ///
    /// Heuristic, in order:
    ///   1. `emulator-…` prefix → always Android.
    ///   2. iOS Simulator or physical iOS device UDID shape → never
    ///      Android. Without the physical exclusion the modern
    ///      8-16-hex device UDID clears rule 3 and a plugged-in iPhone
    ///      is diagnosed as an unreachable adb serial.
    ///   3. ASCII-only, length 4–32, allowed `[A-Za-z0-9._:-]`, with at
    ///      least one digit → Android.
    ///
    /// Rule 3 keeps typos like `--udid foo` (too short) or
    /// `--udid mycoolphone` (no digits) out of the adb path; they fall
    /// through to the iOS resolver, which surfaces a clearer error
    /// faster than waiting 5 s for `adb -s <typo> …` to time out.
    public static func looksLikeAndroid(_ udid: String) -> Bool {
        let trimmed = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed.hasPrefix("emulator-") { return true }
        if looksLikeIOSSim(trimmed) { return false }
        if looksLikePhysicalIOSDevice(trimmed) { return false }
        guard trimmed.count >= 4, trimmed.count <= 32 else { return false }
        let allowed: (Character) -> Bool = { ch in
            ch.isASCII && (
                ch.isLetter || ch.isNumber || ch == "-" || ch == "." || ch == ":" || ch == "_"
            )
        }
        guard trimmed.allSatisfy(allowed) else { return false }
        guard trimmed.contains(where: { $0.isNumber }) else { return false }
        return true
    }
}