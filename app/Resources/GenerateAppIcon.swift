import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Noodle app icon, drawn in code. No SF Symbols or image assets; the brand kit banners set the word Noodle in the system font.
//
// Usage (from the repo root, with swift directly, not the package):
//   swift app/Resources/GenerateAppIcon.swift [work-dir]
//   swift app/Resources/GenerateAppIcon.swift --web-mark > website/public/assets/noodle-mark.svg
//   swift app/Resources/GenerateAppIcon.swift --brand   (logo kit in website/public/brand)
//
// Writes app/Resources/AppIcon.icns and website/public/assets/favicon.svg.
// If a work dir is given, the iconset, master-1024.png, art-full.svg, art-small.svg
// and art-tiny.svg are kept there too.
//
// Subject: a low shipping container with a face (white lid, two pale blue side facets, the same
// three-tone shading) with one noodle strand rising out of a slot
// in the lid. The strand is made only of a straight stem and true circular arcs
// of even weight, leaning right and curling in on itself like a fiddlehead, so it
// cannot be read as a snake or a letter. Three drawings share the geometry,
// by level of detail: `full` (corrugation ribs, 128 px and up), `small` (no ribs,
// heavier strand, 64 px) and `tiny` (the small spiral, bolder strand, bigger subject, 32 px and 16 px,
// and the SVG favicon).
// Geometry is y-down on a 1024 canvas; the tile is the macOS grid (824 square
// at 100,100, corner radius 190) with a soft shadow. No gradients, no text.

// MARK: - Palette

struct RGB { let r, g, b: Double }
func hex(_ v: UInt32) -> RGB {
    func channel(_ divisor: UInt32) -> Double { Double(v / divisor % 256) / 255 }
    return RGB(r: channel(65536), g: channel(256), b: channel(1))
}
func css(_ c: RGB) -> String {
    let h = { (x: Double) in String(format: "%02X", Int((x * 255).rounded())) }
    return "#\(h(c.r))\(h(c.g))\(h(c.b))"
}

let tileColor = hex(0x2F8FB0)          // sky blue, the Containers colour
let white = hex(0xFFFFFF)              // lid and strand highlight
let tintLight = hex(0xDEF1F8)          // long side facet, strand body
let tintMid = hex(0xA9D8EA)            // short side facet and corner posts
let slotColor = hex(0x15506A)          // the slot in the lid, and the eyes

// MARK: - Shapes

enum Seg {
    case move(Double, Double)
    case line(Double, Double)
    case curve(Double, Double, Double, Double, Double, Double)
    case close
}

struct Shape {
    var segs: [Seg]
    var fill: RGB? = nil
    var stroke: RGB? = nil
    var width: Double = 0
    /// A stroke ends in a round tip at the strand's free end; the piece inside the slot does not.
    var tip = true
}

func polygon(_ pts: [(Double, Double)], _ c: RGB) -> Shape {
    var segs: [Seg] = [.move(pts[0].0, pts[0].1)]
    for p in pts.dropFirst() { segs.append(.line(p.0, p.1)) }
    return Shape(segs: segs + [.close], fill: c)
}

func roundedRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> [Seg] {
    let k = 0.5522847498 * r
    return [
        .move(x + r, y), .line(x + w - r, y),
        .curve(x + w - r + k, y, x + w, y + r - k, x + w, y + r),
        .line(x + w, y + h - r),
        .curve(x + w, y + h - r + k, x + w - r + k, y + h, x + w - r, y + h),
        .line(x + r, y + h),
        .curve(x + r - k, y + h, x, y + h - r + k, x, y + h - r),
        .line(x, y + r),
        .curve(x, y + r - k, x + r - k, y, x + r, y),
        .close,
    ]
}

