import AppKit
import QuartzCore

enum OverlayPurpose {
    case still
    case ocr
    case record
    case timed
    /// The dedicated Capture Window command. This is the only mode where
    /// hovering highlights windows and a click grabs one; every other mode is
    /// a pure area marquee so a drag can never turn into a window capture.
    case window
}

enum SelectionResult {
    /// Rect in global AppKit coordinates plus the screen it belongs to.
    case rect(CGRect, NSScreen)
    case window(WindowInfo)
    case frozenRect(CGImage, CGRect, NSScreen, CGFloat)
    case cancelled
}

struct WindowInfo {
    let windowID: CGWindowID
    /// Global AppKit bottom left origin frame.
    let frame: CGRect
    let title: String
    let ownerName: String
}

enum WindowLister {
    /// On screen normal windows, front to back, excluding this app.
    static func windowsFrontToBack() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        var result: [WindowInfo] = []
        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32, pid != myPID,
                  let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let cgRect = CGRect(x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                                width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0)
            guard cgRect.width >= 40, cgRect.height >= 40 else { continue }
            let frame = CaptureEngine.flipped(cgRect)
            let title = entry[kCGWindowName as String] as? String ?? ""
            let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
            result.append(WindowInfo(windowID: windowID, frame: frame, title: title, ownerName: owner))
        }
        return result
    }

    static func window(at globalPoint: CGPoint) -> WindowInfo? {
        windowsFrontToBack().first { $0.frame.contains(globalPoint) }
    }
}

/// Never key, never main, never activating. Taking focus from the frontmost
/// app closes its transient UI — an open menu, a Gmail details popover, a
/// tooltip — before the capture happens, which is exactly what a screenshot
/// tool must not do. The native capture UI stays out of focus the same way.
final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets Snapline own the cursor while it is not the active app. The overlay
/// never activates (that would close the frontmost app's menus), and without
/// this the app underneath takes the cursor back, most visibly once the
/// pointer crosses onto another display. Looked up at runtime, so a missing
/// symbol just leaves the default behaviour.
enum BackgroundCursor {
    private static var enabled = false

