import Foundation

/// Builds test signals that behave like a plucked guitar string rather than a pure sine.
enum SyntheticSignal {
    /// Harmonic amplitudes typical of a low acoustic string: a weak fundamental with stronger
    /// 2nd and 3rd harmonics. This is the case that causes octave errors.
    static let weakFundamental: [Double] = [0.35, 1.0, 0.8, 0.5, 0.35, 0.2, 0.12, 0.08]

    static func pluck(
        frequency: Double,
        sampleRate: Double,
        count: Int,
        harmonics: [Double] = weakFundamental,
        inharmonicity: Double = 0,
        noise: Double = 0.02,
        seed: UInt64 = 1
    ) -> [Float] {
        var rng = SeededGenerator(seed: seed)
        return (0..<count).map { i in
            let t = Double(i) / sampleRate
            var sample = 0.0
            for (index, amplitude) in harmonics.enumerated() {
                let n = Double(index + 1)
                // Real strings are slightly stiff, so upper partials run sharp of n * f.
                let partial = n * frequency * (1 + inharmonicity * n * n).squareRoot()
                guard partial < sampleRate / 2 else { break }
                sample += amplitude * exp(-t * (1 + n)) * sin(2 * .pi * partial * t + n)
            }
            sample += Double.random(in: -noise...noise, using: &rng)
            return Float(0.25 * sample)
        }
    }

    /// A long, decaying pluck where each harmonic has its own decay rate (per second), over a
    /// constant noise floor. With the default low-E profile the fundamental starts weak and dies
    /// faster than the 2nd harmonic, which is what makes a fading string read an octave high.
    static func decayingPluck(
        frequency: Double,
        sampleRate: Double,
        duration: Double,
        partials: [(amplitude: Double, decay: Double)] = [(0.35, 1.1), (1.0, 0.55), (0.8, 0.8), (0.5, 1.0), (0.3, 1.4), (0.2, 1.8)],
        gain: Double = 0.15,
        noiseFloor: Double = 0.0015,
        seed: UInt64 = 3
    ) -> [Float] {
        var rng = SeededGenerator(seed: seed)
        return (0..<Int(sampleRate * duration)).map { i in
            let t = Double(i) / sampleRate
            var sample = 0.0
            for (index, partial) in partials.enumerated() {
                let n = Double(index + 1)
                sample += partial.amplitude * exp(-t * partial.decay) * sin(2 * .pi * frequency * n * t + n)
            }
            return Float(gain * sample + Double.random(in: -noiseFloor...noiseFloor, using: &rng))
        }
    }

    static func whiteNoise(count: Int, amplitude: Float = 0.2, seed: UInt64 = 7) -> [Float] {
        var rng = SeededGenerator(seed: seed)
        return (0..<count).map { _ in Float.random(in: -amplitude...amplitude, using: &rng) }
    }
}

/// Deterministic generator (SplitMix64) so signal tests are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
