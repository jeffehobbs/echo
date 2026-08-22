import Foundation
import os.lock

// MARK: - Clock

/// Monotonic seconds, shared by the MIDI listener and the weaver so phrase
/// gaps and beat times are measured on the same ruler.
enum Clock {
    private static let scale: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000.0
    }()

    static func now() -> Double { Double(mach_absolute_time()) * scale }
}

// MARK: - Primes

/// Echo's whole sense of time is built on primes: every phrase recurs on a
/// prime number of beats, so no two phrases ever line up the same way twice
/// (their patterns only repeat after the product of their periods).
enum Primes {
    /// Recurrence periods, in beats. Slow enough for ambient spacing.
    static let periods = [5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89, 97, 101]

    /// Small primes used for stepping through fragments, transforms and
    /// arpeggio gates, so those choices also never fall into a cycle.
    static let small = [2, 3, 5, 7, 11, 13]

    /// A prime step that is coprime with `count`, so repeated stepping visits
    /// every element before returning to the start.
    static func step(for count: Int, seed: Int) -> Int {
        guard count > 1 else { return 1 }
        let candidates = small.filter { count % $0 != 0 }
        guard !candidates.isEmpty else { return 1 }
        return candidates[abs(seed) % candidates.count]
    }

    /// Pick the period whose position in the list matches how strongly a
    /// phrase is weighted: heavy phrases recur often, light ones rarely.
    /// `taken` keeps periods distinct so firings stay spread out.
    static func period(forWeight weight: Double, taken: Set<Int>) -> Int {
        let w = min(1, max(0, weight))
        let ideal = Int(round((1 - w) * Double(periods.count - 1)))
        for offset in 0..<periods.count {
            for candidate in [ideal + offset, ideal - offset] where candidate >= 0 && candidate < periods.count {
                let p = periods[candidate]
                if !taken.contains(p) { return p }
            }
        }
        return periods[ideal]
    }
}

// MARK: - Deterministic randomness

/// Small xorshift so phrase choices are reproducible and never touch the
/// system RNG from the audio path.
struct Rng {
    private var state: UInt32

    init(seed: UInt32) { state = seed == 0 ? 0x9E3779B9 : seed }

    mutating func next() -> UInt32 {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return state
    }

    mutating func unit() -> Double { Double(next() % 100_000) / 100_000.0 }

    mutating func int(_ range: Range<Int>) -> Int {
        guard range.count > 0 else { return range.lowerBound }
        return range.lowerBound + Int(next() % UInt32(range.count))
    }

    mutating func chance(_ p: Double) -> Bool { unit() < p }
}

// MARK: - Lock-guarded event queue

/// Fixed-capacity queue from the logic thread to the render thread. The render
/// side drains with a try-lock so it never blocks; the writer holds the lock
/// only long enough to copy a struct.
final class EventQueue<T> {
    private let capacity: Int
    private let storage: UnsafeMutablePointer<T>
    private var count = 0
    private let lock: UnsafeMutablePointer<os_unfair_lock_s>

    init(capacity: Int = 512) {
        self.capacity = capacity
        storage = UnsafeMutablePointer<T>.allocate(capacity: capacity)
        lock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock_s())
    }

    deinit {
        storage.deallocate()
        lock.deallocate()
    }

    func push(_ event: T) {
        os_unfair_lock_lock(lock)
        if count < capacity {
            storage[count] = event
            count += 1
        }
        os_unfair_lock_unlock(lock)
    }

    func drain(_ body: (T) -> Void) {
        guard os_unfair_lock_trylock(lock) else { return }
        for i in 0..<count { body(storage[i]) }
        count = 0
        os_unfair_lock_unlock(lock)
    }
}
