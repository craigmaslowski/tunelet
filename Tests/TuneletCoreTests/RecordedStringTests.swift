import AVFoundation
import Foundation
import Testing
@testable import TuneletCore

/// Real recordings of each string of three acoustic guitars (two steel-string, one nylon), in tune
/// according to each guitar's built-in tuner, captured through a MacBook's built-in mic (see
/// audio-samples/README.md).
///
/// These guard against the regressions synthetic signals missed: the low E's attack reading an
/// octave high (shown as the D string), and the high e's attack reading an octave low.
@Suite struct RecordedStringTests {
    struct Sample: Sendable, CustomTestStringConvertible {
        let guitar: String
        let name: String
        /// 0 = 6th string … 5 = 1st string.
        let string: Int
        var file: String { "\(guitar)-\(name)" }
        var testDescription: String { file }
    }

    /// File-name prefixes, one per guitar.
    static let guitars = ["martin-gpc-x1e", "hb-clc650-sm-ce", "cordoba-f7-nylon"]

    static let strings = ["E-6th-string", "A-5th-string", "D-4th-string", "G-3rd-string", "B-2nd-string", "E-1st-string"]

    static let samples = guitars.flatMap { guitar in
        strings.enumerated().map { Sample(guitar: guitar, name: $0.element, string: $0.offset) }
    }

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

    /// Guitar mode must show this string and no other, at any moment, current or held. Checked at
    /// the standard 60 Hz floor and at the extended floor that 8-string tunings and chromatic
    /// mode's low-notes switch use, where low resonances could otherwise be read as notes.
    @Test(arguments: samples, [YINDetector.defaultRange.lowerBound, Tuning.extendedFloor(a4: 440)])
    func showsOnlyItsOwnString(sample: Sample, floor: Double) throws {
        let (signal, sampleRate) = try Self.load(sample)
        let steps = Pipeline.run(signal, sampleRate: sampleRate, minimumFrequency: floor)
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
