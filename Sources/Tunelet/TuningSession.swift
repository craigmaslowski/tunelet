import AVFoundation
import Observation
import TuneletCore

/// One tuning-mode session: owns the microphone while active, and stops itself after a
/// period without a detected pitch.
@MainActor
@Observable
final class TuningSession {
    enum State: Equatable {
        case idle
        case requestingPermission
        case permissionDenied
        case listening
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet { if (oldValue == .listening) != (state == .listening) { onLiveChange?(state == .listening) } }
    }
    /// The smoothed pitch to display while listening.
    private(set) var pitch: PitchSmoother.Output = .none
    /// The string whose reference tone is playing, if any.
    private(set) var referenceString: Int?

    /// Called when the microphone goes live or stops.
    @ObservationIgnored var onLiveChange: ((Bool) -> Void)?
    /// Called when the session stops itself after the idle timeout.
    @ObservationIgnored var onAutoStop: (() -> Void)?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let capture = AudioCapture()
    @ObservationIgnored private var lastPitchTime = Date()
    @ObservationIgnored private var idleCheck: Timer?
    @ObservationIgnored private var smoother = PitchSmoother()
    @ObservationIgnored private let tonePlayer = ReferenceTonePlayer()
    /// Readings before this time (system uptime) are ignored: the mic hears the reference tone.
    @ObservationIgnored private var ignoreReadingsUntil: TimeInterval = 0

    /// How long the mic is ignored after a reference tone ends, for the room's echo to die away.
    private static let toneEchoTime: TimeInterval = 0.3

    init(preferences: Preferences) {
        self.preferences = preferences
        tonePlayer.onFinish = { [weak self] in self?.referenceFinished() }
    }

    var isActive: Bool { state != .idle }

    func start() {
        guard state == .idle else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginCapture()
        case .notDetermined:
            state = .requestingPermission
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                // The popover may have been closed while the system prompt was up.
                guard state == .requestingPermission else { return }
                if granted { beginCapture() } else { state = .permissionDenied }
            }
        default:
            state = .permissionDenied
        }
    }

    /// Plays a string's note. The tuner ignores the microphone while it plays.
    func playReference(string index: Int) {
        guard state == .listening, preferences.referenceTones else { return }
        let tuning = preferences.selectedTuning
        guard tuning.strings.indices.contains(index) else { return }
        do {
            try tonePlayer.play(frequency: tuning.strings[index].frequency(a4: preferences.a4))
        } catch {
            return
        }
        referenceString = index
        ignoreReadingsUntil = .infinity
        smoother.reset()
        pitch = .none
    }

    func stop() {
        tonePlayer.stop()
        referenceString = nil
        idleCheck?.invalidate()
        idleCheck = nil
        capture.stop()
        smoother.reset()
        pitch = .none
        state = .idle
    }

    private func beginCapture() {
        capture.onReading = { [weak self] reading in self?.handle(reading) }
        capture.onFailure = { [weak self] error in
            self?.stop()
            self?.state = .failed(error.localizedDescription)
        }
        do {
            try capture.start()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        state = .listening
        lastPitchTime = Date()
        idleCheck = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
    }

    private func referenceFinished() {
        referenceString = nil
        ignoreReadingsUntil = ProcessInfo.processInfo.systemUptime + Self.toneEchoTime
        smoother.reset()
    }

    private func handle(_ reading: PitchReading) {
        let now = ProcessInfo.processInfo.systemUptime
        // While a reference tone plays (and its echo dies away), the mic is hearing the tone, not
        // the guitar: don't display it, and don't count it as activity for auto-stop.
        guard state == .listening, now >= ignoreReadingsUntil else { return }
        let output = smoother.update(reading, at: now)
        // Avoid invalidating the view when nothing changed (e.g. a long silence).
        if output != pitch { pitch = output }
        if reading.estimate != nil { lastPitchTime = Date() }
    }

    private func checkIdle() {
        guard state == .listening,
              Date().timeIntervalSince(lastPitchTime) >= preferences.autoStopSeconds else { return }
        stop()
        onAutoStop?()
    }
}
