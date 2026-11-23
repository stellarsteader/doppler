import AppKit
import AVFoundation
import SwiftUI

enum SettingsTab: Hashable { case general, server, permissions, about }

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var permissions = PermissionsModel()
    @StateObject private var server = ServerStatus()
    @State private var tab: SettingsTab = .general
    @State private var contentHeight: CGFloat = 801
    @State private var sizer = SettingsWindowSizer()

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $tab)
            ScrollView {
                page.background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { pageHeightChanged(proxy.size.height, newTab: true) }
                        .onChange(of: proxy.size.height) { _, height in pageHeightChanged(height, newTab: false) }
                })
            }
            .id(tab)
            .scrollBounceBehavior(.basedOnSize)
        }
        // Never taller than the tab's content; only a tab longer than the minimum can shrink and scroll.
        .frame(minWidth: Mono.minWindowWidth, idealWidth: Mono.windowWidth, maxWidth: Mono.windowWidth,
               minHeight: min(Mono.minContentHeight, contentHeight), idealHeight: contentHeight,
               maxHeight: contentHeight)
        .background(Mono.background)
        .background(SettingsWindowChrome(sizer: sizer))
        .environmentObject(permissions)
        .environmentObject(server)
        .onAppear {
            AppController.shared.setSettingsOpen(true)
            server.check()
        }
        .onDisappear { AppController.shared.setSettingsOpen(false) }
    }

    @ViewBuilder private var page: some View {
        switch tab {
        case .general: GeneralTab(tab: $tab)
        case .server: ServerTab()
        case .permissions: PermissionsTab()
        case .about: AboutTab()
        }
    }

    private func pageHeightChanged(_ height: CGFloat, newTab: Bool) {
        guard height > 0 else { return }
        contentHeight = Mono.tabBarHeight + height
        sizer.fit(to: contentHeight, newTab: newTab)
    }
}

private struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    private let tabs: [(tab: SettingsTab, title: String, icon: String)] = [
        (.general, "General", "gearshape"),
        (.server, "Server", "server.rack"),
        (.permissions, "Permissions", "lock.shield"),
        (.about, "About", "info.circle"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.tab) { item in
                let selected = item.tab == selection
                Button { selection = item.tab } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon)
                            .font(.system(size: 17))
                            .frame(height: 20)
                        Text(item.title).font(.system(size: 11, weight: selected ? .medium : .regular))
                    }
                    .foregroundStyle(selected ? Mono.text : Mono.secondary)
                    .frame(width: 78, height: 46)
                    .background(selected ? Mono.control : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Mono.tabBarHeight)
        .background(WindowDragArea())
        .background(Mono.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Mono.line).frame(height: 1) }
    }
}

struct GeneralTab: View {
    @Binding var tab: SettingsTab
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var permissions: PermissionsModel
    @State private var microphones: [AudioInputDevice] = []
    @State private var audioApps: [AudioApp] = []

