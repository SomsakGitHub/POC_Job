/// Which answers for the server's settings count when requests for them overlap.
///
/// A change asks the server to hold other settings and a read only asks what it holds. Two requests of one kind are
/// ordered by when they started: the answer of the newer one counts, whichever of them comes back first. A change is
/// never set aside because a read started after it. A read is set aside when a change overlapped it in time, that is,
/// when a change was on its way as the read started or one started before the read was answered: the server may have
/// answered the read before the change took effect, so its answer can be older than the change.
struct SettingsOrder {
    /// A read on its way: when it started, as far as `counts(_:)` needs to know.
    struct Read {
        /// How many reads had started when this one did, itself included.
        fileprivate let number: Int
        /// How many changes had started by then.
        fileprivate let changesStarted: Int
        /// Whether a change was on its way.
        fileprivate let overlapsAChange: Bool
    }

    /// A change on its way: when it started, as far as `counts(_:)` needs to know.
    struct Change {
        /// How many changes had started when this one did, itself included.
        fileprivate let number: Int
    }

    /// How many reads have started.
    private var readsStarted = 0
    /// How many changes have started.
    private var changesStarted = 0
    /// How many changes have started and not ended yet.
    private var changesOnTheirWay = 0

    /// Notes that a read starts.
    mutating func startRead() -> Read {
        readsStarted += 1
        return Read(number: readsStarted, changesStarted: changesStarted, overlapsAChange: changesOnTheirWay > 0)
    }

    /// Notes that a change starts.
    mutating func startChange() -> Change {
        changesStarted += 1
        changesOnTheirWay += 1
        return Change(number: changesStarted)
    }

    /// Notes that a change has ended, with an answer, with a failure or because it was cancelled.
    mutating func endChange() {
        changesOnTheirWay -= 1
    }

    /// Whether the answer of `read` counts: no newer read has started and no change overlapped it.
    func counts(_ read: Read) -> Bool {
        read.number == readsStarted && !read.overlapsAChange && read.changesStarted == changesStarted
    }

    /// Whether the answer of `change` counts: no newer change has started.
    func counts(_ change: Change) -> Bool {
        change.number == changesStarted
    }
}