/// Circular arc as cubic Beziers (pieces of at most 45 degrees). Angles in degrees, y-down screen.
func arcSegs(cx: Double, cy: Double, r: Double, from a0: Double, to a1: Double) -> [Seg] {
    let n = max(1, Int((abs(a1 - a0) / 45).rounded(.up)))
    let step = (a1 - a0) / Double(n) * .pi / 180
    let k = 4.0 / 3.0 * tan(step / 4)
    var out: [Seg] = []
    var a = a0 * .pi / 180
    for _ in 0..<n {
        let b = a + step
        let (c0, s0, c1, s1) = (cos(a), sin(a), cos(b), sin(b))
        out.append(.curve(cx + r * (c0 - k * s0), cy + r * (s0 + k * c0),
                          cx + r * (c1 + k * s1), cy + r * (s1 - k * c1),
                          cx + r * c1, cy + r * s1))
        a = b
    }
    return out
}

struct Drawing {
    var shapes: [Shape]
    var strandEnd: (Double, Double)
    var strandWidth: Double
}

/// The noodle: straight stem, then a gentle lean and a fiddlehead curl, all clockwise arcs.
/// Starts heading up at (x, y). Returns the path, the end point and sampled points for bounds.
func strandPath(x x0: Double, y y0: Double, parts: [(r: Double, sweep: Double)]) -> (segs: [Seg], end: (Double, Double), pts: [(Double, Double)]) {
    var x = x0, y = y0, heading = -90.0
    var segs: [Seg] = [.move(x, y)]
    var pts = [(x, y)]
    for p in parts {
        if p.r == 0 {
            x += p.sweep * cos(heading * .pi / 180)
            y += p.sweep * sin(heading * .pi / 180)
            segs.append(.line(x, y)); pts.append((x, y)); continue
        }
        let cx = x + p.r * cos((heading + 90) * .pi / 180)
        let cy = y + p.r * sin((heading + 90) * .pi / 180)
        let a0 = heading - 90, a1 = a0 + p.sweep
        segs += arcSegs(cx: cx, cy: cy, r: p.r, from: a0, to: a1)
        var a = a0
        while a <= a1 { pts.append((cx + p.r * cos(a * .pi / 180), cy + p.r * sin(a * .pi / 180))); a += 5 }
        x = cx + p.r * cos(a1 * .pi / 180); y = cy + p.r * sin(a1 * .pi / 180)
        pts.append((x, y)); heading += p.sweep
    }
    return (segs, (x, y), pts)
}

enum Detail { case full, small, tiny }

func detail(forSize px: Int) -> Detail { px >= 128 ? .full : (px >= 64 ? .small : .tiny) }

func disc(_ c: (Double, Double), _ r: Double, _ col: RGB) -> Shape {
    polygon((0..<24).map { i in let t = Double(i) / 24 * 2 * .pi; return (c.0 + r * cos(t), c.1 + r * sin(t)) }, col)
}

/// Models: two sparks by the strand's tip.
func sparks(strandEnd end: (Double, Double)) -> [Shape] {
    func star(_ c: (Double, Double), _ R: Double) -> Shape {
        polygon((0..<8).map { i in
            let t = Double(i) / 8 * 2 * .pi - .pi / 2, r = i % 2 == 0 ? R : R * 0.3
            return (c.0 + r * cos(t), c.1 + r * sin(t))
        }, white)
    }
    return [star((end.0 + 150, end.1 - 120), 34), star((end.0 + 205, end.1 - 62), 16)]
}

/// Two tall eyes on the long side, drawn in that face's plane at every size; the glint only where it can be seen.
func face(_ detail: Detail, x0: Double, top: (Double) -> Double, middle: Double, height H: Double) -> [Shape] {
    let (erx, ery, gap) = [Detail.full: (10.5, 14.5, 26.0), .small: (14.0, 19.0, 30.0), .tiny: (18.0, 23.0, 36.0)][detail]!
    func oval(_ a: Double, _ rx: Double, _ ry: Double, _ c: RGB, _ ox: Double = 0, _ oy: Double = 0) -> Shape {
        let ex = x0 + a + ox, ey = top(x0 + a) + 0.48 * H + oy
        return polygon((0..<32).map { i in
            let t = Double(i) / 32 * 2 * .pi
            return (ex + rx * cos(t), ey + 0.5 * rx * cos(t) + ry * sin(t))
        }, c)
    }
    var shapes: [Shape] = []
    for a in [middle - gap, middle + gap] {
        shapes.append(oval(a, erx, ery, slotColor))
        if detail == .full { shapes.append(oval(a, 3.8, 5, white, -3.4, -6.5)) }
    }
    return shapes
}

