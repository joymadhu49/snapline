import AppKit
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

enum EditorTool: String, CaseIterable, Identifiable {
    case select, arrow, line, rect, ellipse, freehand, highlight, text, counter, redact, crop
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .freehand: return "scribble"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .redact: return "checkerboard.rectangle"
        case .crop: return "crop"
        }
    }

    var help: String {
        let name: String
        switch self {
        case .select: name = "Select and move"
        case .arrow: name = "Arrow"
        case .line: name = "Line"
        case .rect: name = "Rectangle"
        case .ellipse: name = "Ellipse"
        case .freehand: name = "Freehand pen"
        case .highlight: name = "Highlighter"
        case .text: name = "Text"
        case .counter: name = "Numbered counter"
        case .redact: name = "Pixelate area"
        case .crop: name = "Crop"
        }
        return "\(name) (\(key.uppercased()))"
    }

    /// Single key that switches to the tool while the canvas has focus.
    var key: String {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .line: return "l"
        case .rect: return "r"
        case .ellipse: return "o"
        case .freehand: return "p"
        case .highlight: return "h"
        case .text: return "t"
        case .counter: return "n"
        case .redact: return "b"
        case .crop: return "c"
        }
    }
}

struct Annotation: Identifiable {
    enum Kind { case arrow, line, rect, ellipse, freehand, highlight, text, counter, redact }

    let id: UUID
    var kind: Kind
    /// All geometry lives in image pixel space with a top left origin.
    var start: CGPoint
    var end: CGPoint
    var path: [CGPoint] = []
    var text: String = ""
    var number: Int = 0
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 6
    var fontSize: CGFloat = 34

    init(kind: Kind, start: CGPoint, end: CGPoint) {
        self.id = UUID()
        self.kind = kind
        self.start = start
        self.end = end
    }

    var boundingRect: CGRect {
        switch kind {
        case .freehand:
            guard !path.isEmpty else { return CGRect(origin: start, size: .zero) }
            let xs = path.map(\.x), ys = path.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        case .text:
            let size = textSize
            return CGRect(x: start.x, y: start.y, width: size.width, height: size.height)
        case .counter:
            let r = counterRadius
            return CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
        default:
            return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        }
    }

    var counterRadius: CGFloat { fontSize * 0.72 }

    var textSize: CGSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)]
        let measured = (text.isEmpty ? "Text" : text).size(withAttributes: attributes)
        return CGSize(width: measured.width + 8, height: measured.height + 4)
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch kind {
        case .line, .arrow:
            return distanceToSegment(point, start, end) <= tolerance + lineWidth
        case .rect, .ellipse:
            let outer = boundingRect.insetBy(dx: -tolerance, dy: -tolerance)
            let inner = boundingRect.insetBy(dx: tolerance + lineWidth, dy: tolerance + lineWidth)
            return outer.contains(point) && !(inner.width > 0 && inner.height > 0 && inner.contains(point))
        case .highlight, .redact:
            return boundingRect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .freehand:
            return path.contains { hypot($0.x - point.x, $0.y - point.y) <= tolerance + lineWidth * 2 }
        case .text, .counter:
            return boundingRect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let lengthSquared = abx * abx + aby * aby
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * abx + (p.y - a.y) * aby) / lengthSquared
        t = max(0, min(1, t))
        let proj = CGPoint(x: a.x + t * abx, y: a.y + t * aby)
        return hypot(p.x - proj.x, p.y - proj.y)
    }

    mutating func translate(by delta: CGPoint) {
        start.x += delta.x; start.y += delta.y
        end.x += delta.x; end.y += delta.y
        path = path.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
    }
}

struct BackgroundConfig {
    var enabled = false
    var presetIndex = 0
    /// Padding in image points, multiplied by the capture scale on render.
    var padding: CGFloat = 48
    var cornerRadius: CGFloat = 12
    var shadow = true

    static let presets: [[NSColor]] = [
        [NSColor(red: 0.35, green: 0.32, blue: 0.98, alpha: 1), NSColor(red: 0.85, green: 0.32, blue: 0.85, alpha: 1)],
        [NSColor(red: 0.10, green: 0.55, blue: 0.95, alpha: 1), NSColor(red: 0.15, green: 0.90, blue: 0.75, alpha: 1)],
        [NSColor(red: 0.98, green: 0.55, blue: 0.25, alpha: 1), NSColor(red: 0.95, green: 0.25, blue: 0.45, alpha: 1)],
        [NSColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1), NSColor(red: 0.22, green: 0.24, blue: 0.30, alpha: 1)],
        [NSColor(red: 0.92, green: 0.92, blue: 0.94, alpha: 1), NSColor(red: 0.80, green: 0.82, blue: 0.88, alpha: 1)],
        [NSColor(red: 0.16, green: 0.55, blue: 0.35, alpha: 1), NSColor(red: 0.55, green: 0.85, blue: 0.40, alpha: 1)]
    ]
}

