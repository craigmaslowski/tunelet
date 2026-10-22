import AVFoundation
import Accelerate

/// A plucked-string reference tone, built by additive synthesis so its pitch is exact.
///
/// A fundamental plus a few harmonics, each decaying, with upper harmonics fading faster like a
/// real string. The harmonics matter on laptop speakers, which barely reproduce a low E's 82 Hz
/// fundamental; the ear still hears the pitch from them.
public enum ReferenceTone {
    public static let duration = 2.0
    public static let peak: Float = 0.5   // -6 dBFS

    /// Relative amplitude of each harmonic (fundamental first).
    static let harmonics: [Double] = [1.0, 0.5, 0.3, 0.2, 0.12, 0.08]
    static let attack = 0.005     // seconds of fade-in, to avoid a click at the start
    static let release = 0.05     // seconds of fade-out at the end

    public static func pluck(frequency: Double, sampleRate: Double, duration: Double = duration) -> [Float] {
        let count = Int(sampleRate * duration)
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            var value = 0.0
            for (index, amplitude) in harmonics.enumerated() {
                let n = Double(index + 1)
                let partial = frequency * n
                guard partial < sampleRate / 2 else { break }
                value += amplitude * exp(-t * (1.5 + 0.8 * n)) * sin(2 * .pi * partial * t)
            }
            let fadeIn = min(1, t / attack)
            let fadeOut = min(1, (duration - t) / release)
            samples[i] = Float(value * fadeIn * max(0, fadeOut))
        }

        var maxAbs: Float = 0
        vDSP_maxmgv(samples, 1, &maxAbs, vDSP_Length(count))
        if maxAbs > 0 {
            var scale = peak / maxAbs
            vDSP_vsmul(samples, 1, &scale, &samples, 1, vDSP_Length(count))
        }
        return samples
    }
}

/// Plays reference tones through the default output, on its own engine (separate from capture).
@MainActor
public final class ReferenceTonePlayer {
    /// Called when a tone finishes on its own or is stopped.
    public var onFinish: (() -> Void)?
    public private(set) var isPlaying = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    /// Identifies the current tone, so a finished tone that was replaced doesn't report finishing.
    private var generation = 0

    public init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    public func play(frequency: Double) throws {
        let samples = ReferenceTone.pluck(frequency: frequency, sampleRate: format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        generation += 1
        let current = generation
        player.stop()
        isPlaying = true
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == current else { return }
                    self.isPlaying = false
                    self.onFinish?()
                }
            }
        }
        player.play()
    }

    public func stop() {
        guard isPlaying || engine.isRunning else { return }
        generation += 1
        player.stop()
        engine.stop()
        if isPlaying {
            isPlaying = false
            onFinish?()
        }
    }
}