func buildDrawing(_ detail: Detail) -> Drawing {
    // Container: iso 2:1, long face on the left. L, S, H = long, short, height.
    let L = 236.0, S = 100.0, H = 120.0
    let x0 = 512 - (L + S) / 2, xf = x0 + L, xr = xf + S
    let yF = 690.0
    let lf = (x0, yF - L / 2), fr = (xf, yF), rt = (xr, yF - S / 2), bk = (x0 + S, yF - L / 2 - S / 2)
    let cx = (lf.0 + rt.0) / 2, cy = (fr.1 + bk.1) / 2
    /// The top edge of the long face at x.
    func top(_ x: Double) -> Double { lf.1 + (x - x0) * 0.5 }

    var shapes: [Shape] = []
    // Side facets tuck 2 units under the lid and under each other so no hairline seams show.
    shapes.append(polygon([(lf.0, lf.1 - 2), (fr.0, fr.1 - 2), (xf, yF + H), (x0, lf.1 + H)], tintLight))
    shapes.append(polygon([(fr.0 - 2, fr.1 - 2), (rt.0, rt.1 - 2), (xr, rt.1 + H), (xf - 2, yF + H)], tintMid))
    shapes.append(polygon([lf, fr, rt, bk], white))
    // Corner posts keep it a shipping container while the middle stays clear for the face.
    for (a, b) in [(x0, x0 + 15), (xf - 15, xf)] {
        shapes.append(polygon([(a, top(a)), (b, top(b)), (b, top(b) + H), (a, top(a) + H)], tintMid))
    }

    // Slot in the lid, and the strand rising out of it. Below full size the slot hugs the strand,
    // so its two ends do not read as a second pair of eyes.
    let w = [Detail.full: 38.0, .small: 50.0, .tiny: 58.0][detail]!
    let sx = cx - 34, sy = cy - 17
    let rx = detail == .full ? 48.0 : w / 2 + 6, ry = rx / 2
    var ell: [Seg] = [.move(sx + rx, sy)]
    let k = 0.5522847498
    ell += [.curve(sx + rx, sy + k * ry, sx + k * rx, sy + ry, sx, sy + ry),
            .curve(sx - k * rx, sy + ry, sx - rx, sy + k * ry, sx - rx, sy),
            .curve(sx - rx, sy - k * ry, sx - k * rx, sy - ry, sx, sy - ry),
            .curve(sx + k * rx, sy - ry, sx + rx, sy - k * ry, sx + rx, sy), .close]
    shapes.append(Shape(segs: ell, fill: slotColor))

    // Full size has its own spiral; small and tiny share one, because a single wide loop read as a "P".
    let parts: [(r: Double, sweep: Double)] = detail == .full
        ? [(0, 40), (240, 34), (96, 170), (54, 180)]
        : [(0, 30), (250, 34), (104, 168), (62, 176)]
    let st = strandPath(x: sx, y: sy, parts: parts)
    // The strand drops into the slot: the piece below the rim sits in shadow and ends on the slot's front edge.
    shapes.append(Shape(segs: [.move(sx, sy + ry * 0.92), .line(sx, sy)], stroke: tintMid, width: w, tip: false))
    if detail == .tiny {
        shapes.append(Shape(segs: st.segs, stroke: white, width: w))
    } else {
        // A round strand: a pale body with a white highlight down its middle.
        shapes.append(Shape(segs: st.segs, stroke: tintLight, width: w))
        shapes.append(Shape(segs: st.segs, stroke: white, width: w * 0.5))
    }
    if detail == .full { shapes += sparks(strandEnd: st.end) }
    shapes += face(detail, x0: x0, top: top, middle: L / 2, height: H)

    // Optical centring: bounds of container and strand (with stroke), centred on the tile.
    var xs = [x0, xr], ys = [yF + H]
    for p in st.pts { xs += [p.0 - w / 2, p.0 + w / 2]; ys += [p.1 - w / 2] }
    let bx = (xs.min()! + xs.max()!) / 2, by = (ys.min()! + ys.max()!) / 2
    let scale = [Detail.full: 1.08, .small: 1.12, .tiny: 1.2][detail]!
    let dx = 512 - bx, dy = 512 - by
    func tx(_ x: Double) -> Double { 512 + (x + dx - 512) * scale }
    func ty(_ y: Double) -> Double { 512 + (y + dy - 512) * scale }
    shapes = shapes.map { sh in
        var o = sh
        o.segs = sh.segs.map { seg in
            switch seg {
            case .move(let x, let y): return .move(tx(x), ty(y))
            case .line(let x, let y): return .line(tx(x), ty(y))
            case .curve(let a, let b, let c, let d, let e, let f): return .curve(tx(a), ty(b), tx(c), ty(d), tx(e), ty(f))
            case .close: return .close
            }
        }
        o.width = sh.width * scale
        return o
    }
    return Drawing(shapes: shapes, strandEnd: (tx(st.end.0), ty(st.end.1)), strandWidth: w * scale)
}

