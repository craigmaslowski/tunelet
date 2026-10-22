import AVFoundation
import Foundation
import Testing
@testable import TuneletCore

/// Real recordings of each string of an acoustic guitar, in tune according to the guitar's built-in
/// tuner, captured through a MacBook's built-in mic (see audio-samples/README.md).
///
/// These guard against the regressions synthetic signals missed: the low E's attack reading an
/// octave high (shown as the D string), and the high e's attack reading an octave low.
@Suite struct RecordedStringTests {
    struct Sample: Sendable, CustomTestStringConvertible {
        let file: String
        /// 0 = 6th string … 5 = 1st string.
        let string: Int
        var testDescription: String { file }
    }

    static let samples = [
        Sample(file: "E-6th-string", string: 0),
        Sample(file: "A-5th-string", string: 1),
        Sample(file: "D-4th-string", string: 2),
        Sample(file: "G-3rd-string", string: 3),
        Sample(file: "B-2nd-string", string: 4),
        Sample(file: "E-1st-string", string: 5),
    ]

    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // TuneletCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("audio-samples")

    static func load(_ sample: Sample) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: directory.appendingPathComponent("\(sample.file).m4a"))
        let format = file.processingFormat
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        return (Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))), format.sampleRate)
    }

    /// Guitar mode must show this string and no other, at any moment, current or held.
    @Test(arguments: samples)
    func showsOnlyItsOwnString(sample: Sample) throws {
        let (signal, sampleRate) = try Self.load(sample)
        let steps = Pipeline.run(signal, sampleRate: sampleRate)
        let shownStrings = steps.compactMap(\.shown).map {
            TunerMode.guitar.target(for: $0, tuning: .standard, a4: 440).string!
        }
        #expect(!shownStrings.isEmpty, "never showed a note")
        let wrong = Set(shownStrings).subtracting([sample.string]).map { Tuning.standard.strings[$0].description }
        #expect(wrong.isEmpty, "also showed \(wrong.sorted())")
    }

    /// Once the pluck has settled, the reading agrees with the guitar's tuner. The tolerance allows
    /// for that tuner's own accuracy and the ~1–1.5¢ stiff-string bias (see DESIGN.md); measured
    /// settled readings span about -4¢ (B) to +3¢ (low E).
    @Test(arguments: samples)
    func readsInTuneOnceSettled(sample: Sample) throws {
        let (signal, sampleRate) = try Self.load(sample)
        let current = Pipeline.run(signal, sampleRate: sampleRate).filter { !$0.isHeld }.compactMap(\.shown)
        // A hard pluck starts sharp and settles; judge the second half of the note.
        let settled = current.suffix(current.count / 2).map {
            TunerMode.guitar.target(for: $0, tuning: .standard, a4: 440).cents
        }.sorted()
        let median = try #require(settled.isEmpty ? nil : settled[settled.count / 2])
        #expect(abs(median) < 6, "settled reading \(median)¢")
    }
}
