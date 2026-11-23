import AppKit
import Combine
import ServiceManagement

struct Hotkey: Codable, Equatable {
    enum Kind: String, Codable { case combo, modifierOnly }

    var kind: Kind
    var keyCode: UInt16
    var modifiers: UInt
    var display: String
    var secondKeyCode: UInt16? = nil
    var keyLabel: String? = nil

    static let `default` = Hotkey(kind: .combo, keyCode: 49, modifiers: NSEvent.ModifierFlags.option.rawValue,
                                  display: "⌥ Space", keyLabel: "Space")

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var parts: [String] {
        switch kind {
        case .combo:
            let flags = modifierFlags
            var parts: [String] = []
            if flags.contains(.control) { parts.append("⌃") }
            if flags.contains(.option) { parts.append("⌥") }
            if flags.contains(.shift) { parts.append("⇧") }
            if flags.contains(.command) { parts.append("⌘") }
            parts.append(keyLabel ?? display.components(separatedBy: " ").last ?? "?")
            return parts
        case .modifierOnly:
            return Self.caps(for: modifierKeyCodes)
        }
    }

    static func caps(for keyCodes: [UInt16]) -> [String] {
        [63, 59, 62, 58, 61, 56, 60, 55, 54].filter(keyCodes.contains).compactMap { modifierKeys[$0]?.cap }
    }

    var blocksTyping: Bool {
        guard kind == .combo, modifierFlags.isDisjoint(with: [.command, .option, .control]) else { return false }
        let label = keyLabel ?? ""
        return label.count == 1 || ["Space", "Return", "Tab", "Delete"].contains(label)
    }

    var usesFn: Bool { kind == .modifierOnly && modifierKeyCodes.contains(63) }

    /// System Settings → Keyboard → "Press 🌐 key to": 0 = Do Nothing. Anything else (or unset)
    /// means pressing Fn also opens the emoji picker, switches input source, or starts dictation.
    static var fnKeyIsFree: Bool {
        CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int == 0
    }

    var modifierKeyCodes: [UInt16] { [keyCode] + (secondKeyCode.map { [$0] } ?? []) }

    /// Device-dependent flag bits, so Right ⌥ and Left ⌥ can be told apart.
    private static let sideMasks: [UInt16: UInt] = [
        55: 0x08, 54: 0x10,  // ⌘ left/right
        58: 0x20, 61: 0x40,  // ⌥
        56: 0x02, 60: 0x04,  // ⇧
        59: 0x01, 62: 0x2000,  // ⌃
    ]

    static func isModifierDown(_ keyCode: UInt16, in flags: NSEvent.ModifierFlags) -> Bool {
        if let mask = sideMasks[keyCode] { return flags.rawValue & mask != 0 }
        return keyCode == 63 && flags.contains(.function)
    }

    static let modifierKeys: [UInt16: (name: String, cap: String, flag: NSEvent.ModifierFlags)] = [
        54: ("Right ⌘", "right ⌘", .command), 55: ("Left ⌘", "⌘", .command),
        58: ("Left ⌥", "⌥", .option), 61: ("Right ⌥", "right ⌥", .option),
        56: ("Left ⇧", "⇧", .shift), 60: ("Right ⇧", "right ⇧", .shift),
        59: ("Left ⌃", "⌃", .control), 62: ("Right ⌃", "right ⌃", .control),
        63: ("Fn", "fn", .function),
    ]
}

enum RecordMode: String, CaseIterable, Identifiable {
    case hold, toggle
    var id: String { rawValue }
    var title: String { self == .hold ? "Hold to talk" : "Tap to toggle" }
}

enum SpokenLanguage: String, CaseIterable, Identifiable {
    case auto, ko, en, no
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Auto-detect"
        case .ko: "Korean"
        case .en: "English"
        case .no: "Norwegian"
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    /// 25 min of audio is 48 MB, so the upload fallback still fits the server's 50 MB limit.
    static let recordingLimitRange = 1...25
    private let defaults = UserDefaults.standard

    @Published var serverURL: String { didSet { defaults.set(serverURL, forKey: "serverURL") } }
    @Published var token: String { didSet { Keychain.set(token, for: "token") } }
    /// Sent with uploads, for servers that require a model name. Doppler Server ignores it.
    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }
    @Published var hotkey: Hotkey {
        didSet { defaults.set(try? JSONEncoder().encode(hotkey), forKey: "hotkey") }
    }
    @Published var mode: RecordMode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    @Published var language: SpokenLanguage { didSet { defaults.set(language.rawValue, forKey: "language") } }
    @Published var recordingLimitMinutes: Int {
        didSet { defaults.set(recordingLimitMinutes, forKey: "recordingLimitMinutes") }
    }
    @Published var autoPaste: Bool { didSet { defaults.set(autoPaste, forKey: "autoPaste") } }
    @Published var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: "restoreClipboard") } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    @Published var showLiveText: Bool { didSet { defaults.set(showLiveText, forKey: "showLiveText") } }
    @Published var notchStyle: NotchStyle { didSet { defaults.set(notchStyle.rawValue, forKey: "notchStyle") } }
    @Published var inputSource: InputSource {
        didSet { defaults.set(try? JSONEncoder().encode(inputSource), forKey: "inputSource") }
    }
    /// Off by default: apps only appear as sources, and macOS only asks for permission, once on.
    @Published var captureAppAudio: Bool {
        didSet {
            defaults.set(captureAppAudio, forKey: "captureAppAudio")
            if !captureAppAudio, case .app = inputSource { inputSource = .systemDefault }
        }
    }
    @Published var showInDock: Bool {
        didSet {
            defaults.set(showInDock, forKey: "showInDock")
            AppController.shared.updateDockVisibility()
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("launch at login: \(error)")
            }
        }
    }

    private init() {
        defaults.register(defaults: [
            "serverURL": "http://127.0.0.1:8000",
            "mode": RecordMode.hold.rawValue,
            "language": SpokenLanguage.auto.rawValue,
            "recordingLimitMinutes": Self.recordingLimitRange.upperBound,
            "autoPaste": true,
            "restoreClipboard": true,
            "playSounds": true,
            "showLiveText": true,
        ])
        serverURL = defaults.string(forKey: "serverURL") ?? ""
        token = Keychain.get("token") ?? ""
        model = defaults.string(forKey: "model") ?? ""
        hotkey = (defaults.data(forKey: "hotkey")).flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) } ?? .default
        mode = RecordMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .hold
        language = SpokenLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .auto
        recordingLimitMinutes = defaults.integer(forKey: "recordingLimitMinutes")
            .clamped(to: Self.recordingLimitRange)
        autoPaste = defaults.bool(forKey: "autoPaste")
        restoreClipboard = defaults.bool(forKey: "restoreClipboard")
        playSounds = defaults.bool(forKey: "playSounds")
        showLiveText = defaults.bool(forKey: "showLiveText")
        notchStyle = NotchStyle(rawValue: defaults.string(forKey: "notchStyle") ?? "") ?? .rings
        // Earlier versions saved just a microphone UID.
        inputSource = defaults.data(forKey: "inputSource").flatMap { try? JSONDecoder().decode(InputSource.self, from: $0) }
            ?? .microphone(uid: defaults.string(forKey: "microphoneUID") ?? "")
        captureAppAudio = defaults.bool(forKey: "captureAppAudio")
        showInDock = defaults.bool(forKey: "showInDock")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var baseURL: URL? {
        URL(string: serverURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    var streamURL: URL? {
        guard let base = baseURL, var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        parts.path += "/v1/stream"
        return parts.url
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
