import AppKit
import Combine

final class AppController: ObservableObject {
    static let shared = AppController()

    enum State { case idle, recording, processing }

    @Published private(set) var state: State = .idle
    @Published private(set) var recent: [String] = []
    @Published private(set) var lastError: String?
    /// lastError came from talking to the server, so it's stale once the server answers again.
    private var lastErrorFromServer = false

    let settings = AppSettings.shared
    let server = ServerStatus.shared
    let overlay = OverlayModel()
    private lazy var panel = NotchPanel(model: overlay)
    private let hotkeys = HotkeyManager()
    private var recorder: AudioRecorder?
    private var session: StreamingSession?
    private var connected: Task<Bool, Never>?
    private var startedAt = Date()
    private var autoStop: DispatchWorkItem?
    private var recordingID = ""
    private var cancellables = Set<AnyCancellable>()

    // Full recording, kept for the upload fallback. Written from the audio thread.
    private var pcm = Data()
    private let pcmLock = NSLock()

    func setup() {
        hotkeys.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkeys.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkeys.onCancel = { [weak self] in self?.hotkeyCancelled() }
        settings.$hotkey.removeDuplicates().sink { [weak self] hotkey in
            self?.hotkeys.register(hotkey)
            if hotkey.kind == .modifierOnly { self?.requestAccessibilityOnce() }
        }.store(in: &cancellables)
        settings.$showLiveText.assign(to: \.showLiveText, on: overlay).store(in: &cancellables)
        settings.$notchStyle.assign(to: \.style, on: overlay).store(in: &cancellables)
        // The settings window and menu are drawn dark; set it app-wide before any window exists,
        // or text fields made under a light system appearance keep dark text.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        updateDockVisibility()

        server.startPolling()
        server.$state.removeDuplicates().sink { [weak self] state in
            guard let self, state == .ok, lastErrorFromServer else { return }
            lastError = nil
            lastErrorFromServer = false
        }.store(in: &cancellables)

        Task { _ = await MicrophoneSource.requestPermission() }
        if settings.autoPaste { requestAccessibilityOnce() }
    }

    private var askedForAccessibility = false

    private func requestAccessibilityOnce() {
        guard !askedForAccessibility, !Paster.isTrusted else { return }
        askedForAccessibility = true
        Paster.requestAccess()
    }

    private var settingsOpen = false

    func setSettingsOpen(_ open: Bool) {
        settingsOpen = open
        updateDockVisibility()
    }

    func updateDockVisibility() {
        NSApp.setActivationPolicy(settings.showInDock || settingsOpen ? .regular : .accessory)
        if settingsOpen { NSApp.activate(ignoringOtherApps: true) }
    }

    func suspendHotkey(_ suspended: Bool) {
        if suspended { hotkeys.unregister() } else { hotkeys.register(settings.hotkey) }
    }

    private func hotkeyPressed() {
        if settings.mode == .hold, state == .idle { start() }
    }

    /// Toggle acts on release, so a shortcut that turns into another one (⌃ fn →) starts nothing.
    private func hotkeyReleased() {
        switch (settings.mode, state) {
        case (.hold, _), (.toggle, .recording): stop()
        case (.toggle, .idle): start()
        default: break
        }
    }

    private func hotkeyCancelled() {
        if settings.mode == .hold { discard() }
    }