    static func enable() {
        guard !enabled else { return }
        enabled = true
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        guard let handle = dlopen(nil, RTLD_NOW),
              let connection = dlsym(handle, "_CGSDefaultConnection"),
              let setProperty = dlsym(handle, "CGSSetConnectionProperty") else { return }
        let cid = unsafeBitCast(connection, to: DefaultConnection.self)()
        _ = unsafeBitCast(setProperty, to: SetProperty.self)(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}


/// Recording toggles shown on the bar under a recording selection. The overlay
/// only holds them; the coordinator seeds them from settings and writes changes
/// back, so this file still compiles on its own in the capture regression test.
struct RecordOptions {
    var systemAudio = true
    var microphone = false
    var showCursor = true
}

enum RecordBarItem {
    case systemAudio, microphone, cursor, record, cancel
}

/// Geometry of the bar under a recording selection, in the bar's own bottom
/// left coordinates. The view that draws it and the controller that hit tests
/// it share this one layout, so the two can never disagree.
struct RecordBarLayout {
    static let shared = RecordBarLayout()
    static let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    static let recordFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static var showsMicrophone: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    let size: CGSize
    let sizeTextX: CGFloat
    let dividers: [CGFloat]
    let items: [(RecordBarItem, CGRect)]

    private init() {
        let height: CGFloat = 46
        let button: CGFloat = 32
        let buttonY = (height - button) / 2
        var x: CGFloat = 16
        sizeTextX = x
        // Sized for the widest reading, so the bar never jitters while resizing.
        let sizeWidth = NSAttributedString(string: "0000 × 0000", attributes: [.font: Self.sizeFont]).size().width
        x += ceil(sizeWidth) + 12
        var dividers = [x]
        x += 9
        var items: [(RecordBarItem, CGRect)] = []
        let toggles: [RecordBarItem] = Self.showsMicrophone ? [.systemAudio, .microphone, .cursor] : [.systemAudio, .cursor]
        for toggle in toggles {
            items.append((toggle, CGRect(x: x, y: buttonY, width: button, height: button)))
            x += button + 2
        }
        x += 7
        dividers.append(x)
        x += 9
        let recordText = NSAttributedString(string: "Record", attributes: [.font: Self.recordFont]).size().width
        let recordWidth = ceil(recordText) + 44
        items.append((.record, CGRect(x: x, y: buttonY, width: recordWidth, height: button)))
        x += recordWidth + 4
        items.append((.cancel, CGRect(x: x, y: buttonY, width: button, height: button)))
        x += button + 7
        size = CGSize(width: x, height: height)
        self.dividers = dividers
        self.items = items
    }

    func item(at local: CGPoint) -> RecordBarItem? {
        items.first { $0.1.insetBy(dx: -1, dy: -4).contains(local) }?.0
    }

    /// Below the selection, else above it, else tucked inside its bottom edge;
    /// always fully on the selection's screen.
    func frame(for selection: CGRect, on screen: CGRect) -> CGRect {
        let gap: CGFloat = 12
        var y = selection.minY - gap - size.height
        if y < screen.minY + 8 {
            y = selection.maxY + gap
            if y + size.height > screen.maxY - 8 { y = max(selection.minY + gap, screen.minY + 8) }
        }
        let x = min(max(selection.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        return CGRect(x: round(x), y: round(y), width: size.width, height: size.height)
    }
}

/// Full screen dimmed selection chrome across all displays.
///
/// Everything on screen is a CALayer, so tracking the cursor only swaps layer
/// paths and frames that the window server composites; nothing rasterises a
/// screen sized bitmap per event. An earlier version redrew the whole view
/// with Core Graphics on every mouse move and hit WindowServer for the window
/// list on each one, which made a fast drag trail visibly behind the pointer.
///
/// Selection state lives here rather than in the per screen views, so a drag
/// that crosses displays shows up on every one of them.
///
/// Recording works like CleanShot's: releasing the drag does not start
/// anything. The area stays up with handles to move and resize it, and a bar
/// underneath carries the size, the audio and cursor toggles, and Record.
final class SelectionOverlayController {
    static var current: SelectionOverlayController?

    let purpose: OverlayPurpose
    private let completion: (SelectionResult) -> Void
    private var windows: [OverlayWindow] = []
    private var views: [SelectionView] = []
    private var frozenDisplays: [NSScreen: FrozenDisplay] = [:]
    private var freezeTask: Task<Void, Never>?
    private var displayObserver: NSObjectProtocol?
    private var finished = false
    private var keyDownMonitor: Any?
    private var flagsMonitor: Any?
    private var windowListTimer: Timer?
    private var keyPollTimer: Timer?

    // Shared selection state, global AppKit coordinates.
    private(set) var dragStartGlobal: CGPoint?
    private(set) var dragCurrentGlobal: CGPoint?
    private(set) var isDragging = false
    private(set) var hoverWindow: WindowInfo?
    private(set) var mouseGlobal: CGPoint = NSEvent.mouseLocation
    /// The display a drag started on. A selection stays on one display, as in
    /// CleanShot, instead of spanning two and snapping to one on release.
    private var dragScreenFrame: CGRect?
    private var cachedWindows: [WindowInfo] = []
    private var lastPolledFlags: NSEvent.ModifierFlags = []
    private var lastPolledSpace = false
    /// A selection that ended before the frozen frames arrived. It completes
    /// as soon as they do, so a fast flick never grabs the live desktop.
    private var pendingResult: SelectionResult?

    // Adjust phase (recording only).
    private enum Grab: Equatable {
        case move
        case resize(left: Bool, right: Bool, bottom: Bool, top: Bool)
    }
    /// The recording area after the first drag, still open to adjustment.
    private(set) var adjustRect: CGRect?
    private var grab: Grab?
    private var grabStartRect = CGRect.zero
    private var grabStartPoint = CGPoint.zero
    private var pressOnBar = false
    private var pressedBarItem: RecordBarItem?
    private(set) var hoveredBarItem: RecordBarItem?
    var recordOptions = RecordOptions()
    var onRecordOptionsChanged: ((RecordOptions) -> Void)?
    var isManipulating: Bool { grab != nil }

    init(purpose: OverlayPurpose, completion: @escaping (SelectionResult) -> Void) {
        self.purpose = purpose
        self.completion = completion
    }

    private var allowsWindowPick: Bool {
        purpose == .window
    }

    private var usesAdjustPhase: Bool {
        purpose == .record
    }

    func begin() {
        guard SelectionOverlayController.current == nil, !finished else { return }
        SelectionOverlayController.current = self
        let screens = NSScreen.screens
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.finish(.cancelled) }
        // The crosshair and dim go up on the very key press. Waiting for the
        // frozen frames first left a visible beat (60 to 160 ms) between the
        // shortcut and anything happening. ScreenCaptureKit excludes Snapline's
        // own windows, so freezing underneath the overlay still yields a clean
        // desktop, and the frame lands under the dim before a drag gets going.
        showOverlay(on: screens)
        guard needsFrozenPixels else { return }
        freezeTask = Task { @MainActor [weak self] in
            do {
                let snapshots = try await CaptureEngine.freezeDisplays(screens)
                guard let self, !self.finished, !Task.isCancelled else { return }
                self.frozenDisplays = snapshots
                self.freezeTask = nil
                for view in self.views {
                    if let snapshot = snapshots[view.assignedScreen] { view.setSnapshot(snapshot.image) }
                }
                self.refreshViews()
                // A selection finished before the frames arrived completes now.
                if let pending = self.pendingResult {
                    self.pendingResult = nil
                    self.finish(pending)
                }
            } catch {
                guard let self, !self.finished else { return }
                NSLog("Snapline screen freeze failed: \(error)")
                self.pendingResult = nil
                self.finish(.cancelled)
                Toast.show("Screen capture failed. Please try again.")
            }
        }
    }

    /// Still and OCR selections are cut from frozen frames, never the live desktop.
    private var needsFrozenPixels: Bool {
        purpose == .still || purpose == .ocr
    }

    private func showOverlay(on screens: [NSScreen]) {
        // Deliberately no NSApp.activate: stealing focus from the frontmost app
        // made pages and apps dismiss their popovers and menus before the shot.
        refreshWindowList()

        for screen in screens {
            let window = OverlayWindow(contentRect: screen.frame,
                                       styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), screen: screen)
            view.controller = self
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            windows.append(window)
            views.append(view)
        }
        refreshViews()
        // Every window is fully built before any of them is shown, so the dim
        // lands on all displays in the same frame instead of one at a time.
        windows.forEach { $0.orderFrontRegardless() }
        BackgroundCursor.enable()
        NSCursor.crosshair.set()

        // The dim fades in rather than snapping on, so the screen does not read
        // as blinking dark. The crosshair and hint arrive at full strength at
        // once: that is the instant feedback the shortcut is waiting for.
        for view in views { view.fadeInDim() }

        // The overlay never takes key focus, so keyboard events keep going to
        // whichever app was frontmost. Escape, Return, and space are therefore
        // read straight from the hardware key state on a fast clock instead of
        // arriving as events. The local monitor stays as well: when Snapline
        // itself happens to be the active app it swallows those keys so they
        // do not beep or leak anywhere.
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53, 36, 76, 49: return nil // handled by the key poll
            default: return event
            }
        }
        // Shift and Option reshape the marquee live, so a modifier change has
        // to repaint even though the mouse did not move.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.refreshViews()
            return event
        }
        // One tick per display frame: ⇧, ⌥, and space reshape the marquee while
        // the mouse is still, and at 20 Hz that change visibly lagged the key.
        let poll = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.pollKeys()
        }
        RunLoop.main.add(poll, forMode: .common)
        keyPollTimer = poll

        // The window list is refreshed on a slow clock instead of per mouse
        // move; hover hit testing runs against this cache and costs nothing.
        windowListTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.refreshWindowList()
        }
        windowListTimer?.tolerance = 0.3
    }

    /// Runs whether or not Snapline is the active app: CGEventSource reads the
    /// current hardware key state without any event routing or permissions.
    private func pollKeys() {
        if CGEventSource.keyState(.combinedSessionState, key: 53) { // Escape
            finish(.cancelled)
            return
        }
        if CGEventSource.keyState(.combinedSessionState, key: 36)
            || CGEventSource.keyState(.combinedSessionState, key: 76) { // Return
            if adjustRect != nil {
                confirmAdjustedArea()
                return
            }
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            if let screen { finish(.rect(screen.frame, screen)) }
            return
        }
        // Mouse moved events reach a background app's windows unreliably, and
        // least of all on a second display, so the pointer is also read on this
        // clock: the chrome and the cursor follow it on every display.
        let mouse = NSEvent.mouseLocation
        if mouse != mouseGlobal {
            if NSEvent.pressedMouseButtons & 1 == 0 {
                if dragStartGlobal == nil, grab == nil, !pressOnBar { pointerMoved(to: mouse) }
            } else if dragStartGlobal != nil || grab != nil {
                dragChanged(to: mouse)
            }
        }
        // Space and the modifiers reshape the marquee even while the mouse is
        // still, so a drag in progress repaints when either changes.
        let flags = NSEvent.modifierFlags.intersection([.shift, .option])
        let space = CGEventSource.keyState(.combinedSessionState, key: 49)
        if isDragging, flags != lastPolledFlags || space != lastPolledSpace { refreshViews() }
        lastPolledFlags = flags
        lastPolledSpace = space
    }

    private func refreshWindowList() {
        guard allowsWindowPick else { return }
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let list = WindowLister.windowsFrontToBack()
            DispatchQueue.main.async {
                guard let self, !self.finished else { return }
                self.cachedWindows = list
                if !self.isDragging {
                    self.hoverWindow = list.first { $0.frame.contains(self.mouseGlobal) }
                    self.refreshViews()
                }
            }
        }
    }

    // MARK: Event routing from the per screen views

    func pointerMoved(to point: CGPoint) {
        mouseGlobal = point
        if !isDragging {
            hoverWindow = allowsWindowPick ? cachedWindows.first { $0.frame.contains(point) } : nil
        }
        hoveredBarItem = barItem(at: point)
        refreshViews()
        cursor(at: point).set()
    }

    func pointerExited() {
        hoverWindow = nil
        hoveredBarItem = nil
        refreshViews()
    }

    func dragBegan(at point: CGPoint) {
        mouseGlobal = point
        if let rect = adjustRect {
            if let bar = recordBarFrame()?.frame, bar.contains(point) {
                // The bar swallows the press even between its buttons.
                pressOnBar = true
                pressedBarItem = barItem(at: point)
                return
            }
            if let hit = grabHit(at: point, in: rect) {
                grab = hit
                grabStartRect = rect
                grabStartPoint = point
                refreshViews()
                cursor(at: point).set()
                return
            }
        }
        dragScreenFrame = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }?.frame
        dragStartGlobal = point
        dragCurrentGlobal = point
        isDragging = false
    }

    func dragChanged(to point: CGPoint) {
        mouseGlobal = point
        if pressOnBar {
            hoveredBarItem = barItem(at: point)
            refreshViews()
            return
        }
        if grab != nil {
            applyGrab(to: point)
            refreshViews()
            return
        }
        let point = clampedToDragScreen(point)
        // Space held mid drag moves the selection instead of resizing it.
        let spaceHeld = CGEventSource.keyState(.combinedSessionState, key: 49)
        if spaceHeld, isDragging, let current = dragCurrentGlobal, let start = dragStartGlobal {
            dragStartGlobal = CGPoint(x: start.x + point.x - current.x,
                                      y: start.y + point.y - current.y)
        }
        dragCurrentGlobal = point
        if !isDragging, let start = dragStartGlobal,
           hypot(point.x - start.x, point.y - start.y) > 3 {
            isDragging = true
            hoverWindow = nil
            // A fresh drag outside the area replaces it; a stray click does not.
            adjustRect = nil
        }
        refreshViews()
    }

    func dragEnded(in window: NSWindow?) {
        if pressOnBar {
            pressOnBar = false
            let released = barItem(at: mouseGlobal)
            if let pressed = pressedBarItem, pressed == released { perform(pressed) }
            pressedBarItem = nil
            refreshViews()
            return
        }
        if grab != nil {
            grab = nil
            refreshViews()
            cursor(at: mouseGlobal).set()
            return
        }
        if isDragging, let rect = selectionRect(), rect.width >= 4, rect.height >= 4 {
            if let screen = screen(for: rect) ?? window?.screen ?? NSScreen.main {
                let clipped = rect.intersection(screen.frame)
                if usesAdjustPhase {
                    adjustRect = Self.rounded(clipped)
                    isDragging = false
                    dragStartGlobal = nil
                    dragCurrentGlobal = nil
                    dragScreenFrame = nil
                    hoveredBarItem = barItem(at: mouseGlobal)
                    refreshViews()
                    cursor(at: mouseGlobal).set()
                    return
                }
                finish(.rect(clipped, screen))
                return
            }
        }
        if !isDragging, let hover = hoverWindow {
            finish(.window(hover))
            return
        }
        isDragging = false
        dragStartGlobal = nil
        dragCurrentGlobal = nil
        dragScreenFrame = nil
        refreshViews()
    }

    /// The rect being dragged out. Shift locks it to a square and Option grows
    /// it from the starting point, matching the system capture overlay.
    func selectionRect() -> CGRect? {
        guard let start = dragStartGlobal, let current = dragCurrentGlobal else { return nil }
        let flags = NSEvent.modifierFlags
        var dx = current.x - start.x
        var dy = current.y - start.y
        if flags.contains(.shift) {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        var rect: CGRect
        if flags.contains(.option) {
            rect = CGRect(x: start.x - abs(dx), y: start.y - abs(dy),
                          width: abs(dx) * 2, height: abs(dy) * 2)
        } else {
            rect = CGRect(x: min(start.x, start.x + dx), y: min(start.y, start.y + dy),
                          width: abs(dx), height: abs(dy))
        }
        if let frame = dragScreenFrame { rect = rect.intersection(frame) }
        return rect.isNull ? nil : rect
    }

    private func clampedToDragScreen(_ point: CGPoint) -> CGPoint {
        guard let frame = dragScreenFrame else { return point }
        return CGPoint(x: min(max(point.x, frame.minX), frame.maxX),
                       y: min(max(point.y, frame.minY), frame.maxY))
    }

    // MARK: Adjust phase

    /// The recording bar's global frame and the screen it sits on.
    func recordBarFrame() -> (frame: CGRect, screen: NSScreen)? {
        guard let rect = adjustRect, let screen = screen(for: rect) else { return nil }
        return (RecordBarLayout.shared.frame(for: rect, on: screen.frame), screen)
    }

    private func barItem(at point: CGPoint) -> RecordBarItem? {
        guard let bar = recordBarFrame()?.frame, bar.contains(point) else { return nil }
        return RecordBarLayout.shared.item(at: CGPoint(x: point.x - bar.minX, y: point.y - bar.minY))
    }

    private func perform(_ item: RecordBarItem) {
        switch item {
        case .record:
            confirmAdjustedArea()
            return
        case .cancel:
            finish(.cancelled)
            return
        case .systemAudio: recordOptions.systemAudio.toggle()
        case .microphone: recordOptions.microphone.toggle()
        case .cursor: recordOptions.showCursor.toggle()
        }
        onRecordOptionsChanged?(recordOptions)
    }

    private func confirmAdjustedArea() {
        guard let rect = adjustRect, let screen = screen(for: rect) else { return }
        finish(.rect(rect.intersection(screen.frame), screen))
    }

    /// Edges within reach of the pointer resize, the inside moves. Handles
    /// are small, so the reach extends a little past the border both ways.
    private func grabHit(at point: CGPoint, in rect: CGRect) -> Grab? {
        let reach: CGFloat = 9
        guard rect.insetBy(dx: -reach, dy: -reach).contains(point) else { return nil }
        var left = abs(point.x - rect.minX) <= reach
        var right = abs(point.x - rect.maxX) <= reach
        var bottom = abs(point.y - rect.minY) <= reach
        var top = abs(point.y - rect.maxY) <= reach
        // On a thin area both sides can be in reach; the nearer one wins.
        if left && right {
            if abs(point.x - rect.minX) < abs(point.x - rect.maxX) { right = false } else { left = false }
        }
        if bottom && top {
            if abs(point.y - rect.minY) < abs(point.y - rect.maxY) { top = false } else { bottom = false }
        }
        if left || right || bottom || top {
            return .resize(left: left, right: right, bottom: bottom, top: top)
        }
        return rect.contains(point) ? .move : nil
    }

    private func applyGrab(to point: CGPoint) {
        guard let grab, let screen = screen(for: grabStartRect)?.frame else { return }
        let dx = point.x - grabStartPoint.x
        let dy = point.y - grabStartPoint.y
        let start = grabStartRect
        var rect: CGRect
        switch grab {
        case .move:
            // The area follows the pointer onto another display, shrinking only
            // if that display is too small to hold it.
            let target = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }?.frame ?? screen
            let width = min(start.width, target.width), height = min(start.height, target.height)
            rect = CGRect(x: min(max(start.minX + dx, target.minX), target.maxX - width),
                          y: min(max(start.minY + dy, target.minY), target.maxY - height),
                          width: width, height: height)
        case let .resize(left, right, bottom, top):
            let minSide: CGFloat = 24
            var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
            if left { minX = min(max(start.minX + dx, screen.minX), maxX - minSide) }
            if right { maxX = max(min(start.maxX + dx, screen.maxX), minX + minSide) }
            if bottom { minY = min(max(start.minY + dy, screen.minY), maxY - minSide) }
            if top { maxY = max(min(start.maxY + dy, screen.maxY), minY + minSide) }
            rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        adjustRect = Self.rounded(rect)
    }

    private func cursor(at point: CGPoint) -> NSCursor {
        guard let rect = adjustRect, !isDragging else { return .crosshair }
        if let bar = recordBarFrame()?.frame, bar.contains(point) {
            return barItem(at: point) == nil ? .arrow : .pointingHand
        }
        switch grab ?? grabHit(at: point, in: rect) {
        case .move?:
            return grab == nil ? .openHand : .closedHand
        case let .resize(left, right, bottom, top)?:
            return Self.resizeCursor(left: left, right: right, bottom: bottom, top: top)
        case nil:
            return .crosshair
        }
    }

    private static func resizeCursor(left: Bool, right: Bool, bottom: Bool, top: Bool) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch (left, right, bottom, top) {
            case (true, _, _, true): position = .topLeft
            case (_, true, _, true): position = .topRight
            case (true, _, true, _): position = .bottomLeft
            case (_, true, true, _): position = .bottomRight
            case (true, _, _, _): position = .left
            case (_, true, _, _): position = .right
            case (_, _, true, _): position = .bottom
            default: position = .top
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        if (left || right) && !(bottom || top) { return .resizeLeftRight }
        if (bottom || top) && !(left || right) { return .resizeUpDown }
        return .crosshair
    }

    private static func rounded(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(),
               width: rect.width.rounded(), height: rect.height.rounded())
    }

    /// The screen holding most of the rect's area.
    private func screen(for rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { a, b in
            let areaA = a.frame.intersection(rect)
            let areaB = b.frame.intersection(rect)
            return areaA.width * areaA.height < areaB.width * areaB.height
        }
    }

    private func refreshViews() {
        views.forEach { $0.refresh() }
    }

    /// Stops listening to the keyboard and pointer clocks and hands the cursor back.
    private func stopInput() {
        windowListTimer?.invalidate()
        windowListTimer = nil
        keyPollTimer?.invalidate()
        keyPollTimer = nil
        for monitor in [keyDownMonitor, flagsMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        keyDownMonitor = nil
        flagsMonitor = nil
        NSCursor.arrow.set()
    }

    func finish(_ result: SelectionResult) {
        guard !finished else { return }
        if case .rect = result, needsFrozenPixels, frozenDisplays.isEmpty, freezeTask != nil {
            // Released before the frames landed, usually a fast flick right
            // after the shortcut. The overlay leaves now so the release feels
            // immediate; the crop happens the moment the frames arrive.
            guard pendingResult == nil else { return }
            pendingResult = result
            stopInput()
            windows.forEach { $0.orderOut(nil) }
            return
        }
        finished = true
        var deliveredResult = result
        if case let .rect(rect, screen) = result, needsFrozenPixels {
            do {
                guard let snapshot = frozenDisplays[screen] else { throw CaptureError.captureFailed }
                let image = try snapshot.crop(globalRect: rect)
                deliveredResult = .frozenRect(image, rect, screen, snapshot.scale)
            } catch {
                NSLog("Snapline frozen crop failed: \(error)")
                deliveredResult = .cancelled
                Toast.show("Screen capture failed. Please try again.")
            }
        }
        freezeTask?.cancel()
        freezeTask = nil
        pendingResult = nil
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        displayObserver = nil
        stopInput()
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
        views.removeAll()
        frozenDisplays.removeAll()
        SelectionOverlayController.current = nil
        if needsFrozenPixels {
            // The final image already exists. Never capture the live desktop here.
            completion(deliveredResult)
            return
        }
        // Give WindowServer a beat to drop the overlay before any capture happens.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [completion] in
            completion(result)
        }
    }
}

