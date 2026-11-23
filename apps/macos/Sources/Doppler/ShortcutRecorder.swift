import AppKit
import SwiftUI

struct ShortcutRecorder: View {
    @Binding var hotkey: Hotkey
    @State private var recording = false
    @State private var hovering = false
    @State private var monitor: Any?
    @State private var held: [UInt16] = []
    @State private var peak: [UInt16] = []

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            HStack(spacing: 4) {
                if recording && held.isEmpty {
                    Text("Press keys…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Mono.text)
                        .padding(.horizontal, 4)
                } else {
                    let caps = recording ? Hotkey.caps(for: held) : hotkey.parts
                    ForEach(Array(caps.enumerated()), id: \.offset) { KeyCap($0.element) }
                }
            }
            .frame(minHeight: 22)
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(hovering && !recording ? 0.06 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Mono.text, lineWidth: recording ? 1.5 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(recording ? "Press one or two keys · Esc to cancel" : "Click to change")
        .animation(.easeOut(duration: 0.12), value: recording)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        held = []
        peak = []
        AppController.shared.suspendHotkey(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        AppController.shared.suspendHotkey(false)
    }

    private func handle(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if event.type == .keyDown {
            if event.keyCode == 53, mods.isEmpty { stop(); return }  // Esc
            var key = Hotkey(kind: .combo, keyCode: event.keyCode, modifiers: mods.rawValue, display: "",
                             keyLabel: Self.keyName(event))
            key.display = key.parts.joined(separator: " ")
            hotkey = key
            stop()
            return
        }

        guard Hotkey.modifierKeys[event.keyCode] != nil else { return }
        if Hotkey.isModifierDown(event.keyCode, in: event.modifierFlags) {
            if !held.contains(event.keyCode), held.count < 2 { held.append(event.keyCode) }
            if held.count > peak.count { peak = held }
        } else {
            held.removeAll { $0 == event.keyCode }
            if held.isEmpty, let first = peak.first {
                var key = Hotkey(kind: .modifierOnly, keyCode: first, modifiers: 0, display: "",
                                 secondKeyCode: peak.count > 1 ? peak[1] : nil)
                key.display = key.parts.joined(separator: " ")
                hotkey = key
                stop()
            }
        }
    }

    private static let namedKeys: [UInt16: String] = [
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 117: "⌦", 53: "Esc",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    private static func keyName(_ event: NSEvent) -> String {
        namedKeys[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

struct KeyCap: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .frame(minWidth: 24, minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.25), radius: 0, x: 0, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15)))
    }
}
