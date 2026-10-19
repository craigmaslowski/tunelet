import Testing
@testable import TuneletCore

@Suite struct PitchSmootherTests {
    private func pitch(_ f: Double) -> PitchEstimate { PitchEstimate(frequency: f, confidence: 0.95) }
    private let dt = 0.02

    private func isPitch(_ output: PitchSmoother.Output, _ expected: Double) -> Bool {
        if case .pitch(let f) = output { return abs(f - expected) < 1e-9 }
        return false
    }

    @Test func medianDropsOutliers() {
        var s = PitchSmoother()
        var t = 0.0
        for f in [110.0, 110.2, 109.9, 110.1] { _ = s.update(pitch(f), at: t); t += dt }
        // A single reading 60¢ sharp (inside the jump threshold) is outvoted: the median stays
        // within the clean readings (109.9...110.2).
        guard case .pitch(let out) = s.update(pitch(110 * 1.035), at: t) else { Issue.record("no pitch"); return }
        #expect((109.9...110.2).contains(out))
    }

    @Test func loneOctaveErrorIsIgnored() {
        var s = PitchSmoother()
        var t = 0.0
        for _ in 0..<5 { _ = s.update(pitch(82.4), at: t); t += dt }
        #expect(s.update(pitch(164.8), at: t) == .pitch(82.4))
        t += dt
        #expect(s.update(pitch(82.4), at: t) == .pitch(82.4))
    }

    @Test func newNoteShowsAfterTwoAgreeingReadings() {
        var s = PitchSmoother()
        var t = 0.0
        for _ in 0..<5 { _ = s.update(pitch(82.41), at: t); t += dt }
        #expect(s.update(pitch(110), at: t) == .pitch(82.41))
        t += dt
        #expect(isPitch(s.update(pitch(110.1), at: t), 110.05))
    }

    @Test func holdsThenClears() {
        var s = PitchSmoother(holdDuration: 1.5)
        _ = s.update(pitch(196), at: 0)
        #expect(s.update(nil, at: 0.5) == .held(196))
        #expect(s.update(nil, at: 1.5) == .held(196))
        #expect(s.update(nil, at: 1.6) == .none)
        // After clearing, a new pitch starts fresh rather than being treated as a jump.
        #expect(s.update(pitch(247), at: 1.7) == .pitch(247))
    }

    @Test func pitchReturningDuringHoldResumes() {
        var s = PitchSmoother()
        _ = s.update(pitch(146.8), at: 0)
        _ = s.update(nil, at: 0.3)
        #expect(isPitch(s.update(pitch(146.9), at: 0.4), 146.85))
    }

    @Test func tracksSlowTuningSweep() {
        // Turning a peg: pitch rises steadily by ~1¢ per reading. Must follow, never reset or stall.
        var s = PitchSmoother()
        var f = 100.0
        var t = 0.0
        var last = 0.0
        for _ in 0..<200 {
            guard case .pitch(let out) = s.update(pitch(f), at: t) else { Issue.record("lost pitch"); return }
            #expect(out >= last)
            // Median of 5 lags by 2 readings: about 2¢.
            #expect(abs(Pitch.cents(out, from: f)) < 3)
            last = out
            f *= 1.000578 // +1¢
            t += dt
        }
    }
}

@Suite struct TunerModeTests {
    @Test func guitarModeTargetsNearestString() {
        let a3 = Note("A3")!.frequency(a4: 440)
        let target = TunerMode.guitar.target(for: a3, tuning: .standard, a4: 440)
        // A3 is between G3 and B3; B3 (200¢ away) and G3 (200¢ away) tie, nearest picks the first.
        #expect(target.string == 3 || target.string == 4)
        #expect(abs(abs(target.cents) - 200) < 1e-6)
    }

    @Test func chromaticModeTargetsNearestNote() {
        let a3 = Note("A3")!.frequency(a4: 440) * 1.003
        let target = TunerMode.chromatic.target(for: a3, tuning: .standard, a4: 440)
        #expect(target.note == Note("A3")!)
        #expect(target.string == nil)
        #expect(abs(target.cents - Pitch.cents(1.003, from: 1)) < 1e-6)
    }
}
