import AppKit
import ApplicationServices
import IslandCore

/// Puts a message typed on a card into its chat in the Claude app: opens that chat,
/// pastes into its message box, and presses Return, just as if it had been typed there.
///
/// Finding the box and pressing keys takes Accessibility permission. Without it, or
/// when the box cannot be found, the chat still opens and the message is left on the
/// clipboard. A key is only ever pressed while Claude is in front with a text box
/// focused in the lower part of its window, so nothing lands anywhere else.
@MainActor
enum ChatPaster {
    enum Outcome: Equatable {
        /// Pasted and sent.
        case sent
        /// Pasted and left in the box, for the reason given.
        case pasted(String)
        /// Not pasted; the message is on the clipboard, for the reason given.
        case copied(String)
    }

    static let claudeBundleID = "com.anthropic.claudefordesktop"

    /// Whether macOS lets this app read other apps' windows and press keys in them.
    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own prompt, which leads to Privacy & Security > Accessibility.
    static func requestPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func deliver(_ text: String, to session: AgentSession, send: Bool) async -> Outcome {
        guard let link = SessionOpener.claudeLink(for: session) else {
            return copy(text, because: "Couldn't find this chat in the Claude app")
        }
        guard isAllowed else {
            requestPermission()
            NSWorkspace.shared.open(link)
            return copy(text, because: "Allow Agent Island under Accessibility to paste for you")
        }

        NSWorkspace.shared.open(link)
        guard let claude = await claudeInFront() else {
            return copy(text, because: "Claude didn't come to the front")
        }
        let app = AXUIElementCreateApplication(claude.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)
        // Electron builds its accessibility tree only when asked.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        guard let box = await messageBox(in: app) else {
            return copy(text, because: "Couldn't find the message box")
        }
        // Never mix into something the user had started typing there.
        let before = (string(box, kAXValueAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let restore = putOnClipboard(text)
        press(keyCode: 0x09, flags: .maskCommand, pid: claude.processIdentifier) // ⌘V
        try? await Task.sleep(for: .milliseconds(180))
        defer { restore() }

        guard send else { return .pasted("Pasted into the chat; press Return there to send") }
        guard before.isEmpty else { return .pasted("Claude's box already had text, so it's pasted but not sent") }
        // Only send what is actually in the box now.
        if let after = string(box, kAXValueAttribute) {
            let start = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
            let flatAfter = after.replacingOccurrences(of: "\n", with: " ")
            let flatStart = start.replacingOccurrences(of: "\n", with: " ")
            guard flatAfter.contains(flatStart) else {
                return .pasted("Pasted, but couldn't confirm it, so it wasn't sent")
            }
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == claude.processIdentifier else {
            return .pasted("Pasted; Claude lost focus before it could be sent")
        }
        press(keyCode: 0x24, pid: claude.processIdentifier) // Return
        return .sent
    }

    // MARK: - Finding the box

    /// Waits for the Claude app to come forward after its link is opened.
    private static func claudeInFront() async -> NSRunningApplication? {
        for _ in 0..<60 {
            if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == claudeBundleID {
                return front
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// The chat's message box: the focused text area if it is one, otherwise the
    /// lowest text area in the window, focused first. The chat may still be loading,
    /// so this keeps looking for a few seconds.
    private static func messageBox(in app: AXUIElement) async -> AXUIElement? {
        for attempt in 0..<20 {
            if let focused = element(app, kAXFocusedUIElementAttribute), isMessageBox(focused, in: app) {
                return focused
            }
            // Give the chat a moment to take focus by itself before moving it.
            if attempt >= 3, let window = element(app, kAXFocusedWindowAttribute),
               let candidate = lowestTextArea(in: window) {
                AXUIElementSetAttributeValue(candidate, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                try? await Task.sleep(for: .milliseconds(120))
                if let focused = element(app, kAXFocusedUIElementAttribute), isMessageBox(focused, in: app) {
                    return focused
                }
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return nil
    }

    /// A multi-line text box in the lower half of Claude's window. The sidebar search
    /// is a text field, not a text area, and sits at the top, so it never qualifies.
    private static func isMessageBox(_ element: AXUIElement, in app: AXUIElement) -> Bool {
        guard string(element, kAXRoleAttribute) == kAXTextAreaRole as String else { return false }
        guard let window = self.element(app, kAXFocusedWindowAttribute),
              let windowFrame = frame(of: window),
              let boxFrame = frame(of: element)
        else { return false }
        return boxFrame.midY > windowFrame.midY
    }

    private static func lowestTextArea(in window: AXUIElement) -> AXUIElement? {
        var queue: [AXUIElement] = [window]
        var best: (element: AXUIElement, y: CGFloat)?
        var visited = 0
        while !queue.isEmpty, visited < 4000 {
            let current = queue.removeFirst()
            visited += 1
            if string(current, kAXRoleAttribute) == kAXTextAreaRole as String, let frame = frame(of: current),
               frame.width > 100, frame.midY > (best?.y ?? -.infinity) {
                best = (current, frame.midY)
            }
            queue.append(contentsOf: children(of: current))
        }
        return best?.element
    }

    // MARK: - Keys and the clipboard

    private static func press(keyCode: CGKeyCode, flags: CGEventFlags = [], pid: pid_t) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else { continue }
            event.flags = flags
            event.postToPid(pid)
        }
    }

    /// Puts the text on the clipboard and returns a way to put back what was there,
    /// unless something else has changed the clipboard in the meantime.
    private static func putOnClipboard(_ text: String) -> () -> Void {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ours = pasteboard.changeCount
        return {
            Task { @MainActor in
                // The app reads the clipboard as it handles ⌘V; give it time first.
                try? await Task.sleep(for: .milliseconds(600))
                guard pasteboard.changeCount == ours else { return }
                pasteboard.clearContents()
                if !saved.isEmpty { pasteboard.writeObjects(saved) }
            }
        }
    }

    /// The fallback: the message stays on the clipboard for a ⌘V by hand.
    private static func copy(_ text: String, because reason: String) -> Outcome {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return .copied("\(reason). It's on your clipboard: press \u{2318}V in the chat.")
    }

    // MARK: - Accessibility values

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(parent, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        guard let list = value(element, kAXChildrenAttribute) as? [CFTypeRef] else { return [] }
        return list.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? unsafeDowncast(item, to: AXUIElement.self) : nil
        }
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard
            let positionValue = value(element, kAXPositionAttribute), CFGetTypeID(positionValue) == AXValueGetTypeID(),
            let sizeValue = value(element, kAXSizeAttribute), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &position)
        AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size)
        return CGRect(origin: position, size: size)
    }
}
