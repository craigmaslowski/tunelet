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

    public private(set) var detector: YINDetector
    public let silenceRMS: Float

    // Everything below is confined to `queue` once started.
    private let ring: SampleRing
    private let window: UnsafeMutablePointer<Float>
    private var lastAnalyzedEnd = -1
    private let queue = DispatchQueue(label: "Tunelet.PitchAnalyzer", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    public init(ring: SampleRing, sampleRate: Double, minimumFrequency: Double = YINDetector.defaultRange.lowerBound,
                silenceRMS: Float = PitchAnalyzer.defaultSilenceRMS) {
        detector = YINDetector(sampleRate: sampleRate, minFrequency: minimumFrequency)
        // Room for the largest window any floor can need, so changing the floor never reallocates.
        let capacity = max(detector.windowSize, YINDetector(sampleRate: sampleRate, minFrequency: Self.lowestFloor).windowSize)
        precondition(ring.capacity >= capacity, "ring smaller than the analysis window")
        self.ring = ring
        self.silenceRMS = silenceRMS
        window = .allocate(capacity: capacity)
        window.initialize(repeating: 0, count: capacity)
    }

    /// No floor below this is supported.
    public static let lowestFloor = 30.0

    /// Changes the lowest frequency listened for. Safe while running: the detector is replaced on
    /// the analysis queue, between analyses. Waits until the change has taken effect.
    public func setMinimumFrequency(_ frequency: Double) {
        let floor = max(frequency, Self.lowestFloor)
        queue.sync {
            guard abs(detector.minFrequency - floor) > 0.01 else { return }
            detector = YINDetector(sampleRate: detector.sampleRate, minFrequency: floor)
            lastAnalyzedEnd = -1
        }
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
