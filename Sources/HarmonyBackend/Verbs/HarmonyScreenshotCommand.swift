// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import ImageIO
import SimUseCore

public struct HarmonyScreenshotCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(commandName: "screenshot", abstract: "Capture HarmonyOS to PNG or JPEG (snapshot_display with uitest fallback).")
    @OptionGroup public var device: HarmonyDeviceOptions
    @OptionGroup public var json: JSONOutputOptions
    @Option(name: .customLong("output"), help: "PNG/JPEG output path or directory. Defaults to a timestamped PNG.") public var output: String?
    public var jsonOutput: Bool { json.enabled }
    public var simulatorUDIDForDaemon: String? { device.resolved }
    // Preserve caller-relative paths and avoid moving image bytes over the daemon socket.
    public var daemonBypass: Bool { true }
    public init() {}
    public struct ExecutionResult: Codable, Equatable { public let path: String }
    public mutating func resolveDeferredArguments() throws { try device.resolve() }
    public func execute() async throws -> ExecutionResult { try Self.performScreenshot(udid: device.resolved, output: output) }
    public static func performScreenshot(udid: String, output: String?) throws -> ExecutionResult {
        let url = OutputFilePath.resolve(output: output) {
            "Harmony Screenshot - \(OutputFilePath.screenshotTimestamp(Date())).png"
        }
        let suffix = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg"].contains(suffix) else { throw HarmonyError("Harmony screenshot output must have a .png, .jpg, or .jpeg extension.") }
        let capture = try HarmonyDeviceController.shared.client(serial: udid).screenshot()
        let data = try encodedImage(capture, fileExtension: suffix)
        try OutputFilePath.createParentDirectory(for: url)
        try data.write(to: url, options: .atomic)
        return ExecutionResult(path: url.path)
    }
    static func encodedImage(_ capture: UITestClient.Capture, fileExtension: String) throws -> Data {
        let desired = fileExtension == "png" ? "public.png" : "public.jpeg"
        if capture.fileExtension == (fileExtension == "png" ? "png" : "jpeg") { return capture.data }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, desired as CFString, 1, nil) else {
            throw HarmonyError("Could not create screenshot encoder.")
        }
        CGImageDestinationAddImage(destination, capture.image, nil)
        guard CGImageDestinationFinalize(destination) else { throw HarmonyError("Could not encode the Harmony screenshot.") }
        return output as Data
    }
    public func format(_ result: ExecutionResult) -> CommandOutput { .line(result.path) }
}