/// Offscreen drawing for the overlay's small pieces of chrome (hint pill,
/// recording bar). They are drawn once per change into a bitmap at the
/// display's scale and handed to a layer, so tracking stays pure compositing.
enum OverlayArt {
    static let panelFill = NSColor(srgbRed: 0.075, green: 0.075, blue: 0.082, alpha: 0.92)
    static let panelStroke = NSColor.white.withAlphaComponent(0.13)
    static let recordRed = NSColor(srgbRed: 0.918, green: 0.286, blue: 0.302, alpha: 1)

    static func render(size: CGSize, scale: CGFloat, _ draw: () -> Void) -> CGImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(ceil(size.width * scale)),
                                         pixelsHigh: Int(ceil(size.height * scale)),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    static func panel(_ rect: CGRect, radius: CGFloat) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        panelFill.setFill()
        path.fill()
        panelStroke.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    /// Draws an SF Symbol centred in `rect`, filled with `color`.
    static func symbol(_ name: String, in rect: CGRect, pointSize: CGFloat, color: NSColor) {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium)) else { return }
        let size = base.size
        let tinted = NSImage(size: size, flipped: false) { bounds in
            base.draw(in: bounds)
            color.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: CGRect(x: (rect.midX - size.width / 2).rounded(), y: (rect.midY - size.height / 2).rounded(),
                               width: size.width, height: size.height))
    }

    /// The hint pill: an instruction, then key caps with what they do.
    static func hint(title: String, keys: [(String, String)], scale: CGFloat) -> (CGImage?, CGSize) {
        let titleText = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95)
        ])
        let capFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let pieces = keys.map { key, label in
            (NSAttributedString(string: key, attributes: [.font: capFont, .foregroundColor: NSColor.white.withAlphaComponent(0.9)]),
             NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .regular),
                                                            .foregroundColor: NSColor.white.withAlphaComponent(0.58)]))
        }
        let height: CGFloat = 36
        let capHeight: CGFloat = 20
        func capWidth(_ text: NSAttributedString) -> CGFloat { max(ceil(text.size().width) + 12, capHeight) }
        var width = 16 + ceil(titleText.size().width)
        if !pieces.isEmpty { width += 29 }
        for (index, piece) in pieces.enumerated() {
            width += capWidth(piece.0) + 6 + ceil(piece.1.size().width)
            if index < pieces.count - 1 { width += 14 }
        }
        width += 16
        let size = CGSize(width: width, height: height)
        let image = render(size: size, scale: scale) {
            panel(CGRect(origin: .zero, size: size), radius: height / 2)
            var x: CGFloat = 16
            titleText.draw(at: CGPoint(x: x, y: (height - titleText.size().height) / 2))
            x += ceil(titleText.size().width)
            guard !pieces.isEmpty else { return }
            x += 14
            NSColor.white.withAlphaComponent(0.14).setFill()
            CGRect(x: x, y: (height - 16) / 2, width: 1, height: 16).fill()
            x += 15
            for piece in pieces {
                let cap = CGRect(x: x, y: (height - capHeight) / 2, width: capWidth(piece.0), height: capHeight)
                NSColor.white.withAlphaComponent(0.13).setFill()
                NSBezierPath(roundedRect: cap, xRadius: 5, yRadius: 5).fill()
                let keySize = piece.0.size()
                piece.0.draw(at: CGPoint(x: cap.midX - keySize.width / 2, y: cap.midY - keySize.height / 2))
                x = cap.maxX + 6
                piece.1.draw(at: CGPoint(x: x, y: (height - piece.1.size().height) / 2))
                x += ceil(piece.1.size().width) + 14
            }
        }
        return (image, size)
    }

    static func recordBar(size selection: CGSize, options: RecordOptions, hovered: RecordBarItem?,
                          scale: CGFloat) -> CGImage? {
        let layout = RecordBarLayout.shared
        return render(size: layout.size, scale: scale) {
            panel(CGRect(origin: .zero, size: layout.size), radius: 12)
            let dim = NSColor.white.withAlphaComponent(0.4)
            let sizeText = NSMutableAttributedString(string: "\(Int(selection.width))", attributes: [
                .font: RecordBarLayout.sizeFont, .foregroundColor: NSColor.white.withAlphaComponent(0.92)
            ])
            sizeText.append(NSAttributedString(string: " × ", attributes: [.font: RecordBarLayout.sizeFont, .foregroundColor: dim]))
            sizeText.append(NSAttributedString(string: "\(Int(selection.height))", attributes: [
                .font: RecordBarLayout.sizeFont, .foregroundColor: NSColor.white.withAlphaComponent(0.92)
            ]))
            sizeText.draw(at: CGPoint(x: layout.sizeTextX, y: (layout.size.height - sizeText.size().height) / 2))

            NSColor.white.withAlphaComponent(0.12).setFill()
            for x in layout.dividers {
                CGRect(x: x, y: (layout.size.height - 20) / 2, width: 1, height: 20).fill()
            }

            for (item, rect) in layout.items {
                let hover = item == hovered
                switch item {
                case .systemAudio, .microphone, .cursor:
                    let on: Bool
                    let icon: String
                    switch item {
                    case .systemAudio:
                        on = options.systemAudio
                        icon = on ? "speaker.wave.2.fill" : "speaker.slash.fill"
                    case .microphone:
                        on = options.microphone
                        icon = on ? "mic.fill" : "mic.slash.fill"
                    default:
                        on = options.showCursor
                        icon = on ? "cursorarrow" : "cursorarrow.slash"
                    }
                    if on || hover {
                        NSColor.white.withAlphaComponent(on ? (hover ? 0.18 : 0.12) : 0.07).setFill()
                        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
                    }
                    symbol(icon, in: rect, pointSize: 12.5,
                           color: on ? NSColor.white.withAlphaComponent(0.95) : dim)
                case .record:
                    (hover ? recordRed.blended(withFraction: 0.12, of: .white) ?? recordRed : recordRed).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
                    NSColor.white.setFill()
                    NSBezierPath(ovalIn: CGRect(x: rect.minX + 14, y: rect.midY - 4, width: 8, height: 8)).fill()
                    let title = NSAttributedString(string: "Record", attributes: [
                        .font: RecordBarLayout.recordFont, .foregroundColor: NSColor.white
                    ])
                    title.draw(at: CGPoint(x: rect.minX + 30, y: rect.midY - title.size().height / 2))
                case .cancel:
                    if hover {
                        NSColor.white.withAlphaComponent(0.08).setFill()
                        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
                    }
                    symbol("xmark", in: rect, pointSize: 11,
                           color: NSColor.white.withAlphaComponent(hover ? 0.9 : 0.55))
                }
            }
        }
    }
}

