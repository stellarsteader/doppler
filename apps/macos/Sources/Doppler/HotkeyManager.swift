import AppKit
import Carbon.HIToolbox

/// Combos use Carbon's RegisterEventHotKey: system-wide, no permission prompt, and it reports
/// key-up, which NSEvent hotkeys can't. Modifier-only shortcuts (Right ⌥, Fn, ⌃ + ⌥) can't be
/// registered that way, so they're watched with an NSEvent flagsChanged monitor (needs
/// Accessibility, which pasting needs anyway).
final class HotkeyManager {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    var onCancel: () -> Void = {}
    var isSuspended = false

    private var hotkeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyTap: CFMachPort?
    private var keyTapSource: CFRunLoopSource?
    private var isDown = false
    private var isHeld = false
    private var isSpoiled = false
    private var current: Hotkey?

    func register(_ hotkey: Hotkey) {
        unregister()
        current = hotkey
        switch hotkey.kind {
        case .combo: registerCarbon(hotkey)
        case .modifierOnly: registerModifierMonitor(hotkey)
        }
    }

    func unregister() {
        if let hotkeyRef { UnregisterEventHotKey(hotkeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: false); CFMachPortInvalidate(keyTap) }
        if let keyTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), keyTapSource, .commonModes) }
        hotkeyRef = nil; handlerRef = nil; globalMonitor = nil; localMonitor = nil
        keyTap = nil; keyTapSource = nil
        isDown = false; isHeld = false; isSpoiled = false
    }

    private func pressed() {
        guard !isSuspended, !isDown else { return }
        isDown = true
        onPress()
    }

    private func released() {
        guard isDown else { return }
        isDown = false
        if !isSuspended { onRelease() }
    }

    private func registerCarbon(_ hotkey: Hotkey) {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            let kind = GetEventKind(event)
            DispatchQueue.main.async {
                if kind == UInt32(kEventHotKeyPressed) { manager.pressed() } else { manager.released() }
            }
            return noErr
        }, types.count, &types, selfPtr, &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x5353_5454), id: 1)  // 'SSTT'
        let status = RegisterEventHotKey(UInt32(hotkey.keyCode), Self.carbonModifiers(hotkey.modifierFlags),
                                         id, GetApplicationEventTarget(), 0, &hotkeyRef)
        if status != noErr { NSLog("RegisterEventHotKey failed (\(status)): shortcut may be taken by another app") }
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }

    /// If another key joins in (⌃ fn → tiles a window), it was some other shortcut: the press is
    /// cancelled and nothing fires until the keys are let go.
    private func registerModifierMonitor(_ hotkey: Hotkey) {
        let keys = hotkey.modifierKeyCodes
        let own = NSEvent.ModifierFlags(keys.compactMap { Hotkey.modifierKeys[$0]?.flag })
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            let flags = event.modifierFlags
            isHeld = keys.allSatisfy { Hotkey.isModifierDown($0, in: flags) }
            let others = flags.intersection([.command, .option, .shift, .control, .function]).subtracting(own)
            if !isHeld {
                isSpoiled = false
                released()
            } else if !others.isEmpty {
                spoil()
            } else if !isSpoiled {
                pressed()
            }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { handler($0); return $0 }
        watchKeyDowns()
    }

    private func spoil() {
        isSpoiled = true
        guard isDown else { return }
        isDown = false
        if !isSuspended { onCancel() }
    }

    /// A listen-only tap at the hardware level, since keys that trigger system shortcuts (window
    /// tiling) never reach an NSEvent monitor.
    private func watchKeyDowns() {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        keyTap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = manager.keyTap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else if manager.isHeld {
                    manager.spoil()
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr)
        guard let keyTap else { NSLog("key tap unavailable: needs Accessibility"); return }
        keyTapSource = CFMachPortCreateRunLoopSource(nil, keyTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), keyTapSource, .commonModes)
    }
}
