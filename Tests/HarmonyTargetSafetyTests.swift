// SPDX-License-Identifier: Apache-2.0
#if canImport(HarmonyBackend)
import ArgumentParser
import Foundation
import HarmonyBackend
import SimUseCore
import Testing
import os

private final class HarmonyTargetTransport: HarmonyTransport, Sendable {
    struct State: Sendable {
        var artifact: Data
        var calls: [[String]] = []
        var failDump = false
    }
    let serial: String
    let state: OSAllocatedUnfairLock<State>

    init(serial: String, artifact: Data) {
        self.serial = serial
        state = OSAllocatedUnfairLock(initialState: State(artifact: artifact))
    }

    func shell(serial: String, args: [String]) throws -> Hdc.RunResult {
        guard serial == self.serial else { throw HarmonyError("Unexpected fixture serial") }
        return try state.withLock { state in
            state.calls.append(args)
            if args.starts(with: ["uitest", "dumpLayout"]), state.failDump {
                throw HarmonyError("Fixture layout capture failed")
            }
            guard args.starts(with: ["uitest", "dumpLayout"]) || args.starts(with: ["uitest", "uiInput"])
                    || args.starts(with: ["rm", "-f"]) else { throw HarmonyError("Unexpected fixture shell command") }
            return .init(stdout: "fixture success", stderr: "", exitCode: 0)
        }
    }

    func run(args: [String], timeout: TimeInterval?) throws -> Hdc.RunResult {
        guard args.count == 6, args[0] == "-t", args[1] == serial, args[2] == "file", args[3] == "recv" else {
            throw HarmonyError("Unexpected fixture transfer")
        }
        let data = state.withLock { $0.artifact }
        try data.write(to: URL(fileURLWithPath: args[5]))
        return .init(stdout: "FileTransfer finish", stderr: "", exitCode: 0)
    }
}

private final class HarmonyTargetFixture {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("sim-use-harmony-target-\(UUID().uuidString)", isDirectory: true)
    let serial = "TESTTARGET" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let roots: [HarmonyLayoutNode]
    private let transport: HarmonyTargetTransport
    private let controller: HarmonyDeviceController

    init(roots: [HarmonyLayoutNode]? = nil) throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/harmony")
        self.roots = try roots ?? HarmonyLayoutNode.decode(Data(contentsOf: fixtures.appendingPathComponent("third-party.json")))
        transport = HarmonyTargetTransport(serial: serial, artifact: try JSONEncoder().encode(self.roots))
        let absent = OutlineCache.directory(for: serial, home: home).appendingPathComponent("no-device-transport")
        controller = HarmonyDeviceController(hdc: Hdc(binaryPath: absent.path), uiTransport: transport, home: home)
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    var withoutKeyboard: [HarmonyLayoutNode] {
        roots.filter {
            !($0.attributes["bundleName"] ?? "").contains("inputmethod")
                && !($0.id ?? "").hasPrefix("keyboardPanel")
        }
    }

    func setCurrentLayout(_ roots: [HarmonyLayoutNode]) throws {
        let data = try JSONEncoder().encode(roots)
        transport.state.withLock { $0.artifact = data }
    }

    func describeUI() throws -> DescribeUIResult {
        try controller.describeUI(serial: serial, includeRaw: false)
    }

    func cache(_ roots: [HarmonyLayoutNode], unfiltered: Bool = false, capturedAt: Date = Date()) throws -> Outline {
        let outline = try HarmonyOutlineRenderer.render(roots: roots, options: .init(filterOffscreen: !unfiltered))
        try OutlineCache.write(outline: outline, udid: serial, capturedAt: capturedAt, home: home)
        return outline
    }

    func cacheData() throws -> Data { try Data(contentsOf: OutlineCache.file(for: serial, home: home)) }
    func resetEvents() throws { transport.state.withLock { $0.calls.removeAll(keepingCapacity: true) } }
    func calls() throws -> [[String]] { transport.state.withLock { $0.calls } }
    func inputs() throws -> [[String]] { try calls().filter { $0.starts(with: ["uitest", "uiInput"]) } }

