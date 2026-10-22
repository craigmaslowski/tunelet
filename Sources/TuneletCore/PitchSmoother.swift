/// Turns raw ~50/s pitch readings into a steady value for display.
///
/// - **Median** of the last few readings settles jitter and drops outliers from the pick attack.
/// - **Note changes need evidence.** A real new note arrives with an attack (a jump in level).
///   As a string fades, its fundamental can sink below the noise before its 2nd or 3rd harmonic
///   does, and the detector then reports the harmonic. So:
///   - a new note starting from silence, or a jump just after an attack, is committed once
///     `startConfirmCount` readings agree, so a pluck whose first reading is an octave high
///     doesn't flash the wrong note;
///   - otherwise, once the note has settled (`settleWindow` after it was committed), a jump *up*
///     to a harmonic (×2…×6) is rejected: that's a harmonic outlasting the fundamental. While the
///     note is still settling, an octave correction in either direction is allowed, because the
///     detector can misjudge the octave of an attack both ways;
///   - any other jump, including *down* to a sub-harmonic, is accepted once it persists for
///     `confirmCount` readings. A jump down usually means the current note was itself a harmonic
///     (a low string's attack can read an octave high), so it must not need an attack. This
///     also lets a second string plucked over a ringing first one come through.
/// - **Tail cutoff:** once the level falls `tailRatio` below the note's peak, readings are no
///   longer trusted, including after the note has ended, until the next attack.
/// - **Hold:** when there's no trusted pitch, the last value stays for `holdDuration` (reported as
///   `.held` after a short grace period, so a single dropped reading doesn't flicker). After the
///   hold, the ended note is remembered until the next attack, so a harmonic that outlives the
///   hold still isn't shown as a new note.
public struct PitchSmoother {
    public enum Output: Equatable {
        /// A current, smoothed frequency in Hz.
        case pitch(Double)
        /// No trusted pitch right now; this is the last smoothed frequency, still within the hold time.
        case held(Double)
        case none
    }

    public var medianCount = 9
    /// Bigger jumps than this (in cents) count as a different note rather than tuning movement.
    public var jumpCents = 100.0
    public var holdDuration = 1.5
    /// Missing readings for less than this keep reporting `.pitch` rather than `.held`.
    public var dropoutGrace = 0.1
    /// A level rise of this ratio over the quietest of the previous `onsetLookback` readings is an attack (2 = +6 dB).
    public var onsetRatio: Float = 2
    public var onsetLookback = 3
    /// How long after an attack a note change is allowed.
    public var attackWindow = 0.15
    /// Readings below this fraction of the note's peak level are not trusted (0.0316 = -30 dB).
    public var tailRatio: Float = 0.0316
    public var confirmCount = 5
    public var startConfirmCount = 3
    /// How long after a note is committed it can still be corrected by an octave upward.
    public var settleWindow = 0.6
    /// How close (in cents) a frequency ratio must be to a whole number to count as harmonic.
    /// 50¢ means "rounds to the same note an octave (twelfth, …) away"; harmonics read near the
    /// noise floor drift by tens of cents.
    public var harmonicToleranceCents = 50.0

    private var recent: [Double] = []
    private var levels: [Float] = []
    private var lastAttack: Double?
    private var peak: Float = 0
    private var candidate: Double?
    private var candidateCount = 0
    private var lastOutput: Double?
    private var lastPitchTime: Double?
    private var noteStart: Double?
    /// The note that last ended without a new attack since.
    private var endedNote: Double?

    public init() {}

