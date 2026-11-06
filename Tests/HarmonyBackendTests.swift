// SPDX-License-Identifier: Apache-2.0
#if canImport(HarmonyBackend)
import ArgumentParser
import CoreGraphics
import Foundation
import ImageIO
import SimUseCore
import Testing
@testable import HarmonyBackend

private func harmonyFixture(_ name: String) throws -> Data {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/harmony")
    return try Data(contentsOf: directory.appendingPathComponent(name))
}

private func harmonyTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sim-use-harmony-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func harmonyPNG() throws -> Data {
    let pixel = Data([0, 0, 0, 255])
    let provider = try #require(CGDataProvider(data: pixel as CFData))
    let image = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Suite("Harmony layout and keyboard fixtures")
struct HarmonyLayoutTests {
    @Test("Real home and third-party dumps preserve nodes, bounds, bundles and aliases")
    func realLayouts() throws {
        for (fixture, count, bundle) in [("home.json", 214, "com.ohos.sceneboard"), ("third-party.json", 930, "com.baidu.baiduapp")] {
            let roots = try HarmonyLayoutNode.decode(harmonyFixture(fixture))
            func countNodes(_ node: HarmonyLayoutNode) -> Int { 1 + node.children.reduce(0) { $0 + countNodes($1) } }
            #expect(roots.reduce(0) { $0 + countNodes($1) } == count)
            let outline = try HarmonyOutlineRenderer.render(roots: roots)
            #expect(outline.screen == .init(x: 0, y: 0, width: 1260, height: 2720))
            #expect(outline.appLabel == bundle)
            #expect(outline.entries.map(\.aliases.at) == Array(1...outline.entries.count))
            #expect(outline.text.contains("App: \(bundle)"))
            #expect(!HarmonyOutlineRenderer.hasSystemDialog(roots: roots))
            let home = try harmonyTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: home) }
            try OutlineCache.write(outline: outline, udid: "test-harmony", home: home)
            for entry in outline.entries {
                let target = try OutlineAliasResolver.resolve("@\(entry.aliases.at)", udid: "test-harmony", home: home)
                #expect(target.point.x == Double(entry.frame.x + entry.frame.width / 2))
                #expect(target.point.y == Double(entry.frame.y + entry.frame.height / 2))
                #expect(target.label == entry.label)
            }
        }
    }

    @Test("Real object-root system dialog is flagged but never dismissed")
    func dialog() throws {
        let roots = try HarmonyLayoutNode.decode(harmonyFixture("system-dialog.json"))
        #expect(roots.count == 1)
        #expect(HarmonyOutlineRenderer.hasSystemDialog(roots: roots))
        let outline = try HarmonyOutlineRenderer.render(roots: roots)
        #expect(outline.text.hasPrefix("[!] Harmony system dialog"))
        #expect(outline.entries.contains { $0.label == "确定" })
    }

    @Test("Real third-party input is classified and matched by id")
    func inputSelector() throws {
        let roots = try HarmonyLayoutNode.decode(harmonyFixture("third-party.json"))
        let outline = try HarmonyOutlineRenderer.render(roots: roots)
        let entry = try HarmonyTargetResolver.match(entries: outline.entries, screen: outline.screen,
                                                   id: "1322ai_SearchBox_textarea", elementType: "TextField")
        #expect(entry.frame == .init(x: 92, y: 177, width: 1053, height: 57))
        #expect(entry.role == "TextField")
        // The old TextInput remains in the dump with visible=true, but its
        // __Common__ ancestor is hidden with zero bounds. Only the current
        // TextArea is actionable in the default outline.
        #expect(throws: (any Error).self) {
            try HarmonyTargetResolver.match(entries: outline.entries, screen: outline.screen,
                                            id: "hissug_search_box_id", elementType: "TextField")
        }
        let unfiltered = try HarmonyOutlineRenderer.render(roots: roots, options: .init(filterOffscreen: false))
        let hiddenInput = try HarmonyTargetResolver.match(entries: unfiltered.entries, screen: unfiltered.screen,
                                                         id: "hissug_search_box_id", elementType: "TextField")
        #expect(hiddenInput.frame == .init(x: 88, y: 166, width: 770, height: 78))
        #expect(throws: (any Error).self) {
            try HarmonyTargetResolver.match(entries: outline.entries, screen: outline.screen, id: "missing-control")
        }
        #expect(throws: (any Error).self) {
            try HarmonyTargetResolver.match(entries: outline.entries, screen: outline.screen, elementType: "NotAType")
        }
    }

    @Test("System SearchField supports typed selectors and text readback")
    func systemSearchField() throws {
        let roots = try HarmonyLayoutNode.decode(harmonyFixture("system-search-input.json"))
        let outline = try HarmonyOutlineRenderer.render(roots: roots)
        let entry = try HarmonyTargetResolver.match(
            entries: outline.entries, screen: outline.screen,
            id: "__SearchField__hisearchSearchInput", elementType: "TextField"
        )
        #expect(entry.label == "鸿蒙测试abc123")
        #expect(entry.frame == .init(x: 169, y: 169, width: 935, height: 127))
    }

    @Test("Bounds reject malformed, reversed and overflowing inputs")
    func bounds() {
        #expect(HarmonyLayoutNode.parseBounds("[-1,2][30,40]") == .init(x: -1, y: 2, width: 31, height: 38))
        for invalid in ["", "[0,0,2,2]", "[2,0][1,2]", "[0,0][nan,5]", "[0,0][9223372036854775807,3]", "prefix[0,0][1,1]"] {
            #expect(HarmonyLayoutNode.parseBounds(invalid) == nil)
        }
    }

    @Test("Classifier maps Harmony controls without Android classes")
    func classifier() {
        for (type, expected) in [("TextInput", "TextField"), ("TextArea", "TextField"), ("Button", "Button"),
                                 ("Text", "TextView"), ("Toggle", "Switch"), ("List", "List"),
                                 ("GridItem", "Cell"), ("Scroll", "ScrollView"), ("Unknown", "View")] {
            #expect(HarmonyClassifier.role(.init(attributes: ["type": type])) == expected)
        }
        #expect(HarmonyClassifier.role(.init(attributes: ["type": "Image", "clickable": "true"])) == "Button")
        #expect(!HarmonyLayoutNode(attributes: ["focused": ""]).flag("focused"))
    }

    @Test("Shared whitespace and ambiguity policy remains consumer-visible")
    func selectors() throws {
        let screen = Outline.Frame(x: 0, y: 0, width: 100, height: 200)
        let entries = [
            Outline.Entry(aliases: .init(at: 1), role: "Button", label: "Send\nmessage", frame: .init(x: 1, y: 10, width: 20, height: 20), region: .init(kind: "Content"), states: []),
            Outline.Entry(aliases: .init(at: 2), role: "Button", label: "Send message", frame: .init(x: 1, y: 100, width: 20, height: 20), region: .init(kind: "Content"), states: []),
        ]
        #expect(try HarmonyTargetResolver.match(entries: entries, screen: screen, label: "Send message").aliases.at == 2)
        #expect(try HarmonyTargetResolver.match(entries: [entries[0]], screen: screen, label: "Send message").aliases.at == 1)
        #expect(throws: (any Error).self) { try HarmonyTargetResolver.match(entries: entries, screen: screen, labelContains: "Send") }
        #expect(try HarmonyTargetResolver.match(entries: entries, screen: screen, labelContains: "Send", frameSpecs: ["minY=0.4r"]).aliases.at == 2)
    }

    @Test("A missing Harmony selector directs recovery to the current UI, not connectivity")
    func selectorMissHint() throws {
        let roots = try HarmonyLayoutNode.decode(harmonyFixture("system-search-input.json"))
        let outline = try HarmonyOutlineRenderer.render(roots: roots)
        do {
            _ = try HarmonyTargetResolver.match(entries: outline.entries, screen: outline.screen, id: "missing-control")
            Issue.record("Expected the missing selector to fail")
        } catch let error as HarmonyError {
            let hint = try #require(error.hint)
            #expect(hint.contains("describe-ui"))
            #expect(!hint.contains("hdc connectivity"))
        }
    }

    @Test("An actual transport failure retains hdc connection recovery advice")
    func transportFailureHint() throws {
        do {
            _ = try Hdc(binaryPath: "/usr/bin/false").listTargets()
            Issue.record("Expected the failing host process to fail discovery")
        } catch let error as HarmonyError {
            #expect(error.message.contains("hdc failed"))
            #expect(error.hint?.contains("hdc connectivity") == true)
            #expect(error.hint?.contains("--device") == true)
        }
    }

    @Test("G1 separates shown, hidden and hidden-after-Back in both real scenes")
    func keyboardFixtures() throws {
        for scene in ["system", "app"] {
            for (state, visible) in [("hidden", false), ("shown", true), ("after-back", false)] {
                let dump = String(decoding: try harmonyFixture("\(scene)-\(state).wms"), as: UTF8.self)
                #expect(try HarmonyKeyboardProbe.parse(dump) == visible)
            }
        }
    }

    @Test("Absent or malformed keyboard probes never report hidden")
    func keyboardFailures() throws {
        let valid = String(decoding: try harmonyFixture("system-hidden.wms"), as: UTF8.self)
        let missing = valid.replacingOccurrences(of: "SCBKeyboardPanel", with: "OtherPanel")
        for dump in ["", "hdc error", "SCBKeyboardPanel 0 1 2 2134 1 0 -1", missing,
                     "WindowName ZOrd\nSCBKeyboardPanel unknown", "WindowName ZOrd\nSCBKeyboardPanel -2"] {
            #expect(throws: (any Error).self) { try HarmonyKeyboardProbe.parse(dump) }
        }
        #expect(try HarmonyKeyboardProbe.parse("ZOrd WindowName\n0 SCBKeyboardPanel") == true)
    }

    @Test("App-state uses main process liveness, not a foreground layout guess")
    func processes() throws {
        let snapshot = try HarmonyDeviceController.parseProcesses(String(decoding: harmonyFixture("processes.txt"), as: UTF8.self))
        #expect(snapshot.appsByPid == [3229: "com.ohos.sceneboard", 17290: "com.baidu.baiduapp"])
        let report = AppStateReport.buildResult(platform: "harmony", snapshot: snapshot, bundleId: "com.baidu.baiduapp", didReset: false)
        #expect(report.query?.state == "running")
        #expect(report.platform == "harmony")
        let systemReport = AppStateReport.buildResult(platform: "harmony", snapshot: snapshot, bundleId: "com.ohos.sceneboard", didReset: false)
        #expect(systemReport.query?.state == "running")
        let absentReport = AppStateReport.buildResult(platform: "harmony", snapshot: snapshot, bundleId: "com.ohos.absent", didReset: false)
        #expect(absentReport.query?.state == "not_running")
    }

    @Test("Process names retain spaces without breaking app-state")
    func processNamesWithSpaces() throws {
        let snapshot = try HarmonyDeviceController.parseProcesses(String(decoding: harmonyFixture("processes-whitespace.txt"), as: UTF8.self))
        #expect(snapshot.appsByPid == [3229: "com.ohos.sceneboard", 17290: "com.baidu.baiduapp", 24000: "com.example.worker name"])
    }

    @Test("Malformed process tables never report apps as stopped")
    func processFailures() {
        for output in [
            "", "not a ps table", "3229 com.ohos.sceneboard",
            "PID COMMAND\n3229 com.ohos.sceneboard",
            "PID NAME EXTRA\n3229 com.ohos.sceneboard",
            "PID NAME\ninvalid com.ohos.sceneboard",
            "PID NAME\n0 com.ohos.sceneboard",
            "PID NAME\n-1 com.ohos.sceneboard",
            "PID NAME\n999999999999999999999999 com.ohos.sceneboard",
            "PID NAME\n3229", "PID NAME\n3229   \t",
            "PID NAME\n3229 com.ohos.sceneboard\nbroken row",
        ] {
            #expect(throws: (any Error).self) { try HarmonyDeviceController.parseProcesses(output) }
        }
    }
}

