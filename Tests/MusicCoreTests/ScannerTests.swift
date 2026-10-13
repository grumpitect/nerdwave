import AVFoundation
import XCTest
@testable import MusicCore

final class LoudnessTests: XCTestCase {
    func writeSine(amplitude: Float, seconds: Double, rate: Double = 48_000, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * rate)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        for c in 0..<2 { for i in 0..<Int(frames) { buf.floatChannelData![c][i] = amplitude * sin(2 * .pi * 1000 * Float(i) / Float(rate)) } }
        try file.write(from: buf)
    }

    /// EBU Tech 3341: a 1 kHz sine at -23 dBFS in both channels reads -23.0 LUFS.
    func testReferenceToneReadsMinus23LUFS() throws {
        for rate in [48_000.0, 44_100.0] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ref-\(UUID().uuidString).caf")
            defer { try? FileManager.default.removeItem(at: url) }
            try writeSine(amplitude: pow(10, -23 / 20), seconds: 5, rate: rate, to: url)
            XCTAssertEqual(integratedLoudness(of: url)!, -23, accuracy: 0.1, "at \(rate) Hz")
        }
    }

    func testSilenceHasNoLoudness() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silent-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSine(amplitude: 0, seconds: 2, to: url)
        XCTAssertNil(integratedLoudness(of: url))
    }

    func testWeightsTurnLouderPlaylistsDown() {
        let w = playlistWeights(medianLoudness: ["Calm": -15.74, "Chill": -11.97, "Hip-Hop": -9.14])
        XCTAssertEqual(w["Calm"], 100)                          // quietest is the reference
        XCTAssertEqual(w["Chill"], 87)
        XCTAssertEqual(w["Hip-Hop"], 78)
        XCTAssertTrue(playlistWeights(medianLoudness: [:]).isEmpty)
        XCTAssertEqual(median([3, 1, 2]), 2); XCTAssertEqual(median([4, 1, 3, 2]), 2.5); XCTAssertNil(median([]))
    }
}