// MARK: - SVG

func svgPath(_ segs: [Seg]) -> String {
    func n(_ v: Double) -> String { String(format: "%g", (v * 100).rounded() / 100) }
    return segs.map { s -> String in
        switch s {
        case .move(let x, let y): return "M\(n(x)) \(n(y))"
        case .line(let x, let y): return "L\(n(x)) \(n(y))"
        case .curve(let a, let b, let c, let d, let e, let f): return "C\(n(a)) \(n(b)) \(n(c)) \(n(d)) \(n(e)) \(n(f))"
        case .close: return "Z"
        }
    }.joined()
}

/// Tile plus art as SVG. `canvas` true gives the full 1024 canvas with shadow-free tile, false the tight favicon viewBox.
func artSVG(_ detail: Detail, canvas: Bool, groupStrand: Bool = false, square: Bool = false) -> String {
    let d = buildDrawing(detail)
    var s = canvas
        ? "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1024 1024\" width=\"1024\" height=\"1024\">\n"
        : "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"100 100 824 824\" width=\"512\" height=\"512\">\n"
    s += "  <path d=\"\(svgPath(roundedRect(100, 100, 824, 824, square ? 0 : 190)))\" fill=\"\(css(tileColor))\"/>\n"
    for sh in d.shapes {
        if let f = sh.fill {
            s += "  <path d=\"\(svgPath(sh.segs))\" fill=\"\(css(f))\"/>\n"
        } else if let st = sh.stroke {
            if groupStrand { s += "  <g class=\"noodle-strand\">\n" }
            s += "  <path d=\"\(svgPath(sh.segs))\" fill=\"none\" stroke=\"\(css(st))\" stroke-width=\"\(String(format: "%g", (sh.width * 100).rounded() / 100))\"/>\n"
            if sh.tip {
                s += "  <circle cx=\"\(String(format: "%.2f", d.strandEnd.0))\" cy=\"\(String(format: "%.2f", d.strandEnd.1))\" r=\"\(String(format: "%g", sh.width / 2))\" fill=\"\(css(st))\"/>\n"
            }
            if groupStrand { s += "  </g>\n" }
        }
    }
    return s + "</svg>\n"
}

// MARK: - Raster

