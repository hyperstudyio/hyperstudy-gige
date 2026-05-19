import Testing
@testable import FramePipelineKit

@Suite struct BoundedFrameRingTests {
    @Test func pushesWithinCapacityKeepFifoOrder() {
        let ring = BoundedFrameRing<Int>(capacity: 3)
        #expect(ring.push(1) == nil)
        #expect(ring.push(2) == nil)
        #expect(ring.push(3) == nil)
        #expect(ring.count == 3)
        #expect(ring.pop() == 1)
        #expect(ring.pop() == 2)
        #expect(ring.pop() == 3)
        #expect(ring.pop() == nil)
    }

    @Test func overflowDropsOldestAndReturnsIt() {
        let ring = BoundedFrameRing<Int>(capacity: 2)
        #expect(ring.push(1) == nil)
        #expect(ring.push(2) == nil)
        let dropped = ring.push(3) // capacity exceeded -> drop oldest (1)
        #expect(dropped == 1)
        #expect(ring.totalDropped == 1)
        #expect(ring.count == 2)
        #expect(ring.pop() == 2)
        #expect(ring.pop() == 3)
    }

    @Test func popOnEmptyReturnsNil() {
        let ring = BoundedFrameRing<Int>(capacity: 4)
        #expect(ring.pop() == nil)
    }
}
