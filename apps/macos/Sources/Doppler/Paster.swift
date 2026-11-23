import AppKit
import ApplicationServices

enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func paste(_ text: String, restoreClipboard: Bool) {
        let board = NSPasteboard.general
        let saved = restoreClipboard ? snapshot(board) : nil
        copy(text)
        let ourChange = board.changeCount

        // A private source, so modifiers still physically held (the shortcut's ⌃ or fn) aren't
        // merged into the ⌘V and turn it into ⌃⌘V.
        let source = CGEventSource(stateID: .privateState)
        let vKey: CGKeyCode = 9
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }

        // Give the target app time to read the clipboard, then put the user's content back,
        // unless something else has written to the clipboard in the meantime.
        if let saved {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard board.changeCount == ourChange else { return }
                board.clearContents()
                board.writeObjects(saved)
            }
        }
    }

    private static func snapshot(_ board: NSPasteboard) -> [NSPasteboardItem] {
        (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }
}
