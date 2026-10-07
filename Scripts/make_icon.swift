// Renders the whole Snapline logo system. Run: swift Scripts/make_icon.swift
//
// Outputs:
//   Resources/AppIcon.icns      app icon, every size iconutil wants
//   Resources/MenuBarIcon.pdf   monochrome template glyph for the status item
//   Brand/                      mark + lockup as SVG and PNG, for README and web
//
// The mark is the name drawn literally: one line that snaps at right angles
// into an S, with a square selection handle on each end, the way a selected
// path looks in a design tool. Snap, line, and the act of selecting, in one
// stroke. The square corners echo the capture marquee without borrowing the
// generic viewfinder brackets every screenshot app uses.
import AppKit
import CoreText

// MARK: - Geometry

/// One description of the mark, instanced at 1024 for the icon and at 18pt
/// for the menu bar. Coordinates are y-up; SVG output flips them.
struct MarkGeometry {
    var center: CGPoint
    /// Centre line extents of the S.
    var width: CGFloat
    var height: CGFloat
    var stroke: CGFloat
    /// Centre line radius of the four rounded turns.
    var radius: CGFloat
    var handle: CGFloat
    var handleRadius: CGFloat
    /// Clear space cut between each handle and the stroke it sits on.
    var gap: CGFloat

    /// Top right to bottom left: top bar, left drop, middle bar, right drop, bottom bar.
    var centerLine: CGPath {
        let minX = center.x - width / 2, maxX = center.x + width / 2
        let top = center.y + height / 2, bottom = center.y - height / 2, mid = center.y
        let p = CGMutablePath()
        p.move(to: CGPoint(x: maxX, y: top))
        p.addArc(tangent1End: CGPoint(x: minX, y: top), tangent2End: CGPoint(x: minX, y: mid), radius: radius)
        p.addArc(tangent1End: CGPoint(x: minX, y: mid), tangent2End: CGPoint(x: maxX, y: mid), radius: radius)
        p.addArc(tangent1End: CGPoint(x: maxX, y: mid), tangent2End: CGPoint(x: maxX, y: bottom), radius: radius)
        p.addArc(tangent1End: CGPoint(x: maxX, y: bottom), tangent2End: CGPoint(x: minX, y: bottom), radius: radius)
        p.addLine(to: CGPoint(x: minX, y: bottom))
        return p
    }

    var handleRects: [CGRect] {
        [CGPoint(x: center.x + width / 2, y: center.y + height / 2),
         CGPoint(x: center.x - width / 2, y: center.y - height / 2)].map {
            CGRect(x: $0.x - handle / 2, y: $0.y - handle / 2, width: handle, height: handle)
        }
    }

    var handles: [CGPath] {
        handleRects.map { CGPath(roundedRect: $0, cornerWidth: handleRadius, cornerHeight: handleRadius, transform: nil) }
    }

    /// The stroke as one filled outline with clear space cut around both
    /// handles, so every output (raster, PDF, SVG) is plain fills with no
    /// knockout colour that has to match whatever sits underneath.
    var line: CGPath {
        let outline = centerLine.copy(strokingWithWidth: stroke, lineCap: .butt, lineJoin: .round, miterLimit: 10)
        let cut = CGMutablePath()
        for rect in handleRects {
            let r = handleRadius + gap
            cut.addPath(CGPath(roundedRect: rect.insetBy(dx: -gap, dy: -gap), cornerWidth: r, cornerHeight: r, transform: nil))
        }
        return outline.subtracting(cut)
    }
}

enum Mark {
    static let canvas: CGFloat = 1024
    static let icon = MarkGeometry(center: CGPoint(x: 512, y: 512), width: 380, height: 470, stroke: 72,
                                   radius: 62, handle: 110, handleRadius: 24, gap: 18)
}

