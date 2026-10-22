import Foundation

/// A note in 12-tone equal temperament, identified by its MIDI number (A4 = 69, E2 = 40).
public struct Note: Hashable, Sendable, Codable, CustomStringConvertible {
    public let midi: Int

    public init(midi: Int) { self.midi = midi }

    /// Parses names like "E2", "F#3", "Bb1", "D♯4". Returns nil if `text` isn't a note name.
    public init?(_ text: String) {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard let letter = s.first?.uppercased(),
              let base = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][letter]
        else { return nil }

        var rest = s.dropFirst()
        var accidental = 0
        if let c = rest.first, "#♯".contains(c) { accidental = 1; rest = rest.dropFirst() }
        else if let c = rest.first, "b♭".contains(c) { accidental = -1; rest = rest.dropFirst() }

        guard !rest.isEmpty, let octave = Int(rest) else { return nil }
        midi = (octave + 1) * 12 + base + accidental
    }

    private static let sharpNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    private static let flatNames = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]

    /// Pitch class name, e.g. "F♯" or "G♭".
    public func name(_ accidentals: Accidentals) -> String {
        let names = accidentals == .sharps ? Self.sharpNames : Self.flatNames
        return names[((midi % 12) + 12) % 12]
    }

    /// Scientific pitch notation octave (middle C = C4).
    public var octave: Int { Int((Double(midi) / 12).rounded(.down)) - 1 }

    /// Name with octave, e.g. "F♯3" or "G♭3".
    public func label(_ accidentals: Accidentals) -> String { "\(name(accidentals))\(octave)" }

    public var description: String { label(.sharps) }

    public func frequency(a4: Double) -> Double {
        a4 * pow(2, Double(midi - 69) / 12)
    }
}

/// How black-key notes are spelled.
public enum Accidentals: String, Hashable, Sendable, Codable, CaseIterable {
    case sharps, flats
}

public enum Pitch {
    /// Signed distance from `reference` to `frequency` in cents. Positive means sharp.
    public static func cents(_ frequency: Double, from reference: Double) -> Double {
        1200 * log2(frequency / reference)
    }

    /// The nearest equal-tempered note to `frequency` and the offset from it in cents (-50...50).
    public static func nearestNote(to frequency: Double, a4: Double) -> (note: Note, cents: Double) {
        let midi = Int((69 + 12 * log2(frequency / a4)).rounded())
        let note = Note(midi: midi)
        return (note, cents(frequency, from: note.frequency(a4: a4)))
    }
}

/// A named tuning of 4 to 8 strings, ordered from the bass-side string (highest number) to the
/// treble-side string (string 1). The bass-side string is usually, but not always, the lowest
/// note: a ukulele's re-entrant G4 sits on the 4th string.
public struct Tuning: Hashable, Sendable, Codable, Identifiable {
    /// 4 covers ukuleles; 8 covers 8-string guitars.
    public static let stringCountRange = 4...8
    /// The lowest note a string can be tuned to: an 8-string guitar's low F♯1.
    public static let lowestNote = Note(midi: 30)
    /// Semitones of headroom below a tuning's lowest string, so a slack or tuned-down string is
    /// still detected. Three keeps drop D (D2) at the standard 60 Hz floor.
    static let floorHeadroom = 3.0

    public var id: UUID
    public var name: String
    public var strings: [Note]
    /// Spelling for this tuning's notes; nil follows the global preference.
    public var accidentals: Accidentals?

    public init(id: UUID = UUID(), name: String, strings: [Note], accidentals: Accidentals? = nil) {
        precondition(Self.stringCountRange.contains(strings.count),
                     "a tuning needs \(Self.stringCountRange.lowerBound) to \(Self.stringCountRange.upperBound) strings")
        self.id = id
        self.name = name
        self.strings = strings
        self.accidentals = accidentals
    }

    /// The lowest frequency the detector should listen for with this tuning: `floorHeadroom`
    /// semitones below its lowest string, but never above the standard 60 Hz floor. Tunings
    /// within normal guitar range keep exactly the standard floor.
    public func detectionFloor(a4: Double) -> Double {
        let lowest = strings.map { $0.frequency(a4: a4) }.min() ?? YINDetector.defaultRange.lowerBound
        return min(YINDetector.defaultRange.lowerBound, lowest * pow(2, -Self.floorHeadroom / 12))
    }

    /// The lowest floor any tuning can need: `floorHeadroom` below `lowestNote` (about 39 Hz, D♯1).
    public static func extendedFloor(a4: Double) -> Double {
        lowestNote.frequency(a4: a4) * pow(2, -floorHeadroom / 12)
    }

    /// One more string on the bass side, a fourth below the current bass-side string (as a 7th
    /// string adds a low B below E), but not below `lowestNote`. Nil at the maximum count.
    public func addingBassString() -> Tuning? {
        guard strings.count < Self.stringCountRange.upperBound, let bass = strings.first else { return nil }
        var tuning = self
        tuning.strings.insert(Note(midi: max(bass.midi - 5, Self.lowestNote.midi)), at: 0)
        return tuning
    }

    /// The bass-side string removed. Nil at the minimum count.
    public func removingBassString() -> Tuning? {
        guard strings.count > Self.stringCountRange.lowerBound else { return nil }
        var tuning = self
        tuning.strings.removeFirst()
        return tuning
    }

    /// The spelling to display: this tuning's override, or `global` if it has none.
    public func accidentals(default global: Accidentals) -> Accidentals {
        accidentals ?? global
    }

    public static let standard = Tuning(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Standard",
        strings: ["E2", "A2", "D3", "G3", "B3", "E4"].map { Note($0)! }
    )

    /// Guitar mode: the string whose target is closest to `frequency` and the offset from it in cents.
    public func nearestString(to frequency: Double, a4: Double) -> (index: Int, cents: Double) {
        let offsets = strings.map { Pitch.cents(frequency, from: $0.frequency(a4: a4)) }
        let index = offsets.indices.min { abs(offsets[$0]) < abs(offsets[$1]) }!
        return (index, offsets[index])
    }
}
