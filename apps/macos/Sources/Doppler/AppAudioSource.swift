import AppKit
import AVFoundation
import CoreAudio

final class AppAudioSource: AudioSource {
    private let bundleID: String

    // Its own queue, so stop() can wait for in-flight callbacks.
    private let queue = DispatchQueue(label: "dev.doppler.app-audio", qos: .userInitiated)
    private var description: CATapDescription?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var processListener: AudioObjectPropertyListenerBlock?
    private var processAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                            mScope: kAudioObjectPropertyScopeGlobal,
                                                            mElement: kAudioObjectPropertyElementMain)

    init(bundleID: String) {
        self.bundleID = bundleID
    }

    /// macOS has no API to check this permission: it prompts on first capture.
    func checkAccess() -> String? { nil }

    /// Without the permission, macOS delivers silence rather than an error.
    var silenceMessage: String {
        "No sound from \(AudioApps.name(of: bundleID)). Check it's playing and allow System Audio Recording in Privacy & Security."
    }

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        do {
            let description = CATapDescription(monoMixdownOfProcesses: AudioApps.processes(of: bundleID))
            description.uuid = UUID()
            description.name = "Doppler"
            description.muteBehavior = .unmuted
            description.isPrivate = true
            self.description = description
            try check(AudioHardwareCreateProcessTap(description, &tapID))

            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Doppler",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID))

            var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                           mScope: kAudioObjectPropertyScopeGlobal,
                                                           mElement: kAudioObjectPropertyElementMain)
            var stream = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &stream))
            guard let format = AVAudioFormat(streamDescription: &stream) else { throw CaptureError(status: -1) }

            // Apps can start their audio process on first playback, so follow the process list.
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.updateProcesses() }
            processListener = listener
            try check(AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &processAddress,
                                                          queue, listener))

            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, deviceID, queue) { _, input, _, _, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil)
                else { return }
                onBuffer(buffer)
            })
            try check(AudioDeviceStart(deviceID, ioProc))
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let processListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &processAddress,
                                                   queue, processListener)
        }
        processListener = nil
        if let ioProc {
            AudioDeviceStop(deviceID, ioProc)
            AudioDeviceDestroyIOProcID(deviceID, ioProc)
        }
        ioProc = nil
        queue.sync {}  // let any in-flight callback finish, so no buffer arrives after stop
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
        deviceID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        description = nil
    }

    private func updateProcesses() {
        guard let description, tapID != kAudioObjectUnknown else { return }
        let processes = AudioApps.processes(of: bundleID)
        guard Set(processes) != Set(description.processes) else { return }
        description.processes = processes
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafePointer(to: description) {
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.stride), $0)
        }
        if status != noErr { NSLog("app audio tap update failed: \(status)") }
    }

    private func check(_ status: OSStatus) throws {
        if status != noErr { throw CaptureError(status: status) }
    }

    struct CaptureError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Couldn't capture app audio (\(status))" }
    }
}

struct AudioApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}

enum AudioApps {
    /// Safari's sound comes from a shared WebKit process that can't be attributed to it.
    private static let unsupported: Set<String> = ["com.apple.Safari"]

    static func available() -> [AudioApp] {
        let running = runningApps()
        let owners = Set(audioProcesses().compactMap { owner(of: $0.bundleID, among: running.keys) })
        return owners.subtracting(unsupported)
            .map { AudioApp(bundleID: $0, name: running[$0] ?? $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func processes(of bundleID: String) -> [AudioObjectID] {
        let apps = Set(runningApps().keys).union([bundleID])
        return audioProcesses().filter { owner(of: $0.bundleID, among: apps) == bundleID }.map(\.id)
    }

    static func name(of bundleID: String) -> String {
        if let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName {
            return name
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return url.deletingPathExtension().lastPathComponent
    }

    /// Helpers extend their app's bundle ID (com.example.App.helper). The longest match wins, so
    /// com.example.App.beta.helper belongs to com.example.App.beta rather than com.example.App.
    private static func owner(of process: String, among apps: some Sequence<String>) -> String? {
        apps.filter { process == $0 || process.hasPrefix($0 + ".") }.max { $0.count < $1.count }
    }

    private static func runningApps() -> [String: String] {
        var apps: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { continue }
            apps[id] = app.localizedName ?? id
        }
        return apps
    }

    private static func audioProcesses() -> [(id: AudioObjectID, bundleID: String)] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in bundleID(ofProcess: id).map { (id, $0) } }
    }

    private static func bundleID(ofProcess process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(process, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
