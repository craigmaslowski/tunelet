import Testing
@testable import TuneletCore

@Suite struct SampleRingTests {
    private func latest(_ ring: SampleRing, _ count: Int) -> [Float]? {
        var out = [Float](repeating: .nan, count: count)
        let ok = out.withUnsafeMutableBufferPointer { ring.copyLatest(count, into: $0.baseAddress!) }
        return ok ? out : nil
    }

    private func write(_ ring: SampleRing, _ samples: [Float], stride: Int = 1) {
        samples.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: samples.count / stride, stride: stride) }
    }

    @Test func roundsCapacityUpToPowerOfTwo() {
        #expect(SampleRing(minimumCapacity: 1000).capacity == 1024)
        #expect(SampleRing(minimumCapacity: 1024).capacity == 1024)
        #expect(SampleRing(minimumCapacity: 48_000).capacity == 65_536)
    }

    @Test func refusesUntilEnoughWritten() {
        let ring = SampleRing(minimumCapacity: 16)
        write(ring, [1, 2, 3])
        #expect(latest(ring, 4) == nil)
        #expect(latest(ring, 3) == [1, 2, 3])
    }

    @Test func returnsNewestSamplesAcrossWraparound() {
        let ring = SampleRing(minimumCapacity: 16)
        var expected: [Float] = []
        var next: Float = 0
        // Uneven chunk sizes so writes straddle the wrap point in different places.
        for chunk in [5, 7, 3, 11, 1, 9, 16, 2, 13] {
            let samples = (0..<chunk).map { _ in next += 1; return next }
            write(ring, samples)
            expected += samples
            for count in [1, 4, 10, 16] where count <= expected.count {
                #expect(latest(ring, count) == Array(expected.suffix(count)))
            }
        }
        #expect(ring.totalWritten == expected.count)
    }

    @Test func oversizedWriteKeepsNewest() {
        let ring = SampleRing(minimumCapacity: 8)
        let samples = (1...20).map(Float.init)
        write(ring, samples)
        #expect(ring.totalWritten == 20)
        #expect(latest(ring, 8) == Array(samples.suffix(8)))
    }

    @Test func stridedWriteTakesFirstChannel() {
        let ring = SampleRing(minimumCapacity: 8)
        // Interleaved stereo: left = 1,2,3,4  right = -1,-2,-3,-4
        write(ring, [1, -1, 2, -2, 3, -3, 4, -4], stride: 2)
        #expect(latest(ring, 4) == [1, 2, 3, 4])

        // And across the wrap point.
        write(ring, [5, -5, 6, -6, 7, -7, 8, -8, 9, -9, 10, -10], stride: 2)
        #expect(latest(ring, 8) == [3, 4, 5, 6, 7, 8, 9, 10])
    }

    /// Hammers the ring from a producer thread while the consumer copies. Every copy that reports
    /// success must be an intact run of consecutive values.
    @Test func concurrentCopiesAreNeverTorn() async {
        let ring = SampleRing(minimumCapacity: 256)
        let total = 2_000_000
        let producer = Task.detached {
            var chunk = [Float](repeating: 0, count: 64)
            var value: Float = 0
            var written = 0
            while written < total {
                for i in chunk.indices { value += 1; chunk[i] = value.truncatingRemainder(dividingBy: 1_000_000) }
                chunk.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 64) }
                written += 64
            }
        }

        var window = [Float](repeating: 0, count: 200)
        var accepted = 0
        while !producer.isCancelled, ring.totalWritten < total {
            let ok = window.withUnsafeMutableBufferPointer { ring.copyLatest(200, into: $0.baseAddress!) }
            guard ok else { continue }
            accepted += 1
            for i in 1..<window.count {
                let step = window[i] - window[i - 1]
                if step != 1 && !(window[i] == 0 && window[i - 1] == 999_999) {
                    Issue.record("torn copy at \(i): \(window[i - 1]) → \(window[i])")
                    break
                }
            }
        }
        await producer.value
        #expect(accepted > 0)
    }
}