/// One per screen. Forwards events to the controller and renders the shared
/// selection state for its own patch of the desktop: dim with a punched out
/// cutout, one clean white marquee line, a size label that follows the pointer,
/// resize handles and the recording bar while adjusting, and the hint pill.
final class SelectionView: NSView {
    // The hint copy depends on the controller's purpose, so it is laid out the
    // moment the controller attaches rather than at init.
    weak var controller: SelectionOverlayController? { didSet { refreshHint() } }
    let assignedScreen: NSScreen

    /// Always the first sublayer. Empty over the live desktop until the frozen
    /// frame arrives, and stays empty in the live modes (recording, timer, window).
    private let snapshotLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    /// One white hairline with a soft shadow: it reads on white pages and busy
    /// photos alike, without a coloured stroke, a grid, or screen wide guides.
    private let borderLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()
    private let badgeLayer = CALayer()
    private let badgeText = CATextLayer()
    private let hintLayer = CALayer()
    private let barLayer = CALayer()
    private var hintKey = ""
    private var barKey = ""

    // Pixel magnifier, the same idea as CleanShot's: a zoomed patch of the
    // frozen frame under the pointer with the target pixel boxed and the
    // point coordinates underneath (the selection size while dragging). It
    // only reads from the frozen frame, so it appears once that frame lands
    // and never in the live modes.
    private let loupeLayer = CALayer()
    private let loupeImage = CALayer()
    private let loupeTarget = CAShapeLayer()
    private let loupeLabel = CALayer()
    private let loupeText = CATextLayer()
    private var snapshot: CGImage?
    private static let loupeSize: CGFloat = 120
    /// Odd, so the pixel under the pointer sits dead centre.
    private static let loupePixels: CGFloat = 15

