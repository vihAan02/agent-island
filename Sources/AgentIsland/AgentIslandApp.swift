import AppKit
import IslandCore
import SwiftUI

@main
struct AgentIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Agent Island", systemImage: "circle.grid.2x1.left.filled") {
            IslandMenu(model: AppEnvironment.shared.model)
        }
    }
}

/// One place for the objects the menu and the delegate both need.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let settings = IslandSettings()
    lazy var model = IslandModel(
        settings: settings,
        demoMode: CommandLine.arguments.contains("--demo")
    )
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // One copy at a time: two would fight over the hook socket.
        let isTool = CommandLine.arguments.contains { $0.hasPrefix("--") && $0 != "--demo" }
        if !isTool, !SingleInstance.acquire() {
            NSLog("Agent Island is already running")
            NSApp.terminate(nil)
            return
        }

        // `--probe` prints what the watchers can see and exits. Used to check detection.
        if CommandLine.arguments.contains("--probe") {
            Task { await ProbeMode.run() }
            return
        }

        // `--install-hooks` / `--uninstall-hooks` for scripting and for the README.
        if CommandLine.arguments.contains("--install-hooks") {
            runHookCommand(install: true)
            return
        }
        if CommandLine.arguments.contains("--uninstall-hooks") {
            runHookCommand(install: false)
            return
        }

        // `--render <dir>` draws the island offscreen and exits. Used for visual checks.
        if let index = CommandLine.arguments.firstIndex(of: "--render") {
            let directory = CommandLine.arguments.count > index + 1
                ? CommandLine.arguments[index + 1]
                : FileManager.default.currentDirectoryPath
            RenderMode.run(outputDirectory: directory)
            NSApp.terminate(nil)
            return
        }

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
        model.onExpansionChanged = { [weak controller] expanded in
            controller?.setExpanded(expanded)
        }

        model.start()
        offerHookInstallIfNeeded()
    }

    /// Asks once, on the first launch, before touching the agents' settings files.
    private func offerHookInstallIfNeeded() {
        guard !CommandLine.arguments.contains("--demo") else { return }
        let settings = AppEnvironment.shared.settings
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "askedAboutHooks"), !settings.claudeHooksInstalled else { return }
        defaults.set(true, forKey: "askedAboutHooks")

        let alert = NSAlert()
        alert.messageText = "Let Agent Island read Claude Code status?"
        alert.informativeText = """
            It adds a few hook entries to ~/.claude/settings.json that report when a \
            session starts, asks you something, hits an error, or finishes. Your current \
            settings file is backed up first, and you can remove the hooks from the menu \
            bar at any time.

            Without them the island still works, but permission prompts look the same as \
            a long-running tool.
            """
        alert.addButton(withTitle: "Add Hooks")
        alert.addButton(withTitle: "Not Now")
        alert.alertStyle = .informational

        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try settings.installClaudeHooks()
        } catch {
            presentError("Could not add the hooks", error)
        }
    }

    private func runHookCommand(install: Bool) {
        let settings = AppEnvironment.shared.settings
        do {
            if install {
                try settings.installClaudeHooks()
                print("Claude hooks installed in \(IslandPaths.claudeSettings)")
                print("Hook binary: \(IslandSettings.hookBinaryPath)")
            } else {
                try settings.uninstallClaudeHooks()
                print("Claude hooks removed from \(IslandPaths.claudeSettings)")
            }
        } catch {
            print("Failed: \(error)")
        }
        NSApp.terminate(nil)
    }

    private func presentError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "\(error)"
        alert.runModal()
    }
}

/// The menu bar menu: what is running, what to watch, and hook management.
struct IslandMenu: View {
    @Bindable var model: IslandModel

    var body: some View {
        let _ = Diagnostics.count("menu-body")
        let settings = model.settings

        Text(summary)

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

        if settings.claudeHooksInstalled {
            Button("Remove Claude Hooks") { try? settings.uninstallClaudeHooks() }
        } else {
            Button("Add Claude Hooks\u{2026}") { try? settings.installClaudeHooks() }
        }
        if settings.codexHooksInstalled {
            Button("Remove Codex Hooks") { try? settings.uninstallCodexHooks() }
        } else {
            Button("Add Codex Hooks\u{2026}") { try? settings.installCodexHooks() }
        }

        Divider()

        Button("Quit Agent Island") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var summary: String {
        let count = model.bubbles.count
        if count == 0 { return "No agents running" }
        let working = model.bubbles.filter { $0.session.status == .working }.count
        let waiting = model.bubbles.filter { $0.session.status == .question }.count
        var parts = ["\(count) session\(count == 1 ? "" : "s")"]
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) waiting for you") }
        return parts.joined(separator: " \u{00b7} ")
    }
}