    /// Feeds one reading. `time` is any monotonic clock in seconds.
    public mutating func update(_ reading: PitchReading, at time: Double) -> Output {
        trackLevel(reading.rms, at: time)

        var frequency = reading.estimate?.frequency
        // The peak is kept until the next attack, so this also covers the fade after a note ends.
        if reading.rms < peak * tailRatio { frequency = nil }
        guard let frequency else { return noPitch(at: time) }

        if lastOutput == nil, let ended = endedNote, frequency > ended, isHarmonic(frequency, of: ended) {
            return .none
        }

        // How many agreeing readings a new note needs before it's shown (0: not a new note).
        var needed = 0
        if let current = lastOutput {
            if abs(Pitch.cents(frequency, from: current)) > jumpCents {
                let inAttack = lastAttack.map { time - $0 <= attackWindow } ?? false
                if inAttack {
                    needed = startConfirmCount
                } else if frequency > current, isHarmonic(frequency, of: current),
                          !(noteStart.map { time - $0 <= settleWindow } ?? false) {
                    // Most likely a harmonic outlasting the fundamental: not a new note.
                    return noPitch(at: time)
                } else {
                    needed = confirmCount
                }
            }
        } else {
            needed = startConfirmCount
        }

        if needed > 0 {
            if let c = candidate, abs(Pitch.cents(frequency, from: c)) <= jumpCents / 2 {
                candidateCount += 1
            } else {
                candidate = frequency
                candidateCount = 1
            }
            guard candidateCount >= needed else { return noPitch(at: time) }
            startNote()
            noteStart = time
        } else {
            candidate = nil
            candidateCount = 0
        }

        recent.append(frequency)
        if recent.count > medianCount { recent.removeFirst() }
        let median = Self.median(recent)
        lastOutput = median
        lastPitchTime = time
        return .pitch(median)
    }

    public mutating func reset() {
        recent.removeAll(keepingCapacity: true)
        levels.removeAll(keepingCapacity: true)
        lastAttack = nil
        peak = 0
        candidate = nil
        candidateCount = 0
        lastOutput = nil
        lastPitchTime = nil
        noteStart = nil
        endedNote = nil
    }

    private mutating func trackLevel(_ rms: Float, at time: Double) {
        if levels.count == onsetLookback, let quietest = levels.min(), rms >= onsetRatio * max(quietest, 1e-6) {
            lastAttack = time
            peak = rms
            endedNote = nil
        } else {
            peak = max(peak, rms)
        }
        levels.append(rms)
        if levels.count > onsetLookback { levels.removeFirst() }
    }

    private mutating func startNote() {
        recent.removeAll(keepingCapacity: true)
        candidate = nil
        candidateCount = 0
    }

    private mutating func noPitch(at time: Double) -> Output {
        guard let lastOutput, let lastPitchTime else { return .none }
        let silentFor = time - lastPitchTime
        if silentFor <= dropoutGrace { return .pitch(lastOutput) }
        if silentFor <= holdDuration { return .held(lastOutput) }
        // The note is over. Keep level history so the next attack is still recognised.
        endedNote = lastOutput
        recent.removeAll(keepingCapacity: true)
        candidate = nil
        candidateCount = 0
        self.lastOutput = nil
        self.lastPitchTime = nil
        return .none
    }

    private func isHarmonic(_ frequency: Double, of reference: Double) -> Bool {
        var ratio = frequency / reference
        if ratio < 1 { ratio = 1 / ratio }
        let whole = ratio.rounded()
        return (2...6).contains(whole) && abs(Pitch.cents(ratio, from: whole)) <= harmonicToleranceCents
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}

/// What the tuner measures against.
public enum TunerMode: String, Codable, CaseIterable, Sendable {
    /// Nearest string of the current tuning.
    case guitar
    /// Nearest equal-tempered note.
    case chromatic

    /// The note to tune towards, the offset from it in cents, and (guitar mode) which string.
    public func target(for frequency: Double, tuning: Tuning, a4: Double) -> (note: Note, cents: Double, string: Int?) {
        switch self {
        case .guitar:
            let nearest = tuning.nearestString(to: frequency, a4: a4)
            return (tuning.strings[nearest.index], nearest.cents, nearest.index)
        case .chromatic:
            let nearest = Pitch.nearestNote(to: frequency, a4: a4)
            return (nearest.note, nearest.cents, nil)
        }
    }
}