// Optically tuned at 18pt against Wi-Fi, search, and clipboard in the menu
// bar, at 1x and 2x: the S stands about as tall as Apple's own glyphs, the
// stroke sits near SF Symbols Regular stem weight, and the gap around each
// handle stays open at 1x instead of filling in.
enum MenuBar {
    static let size: CGFloat = 18
    static let glyph = MarkGeometry(center: CGPoint(x: 9, y: 9), width: 9.6, height: 12.4, stroke: 1.6,
                                    radius: 2.1, handle: 3.6, handleRadius: 0.8, gap: 0.9)
}

// MARK: - Palette

enum Brand {
    static let inkTop = NSColor(srgbRed: 0.141, green: 0.149, blue: 0.176, alpha: 1) // #24262D
    static let inkBottom = NSColor(srgbRed: 0.047, green: 0.051, blue: 0.067, alpha: 1) // #0C0D11
    static let chalk = NSColor(srgbRed: 0.965, green: 0.969, blue: 0.980, alpha: 1) // #F6F7FA
    static let chalkShade = NSColor(srgbRed: 0.851, green: 0.863, blue: 0.890, alpha: 1) // #D9DCE3
    static let accentTop = NSColor(srgbRed: 0.357, green: 0.549, blue: 1.000, alpha: 1) // #5B8CFF
    static let accentBottom = NSColor(srgbRed: 0.200, green: 0.400, blue: 0.941, alpha: 1) // #3366F0

    static let inkTopHex = "#24262D", inkBottomHex = "#0C0D11"
    static let chalkHex = "#F6F7FA", chalkShadeHex = "#D9DCE3"
    static let accentTopHex = "#5B8CFF", accentBottomHex = "#3366F0"
}

// MARK: - Shapes

/// Superellipse, the continuous-corner shape macOS icons actually use. A plain
/// rounded rect reads subtly wrong next to Apple's own icons in the Dock.
func squircle(in rect: CGRect, n: CGFloat = 5.0, steps: Int = 720) -> CGPath {
    let a = rect.width / 2, b = rect.height / 2
    let p = CGMutablePath()
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let point = CGPoint(x: rect.midX + a * pow(abs(ct), 2 / n) * (ct < 0 ? -1 : 1),
                            y: rect.midY + b * pow(abs(st), 2 / n) * (st < 0 ? -1 : 1))
        if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
    }
    p.closeSubpath()
    return p
}

let plate = CGRect(x: 100, y: 100, width: 824, height: 824)

// MARK: - Drawing

func fillVertical(_ ctx: CGContext, _ path: CGPath, top: NSColor, bottom: NSColor, from y1: CGFloat, to y2: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: y1), end: CGPoint(x: 0, y: y2), options: [])
    ctx.restoreGState()
}

/// The mark in colour, in the 1024 space: a softly lit chalk line and two
/// blue handles, each handle lit from above on its own.
func drawMark(_ ctx: CGContext) {
    let g = Mark.icon
    let bounds = g.line.boundingBox
    fillVertical(ctx, g.line, top: Brand.chalk, bottom: Brand.chalkShade, from: bounds.maxY, to: bounds.minY)
    for (rect, handle) in zip(g.handleRects, g.handles) {
        fillVertical(ctx, handle, top: Brand.accentTop, bottom: Brand.accentBottom, from: rect.maxY, to: rect.minY)
        // A hairline of light along the top edge gives the handle a little body.
        ctx.saveGState()
        ctx.addPath(handle)
        ctx.clip()
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 3, dy: 3).offsetBy(dx: 0, dy: -3),
                           cornerWidth: g.handleRadius, cornerHeight: g.handleRadius, transform: nil))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
        ctx.setLineWidth(6)
        ctx.strokePath()
        ctx.restoreGState()
    }
}

