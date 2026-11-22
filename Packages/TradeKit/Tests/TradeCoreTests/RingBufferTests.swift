import Testing
import TradeCore

private func requireSendable<T: Sendable>(_: T.Type) {}

struct RingBufferTests {
    @Test func startsEmpty() {
        let ring = RingBuffer<Int>(capacity: 3)

        #expect(ring.count == 0)
        #expect(ring.toArray() == [])
    }

    /// Up to the capacity nothing is dropped: the buffer fills first, and exactly at capacity all of it is there.
    @Test func keepsEverythingUntilItIsFull() {
        var ring = RingBuffer<Int>(capacity: 3)

        ring.append(1)
        #expect(ring.toArray() == [1])
        #expect(ring.count == 1)

        ring.append(2)
        #expect(ring.toArray() == [1, 2])
        #expect(ring.count == 2)

        ring.append(3)
        #expect(ring.toArray() == [1, 2, 3])
        #expect(ring.count == 3)
    }

    /// The brief's case: capacity 3 after five appends holds the last three, oldest first.
    @Test func capacityThreeAfterFiveAppendsKeepsTheLastThreeInOrder() {
        var ring = RingBuffer<Int>(capacity: 3)

        for value in 1...5 {
            ring.append(value)
        }

        #expect(ring.count == 3)
        #expect(ring.toArray() == [3, 4, 5])
    }

    /// Index 0 is the oldest element and `count - 1` the newest, also after the buffer has wrapped.
    @Test func subscriptZeroIsTheOldest() {
        var ring = RingBuffer<Int>(capacity: 3)
        ring.append(1)
        ring.append(2)
        #expect(ring[0] == 1)
        #expect(ring[1] == 2)

        for value in 3...5 {
            ring.append(value)
        }
        #expect(ring[0] == 3)
        #expect(ring[1] == 4)
        #expect(ring[2] == 5)
    }

    @Test func capacityOneKeepsOnlyTheLatest() {
        var ring = RingBuffer<String>(capacity: 1)
        #expect(ring.count == 0)

        ring.append("a")
        #expect(ring.toArray() == ["a"])
        #expect(ring[0] == "a")

        ring.append("b")
        ring.append("c")
        #expect(ring.count == 1)
        #expect(ring.toArray() == ["c"])
        #expect(ring[0] == "c")
    }

    /// Checked against a plain array at every step, through several full turns of the buffer: `toArray()`, `count`
    /// and every subscript equal the last `capacity` appended values, oldest first.
    @Test(arguments: [1, 2, 3, 4, 7, 16])
    func matchesTheLastCapacityElementsAtEveryStep(capacity: Int) {
        var ring = RingBuffer<Int>(capacity: capacity)
        var appended: [Int] = []

        for value in 1...50 {
            ring.append(value)
            appended.append(value)
            let expected = Array(appended.suffix(capacity))

            #expect(ring.count == expected.count, "after \(value)")
            #expect(ring.toArray() == expected, "after \(value)")
            #expect(expected.indices.allSatisfy { ring[$0] == expected[$0] }, "after \(value)")
        }
    }

    @Test func removeAllEmptiesTheBuffer() {
        var ring = RingBuffer<Int>(capacity: 3)
        ring.append(1)
        ring.append(2)

        ring.removeAll()

        #expect(ring.count == 0)
        #expect(ring.toArray() == [])
    }

    /// `removeAll` keeps the capacity, and forgets where the buffer had wrapped to: refilling past the capacity keeps
    /// the last three, in order, as on a new buffer.
    @Test func removeAllKeepsTheCapacityAndStartsOrderingAfresh() {
        var ring = RingBuffer<Int>(capacity: 3)
        for value in 1...5 {
            ring.append(value)
        }

        ring.removeAll()
        #expect(ring.count == 0)

        for value in 10...14 {
            ring.append(value)
        }
        #expect(ring.count == 3)
        #expect(ring.toArray() == [12, 13, 14])
        #expect(ring[0] == 12)
    }

    @Test func removeAllOnAnEmptyBufferIsHarmless() {
        var ring = RingBuffer<Int>(capacity: 2)

        ring.removeAll()
        ring.append(1)

        #expect(ring.toArray() == [1])
    }

    /// A capacity below 1 is clamped to 1 rather than crashing or making a buffer that cannot hold anything.
    @Test(arguments: [0, -1, -1000, Int.min])
    func aCapacityBelowOneIsClampedToOne(capacity: Int) {
        var ring = RingBuffer<Int>(capacity: capacity)

        ring.append(1)
        ring.append(2)

        #expect(ring.count == 1)
        #expect(ring.toArray() == [2])
    }

    /// The capacity is a limit, not an allocation: an enormous one costs nothing until elements arrive.
    @Test func aHugeCapacityDoesNotAllocateUpFront() {
        var ring = RingBuffer<Int>(capacity: .max)

        for value in 1...3 {
            ring.append(value)
        }

        #expect(ring.count == 3)
        #expect(ring.toArray() == [1, 2, 3])
        #expect(ring[2] == 3)
    }

    /// A buffer is a value: a copy has its own contents from then on.
    @Test func copiesAreIndependent() {
        var original = RingBuffer<Int>(capacity: 3)
        for value in 1...4 {
            original.append(value)
        }

        var copy = original
        copy.append(5)
        original.removeAll()

        #expect(original.toArray() == [])
        #expect(copy.toArray() == [3, 4, 5])
    }

    @Test func theBufferIsSendable() {
        requireSendable(RingBuffer<Int>.self)
    }

    #if os(macOS)
    // A trap cannot be caught, so these run the failing subscript in a child process and check that it exits badly
    // and says why. (Swift Testing offers exit tests on macOS but not on iOS, hence the guard.)

    /// An index outside `0..<count` is a programmer error, as it is for `Array`: a precondition whose message names
    /// the index and the valid range. Indexes inside the capacity but beyond `count` are out of range too.
    @Test(arguments: [-1, 1, 2, 3, Int.max, Int.min])
    func anOutOfRangeSubscriptIsAProgrammerError(index: Int) async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            [index = index as Int] in
            var ring = RingBuffer<Int>(capacity: 3)
            ring.append(7)
            _ = ring[index]
        }

        let message = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
        #expect(message.contains("out of range"))
        #expect(message.contains("\(index)"))
        #expect(message.contains("0..<1"))
    }

    @Test func subscriptingAnEmptyBufferIsAProgrammerError() async {
        await #expect(processExitsWith: .failure) {
            let ring = RingBuffer<Int>(capacity: 3)
            _ = ring[0]
        }
    }
    #endif
}
