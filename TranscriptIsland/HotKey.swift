import Carbon.HIToolbox
import Foundation
import os

/// A system-wide key via Carbon's `RegisterEventHotKey`. Works while any app is
/// focused, swallows the key press, and needs no permissions.
@MainActor
final class HotKey {
    var onPress: (@MainActor () -> Void)?
    var isRegistered: Bool { hotKeyRef != nil }

    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x5452_4953  // 'TRIS'
    private static let log = Logger.app("HotKey")

    /// `id` must be unique per key within the app.
    init(id: UInt32) {
        self.id = id
        installHandler()
    }

    /// Returns false if another app already holds this key combination.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()
        let status = RegisterEventHotKey(
            keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: id),
            GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &hotKeyRef
        )
        Self.log.debug("register key \(keyCode) mods \(modifiers) as #\(self.id): status \(status)")
        if status != noErr { hotKeyRef = nil }
        return status == noErr
    }

    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        register(keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers)
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var pressed = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed
                )
                let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
                guard status == noErr, pressed.signature == HotKey.signature, pressed.id == hotKey.id else {
                    return OSStatus(eventNotHandledErr)  // another HotKey's press
                }
                MainActor.assumeIsolated {  // Carbon delivers hot key events on the main thread
                    HotKey.log.debug("pressed #\(pressed.id)")
                    hotKey.onPress?()
                }
                return noErr
            },
            1, &eventType, context, &handlerRef
        )
    }
}
