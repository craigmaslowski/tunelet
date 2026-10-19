import Foundation
import Testing
@testable import TuneletCore

@Suite struct NoteTests {
    @Test(arguments: [
        ("A4", 69), ("E2", 40), ("D2", 38), ("C4", 60), ("B3", 59), ("E4", 64),
        ("F#3", 54), ("F♯3", 54), ("Bb1", 34), ("B♭1", 34), ("Cb4", 59), ("B#3", 60), ("e2", 40),
        (" G3 ", 55), ("C-1", 0),
    ])
    func parses(text: String, midi: Int) {
        #expect(Note(text)?.midi == midi)
    }

    @Test(arguments: ["", "H2", "E", "#2", "E2x", "Ebb2", "2E"])
    func rejectsInvalid(text: String) {
        #expect(Note(text) == nil)
    }

    @Test(arguments: Accidentals.allCases)
    func roundTripsThroughLabel(accidentals: Accidentals) {
        for midi in 0...127 {
            let note = Note(midi: midi)
            #expect(Note(note.label(accidentals)) == note, "\(note.label(accidentals))")
        }
    }

    @Test func spellsBlackKeysPerPreference() {
        let all = (60...71).map { Note(midi: $0) }
        #expect(all.map { $0.name(.sharps) } == ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"])
        #expect(all.map { $0.name(.flats) } == ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"])
        #expect(Note("D#2")!.label(.flats) == "E♭2")
        #expect(Note("Eb2")!.label(.sharps) == "D♯2")
        #expect(Note("Eb2")!.description == "D♯2")
    }

    @Test func frequencies() {
        #expect(abs(Note("A4")!.frequency(a4: 440) - 440) < 1e-9)
        #expect(abs(Note("E2")!.frequency(a4: 440) - 82.4069) < 1e-3)
        #expect(abs(Note("D2")!.frequency(a4: 440) - 73.4162) < 1e-3)
        #expect(abs(Note("A4")!.frequency(a4: 442) - 442) < 1e-9)
        #expect(abs(Note("A3")!.frequency(a4: 442) - 221) < 1e-9)
    }
}

@Suite struct PitchTests {
    @Test func cents() {
        #expect(abs(Pitch.cents(880, from: 440) - 1200) < 1e-9)
        #expect(abs(Pitch.cents(440 * pow(2, 1.0 / 12), from: 440) - 100) < 1e-9)
        #expect(Pitch.cents(439, from: 440) < 0)
    }

    @Test func nearestNoteChromatic() {
        let sharpA = Pitch.nearestNote(to: 440 * pow(2, 12.0 / 1200), a4: 440)
        #expect(sharpA.note == Note("A4")!)
        #expect(abs(sharpA.cents - 12) < 1e-9)

        let flatBb = Pitch.nearestNote(to: Note("A#4")!.frequency(a4: 440) * pow(2, -49.0 / 1200), a4: 440)
        #expect(flatBb.note == Note("A#4")!)
        #expect(abs(flatBb.cents + 49) < 1e-9)
    }

    @Test func nearestNoteRespectsCalibration() {
        // 440 Hz is about 7.85¢ flat of A4 when calibrated to 442.
        let result = Pitch.nearestNote(to: 440, a4: 442)
        #expect(result.note == Note("A4")!)
        #expect(abs(result.cents - Pitch.cents(440, from: 442)) < 1e-9)
        #expect(result.cents < -7.8 && result.cents > -7.9)
    }
}

@Suite struct TuningTests {
    @Test func standardTuning() {
        #expect(Tuning.standard.strings.map(\.description) == ["E2", "A2", "D3", "G3", "B3", "E4"])
    }

    @Test func snapsToNearestString() {
        let t = Tuning.standard
        for (index, note) in t.strings.enumerated() {
            let slightlySharp = note.frequency(a4: 440) * pow(2, 8.0 / 1200)
            let result = t.nearestString(to: slightlySharp, a4: 440)
            #expect(result.index == index)
            #expect(abs(result.cents - 8) < 1e-9)
        }
    }

    @Test func badlyDetunedStringSnapsToNeighbour() {
        // Low E tuned down 4 semitones to C2 is closer to... still E2 (no lower string), 400¢ flat.
        let c2 = Note("C2")!.frequency(a4: 440)
        let low = Tuning.standard.nearestString(to: c2, a4: 440)
        #expect(low.index == 0)
        #expect(abs(low.cents + 400) < 1e-9)

        // A string 3 semitones sharp (C3) is nearer D3 than A2: the documented reason for chromatic mode.
        let c3 = Note("C3")!.frequency(a4: 440)
        #expect(Tuning.standard.nearestString(to: c3, a4: 440).index == 2)
    }

    @Test func accidentalsOverrideFallsBackToGlobal() {
        var tuning = Tuning(name: "Mine", strings: ["D2", "A2", "D3", "F#3", "A3", "D4"].map { Note($0)! })
        #expect(tuning.accidentals == nil)
        #expect(tuning.accidentals(default: .sharps) == .sharps)
        #expect(tuning.accidentals(default: .flats) == .flats)

        tuning.accidentals = .flats
        #expect(tuning.accidentals(default: .sharps) == .flats)
        #expect(tuning.strings[3].label(tuning.accidentals(default: .sharps)) == "G♭3")
    }

    @Test(arguments: [nil, Accidentals.sharps, Accidentals.flats])
    func roundTripsThroughJSON(accidentals: Accidentals?) throws {
        let custom = Tuning(name: "Mine", strings: ["D2", "A2", "D3", "F#3", "A3", "D4"].map { Note($0)! },
                            accidentals: accidentals)
        let decoded = try JSONDecoder().decode(Tuning.self, from: JSONEncoder().encode(custom))
        #expect(decoded == custom)
    }
}
