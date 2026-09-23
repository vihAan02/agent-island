import AppKit
import IslandCore
import SwiftUI

@main
struct AgentIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Agent Island", systemImage: "circle.grid.2x1.left.filled") {
            IslandMenu(model: AppEnvironment.shared.model, hooks: AppEnvironment.shared.hooks)
        }
    }
}

/// One place for the objects the menu, the window, and the delegate all need.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let settings = IslandSettings()
    let hooks = HookManager()
    lazy var model = IslandModel(
        settings: settings,
        demoMode: CommandLine.arguments.contains("--demo")
    )
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: PanelController?

    /// Posted by a second copy of the app, launched from somewhere else, asking this
    /// one to show its window before the second copy quits.
    nonisolated static let openWindowNotification = Notification.Name("com.agentisland.app.openWindow")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let arguments = CommandLine.arguments

        // One copy at a time: two would fight over the hook socket.
        let isTool = arguments.contains { $0.hasPrefix("--") && $0 != "--demo" }
        if !isTool, !SingleInstance.acquire() {
            NSLog("Agent Island is already running; asking it to show its window")
            DistributedNotificationCenter.default().postNotificationName(
                Self.openWindowNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            NSApp.terminate(nil)
            return
        }

        // `--probe [seconds]` prints what the watchers can see and exits. Used to check
        // detection, and with scripts/simulate.sh to check the hook path headlessly.
        if let index = arguments.firstIndex(of: "--probe") {
            let seconds = arguments.count > index + 1 ? Int(arguments[index + 1]) : nil
            Task { await ProbeMode.run(seconds: seconds ?? 6) }
            return
        }

        // `--install-hooks` / `--uninstall-hooks` for scripting and for the README.
        if arguments.contains("--install-hooks") {
            runHookCommand(install: true)
            return
        }
        if arguments.contains("--uninstall-hooks") {
            runHookCommand(install: false)
            return
        }

        // `--render <dir>` draws the island offscreen and exits. Used for visual checks.
        if let index = arguments.firstIndex(of: "--render") {
            let directory = arguments.count > index + 1
                ? arguments[index + 1]
                : FileManager.default.currentDirectoryPath
            RenderMode.run(outputDirectory: directory)
            NSApp.terminate(nil)
            return
        }

        // `--render-icon <dir>.iconset` writes the app icon for scripts/bundle.sh.
        if let index = arguments.firstIndex(of: "--render-icon"), arguments.count > index + 1 {
            AppIcon.writeIconset(to: arguments[index + 1])
            NSApp.terminate(nil)
            return
        }

        AppIcon.applyIfBundleHasNone()

        let model = AppEnvironment.shared.model
        let controller = PanelController { geometry in
            IslandRootView(geometry: geometry, model: model)
        }
        panelController = controller

        model.geometry = controller.geometry
        model.onLayoutChanged = { [weak controller] rects in
            controller?.interactiveRects = rects
        }
        controller.onHover = { [weak model] point in
            model?.setPointer(point)
        }
        controller.pointerTarget = model
        controller.onOutsideClick = { [weak model] in
            model?.collapse()
        }
        model.onExpansionChanged = { [weak controller] expanded in
            controller?.setExpanded(expanded)
        }

        AppEnvironment.shared.hooks.updateInstalledHooks()
        model.start()

        DistributedNotificationCenter.default().addObserver(
            forName: Self.openWindowNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { MainWindowController.shared.show() }
        }

        openWindowAtLaunchIfWanted()
    }

    /// Opening the app from Finder, Spotlight, or the Dock while it is already
    /// running shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainWindowController.shared.show()
        return false
    }

    /// Closing the window only hides it; the island keeps running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A launch you asked for opens the window. A launch at login, or one of the
    /// developer modes, keeps to the menu bar.
    ///
    /// The very first launch opens on Hooks, so the choice about touching
    /// `~/.claude/settings.json` is made there rather than in a modal alert.
    private func openWindowAtLaunchIfWanted() {
        guard !CommandLine.arguments.contains("--demo"), !launchedAsLoginItem else { return }

        let defaults = UserDefaults.standard
        let firstRun = !defaults.bool(forKey: "askedAboutHooks")
        defaults.set(true, forKey: "askedAboutHooks")

        let needsHooks = AppEnvironment.shared.hooks.state(for: .claude) != .installed
        MainWindowController.shared.show(firstRun && needsHooks ? .hooks : .agents)
    }

    /// True when macOS started the app as a login item.
    private var launchedAsLoginItem: Bool {
        guard
            let event = NSAppleEventManager.shared().currentAppleEvent,
            event.eventID == Self.fourCharCode("oapp")
        else { return false }
        return event.paramDescriptor(forKeyword: Self.fourCharCode("prdt"))?.enumCodeValue
            == Self.fourCharCode("lgit")
    }

    private static func fourCharCode(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func runHookCommand(install: Bool) {
        let hooks = AppEnvironment.shared.hooks
        let succeeded = install ? hooks.install(.claude) : hooks.uninstall(.claude)
        if succeeded {
            print(install
                ? "Claude hooks installed in \(IslandPaths.claudeSettings)\nHook binary: \(IslandSettings.hookBinaryPath)"
                : "Claude hooks removed from \(IslandPaths.claudeSettings)")
        } else {
            print("Failed: \(hooks.errors[.claude] ?? "unknown error")")
        }
        NSApp.terminate(nil)
    }
}

/// The menu bar menu: what is running, what to watch, hooks, and the way into the window.
struct IslandMenu: View {
    @Bindable var model: IslandModel
    let hooks: HookManager

    var body: some View {
        let _ = Diagnostics.count("menu-body")
        let settings = model.settings

        Text(model.summary)

        Button("Open Agent Island\u{2026}") { MainWindowController.shared.show(.agents) }
            .keyboardShortcut("o")

        Divider()

        Toggle("Watch Claude Code", isOn: Binding(
            get: { settings.watchClaude },
            set: { settings.watchClaude = $0 }
        ))
        Toggle("Watch Codex", isOn: Binding(
            get: { settings.watchCodex },
            set: { settings.watchCodex = $0 }
        ))

        Picker("Circles", selection: Binding(
            get: { settings.visibility },
            set: { settings.visibility = $0 }
        )) {
            ForEach(IslandSettings.Visibility.allCases) { option in
                Text(option.label).tag(option)
            }
        }

        Menu("Codex Pet") {
            ForEach(PetSpriteStore.shared.availablePetIDs(), id: \.self) { pet in
                Button {
                    settings.codexPetID = pet
                } label: {
                    Text(pet == settings.codexPetID ? "\u{2713} \(pet.capitalized)" : pet.capitalized)
                }
            }
        }

        Divider()

        hookButton(.claude, name: "Claude")
        hookButton(.codex, name: "Codex")

        Divider()

        Button("Quit Agent Island") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private func hookButton(_ kind: AgentKind, name: String) -> some View {
        switch hooks.state(for: kind) {
        case .notInstalled:
            Button("Add \(name) Hooks") { run { hooks.install(kind) } }
        case .installed:
            Button("Remove \(name) Hooks") { run { hooks.uninstall(kind) } }
        case .elsewhere:
            Button("Repair \(name) Hooks") { run { hooks.install(kind) } }
        }
    }

    /// A failed change opens the Hooks page, where the error is shown.
    private func run(_ change: () -> Bool) {
        if !change() { MainWindowController.shared.show(.hooks) }
    }
}
