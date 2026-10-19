import Synchronization

/// Fixed-size ring buffer holding the most recent mono samples.
///
/// One producer (the real-time audio thread) writes; one consumer (the analysis queue) copies out
/// the newest window. `write` never allocates, locks, or blocks. The consumer validates each copy
/// seqlock-style and reports failure if the producer lapped the region it was reading.
public final class SampleRing: @unchecked Sendable {
    public let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    /// Total samples ever written (published). Only the producer stores to it.
    private let written = Atomic<Int>(0)
    /// Where the in-progress write will end. Set before touching storage, so the consumer can tell
    /// when a write that hasn't been published yet has overwritten what it copied.
    private let reserved = Atomic<Int>(0)

    /// Capacity is rounded up to a power of two.
    public init(minimumCapacity: Int) {
        precondition(minimumCapacity > 0)
        var size = 1
        while size < minimumCapacity { size <<= 1 }
        capacity = size
        mask = size - 1
        storage = .allocate(capacity: size)
        storage.initialize(repeating: 0, count: size)
    }

    deinit {
        storage.deallocate()
    }

    /// Total samples written since creation.
    public var totalWritten: Int { written.load(ordering: .acquiring) }

    /// Appends `count` samples read from `source` at `stride` (use the channel count to take the
    /// first channel of interleaved audio). Real-time safe. Producer only.
    public func write(_ source: UnsafePointer<Float>, count: Int, stride: Int = 1) {
        guard count > 0 else { return }
        let start = written.load(ordering: .relaxed)
        reserved.store(start + count, ordering: .relaxed)
        // Make the reservation visible before any of the sample stores below.
        atomicMemoryFence(ordering: .releasing)

        // If handed more than fits, only the newest `capacity` samples matter.
        let skip = max(0, count - capacity)
        let n = count - skip
        var position = (start + skip) & mask
        var src = source + skip * stride

        if stride == 1 {
            let first = min(n, capacity - position)
            (storage + position).update(from: src, count: first)
            if first < n { storage.update(from: src + first, count: n - first) }
        } else {
            for _ in 0..<n {
                storage[position] = src.pointee
                src += stride
                position = (position + 1) & mask
            }
        }
        written.store(start + count, ordering: .releasing)
    }

    /// Copies the newest `count` samples, oldest first, into `destination`. Consumer only.
    ///
    /// Returns false if fewer than `count` samples have been written, or if the producer
    /// overwrote part of the region during the copy (the copy is then torn and must be discarded).
    public func copyLatest(_ count: Int, into destination: UnsafeMutablePointer<Float>) -> Bool {
        precondition(count > 0 && count <= capacity)
        let end = written.load(ordering: .acquiring)
        guard end >= count else { return false }

        let start = end - count
        let position = start & mask
        let first = min(count, capacity - position)
        destination.update(from: storage + position, count: first)
        if first < count { (destination + first).update(from: storage, count: count - first) }

        // Order the copy before re-reading the reservation, then check that no write, finished or
        // still in progress, reached into the region we copied.
        atomicMemoryFence(ordering: .acquiring)
        return reserved.load(ordering: .relaxed) - start <= capacity
    }
}
