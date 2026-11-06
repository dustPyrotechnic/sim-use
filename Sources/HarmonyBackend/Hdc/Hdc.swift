// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import SimUseCore

public struct HarmonyError: LocalizedError, HintProviding {
    public let message: String
    public let hint: String?
    public init(
        _ message: String,
        hint: String = "Check hdc connectivity and the explicit --device identifier. No device settings are changed automatically."
    ) {
        self.message = message
        self.hint = hint
    }
    public var errorDescription: String? { message }
}

/// hdc configuration is immutable; only membership discovery is cached, never liveness.
public struct Hdc: Sendable {
    public let binaryPath: String
    public let defaultTimeout: TimeInterval
    public let environment: [String: String]

    public init(binaryPath: String? = nil, defaultTimeout: TimeInterval = 30,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.binaryPath = binaryPath ?? Self.discover(environment: environment)
        self.defaultTimeout = defaultTimeout
        self.environment = environment
    }

    public static func discover(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["SIM_USE_HDC"], !override.isEmpty { return override }
        let candidates = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/hdc" } + [
            "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc",
            "/Applications/DevEco-Studio.app/Contents/sdk/default/harmonyos/toolchains/hdc",
            "\(environment["HOME"] ?? "")/Library/OpenHarmony/Sdk/toolchains/hdc",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "hdc"
    }

    public static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: discover()) }

    public static func connectionIdentity(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let address = environment["OHOS_HDC_SERVER_PORT"].flatMap { $0.isEmpty ? nil : $0 } ?? "8710"
        return "hdc:\(address)"
    }

    private static let cacheLock = NSLock()
    private static let membershipTimeout: TimeInterval = 3
    nonisolated(unsafe) private static var membership: [String: Set<String>] = [:]

    public static func isKnownTarget(_ serial: String) throws -> Bool {
        try isKnownTarget(serial, using: Hdc())
    }

    static func isKnownTarget(_ serial: String, using hdc: Hdc) throws -> Bool {
        try isKnownTarget(serial, using: hdc) { try hdc.listTargets(timeout: $0) }
    }

    static func isKnownTarget(
        _ serial: String, using hdc: Hdc, listTargets: (TimeInterval) throws -> [String]
    ) throws -> Bool {
        let key = hdc.binaryPath + "|" + connectionIdentity(environment: hdc.environment)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = membership[key] { return cached.contains(serial) }
        let targets = Set(try listTargets(membershipTimeout))
        membership[key] = targets
        return targets.contains(serial)
    }

    public func listTargets(timeout: TimeInterval? = nil) throws -> [String] {
        try Self.parseTargets(run(args: ["list", "targets"], timeout: timeout).stdout)
    }

    public static func parseTargets(_ output: String) throws -> [String] {
        var targets: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty || value == "[Empty]" { continue }
            guard !value.contains(where: \.isWhitespace), !value.hasPrefix("["), !value.hasPrefix("-") else {
                throw HarmonyError("Unrecognized hdc target-list output: \(value)")
            }
            targets.append(value)
        }
        return targets
    }

    public struct RunResult: Equatable, Sendable {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
        public init(stdout: String, stderr: String = "", exitCode: Int32 = 0) {
            self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode
        }
    }

    /// POSIX single-quoting is required: hdc joins shell arguments before remote execution.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func validateSerial(_ serial: String) throws {
        guard !serial.isEmpty, !serial.hasPrefix("-"), !serial.contains(where: { $0.isWhitespace || $0 == "\0" }) else {
            throw HarmonyError("Invalid Harmony device identifier.")
        }
    }

    @discardableResult
    public func shell(serial: String, args: [String]) throws -> RunResult {
        try Self.validateSerial(serial)
        guard !args.isEmpty, !args.contains(where: { $0.contains("\0") }) else {
            throw HarmonyError("Shell arguments cannot be empty or contain NUL bytes.")
        }
        let marker = "SIM_USE_EXIT_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let command = args.map(Self.shellQuote).joined(separator: " ")
            + "; sim_use_status=$?; printf '\\n\(marker):%s\\n' \"$sim_use_status\""
        let result = try run(args: ["-t", serial, "shell", command])
        return try Self.decodeShellResult(result, marker: marker)
    }

    static func decodeShellResult(_ result: RunResult, marker: String) throws -> RunResult {
        let lines = result.stdout.components(separatedBy: "\n")
        guard let index = lines.lastIndex(where: { $0.hasPrefix(marker + ":") }),
              let code = Int32(lines[index].dropFirst(marker.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)),
              lines.dropFirst(index + 1).allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw HarmonyError("hdc did not return a remote shell exit status; the connection may have failed.")
        }
        let stdout = lines[..<index].joined(separator: "\n")
        guard code == 0 else { throw HarmonyError("Harmony shell failed (\(code)): \(stdout) \(result.stderr)") }
        return RunResult(stdout: stdout, stderr: result.stderr)
    }

    static func reportsFailure(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            let lower = line.trimmingCharacters(in: .whitespaces).lowercased()
            return lower.hasPrefix("[fail]") || lower.hasPrefix("[error]") || lower.hasPrefix("error:")
                || lower.hasPrefix("error code:") || lower.hasPrefix("fail:")
                || lower.hasPrefix("failed to ") || lower.hasPrefix("missing parameter")
                || lower.hasPrefix("unknown command") || lower.hasPrefix("invalid argument")
        }
    }

    /// File-backed capture cannot deadlock on full pipes or descendant-inherited pipe FDs.
    @discardableResult
    public func run(args: [String], timeout: TimeInterval? = nil) throws -> RunResult {
        guard !args.contains(where: { $0.contains("\0") }) else { throw HarmonyError("hdc arguments contain NUL bytes.") }
        let deadline = timeout ?? defaultTimeout
        guard deadline.isFinite, deadline > 0 else { throw HarmonyError("hdc timeout must be finite and positive.") }
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw HarmonyError("hdc was not found. Set SIM_USE_HDC or install the DevEco command-line tools.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sim-use-hdc-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outURL = directory.appendingPathComponent("stdout")
        let errURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let out = try FileHandle(forWritingTo: outURL)
        let err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.environment = environment
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + deadline) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 0.25) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            throw HarmonyError("hdc timed out after \(deadline) seconds.")
        }
        let stdout = String(decoding: try Data(contentsOf: outURL), as: UTF8.self)
        let stderr = String(decoding: try Data(contentsOf: errURL), as: UTF8.self)
        guard process.terminationStatus == 0, !Self.reportsFailure(stdout), !Self.reportsFailure(stderr) else {
            throw HarmonyError("hdc failed (\(process.terminationStatus)): \(stderr.isEmpty ? stdout : stderr)")
        }
        return RunResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }
}