    struct Response {
        let ok: Bool
        let error: String?
        let hint: String?
    }

    func run(_ verb: String, target: [String], failDump: Bool = false) throws -> Response {
        transport.state.withLock { $0.failDump = failDump }
        let alias = target.count == 1 ? target[0] : nil
        let targeting = try TapTargetingOptions.parse(alias == nil ? target : [])
        do {
            switch verb {
            case "tap":
                _ = try HarmonyTapCommand.performTap(serial: serial, alias: alias, targeting: targeting, controller: controller)
            case "long-press":
                _ = try HarmonyLongPressCommand.performLongPress(serial: serial, alias: alias, targeting: targeting,
                                                               duration: 0.8, controller: controller)
            case "type":
                try HarmonyTypeCommand.performType(udid: serial, text: "unchanged text", clear: false,
                                                   alias: alias, targeting: targeting, controller: controller)
            default:
                throw TestError.unexpectedState("Unexpected input verb: \(verb)")
            }
            return Response(ok: true, error: nil, hint: nil)
        } catch let error as HarmonyError {
            return Response(ok: false, error: error.message, hint: error.hint)
        }
    }

    static func expectedInput(_ verb: String, x: Int, y: Int) -> [String] {
        let action = verb == "type" ? "inputText" : (verb == "long-press" ? "longClick" : "click")
        return ["uitest", "uiInput", action, String(x), String(y)] + (verb == "type" ? ["unchanged text"] : [])
    }

    static func node(_ type: String, id: String = "", bounds: String, bundle: String = "", label: String = "",
                     children: [HarmonyLayoutNode] = []) -> HarmonyLayoutNode {
        HarmonyLayoutNode(attributes: ["type": type, "id": id, "bounds": bounds, "bundleName": bundle,
                                       "text": label, "visible": "true", "clickable": type == "Button" ? "true" : "false"], children: children)
    }
}

@Suite("Harmony live target safety")
struct HarmonyTargetSafetyTests {
    @Test("An isolated describe-ui snapshot is consumed by alias input without changing the cache")
    func isolatedSnapshotAliasRoundTrip() throws {
        let root = HarmonyTargetFixture.node("root", bounds: "[0,0][100,100]", children: [
            HarmonyTargetFixture.node("Button", id: "isolated", bounds: "[10,20][30,40]"),
        ])
        let fixture = try HarmonyTargetFixture(roots: [root])
        let snapshot = try fixture.describeUI()
        let entry = try #require(snapshot.entries.first { $0.uniqueId == "isolated" })
        let original = try fixture.cacheData()
        #expect(try fixture.run("tap", target: ["@\(entry.aliases.at)"]).ok)
        #expect(try fixture.inputs() == [HarmonyTargetFixture.expectedInput("tap", x: 20, y: 30)])
        #expect(try fixture.cacheData() == original)
    }

    @Test("Stale and unfiltered aliases cannot input into the current keyboard",
          arguments: ["tap", "long-press", "type"], [false, true])
    func coveredAliases(verb: String, unfiltered: Bool) throws {
        let fixture = try HarmonyTargetFixture()
        let snapshot = try fixture.cache(unfiltered ? fixture.roots : fixture.withoutKeyboard, unfiltered: unfiltered)
        let button = try #require(snapshot.entries.first { $0.uniqueId == "2851" })
        let cell = try #require(snapshot.entries.first { $0.aliases.list != nil && (1700..<2600).contains($0.frame.y + $0.frame.height / 2) })
        let list = try #require(cell.aliases.list)
        let original = try fixture.cacheData()
        for alias in ["@\(button.aliases.at)", "#\(list.index)@\(list.scope)"] {
            try fixture.resetEvents()
            let result = try fixture.run(verb, target: [alias])
            #expect(!result.ok)
            #expect(result.hint?.contains("describe-ui") == true)
            #expect(try fixture.inputs().isEmpty)
            #expect(try fixture.cacheData() == original)
        }
    }

