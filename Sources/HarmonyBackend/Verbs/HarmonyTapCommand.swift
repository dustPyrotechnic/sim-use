// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

public enum HarmonyTargetResolver {
    public static let safetyHelp = """
    Harmony target safety: cached @N and #N targets read a current layout only
    to check keyboard occlusion and screen bounds, not general alias freshness.
    This does not prove the target is still in its original place. Always run
    ui again after page changes. An old keyboard alias after keyboard dismissal
    or a hidden diagnostic alias may still input at an uncovered cached point.
    Covered App targets, unusable cached sizes and failed dumps are rejected.
    Matching current keyboard controls remain usable; cached coordinates and
    alias numbering are not refreshed. Selectors and aliases must resolve to
    an on-screen input point; scroll and re-run describe-ui if it is outside.
    Explicit --x/--y and --point coordinates bypass these layout checks.
    """

    public static func hasTarget(alias: String?, targeting: TapTargetingOptions) -> Bool {
        alias != nil || targeting.hasExplicitCoordinates || targeting.elementID != nil
            || targeting.elementLabel != nil || targeting.elementValue != nil || targeting.labelContains != nil
            || targeting.labelRegex != nil || targeting.elementType != nil || !targeting.frameSpecs.isEmpty
    }

    public static func resolve(serial: String, alias: String?, targeting: TapTargetingOptions,
                               controller: HarmonyDeviceController = .shared) throws -> (x: Int, y: Int) {
        try targeting.validate(alias: alias)
        if let point = try TapCoordinateResolver.resolve(x: targeting.pointX, y: targeting.pointY, point: targeting.point) {
            return try integerPoint(x: point.x, y: point.y)
        }
        var id = targeting.elementID
        if let alias {
            guard let parsed = OutlineAliasResolver.parse(alias) else { throw HarmonyError("Malformed Harmony target alias: \(alias)") }
            switch parsed {
            case .id(let value): id = value
            case .at, .list:
                let cached = try OutlineAliasResolver.resolveWithPayload(alias, udid: serial, home: controller.cacheHome)
                guard cached.entry.w > 0, cached.entry.h > 0 else {
                    throw HarmonyError("The cached Harmony target has no usable size.",
                                       hint: "Run describe-ui again and choose a target with positive width and height before input.")
                }
                let point = try elementPoint(x: cached.resolved.point.x, y: cached.resolved.point.y)
                let roots = try HarmonyLayoutNode.decode(controller.client(serial: serial).dumpLayout())
                try HarmonyOutlineRenderer.validateCachedTarget(cached.entry, point: point, roots: roots)
                return point
            }
        }
        let roots = try HarmonyLayoutNode.decode(controller.client(serial: serial).dumpLayout())
        let outline = try HarmonyOutlineRenderer.render(roots: roots)
        let entry: Outline.Entry
        do {
            entry = try match(entries: outline.entries, screen: outline.screen, id: id,
                              label: targeting.elementLabel, value: targeting.elementValue,
                              labelContains: targeting.labelContains, labelRegex: targeting.labelRegex,
                              elementType: targeting.elementType, frameSpecs: targeting.frameSpecs)
        } catch {
            // Preserve selector-error caching; target safety failures must not replace aliases.
            controller.cacheOutline(outline, serial: serial)
            throw error
        }
        let point = try elementPoint(x: Double(entry.frame.x) + Double(entry.frame.width) / 2,
                                    y: Double(entry.frame.y) + Double(entry.frame.height) / 2)
        try HarmonyOutlineRenderer.validateTargetPoint(point, screen: outline.screen)
        controller.cacheOutline(outline, serial: serial)
        return point
    }

    private static func elementPoint(x: Double, y: Double) throws -> (x: Int, y: Int) {
        guard x >= 0, y >= 0 else {
            throw HarmonyError("Harmony target point is outside the screen.",
                               hint: HarmonyOutlineRenderer.offscreenTargetHint)
        }
        return try integerPoint(x: x, y: y)
    }

    static func integerPoint(x: Double, y: Double) throws -> (x: Int, y: Int) {
        guard x.isFinite, y.isFinite, (0...1_000_000).contains(x), (0...1_000_000).contains(y) else {
            throw HarmonyError("Harmony target coordinates must be finite, non-negative device pixels.")
        }
        return (Int(x.rounded()), Int(y.rounded()))
    }

