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

    private static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    /// Pitch class name using sharps, e.g. "F♯".
    public var name: String { Self.names[((midi % 12) + 12) % 12] }

    /// Scientific pitch notation octave (middle C = C4).
    public var octave: Int { Int((Double(midi) / 12).rounded(.down)) - 1 }

    public var description: String { "\(name)\(octave)" }

    public func frequency(a4: Double) -> Double {
        a4 * pow(2, Double(midi - 69) / 12)
    }
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

/// A named 6-string tuning, strings ordered from 6th (lowest) to 1st (highest).
public struct Tuning: Hashable, Sendable, Codable, Identifiable {
    public static let stringCount = 6

    public var id: UUID
    public var name: String
    public var strings: [Note]

    public init(id: UUID = UUID(), name: String, strings: [Note]) {
        precondition(strings.count == Self.stringCount, "a tuning needs exactly \(Self.stringCount) strings")
        self.id = id
        self.name = name
        self.strings = strings
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
