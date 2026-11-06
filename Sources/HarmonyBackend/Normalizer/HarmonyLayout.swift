// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

public struct HarmonyLayoutNode: Codable, Equatable, Sendable {
    public let attributes: [String: String]
    public let children: [HarmonyLayoutNode]

    public init(attributes: [String: String], children: [HarmonyLayoutNode] = []) {
        self.attributes = attributes
        self.children = children
    }

    enum CodingKeys: String, CodingKey { case attributes, children }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attributes = try container.decode([String: String].self, forKey: .attributes)
        children = try container.decodeIfPresent([HarmonyLayoutNode].self, forKey: .children) ?? []
    }

    public var type: String { attributes["type"] ?? "" }
    public var text: String { attributes["text"] ?? "" }
    public var label: String {
        let description = attributes["description"] ?? ""
        return description.isEmpty ? text : description
    }
    public var id: String? {
        [attributes["id"], attributes["key"], attributes["accessibilityId"]].compactMap { $0 }.first { !$0.isEmpty }
    }
    public func flag(_ name: String) -> Bool { attributes[name] == "true" }
    public var frame: Outline.Frame? { Self.parseBounds(attributes["bounds"] ?? "") }

    private static let boundsPattern = try! NSRegularExpression(pattern: #"^\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]$"#)
    public static func parseBounds(_ bounds: String) -> Outline.Frame? {
        let range = NSRange(bounds.startIndex..<bounds.endIndex, in: bounds)
        guard let match = boundsPattern.firstMatch(in: bounds, range: range) else { return nil }
        var values: [Int] = []
        for index in 1...4 {
            guard let range = Range(match.range(at: index), in: bounds), let value = Int(bounds[range]),
                  (-1_000_000...1_000_000).contains(value) else { return nil }
            values.append(value)
        }
        guard values[2] >= values[0], values[3] >= values[1] else { return nil }
        return .init(x: values[0], y: values[1], width: values[2] - values[0], height: values[3] - values[1])
    }

    public static func decode(_ data: Data) throws -> [HarmonyLayoutNode] {
        let decoder = JSONDecoder()
        let roots: [HarmonyLayoutNode]
        if data.first(where: { ![9, 10, 13, 32].contains($0) }) == 91 {
            roots = try decoder.decode([HarmonyLayoutNode].self, from: data)
        } else {
            roots = [try decoder.decode(HarmonyLayoutNode.self, from: data)]
        }
        guard !roots.isEmpty, roots.contains(where: { $0.frame != nil }) else {
            throw HarmonyError("Harmony layout has no window with valid bounds.")
        }
        return roots
    }
}

public enum HarmonyClassifier {
    public static func role(_ node: HarmonyLayoutNode) -> String {
        switch node.type {
        case "Button": return "Button"
        case "TextInput", "TextArea", "Search", "SearchField": return "TextField"
        case "Text", "Span", "TextClock", "RichEditor": return "TextView"
        case "Toggle", "Switch": return "Switch"
        case "Checkbox", "CheckboxGroup", "Radio": return "Checkbox"
        case "Image", "SymbolGlyph": return node.flag("clickable") ? "Button" : "Image"
        case "List", "Grid": return "List"
        case "ListItem", "GridItem": return "Cell"
        case "Scroll", "Swiper": return "ScrollView"
        case "Slider": return "Slider"
        case "Progress", "LoadingProgress": return "ProgressBar"
        case "Navigation", "NavBar": return "NavigationBar"
        case "Hyperlink": return "Link"
        default: return node.flag("clickable") ? "Button" : "View"
        }
    }
}

public enum HarmonyOutlineRenderer {
    public struct RendererOptions: Sendable {
        public var filterOffscreen: Bool
        public init(filterOffscreen: Bool = true) { self.filterOffscreen = filterOffscreen }
        public static let `default` = RendererOptions()
    }

    public static func appPackage(roots: [HarmonyLayoutNode]) -> String {
        var bundles: [String] = []
        func visit(_ node: HarmonyLayoutNode) {
            if let bundle = node.attributes["bundleName"], !bundle.isEmpty, !bundles.contains(bundle) { bundles.append(bundle) }
            node.children.forEach(visit)
        }
        roots.forEach(visit)
        return bundles.first { !$0.hasPrefix("com.ohos.") && !$0.contains("inputmethod") }
            ?? bundles.first ?? "HarmonyOS"
    }

