import Foundation
import Observation

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class Preferences {
    static let autoStopRange: ClosedRange<TimeInterval> = 30...600

    /// Stop listening after this long without a detected pitch.
    var autoStopSeconds: TimeInterval {
        didSet { defaults.set(autoStopSeconds, forKey: Keys.autoStopSeconds) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let autoStopSeconds = "autoStopSeconds"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.double(forKey: Keys.autoStopSeconds)
        autoStopSeconds = Self.autoStopRange.contains(stored) ? stored : 120
    }
}
