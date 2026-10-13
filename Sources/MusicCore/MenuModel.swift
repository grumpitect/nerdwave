import Foundation

/// The menu, described without AppKit so its layout can be tested.
public enum MenuEntry: Equatable {
    /// Back, rewind 10 s, play/pause, forward 10 s, next.
    case transport(playing: Bool, enabled: Bool, canGoBack: Bool)
    case nowPlaying(String)
    case volume(percent: Int)
    case playlist(name: String, symbol: String, checked: Bool)
    case noPlaylists
    /// Choose a folder to scan and build playlists from (always available).
    case scanFolder(highlighted: Bool)
    case scanning(String)
    /// A problem worth showing (for example the audio output is unavailable).
    case notice(String)
    case feedback
    case welcome
    case openAtLogin(on: Bool)
    case exit
    case separator
}

public let moodSymbols: [String: String] = [
    "Chill": "cup.and.saucer.fill",
    "Hip-Hop": "headphones",
    "Upbeat": "bolt.fill",
    "Late Night": "moon.stars.fill",
    "Retro Gaming": "gamecontroller.fill",
    "Calm": "leaf.fill",
    "Rock": "guitars.fill",
]

public struct MenuState {
    public var playlists: [String]
    public var current: String?
    public var isPlaying: Bool
    public var nowPlaying: String?
    public var volumePercent: Int
    public var openAtLogin: Bool
    public var canGoBack: Bool
    public var scanStatus: String?
    public var notice: String?
    public init(playlists: [String], current: String?, isPlaying: Bool, nowPlaying: String?,
                volumePercent: Int, openAtLogin: Bool, canGoBack: Bool = false, scanStatus: String? = nil,
                notice: String? = nil) {
        self.playlists = playlists; self.current = current; self.isPlaying = isPlaying
        self.nowPlaying = nowPlaying; self.volumePercent = volumePercent; self.openAtLogin = openAtLogin
        self.canGoBack = canGoBack
        self.scanStatus = scanStatus
        self.notice = notice
    }
}

/// Transport controls first, then what's playing and the volume, the playlists, and Exit last.
public func menuEntries(for s: MenuState) -> [MenuEntry] {
    var items: [MenuEntry] = [.transport(playing: s.isPlaying, enabled: s.current != nil,
                                         canGoBack: s.canGoBack && s.current != nil)]
    if let current = s.current { items.append(.nowPlaying("\(current): \(s.nowPlaying ?? "")")) }
    items.append(.volume(percent: s.volumePercent))
    items.append(.separator)
    if s.playlists.isEmpty { items.append(.noPlaylists) }
    for name in s.playlists {
        items.append(.playlist(name: name, symbol: moodSymbols[name] ?? "music.note.list", checked: name == s.current))
    }
    if let notice = s.notice { items.append(.notice(notice)) }
    if let status = s.scanStatus { items.append(.scanning(status)) }
    else { items.append(.scanFolder(highlighted: s.playlists.isEmpty)) }
    items.append(.separator)
    items.append(.welcome)
    items.append(.feedback)
    items.append(.openAtLogin(on: s.openAtLogin))
    items.append(.exit)
    return items
}
