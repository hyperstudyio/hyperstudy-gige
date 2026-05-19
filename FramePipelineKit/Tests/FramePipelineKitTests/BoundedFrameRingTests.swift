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

    @Test func capacityOneDropsAndReplacesEveryPush() {
        let ring = BoundedFrameRing<Int>(capacity: 1)
        #expect(ring.push(10) == nil)         // first push: no drop
        #expect(ring.push(20) == 10)          // second push: drops 10, replaces with 20
        #expect(ring.push(30) == 20)          // third push: drops 20, replaces with 30
        #expect(ring.totalDropped == 2)
        #expect(ring.count == 1)
        #expect(ring.pop() == 30)
        #expect(ring.pop() == nil)
    }

    @Test func concurrentPushPopNeverExceedsCapacity() async {
        let capacity = 8
        let ring = BoundedFrameRing<Int>(capacity: capacity)
        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< 200 {
                group.addTask { ring.push(i) }
            }
            for _ in 0 ..< 200 {
                group.addTask { _ = ring.pop() }
            }
        }
        #expect(ring.count <= capacity)
    }
}
