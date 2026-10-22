import Accelerate
import Testing
@testable import TuneletCore

@Suite struct PitchSmootherTests {
    private let dt = 0.02

    private func reading(_ f: Double?, level: Float = 0.1) -> PitchReading {
        PitchReading(estimate: f.map { PitchEstimate(frequency: $0, confidence: 0.95) }, rms: level)
    }

    private func frequency(_ output: PitchSmoother.Output) -> Double? {
        switch output {
        case .pitch(let f), .held(let f): f
        case .none: nil
        }
    }

    /// Feeds `count` readings of `f` at a steady level, returning the last output and advancing `t`.
    @discardableResult
    private func steady(_ s: inout PitchSmoother, _ f: Double?, count: Int, level: Float = 0.1,
                        t: inout Double) -> PitchSmoother.Output {
        var out = PitchSmoother.Output.none
        for _ in 0..<count { out = s.update(reading(f, level: level), at: t); t += dt }
        return out
    }

    @Test func medianSettlesJitter() {
        var s = PitchSmoother()
        var t = 0.0
        for f in [110.0, 110.2, 109.9, 110.1, 110.0, 110.3, 109.8, 110.1] { _ = s.update(reading(f), at: t); t += dt }
        // A single reading 60¢ sharp (inside the jump threshold) is outvoted.
        guard case .pitch(let out) = s.update(reading(110 * 1.035), at: t) else { Issue.record("no pitch"); return }
        #expect((109.9...110.2).contains(out))
    }

