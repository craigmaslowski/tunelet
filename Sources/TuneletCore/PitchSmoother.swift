/// Turns raw ~50/s pitch readings into a steady value for display.
///
/// - Median of the last few readings drops outliers from the pick attack.
/// - A jump of more than `jumpCents` (a different string or note) resets the history so the new
///   note shows immediately, but only once two consecutive readings agree on it. A lone outlier,
///   such as a single octave error, is ignored.
/// - When the pitch disappears, the last value is held for `holdDuration` so it can still be read
///   as the string decays.
public struct PitchSmoother {
    public enum Output: Equatable {
        /// A current, smoothed frequency in Hz.
        case pitch(Double)
        /// No pitch right now; this is the last smoothed frequency, still within the hold time.
        case held(Double)
        case none
    }

    public var medianCount: Int
    public var jumpCents: Double
    public var holdDuration: Double

    private var recent: [Double] = []
    private var pendingJump: Double?
    private var lastOutput: Double?
    private var lastPitchTime: Double?

    public init(medianCount: Int = 5, jumpCents: Double = 100, holdDuration: Double = 1.5) {
        self.medianCount = medianCount
        self.jumpCents = jumpCents
        self.holdDuration = holdDuration
        recent.reserveCapacity(medianCount)
    }

    /// Feeds one reading. `time` is any monotonic clock in seconds.
    public mutating func update(_ estimate: PitchEstimate?, at time: Double) -> Output {
        guard let frequency = estimate?.frequency else {
            if let lastOutput, let lastPitchTime, time - lastPitchTime <= holdDuration {
                return .held(lastOutput)
            }
            reset()
            return .none
        }
        lastPitchTime = time

        if let current = lastOutput, abs(Pitch.cents(frequency, from: current)) > jumpCents {
            if let pending = pendingJump, abs(Pitch.cents(frequency, from: pending)) <= jumpCents / 2 {
                // Two readings in a row agree on a new note: start over from them.
                recent = [pending]
                pendingJump = nil
            } else {
                // Possibly an outlier. Remember it, keep showing the current note.
                pendingJump = frequency
                return .pitch(current)
            }
        } else {
            pendingJump = nil
        }

        recent.append(frequency)
        if recent.count > medianCount { recent.removeFirst() }
        let median = Self.median(recent)
        lastOutput = median
        return .pitch(median)
    }

    public mutating func reset() {
        recent.removeAll(keepingCapacity: true)
        pendingJump = nil
        lastOutput = nil
        lastPitchTime = nil
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
