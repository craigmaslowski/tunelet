import Accelerate
@testable import TuneletCore

/// Runs audio through the same path as the app: the newest analysis window every 20 ms (as
/// `PitchAnalyzer` does), the -50 dBFS silence gate, YIN, then the smoother.
enum Pipeline {
    struct Step {
        let time: Double
        /// The detector's raw answer, before smoothing.
        let estimate: PitchEstimate?
        let rms: Float
        let output: PitchSmoother.Output

        /// The displayed frequency, current or held.
        var shown: Double? {
            switch output {
            case .pitch(let f), .held(let f): f
            case .none: nil
            }
        }

        var isHeld: Bool {
            if case .held = output { true } else { false }
        }
    }

    static func run(_ signal: [Float], sampleRate: Double) -> [Step] {
        let detector = YINDetector(sampleRate: sampleRate)
        let window = detector.windowSize
        let hop = Int(sampleRate * 0.02)
        var smoother = PitchSmoother()
        var steps: [Step] = []
        signal.withUnsafeBufferPointer { all in
            var end = window
            while end <= all.count {
                let slice = UnsafeBufferPointer(rebasing: all[(end - window)..<end])
                var rms: Float = 0
                vDSP_rmsqv(slice.baseAddress!, 1, &rms, vDSP_Length(window))
                let estimate = rms >= PitchAnalyzer.defaultSilenceRMS ? detector.detect(slice) : nil
                let time = Double(end) / sampleRate
                let output = smoother.update(PitchReading(estimate: estimate, rms: rms), at: time)
                steps.append(Step(time: time, estimate: estimate, rms: rms, output: output))
                end += hop
            }
        }
        return steps
    }
}