func addPath(_ ctx: CGContext, _ segs: [Seg]) {
    for s in segs {
        switch s {
        case .move(let x, let y): ctx.move(to: CGPoint(x: x, y: y))
        case .line(let x, let y): ctx.addLine(to: CGPoint(x: x, y: y))
        case .curve(let a, let b, let c, let d, let e, let f):
            ctx.addCurve(to: CGPoint(x: e, y: f), control1: CGPoint(x: a, y: b), control2: CGPoint(x: c, y: d))
        case .close: ctx.closePath()
        }
    }
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func cg(_ c: RGB, _ a: Double = 1) -> CGColor { CGColor(colorSpace: srgb, components: [c.r, c.g, c.b, a])! }

/// Full icon with shadow (padding included) when `bleed` is false; tile only, edge to edge, when true.
func render(size: Int, bleed: Bool, detail: Detail) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let scale = Double(size) / (bleed ? 824 : 1024)
    // Flip to y-down so the geometry matches the SVG.
    ctx.translateBy(x: 0, y: Double(size))
    ctx.scaleBy(x: scale, y: -scale)
    if bleed { ctx.translateBy(x: -100, y: -100) }

    // Tile, with a soft shadow when it carries padding.
    ctx.saveGState()
    if !bleed {
        ctx.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 30 * scale, color: cg(RGB(r: 0, g: 0, b: 0), 0.30))
    }
    addPath(ctx, roundedRect(100, 100, 824, 824, 190))
    ctx.setFillColor(cg(tileColor))
    ctx.fillPath()
    ctx.restoreGState()

    drawArt(ctx, detail)
    return ctx.makeImage()!
}

/// The container and strand in tile coordinates (the context is already y-down on the 1024 grid).
func drawArt(_ ctx: CGContext, _ detail: Detail) {
    let d = buildDrawing(detail)
    for sh in d.shapes {
        ctx.saveGState()
        addPath(ctx, sh.segs)
        if let f = sh.fill {
            ctx.setFillColor(cg(f))
            ctx.fillPath()
        } else if let st = sh.stroke {
            ctx.setStrokeColor(cg(st))
            ctx.setLineWidth(sh.width)
            ctx.setLineCap(.butt)
            ctx.strokePath()
            // Round tip at the free end of the strand.
            if sh.tip {
                ctx.setFillColor(cg(st))
                let r = sh.width / 2
                ctx.fillEllipse(in: CGRect(x: d.strandEnd.0 - r, y: d.strandEnd.1 - r, width: 2 * r, height: 2 * r))
            }
        }
        ctx.restoreGState()
    }
}

func writePNG(_ image: CGImage, to url: URL, type: UTType = .png) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        throw NSError(domain: "icon", code: 1)
    }
    CGImageDestinationAddImage(dest, image, type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary : nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "icon", code: 2) }
}

// MARK: - Brand kit

enum TileStyle: String { case rounded, square }

func canvas(_ w: Int, _ h: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.translateBy(x: 0, y: Double(h))
    ctx.scaleBy(x: 1, y: -1)  // y-down, like the SVG geometry
    return ctx
}

/// The tile edge to edge, no shadow. Rounded keeps the macOS corner with transparent corners; square fills the canvas.
func renderTile(size: Int, style: TileStyle) -> CGImage {
    let ctx = canvas(size, size)
    let s = Double(size) / 824
    ctx.scaleBy(x: s, y: s)
    ctx.translateBy(x: -100, y: -100)
    if style == .rounded { addPath(ctx, roundedRect(100, 100, 824, 824, 190)) } else { ctx.addRect(CGRect(x: 100, y: 100, width: 824, height: 824)) }
    ctx.setFillColor(cg(tileColor))
    ctx.fillPath()
    drawArt(ctx, detail(forSize: size))
    return ctx.makeImage()!
}

/// One-colour mark: the strand rising from a lid line, as in the menu bar glyph. Box in 1024-grid units.
let markBox = CGRect(x: 330, y: 250, width: 400, height: 420)
func drawMark(_ ctx: CGContext, colour: RGB) {
    let strand = buildDrawing(.full).shapes.first { $0.stroke != nil }!
    guard case .move(let sx, let sy) = strand.segs[0] else { return }
    ctx.setStrokeColor(cg(colour))
    ctx.setLineWidth(62)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    addPath(ctx, [.move(sx, sy + 80)] + strand.segs.dropFirst())  // stem runs down to the lid
    ctx.strokePath()
    ctx.move(to: CGPoint(x: sx - 87, y: sy + 110))
    ctx.addLine(to: CGPoint(x: sx + 233, y: sy + 110))
    ctx.strokePath()
}

