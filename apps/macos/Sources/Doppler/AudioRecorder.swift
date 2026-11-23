import AVFoundation

/// Starting a source can take a second, so it happens on a private queue: blocking the main
/// thread would freeze the notch animation.
final class AudioRecorder {
    /// Called on the audio thread with each converted chunk.
    var onChunk: (Data) -> Void = { _ in }
    var onMeter: (Float) -> Void = { _ in }
    var onError: (Error) -> Void = { _ in }

    private static let minChunkBytes = 1600  // 50 ms
    private static let meterHop = 320  // 20 ms at 16 kHz
    private static let meterWindow = 512  // 32 ms at 16 kHz

    private let source: AudioSource
    private let queue = DispatchQueue(label: "dev.doppler.recorder", qos: .userInitiated)
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var pending = Data()
    private var meterSamples: [Int16] = []
    private var samplesSinceMeter = 0

    init(source: AudioSource) {
        self.source = source
    }

    var silenceMessage: String { source.silenceMessage }

    func start() {
        queue.async { [self] in
            do {
                try source.start { [weak self] buffer in self?.process(buffer) }
            } catch {
                DispatchQueue.main.async { self.onError(error) }
            }
        }
    }

    /// Returns once the source is off, so no chunk arrives after it.
    func stop() {
        queue.sync {
            source.stop()
            if !pending.isEmpty { onChunk(pending) }
            pending = Data()
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        // A microphone's format can change mid-recording when the route changes.
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outFormat)
        }
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
        meter(samples, count: Int(out.frameLength))

        // Sources deliver anywhere from 10 to 100 ms at a time; don't send tiny messages.
        pending.append(Data(bytes: samples, count: Int(out.frameLength) * 2))
        guard pending.count >= Self.minChunkBytes else { return }
        onChunk(pending)
        pending = Data()
    }

    /// Measures every 20 ms of audio. When a source delivers a larger block, each measurement is
    /// shown at its own moment, so the notch follows the voice instead of jumping once per block.
    private func meter(_ samples: UnsafePointer<Int16>, count: Int) {
        var offset = 0, step = 0
        while offset < count {
            let hop = min(Self.meterHop - samplesSinceMeter, count - offset)
            meterSamples.append(contentsOf: UnsafeBufferPointer(start: samples + offset, count: hop))
            if meterSamples.count > Self.meterWindow { meterSamples.removeFirst(meterSamples.count - Self.meterWindow) }
            offset += hop
            samplesSinceMeter += hop
            guard samplesSinceMeter == Self.meterHop else { continue }
            samplesSinceMeter = 0

            let level = meterSamples.withUnsafeBufferPointer { Self.level($0.baseAddress!, count: $0.count) }
            let delay = Double(step) * Double(Self.meterHop) / 16000
            step += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.onMeter(level)
            }
        }
    }

    private static func level(_ samples: UnsafePointer<Int16>, count: Int) -> Float {
        var sum: Float = 0
        for i in 0..<count {
            let s = Float(samples[i]) / 32768
            sum += s * s
        }
        let rms = (sum / Float(max(count, 1))).squareRoot()
        let db = 20 * log10(max(rms, 1e-6))
        return min(max((db + 48) / 33, 0), 1)  // -48 dB -> 0, -15 dB -> 1
    }
}
