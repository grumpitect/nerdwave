import Foundation

/// A shuffled play order that never ends: when a pass finishes it reshuffles,
/// avoiding the same track twice in a row across the pass boundary.
public struct PlayQueue<RNG: RandomNumberGenerator> {
    public private(set) var order: [URL]
    public private(set) var position = 0
    public private(set) var passes = 1
    private var rng: RNG

    public init(tracks: [URL], rng: RNG) {
        self.rng = rng
        order = tracks
        order.shuffle(using: &self.rng)
    }

    public var isEmpty: Bool { order.isEmpty }
    public var current: URL? { order.isEmpty ? nil : order[position] }

    /// Moves to the next track and returns it, reshuffling at the end of a pass.
    @discardableResult
    public mutating func advance() -> URL? {
        guard !order.isEmpty else { return nil }
        position += 1
        if position >= order.count {
            let last = order.last
            order.shuffle(using: &rng)
            if order.count > 1, order.first == last { order.swapAt(0, order.count - 1) }
            position = 0
            passes += 1
        }
        return current
    }

    /// Drops a track that turned out to be unplayable.
    public mutating func removeCurrent() {
        guard !order.isEmpty else { return }
        order.remove(at: position)
        if position >= order.count { position = 0 }
    }
}
