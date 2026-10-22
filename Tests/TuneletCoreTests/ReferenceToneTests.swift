import Accelerate
import Foundation
import Testing
@testable import TuneletCore

@Suite struct ReferenceToneTests {
    static let sampleRate = 48_000.0

    /// The tone must be exactly the note it claims to be, checked with Tunelet's own detector.
    @Test(arguments: [440.0, 442.0, 432.0])
    func pitchIsExact(a4: Double) throws {
        let detector = YINDetector(sampleRate: Self.sampleRate)
        for note in Tuning.standard.strings + [Note("D2")!] {
            let f = note.frequency(a4: a4)
            let tone = ReferenceTone.pluck(frequency: f, sampleRate: Self.sampleRate)
            // A window from the body of the tone, after the attack.
            let start = Int(Self.sampleRate * 0.2)
            let window = Array(tone[start..<(start + detector.windowSize)])
            let estimate = try #require(detector.detect(window))
            #expect(abs(Pitch.cents(estimate.frequency, from: f)) < 0.1, "\(note) at A4=\(a4): \(estimate.frequency) Hz")
        }
    }

    @Test func lengthAndLevel() {
        let tone = ReferenceTone.pluck(frequency: 82.41, sampleRate: Self.sampleRate)
        #expect(tone.count == Int(Self.sampleRate * ReferenceTone.duration))
        var peak: Float = 0
        vDSP_maxmgv(tone, 1, &peak, vDSP_Length(tone.count))
        #expect(abs(peak - ReferenceTone.peak) < 1e-5)
    }

    /// Starting or ending on a non-zero sample makes an audible click.
    @Test(arguments: [82.41, 329.63])
    func startsAndEndsSilently(frequency: Double) {
        let tone = ReferenceTone.pluck(frequency: frequency, sampleRate: Self.sampleRate)
        #expect(abs(tone.first!) < 1e-4)
        #expect(abs(tone.last!) < 1e-4)
        // No jump between neighbouring samples bigger than the signal's own steepest slope allows.
        let maxStep = zip(tone, tone.dropFirst()).map { abs($1 - $0) }.max()!
        #expect(maxStep < 0.1)
    }
}