    private static let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    /// Settings > General > "Show pixel magnifier", off by default: the plain
    /// marquee reads cleaner. Read straight from defaults so the overlay
    /// compiles on its own in the capture regression test.
    private let showsMagnifier = UserDefaults.standard.object(forKey: "showMagnifier") as? Bool ?? false

    init(frame: NSRect, screen: NSScreen) {
        self.assignedScreen = screen
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        buildLayers()
    }

    /// Puts the frozen frame under the chrome. It replaces the live desktop in
    /// the same spot, so nothing visibly changes unless the screen was moving.
    func setSnapshot(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        snapshot = image
        snapshotLayer.contents = image
        snapshotLayer.contentsScale = CGFloat(image.width) / max(bounds.width, 1)
        loupeImage.contents = image
        CATransaction.commit()
    }

    func fadeInDim() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.12
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        dimLayer.add(fade, forKey: "fadeIn")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    /// The overlay is never the active app, so a pushed cursor does not stick;
    /// the crosshair is applied whenever the pointer is over this window, and
    /// the controller swaps in move and resize cursors while adjusting.
    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    // MARK: Events

    private func globalPoint(from event: NSEvent) -> CGPoint {
        guard let window else { return .zero }
        return window.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
    }

    override func mouseMoved(with event: NSEvent) { controller?.pointerMoved(to: globalPoint(from: event)) }
    override func mouseExited(with event: NSEvent) { controller?.pointerExited() }
    override func mouseDown(with event: NSEvent) { controller?.dragBegan(at: globalPoint(from: event)) }
    override func mouseDragged(with event: NSEvent) { controller?.dragChanged(to: globalPoint(from: event)) }
    override func mouseUp(with event: NSEvent) { controller?.dragEnded(in: window) }
    override func rightMouseDown(with event: NSEvent) { controller?.finish(.cancelled) }

