import Accelerate
import Dispatch
import Foundation

/// One analysis result: the detected pitch (nil when none) and the window's RMS level.
public struct PitchReading: Sendable, Equatable {
    public let estimate: PitchEstimate?
    public let rms: Float

    public init(estimate: PitchEstimate?, rms: Float) {
        self.estimate = estimate
        self.rms = rms
    }

    /// Level in dB relative to full scale.
    public var levelDBFS: Float { 20 * log10(max(rms, 1e-9)) }
}

/// Runs YIN over the newest window of a `SampleRing` on a fixed schedule, on its own queue.
public final class PitchAnalyzer: @unchecked Sendable {
    public static let defaultInterval: DispatchTimeInterval = .milliseconds(20)
    /// Below this RMS (-50 dBFS) the window counts as silence and YIN is skipped.
    public static let defaultSilenceRMS: Float = 0.00316

    public let detector: YINDetector
    public let silenceRMS: Float

    // Everything below is confined to `queue` once started.
    private let ring: SampleRing
    private let window: UnsafeMutablePointer<Float>
    private var lastAnalyzedEnd = -1
    private let queue = DispatchQueue(label: "Tunelet.PitchAnalyzer", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    public init(ring: SampleRing, sampleRate: Double, silenceRMS: Float = PitchAnalyzer.defaultSilenceRMS) {
        detector = YINDetector(sampleRate: sampleRate)
        precondition(ring.capacity >= detector.windowSize, "ring smaller than the analysis window")
        self.ring = ring
        self.silenceRMS = silenceRMS
        window = .allocate(capacity: detector.windowSize)
        window.initialize(repeating: 0, count: detector.windowSize)
    }

    deinit {
        timer?.cancel()
        window.deallocate()
    }

    /// Starts analysing every `interval`. `handler` is called on the analysis queue.
    /// Call from one thread only (the owner's), together with `stop`.
    public func start(interval: DispatchTimeInterval = defaultInterval,
                      handler: @escaping @Sendable (PitchReading) -> Void) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            if let reading = self?.analyze() { handler(reading) }
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Analyses the newest window. Returns nil if no new audio arrived since the last call or
    /// there isn't a full window yet. Exposed for tests; in the app only the timer calls it.
    func analyze() -> PitchReading? {
        let end = ring.totalWritten
        guard end != lastAnalyzedEnd else { return nil }
        let count = detector.windowSize
        guard ring.copyLatest(count, into: window) else { return nil }
        lastAnalyzedEnd = end

        var rms: Float = 0
        vDSP_rmsqv(window, 1, &rms, vDSP_Length(count))
        let estimate = rms >= silenceRMS ? detector.detect(UnsafeBufferPointer(start: window, count: count)) : nil
        return PitchReading(estimate: estimate, rms: rms)
    }
}
