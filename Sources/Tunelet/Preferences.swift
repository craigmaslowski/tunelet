import Foundation
import Observation
import TuneletCore

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class Preferences {
    static let a4Range: ClosedRange<Double> = 415...466
    static let autoStopRange: ClosedRange<TimeInterval> = 30...600
    static let inTuneRange: ClosedRange<Double> = 1...10

    var mode: TunerMode {
        didSet { defaults.set(mode.rawValue, forKey: Keys.mode) }
    }

    /// Reference pitch for A4 in Hz.
    var a4: Double {
        didSet { defaults.set(a4, forKey: Keys.a4) }
    }

    /// Global note spelling; a tuning may override it.
    var accidentals: Accidentals {
        didSet { defaults.set(accidentals.rawValue, forKey: Keys.accidentals) }
    }

    /// Never empty.
    var tunings: [Tuning] {
        didSet {
            if tunings.isEmpty { tunings = [.standard] }
            if let data = try? JSONEncoder().encode(tunings) { defaults.set(data, forKey: Keys.tunings) }
            if !tunings.contains(where: { $0.id == selectedTuningID }) { selectedTuningID = tunings[0].id }
        }
    }

    var selectedTuningID: UUID {
        didSet { defaults.set(selectedTuningID.uuidString, forKey: Keys.selectedTuning) }
    }

    /// Offsets within ± this many cents count as in tune.
    var inTuneCents: Double {
        didSet { defaults.set(inTuneCents, forKey: Keys.inTuneCents) }
    }

    /// Chromatic mode listens down to `Tuning.extendedFloor` instead of 60 Hz.
    var chromaticLowNotes: Bool {
        didSet { defaults.set(chromaticLowNotes, forKey: Keys.chromaticLowNotes) }
    }

    /// Clicking a string in the tuner plays its note.
    var referenceTones: Bool {
        didSet { defaults.set(referenceTones, forKey: Keys.referenceTones) }
    }

    /// Stop listening after this long without a detected pitch.
    var autoStopSeconds: TimeInterval {
        didSet { defaults.set(autoStopSeconds, forKey: Keys.autoStopSeconds) }
    }

    var selectedTuning: Tuning {
        tunings.first { $0.id == selectedTuningID } ?? tunings[0]
    }

    /// Spelling for the selected tuning, used in both modes so names don't change on switching.
    var effectiveAccidentals: Accidentals {
        selectedTuning.accidentals(default: accidentals)
    }

    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let mode = "mode"
        static let a4 = "a4"
        static let accidentals = "accidentals"
        static let tunings = "tunings"
        static let selectedTuning = "selectedTuning"
        static let autoStopSeconds = "autoStopSeconds"
        static let inTuneCents = "inTuneCents"
        static let referenceTones = "referenceTones"
        static let chromaticLowNotes = "chromaticLowNotes"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        mode = defaults.string(forKey: Keys.mode).flatMap(TunerMode.init(rawValue:)) ?? .guitar

        let storedA4 = defaults.double(forKey: Keys.a4)
        a4 = Self.a4Range.contains(storedA4) ? storedA4 : 440

        accidentals = defaults.string(forKey: Keys.accidentals).flatMap(Accidentals.init(rawValue:)) ?? .sharps

        let storedTunings = (defaults.data(forKey: Keys.tunings)
            .flatMap { try? JSONDecoder().decode([Tuning].self, from: $0) } ?? [])
            .filter { Tuning.stringCountRange.contains($0.strings.count) }
        let loadedTunings = storedTunings.isEmpty ? [Tuning.standard] : storedTunings
        tunings = loadedTunings

        let storedID = defaults.string(forKey: Keys.selectedTuning).flatMap(UUID.init(uuidString:))
        selectedTuningID = loadedTunings.first { $0.id == storedID }?.id ?? loadedTunings[0].id

        let storedInTune = defaults.double(forKey: Keys.inTuneCents)
        inTuneCents = Self.inTuneRange.contains(storedInTune) ? storedInTune : 2

        referenceTones = defaults.object(forKey: Keys.referenceTones) as? Bool ?? true
        chromaticLowNotes = defaults.bool(forKey: Keys.chromaticLowNotes)

        let storedTimeout = defaults.double(forKey: Keys.autoStopSeconds)
        autoStopSeconds = Self.autoStopRange.contains(storedTimeout) ? storedTimeout : 120
    }
}