/// Transparent square with the mark centred, 10% clear space on every side.
func renderMark(size: Int, colour: RGB) -> CGImage {
    let ctx = canvas(size, size)
    let s = Double(size) * 0.8 / markBox.height
    ctx.translateBy(x: Double(size) / 2, y: Double(size) / 2)
    ctx.scaleBy(x: s, y: s)
    ctx.translateBy(x: -markBox.midX, y: -markBox.midY)
    drawMark(ctx, colour: colour)
    return ctx.makeImage()!
}

/// Plum field, white mark and the word Noodle, centred. Sized for profile banners and repo previews.
func renderBanner(width: Int, height: Int) -> CGImage {
    let ctx = canvas(width, height)
    ctx.setFillColor(cg(tileColor))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let h = Double(height)
    let markH = h * 0.36, s = markH / markBox.height, markW = markBox.width * s
    let font = CTFontCreateCopyWithSymbolicTraits(CTFontCreateUIFontForLanguage(.system, h * 0.26, nil)!, h * 0.26, nil, .traitBold, .traitBold)!
    let text = NSAttributedString(string: "Noodle", attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): cg(white),
    ])
    let line = CTLineCreateWithAttributedString(text)
    let textW = CTLineGetTypographicBounds(line, nil, nil, nil)
    let gap = h * 0.08, x0 = (Double(width) - markW - gap - textW) / 2
    ctx.saveGState()
    ctx.translateBy(x: x0, y: (h - markH) / 2)
    ctx.scaleBy(x: s, y: s)
    ctx.translateBy(x: -markBox.minX, y: -markBox.minY)
    drawMark(ctx, colour: white)
    ctx.restoreGState()
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)  // undo the y-down flip for glyphs
    ctx.textPosition = CGPoint(x: x0 + markW + gap, y: h / 2 + CTFontGetCapHeight(font) / 2)
    CTLineDraw(line, ctx)
    return ctx.makeImage()!
}

func writeICO(_ sizes: [Int], to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.ico.identifier as CFString, sizes.count, nil) else {
        throw NSError(domain: "icon", code: 3)
    }
    for s in sizes { CGImageDestinationAddImage(dest, renderTile(size: s, style: .rounded), nil) }
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "icon", code: 4) }
}

