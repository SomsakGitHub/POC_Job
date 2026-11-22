/// A buffer that keeps the newest `capacity` elements: once it is full, each append drops the oldest.
///
/// A value type, so a copy has its own contents. The capacity is a limit, not an allocation: nothing is reserved up
/// front, so an enormous capacity costs nothing until elements arrive.
public struct RingBuffer<Element: Sendable>: Sendable {
    private let capacity: Int
    private var storage: [Element] = []
    /// Where in `storage` the oldest element is: 0 until the buffer is full and starts overwriting.
    private var oldest = 0

    /// A capacity below 1 is clamped to 1, so the buffer can always hold the newest element and never crashes.
    public init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    public var count: Int {
        storage.count
    }

    /// Adds `element` as the newest; when the buffer is full, the oldest element is dropped to make room.
    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[oldest] = element
            oldest = (oldest + 1) % capacity
        }
    }

    /// The element at `i`, where 0 is the oldest and `count - 1` the newest. An index outside `0..<count` is a
    /// programmer error, as it is for `Array`: a precondition fails, naming the index and the valid range.
    public subscript(i: Int) -> Element {
        precondition(i >= 0 && i < storage.count, "RingBuffer index \(i) is out of range 0..<\(storage.count)")
        return storage[(oldest + i) % storage.count]
    }

    /// The elements, oldest first.
    public func toArray() -> [Element] {
        Array(storage[oldest...]) + storage[..<oldest]
    }

    /// Empties the buffer. The capacity stays the same.
    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        oldest = 0
    }
}