    var body: some View {
        SettingsPage {
            if let problem = permissions.problem {
                SettingsCard {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Mono.error)
                        Text(problem)
                            .font(.system(size: 12))
                            .foregroundStyle(Mono.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Fix…") { tab = .permissions }
                            .buttonStyle(MonoButtonStyle())
                            .fixedSize()
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 12)
                    .padding(.vertical, 6)
                    .frame(minHeight: Mono.rowHeight)
                }
            }

            SettingsCard {
                SettingsRow("Shortcut") { ShortcutRecorder(hotkey: $settings.hotkey) }
                RowDivider()
                SettingsRow("Mode") {
                    MonoSegmented(options: RecordMode.allCases, title: \.title, selection: $settings.mode)
                }
            } footer: {
                if settings.hotkey.usesFn && !permissions.fnKeyIsFree {
                    HStack(spacing: 4) {
                        Text("fn also opens the emoji picker.")
                        Button {
                            openURL("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
                        } label: {
                            Text("Set 🌐 to Do Nothing…").underline().foregroundStyle(Mono.text)
                        }
                        .buttonStyle(.plain)
                    }
                } else if settings.hotkey.blocksTyping {
                    Text("This key won’t type in other apps while Doppler is running.")
                }
            }

            SettingsCard("Notch") {
                SettingsRow("Style") {
                    MonoPicker(title: "Style", value: settings.notchStyle.title, selection: $settings.notchStyle,
                               entries: NotchStyle.allCases.map { .option($0.title, $0) })
                }
                RowDivider()
                SettingsRow("Animation") {
                    Button("Preview") { AppController.shared.previewNotch() }
                        .buttonStyle(MonoButtonStyle())
                }
            }

            SettingsCard("Input") {
                SettingsRow("Language") {
                    MonoPicker(title: "Language", value: settings.language.title, selection: $settings.language,
                               entries: SpokenLanguage.allCases.map { .option($0.title, $0) })
                }
                RowDivider()
                SettingsRow(settings.captureAppAudio ? "App audio" : "Microphone") {
                    MonoPicker(title: settings.captureAppAudio ? "App audio" : "Microphone",
                               value: inputSourceName,
                               selection: $settings.inputSource,
                               entries: inputSourceEntries)
                }
                RowDivider()
                ToggleRow("Transcribe audio from apps", isOn: $settings.captureAppAudio)
                RowDivider()
                SettingsRow("Max transcription time") {
                    NumberStepper(value: $settings.recordingLimitMinutes,
                                  range: AppSettings.recordingLimitRange,
                                  unit: "min")
                }
            }

            SettingsCard("After transcribing") {
                ToggleRow("Paste transcription into active text box", isOn: $settings.autoPaste)
                RowDivider()
                ToggleRow("Restore clipboard after pasting transcription", inset: 18,
                          isOn: $settings.restoreClipboard)
                    .disabled(!settings.autoPaste)
                RowDivider()
                ToggleRow("Show live transcription under notch", isOn: $settings.showLiveText)
                RowDivider()
                ToggleRow("Play sounds", isOn: $settings.playSounds)
            }

            SettingsCard("App") {
                ToggleRow("Launch at login", isOn: $settings.launchAtLogin)
                RowDivider()
                ToggleRow("Show in Dock", isOn: $settings.showInDock)
            }
        }
        .onAppear(perform: refreshSources)
        .onChange(of: settings.captureAppAudio) { _, _ in refreshSources() }
        // Coming back to Settings after opening the app you want to capture.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshSources()
        }
    }

    private var inputSourceName: String {
        switch settings.inputSource {
        case .microphone(let uid) where uid.isEmpty:
            return "System default"
        case .microphone(let uid):
            return microphones.first { $0.uid == uid }?.name ?? "Disconnected device"
        case .app(let bundleID):
            return audioApps.first { $0.bundleID == bundleID }?.name
                ?? "\(AudioApps.name(of: bundleID)) (not running)"
        }
    }

    private var inputSourceEntries: [MonoMenuEntry<InputSource>] {
        var entries: [MonoMenuEntry<InputSource>] = [.option("System default", .systemDefault)]
        if !microphones.isEmpty { entries.append(.divider) }
        entries += microphones.map { .option($0.name, .microphone(uid: $0.uid)) }
        if case .microphone(let uid) = settings.inputSource, !uid.isEmpty,
           !microphones.contains(where: { $0.uid == uid }) {
            entries.append(.option("Disconnected device", settings.inputSource))
        }
        if settings.captureAppAudio {
            entries.append(.divider)
            entries += audioApps.map { .option($0.name, .app(bundleID: $0.bundleID)) }
            if case .app(let bundleID) = settings.inputSource,
               !audioApps.contains(where: { $0.bundleID == bundleID }) {
                entries.append(.option("\(AudioApps.name(of: bundleID)) (not running)", settings.inputSource))
            }
        }
        return entries
    }

    private func refreshSources() {
        microphones = AudioDevices.inputs()
        audioApps = settings.captureAppAudio ? AudioApps.available() : []
    }
}

