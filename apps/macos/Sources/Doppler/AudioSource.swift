import AVFoundation

protocol AudioSource: AnyObject {
    func checkAccess() -> String?
    var silenceMessage: String { get }
    /// May block briefly, so never call it on the main thread.
    /// onBuffer runs on an audio thread; the buffer is only valid during the call.
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws
    /// Returns once no more buffers will arrive.
    func stop()
}

enum InputSource: Codable, Hashable {
    /// A Core Audio input device UID, or empty for the system default.
    case microphone(uid: String)
    case app(bundleID: String)

    static let systemDefault = InputSource.microphone(uid: "")

    func makeSource() -> AudioSource {
        switch self {
        case .microphone(let uid): MicrophoneSource(uid: uid)
        case .app(let bundleID): AppAudioSource(bundleID: bundleID)
        }
    }
}