@Suite("Harmony keyboard occlusion")
struct HarmonyKeyboardOcclusionTests {
    @Test("Real keyboard panel removes covered app targets from outline, selectors and cached aliases")
    func realKeyboardOcclusion() throws {
        let roots = try HarmonyLayoutNode.decode(harmonyFixture("third-party.json"))
        let outline = try HarmonyOutlineRenderer.render(roots: roots)
        #expect(!outline.entries.contains { $0.uniqueId == "2851" })
        #expect(!outline.text.contains("#2851 "))
        #expect(throws: HarmonyError.self) {
            try HarmonyTargetResolver.match(entries: outline.entries, screen: outline.screen, id: "2851")
        }
        let partial = try HarmonyTargetResolver.match(entries: outline.entries, screen: outline.screen, id: "2809")
        #expect(partial.frame == .init(x: 52, y: 1495, width: 1205, height: 115))
        let keyboard = try HarmonyTargetResolver.match(entries: outline.entries, screen: outline.screen, id: "KeyMenu")
        #expect(keyboard.frame == .init(x: 33, y: 1721, width: 124, height: 124))
        for id in ["keyboardLeftButton", "keyboardRightButton"] {
            let systemControl = try HarmonyTargetResolver.match(entries: outline.entries, screen: outline.screen, id: id)
            #expect(systemControl.frame.y == 2584)
        }
        let home = try harmonyTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try OutlineCache.write(outline: outline, udid: "TESTOCCLUSION01", home: home)
        for entry in outline.entries {
            let target = try OutlineAliasResolver.resolve("@\(entry.aliases.at)", udid: "TESTOCCLUSION01", home: home)
            #expect(target.point.x != 654 || target.point.y != 1984)
        }
        let unfiltered = try HarmonyOutlineRenderer.render(roots: roots, options: .init(filterOffscreen: false))
        let covered = try HarmonyTargetResolver.match(entries: unfiltered.entries, screen: unfiltered.screen, id: "2851")
        #expect(covered.frame == .init(x: 52, y: 1927, width: 1205, height: 115))
        #expect(unfiltered.entries.contains { $0.uniqueId == "KeyMenu" })
    }

    @Test("Covered list centers do not hide visible children or leave cell alias gaps")
    func visibleListCells() throws {
        let roots = try HarmonyLayoutNode.decode(harmonyFixture("third-party.json"))
        let keyboard = try #require(roots.first { $0.attributes["bundleName"] == "com.huawei.hmos.inputmethod" })
        let list = Self.node("List", id: "results", bounds: "[0,1400][1260,2600]", children: [
            Self.node("ListItem", id: "visible", bounds: "[0,1400][1260,1500]"),
            Self.node("ListItem", id: "covered", bounds: "[0,1900][1260,2000]"),
            Self.node("ListItem", id: "partial", bounds: "[0,1490][1260,1610]"),
        ])
        let app = Self.node("root", bounds: "[0,0][1260,2720]", bundle: "com.example.fixture", children: [list])
        let outline = try HarmonyOutlineRenderer.render(roots: [app, keyboard])
        let cells = outline.entries.filter { $0.aliases.list?.scope == 1 }
        #expect(cells.map(\.uniqueId) == ["visible", "partial"])
        #expect(cells.map(\.aliases.at) == [1, 2])
        #expect(cells.compactMap { $0.aliases.list?.index } == [1, 2])
        #expect(outline.lists.first?.cellCount == 2)
        #expect(!outline.entries.contains { $0.uniqueId == "results" })
        let home = try harmonyTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try OutlineCache.write(outline: outline, udid: "TESTOCCLUSION02", home: home)
        let second = try OutlineAliasResolver.resolve("#2", udid: "TESTOCCLUSION02", home: home)
        #expect(second.label == "partial")
        #expect(second.point.x == 630 && second.point.y == 1550)
        #expect(throws: OutlineAliasResolver.ResolutionError.self) {
            try OutlineAliasResolver.resolve("#3", udid: "TESTOCCLUSION02", home: home)
        }
        let unfiltered = try HarmonyOutlineRenderer.render(roots: [app, keyboard], options: .init(filterOffscreen: false))
        #expect(unfiltered.lists.first?.cellCount == 3)
    }

    @Test("Keyboard coverage uses the target center and preserves keyboard controls")
    func centerVisibility() throws {
        let app = Self.node("root", bounds: "[0,0][300,300]", bundle: "com.example.fixture", children: [
            Self.node("Button", id: "left-visible", bounds: "[60,120][120,160]"),
            Self.node("Button", id: "covered", bounds: "[150,120][230,160]"),
            Self.node("Button", id: "right-visible", bounds: "[210,120][260,160]"),
            Self.node("Button", id: "top-covered", bounds: "[120,90][160,110]"),
            Self.node("Button", id: "bottom-visible", bounds: "[120,190][160,210]"),
        ])
        let keyboard = Self.node("root", bounds: "[0,0][300,300]", bundle: "com.huawei.hmos.inputmethod", children: [
            Self.node("Column", bounds: "[100,100][200,200]", children: [
                Self.node("Button", id: "ime-key", bounds: "[130,130][170,170]"),
            ]),
        ])
        let outline = try HarmonyOutlineRenderer.render(roots: [app, keyboard])
        #expect(outline.entries.map(\.uniqueId) == ["left-visible", "right-visible", "ime-key", "bottom-visible"])
    }

    @Test("Absent, hidden or unusable input-method geometry leaves the outline unchanged",
          arguments: ["absent", "invalid", "zero", "fullscreen", "hidden"])
    func missingGeometry(scenario: String) throws {
        let app = Self.node("root", bounds: "[0,0][300,300]", bundle: "com.example.fixture", children: [
            Self.node("Button", id: "app-button", bounds: "[100,180][200,220]"),
        ])
        let baseline = try HarmonyOutlineRenderer.render(roots: [app])
        var roots = [app]
        switch scenario {
        case "invalid":
            roots.append(Self.node("root", bounds: "invalid", bundle: "com.huawei.hmos.inputmethod"))
        case "zero":
            roots.append(Self.node("root", bounds: "[0,0][0,0]", bundle: "com.huawei.hmos.inputmethod"))
        case "fullscreen":
            roots.append(Self.node("root", bounds: "[0,0][300,300]", bundle: "com.huawei.hmos.inputmethod"))
        case "hidden":
            roots.append(Self.node("root", bounds: "[0,0][300,300]", bundle: "com.huawei.hmos.inputmethod", visible: false,
                                   children: [Self.node("Column", bounds: "[0,100][300,300]")]))
        default: break
        }
        #expect(try HarmonyOutlineRenderer.render(roots: roots) == baseline)
    }

    @Test("Real app targets in the transparent keyboard strip remain selectable and cached",
          arguments: [("2325", 105, 1606), ("2821", 654, 1696), ("2823", 654, 1696), ("2832", 269, 1696)])
    func transparentFixtureTargets(id: String, x: Int, y: Int) throws {
        let roots = try HarmonyLayoutNode.decode(harmonyFixture("third-party.json"))
        let outline = try HarmonyOutlineRenderer.render(roots: roots)
        #expect(outline.entries.contains { $0.uniqueId == id })
        let entry = try HarmonyTargetResolver.match(entries: outline.entries, screen: outline.screen, id: id)
        let home = try harmonyTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try OutlineCache.write(outline: outline, udid: "TESTTRANSPARENT01", home: home)
        let target = try OutlineAliasResolver.resolve("@\(entry.aliases.at)", udid: "TESTTRANSPARENT01", home: home)
        #expect(target.point.x == Double(x) && target.point.y == Double(y))
        for coveredID in ["2837", "2851"] {
            #expect(!outline.entries.contains { $0.uniqueId == coveredID })
            #expect(throws: HarmonyError.self) {
                try HarmonyTargetResolver.match(entries: outline.entries, screen: outline.screen, id: coveredID)
            }
        }
    }

    @Test("The real transparent-strip cell extends the filtered list without alias gaps")
    func transparentFixtureList() throws {
        let roots = try HarmonyLayoutNode.decode(harmonyFixture("third-party.json"))
        let outline = try HarmonyOutlineRenderer.render(roots: roots)
        let cell = try HarmonyTargetResolver.match(entries: outline.entries, screen: outline.screen, id: "2821")
        let alias = try #require(cell.aliases.list)
        let summary = try #require(outline.lists.first { $0.scope == alias.scope })
        #expect(alias.index == 9)
        #expect(summary.cellCount == 9)
        let indices = outline.entries.compactMap { entry in
            entry.aliases.list.flatMap { $0.scope == alias.scope ? $0.index : nil }
        }
        #expect(indices == [1, 2, 3, 4, 5, 6, 7, 8, 9])
        let home = try harmonyTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try OutlineCache.write(outline: outline, udid: "TESTTRANSPARENT02", home: home)
        let target = try OutlineAliasResolver.resolve("#9@\(alias.scope)", udid: "TESTTRANSPARENT02", home: home)
        #expect(target.point.x == 654 && target.point.y == 1696)
        #expect(throws: OutlineAliasResolver.ResolutionError.self) {
            try OutlineAliasResolver.resolve("#10@\(alias.scope)", udid: "TESTTRANSPARENT02", home: home)
        }
    }

    @Test("Painted popup and image backgrounds cover only their own frames",
          arguments: ["color", "six-digit", "image", "missing-color", "missing-image"])
    func paintedIslands(paint: String) throws {
        let color: String? = paint == "color" ? "#FF123456"
            : (paint == "six-digit" ? "#000000" : (paint == "missing-color" ? nil : "#00000000"))
        let image: String? = paint == "image" ? "resource://keyboard-skin.png" : (paint == "missing-image" ? nil : "empty source")
        let app = Self.node("root", bounds: "[0,0][300,300]", bundle: "com.example.fixture", children: [
            Self.node("Button", id: "near-popup", bounds: "[100,120][140,160]"),
            Self.node("Button", id: "under-popup", bounds: "[22,130][32,150]"),
            Self.node("Button", id: "under-keyboard", bounds: "[100,220][140,260]"),
        ])
        let popup = Self.node("Column", bounds: "[20,120][80,160]", backgroundColor: color, backgroundImage: image, children: [
            Self.node("Button", id: "popup-control", bounds: "[30,125][70,155]",
                      backgroundColor: "#00000000", backgroundImage: "empty source"),
        ])
        let keyboard = Self.node("root", bounds: "[0,0][300,300]", bundle: "com.huawei.hmos.inputmethod",
                                 backgroundColor: "#00000000", backgroundImage: "empty source", children: [
            Self.node("Column", bounds: "[0,100][300,300]", backgroundColor: "#00000000", backgroundImage: "empty source", children: [
                popup,
                Self.node("Row", bounds: "[0,200][300,300]", backgroundColor: "#FFE3E4E6", backgroundImage: "empty source"),
            ]),
        ])
        let outline = try HarmonyOutlineRenderer.render(roots: [app, keyboard])
        #expect(outline.entries.map(\.uniqueId) == ["near-popup", "popup-control"])
        let unfiltered = try HarmonyOutlineRenderer.render(roots: [app, keyboard], options: .init(filterOffscreen: false))
        #expect(unfiltered.entries.contains { $0.uniqueId == "under-popup" })
        #expect(unfiltered.entries.contains { $0.uniqueId == "under-keyboard" })
    }

    @Test("An all-transparent input-method subtree keeps its own bounded fallback",
          arguments: [false, true])
    func transparentFallback(otherPaintedWindow: Bool) throws {
        let app = Self.node("root", bounds: "[0,0][300,300]", bundle: "com.example.fixture", children: [
            Self.node("Button", id: "above", bounds: "[100,60][140,80]"),
            Self.node("Button", id: "covered", bounds: "[100,140][140,180]"),
        ])
        let keyboard = Self.node("root", bounds: "[0,0][300,300]", bundle: "com.huawei.hmos.inputmethod",
                                 backgroundColor: "#00000000", backgroundImage: "empty source", children: [
            Self.node("Column", bounds: "[0,100][300,300]", backgroundColor: "#00000000", backgroundImage: "empty source", children: [
                Self.node("Button", id: "ime-key", bounds: "[100,190][140,230]",
                          backgroundColor: "#00000000", backgroundImage: "empty source"),
            ]),
        ])
        var roots = [app, keyboard]
        if otherPaintedWindow {
            roots.append(Self.node("root", bounds: "[0,0][300,300]", bundle: "com.huawei.hmos.inputmethod", children: [
                Self.node("Row", bounds: "[0,250][300,300]", backgroundColor: "#FFFFFFFF", backgroundImage: "empty source"),
            ]))
        }
        let outline = try HarmonyOutlineRenderer.render(roots: roots)
        #expect(outline.entries.map(\.uniqueId) == ["above", "ime-key"])
        #expect(throws: HarmonyError.self) {
            try HarmonyTargetResolver.match(entries: outline.entries, screen: outline.screen, id: "covered")
        }
    }

    @Test("Odd-sized targets cannot cross a keyboard edge through either pixel-center convention",
          arguments: [("[79,120][120,160]", 99, 140), ("[120,79][160,120]", 140, 99),
                      ("[179,120][220,160]", 199, 140), ("[120,179][160,220]", 140, 199)])
    func oddPixelCenters(bounds: String, cachedX: Int, cachedY: Int) throws {
        let app = Self.node("root", bounds: "[0,0][300,300]", bundle: "com.example.fixture", children: [
            Self.node("Button", id: "safe", bounds: "[10,10][30,30]"),
            Self.node("Button", id: "edge", bounds: bounds),
        ])
        let keyboard = Self.node("root", bounds: "[0,0][300,300]", bundle: "com.huawei.hmos.inputmethod", children: [
            Self.node("Column", bounds: "[100,100][200,200]", children: [
                Self.node("Button", id: "ime-key", bounds: "[130,130][170,170]"),
            ]),
        ])
        let home = try harmonyTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let unfiltered = try HarmonyOutlineRenderer.render(roots: [app, keyboard], options: .init(filterOffscreen: false))
        let edge = try HarmonyTargetResolver.match(entries: unfiltered.entries, screen: unfiltered.screen, id: "edge")
        try OutlineCache.write(outline: unfiltered, udid: "TESTPIXELCENTER01", home: home)
        let rawTarget = try OutlineAliasResolver.resolve("@\(edge.aliases.at)", udid: "TESTPIXELCENTER01", home: home)
        #expect(rawTarget.point.x == Double(cachedX) && rawTarget.point.y == Double(cachedY))
        let outline = try HarmonyOutlineRenderer.render(roots: [app, keyboard])
        #expect(outline.entries.map(\.uniqueId) == ["safe", "ime-key"])
        #expect(throws: HarmonyError.self) {
            try HarmonyTargetResolver.match(entries: outline.entries, screen: outline.screen, id: "edge")
        }
        try OutlineCache.write(outline: outline, udid: "TESTPIXELCENTER01", home: home)
        for entry in outline.entries {
            let target = try OutlineAliasResolver.resolve("@\(entry.aliases.at)", udid: "TESTPIXELCENTER01", home: home)
            #expect(target.point.x != Double(cachedX) || target.point.y != Double(cachedY))
        }
    }

    private static func node(_ type: String, id: String = "", bounds: String, bundle: String? = nil,
                             visible: Bool = true, backgroundColor: String? = nil, backgroundImage: String? = nil,
                             children: [HarmonyLayoutNode] = []) -> HarmonyLayoutNode {
        var attributes = ["type": type, "id": id, "bounds": bounds, "visible": visible ? "true" : "false",
                          "text": type == "Button" || type == "ListItem" ? id : ""]
        if let bundle { attributes["bundleName"] = bundle }
        if let backgroundColor { attributes["backgroundColor"] = backgroundColor }
        if let backgroundImage { attributes["backgroundImage"] = backgroundImage }
        return HarmonyLayoutNode(attributes: attributes, children: children)
    }
}

