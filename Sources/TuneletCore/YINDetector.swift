import Accelerate

/// A detected pitch and how periodic the signal was.
public struct PitchEstimate: Sendable, Equatable {
    /// Fundamental frequency in Hz.
    public let frequency: Double
    /// 0...1, where 1 is perfectly periodic (1 - the YIN dip depth).
    public let confidence: Double
}

/// YIN pitch detector (de Cheveigné & Kawahara, 2002).
///
/// All working memory is allocated up front so `detect` can run on the analysis thread
/// without allocating. Not thread-safe: use one instance per thread.
public final class YINDetector {
    /// Frequencies the detector covers by default: below a slack D2 up past the high frets.
    public static let defaultRange: ClosedRange<Double> = 60...1200

    public let sampleRate: Double
    public let minFrequency: Double
    public let maxFrequency: Double
    /// Dip threshold on the cumulative mean normalized difference. Lower is stricter.
    public let threshold: Float
    /// Number of samples `detect` expects.
    public let windowSize: Int

    private let minLag: Int
    private let maxLag: Int
    private var difference: [Float]
    private var normalized: [Float]

    public init(
        sampleRate: Double,
        minFrequency: Double = YINDetector.defaultRange.lowerBound,
        maxFrequency: Double = YINDetector.defaultRange.upperBound,
        threshold: Float = 0.15,
        windowDuration: Double = 0.085
    ) {
        precondition(sampleRate > 0 && minFrequency > 0 && maxFrequency > minFrequency)
        self.sampleRate = sampleRate
        self.minFrequency = minFrequency
        self.maxFrequency = maxFrequency
        self.threshold = threshold

        maxLag = Int((sampleRate / minFrequency).rounded(.up)) + 1
        minLag = max(2, Int((sampleRate / maxFrequency).rounded(.down)))
        // The comparison span must cover at least one full period of the lowest note on top of the lag.
        windowSize = max(Int(sampleRate * windowDuration), 2 * maxLag)

        difference = [Float](repeating: 0, count: maxLag + 1)
        normalized = [Float](repeating: 1, count: maxLag + 1)
    }

    /// Returns the pitch of `samples` (must hold `windowSize` samples), or nil if no clear pitch is present.
    public func detect(_ samples: UnsafeBufferPointer<Float>) -> PitchEstimate? {
        precondition(samples.count >= windowSize, "expected \(windowSize) samples, got \(samples.count)")
        guard let base = samples.baseAddress else { return nil }
        let span = vDSP_Length(windowSize - maxLag)

        // Difference function: d(lag) = sum over the span of (x[i] - x[i + lag])^2
        for lag in 1...maxLag {
            var sum: Float = 0
            vDSP_distancesq(base, 1, base + lag, 1, &sum, span)
            difference[lag] = sum
        }

        // Cumulative mean normalized difference: d'(lag) = d(lag) * lag / sum(d(1...lag))
        normalized[0] = 1
        var runningSum: Float = 0
        for lag in 1...maxLag {
            runningSum += difference[lag]
            normalized[lag] = runningSum > 0 ? difference[lag] * Float(lag) / runningSum : 1
        }

        // Absolute threshold: the first dip below threshold, followed down to its local minimum.
        // Taking the first (shortest-lag) dip rather than the global minimum is what avoids
        // octave-down errors.
        var lag = minLag
        var bestLag = -1
        while lag < maxLag {
            if normalized[lag] < threshold {
                while lag + 1 < maxLag && normalized[lag + 1] < normalized[lag] { lag += 1 }
                bestLag = lag
                break
            }
            lag += 1
        }
        guard bestLag > 0 else { return nil }

        // Parabolic interpolation around the dip for sub-sample lag precision.
        var refinedLag = Double(bestLag)
        let left = Double(normalized[bestLag - 1])
        let center = Double(normalized[bestLag])
        let right = Double(normalized[bestLag + 1])
        let curvature = left - 2 * center + right
        if curvature > 0 {
            refinedLag += 0.5 * (left - right) / curvature
        }

        let frequency = sampleRate / refinedLag
        guard frequency >= minFrequency, frequency <= maxFrequency else { return nil }
        return PitchEstimate(frequency: frequency, confidence: Double(1 - center))
    }

    public func detect(_ samples: [Float]) -> PitchEstimate? {
        samples.withUnsafeBufferPointer { detect($0) }
    }
}