/// website/public/brand: every logo file the site, stores, social profiles and press need.
func writeBrandKit(root: URL) throws {
    let out = root.appendingPathComponent("website/public/brand", isDirectory: true)
    for sub in ["icon", "tile", "mark", "social", "web"] {
        try FileManager.default.createDirectory(at: out.appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    func file(_ path: String) -> URL { out.appendingPathComponent(path) }
    // App icon as macOS shows it: padding and shadow included.
    for s in [1024, 512, 256, 128, 64, 32, 16] { try writePNG(render(size: s, bleed: false, detail: detail(forSize: s)), to: file("icon/noodle-app-icon-\(s).png")) }
    // Tile edge to edge, with and without the corner radius.
    for style in [TileStyle.rounded, .square] {
        for s in [1024, 512, 256, 128, 64, 32] { try writePNG(renderTile(size: s, style: style), to: file("tile/noodle-\(style.rawValue)-\(s).png")) }
    }
    for s in [1024, 512, 256] { try writePNG(renderTile(size: s, style: .square), to: file("tile/noodle-square-\(s).jpg"), type: .jpeg) }
    try artSVG(.full, canvas: false).write(to: file("tile/noodle-rounded.svg"), atomically: true, encoding: .utf8)
    try artSVG(.full, canvas: false, square: true).write(to: file("tile/noodle-square.svg"), atomically: true, encoding: .utf8)
    // One-colour mark on transparent.
    let glyph = try String(contentsOf: root.appendingPathComponent("app/Resources/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon.svg"), encoding: .utf8)
    for (name, colour) in [("plum", tileColor), ("black", hex(0x16151C)), ("white", white)] {
        for s in [1024, 512, 256, 64] { try writePNG(renderMark(size: s, colour: colour), to: file("mark/noodle-mark-\(name)-\(s).png")) }
        try glyph.replacingOccurrences(of: "#000", with: css(colour)).replacingOccurrences(of: " width=\"18\" height=\"19\"", with: "")
            .write(to: file("mark/noodle-mark-\(name).svg"), atomically: true, encoding: .utf8)
    }
    // Social: square avatars (circle-safe), profile banners and the GitHub repo preview.
    for s in [400, 800] { try writePNG(renderTile(size: s, style: .square), to: file("social/avatar-\(s).png")) }
    // The GitHub preview is the dark card kept in social/, not drawn here.
    for (name, w, h) in [("x-banner", 1500, 500), ("linkedin-banner", 1584, 396)] {
        let img = renderBanner(width: w, height: h)
        try writePNG(img, to: file("social/\(name).png"))
        try writePNG(img, to: file("social/\(name).jpg"), type: .jpeg)
    }
    // Web and PWA. iOS rounds the touch icon itself and fills transparency with black, so it is square.
    try writePNG(renderTile(size: 180, style: .square), to: file("web/apple-touch-icon.png"))
    for s in [192, 512] { try writePNG(renderTile(size: s, style: .rounded), to: file("web/icon-\(s).png")) }
    try writePNG(renderTile(size: 512, style: .square), to: file("web/icon-maskable-512.png"))  // art stays inside the 80% safe circle
    try writeICO([16, 32, 48], to: file("web/favicon.ico"))
}

// MARK: - Output

if CommandLine.arguments.dropFirst().first == "--web-mark" {
    print(artSVG(.full, canvas: false, groupStrand: true), terminator: "")
    exit(0)
}

let fm = FileManager.default
let scriptURL = URL(fileURLWithPath: #filePath)
let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
if CommandLine.arguments.dropFirst().first == "--brand" {
    try writeBrandKit(root: root)
    print("wrote website/public/brand")
    exit(0)
}
let keep = CommandLine.arguments.count > 1
let work = keep
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    : fm.temporaryDirectory.appendingPathComponent("noodle-\(UUID().uuidString)", isDirectory: true)
let iconset = work.appendingPathComponent("Noodle.iconset", isDirectory: true)
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
// 128 px and up: full drawing. 64: no ribs, heavier strand. 32 and 16: bolder still.
for (name, size) in sizes { try writePNG(render(size: size, bleed: false, detail: detail(forSize: size)), to: iconset.appendingPathComponent(name)) }
try writePNG(render(size: 1024, bleed: false, detail: .full), to: work.appendingPathComponent("master-1024.png"))
if keep {
    for size in [256, 128, 64, 32, 16] {
        try writePNG(render(size: size, bleed: false, detail: detail(forSize: size)), to: work.appendingPathComponent("s\(size).png"))
    }
    try artSVG(.full, canvas: true).write(to: work.appendingPathComponent("art-full.svg"), atomically: true, encoding: .utf8)
    try artSVG(.small, canvas: true).write(to: work.appendingPathComponent("art-small.svg"), atomically: true, encoding: .utf8)
    try artSVG(.tiny, canvas: true).write(to: work.appendingPathComponent("art-tiny.svg"), atomically: true, encoding: .utf8)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("app/Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")

let assets = root.appendingPathComponent("website/public/assets", isDirectory: true)
try fm.createDirectory(at: assets, withIntermediateDirectories: true)
try artSVG(.tiny, canvas: false).write(to: assets.appendingPathComponent("favicon.svg"), atomically: true, encoding: .utf8)

if !keep { try? fm.removeItem(at: work) }
print("wrote app/Resources/AppIcon.icns, website/public/assets/favicon.svg (tile \(css(tileColor)))")