    public static func hasSystemDialog(roots: [HarmonyLayoutNode]) -> Bool {
        func visit(_ node: HarmonyLayoutNode, inheritedBundle: String) -> Bool {
            let bundle = node.attributes["bundleName"].flatMap { $0.isEmpty ? nil : $0 } ?? inheritedBundle
            if node.attributes["visible"] == "false" { return false }
            let identity = [node.type, node.attributes["id"] ?? "", node.attributes["key"] ?? ""].joined(separator: " ").lowercased()
            if bundle == "com.ohos.sceneboard", identity.contains("dialog") { return true }
            return node.children.contains { visit($0, inheritedBundle: bundle) }
        }
        return roots.contains { visit($0, inheritedBundle: "") }
    }

    private static func hasTransparentBackground(_ node: HarmonyLayoutNode) -> Bool {
        guard node.attributes["backgroundImage"] == "empty source",
              let color = node.attributes["backgroundColor"], color.utf8.count == 9,
              color.hasPrefix("#00") else { return false }
        return UInt32(color.dropFirst(), radix: 16) != nil
    }

    // Transparent wrappers do not cover content. If an entire input-method
    // subtree has no painted geometry, retain the previous bounded fallback.
    // See docs/ai/012-harmonyos-backend/005-transparent-keyboard-geometry.md.
    private static func keyboardFrames(roots: [HarmonyLayoutNode], screen: Outline.Frame) -> [Outline.Frame] {
        var frames: [Outline.Frame] = []
        func collect(_ node: HarmonyLayoutNode, inheritedBundle: String, skipTransparent: Bool) {
            guard node.attributes["visible"] != "false" else { return }
            let bundle = node.attributes["bundleName"].flatMap { $0.isEmpty ? nil : $0 } ?? inheritedBundle
            if bundle.contains("inputmethod"), (!skipTransparent || !hasTransparentBackground(node)),
               let frame = node.frame {
                let left = max(0, frame.x), top = max(0, frame.y)
                let right = min(screen.width, frame.x + frame.width)
                let bottom = min(screen.height, frame.y + frame.height)
                if right > left, bottom > top,
                   left > 0 || top > 0 || right < screen.width || bottom < screen.height {
                    frames.append(.init(x: left, y: top, width: right - left, height: bottom - top))
                    return
                }
            }
            for child in node.children { collect(child, inheritedBundle: bundle, skipTransparent: skipTransparent) }
        }
        func visit(_ node: HarmonyLayoutNode, inheritedBundle: String) {
            guard node.attributes["visible"] != "false" else { return }
            let bundle = node.attributes["bundleName"].flatMap { $0.isEmpty ? nil : $0 } ?? inheritedBundle
            if bundle.contains("inputmethod") {
                let start = frames.count
                collect(node, inheritedBundle: bundle, skipTransparent: true)
                if frames.count == start {
                    collect(node, inheritedBundle: bundle, skipTransparent: false)
                }
                return
            }
            for child in node.children { visit(child, inheritedBundle: bundle) }
        }
        for root in roots { visit(root, inheritedBundle: "") }
        return frames
    }

    private static func screenBounds(roots: [HarmonyLayoutNode]) throws -> Outline.Frame {
        let rootFrames = roots.compactMap(\.frame)
        guard let maxX = rootFrames.map({ $0.x + $0.width }).max(),
              let maxY = rootFrames.map({ $0.y + $0.height }).max(), maxX > 0, maxY > 0 else {
            throw HarmonyError("Harmony layout does not describe a valid screen.")
        }
        return .init(x: 0, y: 0, width: maxX, height: maxY)
    }

    private static func context(_ node: HarmonyLayoutNode, parentBundle: String, parentKeyboard: Bool) -> (bundle: String, keyboard: Bool) {
        let bundle = node.attributes["bundleName"].flatMap { $0.isEmpty ? nil : $0 } ?? parentBundle
        let systemPanel = bundle == "com.ohos.sceneboard" && node.type == "WindowScene"
            && (node.attributes["id"]?.hasPrefix("keyboardPanel") == true
                || node.attributes["key"]?.hasPrefix("keyboardPanel") == true)
        return (bundle, bundle.contains("inputmethod") || systemPanel || (parentKeyboard && bundle == parentBundle))
    }

    private static func isMeaningful(_ node: HarmonyLayoutNode, role: String) -> Bool {
        !node.label.isEmpty || node.flag("clickable") || node.flag("longClickable")
            || node.flag("scrollable") || role == "TextField" || role == "Cell" || role == "List"
            || role == "Switch" || role == "Checkbox" || role == "Slider"
    }

    private static func contains(_ frame: Outline.Frame, x: Int, y: Int) -> Bool {
        x >= frame.x && x < frame.x + frame.width && y >= frame.y && y < frame.y + frame.height
    }

    static let offscreenTargetHint = "Use scroll to bring the target into view, then run describe-ui again before input."

