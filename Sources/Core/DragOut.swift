import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What a card hands to another app when it is dragged out.
struct DragPayload {
    /// Resolves the file that should land in the receiving app. Called at drag
    /// time so an unsaved capture only touches the disk when it is really needed.
    var fileURL: () -> URL?
    /// Optional drag image; the file icon is used when this is nil.
    var preview: () -> NSImage?
    /// Runs only when a destination accepts the drop, never on cancellation.
    var onDropCompleted: (() -> Void)?

    init(fileURL: @escaping () -> URL?, preview: @escaping () -> NSImage? = { nil },
         onDropCompleted: (() -> Void)? = nil) {
        self.fileURL = fileURL
        self.preview = preview
        self.onDropCompleted = onDropCompleted
    }
}

/// Starts an AppKit drag on behalf of a SwiftUI card.
///
/// SwiftUI's own `.onDrag` advertises a single item provider, which Finder and
/// chat apps understand but terminals and plain text fields ignore. Running the
/// drag through AppKit lets one gesture carry the file URL, the POSIX path, and
/// the image bytes at once, so the same drag lands correctly in Slack, Figma,
/// Terminal, and an agent prompt.
///
/// The view never handles mouse events itself. A hosting view keeps hit testing
/// for everything SwiftUI draws, so a layer underneath would never see a click;
/// instead SwiftUI recognises the gesture and hands the drag over here.
final class DragOutSource: NSView, NSDraggingSource, NSPasteboardItemDataProvider {
    /// True while any card anywhere is mid drag. Floating panels use this to stay
    /// open after they lose key focus to the app being dropped on.
    private(set) static var isDragging = false

    /// Retained for the lazy image representations the drop target may ask for.
    private var draggedURL: URL?
    private var onDropCompleted: (() -> Void)?

    /// Purely an anchor for the dragging session; clicks belong to SwiftUI.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func beginDrag(_ payload: DragPayload) {
        guard !DragOutSource.isDragging, let window, let url = payload.fileURL() else { return }
        guard let event = dragEvent(in: window) else { return }
        draggedURL = url
        onDropCompleted = payload.onDropCompleted

        let item = NSPasteboardItem()
        // Order is priority order for the receiver: apps that want a real file
        // take the URL, terminals and text fields fall back to the path string,
        // canvases that only accept bitmaps get the image data last.
        _ = item.setString(url.absoluteString, forType: .fileURL)
        // Terminals ask for text before they ask for a file URL, so the text has
        // to be a path a shell can actually use. Escaping here produces the same
        // result a terminal would have produced from the file URL itself, and
        // still gives plain text targets something meaningful.
        _ = item.setString(DragOutSource.shellEscaped(url.path), forType: .string)
        if isImageFile(url) {
            _ = item.setDataProvider(self, forTypes: [.png, .tiff])
        }

        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let preview = payload.preview() ?? NSWorkspace.shared.icon(forFile: url.path)
        let frame = dragFrame(for: preview.size)
        dragItem.setDraggingFrame(frame, contents: roundedPreview(preview, size: frame.size))

        DragOutSource.isDragging = true
        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    /// SwiftUI is mid gesture, so the current event is normally the drag itself.
    /// Synthesising one keeps the drag alive if it ever is not.
    private func dragEvent(in window: NSWindow) -> NSEvent? {
        if let current = NSApp.currentEvent,
           current.type == .leftMouseDragged || current.type == .leftMouseDown {
            return current
        }
        return NSEvent.mouseEvent(with: .leftMouseDragged,
                                  location: window.convertPoint(fromScreen: NSEvent.mouseLocation),
                                  modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber,
                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }

    /// Backslash escapes everything a POSIX shell would otherwise interpret.
    static func shellEscaped(_ path: String) -> String {
        let special = CharacterSet(charactersIn: " \t\n\"'`$&;|<>()[]{}*?!#\\^~")
        var result = String.UnicodeScalarView()
        for scalar in path.unicodeScalars {
            if special.contains(scalar) { result.append("\\") }
            result.append(scalar)
        }
        return String(result)
    }

    private func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// Centres the drag image on the card at the size it is already shown.
    private func dragFrame(for imageSize: NSSize) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let fit = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = NSSize(width: imageSize.width * fit, height: imageSize.height * fit)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    private func roundedPreview(_ image: NSImage, size: NSSize, radius: CGFloat = 8) -> NSImage {
        guard size.width >= 1, size.height >= 1 else { return image }
        let result = NSImage(size: size)
        result.lockFocus()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: radius, yRadius: radius).addClip()
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        result.unlockFocus()
        return result
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        DragOutSource.isDragging = false
        let completion = onDropCompleted
        onDropCompleted = nil
        if !operation.isEmpty { completion?() }
        NotificationCenter.default.post(name: .snaplineDragEnded, object: nil)
    }

    // MARK: Lazy image representations

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        guard let url = draggedURL, let data = try? Data(contentsOf: url) else { return }
        if type == .png, url.pathExtension.lowercased() == "png" {
            _ = item.setData(data, forType: .png)
            return
        }
        guard let rep = NSBitmapImageRep(data: data) else { return }
        let converted = type == .png ? rep.representation(using: .png, properties: [:]) : rep.tiffRepresentation
        if let converted { _ = item.setData(converted, forType: type) }
    }
}

/// Bridge between a SwiftUI card and the AppKit view that owns its drags.
final class DragOutHandle {
    fileprivate weak var source: DragOutSource?

    func drag(_ payload: DragPayload) {
        source?.beginDrag(payload)
    }
}

private struct DragOutAnchor: NSViewRepresentable {
    let handle: DragOutHandle

    func makeNSView(context: Context) -> DragOutSource {
        let view = DragOutSource()
        handle.source = view
        return view
    }

    func updateNSView(_ nsView: DragOutSource, context: Context) {
        handle.source = nsView
    }
}

private struct DragOutModifier: ViewModifier {
    let handle: DragOutHandle
    let payload: () -> DragPayload

    @State private var armed = false

    func body(content: Content) -> some View {
        content
            .background(DragOutAnchor(handle: handle))
            // Simultaneous rather than exclusive so a plain click still counts as
            // a tap; only movement past the threshold turns into a drag.
            .simultaneousGesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { _ in
                        guard !armed else { return }
                        armed = true
                        handle.drag(payload())
                    }
                    .onEnded { _ in armed = false }
            )
            .onReceive(NotificationCenter.default.publisher(for: .snaplineDragEnded)) { _ in
                armed = false
            }
    }
}

extension View {
    /// Makes this view draggable into any app, Finder, or terminal.
    func dragOut(_ handle: DragOutHandle, payload: @escaping () -> DragPayload) -> some View {
        modifier(DragOutModifier(handle: handle, payload: payload))
    }
}

extension Notification.Name {
    static let snaplineDragEnded = Notification.Name("snaplineDragEnded")
}
