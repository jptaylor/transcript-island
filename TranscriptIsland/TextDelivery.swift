import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

/// The app the text should go to: the one in front when dictation starts.
struct InsertionTarget {
    let app: NSRunningApplication
}

enum DeliveryOutcome: Equatable {
    /// ⌘V was sent to the app. Whether a text field took it isn't known (see `TextDelivery`).
    case pasted(appName: String)
    /// Copied to the clipboard only. `accessibilityOff`: there was an app to paste into, but
    /// without Accessibility access the app can't send it the keystroke.
    case copied(accessibilityOff: Bool)
    case nothingHeard
}

/// Gets the text into the app you were using: copies it to the clipboard, then sends ⌘V.
///
/// It deliberately doesn't look at the other app first (to check that a text field is
/// focused). Reading another app's interface goes through the Accessibility API, and macOS
/// shows an indicator in the Dynamic Island ("System & App Protection Override in use")
/// whenever an app does that, for about a minute afterwards. Sending a keystroke doesn't
/// trigger it. So if no text field is focused, ⌘V simply does nothing, and the text is still on
/// the clipboard.
@MainActor
enum TextDelivery {
    private static let log = Logger.app("Delivery")

    /// The app in front (other than this one).
    static func captureTarget() -> InsertionTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        return InsertionTarget(app: app)
    }

    /// Always copies `text` to the clipboard (as a backup). Then, if there's an app to paste
    /// into and Accessibility access is granted, brings it forward if needed and sends ⌘V.
    static func deliver(_ text: String, to target: InsertionTarget?) async -> DeliveryOutcome {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard let target, !target.app.isTerminated else {
            log.notice("copied only: no app to paste into")
            return .copied(accessibilityOff: false)
        }
        let name = target.app.bundleIdentifier ?? "pid \(target.app.processIdentifier)"
        // Sending keystrokes to other apps needs Accessibility access. Checking for it doesn't
        // count as using it.
        guard AXIsProcessTrusted() else {
            log.notice("copied only: Accessibility access is off (target \(name, privacy: .public))")
            return .copied(accessibilityOff: true)
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.app.processIdentifier {
            target.app.activate(from: .current, options: [])
            try? await Task.sleep(for: .milliseconds(200))
        }
        postCommandV()
        log.notice("pasted into \(name, privacy: .public)")
        return .pasted(appName: target.app.localizedName ?? "the app")
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