    static func validateTargetPoint(_ point: (x: Int, y: Int), screen: Outline.Frame) throws {
        guard contains(screen, x: point.x, y: point.y) else {
            throw HarmonyError("Harmony target point (\(point.x), \(point.y)) is outside the \(screen.width)x\(screen.height) screen.",
                               hint: offscreenTargetHint)
        }
    }

    // The cache has no node ID. Require a complete structural match, not
    // merely a keyboard key under the old point. Never refresh the cache here.
    // See docs/ai/012-harmonyos-backend/006-live-target-safety.md.
    static func validateCachedTarget(_ entry: OutlineCache.Payload.Entry, point: (x: Int, y: Int),
                                     roots: [HarmonyLayoutNode]) throws {
        let screen = try screenBounds(roots: roots)
        try validateTargetPoint(point, screen: screen)
        let panels = keyboardFrames(roots: roots, screen: screen)
        guard panels.contains(where: { contains($0, x: point.x, y: point.y) }) else { return }
        let cachedFrame = Outline.Frame(x: entry.x - entry.w / 2, y: entry.y - entry.h / 2, width: entry.w, height: entry.h)
        var keyboardMatch = false
        var appMatch = false
        func visit(_ node: HarmonyLayoutNode, parentBundle: String, parentKeyboard: Bool) {
            guard node.attributes["visible"] != "false" else { return }
            let state = context(node, parentBundle: parentBundle, parentKeyboard: parentKeyboard)
            let role = HarmonyClassifier.role(node)
            if role == entry.role, node.label == entry.label, node.frame == cachedFrame,
               cachedFrame.width > 0, cachedFrame.height > 0, isMeaningful(node, role: role) {
                if state.keyboard {
                    if node.attributes["enabled"] != "false" { keyboardMatch = true }
                } else {
                    appMatch = true
                }
            }
            for child in node.children { visit(child, parentBundle: state.bundle, parentKeyboard: state.keyboard) }
        }
        for root in roots { visit(root, parentBundle: "", parentKeyboard: false) }
        guard keyboardMatch && !appMatch else {
            throw HarmonyError("The cached Harmony target is covered by the current keyboard.",
                               hint: "Run describe-ui again and choose a currently visible target before input.")
        }
    }