    // MARK: Layer setup

    private func buildLayers() {
        guard let root = layer else { return }
        let scale = assignedScreen.backingScaleFactor

        snapshotLayer.frame = bounds
        snapshotLayer.contentsGravity = .resize
        root.addSublayer(snapshotLayer)

        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.36).cgColor
        dimLayer.fillRule = .evenOdd
        root.addSublayer(dimLayer)

        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
        borderLayer.lineWidth = 1
        borderLayer.shadowColor = NSColor.black.cgColor
        borderLayer.shadowOpacity = 0.3
        borderLayer.shadowRadius = 3
        borderLayer.shadowOffset = .zero
        borderLayer.isHidden = true
        root.addSublayer(borderLayer)

        handleLayer.fillColor = NSColor.white.cgColor
        handleLayer.strokeColor = NSColor.black.withAlphaComponent(0.22).cgColor
        handleLayer.lineWidth = 1
        handleLayer.shadowColor = NSColor.black.cgColor
        handleLayer.shadowOpacity = 0.35
        handleLayer.shadowRadius = 2.5
        handleLayer.shadowOffset = CGSize(width: 0, height: -0.5)
        handleLayer.isHidden = true
        root.addSublayer(handleLayer)

        badgeLayer.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        badgeLayer.cornerRadius = 5
        badgeLayer.isHidden = true
        badgeText.contentsScale = scale
        badgeText.alignmentMode = .center
        badgeLayer.addSublayer(badgeText)
        root.addSublayer(badgeLayer)

        hintLayer.contentsScale = scale
        hintLayer.contentsGravity = .resize
        Self.styleShadow(hintLayer)
        root.addSublayer(hintLayer)

        barLayer.contentsScale = scale
        barLayer.contentsGravity = .resize
        Self.styleShadow(barLayer)
        barLayer.isHidden = true
        root.addSublayer(barLayer)