private final class HarmonyRecordingTransport: HarmonyTransport {
    var shellCalls: [[String]] = []
    var runCalls: [[String]] = []
    var artifact = Data("{}".utf8)
    var failCapture = false
    var failTransfer = false
    var failSnapshot = false
    var output = ""
    func shell(serial: String, args: [String]) throws -> Hdc.RunResult {
        shellCalls.append(args)
        if args.first != "rm", failCapture { throw HarmonyError("capture failed") }
        if args.first == "snapshot_display", failSnapshot { throw HarmonyError("unsupported snapshot command") }
        return .init(stdout: output)
    }
    func run(args: [String], timeout: TimeInterval?) throws -> Hdc.RunResult {
        runCalls.append(args)
        if failTransfer { throw HarmonyError("transfer failed") }
        if args.count == 6, args[2] == "file", args[3] == "recv" {
            try artifact.write(to: URL(fileURLWithPath: args[5]))
        }
        return .init(stdout: "")
    }
}

@Suite("Harmony input and artifact safety")
struct HarmonyInputTests {
    @Test("Native input emits exact typed arguments, never shell concatenation")
    func inputArguments() throws {
        let transport = HarmonyRecordingTransport()
        let client = UITestClient(serial: "device1", transport: transport)
        let text = "你好 'quoted'; $(touch nope)\nnext"
        try client.type(text: text)
        try client.type(text: text, target: (10, 20))
        try client.tap(x: 40, y: 50, longPress: true)
        try client.button("back")
        #expect(transport.shellCalls == [["uitest", "uiInput", "text", text],
                                        ["uitest", "uiInput", "inputText", "10", "20", text],
                                        ["uitest", "uiInput", "longClick", "40", "50"],
                                        ["uitest", "uiInput", "keyEvent", "Back"]])
    }

    @Test("Unsupported input fails before transport and never pretends success")
    func invalidInputs() throws {
        let transport = HarmonyRecordingTransport()
        let client = UITestClient(serial: "device1", transport: transport)
        #expect(throws: (any Error).self) { try client.type(text: "erase", clear: true) }
        #expect(throws: (any Error).self) { try client.type(text: "a\0b") }
        #expect(throws: (any Error).self) { try client.tap(x: -1, y: 0) }
        #expect(throws: (any Error).self) { try client.button("volume-up") }
        #expect(throws: (any Error).self) { try client.swipe(startX: 0, startY: 0, endX: 0, endY: 0, durationMs: 100) }
        #expect(transport.shellCalls.isEmpty)
        let targeting = try TapTargetingOptions.parse(["--point", "10,20"])
        #expect(throws: (any Error).self) { try HarmonyTapCommand.performTap(serial: "device1", alias: nil, targeting: targeting, duration: 1) }
        #expect(throws: (any Error).self) { try HarmonyLongPressCommand.performLongPress(serial: "device1", alias: nil, targeting: targeting, duration: 2) }
        #expect(throws: (any Error).self) { try HarmonyTargetResolver.integerPoint(x: .infinity, y: 0) }
        #expect(throws: (any Error).self) { try HarmonyTargetResolver.integerPoint(x: .nan, y: 0) }
    }

    @Test("Swipe duration is converted to supported velocity without clamping")
    func velocity() throws {
        #expect(try UITestClient.swipeVelocity(startX: 0, startY: 0, endX: 300, endY: 400, durationMs: 500) == 1000)
        #expect(throws: (any Error).self) { try UITestClient.swipeVelocity(startX: 0, startY: 0, endX: 10, endY: 0, durationMs: 1000) }
        #expect(throws: (any Error).self) { try UITestClient.swipeVelocity(startX: 0, startY: 0, endX: 1000, endY: 0, durationMs: 1) }
        #expect(throws: (any Error).self) { try UITestClient.swipeVelocity(startX: 0, startY: 0, endX: 100, endY: 0, durationMs: 0) }
    }

    @Test("Dump uses unique remote paths and removes both remote and local artifacts")
    func artifacts() throws {
        let transport = HarmonyRecordingTransport()
        transport.artifact = try harmonyFixture("home.json")
        let client = UITestClient(serial: "device1", transport: transport)
        _ = try client.dumpLayout()
        _ = try client.dumpLayout()
        let captures = transport.shellCalls.filter { $0.first == "uitest" }
        #expect(captures.count == 2)
        #expect(captures[0].last != captures[1].last)
        for call in transport.runCalls {
            #expect(call[4].hasPrefix("/data/local/tmp/sim-use-"))
            #expect(transport.shellCalls.contains(["rm", "-f", call[4]]))
            #expect(!FileManager.default.fileExists(atPath: call[5]))
        }
        #expect(!transport.shellCalls.contains { $0.contains("keyEvent") })
    }

    @Test("Artifact cleanup runs on capture and transfer failures")
    func failedArtifacts() {
        for transfer in [false, true] {
            let transport = HarmonyRecordingTransport()
            transport.failCapture = !transfer
            transport.failTransfer = transfer
            #expect(throws: (any Error).self) { try UITestClient(serial: "device1", transport: transport).dumpLayout() }
            #expect(transport.shellCalls.last?.first == "rm")
            for call in transport.runCalls { #expect(!FileManager.default.fileExists(atPath: call[5])) }
        }
    }

    @Test("Screenshot falls back with a new artifact and rejects invalid image data")
    func screenshotFallback() throws {
        let transport = HarmonyRecordingTransport()
        transport.failSnapshot = true
        transport.artifact = try harmonyPNG()
        let capture = try UITestClient(serial: "device1", transport: transport).screenshot()
        #expect(capture.fileExtension == "png")
        #expect(transport.shellCalls.contains { Array($0.prefix(2)) == ["uitest", "screenCap"] })
        #expect(transport.shellCalls.filter { $0.first == "rm" }.count == 2)
        let jpeg = try HarmonyScreenshotCommand.encodedImage(capture, fileExtension: "jpeg")
        #expect(jpeg.starts(with: [0xff, 0xd8, 0xff]))
        let converted = try UITestClient.capture(jpeg)
        let png = try HarmonyScreenshotCommand.encodedImage(converted, fileExtension: "png")
        #expect(png.starts(with: [0x89, 0x50, 0x4e, 0x47]))
        #expect(throws: (any Error).self) { try UITestClient.capture(Data("not an image".utf8)) }
    }

    @Test("Success advisory is hoisted, not duplicated in data")
    func pasteboardAdvisory() throws {
        let result = HarmonyTypeCommand.ExecutionResult()
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(json == "{}")
        #expect(result.commandAdvisory?.kind == .pasteboardReplaced)
        #expect(result.commandAdvisory?.message.contains("cannot be restored") == true)
    }

    @Test("Device options use only explicit flags or environment and preserve namespace override")
    func explicitDevice() throws {
        #expect(try HarmonyDeviceOptions.select(device: " odd-name ", udid: nil, environment: [:]) == "odd-name")
        #expect(try HarmonyDeviceOptions.select(device: nil, udid: nil, environment: ["SIM_USE_DEVICE": "device1"]) == "device1")
        #expect(try HarmonyDeviceOptions.select(device: nil, udid: nil, environment: ["SIM_USE_UDID": "device2"]) == "device2")
        #expect(throws: (any Error).self) { try HarmonyDeviceOptions.select(device: nil, udid: nil, environment: [:]) }
        #expect(throws: (any Error).self) { try HarmonyDeviceOptions.select(device: nil, udid: nil, environment: ["SIM_USE_DEVICE": "one", "SIM_USE_UDID": "two"]) }
        #expect(try HarmonyDeviceOptions.select(device: "flag", udid: nil, environment: ["SIM_USE_DEVICE": "one", "SIM_USE_UDID": "two"]) == "flag")
        #expect(throws: (any Error).self) { try HarmonyDeviceOptions.select(device: "one", udid: "two", environment: [:]) }
    }
}

