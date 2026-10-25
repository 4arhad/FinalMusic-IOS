import Foundation

// Queue bookkeeping as pure functions, shared by PlayerViewModel and
// LastWaveCoreChecks: reordering, removal, and the advance decision that
// implements shuffle / repeat-all / radio-extension / stop. The player keeps
// all AVPlayer work; only the index arithmetic lives here, where the rules
// ("shuffle never re-picks the current track", "repeat restarts at 0", "a
// radio that runs out extends instead of stopping") are checkable without a
// running audio system.
public enum QueueOps {

    /// Same semantics as SwiftUI's Array.move but returning a new array (and
    /// usable without SwiftUI, where the pure core is compiled): the moved
    /// elements re-enter before whatever was originally at `destination`, so
    /// [1,2,3,4,5] moving offset 0 to offset 3 yields [2,3,1,4,5].
    public static func moved<T>(_ items: [T], fromOffsets source: IndexSet, toOffset destination: Int) -> [T] {
        let moved = source.map { items[$0] }            // IndexSet iterates ascending
        var out = removed(items, at: source)
        let insertAt = destination - source.filter { $0 < destination }.count
        out.insert(contentsOf: moved, at: Swift.max(0, Swift.min(insertAt, out.count)))
        return out
    }

    public static func removed<T>(_ items: [T], at offsets: IndexSet) -> [T] {
        var out = items
        for index in offsets.sorted(by: >) {           // removing from the back keeps earlier indices valid
            if out.indices.contains(index) { out.remove(at: index) }
        }
        return out
    }

    /// How many removed indices precede `index` — used to shift
    /// currentIndex after a queue removal.
    public static func removalShift(before index: Int, offsets: IndexSet) -> Int {
        offsets.filter { $0 < index }.count
    }

    public enum AdvanceAction: Equatable {
        case load(Int)
        case extendRadio
        case stop
    }

    /// The advance rule of the player, with the random pick injected so the
    /// shuffle branch is deterministic under test:
    ///   shuffle (count > 1): play the picked index, but never the current one
    ///                        — on a collision step to (current + 1) % count.
    ///   otherwise:           next index, else restart at 0 when repeat-all is
    ///                        on, else extend the radio, else stop.
    public static func advance(count: Int,
                               current: Int,
                               shuffle: Bool,
                               randomPick: Int,
                               repeatAll: Bool,
                               isRadio: Bool) -> AdvanceAction {
        if shuffle, count > 1 {
            return .load(randomPick == current ? (current + 1) % count : randomPick)
        }
        if current + 1 < count {
            return .load(current + 1)
        }
        if repeatAll, count > 0 {
            return .load(0)
        }
        if isRadio {
            return .extendRadio
        }
        return .stop
    }
}
