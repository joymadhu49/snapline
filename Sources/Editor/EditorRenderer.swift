import AppKit
import CoreImage

/// What drawing an annotation needs from the document: the live editor state
/// on the canvas, an immutable snapshot for the export.
protocol RenderSource {
    var pixelWidth: CGFloat { get }
    var pixelHeight: CGFloat { get }
    var pixelatedImage: CGImage { get }
}

extension EditorState: RenderSource {}

/// An immutable copy of everything the export renders. Taking one is cheap
/// (the image is shared, annotations are values), and it lets the full
/// resolution render run in the background.
struct EditorDocument: RenderSource {
    let baseImage: CGImage
    let captureScale: CGFloat
    let annotations: [Annotation]
    let background: BackgroundConfig
    /// Only produced when a redaction needs it.
    let pixelated: CGImage?

    var pixelWidth: CGFloat { CGFloat(baseImage.width) }
    var pixelHeight: CGFloat { CGFloat(baseImage.height) }
    var pixelatedImage: CGImage { pixelated ?? baseImage }
}

extension EditorState {
    func document() -> EditorDocument {
        EditorDocument(baseImage: baseImage, captureScale: captureScale, annotations: annotations,
                       background: background,
                       pixelated: annotations.contains { $0.kind == .redact } ? pixelatedImage : nil)
    }
}

/// Flattens the editor document into a final image, and helper filters.
enum EditorRenderer {

