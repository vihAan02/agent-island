import AppKit
import SwiftUI

/// The transparent overlay that sits over the menu bar, level with the notch.
final class NotchPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // Above the menu bar, so the circles can sit in the menu bar strip.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        // Clicks land on the circles only; PanelController flips this per pointer move.
        ignoresMouseEvents = true
        // Buttons work without taking focus. Only the card's message field makes the
        // panel key, so typing there never activates the app or pulls a window forward.
        becomesKeyOnlyIfNeeded = true
        setAccessibilityLabel("Agent Island")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Keeps the panel glued to the notch screen and decides when it should take clicks.
@MainActor
final class PanelController {
    private(set) var panel: NotchPanel
    private(set) var geometry: NotchGeometry
    private var mouseMonitor: Any?
    private var clickMonitor: Any?
    private var isExpanded = false
    private var screenObserver: NSObjectProtocol?

    /// Rects, in panel coordinates, that should receive clicks right now.
    var interactiveRects: [CGRect] = [] {
        didSet { updateMousePassthrough(for: NSEvent.mouseLocation) }
    }

    /// Called with the panel-space mouse position, or nil when the pointer is elsewhere.
    var onHover: ((CGPoint?) -> Void)?
    /// Called when the user clicks anywhere outside this app, which closes a card.
    var onOutsideClick: (() -> Void)?

    /// Takes presses on circles: a click opens, a drag moves the circle.
    weak var pointerTarget: IslandPointerTarget? {
        didSet { hostingView.pointerTarget = pointerTarget }
    }
    private let hostingView: IslandHostingView

    init<Content: View>(@ViewBuilder content: (NotchGeometry) -> Content) {
        let geometry = NotchGeometry.current()
        self.geometry = geometry
        panel = NotchPanel(contentRect: geometry.panelFrame)

        let hosting = IslandHostingView(rootView: AnyView(content(geometry)))
        hosting.frame = CGRect(origin: .zero, size: geometry.panelFrame.size)
        hosting.autoresizingMask = [.width, .height]
        hostingView = hosting
        panel.contentView = hosting
        applyFrame()
        panel.orderFrontRegardless()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateGeometry() }
        }

        // Global monitors only see events bound for other apps, so this is exactly
        // "a click somewhere that is not the island".
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.onOutsideClick?() }
        }

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.updateMousePassthrough(for: NSEvent.mouseLocation) }
            _ = event
        }
    }

    /// The controller lives as long as the app does; this exists for tests and teardown.
    func stopMonitoring() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        mouseMonitor = nil
        screenObserver = nil
    }

    /// Grows the window when the hover card opens, and shrinks it again afterwards.
    func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        // The card's field is gone; typing goes back to wherever it was.
        if !expanded { panel.makeFirstResponder(nil) }
        applyFrame()
    }

    private func applyFrame() {
        var frame = geometry.panelFrame
        if !isExpanded {
            let height = geometry.compactHeight
            frame = CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
        }
        panel.setFrame(frame, display: true)
    }

    func updateGeometry() {
        let updated = NotchGeometry.current()
        guard updated != geometry else { return }
        geometry = updated
        applyFrame()
    }

    /// The panel swallows clicks only while the pointer is over a live circle or card.
    private func updateMousePassthrough(for screenPoint: CGPoint) {
        let frame = panel.frame
        let panelPoint = CGPoint(x: screenPoint.x - frame.minX, y: frame.maxY - screenPoint.y)
        let inside = interactiveRects.contains { $0.contains(panelPoint) }
        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
        }
        // A little slack below the strip keeps the card open while the pointer
        // travels towards it.
        let hoverZone = CGRect(
            x: frame.minX - 4,
            y: frame.minY - 12,
            width: frame.width + 8,
            height: frame.height + 16
        )
        onHover?(hoverZone.contains(screenPoint) ? panelPoint : nil)
    }
}

/// What the panel hands presses on circles to.
@MainActor
protocol IslandPointerTarget: AnyObject {
    func circle(at point: CGPoint) -> String?
    func pressBegan(on id: String, at point: CGPoint)
    func pressMoved(to point: CGPoint)
    func pressEnded(at point: CGPoint)
}

/// Hosts the island and handles presses on circles itself, in AppKit.
///
/// SwiftUI gestures in a panel that is rarely key are unreliable for drags, and a
/// drag has to keep going when the pointer leaves the circle it started on. So a
/// press on a circle is claimed here, from mouse down to mouse up. The open card is
/// left to SwiftUI: it is buttons, a form, and a text field.
final class IslandHostingView: NSHostingView<AnyView> {
    weak var pointerTarget: IslandPointerTarget?
    private var isTracking = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Claim a press on a circle before SwiftUI's own views can.
        let panel = panelPoint(fromView: convert(point, from: superview))
        if pointerTarget?.circle(at: panel) != nil { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = panelPoint(event)
        guard let target = pointerTarget, let id = target.circle(at: point) else {
            return super.mouseDown(with: event)
        }
        isTracking = true
        target.pressBegan(on: id, at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTracking else { return super.mouseDragged(with: event) }
        pointerTarget?.pressMoved(to: panelPoint(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard isTracking else { return super.mouseUp(with: event) }
        isTracking = false
        pointerTarget?.pressEnded(at: panelPoint(event))
    }

    /// Panel coordinates: origin at the top left, y growing downward.
    private func panelPoint(_ event: NSEvent) -> CGPoint {
        panelPoint(fromView: convert(event.locationInWindow, from: nil))
    }

    private func panelPoint(fromView point: NSPoint) -> CGPoint {
        isFlipped ? point : CGPoint(x: point.x, y: bounds.height - point.y)
    }
}