    public static func render(roots: [HarmonyLayoutNode], options: RendererOptions = .default) throws -> Outline {
        let screen = try screenBounds(roots: roots)
        let maxX = screen.width, maxY = screen.height
        let app = appPackage(roots: roots)
        let keyboardFrames = options.filterOffscreen ? Self.keyboardFrames(roots: roots, screen: screen) : []
        func isVisible(_ frame: Outline.Frame) -> Bool {
            frame.width > 0 && frame.height > 0 && frame.x < maxX && frame.y < maxY
                && frame.x + frame.width > 0 && frame.y + frame.height > 0
        }
        func isCovered(_ frame: Outline.Frame) -> Bool {
            let cachedX = frame.x + frame.width / 2, cachedY = frame.y + frame.height / 2
            let selectorX = Int((Double(frame.x) + Double(frame.width) / 2).rounded())
            let selectorY = Int((Double(frame.y) + Double(frame.height) / 2).rounded())
            // Cached aliases truncate their center; selectors round. Neither
            // actual device-pixel target may land on the keyboard.
            return keyboardFrames.contains { panel in
                contains(panel, x: cachedX, y: cachedY) || contains(panel, x: selectorX, y: selectorY)
            }
        }
        var entries: [Outline.Entry] = []
        var lists: [Outline.ListSummary] = []
        func walk(_ node: HarmonyLayoutNode, depth: Int, listAlias: Outline.ListAlias? = nil,
                  parentBundle: String = "", parentKeyboard: Bool = false, knownFrame: Outline.Frame? = nil) {
            if options.filterOffscreen && node.attributes["visible"] == "false" { return }
            let role = HarmonyClassifier.role(node)
            let frame = knownFrame ?? node.frame
            let state = keyboardFrames.isEmpty ? (bundle: "", keyboard: false)
                : context(node, parentBundle: parentBundle, parentKeyboard: parentKeyboard)
            let visible = frame.map { isVisible($0) && (keyboardFrames.isEmpty || state.keyboard || !isCovered($0)) } ?? false
            let meaningful = isMeaningful(node, role: role)
            if let frame, meaningful, (!options.filterOffscreen || visible) {
                var states = [String]()
                for flag in ["focused", "selected", "checked"] where node.flag(flag) { states.append(flag) }
                if node.attributes["enabled"] == "false" { states.append("disabled") }
                let band = max(1, screen.height / 10)
                let region = frame.y + frame.height <= band ? "Top" : (frame.y >= maxY - band ? "Bottom" : "Content")
                entries.append(.init(aliases: .init(at: entries.count + 1, list: listAlias), role: role,
                                     label: node.label, frame: frame, region: .init(kind: region), states: states,
                                     uniqueId: node.id, value: node.text.isEmpty ? nil : node.text,
                                     resourceId: node.attributes["id"].flatMap { $0.isEmpty ? nil : $0 },
                                     hint: node.attributes["hint"].flatMap { $0.isEmpty ? nil : $0 }, depth: depth))
            }
            var scope: Int?
            var cells: [(offset: Int, frame: Outline.Frame)] = []
            if role == "List", let frame {
                for (offset, child) in node.children.enumerated() {
                    guard HarmonyClassifier.role(child) == "Cell", let cellFrame = child.frame else { continue }
                    if !keyboardFrames.isEmpty {
                        let childState = context(child, parentBundle: state.bundle, parentKeyboard: state.keyboard)
                        guard child.attributes["visible"] != "false", isVisible(cellFrame),
                              childState.keyboard || !isCovered(cellFrame) else { continue }
                    }
                    cells.append((offset, cellFrame))
                }
                if let first = cells.first {
                    let next = lists.count + 1
                    scope = next
                    lists.append(.init(scope: next, cellCount: cells.count, cellHeight: first.frame.height,
                                       containerRole: role, containerLabel: node.label.isEmpty ? nil : node.label,
                                       bbox: frame, score: Double(cells.count)))
                }
            }
            var cellIndex = 0
            for (offset, child) in node.children.enumerated() {
                var alias: Outline.ListAlias?
                var cellFrame: Outline.Frame?
                if let scope, cellIndex < cells.count, cells[cellIndex].offset == offset {
                    cellFrame = cells[cellIndex].frame
                    cellIndex += 1
                    alias = .init(scope: scope, index: cellIndex)
                }
                walk(child, depth: depth + (meaningful ? 1 : 0), listAlias: alias,
                     parentBundle: state.bundle, parentKeyboard: state.keyboard, knownFrame: cellFrame)
            }
        }
        roots.forEach { walk($0, depth: 0) }
        // Alias numbers follow the same region/y/x print order as the shared outline surface.
        let regionOrder = ["Top": 0, "Content": 1, "Bottom": 2]
        entries.sort {
            let left = regionOrder[$0.region.kind, default: 1]
            let right = regionOrder[$1.region.kind, default: 1]
            if left != right { return left < right }
            if $0.frame.y != $1.frame.y { return $0.frame.y < $1.frame.y }
            if $0.frame.x != $1.frame.x { return $0.frame.x < $1.frame.x }
            return $0.aliases.at < $1.aliases.at
        }
        entries = entries.enumerated().map { index, entry in
            .init(aliases: .init(at: index + 1, list: entry.aliases.list), role: entry.role,
                  label: entry.label, frame: entry.frame, region: entry.region, states: entry.states,
                  uniqueId: entry.uniqueId, value: entry.value, resourceId: entry.resourceId,
                  hint: entry.hint, depth: entry.depth)
        }
        var lines: [String] = []
        if hasSystemDialog(roots: roots) {
            lines.append("[!] Harmony system dialog (com.ohos.sceneboard) is visible. Review it before input; sim-use never dismisses it automatically.")
        }
        lines.append("App: \(app)  \(screen.width)x\(screen.height)")
        for region in ["Top", "Content", "Bottom"] {
            let group = entries.filter { $0.region.kind == region }
            guard !group.isEmpty else { continue }
            let band = max(1, screen.height / 10)
            switch region {
            case "Top": lines.append("\n[Top  y<\(band)]")
            case "Bottom": lines.append("\n[Bottom  y>=\(screen.height - band)]")
            default: lines.append("\n[Content  y=\(band)..\(screen.height - band)]")
            }
            for entry in group {
                let frame = entry.frame
                let collapsed = SelectorTextMatcher.collapseWhitespace(entry.label)
                let truncated = collapsed.count > 60 ? String(collapsed.prefix(59)) + "…" : collapsed
                let label = truncated.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let states = entry.states.map { "  \($0)" }.joined()
                let list = entry.aliases.list.map { $0.scope == 1 ? " #\($0.index)" : " #\($0.index)@\($0.scope)" } ?? ""
                let identifier = entry.uniqueId.map { "  #\($0)" } ?? ""
                let indent = String(repeating: " ", count: min(entry.depth, 2) * 2)
                lines.append("  \(indent)@\(entry.aliases.at)\(list)  \(entry.role)  \"\(label)\"\(identifier)  (\(frame.x),\(frame.y) \(frame.width)x\(frame.height))\(states)")
            }
        }
        return Outline(text: lines.joined(separator: "\n"), entries: entries, lists: lists, screen: screen, appLabel: app)
    }
}
