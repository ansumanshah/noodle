import AppKit
import Vision
import SwiftUI
import Testing
@testable import NoodleApp

/// Headless page rendering. The window is never ordered in, so nothing appears on screen, nothing is fronted
/// and no accessibility permission is involved: the tree is read in process.
@MainActor
enum RenderHarness {
    struct Result {
        let text: String
        let labels: [String]
        let inkRatio: Double
        let png: URL
        func contains(_ s: String) -> Bool {
            let wrapped = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            let needle = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            return wrapped.localizedCaseInsensitiveContains(needle)
        }
    }

    static var outputDir: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }   // app/tests/NoodleAppTests/RenderHarness.swift -> app package root
        return url.appendingPathComponent(".build/render", isDirectory: true)
    }

    /// One shared demo environment. NOODLE_HOME points at a throwaway folder so nothing touches real data.
    static let env: AppEnvironment = {
        setenv("NOODLE_DEMO", "1", 0)   // keep NOODLE_DEMO=empty for the empty-state renders
        setenv("NOODLE_NO_ACTIVATE", "1", 1)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-render-\(getpid())")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let sampleLog = "2026-11-10T08:00:00Z noodled started\n2026-11-10T08:00:01Z ready for requests\n"
        try? sampleLog.write(to: home.appendingPathComponent("noodled.log"), atomically: true, encoding: .utf8)
        setenv("NOODLE_HOME", home.path, 1)
        return AppEnvironment.shared
    }()

    static func render<V: View>(_ view: V, name: String, size: CGSize = CGSize(width: 900, height: 560),
                                dark: Bool = false, compositeAppKitControls: Bool = true,
                                recognizeText: Bool = true,
                                settle: Duration = .milliseconds(900)) async -> Result {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance   // this test process only
        window.appearance = appearance
        host.appearance = appearance
        window.contentView = host
        window.setContentSize(size)
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: settle / 4)
        }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let rep = capture(host, size: size, dark: dark, compositeAppKitControls: compositeAppKitControls)
        if ProcessInfo.processInfo.environment["RENDER_TREE"] != nil { dump(host, 0) }
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let png = outputDir.appendingPathComponent(name + ".png")
        try? rep.representation(using: .png, properties: [:])?.write(to: png)

        var labels: [String] = []
        collect(host, into: &labels, depth: 0)
        var seen = Set<String>()
        labels = labels.filter { !$0.isEmpty && seen.insert($0).inserted }
        let recognized = recognizeText ? ocr(rep) : []
        let result = Result(text: (labels + recognized).joined(separator: "\n"), labels: labels, inkRatio: ink(rep), png: png)
        window.contentView = nil
        window.close()
        return result
    }

    /// cacheDisplay misses SwiftUI's layer-drawn text, so the layer tree is rendered over the window background.
    private static func capture(_ host: NSHostingView<some View>, size: CGSize, dark: Bool,
                                compositeAppKitControls: Bool) -> NSBitmapImageRep {
        let scale = 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        let gc = NSGraphicsContext(bitmapImageRep: rep)!
        let cg = gc.cgContext
        let level: CGFloat = dark ? 0.15 : 0.985   // WorkspaceStyle.content
        cg.setFillColor(NSColor(white: level, alpha: 1).cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        host.layer?.render(in: cg)
        guard compositeAppKitControls else { return rep }
        // Native AppKit controls (text fields, lists, tables) are not part of the layer tree: draw them on top.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        for view in platformHosts(host) {
            // Text fields already appear in the layer render; cacheDisplay would paint an opaque white box over the control surface.
            let fields = textFields(in: view)
            fields.forEach { $0.isHidden = true }
            defer { fields.forEach { $0.isHidden = false } }
            guard let piece = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: piece)
            let r = host.convert(view.bounds, from: view)
            cg.saveGState()
            cg.translateBy(x: r.minX, y: r.maxY)
            cg.scaleBy(x: 1, y: -1)
            piece.draw(in: CGRect(origin: .zero, size: r.size))
            cg.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func textFields(in v: NSView) -> [NSTextField] {
        v.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? textFields(in: $0) }
    }

    private static func platformHosts(_ v: NSView) -> [NSView] {
        v.subviews.flatMap { sub -> [NSView] in
            String(describing: type(of: sub)).hasPrefix("AppKitPlatformViewHost") ? [sub] : platformHosts(sub)
        }
    }

    /// On-device text recognition, so assertions cover SwiftUI text the accessibility tree does not expose offscreen.
    static func ocr(_ rep: NSBitmapImageRep) -> [String] {
        // The in-memory rep carries alpha and a device colour space that Vision reads badly (it missed text the saved PNG
        // gave it), so recognise the PNG-encoded pixels, which is what a person sees.
        guard let data = rep.representation(using: .png, properties: [:]), let cg = NSBitmapImageRep(data: data)?.cgImage else { return [] }
        // Two passes: language correction off keeps identifiers verbatim, on reads short words like "Ready" that it drops.
        let lines = [false, true].flatMap { recognizedLines(cg, correction: $0) }
        // Small coloured status text ("Ready" beside its dot) can fall below Vision's size floor; a 2x copy reads it.
        return lines + (upscaled(cg).map { recognizedText($0, correction: true) } ?? [])
    }

    private static func upscaled(_ cg: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: cg.width * 2, height: cg.height * 2, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width * 2, height: cg.height * 2))
        return ctx.makeImage()
    }

    private static func recognizedLines(_ cg: CGImage, correction: Bool) -> [String] {
        let full = recognizedText(cg, correction: correction)
        // Whole-window recognition can omit long, low-contrast helper lines.
        // Inspect the same pixels in overlapping horizontal bands as well.
        let height = CGFloat(cg.height)
        let width = CGFloat(cg.width)
        let regions = [CGRect(x: 0, y: 0, width: width, height: height * 0.6),
                       CGRect(x: 0, y: height * 0.4, width: width, height: height * 0.6)]
        return full + regions.compactMap { cg.cropping(to: $0) }.flatMap { recognizedText($0, correction: correction) }
    }

    /// Vision can fail transiently under load, and the old `try?` turned that into "no text" for the whole page.
    /// A failed request is retried (bounded) and the revision is pinned so results do not shift with the OS default.
    /// A request that still fails is reported, never silently treated as empty.
    private static func recognizedText(_ cg: CGImage, correction: Bool, attempts: Int = 4) -> [String] {
        for attempt in 1...attempts {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = correction
            if VNRecognizeTextRequest.supportedRevisions.contains(VNRecognizeTextRequestRevision3) {
                request.revision = VNRecognizeTextRequestRevision3
            }
            do {
                try perform(request, on: cg)
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            } catch {
                if attempt == attempts { Issue.record("Text recognition failed after \(attempts) attempts: \(error)") }
                Thread.sleep(forTimeInterval: 0.25 * Double(attempt))
            }
        }
        return []
    }

    /// Vision has frozen inside text recognition for hours, holding every build slot. The request runs on its own
    /// thread; after a minute it is cancelled and the caller retries.
    private static func perform(_ request: VNRecognizeTextRequest, on cg: CGImage) throws {
        final class Outcome: @unchecked Sendable { var error: Error? }
        let outcome = Outcome(), done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            do { try VNImageRequestHandler(cgImage: cg).perform([request]) } catch { outcome.error = error }
            done.signal()
        }
        if done.wait(timeout: .now() + 60) == .timedOut {
            request.cancel()
            _ = done.wait(timeout: .now() + 5)
            throw CocoaError(.userCancelled, userInfo: [NSLocalizedDescriptionKey: "text recognition gave no answer in 60 s"])
        }
        if let error = outcome.error { throw error }
    }

    /// Pixels whose colour is clearly red or green, so a Start or Stop glyph can be checked without reading source.
    static func tint(_ png: URL) -> (red: Int, green: Int) {
        guard let rep = NSBitmapImageRep(data: (try? Data(contentsOf: png)) ?? Data()), let d = rep.bitmapData else { return (0, 0) }
        var r = 0, g = 0
        let bpp = rep.bitsPerPixel / 8
        for i in 0..<(rep.pixelsWide * rep.pixelsHigh) {
            let p = d + i * bpp
            let (cr, cg, cb) = (Int(p[0]), Int(p[1]), Int(p[2]))
            if cr > 150, cg < 110, cb < 110 { r += 1 }
            if cg > 130, cr < 110, cb < 130 { g += 1 }
        }
        return (r, g)
    }

    private static func dump(_ v: NSView, _ d: Int) {
        print(String(repeating: " ", count: d) + String(describing: type(of: v)) + " \(v.frame)")
        for c in v.subviews { dump(c, d + 1) }
    }

    private static func collect(_ object: Any, into out: inout [String], depth: Int) {
        guard depth < 40 else { return }
        if let a = object as? NSObject {
            for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityHelp"] {
                let sel = Selector(name)
                if a.responds(to: sel), let s = a.perform(sel)?.takeUnretainedValue() as? String, !s.isEmpty { out.append(s) }
            }
        }
        var kids: [Any] = []
        if let view = object as? NSView {
            kids += view.accessibilityChildren() ?? []
            kids += view.subviews
        } else if let a = object as? NSObject, a.responds(to: #selector(NSView.accessibilityChildren)),
                  let c = a.perform(#selector(NSView.accessibilityChildren))?.takeUnretainedValue() as? [Any] {
            kids += c
        }
        for k in kids { collect(k, into: &out, depth: depth + 1) }
    }

    /// Share of pixels that differ from the most common colour, so a blank render reads near zero.
    private static func ink(_ rep: NSBitmapImageRep) -> Double {
        guard let data = rep.bitmapData else { return 0 }
        let n = rep.pixelsWide * rep.pixelsHigh
        let bpp = rep.bitsPerPixel / 8
        var counts: [UInt32: Int] = [:]
        var i = 0
        while i < n {
            let p = data + i * bpp
            counts[UInt32(p[0]) << 16 | UInt32(p[1]) << 8 | UInt32(p[2]), default: 0] += 1
            i += 1
        }
        let top = counts.values.max() ?? n
        return Double(n - top) / Double(max(n, 1))
    }
}

let placeholderWords = ["lorem", "todo", "placeholder", "fixme", "coming soon", "tbd", "xxx"]
