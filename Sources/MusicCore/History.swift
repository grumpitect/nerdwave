import Foundation

/// One played track and the playlist it was played from.
public struct HistoryEntry: Codable, Equatable {
    public let path: String
    public let playlist: String
    public init(path: String, playlist: String) { self.path = path; self.playlist = playlist }
    public var url: URL { URL(fileURLWithPath: path) }
}

/// The last `capacity` played tracks with a cursor for back/forward, like browser history:
/// going back and then playing something new drops the "forward" part.
public struct TrackHistory: Codable, Equatable {
    public let capacity: Int
    public private(set) var entries: [HistoryEntry] = []
    /// Index of the track playing now (-1 when empty).
    public private(set) var cursor = -1

    public init(capacity: Int = 1000) { self.capacity = capacity }

    public var canGoBack: Bool { cursor > 0 }
    public var canGoForward: Bool { cursor >= 0 && cursor < entries.count - 1 }
    public var current: HistoryEntry? { entries.indices.contains(cursor) ? entries[cursor] : nil }

    public mutating func record(_ entry: HistoryEntry) {
        if canGoForward { entries.removeSubrange((cursor + 1)...) }
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        cursor = entries.count - 1
    }

    public mutating func back() -> HistoryEntry? {
        guard canGoBack else { return nil }
        cursor -= 1
        return entries[cursor]
    }

    public mutating func forward() -> HistoryEntry? {
        guard canGoForward else { return nil }
        cursor += 1
        return entries[cursor]
    }

    /// Puts the cursor back (used when back/forward finds nothing playable, so history is never lost
    /// just because a drive is unplugged or the audio device is busy).
    public mutating func moveCursor(to index: Int) {
        cursor = entries.isEmpty ? -1 : min(max(0, index), entries.count - 1)
    }
}

/// Saves the history across restarts.
public final class HistoryStore {
    public static let key = "trackHistory"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load(capacity: Int = 1000) -> TrackHistory {
        guard let data = defaults.data(forKey: Self.key),
              let h = try? JSONDecoder().decode(TrackHistory.self, from: data) else { return TrackHistory(capacity: capacity) }
        return h
    }

    public func save(_ history: TrackHistory) {
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: Self.key) }
    }
}
