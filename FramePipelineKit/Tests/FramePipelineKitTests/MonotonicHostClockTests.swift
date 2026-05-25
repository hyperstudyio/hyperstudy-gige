import Foundation
import Testing
@testable import FramePipelineKit

@Suite struct MonotonicHostClockTests {

    @Test func increasingInputPassesThrough() {
        let clock = MonotonicHostClock()
        #expect(clock.next(now: 100) == 100)
        #expect(clock.next(now: 200) == 200)
        #expect(clock.next(now: 300) == 300)
        #expect(clock.nudgeCount == 0)
    }

    @Test func equalInputBumpsByOne() {
        // The lived bug: two threads sample CLOCK_UPTIME_RAW in the same ns.
        // Without the guard, stream.send sees identical PTS and the consumer
        // freezes.
        let clock = MonotonicHostClock()
        #expect(clock.next(now: 100) == 100)
        #expect(clock.next(now: 100) == 101)
        #expect(clock.nudgeCount == 1)
    }

    @Test func backwardsInputBumpsForward() {
        let clock = MonotonicHostClock()
        _ = clock.next(now: 1000)
        #expect(clock.next(now: 500) == 1001,
                "going backwards must produce last + 1, not the raw input")
        #expect(clock.nudgeCount == 1)
    }

    @Test func runOfReorderedInputsStaysMonotonic() {
        let clock = MonotonicHostClock()
        let inputs: [UInt64] = [100, 200, 150, 250, 250, 240, 260]
        let outputs = inputs.map { clock.next(now: $0) }
        // Each output strictly greater than the previous.
        for i in 1..<outputs.count {
            #expect(outputs[i] > outputs[i - 1],
                    "output \(i)=\(outputs[i]) must be > prior \(outputs[i-1])")
        }
    }

    @Test func resetClearsState() {
        let clock = MonotonicHostClock()
        _ = clock.next(now: 1_000_000)
        _ = clock.next(now: 1_000_000)  // nudge
        #expect(clock.nudgeCount == 1)
        clock.reset()
        #expect(clock.next(now: 5) == 5,
                "after reset, a small input should not be bumped against a stale prior")
        #expect(clock.nudgeCount == 0)
    }

    @Test func concurrentCallersNeverProduceDuplicates() {
        // The bug E2/E3 unit-test: real-frame and watchdog paths race.
        let clock = MonotonicHostClock()
        let iterations = 5_000
        let producers = 4
        let lock = NSLock()
        var collected: [UInt64] = []
        collected.reserveCapacity(iterations * producers)

        DispatchQueue.concurrentPerform(iterations: producers) { _ in
            for _ in 0..<iterations {
                let n = clock.next(now: UInt64(mach_absolute_time()))
                lock.lock()
                collected.append(n)
                lock.unlock()
            }
        }

        let sorted = collected.sorted()
        let unique = Set(collected)
        #expect(unique.count == collected.count,
                "values must be unique across all producers — duplicates would freeze CMIO consumers")
        #expect(sorted.first! < sorted.last!,
                "sequence must span a range")
    }
}