    public static func match(entries: [Outline.Entry], screen: Outline.Frame, id: String? = nil,
                             label: String? = nil, value: String? = nil, labelContains: String? = nil,
                             labelRegex: String? = nil, elementType: String? = nil,
                             frameSpecs: [String] = []) throws -> Outline.Entry {
        var matches = entries.filter { $0.frame.width > 0 && $0.frame.height > 0 && !$0.states.contains("disabled") }
        if let id { matches = matches.filter { $0.uniqueId == id || $0.resourceId == id } }
        if let label { matches = SelectorTextMatcher.filterEquals(matches, query: label, text: { $0.label }) }
        if let value { matches = SelectorTextMatcher.filterEquals(matches, query: value, text: { $0.value }) }
        if let labelContains { matches = SelectorTextMatcher.filterContains(matches, needle: labelContains, text: { $0.label }) }
        if let labelRegex {
            let regex = try NSRegularExpression(pattern: labelRegex)
            matches = matches.filter { regex.firstMatch(in: $0.label, range: NSRange($0.label.startIndex..<$0.label.endIndex, in: $0.label)) != nil }
        }
        if let elementType {
            guard ElementVocabulary.canonicalNames.contains(elementType) else { throw HarmonyError("Unknown element type: \(elementType)") }
            matches = matches.filter { $0.role == elementType }
        }
        if !frameSpecs.isEmpty {
            let filter = try SelectorFrameFilter(specs: frameSpecs).resolved(screen: screen)
            matches = matches.filter { filter.contains($0.frame) }
        }
        if matches.isEmpty {
            throw HarmonyError("No Harmony element matches the selector.",
                               hint: "Run describe-ui again for the current screen, then check the selector or use a fresh @N alias.")
        }
        guard matches.count == 1, let match = matches.first else {
            throw HarmonyError("Harmony selector matches \(matches.count) elements. Use @N, --id, --element-type, or --frame to disambiguate.")
        }
        return match
    }
}

public struct HarmonyTapCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tap", abstract: "Tap HarmonyOS coordinates, a cached @N alias, or a selector.",
        discussion: HarmonyTargetResolver.safetyHelp)
    @Argument(help: "Alias from describe-ui: @N, #N, or #identifier.") public var alias: String?
    @OptionGroup public var targeting: TapTargetingOptions
    @OptionGroup public var device: HarmonyDeviceOptions
    @OptionGroup public var json: JSONOutputOptions
    @Option(name: .customLong("duration"), help: "Harmony only accepts 0; use long-press for a native hold.") public var duration: Double?
    public var jsonOutput: Bool { json.enabled }
    public var simulatorUDIDForDaemon: String? { device.resolved }
    public var daemonAllowsTransientRetry: Bool { false }
    public init() {}
    public struct ExecutionResult: Codable, Equatable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }
    public func validate() throws {
        try targeting.validate(alias: alias)
        try Self.validateDuration(duration)
    }
    static func validateDuration(_ duration: Double?) throws {
        guard duration == nil || duration == 0 else { throw HarmonyError("Harmony tap does not support --duration. Use long-press for a native long click.") }
    }
    public mutating func resolveDeferredArguments() throws { try device.resolve() }
    public func execute() async throws -> ExecutionResult {
        try Self.performTap(serial: device.resolved, alias: alias, targeting: targeting, duration: duration)
    }
    public static func performTap(serial: String, alias: String?, targeting: TapTargetingOptions,
                                  duration: Double? = nil, multiTouch: MultiTouchOptions? = nil,
                                  controller: HarmonyDeviceController = .shared) throws -> ExecutionResult {
        try validateDuration(duration)
        if let multiTouch, multiTouch.fingers != 1 { throw HarmonyError("Harmony does not support multi-touch in phase 1.") }
        let point = try HarmonyTargetResolver.resolve(serial: serial, alias: alias, targeting: targeting, controller: controller)
        try controller.client(serial: serial).tap(x: point.x, y: point.y)
        return ExecutionResult(x: Double(point.x), y: Double(point.y))
    }
    public func format(_ result: ExecutionResult) -> CommandOutput { .line("✓ Tap at (\(result.x), \(result.y)) completed successfully") }
}

public struct HarmonyLongPressCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "long-press", abstract: "Perform a native HarmonyOS long click (fixed system hold duration).",
        discussion: HarmonyTargetResolver.safetyHelp)
    @Argument(help: "Alias from describe-ui.") public var alias: String?
    @OptionGroup public var targeting: TapTargetingOptions
    @OptionGroup public var device: HarmonyDeviceOptions
    @OptionGroup public var json: JSONOutputOptions
    public typealias ExecutionResult = HarmonyTapCommand.ExecutionResult
    public var jsonOutput: Bool { json.enabled }
    public var simulatorUDIDForDaemon: String? { device.resolved }
    public var daemonAllowsTransientRetry: Bool { false }
    public init() {}
    public func validate() throws { try targeting.validate(alias: alias) }
    public mutating func resolveDeferredArguments() throws { try device.resolve() }
    public func execute() async throws -> ExecutionResult {
        try Self.performLongPress(serial: device.resolved, alias: alias, targeting: targeting, duration: 0.8)
    }
    public static func performLongPress(serial: String, alias: String?, targeting: TapTargetingOptions,
                                        duration: Double, multiTouch: MultiTouchOptions? = nil,
                                        controller: HarmonyDeviceController = .shared) throws -> ExecutionResult {
        guard duration == 0.8 else { throw HarmonyError("Harmony long-press uses the system's fixed hold duration; custom --duration is unsupported.") }
        if let multiTouch, multiTouch.fingers != 1 { throw HarmonyError("Harmony does not support multi-touch in phase 1.") }
        let point = try HarmonyTargetResolver.resolve(serial: serial, alias: alias, targeting: targeting, controller: controller)
        try controller.client(serial: serial).tap(x: point.x, y: point.y, longPress: true)
        return ExecutionResult(x: Double(point.x), y: Double(point.y))
    }
    public func format(_ result: ExecutionResult) -> CommandOutput { .line("✓ Long-press at (\(result.x), \(result.y)) completed successfully") }
}
