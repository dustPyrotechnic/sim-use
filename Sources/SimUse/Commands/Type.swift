// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import AndroidBackend
import HarmonyBackend
import iOSSimBackend

/// Top-level cross-platform `type` verb. Owns the flag surface and
/// resolves the target platform, then delegates to the per-backend
/// command (`IOSSimTypeCommand` for iOS Simulator UDIDs,
/// `AndroidTypeCommand.performType` for adb serials).
///
/// Android dispatch defaults to `clear: false` (append at caret) so
/// it matches iOS HID's natural append behaviour. Callers wanting
/// replace-mode on Android should use `sim-use android type --clear`
/// directly.
struct Type: SimUseExecutableCommand {
    struct ExecutionResult: Codable, CommandAdvisoryProviding {
        var commandAdvisory: CommandAdvisory? = nil

        init(commandAdvisory: CommandAdvisory? = nil) {
            self.commandAdvisory = commandAdvisory
        }

        init(from decoder: Decoder) throws {}
        func encode(to encoder: Encoder) throws {
            _ = encoder.container(keyedBy: CodingKeys.self)
        }
        private enum CodingKeys: String, CodingKey { case unused }
    }

    static let configuration = CommandConfiguration(
        abstract: "Type text by entering a sequence of characters.",
        discussion: """
        Input Methods:
        1. Direct text: sim-use type "Hello World" --udid UDID
        2. From stdin: echo "Hello World!" | sim-use type --stdin --udid UDID
        3. From file: sim-use type --file text.txt --udid UDID

        Examples:
        • Simple text: sim-use type "Hello World" --udid UDID
        • With spaces: sim-use type "Hello, how are you?" --udid UDID
        • Special characters: sim-use type 'Hello!' --udid UDID

        Shell Escaping Tips:
        • Use double quotes for text with spaces: "Hello World"
        • Use single quotes for text with special characters: 'Hello!'
        • For complex text or automation, prefer --stdin or --file methods

        Character Support:
        • Only US keyboard characters are supported via HID keycodes
        • Supported: A-Z, a-z, 0-9, and symbols: !@#$%^&*()_+-={}[]|\\:";'<>?,./`~
        • Not supported: International characters (£€¥), accented letters (éñü), etc.
        • This is a limitation of the underlying HID keyboard protocol

        Note: iOS may apply smart punctuation spacing to some characters.

        \(HarmonyTargetResolver.safetyHelp)
        """
    )

    @Argument(help: "The text to type. Use quotes for text with spaces or special characters.")
    var text: String?

    @Flag(name: .customLong("stdin"), help: "Read text from standard input.")
    var useStdin: Bool = false

    @Option(name: .customLong("file"), help: "Read text from the specified file.")
    var inputFile: String?

    @Option(name: .customLong("target"), help: "Harmony-only target alias (for example @3); otherwise type into the focused field.")
    var target: String?

    @OptionGroup var targeting: TapTargetingOptions

    private var hasTarget: Bool {
        target != nil || targeting.hasExplicitCoordinates || targeting.elementID != nil
            || targeting.elementLabel != nil || targeting.elementValue != nil
            || targeting.labelContains != nil || targeting.labelRegex != nil
            || targeting.elementType != nil || !targeting.frameSpecs.isEmpty
            || targeting.coordinateSpace != nil
    }

    @OptionGroup var device: DeviceOptions

    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }

    mutating func resolveDeferredArguments() throws {
        try device.resolve(allowPhysical: true)
    }

    var simulatorUDIDForDaemon: String? { device.resolved }

    func daemonArguments(from arguments: [String]) throws -> [String] {
        try IOSSimTypeCommand.daemonArguments(from: arguments, useStdin: useStdin, inputFile: inputFile)
    }

    func format(_ result: ExecutionResult) -> CommandOutput { .empty }

    func validate() throws {
        try IOSSimTypeCommand.validateOptions(text: text, useStdin: useStdin, inputFile: inputFile)
        if hasTarget { try targeting.validate(alias: target) }
    }

    func execute() async throws -> ExecutionResult {
        let platform = try PlatformRouter.resolve(udid: device.resolved)
        if hasTarget, platform != .harmony {
            throw CLIError(errorDescription: "Targeted `type` is Harmony-only; focus the field with `tap` first on iOS and Android.")
        }
        switch platform {
        case .harmony:
            let result = try HarmonyTypeCommand.performType(
                udid: device.resolved, text: resolvedInputText(), clear: false,
                alias: target, targeting: hasTarget ? targeting : nil
            )
            return ExecutionResult(commandAdvisory: result.commandAdvisory)
        case .android:
            return try executeAndroid()
        case .iOSDevice:
            throw TargetCapabilityError.physicalIOS(
                verb: "type",
                reason: "the accessibility audit channel exposes no keyboard or text-input access.",
                alternative: "Text input on physical iOS devices is not available yet. If the step only needs an activation, use `sim-use tap '#<id>' / --label`."
            )
        case .iOSSim, .none:
            return try await executeIOSSim()
        }
    }

    private func executeIOSSim() async throws -> ExecutionResult {
        let sub = makeIOSSubcommand()
        _ = try await sub.execute()
        return ExecutionResult()
    }

    /// Construct the backend command and copy every parsed flag across.
    /// A missed field stays in ArgumentParser's wrapper-definition state
    /// and traps on first read (#42) — pinned by
    /// `ForwarderInitializationGuardTests`.
    func makeIOSSubcommand() -> IOSSimTypeCommand {
        var sub = IOSSimTypeCommand()
        sub.text = text
        sub.useStdin = useStdin
        sub.inputFile = inputFile
        sub.device = device
        sub.json = json
        return sub
    }

    private func resolvedInputText() throws -> String {
        let inputText: String
        switch (text, useStdin, inputFile) {
        case (let positional?, false, nil):
            inputText = positional
        case (nil, true, nil):
            inputText = IOSSimTypeCommand.readFromStdin()
        case (nil, false, let file?):
            inputText = try IOSSimTypeCommand.readFromFile(file)
        case (nil, false, nil):
            throw ValidationError("No input provided. Provide text as argument, or use --stdin, or --file.")
        default:
            throw ValidationError("Invalid input configuration.")
        }
        return inputText
    }

    private func executeAndroid() throws -> ExecutionResult {
        try AndroidTypeCommand.performType(udid: device.resolved, text: resolvedInputText(), clear: false)
        return ExecutionResult()
    }
}