/// Observable editor document.
final class EditorState: ObservableObject {
    @Published var baseImage: CGImage
    let captureScale: CGFloat
    var savedURL: URL?
    /// The on-disk file the capture came in as, saved folder or internal cache.
    /// Done and drag out write the edited result back over it, so everything
    /// that already points at this capture hands out the edited image.
    var sourceFileURL: URL?

    @Published var annotations: [Annotation] = []
    // The last tool, colour, and stroke carry over to the next capture, so a
    // run of shots marked up the same way needs no setup each time.
    @Published var tool: EditorTool = EditorState.remembered.tool {
        didSet { if tool != .crop { UserDefaults.standard.set(tool.rawValue, forKey: "editorLastTool") } }
    }
    @Published var color: NSColor = EditorState.remembered.color {
        didSet {
            if let index = EditorState.palette.firstIndex(of: color) {
                UserDefaults.standard.set(index, forKey: "editorLastColor")
            }
        }
    }
    @Published var strokeChoice: CGFloat = EditorState.remembered.stroke {
        didSet { UserDefaults.standard.set(Double(strokeChoice), forKey: "editorLastStroke") }
    }
    @Published var selectedID: UUID?
    @Published var draft: Annotation?
    @Published var cropDraft: CGRect?
    @Published var background = BackgroundConfig()
    @Published var editingTextID: UUID?

    var counterNext = 1

    static let palette: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemPurple, .systemPink, .white, .black
    ]

    private static var remembered: (tool: EditorTool, color: NSColor, stroke: CGFloat) {
        let defaults = UserDefaults.standard
        let tool = defaults.string(forKey: "editorLastTool").flatMap(EditorTool.init(rawValue:)) ?? .arrow
        let colorIndex = defaults.object(forKey: "editorLastColor") as? Int ?? 0
        let color = palette.indices.contains(colorIndex) ? palette[colorIndex] : .systemRed
        let stroke = defaults.object(forKey: "editorLastStroke") as? Double ?? 3
        return (tool == .crop ? .arrow : tool, color, CGFloat(stroke))
    }

    /// Switches tools the way the toolbar does: leaving crop drops the draft,
    /// and leaving select drops the selection.
    func choose(_ newTool: EditorTool) {
        tool = newTool
        if newTool != .crop { cropDraft = nil }
        if newTool != .select { selectedID = nil }
    }

    private struct Snapshot {
        var image: CGImage
        var annotations: [Annotation]
        var counterNext: Int
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var cachedPixelated: CGImage?

    init(capture: Capture) {
        self.baseImage = capture.image
        self.captureScale = max(1, capture.scale)
        self.savedURL = capture.savedURL
        self.sourceFileURL = capture.fileURL
    }

    var pixelWidth: CGFloat { CGFloat(baseImage.width) }
    var pixelHeight: CGFloat { CGFloat(baseImage.height) }

    /// Effective stroke width in pixels.
    var strokePixels: CGFloat { strokeChoice * captureScale }
    var fontPixels: CGFloat { (strokeChoice * 5 + 8) * captureScale }

    var pixelatedImage: CGImage {
        if let cachedPixelated { return cachedPixelated }
        let generated = EditorRenderer.pixelate(baseImage) ?? baseImage
        cachedPixelated = generated
        return generated
    }

    // MARK: Undo

    func pushUndo() {
        undoStack.append(Snapshot(image: baseImage, annotations: annotations, counterNext: counterNext))
        if undoStack.count > 60 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(Snapshot(image: baseImage, annotations: annotations, counterNext: counterNext))
        restore(snapshot)
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(Snapshot(image: baseImage, annotations: annotations, counterNext: counterNext))
        restore(snapshot)
    }

    private func restore(_ snapshot: Snapshot) {
        if baseImage !== snapshot.image { cachedPixelated = nil }
        baseImage = snapshot.image
        annotations = snapshot.annotations
        counterNext = snapshot.counterNext
        selectedID = nil
        editingTextID = nil
        cropDraft = nil
    }

    // MARK: Mutations

    func commit(_ annotation: Annotation) {
        pushUndo()
        annotations.append(annotation)
    }

    func deleteSelected() {
        guard let selectedID else { return }
        pushUndo()
        annotations.removeAll { $0.id == selectedID }
        self.selectedID = nil
        editingTextID = nil
    }

    func updateSelected(_ transform: (inout Annotation) -> Void) {
        guard let selectedID, let index = annotations.firstIndex(where: { $0.id == selectedID }) else { return }
        transform(&annotations[index])
    }

    func annotation(with id: UUID) -> Annotation? {
        annotations.first { $0.id == id }
    }

    func applyCrop() {
        guard let cropDraft else { return }
        let rect = cropDraft.intersection(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)).integral
        guard rect.width >= 8, rect.height >= 8, let cropped = baseImage.cropping(to: rect) else {
            self.cropDraft = nil
            return
        }
        pushUndo()
        baseImage = cropped
        cachedPixelated = nil
        let delta = CGPoint(x: -rect.origin.x, y: -rect.origin.y)
        annotations = annotations.map { annotation in
            var copy = annotation
            copy.translate(by: delta)
            return copy
        }
        self.cropDraft = nil
        tool = .select
    }
}