final class ScannerTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("music-\(UUID().uuidString)")
        let fm = FileManager.default
        for dir in ["Chill/Album A", "Chill/Album B", "Rock", "Empty", ".Hidden"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for f in ["Chill/Album A/01 One.mp3", "Chill/Album B/02 Two.m4a", "Chill/notes.txt", "Rock/01 Riff.mp3",
                  ".Hidden/secret.mp3", "Loose Track.mp3", "Chill/.DS_Store"] {
            try Data().write(to: root.appendingPathComponent(f))
        }
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testSubfoldersBecomePlaylists() {
        let found = scanMusicFolder(root)
        XCTAssertEqual(found.map(\.name), [root.lastPathComponent, "Chill", "Rock"])   // loose files, then subfolders
        let chill = found.first { $0.name == "Chill" }!
        XCTAssertEqual(chill.tracks.map(\.lastPathComponent), ["01 One.mp3", "02 Two.m4a"])
        XCTAssertFalse(found.contains { $0.name == "Empty" || $0.name == ".Hidden" })
    }

    func testWrittenPlaylistsLoadBackWithWeights() throws {
        let out = root.appendingPathComponent("out")
        let found = scanMusicFolder(root).filter { $0.name != root.lastPathComponent }
        try writePlaylists(found, weights: ["Chill": 87, "Rock": 79], to: out)
        let loaded = Dictionary(uniqueKeysWithValues: loadPlaylists(in: out).map { ($0.name, $0) })
        XCTAssertEqual(loaded["Chill"]!.weight, 0.87, accuracy: 1e-9)
        XCTAssertEqual(loaded["Rock"]!.weight, 0.79, accuracy: 1e-9)
        XCTAssertEqual(loaded["Chill"]!.tracks, found.first { $0.name == "Chill" }!.tracks.map { URL(fileURLWithPath: $0.path) })
    }

    func testRescanReplacesSameNamedPlaylistsOnly() throws {
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try "#EXTM3U\n/x/keep.mp3\n".write(to: out.appendingPathComponent("Keep.m3u"), atomically: true, encoding: .utf8)
        try writePlaylists(scanMusicFolder(root), weights: [:], to: out)
        try writePlaylists(scanMusicFolder(root), weights: [:], to: out)
        let names = Set(loadPlaylists(in: out).map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["Keep", "Chill", "Rock"]))
    }

    func testLooseFilesNeverCollideWithASubfolder() throws {
        let fm = FileManager.default
        let r = root.appendingPathComponent("Jazz")               // root named like one of its subfolders
        try fm.createDirectory(at: r.appendingPathComponent("Jazz"), withIntermediateDirectories: true)
        try Data().write(to: r.appendingPathComponent("loose.mp3"))
        try Data().write(to: r.appendingPathComponent("Jazz/inner.mp3"))
        let names = scanMusicFolder(r).map(\.name)
        XCTAssertEqual(Set(names), ["Jazz", "Jazz (loose files)"])
    }

    func testRebalanceAcrossSeparateScans() throws {
        let out = root.appendingPathComponent("out")
        let a = [ScannedPlaylist(name: "Calm", tracks: [URL(fileURLWithPath: "/m/a.mp3")])]
        let b = [ScannedPlaylist(name: "Hip-Hop", tracks: [URL(fileURLWithPath: "/m/b.mp3")])]
        try writePlaylists(a, weights: ["Calm": 100], loudness: ["Calm": -15.74], to: out)
        try writePlaylists(b, weights: ["Hip-Hop": 100], loudness: ["Hip-Hop": -9.14], to: out)   // second scan
        let w = try rebalancePlaylists(in: out)
        XCTAssertEqual(w, ["Calm": 100, "Hip-Hop": 78])
        let loaded = Dictionary(uniqueKeysWithValues: loadPlaylists(in: out).map { ($0.name, $0.weight) })
        XCTAssertEqual(loaded["Hip-Hop"]!, 0.78, accuracy: 1e-9, "weights rewritten in the files")
    }

    func testMenuAlwaysOffersScanAndHighlightsItWhenEmpty() {
        let empty = menuEntries(for: MenuState(playlists: [], current: nil, isPlaying: false, nowPlaying: nil,
                                               volumePercent: 25, openAtLogin: false))
        XCTAssertTrue(empty.contains(.scanFolder(highlighted: true)))
        let stale = menuEntries(for: MenuState(playlists: [], current: nil, isPlaying: false, nowPlaying: nil,
                                               volumePercent: 25, openAtLogin: false, canGoBack: true))
        XCTAssertEqual(stale.first, .transport(playing: false, enabled: false, canGoBack: false), "no back without a mood")
        XCTAssertTrue(empty.contains(.feedback)); XCTAssertTrue(empty.contains(.welcome))
        let full = menuEntries(for: MenuState(playlists: ["Chill"], current: nil, isPlaying: false, nowPlaying: nil,
                                              volumePercent: 25, openAtLogin: false))
        XCTAssertTrue(full.contains(.scanFolder(highlighted: false)))
        let troubled = menuEntries(for: MenuState(playlists: ["Chill"], current: nil, isPlaying: false, nowPlaying: nil,
                                                  volumePercent: 25, openAtLogin: false, notice: "audio output unavailable"))
        XCTAssertTrue(troubled.contains(.notice("audio output unavailable")))
        XCTAssertTrue(troubled.contains(.scanFolder(highlighted: false)), "scan stays available during an error")
        let scanning = menuEntries(for: MenuState(playlists: ["Chill"], current: nil, isPlaying: false, nowPlaying: nil,
                                                  volumePercent: 25, openAtLogin: false, scanStatus: "measuring 3/10"))
        XCTAssertTrue(scanning.contains(.scanning("measuring 3/10")))
        XCTAssertFalse(scanning.contains(.scanFolder(highlighted: false)))
    }
}
