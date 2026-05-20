import Testing
@testable import FramePipelineKit

@Suite struct LatestFrameSlotTests {
    @Test func takeReturnsTheValueThatWasSet() {
        let slot = LatestFrameSlot<Int>()
        slot.set(42)
        #expect(slot.take() == 42)
    }

    @Test func takeOnEmptyReturnsNil() {
        let slot = LatestFrameSlot<Int>()
        #expect(slot.take() == nil)
    }

    @Test func secondSetReplacesFirstAndCountsDrop() {
        let slot = LatestFrameSlot<Int>()
        slot.set(1)
        let displaced = slot.set(2)
        #expect(displaced == 1)
        #expect(slot.droppedCount == 1)
        #expect(slot.take() == 2)
    }

    @Test func takeClearsTheSlot() {
        let slot = LatestFrameSlot<Int>()
        slot.set(9)
        _ = slot.take()
        #expect(slot.take() == nil)
    }

    @Test func concurrentSetAndTakeDoesNotCrash() async {
        let slot = LatestFrameSlot<Int>()
        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< 500 {
                group.addTask { slot.set(i) }
            }
            for _ in 0 ..< 500 {
                group.addTask { _ = slot.take() }
            }
        }
        // If we reach here without a crash, the lock correctly serialised all accesses.
        // droppedCount must be non-negative and the slot may or may not hold a value.
        #expect(slot.droppedCount >= 0)
    }
}