@Suite("Harmony transport safety")
struct HarmonyTransportTests {
    @Test("Targets and connection identities are deterministic")
    func targets() throws {
        #expect(try Hdc.parseTargets("TESTHARMONY000001\n127.0.0.1:1234\n") == ["TESTHARMONY000001", "127.0.0.1:1234"])
        #expect(try Hdc.parseTargets("[Empty]\n").isEmpty)
        #expect(throws: (any Error).self) { try Hdc.parseTargets("[Fail] No server") }
        #expect(Hdc.connectionIdentity(environment: [:]) == "hdc:8710")
        #expect(Hdc.connectionIdentity(environment: ["OHOS_HDC_SERVER_PORT": "192.0.2.1:9000"]) == "hdc:192.0.2.1:9000")
        #expect(Hdc.discover(environment: ["SIM_USE_HDC": "/explicit/hdc", "PATH": "/bin"]) == "/explicit/hdc")
    }

    @Test("Membership caches successful snapshots by binary and connection identity")
    func membershipCache() throws {
        let binary = "membership-cache-" + UUID().uuidString
        let hdc = Hdc(binaryPath: binary, environment: [:])
        var targets = ["device1"]
        var calls = 0
        func listTargets(_: TimeInterval) -> [String] {
            calls += 1
            return targets
        }
        #expect(try Hdc.isKnownTarget("device1", using: hdc, listTargets: listTargets))
        targets = []
        #expect(try Hdc.isKnownTarget("device1", using: hdc, listTargets: listTargets))
        #expect(try !Hdc.isKnownTarget("device2", using: hdc, listTargets: listTargets))
        #expect(calls == 1)
        let otherConnection = Hdc(binaryPath: binary, environment: ["OHOS_HDC_SERVER_PORT": "9000"])
        #expect(try !Hdc.isKnownTarget("device1", using: otherConnection, listTargets: listTargets))
        #expect(calls == 2)
        targets = ["device2"]
        let otherBinary = Hdc(binaryPath: binary + "-other", environment: [:])
        #expect(try Hdc.isKnownTarget("device2", using: otherBinary, listTargets: listTargets))
        #expect(calls == 3)
    }

