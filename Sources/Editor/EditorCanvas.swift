import SwiftUI
import AppKit

/// Interactive canvas: image, live annotations, selection, crop, and text editing.
struct EditorCanvasView: View {
    @ObservedObject var state: EditorState
    @FocusState private var textFocused: Bool

    private enum DragMode {
        case none
        case draft
        case move
        case handle(Int) // 0 start, 1 end, or corner index for boxes
        case crop
    }

    @State private var dragMode: DragMode = .none
    @State private var gestureStartPX: CGPoint = .zero
    @State private var lastPX: CGPoint = .zero
    @State private var didPushUndoForDrag = false
    @State private var editingText: String = ""

    var body: some View {
        GeometryReader { geo in
            let layout = computeLayout(in: geo.size)
            ZStack(alignment: .topLeading) {
                Color(nsColor: EditorPalette.canvas)

                documentView(layout: layout)
                    .frame(width: layout.docSize.width, height: layout.docSize.height)
                    .offset(x: layout.docOrigin.x, y: layout.docOrigin.y)

                textEditingOverlay(layout: layout)
            }
            .contentShape(Rectangle())
            .gesture(canvasGesture(layout: layout))
            .preference(key: EditorZoomKey.self, value: layout.scale)
        }
    }

    // MARK: Layout

    struct Layout {
        var scale: CGFloat
        var docOrigin: CGPoint
        var docSize: CGSize
        var pad: CGFloat // padding in px around the image inside the document

        func viewPoint(fromPX px: CGPoint) -> CGPoint {
            CGPoint(x: docOrigin.x + (px.x + pad) * scale, y: docOrigin.y + (px.y + pad) * scale)
        }

        func pxPoint(fromView view: CGPoint) -> CGPoint {
            CGPoint(x: (view.x - docOrigin.x) / scale - pad, y: (view.y - docOrigin.y) / scale - pad)
        }
    }

    private func computeLayout(in size: CGSize) -> Layout {
        let padPX = state.background.enabled ? state.background.padding * state.captureScale : 0
        let docW = state.pixelWidth + padPX * 2
        let docH = state.pixelHeight + padPX * 2
        let margin: CGFloat = 24
        let availW = max(100, size.width - margin * 2)
        let availH = max(100, size.height - margin * 2)
        // Never past the capture's real size: a Retina shot is shown at most
        // one image pixel per screen pixel, not blown up and blurred.
        let scale = min(availW / docW, availH / docH, 1 / max(1, state.captureScale))
        let viewW = docW * scale
        let viewH = docH * scale
        return Layout(scale: scale,
                      docOrigin: CGPoint(x: (size.width - viewW) / 2, y: (size.height - viewH) / 2),
                      docSize: CGSize(width: viewW, height: viewH),
                      pad: padPX)
    }

    // MARK: Document rendering

    @ViewBuilder
    private func documentView(layout: Layout) -> some View {
        Canvas { context, size in
            context.scaleBy(x: layout.scale, y: layout.scale)
            drawDocument(into: &context, zoom: layout.scale)
        }
        .allowsHitTesting(false)
    }

    private func drawDocument(into context: inout GraphicsContext, zoom: CGFloat) {
        let pad = state.background.enabled ? state.background.padding * state.captureScale : 0
        let imageRect = CGRect(x: pad, y: pad, width: state.pixelWidth, height: state.pixelHeight)

        if state.background.enabled {
            let colors = BackgroundConfig.presets[min(state.background.presetIndex, BackgroundConfig.presets.count - 1)]
            let gradient = Gradient(colors: colors.map { Color(nsColor: $0) })
            let full = CGRect(x: 0, y: 0,
                              width: state.pixelWidth + pad * 2,
                              height: state.pixelHeight + pad * 2)
            context.fill(Path(full),
                         with: .linearGradient(gradient,
                                               startPoint: CGPoint(x: 0, y: 0),
                                               endPoint: CGPoint(x: full.width, y: full.height)))
            let radius = state.background.cornerRadius * state.captureScale
            let clipPath = Path(roundedRect: imageRect, cornerRadius: radius)
            if state.background.shadow {
                var shadowContext = context
                shadowContext.addFilter(.shadow(color: .black.opacity(0.4),
                                                radius: 20 * state.captureScale,
                                                x: 0, y: 8 * state.captureScale))
                shadowContext.fill(clipPath, with: .color(.black))
            }
            var imageContext = context
            imageContext.clip(to: clipPath)
            imageContext.draw(Image(decorative: state.baseImage, scale: 1), in: imageRect)
            drawAnnotations(into: &imageContext, offset: CGPoint(x: pad, y: pad), zoom: zoom)
        } else {
            context.draw(Image(decorative: state.baseImage, scale: 1), in: imageRect)
            drawAnnotations(into: &context, offset: .zero, zoom: zoom)
        }

        drawCropOverlay(into: &context, pad: pad)
        drawSelectionChrome(into: &context, pad: pad)
    }