    @Test("Current keyboard aliases keep their coordinates and the saved alias numbering")
    func keyboardAliases() throws {
        let fixture = try HarmonyTargetFixture()
        let snapshot = try fixture.cache(fixture.roots)
        let original = try fixture.cacheData()
        for id in ["KeyMenu", "keyboardLeftButton", "keyboardRightButton"] {
            let entry = try #require(snapshot.entries.first { $0.uniqueId == id })
            try fixture.resetEvents()
            let result = try fixture.run("tap", target: ["@\(entry.aliases.at)"])
            #expect(result.ok)
            #expect(try fixture.inputs() == [HarmonyTargetFixture.expectedInput("tap", x: entry.frame.x + entry.frame.width / 2,
                                                                             y: entry.frame.y + entry.frame.height / 2)])
            #expect(try fixture.cacheData() == original)
        }
    }

    @Test("Uncovered aliases keep cached coordinates with or without a keyboard", arguments: [false, true])
    func uncoveredAliases(keyboard: Bool) throws {
        let fixture = try HarmonyTargetFixture()
        let current = keyboard ? fixture.roots : fixture.withoutKeyboard
        try fixture.setCurrentLayout(current)
        let snapshot = try fixture.cache(current, unfiltered: true)
        let id = keyboard ? "2832" : "2851"
        let entry = try #require(snapshot.entries.first { $0.uniqueId == id })
        let original = try fixture.cacheData()
        for _ in 0..<2 {
            try fixture.resetEvents()
            #expect(try fixture.run("tap", target: ["@\(entry.aliases.at)"]).ok)
            #expect(try fixture.inputs() == [HarmonyTargetFixture.expectedInput("tap", x: entry.frame.x + entry.frame.width / 2,
                                                                             y: entry.frame.y + entry.frame.height / 2)])
            #expect(try fixture.cacheData() == original)
        }
    }

    @Test("A failed live alias dump sends no input", arguments: ["tap", "long-press", "type"])
    func failedDump(verb: String) throws {
        let fixture = try HarmonyTargetFixture()
        let snapshot = try fixture.cache(fixture.roots)
        let entry = try #require(snapshot.entries.first { $0.uniqueId == "2832" })
        let original = try fixture.cacheData()
        let result = try fixture.run(verb, target: ["@\(entry.aliases.at)"], failDump: true)
        #expect(!result.ok)
        #expect(result.error?.contains("Fixture layout capture failed") == true)
        #expect(try fixture.inputs().isEmpty)
        #expect(try fixture.cacheData() == original)
    }

    @Test("Element-derived input checks the actual truncated or rounded point against the live screen",
          arguments: ["tap", "long-press", "type"],
          [("[280,40][320,60]", 300, 50, false), ("[40,280][60,320]", 50, 300, false),
           ("[40,280][60,340]", 50, 310, false), ("[40,279][60,320]", 50, 299, true)])
    func screenEdges(verb: String, sample: (String, Int, Int, Bool)) throws {
        let root = HarmonyTargetFixture.node("root", bounds: "[0,0][300,300]", bundle: "com.example.fixture", children: [
            HarmonyTargetFixture.node("Button", id: "edge", bounds: sample.0),
        ])
        let fixture = try HarmonyTargetFixture(roots: [root])
        let snapshot = try fixture.cache([root])
        let entry = try #require(snapshot.entries.first { $0.uniqueId == "edge" })
        let original = try fixture.cacheData()
        for target in [["@\(entry.aliases.at)"], ["--id", "edge"]] {
            try fixture.resetEvents()
            let result = try fixture.run(verb, target: target)
            let allowed = target.count == 1 && sample.3
            #expect(result.ok == allowed)
            if allowed {
                #expect(try fixture.inputs() == [HarmonyTargetFixture.expectedInput(verb, x: sample.1, y: sample.2)])
            } else {
                #expect(result.hint?.contains("scroll") == true)
                #expect(result.hint?.contains("describe-ui") == true)
                #expect(try fixture.inputs().isEmpty)
            }
            if target.count == 1 { #expect(try fixture.cacheData() == original) }
        }
    }

    @Test("Rejected selectors preserve the cached layout and usable aliases",
          arguments: ["tap", "long-press", "type"], ["[40,280][60,340]", "[200,-100][300,20]"])
    func rejectedSelectorsPreserveAliases(verb: String, bounds: String) throws {
        let current = HarmonyTargetFixture.node("root", bounds: "[0,0][300,300]", children: [
            HarmonyTargetFixture.node("Button", id: "outside", bounds: bounds),
        ])
        let previous = HarmonyTargetFixture.node("root", bounds: "[0,0][300,300]", children: [
            HarmonyTargetFixture.node("Button", id: "previous", bounds: "[10,20][30,40]"),
        ])
        let fixture = try HarmonyTargetFixture(roots: [current])
        let snapshot = try fixture.cache([previous], capturedAt: Date(timeIntervalSince1970: 0))
        let entry = try #require(snapshot.entries.first { $0.uniqueId == "previous" })
        let original = try fixture.cacheData()

        let result = try fixture.run(verb, target: ["--id", "outside"])
        #expect(!result.ok)
        #expect(result.error?.contains("outside") == true)
        #expect(result.error?.contains("screen") == true)
        #expect(result.hint?.contains("scroll") == true)
        #expect(result.hint?.contains("describe-ui") == true)
        #expect(try fixture.inputs().isEmpty)
        #expect(try fixture.cacheData() == original)

        #expect(try fixture.run(verb, target: ["@\(entry.aliases.at)"]).ok)
        #expect(try fixture.inputs() == [HarmonyTargetFixture.expectedInput(verb, x: 20, y: 30)])
    }

    @Test("A selector miss refreshes aliases for the current layout without input",
          arguments: ["tap", "long-press", "type"])
    func missingSelectorsRefreshAliases(verb: String) throws {
        let current = HarmonyTargetFixture.node("root", bounds: "[0,0][300,300]", children: [
            HarmonyTargetFixture.node("Button", id: "current", bounds: "[210,220][230,240]"),
        ])
        let previous = HarmonyTargetFixture.node("root", bounds: "[0,0][300,300]", children: [
            HarmonyTargetFixture.node("Button", id: "previous", bounds: "[10,20][30,40]"),
        ])
        let fixture = try HarmonyTargetFixture(roots: [current])
        let snapshot = try fixture.cache([previous], capturedAt: Date(timeIntervalSince1970: 0))
        let entry = try #require(snapshot.entries.first { $0.uniqueId == "previous" })
        let original = try fixture.cacheData()

        let result = try fixture.run(verb, target: ["--id", "missing"])
        #expect(!result.ok)
        #expect(result.error?.contains("No Harmony element matches") == true)
        #expect(result.hint?.contains("describe-ui") == true)
        #expect(result.hint?.contains("selector") == true)
        #expect(result.hint?.contains("@N") == true)
        #expect(!(result.hint ?? "").contains("hdc connectivity"))
        #expect(try fixture.inputs().isEmpty)
        let refreshed = try fixture.cacheData()
        #expect(refreshed != original)

        #expect(try fixture.run(verb, target: ["@\(entry.aliases.at)"]).ok)
        #expect(try fixture.inputs() == [HarmonyTargetFixture.expectedInput(verb, x: 220, y: 230)])
        #expect(try fixture.cacheData() == refreshed)
    }

    @Test("A successful selector refreshes aliases for the current layout",
          arguments: ["tap", "long-press", "type"])
    func successfulSelectorsRefreshAliases(verb: String) throws {
        let current = HarmonyTargetFixture.node("root", bounds: "[0,0][300,300]", children: [
            HarmonyTargetFixture.node("Button", id: "current", bounds: "[210,220][230,240]"),
        ])
        let previous = HarmonyTargetFixture.node("root", bounds: "[0,0][300,300]", children: [
            HarmonyTargetFixture.node("Button", id: "previous", bounds: "[10,20][30,40]"),
        ])
        let fixture = try HarmonyTargetFixture(roots: [current])
        let snapshot = try fixture.cache([previous], capturedAt: Date(timeIntervalSince1970: 0))
        let entry = try #require(snapshot.entries.first { $0.uniqueId == "previous" })
        let original = try fixture.cacheData()

        #expect(try fixture.run(verb, target: ["--id", "current"]).ok)
        #expect(try fixture.inputs() == [HarmonyTargetFixture.expectedInput(verb, x: 220, y: 230)])
        let refreshed = try fixture.cacheData()
        #expect(refreshed != original)

        try fixture.resetEvents()
        #expect(try fixture.run(verb, target: ["@\(entry.aliases.at)"]).ok)
        #expect(try fixture.inputs() == [HarmonyTargetFixture.expectedInput(verb, x: 220, y: 230)])
        #expect(try fixture.cacheData() == refreshed)
    }

    @Test("Negative element centers report screen recovery without input or cache changes",
          arguments: ["tap", "long-press", "type"],
          [("[0,-200][100,-100]", true), ("[200,-100][300,20]", false), ("[-100,200][20,300]", false)])
    func negativeElementCenters(verb: String, sample: (String, Bool)) throws {
        let root = HarmonyTargetFixture.node("root", bounds: "[0,0][1000,1000]", children: [
            HarmonyTargetFixture.node("Button", id: "negative", bounds: sample.0),
        ])
        let fixture = try HarmonyTargetFixture(roots: [root])
        let snapshot = try fixture.cache([root], unfiltered: sample.1, capturedAt: Date(timeIntervalSince1970: 0))
        let entry = try #require(snapshot.entries.first { $0.uniqueId == "negative" })
        let original = try fixture.cacheData()
        let targets = [["@\(entry.aliases.at)"]] + (sample.1 ? [] : [["--id", "negative"]])
        for target in targets {
            try fixture.resetEvents()
            let result = try fixture.run(verb, target: target)
            #expect(!result.ok)
            #expect(result.error?.contains("outside") == true)
            #expect(result.error?.contains("screen") == true)
            #expect(result.hint?.contains("scroll") == true)
            #expect(result.hint?.contains("describe-ui") == true)
            #expect(!(result.hint ?? "").contains("hdc connectivity"))
            #expect(try fixture.inputs().isEmpty)
            #expect(try fixture.cacheData() == original)
        }
    }

    @Test("Zero-area diagnostic aliases and scoped cells cannot send input",
          arguments: ["tap", "long-press", "type"],
          ["[0,0][0,0]", "[500,500][500,500]", "[500,500][500,600]", "[500,500][600,500]"])
    func zeroSizeAliases(verb: String, bounds: String) throws {
        let root = HarmonyTargetFixture.node("root", bounds: "[0,0][1000,1000]", children: [
            HarmonyTargetFixture.node("List", id: "items", bounds: "[0,0][1000,1000]", children: [
                HarmonyTargetFixture.node("ListItem", id: "empty", bounds: bounds),
            ]),
        ])
        let fixture = try HarmonyTargetFixture(roots: [root])
        let snapshot = try fixture.cache([root], unfiltered: true, capturedAt: Date(timeIntervalSince1970: 0))
        let entry = try #require(snapshot.entries.first { $0.uniqueId == "empty" })
        let list = try #require(entry.aliases.list)
        let original = try fixture.cacheData()
        for alias in ["@\(entry.aliases.at)", "#\(list.index)@\(list.scope)"] {
            try fixture.resetEvents()
            let result = try fixture.run(verb, target: [alias])
            #expect(!result.ok)
            #expect(result.hint?.contains("describe-ui") == true)
            #expect(try fixture.inputs().isEmpty)
            #expect(try fixture.cacheData() == original)
        }
    }

    @Test("The real zero-size fixture node stays diagnostic and cannot receive input",
          arguments: ["tap", "long-press", "type"])
    func zeroSizeFixtureAlias(verb: String) throws {
        let fixture = try HarmonyTargetFixture()
        let snapshot = try fixture.cache(fixture.roots, unfiltered: true, capturedAt: Date(timeIntervalSince1970: 0))
        let entry = try #require(snapshot.entries.first { $0.uniqueId == "2306" })
        let original = try fixture.cacheData()
        let result = try fixture.run(verb, target: ["@\(entry.aliases.at)"])
        #expect(!result.ok)
        #expect(result.hint?.contains("describe-ui") == true)
        #expect(try fixture.inputs().isEmpty)
        #expect(try fixture.cacheData() == original)
    }

    @Test("Alias bounds use the current screen, not the cached screen")
    func changedScreen() throws {
        let child = HarmonyTargetFixture.node("Button", id: "edge", bounds: "[280,40][320,60]")
        let current = HarmonyTargetFixture.node("root", bounds: "[0,0][300,300]", children: [child])
        let old = HarmonyTargetFixture.node("root", bounds: "[0,0][600,600]", children: [child])
        let fixture = try HarmonyTargetFixture(roots: [current])
        let snapshot = try fixture.cache([old])
        let entry = try #require(snapshot.entries.first { $0.uniqueId == "edge" })
        let original = try fixture.cacheData()
        let result = try fixture.run("tap", target: ["@\(entry.aliases.at)"])
        #expect(!result.ok)
        #expect(result.hint?.contains("scroll") == true)
        #expect(try fixture.inputs().isEmpty)
        #expect(try fixture.cacheData() == original)
    }

    @Test("Explicit coordinates bypass keyboard, screen and dump validation", arguments: ["tap", "long-press", "type"])
    func explicitCoordinates(verb: String) throws {
        let fixture = try HarmonyTargetFixture()
        _ = try fixture.cache(fixture.roots)
        let original = try fixture.cacheData()
        for target in [["--x", "654", "--y", "1984"], ["--point", "654,1984"], ["--x", "1260", "--y", "2720"]] {
            try fixture.resetEvents()
            #expect(try fixture.run(verb, target: target, failDump: true).ok)
            let outside = target.contains("2720")
            #expect(try fixture.inputs() == [HarmonyTargetFixture.expectedInput(verb, x: outside ? 1260 : 654, y: outside ? 2720 : 1984)])
            #expect(try !fixture.calls().contains { $0.starts(with: ["uitest", "dumpLayout"]) })
            #expect(try fixture.cacheData() == original)
        }
    }

    @Test("A matching keyboard frame does not authorize an ambiguous cached App target")
    func ambiguousKeyboardTarget() throws {
        let app = HarmonyTargetFixture.node("root", bounds: "[0,0][300,300]", bundle: "com.example.fixture", children: [
            HarmonyTargetFixture.node("Button", id: "app", bounds: "[100,200][200,240]", label: "same"),
        ])
        let keyboard = HarmonyTargetFixture.node("root", bounds: "[0,0][300,300]", bundle: "com.example.inputmethod", children: [
            HarmonyTargetFixture.node("Row", bounds: "[0,180][300,300]", children: [
                HarmonyTargetFixture.node("Button", id: "key", bounds: "[100,200][200,240]", label: "same"),
            ]),
        ])
        let fixture = try HarmonyTargetFixture(roots: [app, keyboard])
        let snapshot = try fixture.cache([app])
        let entry = try #require(snapshot.entries.first { $0.uniqueId == "app" })
        let result = try fixture.run("tap", target: ["@\(entry.aliases.at)"])
        #expect(!result.ok)
        #expect(result.hint?.contains("describe-ui") == true)
        #expect(try fixture.inputs().isEmpty)
    }
}
#endif
