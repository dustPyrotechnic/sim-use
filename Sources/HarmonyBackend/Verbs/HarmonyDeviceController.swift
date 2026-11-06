// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

public final class HarmonyDeviceController: Sendable {
    public let hdc: Hdc
    let cacheHome: URL
    private let uiTransport: (any HarmonyTransport & Sendable)?
    public static let shared = HarmonyDeviceController()
    public init(hdc: Hdc = Hdc(), uiTransport: (any HarmonyTransport & Sendable)? = nil,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.hdc = hdc
        self.uiTransport = uiTransport
        cacheHome = home
    }
    public func client(serial: String) -> UITestClient { UITestClient(serial: serial, transport: uiTransport ?? hdc) }

    func cacheOutline(_ outline: Outline, serial: String) {
        do {
            try OutlineCache.write(outline: outline, udid: serial, home: cacheHome)
        } catch {
            FileHandle.standardError.write(Data("warning: could not cache Harmony outline: \(error.localizedDescription)\n".utf8))
        }
    }

    public func listUnifiedDevices() throws -> [Device] {
        // `list targets` itself lists connected targets only; do not invent offline records.
        try hdc.listTargets().map {
            Device(udid: $0, name: $0, platform: .harmony, kind: .physical, state: "device", runtime: "HarmonyOS")
        }
    }

    public func describeUI(serial: String, options: HarmonyOutlineRenderer.RendererOptions = .default,
                           includeRaw: Bool = true) throws -> DescribeUIResult {
        let data = try client(serial: serial).dumpLayout()
        let roots = try HarmonyLayoutNode.decode(data)
        let outline = try HarmonyOutlineRenderer.render(roots: roots, options: options)
        cacheOutline(outline, serial: serial)
        return DescribeUIResult(platform: .harmony, raw: includeRaw ? try JSONValue.decode(from: data) : nil,
                                outline: outline.text, entries: outline.entries, lists: outline.lists,
                                screen: outline.screen, appLabel: outline.appLabel,
                                appPackage: HarmonyOutlineRenderer.appPackage(roots: roots))
    }

    public func appSnapshot(serial: String) throws -> AppSnapshot {
        let result = try hdc.shell(serial: serial, args: ["ps", "-A", "-o", "PID,NAME"])
        return try Self.parseProcesses(result.stdout)
    }

    public static func parseProcesses(_ output: String) throws -> AppSnapshot {
        var foundHeader = false
        var apps: [Int: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            if fields.first?.hasPrefix("#") == true { continue }
            guard fields.count == 2 else {
                throw HarmonyError("Unrecognized Harmony process list; app state is unknown.")
            }
            let name = fields[1].trimmingCharacters(in: .whitespaces)
            if fields[0] == "PID", name == "NAME" { foundHeader = true; continue }
            guard foundHeader, let pid = Int(fields[0]), pid > 0, !name.isEmpty else {
                throw HarmonyError("Unrecognized Harmony process list; app state is unknown.")
            }
            guard name.contains("."), !name.contains(":"), !name.contains("/") else { continue }
            apps[pid] = name
        }
        guard foundHeader else { throw HarmonyError("Harmony process list has no PID/NAME header.") }
        return AppSnapshot(appsByPid: apps)
    }
}