    /// Annotations go through EditorRenderer, the same code that writes the
    /// exported file, so what is on screen is exactly what gets saved.
    private func drawAnnotations(into context: inout GraphicsContext, offset: CGPoint, zoom: CGFloat) {
        var context = context
        context.translateBy(x: offset.x, y: offset.y)
        var visible = state.annotations.filter { $0.id != state.editingTextID }
        if let draft = state.draft { visible.append(draft) }
        let snapshot = state
        context.withCGContext { cg in
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            for annotation in visible {
                EditorRenderer.draw(annotation, state: snapshot, shadowScale: zoom)
            }
            NSGraphicsContext.current = previous
        }
    }

    private func drawCropOverlay(into context: inout GraphicsContext, pad: CGFloat) {
        guard state.tool == .crop, let crop = state.cropDraft else { return }
        let rect = crop.offsetBy(dx: pad, dy: pad)
        let full = CGRect(x: 0, y: 0,
                          width: state.pixelWidth + pad * 2,
                          height: state.pixelHeight + pad * 2)
        var dimPath = Path(full)
        dimPath.addRect(rect)
        context.fill(dimPath, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
        context.stroke(Path(rect), with: .color(.white),
                       style: StrokeStyle(lineWidth: 2 / max(0.01, 1), dash: [6, 4]))
    }

    private func drawSelectionChrome(into context: inout GraphicsContext, pad: CGFloat) {
        guard state.tool == .select, let selectedID = state.selectedID,
              let annotation = state.annotation(with: selectedID) else { return }
        let lineWidth = 1.5 / max(0.2, 1)
        let accent = Color(nsColor: .controlAccentColor)
        for handle in handlePoints(for: annotation) {
            let point = CGPoint(x: handle.x + pad, y: handle.y + pad)
            let radius = handleRadiusPX()
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(.white))
            context.stroke(Path(ellipseIn: rect), with: .color(accent), lineWidth: lineWidth * 2)
        }
        if !isPointKind(annotation.kind) {
            let box = annotation.boundingRect.insetBy(dx: -6, dy: -6).offsetBy(dx: pad, dy: pad)
            context.stroke(Path(box), with: .color(accent.opacity(0.8)),
                           style: StrokeStyle(lineWidth: lineWidth, dash: [5, 4]))
        }
    }

    private func isPointKind(_ kind: Annotation.Kind) -> Bool {
        kind == .text || kind == .counter
    }

    private func handleRadiusPX() -> CGFloat {
        6 * state.captureScale
    }

    private func handlePoints(for annotation: Annotation) -> [CGPoint] {
        switch annotation.kind {
        case .line, .arrow:
            return [annotation.start, annotation.end]
        case .rect, .ellipse, .highlight, .redact:
            let rect = annotation.boundingRect
            return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
        default:
            return []
        }
    }

    // MARK: Text editing overlay

    @ViewBuilder
    private func textEditingOverlay(layout: Layout) -> some View {
        if let editingID = state.editingTextID, let annotation = state.annotation(with: editingID) {
            let origin = layout.viewPoint(fromPX: annotation.start)
            TextField("Text", text: $editingText, axis: .horizontal)
                .textFieldStyle(.plain)
                .font(.system(size: annotation.fontSize * layout.scale, weight: .semibold))
                .foregroundColor(Color(nsColor: annotation.color))
                .background(Color.black.opacity(0.25))
                .focused($textFocused)
                .fixedSize()
                .offset(x: origin.x, y: origin.y)
                .onAppear {
                    editingText = annotation.text
                    textFocused = true
                }
                .onSubmit { commitTextEditing() }
                .onExitCommand { commitTextEditing() }
        }
    }

