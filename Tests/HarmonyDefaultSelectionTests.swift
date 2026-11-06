// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore
import Testing

@Suite("Harmony never becomes an implicit target")
struct HarmonyDefaultSelectionTests {
    private static let simulator = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    private static let harmony = "TESTHARMONY000001"
    private static let android = "emulator-5554"

    private func daemon(_ id: String, _ platform: Platform?) -> DaemonPaths.DiscoveredDaemon {
        .init(udid: id, pid: 123, paths: .init(udid: id), platform: platform)
    }

    private func resolve(_ daemons: [DaemonPaths.DiscoveredDaemon], booted: [DeviceResolver.BootedSimulator]) throws -> String {
        try DeviceResolver.resolve(
            explicit: nil, environment: [:], bootedListProvider: { booted },
            daemonListProvider: { daemons }
        )
    }

    @Test("Harmony alone without an iOS simulator reports noSimulatorBooted")
    func harmonyAlone() throws {
        do {
            _ = try resolve([daemon(Self.harmony, .harmony)], booted: [])
            Issue.record("Harmony must not be selected implicitly")
        } catch DeviceResolver.ResolutionError.noSimulatorBooted {
            // Expected: no hdc query participates in default selection.
        }
    }

    @Test("Harmony alone falls through to the booted iOS simulator")
    func harmonyWithSimulator() throws {
        #expect(try resolve([daemon(Self.harmony, .harmony)], booted: [.init(udid: Self.simulator, name: "iPhone")]) == Self.simulator)
    }

    @Test("Android retains priority over a booted simulator")
    func androidWithSimulator() throws {
        #expect(try resolve([daemon(Self.android, .android)], booted: [.init(udid: Self.simulator, name: "iPhone")]) == Self.android)
    }

    @Test("Android plus Harmony selects Android before simctl")
    func mixedDaemons() throws {
        let selected = try DeviceResolver.resolve(
            explicit: nil, environment: [:],
            bootedListProvider: { Issue.record("The daemon fast path must not call simctl"); return [] },
            daemonListProvider: { [daemon(Self.android, .android), daemon(Self.harmony, .harmony)] }
        )
        #expect(selected == Self.android)
    }

    @Test("A single iOS daemon keeps priority with any booted list")
    func iosDaemon() throws {
        #expect(try resolve([daemon(Self.simulator, .iOSSim)], booted: []) == Self.simulator)
        #expect(try resolve([daemon(Self.simulator, .iOSSim)], booted: [.init(udid: "another", name: "Other")]) == Self.simulator)
    }

    @Test("No daemon selects the only booted simulator")
    func noDaemons() throws {
        #expect(try resolve([], booted: [.init(udid: Self.simulator, name: "iPhone")]) == Self.simulator)
    }

    @Test("Untagged legacy Android daemon keeps its priority")
    func legacyDaemon() throws {
        #expect(try resolve([daemon(Self.android, nil)], booted: [.init(udid: Self.simulator, name: "iPhone")]) == Self.android)
    }

    @Test("Flag and either environment alias explicitly select Harmony")
    func explicitSelection() throws {
        for environment in [[:], ["SIM_USE_DEVICE": Self.harmony], ["SIM_USE_UDID": Self.harmony]] {
            let explicit = environment.isEmpty ? Self.harmony : nil
            #expect(try DeviceResolver.resolve(
                explicit: explicit, environment: environment,
                bootedListProvider: { Issue.record("Explicit selection must not call simctl"); return [] },
                daemonListProvider: { Issue.record("Explicit selection must not enumerate daemons"); return [] }
            ) == Self.harmony)
        }
    }

    @Test("Platform footprint preserves legacy PID and rejects mismatched metadata")
    func footprint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = DaemonPaths(udid: Self.harmony, baseDirectory: directory)
        try paths.ensureBaseDirectory()
        try paths.writePidfile(123, platform: .harmony)
        #expect(try String(contentsOf: paths.pidfileURL, encoding: .utf8) == "123\n")
        #expect(paths.readPlatform() == .harmony)
        try Data("456\n".utf8).write(to: paths.pidfileURL)
        #expect(paths.readPlatform() == nil)
        try paths.writePidfile(456)
        #expect(paths.readPlatform() == nil)
        #expect(!FileManager.default.fileExists(atPath: paths.platformURL.path))
        try paths.writePidfile(456, platform: .harmony)
        paths.removePidfile()
        #expect(!FileManager.default.fileExists(atPath: paths.platformURL.path))
    }
}
