// SPDX-License-Identifier: Apache-2.0
import Foundation
import ImageIO
import SimUseCore

public protocol HarmonyTransport {
    func shell(serial: String, args: [String]) throws -> Hdc.RunResult
    func run(args: [String], timeout: TimeInterval?) throws -> Hdc.RunResult
}
extension Hdc: HarmonyTransport {}

public struct UITestClient {
    public let serial: String
    private let transport: any HarmonyTransport

    public init(serial: String, transport: any HarmonyTransport = Hdc()) {
        self.serial = serial
        self.transport = transport
    }

    /// Every artifact has its own name and is removed even if capture, transfer, or decoding fails.
    private func artifact(extension suffix: String, capture: (String) throws -> Void) throws -> Data {
        try Hdc.validateSerial(serial)
        let name = "sim-use-" + UUID().uuidString
        let remote = "/data/local/tmp/\(name).\(suffix)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let local = directory.appendingPathComponent("capture.\(suffix)")
        defer {
            _ = try? transport.shell(serial: serial, args: ["rm", "-f", remote])
            try? FileManager.default.removeItem(at: directory)
        }
        try capture(remote)
        _ = try transport.run(args: ["-t", serial, "file", "recv", remote, local.path], timeout: nil)
        let data = try Data(contentsOf: local)
        guard !data.isEmpty else { throw HarmonyError("hdc returned an empty \(suffix) artifact.") }
        return data
    }

    public func dumpLayout() throws -> Data {
        try artifact(extension: "json") { path in
            try uitest(["dumpLayout", "-i", "-p", path])
        }
    }

    public struct Capture {
        public let data: Data
        public let fileExtension: String
        let image: CGImage
    }

    public func screenshot() throws -> Capture {
        do {
            let data = try artifact(extension: "jpeg") { path in
                let result = try transport.shell(serial: serial, args: ["snapshot_display", "-f", path])
                try Self.validateToolOutput(result.stdout)
            }
            return try Self.capture(data)
        } catch {
            let primary = error
            do {
                let data = try artifact(extension: "png") { path in
                    try uitest(["screenCap", "-p", path])
                }
                return try Self.capture(data)
            } catch {
                throw HarmonyError("Both screenshot methods failed. snapshot_display: \(primary.localizedDescription); uitest screenCap: \(error.localizedDescription)")
            }
        }
    }

    static func capture(_ data: Data) throws -> Capture {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw HarmonyError("Harmony returned an invalid screenshot image.")
        }
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) { return Capture(data: data, fileExtension: "png", image: image) }
        if data.starts(with: [0xff, 0xd8, 0xff]) { return Capture(data: data, fileExtension: "jpeg", image: image) }
        throw HarmonyError("The screenshot response is neither PNG nor JPEG.")
    }

    static func validateToolOutput(_ text: String) throws {
        if Hdc.reportsFailure(text) || text.lowercased().contains("failed:") {
            throw HarmonyError("Harmony device tool failed: \(text)")
        }
    }

    private func uitest(_ args: [String]) throws {
        let output = try transport.shell(serial: serial, args: ["uitest"] + args)
        try Self.validateToolOutput(output.stdout)
    }

    public static func validatePoint(x: Int, y: Int) throws {
        guard (0...1_000_000).contains(x), (0...1_000_000).contains(y) else {
            throw HarmonyError("Harmony coordinates must be non-negative device pixels within 0...1000000.")
        }
    }

    public func tap(x: Int, y: Int, longPress: Bool = false) throws {
        try Self.validatePoint(x: x, y: y)
        try uitest(["uiInput", longPress ? "longClick" : "click", String(x), String(y)])
    }

    public static func swipeVelocity(startX: Int, startY: Int, endX: Int, endY: Int, durationMs: Int) throws -> Int {
        try validatePoint(x: startX, y: startY)
        try validatePoint(x: endX, y: endY)
        guard durationMs > 0 else { throw HarmonyError("Swipe duration must be positive.") }
        let distance = hypot(Double(endX) - Double(startX), Double(endY) - Double(startY))
        let velocity = distance * 1000 / Double(durationMs)
        guard velocity.isFinite, velocity >= 200, velocity <= 40_000 else {
            throw HarmonyError("Harmony swipe requires a velocity of 200...40000 pixels/second; change the distance or duration.")
        }
        return Int(velocity.rounded())
    }

    public func swipe(startX: Int, startY: Int, endX: Int, endY: Int, durationMs: Int) throws {
        let velocity = try Self.swipeVelocity(startX: startX, startY: startY, endX: endX, endY: endY, durationMs: durationMs)
        try uitest(["uiInput", "swipe", String(startX), String(startY), String(endX), String(endY), String(velocity)])
    }

    public func type(text: String, clear: Bool = false, target: (x: Int, y: Int)? = nil) throws {
        guard !clear else { throw HarmonyError("Harmony uitest does not support --clear. Use the app's own clear control first.") }
        guard !text.contains("\0") else { throw HarmonyError("Text cannot contain NUL bytes.") }
        if let target {
            try Self.validatePoint(x: target.x, y: target.y)
            try uitest(["uiInput", "inputText", String(target.x), String(target.y), text])
        } else {
            try uitest(["uiInput", "text", text])
        }
    }

    public func button(_ button: String) throws {
        let names = ["home": "Home", "back": "Back", "power": "Power"]
        guard let key = names[button.lowercased()] else {
            throw HarmonyError("Harmony supports only the home, back, and power buttons.")
        }
        try uitest(["uiInput", "keyEvent", key])
    }

    public func keyboardVisible() throws -> Bool {
        let output = try transport.shell(serial: serial, args: ["hidumper", "-s", "WindowManagerService", "-a", "-a"])
        return try HarmonyKeyboardProbe.parse(output.stdout)
    }
}

/// G1: only SCBKeyboardPanel's ZOrd is a keyboard signal, never focused layout nodes.
public enum HarmonyKeyboardProbe {
    public static func parse(_ output: String) throws -> Bool {
        var zIndex: Int?
        var nameIndex: Int?
        var values: [Int] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if fields.contains("WindowName"), fields.contains("ZOrd") {
                zIndex = fields.firstIndex(of: "ZOrd")
                nameIndex = fields.firstIndex(of: "WindowName")
                continue
            }
            guard fields.contains("SCBKeyboardPanel") else { continue }
            guard let zIndex, let nameIndex, fields.count > max(zIndex, nameIndex),
                  fields[nameIndex] == "SCBKeyboardPanel", let value = Int(fields[zIndex]), value >= -1 else {
                throw HarmonyError("Malformed SCBKeyboardPanel ZOrd in the WindowManagerService probe.")
            }
            values.append(value)
        }
        guard zIndex != nil, !values.isEmpty else {
            throw HarmonyError("WindowManagerService did not return a window table and SCBKeyboardPanel row; keyboard state is unknown.")
        }
        return values.contains { $0 >= 0 }
    }
}
