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
}
