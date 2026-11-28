import AppKit
import SwiftUI
import Testing
@testable import NoodleApp

/// Design rules that can be checked without a window: row actions and motion.
@MainActor @Suite(.serialized) struct RowAndMotionRuleTests {
    /// No dropdown arrows on "..." menus: every Menu hides its indicator.
    @Test func everyMenuHidesItsIndicator() throws {
        var offenders: [String] = []
        for file in AppSources.swiftFiles {
            let lines = try AppSources.lines(file)
            for (i, line) in lines.enumerated() where line.range(of: #"(^|[^A-Za-z])Menu\("#, options: .regularExpression) != nil {
                let window = lines[i..<min(i + 4, lines.count)].joined()
                if !window.contains(".menuIndicator(.hidden)") { offenders.append("\(file.lastPathComponent):\(i + 1)") }
            }
        }
        #expect(offenders.isEmpty, "Menu without .menuIndicator(.hidden): \(offenders)")
    }

    /// Springs everywhere, and Reduce Motion respected: no bare withAnimation, and any raw .animation names reduceMotion.
    @Test func animationsGoThroughMotionOrReduceMotion() throws {
        var offenders: [String] = []
        for file in AppSources.swiftFiles where file.lastPathComponent != "Motion.swift" {
            let lines = try AppSources.lines(file)
            for (i, line) in lines.enumerated() {
                if line.contains("withAnimation(") { offenders.append("\(file.lastPathComponent):\(i + 1) withAnimation") }
                if line.contains(".animation("), !line.contains("reduceMotion") { offenders.append("\(file.lastPathComponent):\(i + 1) .animation") }
                if line.contains("easeIn") || line.contains("easeOut") || (line.contains(".linear") && !line.contains("progressViewStyle(.linear)")) || line.contains(".easeInOut") {
                    offenders.append("\(file.lastPathComponent):\(i + 1) easing curve")
                }
            }
        }
        #expect(offenders.isEmpty, "Motion rule: \(offenders)")
    }

    @Test func motionTokensAreSprings() {
        // Reduce Motion swaps springs for a 0.12 s fade; everything else is a spring.
        #expect(String(describing: Motion.snappy).contains("spring") || String(describing: Motion.snappy).contains("Spring"))
        #expect(String(describing: Motion.standard).lowercased().contains("spring"))
        #expect(String(describing: Motion.heavy).lowercased().contains("spring"))
    }

    /// Start is green, stop is red.
    @Test func startIsGreenAndStopIsRed() async {
        let running = await RenderHarness.render(RowActionButton(running: true, subject: "x") {}.padding(8), name: "row-action-stop",
                                                 size: CGSize(width: 60, height: 40))
        let stopped = await RenderHarness.render(RowActionButton(running: false, subject: "x") {}.padding(8), name: "row-action-start",
                                                 size: CGSize(width: 60, height: 40))
        let stop = RenderHarness.tint(running.png)
        let start = RenderHarness.tint(stopped.png)
        #expect(stop.red > 20 && stop.green == 0, "stop control is not red: \(stop)")
        #expect(start.green > 20 && start.red == 0, "start control is not green: \(start)")
    }

    /// A control looks different under the pointer: the hover fill sits between rest and pressed.
    @Test func controlSurfaceChangesOnHover() async throws {
        func png(_ name: String, hovered: Bool, pressed: Bool = false) async throws -> Data {
            let view = Text("Run").padding(.horizontal, 12).controlSurface(pressed: pressed, hovered: hovered).padding(8)
            let r = await RenderHarness.render(view, name: name, size: CGSize(width: 80, height: 48), dark: true, recognizeText: false)
            return try Data(contentsOf: r.png)
        }
        let rest = try await png("control-rest", hovered: false)
        let hover = try await png("control-hover", hovered: true)
        let pressed = try await png("control-pressed", hovered: true, pressed: true)
        #expect(rest != hover, "hover looks the same as rest")
        #expect(hover != pressed, "pressed looks the same as hover")
    }
}
