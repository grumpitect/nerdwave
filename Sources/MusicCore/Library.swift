import Foundation

/// Where feedback and feature requests go (GitHub issues).
public let feedbackURL = URL(string: "https://github.com/grumpitect/nerdwave/issues/new/choose")!
/// The YouTube channel Nerdwave was made for.
public let channelURL = URL(string: "https://www.youtube.com/@nerdative")!
/// Free, stream-safe music (not bundled; users download it themselves).
public let streamBeatsURL = URL(string: "https://www.streambeats.com")!

public struct Playlist: Equatable {
    public let name: String
    public let tracks: [URL]
    /// Loudness weight from the playlist's `#WEIGHT:` line (0 to 1; 1 when missing).
    public let weight: Double
    /// SF Symbol from an optional `#ICON:` line; nil means "guess from the name".
    public let icon: String?
    public init(name: String, tracks: [URL], weight: Double = 1, icon: String? = nil) {
        self.name = name; self.tracks = tracks; self.weight = weight; self.icon = icon
    }
    /// The icon to show: the `#ICON:` override, or a guess from the name.
    public var displayIcon: String { icon ?? guessPlaylistIcon(name) }
}

/// Reads an `#ICON: gamecontroller.fill` line (an SF Symbol name).
public func parseIcon(_ line: Substring) -> String? {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard t.uppercased().hasPrefix("#ICON:") else { return nil }
    let v = t.dropFirst("#ICON:".count).trimmingCharacters(in: .whitespaces)
    return v.isEmpty ? nil : v
}

/// Reads a `#WEIGHT: 84%` (or `#WEIGHT: 0.84`) line. Other players treat it as a comment.
public func parseWeight(_ line: Substring) -> Double? {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard t.uppercased().hasPrefix("#WEIGHT:") else { return nil }
    var v = t.dropFirst("#WEIGHT:".count).trimmingCharacters(in: .whitespaces)
    let percent = v.hasSuffix("%")
    if percent { v.removeLast() }
    guard let n = Double(v.trimmingCharacters(in: .whitespaces)) else { return nil }
    return min(1, max(0, percent || n > 1 ? n / 100 : n))
}

/// Reads every `<Name>.m3u` in a folder. Relative entries resolve against that folder,
/// comment lines (`#...`) are ignored except `#WEIGHT:`, and empty playlists are skipped.
public func loadPlaylists(in dir: URL) -> [Playlist] {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return files
        .filter { $0.pathExtension.lowercased() == "m3u" }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        .compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let lines = text.split(whereSeparator: \.isNewline)
            let weight = lines.lazy.compactMap(parseWeight).first ?? 1
            let icon = lines.lazy.compactMap(parseIcon).first
            let tracks = lines
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                .map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : dir.appendingPathComponent($0) }
            return tracks.isEmpty ? nil : Playlist(name: url.deletingPathExtension().lastPathComponent,
                                                   tracks: tracks, weight: weight, icon: icon)
        }
}

/// Removes a playlist by moving its `.m3u` file out of `dir` (to the Trash by default, so it can be restored).
/// The music files themselves are never touched. Returns false when there is no playlist with that name.
@discardableResult
public func removePlaylist(named name: String, in dir: URL,
                           discard: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws -> Bool {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    guard let file = files.first(where: { $0.pathExtension.lowercased() == "m3u" && $0.deletingPathExtension().lastPathComponent == name })
    else { return false }
    try discard(file)
    return true
}

/// The slider follows VLC's cubic volume curve, so 25% sounds like VLC at 25%.
/// 100% with weight 1.0 is full, unattenuated sound; a playlist's weight scales it down.
public func amplitude(weight: Double, percent: Int) -> Float {
    let p = Double(min(100, max(0, percent))) / 100
    return Float(pow(p * min(1, max(0, weight)), 3))
}

/// "01 Track Name.mp3" -> "Track Name".
public func trackDisplayName(_ url: URL) -> String {
    let name = url.deletingPathExtension().lastPathComponent
    if let space = name.firstIndex(of: " "), name[..<space].allSatisfy(\.isNumber), name.index(after: space) < name.endIndex {
        return String(name[name.index(after: space)...])
    }
    return name
}

/// The app's volume slider (0 to 100%), saved across restarts. Defaults to 40%: a quiet background bed on a stream
/// (about -39 LUFS for a typical playlist), well under a voice at about -16.
public final class VolumeSetting {
    public static let key = "volumePercent"
    public static let defaultPercent = 40
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var percent: Int {
        get { defaults.object(forKey: Self.key) == nil ? Self.defaultPercent : min(100, max(0, defaults.integer(forKey: Self.key))) }
        set { defaults.set(min(100, max(0, newValue)), forKey: Self.key) }
    }
}

/// The last playlist picked from the menu, remembered across restarts.
public final class LastPlaylistSetting {
    public static let key = "lastPlaylist"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var name: String? {
        get { defaults.string(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}
