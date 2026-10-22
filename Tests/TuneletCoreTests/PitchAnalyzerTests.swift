import Foundation
import Synchronization
import Testing
@testable import TuneletCore

@Suite struct PitchAnalyzerTests {
    static let sampleRate = 48_000.0

    private func makeAnalyzer() -> (SampleRing, PitchAnalyzer) {
        let ring = SampleRing(minimumCapacity: 48_000)
        return (ring, PitchAnalyzer(ring: ring, sampleRate: Self.sampleRate))
    }

    private func feed(_ ring: SampleRing, _ samples: [Float], chunk: Int = 256) {
        samples.withUnsafeBufferPointer { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = min(chunk, buffer.count - offset)
                ring.write(buffer.baseAddress! + offset, count: n)
                offset += n
            }
        }
    }

    @Test func waitsForFullWindow() {
        let (ring, analyzer) = makeAnalyzer()
        feed(ring, SyntheticSignal.pluck(frequency: 110, sampleRate: Self.sampleRate, count: analyzer.detector.windowSize - 1))
        #expect(analyzer.analyze() == nil)
    }

    @Test func detectsPitchFromRing() throws {
        let (ring, analyzer) = makeAnalyzer()
        let e2 = Note("E2")!.frequency(a4: 440)
        feed(ring, SyntheticSignal.pluck(frequency: e2, sampleRate: Self.sampleRate, count: 2 * analyzer.detector.windowSize))
        let reading = try #require(analyzer.analyze())
        let estimate = try #require(reading.estimate)
        #expect(abs(Pitch.cents(estimate.frequency, from: e2)) < 0.25)
        #expect(reading.levelDBFS > -40)
    }

    @Test func skipsWhenNoNewAudio() {
        let (ring, analyzer) = makeAnalyzer()
        feed(ring, SyntheticSignal.pluck(frequency: 110, sampleRate: Self.sampleRate, count: analyzer.detector.windowSize))
        #expect(analyzer.analyze() != nil)
        #expect(analyzer.analyze() == nil)
        feed(ring, SyntheticSignal.pluck(frequency: 110, sampleRate: Self.sampleRate, count: 256))
        #expect(analyzer.analyze() != nil)
    }

    @Test func floorCanBeLoweredWhileInUse() throws {
        let (ring, analyzer) = makeAnalyzer()
        let fSharp1 = Note("F#1")!.frequency(a4: 440)
        let signal = SyntheticSignal.pluck(frequency: fSharp1, sampleRate: Self.sampleRate, count: 2 * analyzer.detector.windowSize)
        feed(ring, signal)
        // At the standard 60 Hz floor, F♯1 (46 Hz) can't be read as itself.
        let before = try #require(analyzer.analyze())
        #expect(before.estimate.map { abs(Pitch.cents($0.frequency, from: fSharp1)) > 50 } ?? true)

        analyzer.setMinimumFrequency(Tuning.extendedFloor(a4: 440))
        let after = try #require(analyzer.analyze())          // re-analyses the same audio
        let estimate = try #require(after.estimate)
        #expect(abs(Pitch.cents(estimate.frequency, from: fSharp1)) < 0.5)
    }

    @Test func quietSignalIsSilence() throws {
        let (ring, analyzer) = makeAnalyzer()
        // A clean tone at -60 dBFS: periodic, but below the silence gate.
        let tone = SyntheticSignal.pluck(frequency: 110, sampleRate: Self.sampleRate, count: analyzer.detector.windowSize,
                                         harmonics: [1], noise: 0).map { $0 * 0.004 }
        feed(ring, tone)
        let reading = try #require(analyzer.analyze())
        #expect(reading.estimate == nil)
        #expect(reading.levelDBFS < -50)
    }

    @Test func timerDeliversAboutFiftyReadingsPerSecond() async throws {
        let (ring, analyzer) = makeAnalyzer()
        let count = Atomic<Int>(0)

        // Simulate the audio thread: 5 ms buffers of a steady A2 in real time.
        let producer = Task.detached {
            let block = SyntheticSignal.pluck(frequency: 110, sampleRate: 48_000, count: 240, harmonics: [1], noise: 0)
            let clock = ContinuousClock()
            var next = clock.now
            while !Task.isCancelled {
                block.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 240) }
                next += .milliseconds(5)
                try? await clock.sleep(until: next)
            }
        }

        analyzer.start { _ in count.add(1, ordering: .relaxed) }
        try await Task.sleep(for: .seconds(1))
        analyzer.stop()
        producer.cancel()

        // Nominally 50, minus the first ~85 ms while the window fills. Loose bounds: CI-style timing noise.
        let readings = count.load(ordering: .relaxed)
        #expect((30...60).contains(readings), "got \(readings) readings in 1 s")
    }
}