struct ServerTab: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var server: ServerStatus
    @State private var revealToken = false

    var body: some View {
        SettingsPage {
            SettingsCard {
                HStack(spacing: 10) {
                    StatusDot(state: server.state)
                    Text(server.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Mono.text)
                        .fixedSize()
                    Spacer(minLength: 0)
                    if server.state != .failed {
                        Text(server.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(Mono.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button { server.check() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(IconButtonStyle())
                        .help("Check again")
                        .disabled(server.state == .checking)
                }
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .frame(height: Mono.rowHeight)
            } footer: {
                if server.state == .failed {
                    Text(server.detail).foregroundStyle(Mono.error)
                }
            }

            SettingsCard {
                SettingsRow("Server URL") {
                    TextField("Server URL", text: $settings.serverURL, prompt: Text("http://127.0.0.1:8000"))
                        .textContentType(.URL)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                }
                RowDivider()
                SettingsRow("Token") {
                    HStack(spacing: 4) {
                        Group {
                            if revealToken {
                                TextField("", text: $settings.token, prompt: Text("Not set"))
                            } else {
                                SecureField("", text: $settings.token, prompt: Text("Not set"))
                            }
                        }
                        .textFieldStyle(.plain)
                        .font(settings.token.isEmpty ? .system(size: 13) : .system(size: 13, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                        Button { revealToken.toggle() } label: {
                            Image(systemName: revealToken ? "eye.slash" : "eye")
                        }
                        .buttonStyle(IconButtonStyle())
                        .help(revealToken ? "Hide token" : "Show token")
                        Button {
                            if let text = NSPasteboard.general.string(forType: .string) {
                                settings.token = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        } label: { Image(systemName: "doc.on.clipboard") }
                            .buttonStyle(IconButtonStyle())
                            .help("Paste token")
                    }
                }
                RowDivider()
                SettingsRow("Model") {
                    TextField("Model", text: $settings.model, prompt: Text("Optional"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .labelsHidden()
                }
            }
        }
        .onChange(of: settings.serverURL) { _, _ in server.check(after: 0.7) }
        .onChange(of: settings.token) { _, _ in server.check(after: 0.7) }
    }
}

final class ServerStatus: ObservableObject {
    enum State: Equatable { case checking, ok, failed }

    @Published private(set) var state: State = .checking
    @Published private(set) var title = "Checking…"
    @Published private(set) var detail = ""
    private var task: Task<Void, Never>?

    func check(after delay: Double = 0) {
        task?.cancel()
        state = .checking
        title = "Checking…"
        detail = ""
        task = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
            }
            let result = await TranscriptionAPI.check(settings: .shared)
            if Task.isCancelled { return }
            state = result.ok ? .ok : .failed
            title = result.ok ? "Connected" : "Not connected"
            // On success the message is "URL · model"; the URL is already in the row below.
            detail = result.ok ? result.message.components(separatedBy: " · ").last ?? result.message : result.message
        }
    }
}

private struct StatusDot: View {
    let state: ServerStatus.State

    var body: some View {
        ZStack {
            if state == .checking {
                ProgressView().controlSize(.small)
            } else {
                Circle()
                    .fill(state == .ok ? Mono.text : Mono.error)
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 16, height: 16)
    }
}

struct PermissionsTab: View {
    @EnvironmentObject private var permissions: PermissionsModel

    var body: some View {
        SettingsPage {
            SettingsCard {
                PermissionRow(title: "Microphone", granted: permissions.microphone) {
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                        Task { _ = await MicrophoneSource.requestPermission() }
                    } else {
                        openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                    }
                }
                RowDivider()
                PermissionRow(title: "Accessibility", granted: permissions.accessibility) {
                    Paster.requestAccess()
                    openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                }
            } footer: {
                if !permissions.accessibility {
                    Text("Already switched on but still shown as missing? Remove Doppler from the list with “–”, then allow it again. This happens after rebuilding the app.")
                }
            }
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let fix: () -> Void

    var body: some View {
        SettingsRow(title) {
            if granted {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    Text("Allowed").font(.system(size: 12))
                }
                .foregroundStyle(Mono.secondary)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Mono.error)
                    Button("Allow…", action: fix).buttonStyle(MonoButtonStyle(prominent: true))
                }
            }
        }
    }
}

final class PermissionsModel: ObservableObject {
    @Published private(set) var microphone = MicrophoneSource.hasPermission
    @Published private(set) var accessibility = Paster.isTrusted
    /// Not a permission, but polled the same way so the fn tip disappears once it's fixed.
    @Published private(set) var fnKeyIsFree = Hotkey.fnKeyIsFree
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    deinit { timer?.invalidate() }

    private func refresh() {
        if microphone != MicrophoneSource.hasPermission { microphone = MicrophoneSource.hasPermission }
        if accessibility != Paster.isTrusted { accessibility = Paster.isTrusted }
        if fnKeyIsFree != Hotkey.fnKeyIsFree { fnKeyIsFree = Hotkey.fnKeyIsFree }
    }

    var allGranted: Bool { microphone && accessibility }

    var problem: String? {
        if !microphone { return "Microphone access is off, so nothing can be recorded." }
        if !accessibility { return "Accessibility is off, so text is copied instead of pasted." }
        return nil
    }
}

struct AboutTab: View {
    private var version: String {
        "Version " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
            Text("Doppler").font(.system(size: 20, weight: .semibold)).foregroundStyle(Mono.text)
            Text(version).font(.system(size: 12)).foregroundStyle(Mono.secondary)
            Text("Speech to text, on a server you own.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(Mono.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .background(Mono.background)
    }
}

private func openURL(_ string: String) {
    if let url = URL(string: string) { NSWorkspace.shared.open(url) }
}
