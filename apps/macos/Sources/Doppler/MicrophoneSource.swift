import AVFoundation

/// Starting a mic can take a second (Bluetooth headsets switch profile first), which is why
/// AudioRecorder never calls start() on the main thread.
final class MicrophoneSource: AudioSource {
    let silenceMessage = "No sound came from the microphone. Try another one in Settings."

    private let uid: String
    private let queue = DispatchQueue(label: "dev.doppler.microphone", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var onBuffer: (AVAudioPCMBuffer) -> Void = { _ in }
    private var isRunning = false
    private var configObserver: NSObjectProtocol?

    /// A device that has been unplugged silently falls back to the default.
    init(uid: String) {
        self.uid = uid
    }

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static var hasPermission: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    func checkAccess() -> String? {
        if Self.hasPermission { return nil }
        Task { _ = await Self.requestPermission() }
        return "Microphone access is off. Allow it in System Settings → Privacy & Security → Microphone."
    }

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        try queue.sync {
            self.onBuffer = onBuffer
            isRunning = true
            do {
                try run()
            } catch {
                // Bluetooth headsets (AirPods) switch to their mic profile when the mic opens, and
                // the first attempt can catch them mid-switch. Give them a moment, then try again.
                Thread.sleep(forTimeInterval: 0.4)
                do { try run() } catch {
                    isRunning = false
                    throw error
                }
            }
        }
    }

    func stop() {
        queue.sync {
            isRunning = false
            teardown()
        }
    }

    private func run() throws {
        teardown()
        let engine = AVAudioEngine()
        self.engine = engine
        // The default input needs no switching, and switching to it explicitly is what upsets
        // Bluetooth devices, so only set the device when it isn't the default.
        if var device = AudioDevices.deviceID(forUID: uid), device != AudioDevices.defaultInputID,
           let unit = engine.inputNode.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        try tapAndStart(engine)
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in self?.queue.async { self?.configurationChanged() } }
    }

    /// The route changed mid-recording (headset profile switch, device unplugged) and the engine
    /// stopped. Restart it; if the format changed too, an existing engine keeps reporting the old
    /// one, so start over on a fresh engine.
    private func configurationChanged() {
        guard isRunning, let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        do { try tapAndStart(engine) } catch { restart(attempt: 0) }
    }

    private func restart(attempt: Int) {
        guard isRunning else { return }
        do {
            try run()
        } catch where attempt < 5 {
            teardown()
            queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.restart(attempt: attempt + 1) }
        } catch {
            NSLog("microphone restart failed: \(error)")
        }
    }

    private func tapAndStart(_ engine: AVAudioEngine) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // A tap whose rate differs from the hardware's raises an exception instead of an error.
        guard format.sampleRate > 0, format.sampleRate == input.inputFormat(forBus: 0).sampleRate else {
            throw MicrophoneError.noInput
        }
        let deliver = onBuffer
        // Asks for ~20 ms buffers so the notch reacts to the voice right away.
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 50), format: format) {
            buffer, _ in deliver(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func teardown() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    enum MicrophoneError: LocalizedError {
        case noInput
        var errorDescription: String? { "No microphone input available" }
    }
}