    private func start() {
        let source = settings.inputSource.makeSource()
        if let problem = source.checkAccess() { fail(problem); return }
        guard let url = settings.streamURL else { fail("Set your server URL in Settings."); return }
        // Only once a check has passed, which also covers the first moments after launch.
        // The menu already shows the server's state, so this isn't kept as lastError.
        switch server.state {
        case .ok: break
        case .checking: fail("Checking server…", remember: false); return
        case .failed: server.refresh(); fail("Server not connected", remember: false); return
        }

        lastError = nil
        pcmLock.withLock { pcm = Data() }
        startedAt = Date()
        recordingID = UUID().uuidString

        let session = StreamingSession(url: url, token: settings.token,
                                       language: settings.language == .auto ? nil : settings.language.rawValue,
                                       recordingID: recordingID)
        session.onPartial = { [weak self] full in self?.overlay.liveText = full }
        self.session = session
        connected = Task {
            do { try await session.connect(); return true } catch {
                NSLog("stream connect failed, will upload instead: \(error)")
                return false
            }
        }

        let recorder = AudioRecorder(source: source)
        recorder.onChunk = { [weak self] chunk in
            guard let self else { return }
            self.pcmLock.withLock { self.pcm.append(chunk) }
            session.send(chunk)
        }
        recorder.onMeter = { [weak self, weak recorder] level in
            guard let self, let recorder, self.recorder === recorder else { return }
            self.overlay.push(level: level)
        }
        recorder.onError = { [weak self, weak recorder] error in
            guard let self, let recorder, self.state == .recording, self.recorder === recorder else { return }
            self.autoStop?.cancel()
            self.recorder = nil
            session.cancel()
            self.fail(error.localizedDescription)
        }
        recorder.start()
        self.recorder = recorder

        state = .recording
        overlay.liveText = ""
        overlay.resetLevels()
        panel.present(.listening)
        play(.start)

        let autoStop = DispatchWorkItem { [weak self] in self?.stop() }
        self.autoStop = autoStop
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(settings.recordingLimitMinutes * 60), execute: autoStop)
    }

    private func discard() {
        guard state == .recording else { return }
        autoStop?.cancel()
        recorder?.stop()
        recorder = nil
        session?.cancel()
        state = .idle
        panel.hide()
    }

    private func stop() {
        guard state == .recording else { return }
        // A tap shorter than this is almost always accidental.
        if settings.mode == .hold, Date().timeIntervalSince(startedAt) < 0.35 { discard(); return }
        autoStop?.cancel()
        let silenceMessage = recorder?.silenceMessage ?? ""
        recorder?.stop()
        recorder = nil

        let audio = pcmLock.withLock { pcm }
        guard audio.contains(where: { $0 != 0 }) else {
            session?.cancel()
            fail(silenceMessage)
            return
        }

        state = .processing
        overlay.phase = .processing
        play(.stop)
        let session = self.session, connected = self.connected, recordingID = self.recordingID
        Task { [settings] in
            let result = await Self.transcribe(session: session, connected: connected, audio: audio,
                                               recordingID: recordingID, settings: settings)
            await self.finish(result)
        }
    }

    private static func transcribe(session: StreamingSession?, connected: Task<Bool, Never>?, audio: Data,
                                   recordingID: String, settings: AppSettings) async -> Result<Transcript, Error> {
        var streamed = false
        if let session, let connected, await connected.value {
            streamed = true
            do { return .success(try await session.finish()) } catch {
                NSLog("stream failed, uploading instead: \(error)")
            }
        }
        session?.cancel()
        do {
            return .success(try await TranscriptionAPI.upload(pcm: audio, recordingID: streamed ? recordingID : nil,
                                                              settings: settings))
        } catch {
            return .failure(error)
        }
    }

    @MainActor private func finish(_ result: Result<Transcript, Error>) {
        session = nil
        state = .idle
        switch result {
        case .success(let transcript) where transcript.text.isEmpty:
            overlay.resultText = ""
            overlay.phase = .error("No speech detected")
            play(.error)
            panel.hide(after: 1.2)
        case .success(let transcript):
            deliver(transcript.text)
            play(.done)
            recent.insert(transcript.text, at: 0)
            recent = Array(recent.prefix(10))
            overlay.resultText = transcript.text
            overlay.phase = .done
            panel.hide(after: 1.8)
        case .failure(let error):
            server.refresh()  // so the menu shows a server that just went down without waiting for the poll
            fail(error.localizedDescription)
            lastErrorFromServer = true
        }
    }

    private func deliver(_ text: String) {
        if settings.autoPaste && Paster.isTrusted {
            Paster.paste(text, restoreClipboard: settings.restoreClipboard)
            overlay.resultLabel = "Pasted"
        } else {
            Paster.copy(text)
            overlay.resultLabel = "Copied"
        }
    }

    private func fail(_ message: String, remember: Bool = true) {
        state = .idle
        if remember {
            lastError = message
            lastErrorFromServer = false
        }
        panel.present(.error(message))
        play(.error)
        panel.hide(after: 3)
    }

    private enum SoundCue: String {
        case start = "doppler-start", stop = "doppler-stop", done = "doppler-done", error = "doppler-error"
    }

    private func play(_ cue: SoundCue) {
        guard settings.playSounds, let sound = NSSound(named: cue.rawValue) else { return }
        sound.stop()  // the same cue can fire again before a short sound has finished
        sound.volume = 0.35
        sound.play()
    }

    func copyRecent(_ text: String) { Paster.copy(text) }

    private var notchPreview: Task<Void, Never>?

    @MainActor func previewNotch() {
        guard state == .idle else { return }
        notchPreview?.cancel()
        overlay.liveText = ""
        overlay.resetLevels()
        panel.present(.listening)
        notchPreview = Task { @MainActor [weak self] in
            guard let self else { return }
            let sample = "This is a preview of the live text."
            let started = Date()
            while !Task.isCancelled, self.state == .idle {
                let t = Date().timeIntervalSince(started)
                if t > 3.2 { break }
                let speech: Double = abs(sin(t * 2.7)) * (0.35 + 0.55 * abs(sin(t * 9.1)))
                self.overlay.push(level: Float(speech))
                if t > 1.4 { self.overlay.liveText = sample }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled, self.state == .idle else { return }
            self.overlay.phase = .processing
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled, self.state == .idle else { return }
            self.overlay.resultText = sample
            self.overlay.resultLabel = "Pasted"
            self.overlay.phase = .done
            self.panel.hide(after: 1.8)
        }
    }
}
