import AppKit
import Foundation
import SwiftUI

/// Draws every setup state into a bitmap with no window on screen.
extension SetupChecks {
    static func renderStates() throws {
        let out = AppEnvironment.arg("--setup-self-test-out")
        if let out { try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true) }
        for name in SetupPreview.names {
            for dark in [false, true] {
                guard let flow = SetupPreview.flow(named: name) else { throw Failure(description: "No preview \(name)") }
                guard let rep = render(SetupSheetContent(flow: flow, close: { _ in }), dark: dark) else { throw Failure(description: "Cannot render \(name)") }
                try expect(distinctColors(rep) > 4, "State \(name) rendered blank")
                if let out, let png = rep.representation(using: .png, properties: [:]) {
                    try png.write(to: URL(fileURLWithPath: out + "/\(name)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    /// Draws a view into a bitmap with no window on screen, at 2x for a sharp comparison.
    static func render<V: View>(_ view: V, dark: Bool, scale: CGFloat = 2) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: SetupSheetContent.size)
        host.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * scale), pixelsHigh: Int(host.bounds.height * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    static func distinctColors(_ rep: NSBitmapImageRep) -> Int {
        var colors = Set<String>()
        for x in stride(from: 4, to: rep.pixelsWide, by: 31) {
            for y in stride(from: 4, to: rep.pixelsHigh, by: 19) {
                if let c = rep.colorAt(x: x, y: y) { colors.insert("\(Int(c.redComponent * 20))\(Int(c.greenComponent * 20))\(Int(c.blueComponent * 20))") }
            }
        }
        return colors.count
    }
}