    static func pixelate(_ image: CGImage) -> CGImage? {
        let ciImage = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        let scale = max(10, CGFloat(image.width) / 70)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(output, from: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    /// Renders the full document at native pixel size.
    static func render(state: EditorState) -> CGImage? {
        render(state.document())
    }

    /// Renders a snapshot. It shares nothing with the live editor, so this is
    /// safe to run off the main thread while editing carries on.
    static func render(_ state: EditorDocument) -> CGImage? {
        let imgW = CGFloat(state.baseImage.width)
        let imgH = CGFloat(state.baseImage.height)
        let pad = state.background.enabled ? state.background.padding * state.captureScale : 0
        let totalW = Int(imgW + pad * 2)
        let totalH = Int(imgH + pad * 2)

        guard let cgContext = CGContext(data: nil, width: totalW, height: totalH,
                                        bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        // Flip into a top left origin coordinate system and route AppKit drawing into it.
        cgContext.translateBy(x: 0, y: CGFloat(totalH))
        cgContext.scaleBy(x: 1, y: -1)
        let nsContext = NSGraphicsContext(cgContext: cgContext, flipped: true)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = nsContext
        defer { NSGraphicsContext.current = previous }

        let fullRect = CGRect(x: 0, y: 0, width: CGFloat(totalW), height: CGFloat(totalH))
        let imageRect = CGRect(x: pad, y: pad, width: imgW, height: imgH)

        if state.background.enabled {
            let colors = BackgroundConfig.presets[min(state.background.presetIndex, BackgroundConfig.presets.count - 1)]
            let gradient = NSGradient(starting: colors[0], ending: colors[1])
            gradient?.draw(in: fullRect, angle: -45)

            let radius = state.background.cornerRadius * state.captureScale
            if state.background.shadow {
                nsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
                shadow.shadowBlurRadius = 24 * state.captureScale
                shadow.shadowOffset = NSSize(width: 0, height: -8 * state.captureScale)
                shadow.set()
                NSColor.black.setFill()
                NSBezierPath(roundedRect: imageRect, xRadius: radius, yRadius: radius).fill()
                nsContext.restoreGraphicsState()
            }
            nsContext.saveGraphicsState()
            NSBezierPath(roundedRect: imageRect, xRadius: radius, yRadius: radius).addClip()
            drawImage(state.baseImage, in: imageRect)
            nsContext.restoreGraphicsState()
        } else {
            drawImage(state.baseImage, in: imageRect)
        }

        // Annotations are stored relative to the image, offset by the padding.
        nsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: pad, yBy: pad)
        transform.concat()
        for annotation in state.annotations {
            draw(annotation, state: state)
        }
        nsContext.restoreGraphicsState()

        NSGraphicsContext.current = previous
        return cgContext.makeImage()
    }

    private static func drawImage(_ image: CGImage, in rect: CGRect) {
        // The context is flipped to a top left origin; CGImage drawing needs a local
        // counter flip or the bitmap lands mirrored vertically.
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        cg.translateBy(x: rect.minX, y: rect.maxY)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        cg.restoreGState()
    }

    /// Draws one annotation into the current NSGraphicsContext, which must be
    /// flipped to a top left origin in image pixels. The editor canvas calls
    /// this too, through its CGContext, so the screen and the export are drawn
    /// by the same code and can never disagree.
    ///
    /// `shadowScale` converts image pixels to the context's base space: 1 for
    /// the export, the canvas zoom on screen. Core Graphics shadows ignore the
    /// current transform, so without it the shadow would not shrink with the shot.
    static func draw(_ annotation: Annotation, state: some RenderSource, shadowScale: CGFloat = 1) {
        let color = annotation.color
        guard let context = NSGraphicsContext.current else { return }
        let cg = context.cgContext

        /// A soft shadow under the ink keeps marks readable on light and busy
        /// shots alike, the way CleanShot and Skitch annotations sit on top.
        func withShadow(_ blur: CGFloat, _ body: () -> Void) {
            cg.saveGState()
            cg.setShadow(offset: .zero, blur: blur * shadowScale,
                         color: NSColor.black.withAlphaComponent(0.38).cgColor)
            // One transparency layer per mark, so overlapping parts of the same
            // mark cast a single shadow instead of doubling up.
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            body()
            cg.endTransparencyLayer()
            cg.restoreGState()
        }
        let strokeBlur = max(3, annotation.lineWidth * 1.1)

        switch annotation.kind {
        case .line:
            withShadow(strokeBlur) {
                let path = NSBezierPath()
                path.move(to: annotation.start)
                path.line(to: annotation.end)
                path.lineWidth = annotation.lineWidth
                path.lineCapStyle = .round
                color.setStroke()
                path.stroke()
            }

        case .arrow:
            withShadow(strokeBlur) {
                drawArrow(from: annotation.start, to: annotation.end, width: annotation.lineWidth, color: color)
            }

        case .rect:
            withShadow(strokeBlur) {
                let radius = annotation.lineWidth * 0.9
                let path = NSBezierPath(roundedRect: annotation.boundingRect, xRadius: radius, yRadius: radius)
                path.lineWidth = annotation.lineWidth
                color.setStroke()
                path.stroke()
            }

        case .ellipse:
            withShadow(strokeBlur) {
                let path = NSBezierPath(ovalIn: annotation.boundingRect)
                path.lineWidth = annotation.lineWidth
                color.setStroke()
                path.stroke()
            }

        case .freehand:
            guard annotation.path.count > 1 else { break }
            withShadow(strokeBlur) {
                let path = NSBezierPath()
                path.move(to: annotation.path[0])
                for point in annotation.path.dropFirst() { path.line(to: point) }
                path.lineWidth = annotation.lineWidth
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                color.setStroke()
                path.stroke()
            }

        case .highlight:
            context.saveGraphicsState()
            context.compositingOperation = .multiply
            color.withAlphaComponent(0.4).setFill()
            let radius = min(annotation.boundingRect.height, annotation.boundingRect.width) * 0.12
            NSBezierPath(roundedRect: annotation.boundingRect, xRadius: radius, yRadius: radius).fill()
            context.restoreGraphicsState()

        case .redact:
            context.saveGraphicsState()
            NSBezierPath(rect: annotation.boundingRect).addClip()
            let full = CGRect(x: 0, y: 0, width: state.pixelWidth, height: state.pixelHeight)
            drawImage(state.pixelatedImage, in: full)
            context.restoreGraphicsState()

        case .text:
            withShadow(annotation.fontSize * 0.14) {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: annotation.fontSize, weight: .semibold),
                    .foregroundColor: color
                ]
                (annotation.text as NSString).draw(at: annotation.start, withAttributes: attributes)
            }

        case .counter:
            let radius = annotation.counterRadius
            let circleRect = CGRect(x: annotation.start.x - radius, y: annotation.start.y - radius,
                                    width: radius * 2, height: radius * 2)
            withShadow(radius * 0.35) {
                // A white ring separates the badge from whatever it sits on.
                NSColor.white.setFill()
                NSBezierPath(ovalIn: circleRect).fill()
                color.setFill()
                NSBezierPath(ovalIn: circleRect.insetBy(dx: radius * 0.13, dy: radius * 0.13)).fill()
            }
            let label = "\(annotation.number)"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: radius * 1.05, weight: .bold).withMonospacedDigits,
                .foregroundColor: contrastColor(for: color)
            ]
            let size = label.size(withAttributes: attributes)
            (label as NSString).draw(at: CGPoint(x: annotation.start.x - size.width / 2,
                                                 y: annotation.start.y - size.height / 2),
                                     withAttributes: attributes)
        }
    }

    /// A tapered arrow drawn as one filled shape: a shaft that thickens from a
    /// fine tail into a broad, slightly swept head, with softened corners.
    /// Reads as deliberate at any size instead of a line with a triangle on it.
    private static func drawArrow(from start: CGPoint, to end: CGPoint, width: CGFloat, color: NSColor) {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }
        let ux = dx / length, uy = dy / length // along the arrow
        let nx = -uy, ny = ux // across it

        let headLength = min(max(width * 3.6, 14), length * 0.6)
        let headHalf = max(width * 1.9, 8)
        let neckHalf = width * 0.62
        let tailHalf = max(width * 0.22, 0.75)
        // The barbs sweep back a little past the neck, which gives the head its point.
        let sweep = headLength * 0.18

        func point(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(x: start.x + ux * along + nx * across, y: start.y + uy * along + ny * across)
        }
        let neck = length - headLength
        let path = NSBezierPath()
        path.move(to: point(0, tailHalf))
        path.line(to: point(neck, neckHalf))
        path.line(to: point(neck - sweep, headHalf))
        path.line(to: end)
        path.line(to: point(neck - sweep, -headHalf))
        path.line(to: point(neck, -neckHalf))
        path.line(to: point(0, -tailHalf))
        path.close()
        color.setFill()
        path.fill()
        // A thin stroke in the same colour rounds every corner, tail included.
        path.lineWidth = max(1, width * 0.3)
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    static func contrastColor(for color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.6 ? .black : .white
    }
}

private extension NSFont {
    /// Keeps counter numbers from shifting as they go from 1 to 10.
    var withMonospacedDigits: NSFont {
        let descriptor = fontDescriptor.addingAttributes([
            .featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]
        ])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