    @Test func harmonicWithoutAttackIsIgnored() {
        var s = PitchSmoother()
        var t = 0.0
        steady(&s, 82.4, count: 10, t: &t)
        // The 2nd harmonic takes over as the string fades (level falling, no attack).
        for i in 0..<100 {
            let out = s.update(reading(164.8, level: 0.08 - Float(i) * 0.0005), at: t)
            t += dt
            if let f = frequency(out) { #expect(abs(f - 82.4) < 0.01, "showed \(f) Hz") }
        }
    }

    @Test(arguments: [2.0, 3.0, 0.5])
    func harmonicJumpWithAttackIsANewNote(ratio: Double) {
        var s = PitchSmoother()
        var t = 0.0
        steady(&s, 110, count: 10, level: 0.02, t: &t)
        // A fresh pluck: level jumps well over +6 dB. Shown once three readings agree.
        _ = s.update(reading(110 * ratio, level: 0.2), at: t)
        _ = s.update(reading(110 * ratio, level: 0.2), at: t + dt)
        #expect(s.update(reading(110 * ratio, level: 0.2), at: t + 2 * dt) == .pitch(110 * ratio))
    }

    /// Regression: the attack read an octave high, then the true fundamental arrived without a new
    /// attack and was rejected as a "harmonic", so the wrong note stuck.
    @Test func dropToSubharmonicWithoutAttackIsAccepted() {
        var s = PitchSmoother()
        var t = 0.0
        steady(&s, 164.8, count: 10, level: 0.05, t: &t)
        for _ in 0..<4 {
            #expect(frequency(s.update(reading(82.4, level: 0.04), at: t)) == 164.8)
            t += dt
        }
        #expect(s.update(reading(82.4, level: 0.04), at: t) == .pitch(82.4))
    }

    /// Regression: the first readings of a low-string pluck can be an octave high. They must not be
    /// shown, even for one frame, when the following readings disagree.
    @Test func octaveHighFirstReadingIsNotShown() {
        var s = PitchSmoother()
        var t = 0.0
        steady(&s, nil, count: 5, level: 0.0005, t: &t)                        // silence
        #expect(s.update(reading(164.8, level: 0.05), at: t) == PitchSmoother.Output.none)
        t += dt
        #expect(s.update(reading(82.4, level: 0.06), at: t) == PitchSmoother.Output.none)
        t += dt
        #expect(s.update(reading(82.4, level: 0.06), at: t) == PitchSmoother.Output.none)
        t += dt
        #expect(s.update(reading(82.4, level: 0.06), at: t) == .pitch(82.4))
    }

    @Test func unrelatedNoteWithoutAttackNeedsToPersist() {
        var s = PitchSmoother()
        var t = 0.0
        steady(&s, 82.41, count: 10, t: &t)
        // 110 Hz (A2) is not harmonically related to E2. No attack: shown after 5 consistent readings.
        for _ in 0..<4 {
            #expect(frequency(s.update(reading(110), at: t)) == 82.41)
            t += dt
        }
        #expect(s.update(reading(110), at: t) == .pitch(110))
    }

    @Test func loneOutlierDoesNotFlicker() {
        var s = PitchSmoother()
        var t = 0.0
        steady(&s, 82.4, count: 10, t: &t)
        #expect(s.update(reading(164.8), at: t) == .pitch(82.4))
        t += dt
        #expect(s.update(reading(82.4), at: t) == .pitch(82.4))
    }

    @Test func tailBelowPeakIsNotTrusted() {
        var s = PitchSmoother()
        var t = 0.0
        steady(&s, 196, count: 5, level: 0.3, t: &t)
        // Still detecting a (slightly wandering) pitch, but 36 dB below the peak.
        let out = steady(&s, 197.5, count: 10, level: 0.0047, t: &t)
        #expect(out == .held(196))
    }

    @Test func holdsThenClears() {
        var s = PitchSmoother()
        _ = s.update(reading(196), at: -0.04)
        _ = s.update(reading(196), at: -0.02)
        #expect(s.update(reading(196), at: 0) == .pitch(196))
        #expect(s.update(reading(nil), at: 0.05) == .pitch(196))   // within dropout grace
        #expect(s.update(reading(nil), at: 0.5) == .held(196))
        #expect(s.update(reading(nil), at: 1.5) == .held(196))
        #expect(s.update(reading(nil), at: 1.6) == PitchSmoother.Output.none)
        // After clearing, a new pitch starts fresh once three readings agree.
        #expect(s.update(reading(247), at: 1.70) == PitchSmoother.Output.none)
        #expect(s.update(reading(247), at: 1.72) == PitchSmoother.Output.none)
        #expect(s.update(reading(247), at: 1.74) == .pitch(247))
    }

    @Test func tracksSlowTuningSweep() {
        // Turning a peg: pitch rises steadily by ~1¢ per reading. Must follow, never reset or stall.
        var s = PitchSmoother()
        var f = 100.0
        var t = 0.0
        var last = 0.0
        _ = s.update(reading(f), at: t - 2 * dt)   // the first readings only confirm the note
        _ = s.update(reading(f), at: t - dt)
        for _ in 0..<200 {
            guard case .pitch(let out) = s.update(reading(f), at: t) else { Issue.record("lost pitch"); return }
            #expect(out >= last)
            // Median of 9 lags by 4 readings: about 4¢.
            #expect(abs(Pitch.cents(out, from: f)) < 5)
            last = out
            f *= 1.000578 // +1¢
            t += dt
        }
    }

    /// End-to-end reproduction of the reported bug: a fading low E whose fundamental dies before its
    /// 2nd harmonic, run through the real detector at the analyzer's 20 ms cadence.
    @Test func fadingLowEStaysOnE2() throws {
        let sampleRate = 48_000.0
        let e2 = Note("E2")!.frequency(a4: 440)
        let signal = SyntheticSignal.decayingPluck(frequency: e2, sampleRate: sampleRate, duration: 10)
        let detector = YINDetector(sampleRate: sampleRate)
        let window = detector.windowSize
        let hop = Int(sampleRate * 0.02)

        var smoother = PitchSmoother()
        var rawSawHarmonic = false
        var shownNotes = Set<String>()
        var end = window
        while end <= signal.count {
            let slice = Array(signal[(end - window)..<end])
            var rms: Float = 0
            vDSP_rmsqv(slice, 1, &rms, vDSP_Length(window))
            let estimate = rms >= PitchAnalyzer.defaultSilenceRMS ? detector.detect(slice) : nil
            if let f = estimate?.frequency, abs(Pitch.cents(f, from: 2 * e2)) < 50 { rawSawHarmonic = true }

            let output = smoother.update(PitchReading(estimate: estimate, rms: rms), at: Double(end) / sampleRate)
            if let f = frequency(output) { shownNotes.insert(Pitch.nearestNote(to: f, a4: 440).note.description) }
            end += hop
        }

        // The signal must actually trigger the problem, or this test proves nothing.
        #expect(rawSawHarmonic, "synthetic decay no longer makes the detector read the 2nd harmonic")
        #expect(shownNotes == ["E2"], "displayed \(shownNotes.sorted())")
    }
}

extension PitchSmootherTests {
    /// The real low-E sequence end to end: an attack dominated by the 2nd harmonic that settles into
    /// the sustain spectrum, through the detector at the analyzer's 20 ms cadence. Guitar mode must
    /// show the low E string, never D3 (where an E3 misreading snaps).
    @Test(arguments: ["E2", "D2"])
    func lowStringPluckShowsLowString(name: String) {
        let sampleRate = 48_000.0
        let f = Note(name)!.frequency(a4: 440)
        let detector = YINDetector(sampleRate: sampleRate)
        let window = detector.windowSize
        let attack = SyntheticSignal.lowEAttack, sustain = SyntheticSignal.lowESustain
        let n = Int(sampleRate * 4)
        let signal: [Float] = (0..<n).map { i in
            let t = Double(i) / sampleRate
            let blend = min(1, max(0, (t - 0.3) / 0.4))          // attack → sustain between 0.3 s and 0.7 s
            var s = 0.0
            for h in 0..<attack.count {
                let amp = attack[h] * (1 - blend) + sustain[h] * blend
                s += amp * sin(2 * .pi * f * Double(h + 1) * t + Double(h))
            }
            return Float(0.15 * exp(-t * 0.8) * s)
        }
        var smoother = PitchSmoother()
        var shown = Set<String>()
        var end = window
        while end <= n {
            let slice = Array(signal[(end - window)..<end])
            var rms: Float = 0
            vDSP_rmsqv(slice, 1, &rms, vDSP_Length(window))
            let estimate = rms >= PitchAnalyzer.defaultSilenceRMS ? detector.detect(slice) : nil
            if let out = frequency(smoother.update(PitchReading(estimate: estimate, rms: rms), at: Double(end) / sampleRate)) {
                let target = TunerMode.guitar.target(for: out, tuning: .standard, a4: 440)
                shown.insert(Pitch.nearestNote(to: out, a4: 440).note.description + "/string \(Tuning.stringCount - target.string!)")
            }
            end += Int(sampleRate * 0.02)
        }
        #expect(shown == ["\(name)/string 6"], "displayed \(shown.sorted())")
    }
}

@Suite struct TunerModeTests {
    @Test func guitarModeTargetsNearestString() {
        let a3 = Note("A3")!.frequency(a4: 440)
        let target = TunerMode.guitar.target(for: a3, tuning: .standard, a4: 440)
        // A3 is 200¢ from both G3 and B3; either is acceptable.
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

extension PitchSmootherTests {
    @Test func harmonicAfterHoldNeedsAnAttack() {
        var s = PitchSmoother()
        var t = 0.0
        steady(&s, 82.4, count: 10, level: 0.1, t: &t)
        steady(&s, nil, count: 100, level: 0.01, t: &t)          // hold runs out
        #expect(steady(&s, 164.8, count: 20, level: 0.01, t: &t) == PitchSmoother.Output.none)
        // A real pluck of the higher string is still accepted.
        _ = s.update(reading(164.8, level: 0.2), at: t)
        _ = s.update(reading(164.8, level: 0.2), at: t + dt)
        #expect(s.update(reading(164.8, level: 0.2), at: t + 2 * dt) == .pitch(164.8))
    }
}