    func commitTextEditing() {
        guard let editingID = state.editingTextID else { return }
        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            state.annotations.removeAll { $0.id == editingID }
        } else if let index = state.annotations.firstIndex(where: { $0.id == editingID }) {
            state.annotations[index].text = trimmed
        }
        state.editingTextID = nil
        textFocused = false
    }

    // MARK: Gesture

    private func canvasGesture(layout: Layout) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let px = layout.pxPoint(fromView: value.location)
                if !dragActive {
                    dragActive = true
                    beginDrag(at: layout.pxPoint(fromView: value.startLocation))
                }
                continueDrag(to: px)
            }
            .onEnded { value in
                let px = layout.pxPoint(fromView: value.location)
                endDrag(at: px)
            }
    }

    @State private var dragActive = false

    private func beginDrag(at px: CGPoint) {
        gestureStartPX = px
        lastPX = px
        didPushUndoForDrag = false

        if state.editingTextID != nil {
            commitTextEditing()
        }

        switch state.tool {
        case .select:
            if let selectedID = state.selectedID, let annotation = state.annotation(with: selectedID) {
                let handles = handlePoints(for: annotation)
                for (index, handle) in handles.enumerated() {
                    if hypot(handle.x - px.x, handle.y - px.y) <= handleRadiusPX() * 1.6 {
                        dragMode = .handle(index)
                        return
                    }
                }
            }
            let tolerance = 6 * state.captureScale
            if let hit = state.annotations.reversed().first(where: { $0.hitTest(px, tolerance: tolerance) }) {
                state.selectedID = hit.id
                dragMode = .move
            } else {
                state.selectedID = nil
                dragMode = .none
            }

        case .crop:
            state.cropDraft = CGRect(origin: px, size: .zero)
            dragMode = .crop

        case .text, .counter:
            dragMode = .none

        default:
            var draft = Annotation(kind: kindForTool(state.tool), start: px, end: px)
            draft.color = state.color
            draft.lineWidth = state.strokePixels
            draft.fontSize = state.fontPixels
            if state.tool == .freehand { draft.path = [px] }
            state.draft = draft
            dragMode = .draft
        }
    }

    private func continueDrag(to px: CGPoint) {
        let delta = CGPoint(x: px.x - lastPX.x, y: px.y - lastPX.y)
        switch dragMode {
        case .draft:
            if var draft = state.draft {
                draft.end = px
                if draft.kind == .freehand { draft.path.append(px) }
                state.draft = draft
            }
        case .move:
            guard abs(delta.x) + abs(delta.y) > 0 else { break }
            pushUndoOnceForDrag()
            state.updateSelected { $0.translate(by: delta) }
        case .handle(let index):
            pushUndoOnceForDrag()
            state.updateSelected { annotation in
                switch annotation.kind {
                case .line, .arrow:
                    if index == 0 { annotation.start = px } else { annotation.end = px }
                default:
                    let rect = annotation.boundingRect
                    var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
                    switch index {
                    case 0: minX = px.x; minY = px.y
                    case 1: maxX = px.x; minY = px.y
                    case 2: minX = px.x; maxY = px.y
                    default: maxX = px.x; maxY = px.y
                    }
                    annotation.start = CGPoint(x: min(minX, maxX), y: min(minY, maxY))
                    annotation.end = CGPoint(x: max(minX, maxX), y: max(minY, maxY))
                }
            }
        case .crop:
            state.cropDraft = CGRect(x: min(gestureStartPX.x, px.x), y: min(gestureStartPX.y, px.y),
                                     width: abs(px.x - gestureStartPX.x), height: abs(px.y - gestureStartPX.y))
        case .none:
            break
        }
        lastPX = px
    }

    private func endDrag(at px: CGPoint) {
        defer {
            dragMode = .none
            dragActive = false
        }

        switch state.tool {
        case .text:
            let clamped = clampToImage(px)
            state.pushUndo()
            var annotation = Annotation(kind: .text, start: clamped, end: clamped)
            annotation.color = state.color
            annotation.fontSize = state.fontPixels
            state.annotations.append(annotation)
            state.selectedID = annotation.id
            state.editingTextID = annotation.id
            return

        case .counter:
            let clamped = clampToImage(px)
            var annotation = Annotation(kind: .counter, start: clamped, end: clamped)
            annotation.color = state.color
            annotation.fontSize = state.fontPixels
            annotation.number = state.counterNext
            // Commit snapshots counterNext before it advances so undo restores the number.
            state.commit(annotation)
            state.counterNext += 1
            return

        default:
            break
        }

        if case .draft = dragMode, let draft = state.draft {
            state.draft = nil
            let size = draft.boundingRect
            let bigEnough = draft.kind == .freehand
                ? draft.path.count > 2
                : (size.width > 3 || size.height > 3 || hypot(draft.end.x - draft.start.x, draft.end.y - draft.start.y) > 3)
            if bigEnough {
                state.commit(draft)
            }
        }
    }

    private func pushUndoOnceForDrag() {
        guard !didPushUndoForDrag else { return }
        didPushUndoForDrag = true
        state.pushUndo()
    }

    private func clampToImage(_ px: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, px.x), state.pixelWidth), y: min(max(0, px.y), state.pixelHeight))
    }

    private func kindForTool(_ tool: EditorTool) -> Annotation.Kind {
        switch tool {
        case .arrow: return .arrow
        case .line: return .line
        case .rect: return .rect
        case .ellipse: return .ellipse
        case .freehand: return .freehand
        case .highlight: return .highlight
        case .redact: return .redact
        default: return .rect
        }
    }
}
