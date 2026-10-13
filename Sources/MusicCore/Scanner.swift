import AVFoundation
import Foundation

/// Where Nerdwave keeps its playlists: ~/Library/Application Support/Nerdwave/Playlists
public enum AppPaths {
    public static var playlists: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Nerdwave/Playlists", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

public let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "caf", "alac", "mp4"]

/// A playlist found while scanning a music folder.
public struct ScannedPlaylist: Equatable {
    public let name: String
    public let tracks: [URL]
}

/// Each subfolder of `root` becomes a playlist with every audio file inside it (any depth),
/// named after the subfolder. Audio files directly in `root` form a playlist named after `root`.
/// Hidden files and folders are skipped; tracks are sorted by path.
public func scanMusicFolder(_ root: URL) -> [ScannedPlaylist] {
    let fm = FileManager.default
    func audioFiles(in dir: URL, recursive: Bool) -> [URL] {
        let opts: FileManager.DirectoryEnumerationOptions = recursive ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: opts) else { return [] }
        return e.compactMap { $0 as? URL }
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    var result: [ScannedPlaylist] = []
    let top = audioFiles(in: root, recursive: false)
    let subdirs = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && $0.pathExtension != "app" }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    for dir in subdirs {
        let tracks = audioFiles(in: dir, recursive: true)
        if !tracks.isEmpty { result.append(ScannedPlaylist(name: dir.lastPathComponent, tracks: tracks)) }
    }
    if !top.isEmpty {     // loose files directly in the root; never collide with a subfolder's name
        let clash = result.contains { $0.name.caseInsensitiveCompare(root.lastPathComponent) == .orderedSame }
        let name = clash ? "\(root.lastPathComponent) (loose files)" : root.lastPathComponent
        result.insert(ScannedPlaylist(name: name, tracks: top), at: 0)
    }
    return result
}

/// Median of a list (nil when empty).
public func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let s = values.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

/// Writes `<Name>.m3u` files (absolute paths, `#WEIGHT:` and `#LOUDNESS:` lines, `#EXTINF` with durations)
/// into `dir`. Existing playlists with the same names are replaced; others are left alone.
@discardableResult
public func writePlaylists(_ playlists: [ScannedPlaylist], weights: [String: Int],
                           loudness: [String: Double] = [:], to dir: URL) throws -> [URL] {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var written: [URL] = []
    for p in playlists {
        var lines = ["#EXTM3U", "#WEIGHT: \(weights[p.name] ?? 100)%"]
        if let l = loudness[p.name] { lines.append(String(format: "#LOUDNESS: %.2f LUFS", l)) }
        for t in p.tracks {
            let seconds = (try? AVAudioFile(forReading: t)).map { Int(Double($0.length) / $0.processingFormat.sampleRate) } ?? -1
            lines.append("#EXTINF:\(seconds),\(trackDisplayName(t))")
            lines.append(t.path.replacingOccurrences(of: "\n", with: " "))
        }
        let url = dir.appendingPathComponent("\(p.name).m3u")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        written.append(url)
    }
    return written
}

/// Scans `root`, measures every track's loudness to set balanced weights, and writes the playlists.
/// `progress(done, total)` is called as tracks are measured. Returns the playlists and their weights.
public func buildPlaylists(from root: URL, into dir: URL = AppPaths.playlists,
                           progress: ((Int, Int) -> Void)? = nil) throws -> [(name: String, weight: Int, tracks: Int)] {
    let found = scanMusicFolder(root)
    let total = found.reduce(0) { $0 + $1.tracks.count }
    var done = 0
    var medians: [String: Double] = [:]
    for p in found {
        var values: [Double] = []
        for t in p.tracks {
            if let l = integratedLoudness(of: t) { values.append(l) }
            done += 1
            progress?(done, total)
        }
        medians[p.name] = median(values)
    }
    let measured = medians.compactMapValues { $0 }
    try writePlaylists(found, weights: playlistWeights(medianLoudness: measured), loudness: measured, to: dir)
    let weights = try rebalancePlaylists(in: dir)          // balance against playlists from earlier scans too
    return found.map { (name: $0.name, weight: weights[$0.name] ?? 100, tracks: $0.tracks.count) }
}

/// Reads `#LOUDNESS:` from every playlist in `dir` and rewrites their `#WEIGHT:` lines so all of them,
/// from any scan, are balanced against each other. Playlists without a loudness line are left as they are.
@discardableResult
public func rebalancePlaylists(in dir: URL) throws -> [String: Int] {
    let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension.lowercased() == "m3u" }
    var loudness: [String: Double] = [:]
    var texts: [URL: String] = [:]
    for f in files {
        guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
        texts[f] = text
        if let line = text.split(whereSeparator: \.isNewline).first(where: { $0.uppercased().hasPrefix("#LOUDNESS:") }),
           let value = Double(line.dropFirst("#LOUDNESS:".count).replacingOccurrences(of: "LUFS", with: "")
                .trimmingCharacters(in: .whitespaces)) {
            loudness[f.deletingPathExtension().lastPathComponent] = value
        }
    }
    let weights = playlistWeights(medianLoudness: loudness)
    for (f, text) in texts {
        guard let w = weights[f.deletingPathExtension().lastPathComponent] else { continue }
        let lines = text.components(separatedBy: "\n").map { $0.uppercased().hasPrefix("#WEIGHT:") ? "#WEIGHT: \(w)%" : $0 }
        try lines.joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
    }
    return weights
}