/// Full app icon on the macOS grid: an 824pt squircle centred in a 1024pt canvas.
func drawAppIcon(_ ctx: CGContext) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 34, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    ctx.addPath(squircle(in: plate))
    ctx.setFillColor(Brand.inkBottom.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    fillVertical(ctx, squircle(in: plate), top: Brand.inkTop, bottom: Brand.inkBottom, from: plate.maxY, to: plate.minY)

    // Hairline that lifts the plate off a dark Dock or Finder background.
    ctx.addPath(squircle(in: plate.insetBy(dx: 4, dy: 4)))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.09).cgColor)
    ctx.setLineWidth(6)
    ctx.strokePath()

    drawMark(ctx)
}

// MARK: - Raster helpers

func rasterize(px: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    // Author at 1024 and scale, so hairlines and the squircle stay smooth at 16pt.
    let scale = CGFloat(px) / Mark.canvas
    ctx.scaleBy(x: scale, y: scale)
    draw(ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!)
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: - Output locations

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = repo.appendingPathComponent("Resources")
let brand = repo.appendingPathComponent("Brand")
let fm = FileManager.default
try? fm.createDirectory(at: resources, withIntermediateDirectories: true)
try? fm.createDirectory(at: brand, withIntermediateDirectories: true)

// MARK: - 1. AppIcon.icns

let iconset = fm.temporaryDirectory.appendingPathComponent("Snapline-AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        writePNG(rasterize(px: px, drawAppIcon), to: iconset.appendingPathComponent(name))
    }
}

let icns = Process()
icns.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
icns.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try! icns.run()
icns.waitUntilExit()
try? fm.removeItem(at: iconset)
print("Resources/AppIcon.icns")

// MARK: - 2. Menu bar template

let pdfData = NSMutableData()
var mediaBox = CGRect(x: 0, y: 0, width: MenuBar.size, height: MenuBar.size)
let consumer = CGDataConsumer(data: pdfData as CFMutableData)!
let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
pdf.beginPDFPage(nil)
pdf.setFillColor(NSColor.black.cgColor)
pdf.addPath(MenuBar.glyph.line)
for handle in MenuBar.glyph.handles { pdf.addPath(handle) }
pdf.fillPath()
pdf.endPDFPage()
pdf.closePDF()
try! pdfData.write(to: resources.appendingPathComponent("MenuBarIcon.pdf"), options: .atomic)
print("Resources/MenuBarIcon.pdf")

// MARK: - 3. Vector brand assets

func fmt(_ v: CGFloat) -> String {
    v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
}

