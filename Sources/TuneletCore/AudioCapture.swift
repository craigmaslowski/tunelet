import AVFoundation

public enum AudioCaptureError: LocalizedError {
    case noInputDevice
    case unsupportedFormat(AVAudioFormat)

    public var errorDescription: String? {
        switch self {
        case .noInputDevice: "No audio input device is available."
        case .unsupportedFormat(let format): "Unsupported input format: \(format)."
        }
    }
}

/// Captures the default input device and delivers pitch readings on the main actor.
///
/// Signal path: input node → `AVAudioSinkNode` (real-time thread, copies channel 0 into a
/// `SampleRing`) → `PitchAnalyzer` (own queue, every ~20 ms) → `onReading` (main actor).
/// Microphone permission is the caller's responsibility.
@MainActor
public final class AudioCapture {
    public var onReading: ((PitchReading) -> Void)?
    /// Called if capture stops on its own, e.g. the input device went away and restarting failed.
    public var onFailure: ((Error) -> Void)?

    public private(set) var isRunning = false
    public private(set) var sampleRate: Double = 0

    private let engine = AVAudioEngine()
    private var sink: AVAudioSinkNode?
    private var analyzer: PitchAnalyzer?
    private var configObserver: (any NSObjectProtocol)?

    public init() {}

    public func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioCaptureError.noInputDevice }
        guard format.commonFormat == .pcmFormatFloat32 else { throw AudioCaptureError.unsupportedFormat(format) }

        let windowSize = YINDetector(sampleRate: format.sampleRate).windowSize
        // About a second of headroom: the analyzer reads every 20 ms, so it can never be lapped in practice.
        let ring = SampleRing(minimumCapacity: max(Int(format.sampleRate), 4 * windowSize))
        let stride = format.isInterleaved ? Int(format.channelCount) : 1
        let sink = Self.makeSink(writingTo: ring, stride: stride)
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)

        let analyzer = PitchAnalyzer(ring: ring, sampleRate: format.sampleRate)
        do {
            engine.prepare()
            try engine.start()
        } catch {
            engine.detach(sink)
            throw error
        }
        analyzer.start { [weak self] reading in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.onReading?(reading) }
            }
        }

        self.sink = sink
        self.analyzer = analyzer
        sampleRate = format.sampleRate
        isRunning = true

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAfterConfigurationChange() }
        }
    }

    public func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        analyzer?.stop()
        analyzer = nil
        engine.stop()
        if let sink {
            engine.disconnectNodeInput(sink)
            engine.detach(sink)
        }
        sink = nil
        isRunning = false
    }

    /// The input device or its format changed (e.g. a headset was plugged in): rebuild for the new format.
    private func restartAfterConfigurationChange() {
        guard isRunning else { return }
        stop()
        do {
            try start()
        } catch {
            onFailure?(error)
        }
    }

    /// Built outside the main actor so the block doesn't inherit main-actor isolation:
    /// it runs on the real-time audio thread.
    private nonisolated static func makeSink(writingTo ring: SampleRing, stride: Int) -> AVAudioSinkNode {
        AVAudioSinkNode { _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
            guard buffers.count > 0, let data = buffers[0].mData else { return noErr }
            ring.write(data.assumingMemoryBound(to: Float.self), count: Int(frameCount), stride: stride)
            return noErr
        }
    }
}
