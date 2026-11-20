import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

/// Where the text should go. Captured when recording starts, before anything can move focus.
struct InsertionTarget {
    let app: NSRunningApplication
    let hasEditableFocus: Bool
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

    static func captureTarget() -> InsertionTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        let target = InsertionTarget(app: app, hasEditableFocus: focusedElementIsEditableText(in: app))
        log.notice("target \(app.bundleIdentifier ?? "?", privacy: .public): editable \(target.hasEditableFocus), accessibility \(AXIsProcessTrusted())")
        return target
    }

    /// Always copies `text` to the clipboard (as a backup), then pastes it into the
    /// captured text field if there was one and Accessibility access is granted.
    static func deliver(_ text: String, to target: InsertionTarget?) async -> DeliveryOutcome {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard let target, target.hasEditableFocus, AXIsProcessTrusted(), !target.app.isTerminated else {
            let accessibilityOff = target != nil && !AXIsProcessTrusted()
            log.notice("copied only (target \(target != nil), editable \(target?.hasEditableFocus ?? false), accessibility off \(accessibilityOff))")
            return .copied(accessibilityOff: accessibilityOff)
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.app.processIdentifier {
            target.app.activate(from: .current, options: [])
            try? await Task.sleep(for: .milliseconds(200))
        }
        postCommandV()
        log.notice("pasted into \(target.app.bundleIdentifier ?? "?", privacy: .public)")
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
