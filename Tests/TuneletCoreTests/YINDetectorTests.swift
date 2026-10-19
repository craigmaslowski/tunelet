import Foundation
import Testing
@testable import TuneletCore

@Suite struct YINDetectorTests {
    static let sampleRates = [44_100.0, 48_000.0, 96_000.0]

    /// Every semitone from D2 (lowest tuning in use) through E5 (12th fret, high E), plus the
    /// range floor region a slack string would pass through.
    static let frequencies: [Double] = [62.0, 65.4] + (38...76).map { Note(midi: $0).frequency(a4: 440) }

    @Test(arguments: sampleRates)
    func detectsGuitarRangePrecisely(sampleRate: Double) {
        let detector = YINDetector(sampleRate: sampleRate)
        for frequency in Self.frequencies {
            let signal = SyntheticSignal.pluck(frequency: frequency, sampleRate: sampleRate, count: detector.windowSize)
            guard let estimate = detector.detect(signal) else {
                Issue.record("no pitch for \(frequency) Hz at \(sampleRate) Hz")
                continue
            }
            let error = Pitch.cents(estimate.frequency, from: frequency)
            #expect(abs(error) < 0.25, "\(frequency) Hz read as \(estimate.frequency) Hz (\(error)¢)")
            #expect(estimate.confidence > 0.85)
        }
    }

    /// Real strings are stiff, so their overtones run slightly sharp. YIN reports the period of the
    /// whole waveform, which those overtones pull a little sharp of the bare fundamental. This is the
    /// accepted behaviour (see DESIGN.md); the test pins the size of the effect so a change shows up.
    @Test(arguments: sampleRates)
    func stiffStringReadsSlightlySharp(sampleRate: Double) {
        let detector = YINDetector(sampleRate: sampleRate)
        for frequency in Self.frequencies {
            let signal = SyntheticSignal.pluck(frequency: frequency, sampleRate: sampleRate,
                                               count: detector.windowSize, inharmonicity: 0.0001)
            guard let estimate = detector.detect(signal) else {
                Issue.record("no pitch for \(frequency) Hz at \(sampleRate) Hz")
                continue
            }
            let error = Pitch.cents(estimate.frequency, from: frequency)
            #expect(error > 0 && error < 2, "\(frequency) Hz read as \(estimate.frequency) Hz (\(error)¢)")
        }
    }

    @Test func resolvesSmallDetuning() {
        let detector = YINDetector(sampleRate: 48_000)
        let target = Note("E2")!.frequency(a4: 440)
        for offset in [-20.0, -5, -1, 1, 5, 20] {
            let frequency = target * pow(2, offset / 1200)
            let estimate = detector.detect(SyntheticSignal.pluck(frequency: frequency, sampleRate: 48_000, count: detector.windowSize))
            let measured = estimate.map { Pitch.cents($0.frequency, from: target) }
            #expect(measured.map { abs($0 - offset) < 0.1 } == true, "expected \(offset)¢, got \(String(describing: measured))")
        }
    }

    @Test func pureSineIsExact() {
        let detector = YINDetector(sampleRate: 48_000)
        let signal = SyntheticSignal.pluck(frequency: 110, sampleRate: 48_000, count: detector.windowSize,
                                           harmonics: [1], inharmonicity: 0, noise: 0)
        let estimate = detector.detect(signal)
        #expect(estimate.map { abs(Pitch.cents($0.frequency, from: 110)) < 0.05 } == true)
    }

    @Test func silenceHasNoPitch() {
        let detector = YINDetector(sampleRate: 48_000)
        #expect(detector.detect([Float](repeating: 0, count: detector.windowSize)) == nil)
    }

    @Test(arguments: [1, 2, 3, 4, 5] as [UInt64])
    func whiteNoiseHasNoPitch(seed: UInt64) {
        let detector = YINDetector(sampleRate: 48_000)
        #expect(detector.detect(SyntheticSignal.whiteNoise(count: detector.windowSize, seed: seed)) == nil)
    }

    @Test func rejectsPitchBelowRange() {
        let detector = YINDetector(sampleRate: 48_000)
        let signal = SyntheticSignal.pluck(frequency: 45, sampleRate: 48_000, count: detector.windowSize)
        if let estimate = detector.detect(signal) {
            // Allowed to lock onto a harmonic, but never to report something below the floor.
            #expect(estimate.frequency >= detector.minFrequency)
        }
    }

    @Test func windowSizeCoversLowestPeriodTwice() {
        for rate in Self.sampleRates {
            let detector = YINDetector(sampleRate: rate)
            #expect(Double(detector.windowSize) >= 2 * rate / detector.minFrequency)
            #expect(Double(detector.windowSize) >= rate * 0.085 - 1)
        }
    }
}
