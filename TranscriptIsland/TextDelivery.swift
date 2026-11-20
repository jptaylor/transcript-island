import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

/// The app the text should go to: the one in front when dictation starts.
///
/// Only the app is noted at that point. Looking at its text field needs the Accessibility
/// API, and macOS shows an indicator in the Dynamic Island whenever an app uses that access.
/// That would sit on top of the dictation bar while you talk, so the check waits until the
/// text is delivered.
struct InsertionTarget {
    let app: NSRunningApplication
}

enum DeliveryOutcome: Equatable {
    case inserted(appName: String)
    /// Copied to the clipboard only. `accessibilityOff`: there may have been a text field,
    /// but without Accessibility access the app can't find it or paste into it.
    case copied(accessibilityOff: Bool)
    case nothingHeard
}

@MainActor
enum TextDelivery {
    private static let log = Logger.app("Delivery")

    /// The app in front (other than this one). Makes no Accessibility calls.
    static func captureTarget() -> InsertionTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        return InsertionTarget(app: app)
    }

    /// Always copies `text` to the clipboard (as a backup). Then, if Accessibility access is
    /// granted and the target app has a text field focused, pastes it there.
    static func deliver(_ text: String, to target: InsertionTarget?) async -> DeliveryOutcome {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard let target, !target.app.isTerminated else {
            log.notice("copied only: no app to type into")
            return .copied(accessibilityOff: false)
        }
        let name = target.app.bundleIdentifier ?? "pid \(target.app.processIdentifier)"
        guard AXIsProcessTrusted() else {
            log.notice("copied only: Accessibility access is off (target \(name, privacy: .public))")
            return .copied(accessibilityOff: true)
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.app.processIdentifier {
            target.app.activate(from: .current, options: [])
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard focusedElementIsEditableText(in: target.app) else {
            log.notice("copied only: no text field focused in \(name, privacy: .public)")
            return .copied(accessibilityOff: false)
        }
        postCommandV()
        log.notice("pasted into \(name, privacy: .public)")
        return .inserted(appName: target.app.localizedName ?? "the app")
    }

    // MARK: - Accessibility

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    private static func focusedElementIsEditableText(in app: NSRunningApplication) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focused = element(appElement, kAXFocusedUIElementAttribute)
        if focused == nil {
            // Chromium/Electron apps only build their accessibility tree when asked.
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            focused = element(appElement, kAXFocusedUIElementAttribute)
        }
        guard let focused else { return false }

        if let role = string(focused, kAXRoleAttribute), textRoles.contains(role) {
            return true
        }
        // Rich editors (web contenteditable, custom text views) expose a settable selection.
        var settable: DarwinBoolean = false
        let status = AXUIElementIsAttributeSettable(focused, kAXSelectedTextRangeAttribute as CFString, &settable)
        return status == .success && settable.boolValue
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: - Paste

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