    @Test("Fresh listing sees disconnects without changing cached membership")
    func freshListing() throws {
        let directory = try harmonyTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("hdc")
        try Data("#!/bin/sh\nprintf 'device1\\n'\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let hdc = Hdc(binaryPath: script.path, environment: [:])
        let connectedTargets = try hdc.listTargets()
        #expect(connectedTargets == ["device1"])
        #expect(try Hdc.isKnownTarget("device1", using: hdc) { _ in connectedTargets })
        try Data("#!/bin/sh\nprintf '[Empty]\\n'\n".utf8).write(to: script)
        #expect(try hdc.listTargets().isEmpty)
        #expect(try Hdc.isKnownTarget("device1", using: hdc) { _ in
            Issue.record("A successful membership snapshot must not be reloaded")
            return []
        })
    }

    @Test("Empty membership is cached, while failed discovery propagates and remains retryable")
    func membershipFailures() throws {
        enum DiscoveryFailure: Error { case unavailable }
        let binary = "membership-failure-" + UUID().uuidString
        let empty = Hdc(binaryPath: binary, environment: [:])
        #expect(try !Hdc.isKnownTarget("device1", using: empty) { _ in [] })
        let failing = Hdc(binaryPath: binary, environment: ["OHOS_HDC_SERVER_PORT": "9001"])
        #expect(throws: DiscoveryFailure.self) {
            try Hdc.isKnownTarget("device1", using: failing) { _ in throw DiscoveryFailure.unavailable }
        }
        #expect(try Hdc.isKnownTarget("device1", using: failing) { _ in ["device1"] })
        #expect(try !Hdc.isKnownTarget("device1", using: empty) { _ in
            Issue.record("An empty successful snapshot must remain cached")
            return ["device1"]
        })
        #expect(throws: HarmonyError.self) {
            try Hdc.isKnownTarget("device1", using: Hdc(binaryPath: "/absent-" + UUID().uuidString))
        }
    }

    @Test("Membership passes a 3-second discovery budget independent of business timeouts")
    func membershipDeadline() throws {
        let binary = "membership-deadline-" + UUID().uuidString
        #expect(Hdc(binaryPath: binary).defaultTimeout == 30)
        let hdc = Hdc(binaryPath: binary, defaultTimeout: 0.05)
        var budgets: [TimeInterval] = []
        #expect(try !Hdc.isKnownTarget("device1", using: hdc) { timeout in
            budgets.append(timeout)
            return []
        })
        #expect(budgets == [3])
        #expect(hdc.defaultTimeout == 0.05)
    }

    @Test("The process runner enforces the short deadline independently of membership")
    func processDeadline() {
        let start = Date()
        do {
            _ = try Hdc(binaryPath: "/bin/sleep").run(args: ["10"], timeout: 1.5)
            Issue.record("A sleeping child must time out")
        } catch let error as HarmonyError {
            #expect(error.message.contains("timed out after 1.5 seconds"))
        } catch { Issue.record(error) }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed >= 1.4)
        #expect(elapsed < 4)
        do {
            _ = try Hdc(binaryPath: "/bin/sleep", defaultTimeout: 0.05).run(args: ["10"])
            Issue.record("The configured business timeout must be enforced")
        } catch let error as HarmonyError {
            #expect(error.message.contains("timed out after 0.05 seconds"))
        } catch { Issue.record(error) }
    }

    @Test("An immediate native process completes under the short discovery deadline")
    func immediateProcess() throws {
        let value = "native-target"
        let result = try Hdc(binaryPath: "/usr/bin/printf").run(args: ["%s\\n", value], timeout: 1.5)
        #expect(result.stdout == value + "\n")
    }

    @Test("Remote status is mandatory even when hdc exits zero")
    func remoteStatus() throws {
        #expect(try Hdc.decodeShellResult(.init(stdout: "value\nMARK:0\n"), marker: "MARK").stdout == "value")
        for output in ["", "value", "MARK:1\n", "MARK:no\n", "MARK:0\ntrailing"] {
            #expect(throws: (any Error).self) { try Hdc.decodeShellResult(.init(stdout: output), marker: "MARK") }
        }
        for output in ["[Fail] device absent", "error: invalid suffix", "Missing parameter", "Error code: 17000002"] {
            #expect(Hdc.reportsFailure(output))
            #expect(throws: (any Error).self) { try UITestClient.validateToolOutput(output) }
        }
    }

    @Test("Quoting keeps spaces, quotes, Unicode and shell metacharacters literal")
    func quoting() throws {
        let directory = try harmonyTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("hdc")
        try Data("#!/bin/sh\nshift 3\nexec /bin/sh -c \"$1\"\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let hdc = Hdc(binaryPath: script.path)
        let text = "你好 ' $HOME; $(echo injected)\nnext"
        let result = try hdc.shell(serial: "device1", args: ["printf", "%s", text])
        #expect(result.stdout == text)
        #expect(Hdc.shellQuote("a'b") == "'a'\\''b'")
        #expect(throws: (any Error).self) { try hdc.shell(serial: "-target", args: ["echo"]) }
        #expect(throws: (any Error).self) { try hdc.shell(serial: "device1", args: ["echo", "a\0b"]) }
    }

    @Test("Timeout cleanup stays bounded for a TERM-ignoring command")
    func timeout() {
        let hdc = Hdc(binaryPath: "/bin/sh", defaultTimeout: 0.05)
        let start = Date()
        #expect(throws: HarmonyError.self) {
            try hdc.run(args: ["-c", "trap '' TERM\nwhile :; do :; done\n"])
        }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test("Large output does not fill a pipe and zero-exit error text fails")
    func capture() throws {
        let directory = try harmonyTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("hdc")
        try Data("#!/bin/sh\ni=0; while [ $i -lt 10000 ]; do printf 'abcdefghijklmnopqrstuvwxyz0123456789\\n'; i=$((i+1)); done\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let result = try Hdc(binaryPath: script.path).run(args: [])
        #expect(result.stdout.utf8.count > 300_000)
        try Data("#!/bin/sh\nprintf 'error: rejected\\n'\nexit 0\n".utf8).write(to: script)
        #expect(throws: (any Error).self) { try Hdc(binaryPath: script.path).run(args: []) }
    }
}
#endif