        let size = SelectionView.loupeSize
        loupeLayer.frame = CGRect(x: 0, y: 0, width: size, height: size)
        loupeLayer.cornerRadius = size / 2
        loupeLayer.backgroundColor = NSColor.black.cgColor
        loupeLayer.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        loupeLayer.borderWidth = 2
        loupeLayer.shadowColor = NSColor.black.cgColor
        loupeLayer.shadowOpacity = 0.45
        loupeLayer.shadowRadius = 10
        loupeLayer.shadowOffset = CGSize(width: 0, height: -3)
        loupeLayer.shadowPath = CGPath(ellipseIn: loupeLayer.bounds, transform: nil)
        loupeLayer.isHidden = true

        // The image lives in its own clipped layer so the outer one keeps its shadow.
        let clip = CALayer()
        clip.frame = loupeLayer.bounds
        clip.cornerRadius = size / 2
        clip.masksToBounds = true
        loupeImage.frame = clip.bounds
        loupeImage.contentsGravity = .resize
        loupeImage.magnificationFilter = .nearest
        clip.addSublayer(loupeImage)

        let cell = size / SelectionView.loupePixels
        let box = CGRect(x: (size - cell) / 2, y: (size - cell) / 2, width: cell, height: cell)
        loupeTarget.path = CGPath(rect: box.insetBy(dx: -0.5, dy: -0.5), transform: nil)
        loupeTarget.fillColor = nil
        loupeTarget.strokeColor = NSColor.white.cgColor
        loupeTarget.lineWidth = 1
        loupeTarget.shadowColor = NSColor.black.cgColor
        loupeTarget.shadowOpacity = 0.8
        loupeTarget.shadowRadius = 1
        loupeTarget.shadowOffset = .zero
        clip.addSublayer(loupeTarget)
        loupeLayer.addSublayer(clip)
        root.addSublayer(loupeLayer)