func svgHeader(_ w: CGFloat, _ h: CGFloat) -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(fmt(w)) \(fmt(h))" width="\(fmt(w))" height="\(fmt(h))" fill="none">
    """
}

/// Path data for any CGPath, mapped from the y-up 1024 space into SVG's y-down
/// space at the given scale and offset.
func svgPathData(_ path: CGPath, scale: CGFloat = 1, offsetX: CGFloat = 0, offsetY: CGFloat = 0,
                 flipHeight: CGFloat = Mark.canvas) -> String {
    func pt(_ p: CGPoint) -> String {
        "\(fmt(offsetX + p.x * scale)) \(fmt(offsetY + (flipHeight - p.y) * scale))"
    }
    var d = ""
    path.applyWithBlock { element in
        let e = element.pointee
        switch e.type {
        case .moveToPoint: d += "M\(pt(e.points[0]))"
        case .addLineToPoint: d += "L\(pt(e.points[0]))"
        case .addQuadCurveToPoint: d += "Q\(pt(e.points[0])) \(pt(e.points[1]))"
        case .addCurveToPoint: d += "C\(pt(e.points[0])) \(pt(e.points[1])) \(pt(e.points[2]))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

func verticalGradientDef(_ id: String, top: String, bottom: String, y1: CGFloat, y2: CGFloat) -> String {
    """
        <linearGradient id="\(id)" x1="0" y1="\(fmt(y1))" x2="0" y2="\(fmt(y2))" gradientUnits="userSpaceOnUse">
          <stop stop-color="\(top)"/>
          <stop offset="1" stop-color="\(bottom)"/>
        </linearGradient>
    """
}

/// Gradient defs plus the line and handles, scaled into a document. `lineFill`
/// is a colour, or nil for the lit chalk gradient.
func markSVG(prefix: String, scale: CGFloat = 1, offsetX: CGFloat = 0, offsetY: CGFloat = 0,
             lineFill: String? = nil) -> (defs: String, body: String) {
    let g = Mark.icon
    let lineBox = g.line.boundingBox
    func y(_ v: CGFloat) -> CGFloat { offsetY + (Mark.canvas - v) * scale }
    var defs = verticalGradientDef("\(prefix)-handle", top: Brand.accentTopHex, bottom: Brand.accentBottomHex,
                                   y1: 0, y2: 1).replacingOccurrences(of: "gradientUnits=\"userSpaceOnUse\"",
                                                                     with: "gradientUnits=\"objectBoundingBox\"")
    if lineFill == nil {
        defs += "\n" + verticalGradientDef("\(prefix)-line", top: Brand.chalkHex, bottom: Brand.chalkShadeHex,
                                           y1: y(lineBox.maxY), y2: y(lineBox.minY))
    }
    var body = "  <path d=\"\(svgPathData(g.line, scale: scale, offsetX: offsetX, offsetY: offsetY))\" fill=\"\(lineFill ?? "url(#\(prefix)-line)")\"/>"
    for handle in g.handles {
        body += "\n  <path d=\"\(svgPathData(handle, scale: scale, offsetX: offsetX, offsetY: offsetY))\" fill=\"url(#\(prefix)-handle)\"/>"
    }
    return (defs, body)
}

func plateSVG(prefix: String, scale: CGFloat = 1) -> (defs: String, body: String) {
    let defs = verticalGradientDef("\(prefix)-plate", top: Brand.inkTopHex, bottom: Brand.inkBottomHex,
                                   y1: 100 * scale, y2: 924 * scale)
    let body = """
      <path d="\(svgPathData(squircle(in: plate, steps: 240), scale: scale))" fill="url(#\(prefix)-plate)"/>
      <path d="\(svgPathData(squircle(in: plate.insetBy(dx: 4, dy: 4), steps: 240), scale: scale))" stroke="#FFFFFF" stroke-opacity="0.09" stroke-width="\(fmt(6 * scale))"/>
    """
    return (defs, body)
}

// 3a. Bare mark, transparent. The line uses currentColor so the same file works
// on light and dark pages; the handles keep the brand blue.
let bareMark = markSVG(prefix: "snapline", lineFill: "currentColor")
try! """
\(svgHeader(1024, 1024))
  <defs>
\(bareMark.defs)
  </defs>
\(bareMark.body)
</svg>

""".write(to: brand.appendingPathComponent("snapline-mark.svg"), atomically: true, encoding: .utf8)

// 3b. Full app icon as SVG, true superellipse included.
let iconPlate = plateSVG(prefix: "snapline")
let iconMark = markSVG(prefix: "snapline")
try! """
\(svgHeader(1024, 1024))
  <defs>
\(iconPlate.defs)
\(iconMark.defs)
  </defs>
\(iconPlate.body)
\(iconMark.body)
</svg>

