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
        setAccessibilityLabel("Agent Island")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Keeps the panel glued to the notch screen and decides when it should take clicks.
@MainActor
final class PanelController {
    private(set) var panel: NotchPanel
    private(set) var geometry: NotchGeometry
    private var mouseMonitor: Any?
    private var isExpanded = false
    private var screenObserver: NSObjectProtocol?

    /// Rects, in panel coordinates, that should receive clicks right now.
    var interactiveRects: [CGRect] = [] {
        didSet { updateMousePassthrough(for: NSEvent.mouseLocation) }
    }

    /// Called with the panel-space mouse position, or nil when the pointer is elsewhere.
    var onHover: ((CGPoint?) -> Void)?

    init<Content: View>(@ViewBuilder content: (NotchGeometry) -> Content) {
        let geometry = NotchGeometry.current()
        self.geometry = geometry
        panel = NotchPanel(contentRect: geometry.panelFrame)

        let hosting = NSHostingView(rootView: AnyView(content(geometry)))
        hosting.frame = CGRect(origin: .zero, size: geometry.panelFrame.size)
        hosting.autoresizingMask = [.width, .height]
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

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.updateMousePassthrough(for: NSEvent.mouseLocation) }
            _ = event
        }
    }

    /// The controller lives as long as the app does; this exists for tests and teardown.
    func stopMonitoring() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        mouseMonitor = nil
        screenObserver = nil
    }

    /// Grows the window when the hover card opens, and shrinks it again afterwards.
    func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
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
