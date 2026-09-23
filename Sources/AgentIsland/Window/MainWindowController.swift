import AppKit
import Observation
import SwiftUI

/// The pages of the main window.
enum MainSection: String, CaseIterable, Identifiable {
    case agents
    case island
    case hooks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agents: "Agents"
        case .island: "Island"
        case .hooks: "Hooks"
        }
    }

    var systemImage: String {
        switch self {
        case .agents: "circle.grid.2x1.left.filled"
        case .island: "slider.horizontal.3"
        case .hooks: "point.3.connected.trianglepath.dotted"
        }
    }
}

/// Which page the window shows. Kept outside the view so the menu and the app
/// delegate can open the window straight onto a page.
@MainActor
@Observable
final class MainWindowState {
    var section: MainSection? = .agents
}

/// Agent Island's one real window: hidden until asked for, and gone again once closed.
///
/// The app normally lives in the menu bar with no Dock icon. While this window is
/// open it shows in the Dock and the app switcher like any other app. Closing it
/// puts the app back in the menu bar and tears the window's views down, so nothing
/// in it keeps drawing while it is hidden.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()

    let state = MainWindowState()
    private var window: NSWindow?
    private let frameName = "AgentIslandMainWindow"

    /// Opens the window, or brings it forward, optionally on a given page.
    func show(_ section: MainSection? = nil) {
        if let section { state.section = section }
        let window = self.window ?? makeWindow()
        self.window = window

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
        AppEnvironment.shared.hooks.refresh()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        window = nil
        // Let AppKit finish closing before the Dock icon goes away.
        DispatchQueue.main.async {
            guard self.window == nil else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // The settings files may have been edited by hand while the window was behind.
        AppEnvironment.shared.hooks.refresh()
    }

    private func makeWindow() -> NSWindow {
        let environment = AppEnvironment.shared
        let hosting = NSHostingController(
            rootView: MainWindowView(state: state, model: environment.model, hooks: environment.hooks)
        )
        // The window keeps the size the user gave it rather than shrinking to fit.
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = [.toolbars, .title]

        let window = MainWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "Agent Island"
        window.toolbarStyle = .unified
        window.contentMinSize = NSSize(width: 640, height: 420)
        window.setContentSize(NSSize(width: 800, height: 540))
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        if !window.setFrameUsingName(frameName) { window.center() }
        window.setFrameAutosaveName(frameName)
        return window
    }
}

/// Closes on ⌘W, which an app with no File menu would otherwise ignore.
private final class MainWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