""".write(to: brand.appendingPathComponent("snapline-icon.svg"), atomically: true, encoding: .utf8)

// MARK: - 4. Wordmark lockup

// SF Pro ships with macOS. Swap in an OFL face (Inter, Manrope) by installing it and
// re-running — the first name that resolves wins.
/// Sized so the wordmark's cap height lands near 60% of the icon plate — the mark leads,
/// the name follows.
let wordmarkSize: CGFloat = 165
let wordmarkFont: NSFont = ["Inter-SemiBold", "Manrope-SemiBold", "SFProDisplay-Semibold"]
    .compactMap { NSFont(name: $0, size: wordmarkSize) }
    .first ?? NSFont.systemFont(ofSize: wordmarkSize, weight: .semibold)
let wordmarkTracking: CGFloat = -4

/// Outlines a string so the SVG needs no font installed to render correctly.
func outlinedText(_ text: String, font: NSFont, tracking: CGFloat, originX: CGFloat, baselineY: CGFloat) -> (path: CGPath, width: CGFloat) {
    let combined = CGMutablePath()
    var pen: CGFloat = 0
    for scalar in text.unicodeScalars {
        var ch = UniChar(scalar.value)
        var glyph = CGGlyph(0)
        guard CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1) else { continue }
        if let g = CTFontCreatePathForGlyph(font, glyph, nil) {
            combined.addPath(g, transform: CGAffineTransform(translationX: originX + pen, y: baselineY))
        }
        var advanceGlyph = glyph
        pen += CTFontGetAdvancesForGlyphs(font, .horizontal, &advanceGlyph, nil, 1) + tracking
    }
    return (combined, pen - tracking)
}

let lockupIconSize: CGFloat = 240
let lockupGap: CGFloat = 52
let baseline = (lockupIconSize - wordmarkFont.capHeight) / 2
let (wordPath, wordWidth) = outlinedText("Snapline", font: wordmarkFont, tracking: wordmarkTracking,
                                         originX: lockupIconSize + lockupGap, baselineY: baseline)
let lockupW = lockupIconSize + lockupGap + wordWidth
let lockupH = lockupIconSize

func lockupSVG(wordColor: String) -> String {
    let scale = lockupIconSize / Mark.canvas
    let lp = plateSVG(prefix: "lockup", scale: scale)
    let lm = markSVG(prefix: "lockup", scale: scale)
    return """
    \(svgHeader(lockupW, lockupH))
      <defs>
    \(lp.defs)
    \(lm.defs)
      </defs>
    \(lp.body)
    \(lm.body)
      <path d="\(svgPathData(wordPath, flipHeight: lockupH))" fill="\(wordColor)"/>
    </svg>

    """
}
try! lockupSVG(wordColor: Brand.chalkHex)
    .write(to: brand.appendingPathComponent("snapline-lockup-dark.svg"), atomically: true, encoding: .utf8)
try! lockupSVG(wordColor: "#101114")
    .write(to: brand.appendingPathComponent("snapline-lockup-light.svg"), atomically: true, encoding: .utf8)

// MARK: - 5. PNG brand exports

writePNG(rasterize(px: 1024, drawAppIcon), to: brand.appendingPathComponent("snapline-icon-1024.png"))
writePNG(rasterize(px: 512, drawAppIcon), to: brand.appendingPathComponent("snapline-icon-512.png"))
writePNG(rasterize(px: 1024, drawMark), to: brand.appendingPathComponent("snapline-mark-1024.png"))

func writeLockupPNG(wordColor: NSColor, to url: URL, height: CGFloat = 240) {
    let scale = height / lockupIconSize
    let w = Int((lockupW * scale).rounded()), h = Int((lockupH * scale).rounded())
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    ctx.saveGState()
    ctx.scaleBy(x: lockupIconSize / Mark.canvas, y: lockupIconSize / Mark.canvas)
    drawAppIcon(ctx)
    ctx.restoreGState()
    ctx.addPath(wordPath)
    ctx.setFillColor(wordColor.cgColor)
    ctx.fillPath()
    writePNG(NSBitmapImageRep(cgImage: ctx.makeImage()!), to: url)
}
writeLockupPNG(wordColor: Brand.chalk, to: brand.appendingPathComponent("snapline-lockup-dark.png"))
writeLockupPNG(wordColor: NSColor(srgbRed: 0.063, green: 0.067, blue: 0.078, alpha: 1),
               to: brand.appendingPathComponent("snapline-lockup-light.png"))

print("Brand/snapline-mark.svg, snapline-icon.svg, snapline-lockup-{dark,light}.svg")
print("Brand/snapline-icon-{1024,512}.png, snapline-mark-1024.png, snapline-lockup-{dark,light}.png")
print("Wordmark set in \(wordmarkFont.fontName)")