        Self.stylePill(loupeLabel, radius: 6)
        loupeLabel.isHidden = true
        loupeText.contentsScale = scale
        loupeText.alignmentMode = .center
        loupeLabel.addSublayer(loupeText)
        root.addSublayer(loupeLabel)
    }

    private static func stylePill(_ layer: CALayer, radius: CGFloat) {
        layer.backgroundColor = OverlayArt.panelFill.cgColor
        layer.borderColor = OverlayArt.panelStroke.cgColor
        layer.borderWidth = 0.5
        layer.cornerRadius = radius
    }

    private static func styleShadow(_ layer: CALayer) {
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.4
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: -4)
    }

    /// Zooms the frozen frame around the pointer and parks the magnifier
    /// below right of it, flipping to whichever side still fits on screen.
    /// Returns whether it is showing, so the size can ride under it.
    @discardableResult
    private func updateLoupe(at pointer: CGPoint?, label: String?) -> Bool {
        guard showsMagnifier, let snapshot, let pointer, bounds.contains(pointer) else {
            loupeLayer.isHidden = true
            loupeLabel.isHidden = true
            return false
        }
        let size = SelectionView.loupeSize
        let span = SelectionView.loupePixels
        let imageW = CGFloat(snapshot.width), imageH = CGFloat(snapshot.height)
        let scaleX = imageW / bounds.width, scaleY = imageH / bounds.height
        // The pixel under the pointer, counted from the bottom like the layer's
        // contentsRect, which on macOS runs bottom up the same as AppKit points.
        let px = floor(pointer.x * scaleX)
        let py = floor(pointer.y * scaleY)
        let half = (span - 1) / 2
        loupeImage.contentsRect = CGRect(x: (px - half) / imageW, y: (py - half) / imageH,
                                         width: span / imageW, height: span / imageH)

        let gap: CGFloat = 22
        var origin = CGPoint(x: pointer.x + gap, y: pointer.y - gap - size)
        if origin.x + size > bounds.maxX - 8 { origin.x = pointer.x - gap - size }
        if origin.y < 34 { origin.y = pointer.y + gap }
        loupeLayer.frame.origin = origin
        loupeLayer.isHidden = false

        // Coordinates in points from the display's top left, as rulers and design tools count them.
        let text = NSAttributedString(string: label ?? "\(Int(pointer.x)), \(Int(bounds.height - pointer.y))", attributes: [
            .font: SelectionView.badgeFont,
            .foregroundColor: NSColor.white
        ])
        loupeText.string = text
        let textSize = text.size()
        let labelSize = CGSize(width: ceil(textSize.width) + 16, height: ceil(textSize.height) + 9)
        loupeLabel.frame = CGRect(x: (origin.x + (size - labelSize.width) / 2).rounded(), y: origin.y - labelSize.height - 8,
                                  width: labelSize.width, height: labelSize.height)
        loupeText.frame = CGRect(x: 8, y: 4.5, width: ceil(textSize.width), height: ceil(textSize.height))
        loupeLabel.isHidden = false
        return true
    }

    /// Redraws the hint pill only when its copy changes (mode switches).
    private func refreshHint() {
        let purpose = controller?.purpose ?? .still
        let adjusting = controller?.adjustRect != nil
        let key = "\(purpose)-\(adjusting)"
        guard key != hintKey else { return }
        hintKey = key
        let title: String
        var keys: [(String, String)] = [("esc", "Cancel")]
        switch purpose {
        case .still:
            title = "Drag to select an area"
            keys = [("⏎", "Full screen"), ("⇧", "Square"), ("space", "Move")] + keys
        case .ocr:
            title = "Drag across the text to copy"
        case .record where adjusting:
            title = "Drag the edges to adjust"
            keys = [("⏎", "Record")] + keys
        case .record:
            title = "Drag to choose the recording area"
            keys = [("⏎", "Full screen"), ("⇧", "Square"), ("space", "Move")] + keys
        case .timed:
            title = "Drag to select the area for the timer"
        case .window:
            title = "Click a window, or drag an area"
        }
        let (image, size) = OverlayArt.hint(title: title, keys: keys, scale: assignedScreen.backingScaleFactor)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hintLayer.contents = image
        hintLayer.frame = CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: bounds.height - 72,
                                 width: size.width, height: size.height)
        hintLayer.shadowPath = CGPath(roundedRect: hintLayer.bounds, cornerWidth: size.height / 2,
                                      cornerHeight: size.height / 2, transform: nil)
        CATransaction.commit()
    }

    // MARK: Rendering shared state

    /// Repaints every piece of chrome from the controller's state. All layer
    /// mutation happens with implicit animations off; a 0.25 second implicit
    /// fade on a path change would drag the marquee behind the cursor.
    func refresh() {
        guard let controller else { return }
        refreshHint()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let screenFrame = assignedScreen.frame
        func local(_ global: CGRect) -> CGRect {
            CGRect(x: global.origin.x - screenFrame.origin.x,
                   y: global.origin.y - screenFrame.origin.y,
                   width: global.width, height: global.height)
        }
        let adjusting = controller.adjustRect != nil
        // While dragging, the size label rides the selection's live corner,
        // which stays on the drag's display even if the pointer strays off it.
        let tracked = controller.isDragging ? (controller.dragCurrentGlobal ?? controller.mouseGlobal)
                                            : controller.mouseGlobal
        let pointer = NSMouseInRect(tracked, screenFrame, false)
            ? CGPoint(x: tracked.x - screenFrame.origin.x, y: tracked.y - screenFrame.origin.y)
            : nil
        let pointerHere = NSMouseInRect(controller.mouseGlobal, screenFrame, false)

        var globalCutout: CGRect?
        if let adjustRect = controller.adjustRect {
            globalCutout = adjustRect
        } else if controller.isDragging {
            globalCutout = controller.selectionRect()
        } else if let hover = controller.hoverWindow, hover.frame.intersects(screenFrame) {
            globalCutout = hover.frame
        }
        let cutout = globalCutout.map(local)

        // Dim everything except the cutout.
        let dimPath = CGMutablePath()
        dimPath.addRect(bounds)
        if let cutout { dimPath.addRect(cutout) }
        dimLayer.path = dimPath

        if let cutout {
            borderLayer.path = CGPath(rect: cutout.insetBy(dx: -0.5, dy: -0.5), transform: nil)
            borderLayer.isHidden = false
        } else {
            borderLayer.isHidden = true
        }

        // Handles only on a settled recording area, where they do something.
        if adjusting, let cutout {
            handleLayer.path = SelectionView.handlesPath(for: cutout)
            handleLayer.isHidden = false
        } else {
            handleLayer.isHidden = true
        }
        let shaping = controller.isDragging || controller.isManipulating

        // The size rides with the pointer while dragging (under the magnifier
        // when it is up), sits under a hovered window, and lives in the bar
        // once a recording area is settled.
        let sizeLabel = globalCutout.map { "\(Int($0.width)) × \(Int($0.height))" }
        let loupeShowing = updateLoupe(at: controller.isDragging ? pointer : (adjusting ? nil : pointer),
                                       label: controller.isDragging ? sizeLabel : nil)
        if controller.isDragging, let sizeLabel, let p = pointer, !loupeShowing {
            updateBadge(text: sizeLabel, near: p)
            badgeLayer.isHidden = false
        } else if !controller.isDragging, !adjusting, let cutout, let sizeLabel, let hover = controller.hoverWindow {
            let label = hover.ownerName.isEmpty ? sizeLabel : "\(hover.ownerName)  ·  \(sizeLabel)"
            updateBadge(text: label, under: cutout)
            badgeLayer.isHidden = false
        } else {
            badgeLayer.isHidden = true
        }

        // One hint, on the display the pointer is on; it follows between displays.
        hintLayer.isHidden = shaping || !pointerHere

        updateBar(controller: controller)
    }

    private func updateBar(controller: SelectionOverlayController) {
        guard let adjustRect = controller.adjustRect, let bar = controller.recordBarFrame(),
              bar.screen == assignedScreen else {
            barLayer.isHidden = true
            barKey = ""
            return
        }
        let options = controller.recordOptions
        let hovered = controller.hoveredBarItem
        let key = "\(Int(adjustRect.width))x\(Int(adjustRect.height))|\(options.systemAudio)\(options.microphone)\(options.showCursor)|\(String(describing: hovered))"
        if key != barKey {
            barLayer.contents = OverlayArt.recordBar(size: adjustRect.size, options: options, hovered: hovered,
                                                     scale: assignedScreen.backingScaleFactor)
        }
        let screenFrame = assignedScreen.frame
        let frame = bar.frame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        barLayer.frame = frame
        barLayer.shadowPath = CGPath(roundedRect: barLayer.bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        if barLayer.isHidden {
            // The bar rises into place when the area settles.
            barLayer.isHidden = false
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = 6
            rise.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [fade, rise]
            group.duration = 0.18
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            barLayer.add(group, forKey: "appear")
        }
        barKey = key
    }

    private func layoutBadge(_ text: String) -> CGSize {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: SelectionView.badgeFont,
            .foregroundColor: NSColor.white
        ])
        badgeText.string = attributed
        let size = attributed.size()
        badgeText.frame = CGRect(x: 8, y: 4.5, width: ceil(size.width), height: ceil(size.height))
        return CGSize(width: ceil(size.width) + 16, height: ceil(size.height) + 9)
    }

    /// Below right of the pointer, flipping to stay on screen.
    private func updateBadge(text: String, near pointer: CGPoint) {
        let size = layoutBadge(text)
        let gap: CGFloat = 16
        var origin = CGPoint(x: pointer.x + gap, y: pointer.y - gap - size.height)
        if origin.x + size.width > bounds.maxX - 8 { origin.x = pointer.x - gap - size.width }
        if origin.y < 8 { origin.y = pointer.y + gap }
        badgeLayer.frame = CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
    }

    /// Under the bottom right corner of a hovered window, or inside it near the screen edge.
    private func updateBadge(text: String, under cutout: CGRect) {
        let size = layoutBadge(text)
        var origin = CGPoint(x: cutout.maxX - size.width, y: cutout.minY - size.height - 10)
        if origin.y < 8 { origin.y = cutout.minY + 10 }
        if origin.x < 8 { origin.x = cutout.minX + 10 }
        badgeLayer.frame = CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
    }

    /// Round handles on the corners, plus the edge midpoints once the side is
    /// long enough for them not to crowd the corners.
    private static func handlesPath(for rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let diameter: CGFloat = 9
        var points = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY),
                      CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)]
        if rect.width >= 60 {
            points += [CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.midX, y: rect.maxY)]
        }
        if rect.height >= 60 {
            points += [CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY)]
        }
        for point in points {
            path.addEllipse(in: CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2,
                                       width: diameter, height: diameter))
        }
        return path
    }

}
