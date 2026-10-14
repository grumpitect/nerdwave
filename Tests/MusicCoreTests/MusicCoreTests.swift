import AVFoundation
import XCTest
@testable import MusicCore

/// Records what the player asks of the audio output, so the player logic can be checked without sound.
final class FakeBackend: AudioBackend {
    var onNearEnd: (() -> Void)?
    var onFinished: (() -> Void)?
    var crossfades: [URL] = []
    var isPlaying = false
    var loaded: [URL] = []
    var amplitudes: [Float] = []
    var events: [String] = []
    var unreadable: Set<URL> = []

    var engineDown = false
    func load(_ url: URL) throws {
        if engineDown { throw BackendError.engineUnavailable(NSError(domain: "fake", code: 2)) }
        if unreadable.contains(url) { throw BackendError.unreadable(url) }
        loaded.append(url); events.append("load")
    }
    func crossfade(to url: URL) throws {
        if engineDown { throw BackendError.engineUnavailable(NSError(domain: "fake", code: 2)) }
        if unreadable.contains(url) { throw BackendError.unreadable(url) }
        crossfades.append(url); events.append("crossfade")
    }
    var cued: [(URL, Double)] = []
    func cue(_ url: URL, at elapsed: Double) throws {
        if unreadable.contains(url) { throw BackendError.unreadable(url) }
        loaded.append(url); cued.append((url, elapsed)); events.append("cue")
    }
    func play() { isPlaying = true; events.append("play") }
    func pause() { isPlaying = false; events.append("pause") }
    func stop() { isPlaying = false; events.append("stop") }
    func setAmplitude(_ value: Float) { amplitudes.append(value); events.append("volume") }
    var seeks: [Double] = []
    func seek(by seconds: Double) { seeks.append(seconds) }
    var progress: (elapsed: Double, total: Double)? { loaded.isEmpty ? nil : (12, 120) }
    func finishTrack() { onFinished?() }
    func nearEnd() { onNearEnd?() }
}

/// Deterministic RNG for shuffle tests.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
}

func tracks(_ n: Int) -> [URL] { (1...n).map { URL(fileURLWithPath: "/music/\(String(format: "%02d", $0)) Track \($0).mp3") } }

final class LibraryTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testLoadsPlaylistsSortedAndResolvesPaths() throws {
        try "#EXTM3U\n#EXTINF:1,a\nChill/A/01 One.mp3\n\n/abs/two.mp3\n".write(to: dir.appendingPathComponent("Chill.m3u"), atomically: true, encoding: .utf8)
        try "Rock/x.mp3\n".write(to: dir.appendingPathComponent("Calm.m3u"), atomically: true, encoding: .utf8)
        try "not a playlist".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let lists = loadPlaylists(in: dir)
        XCTAssertEqual(lists.map(\.name), ["Calm", "Chill"])
        XCTAssertEqual(lists[1].tracks, [dir.appendingPathComponent("Chill/A/01 One.mp3"), URL(fileURLWithPath: "/abs/two.mp3")])
    }

    func testSkipsEmptyPlaylistsAndMissingFolder() throws {
        try "#EXTM3U\n# only comments\n".write(to: dir.appendingPathComponent("Empty.m3u"), atomically: true, encoding: .utf8)
        XCTAssertTrue(loadPlaylists(in: dir).isEmpty)
        XCTAssertTrue(loadPlaylists(in: dir.appendingPathComponent("nope")).isEmpty)
    }

    func testReadsWeightFromPlaylistFile() throws {
        try "#EXTM3U\n#WEIGHT: 84%\nA/01 x.mp3\n".write(to: dir.appendingPathComponent("Hip-Hop.m3u"), atomically: true, encoding: .utf8)
        try "#weight:0.5\nB/y.mp3\n".write(to: dir.appendingPathComponent("Half.m3u"), atomically: true, encoding: .utf8)
        try "C/z.mp3\n".write(to: dir.appendingPathComponent("NoWeight.m3u"), atomically: true, encoding: .utf8)
        let byName = Dictionary(uniqueKeysWithValues: loadPlaylists(in: dir).map { ($0.name, $0) })
        XCTAssertEqual(byName["Hip-Hop"]!.weight, 0.84, accuracy: 1e-9)
        XCTAssertEqual(byName["Half"]!.weight, 0.5, accuracy: 1e-9)
        XCTAssertEqual(byName["NoWeight"]!.weight, 1)
        XCTAssertEqual(byName["Hip-Hop"]!.tracks.count, 1, "the weight line is not a track")
    }

    func testParseWeight() {
        XCTAssertEqual(parseWeight("#WEIGHT: 84%"), 0.84)
        XCTAssertEqual(parseWeight("#WEIGHT:0.84"), 0.84)
        XCTAssertEqual(parseWeight("#WEIGHT: 84"), 0.84)          // bare number above 1 is a percentage
        XCTAssertEqual(parseWeight("#WEIGHT: 150%"), 1)           // clamped
        XCTAssertNil(parseWeight("#WEIGHT: loud"))
        XCTAssertNil(parseWeight("#EXTINF:12,Song"))
    }

    func testAmplitudeFollowsVLCCurveAndWeights() {
        XCTAssertEqual(amplitude(weight: 1, percent: 100), 1, accuracy: 1e-6)          // 100% = full sound
        // 25% sounds like VLC at 25%: (0.25)^3 = -36.1 dB
        XCTAssertEqual(20 * log10(Double(amplitude(weight: 1, percent: 25))), -36.1, accuracy: 0.1)
        XCTAssertEqual(amplitude(weight: 0.5, percent: 100), Float(pow(0.5, 3)), accuracy: 1e-6)
        XCTAssertEqual(amplitude(weight: 0.8, percent: 0), 0)
        XCTAssertEqual(amplitude(weight: 1, percent: 150), 1, accuracy: 1e-6)          // clamped
        XCTAssertEqual(amplitude(weight: 2, percent: 100), 1, accuracy: 1e-6)          // clamped
    }

    func testPlaylistBalanceMatchesCalibration() {
        // Calm needed VLC 76 and Hip-Hop 64, so Hip-Hop's weight is 64/76 = 84%.
        let calm = Double(amplitude(weight: 1, percent: 25)), hip = Double(amplitude(weight: 64.0 / 76, percent: 25))
        XCTAssertEqual(20 * log10(hip / calm), 60 * log10(64.0 / 76), accuracy: 0.01)
    }

    func testTrackDisplayName() {
        XCTAssertEqual(trackDisplayName(URL(fileURLWithPath: "/a/01 Track Name.mp3")), "Track Name")
        XCTAssertEqual(trackDisplayName(URL(fileURLWithPath: "/a/No Number.mp3")), "No Number")
        XCTAssertEqual(trackDisplayName(URL(fileURLWithPath: "/a/2049.mp3")), "2049")
    }

    func testLastPlaylistIsRemembered() {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(LastPlaylistSetting(defaults: defaults).name)
        LastPlaylistSetting(defaults: defaults).name = "Retro Gaming"
        XCTAssertEqual(LastPlaylistSetting(defaults: defaults).name, "Retro Gaming")   // survives a "restart"
    }

    func testVolumeSettingPersistsAndClamps() {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(VolumeSetting(defaults: defaults).percent, 40)           // default
        VolumeSetting(defaults: defaults).percent = 42
        XCTAssertEqual(VolumeSetting(defaults: defaults).percent, 42)           // survives a "restart"
        VolumeSetting(defaults: defaults).percent = 250
        XCTAssertEqual(VolumeSetting(defaults: defaults).percent, 100)
        VolumeSetting(defaults: defaults).percent = -3
        XCTAssertEqual(VolumeSetting(defaults: defaults).percent, 0)
    }
}

final class PlayQueueTests: XCTestCase {
    func testMakeCurrentMovesTrackToThePlayPosition() {
        var q = PlayQueue(tracks: tracks(6), rng: SeededRNG(state: 7))
        let target = q.order[4]
        q.makeCurrent(target)
        XCTAssertEqual(q.current, target)
        XCTAssertEqual(Set(q.order), Set(tracks(6)))
        XCTAssertNotEqual(q.advance(), target)
    }

    func testPlaysEveryTrackOncePerPassThenReshuffles() {
        var q = PlayQueue(tracks: tracks(10), rng: SeededRNG(state: 7))
        var firstPass = [q.current!]
        for _ in 1..<10 { firstPass.append(q.advance()!) }
        XCTAssertEqual(Set(firstPass), Set(tracks(10)))
        XCTAssertEqual(q.passes, 1)
        let next = q.advance()!
        XCTAssertEqual(q.passes, 2)
        XCTAssertNotEqual(next, firstPass.last)            // no repeat across the pass boundary
    }

    func testShuffleChangesOrder() {
        let q = PlayQueue(tracks: tracks(30), rng: SeededRNG(state: 1))
        XCTAssertNotEqual(q.order, tracks(30))
    }

    func testEmptyAndRemove() {
        var empty = PlayQueue(tracks: [], rng: SeededRNG(state: 1))
        XCTAssertNil(empty.current); XCTAssertNil(empty.advance())
        var q = PlayQueue(tracks: tracks(2), rng: SeededRNG(state: 3))
        q.removeCurrent(); XCTAssertEqual(q.order.count, 1)
        q.removeCurrent(); XCTAssertTrue(q.isEmpty); XCTAssertNil(q.current)
    }
}

final class PlayerTests: XCTestCase {
    func testPlaySetsVolumeBeforeLoadingAndPlays() {
        let b = FakeBackend()
        let p = MusicPlayer(backend: b, volumePercent: 25, fileExists: { _ in true })
        p.play(Playlist(name: "Chill", tracks: tracks(5)), weight: 0.9)
        XCTAssertEqual(b.events.first, "volume", "level must be set before anything plays")
        XCTAssertEqual(b.amplitudes.last!, amplitude(weight: 0.9, percent: 25), accuracy: 1e-9)
        XCTAssertTrue(p.isPlaying)
        XCTAssertEqual(p.current?.name, "Chill")
        XCTAssertNotNil(p.nowPlaying)
    }

    func testAdvancesWhenTrackFinishesAndLoopsForever() {
        let b = FakeBackend()
        let p = MusicPlayer(backend: b, fileExists: { _ in true })
        p.play(Playlist(name: "Rock", tracks: tracks(3)), weight: 0.85)
        for _ in 0..<10 { b.finishTrack() }
        XCTAssertEqual(b.loaded.count, 11)
        XCTAssertTrue(p.isPlaying)
    }

    func testPauseResumeAndStop() {
        let b = FakeBackend()
        let p = MusicPlayer(backend: b, fileExists: { _ in true })
        p.togglePause()                                      // nothing loaded: no-op
        XCTAssertFalse(b.events.contains("play"))
        p.play(Playlist(name: "Calm", tracks: tracks(2)), weight: 1)
        p.togglePause(); XCTAssertFalse(p.isPlaying)
        p.togglePause(); XCTAssertTrue(p.isPlaying)
        p.stop()
        XCTAssertFalse(p.isPlaying); XCTAssertNil(p.current); XCTAssertNil(p.nowPlaying)
    }

    func testResumeLoadsTrackPausedAndPlayContinuesIt() {
        let b = FakeBackend()
        let all = tracks(5)
        let p = MusicPlayer(backend: b, fileExists: { _ in true })
        p.cue(Playlist(name: "Chill", tracks: all), weight: 1, resuming: all[2], at: 42)
        XCTAssertEqual(b.cued.first?.0, all[2]); XCTAssertEqual(b.cued.first?.1, 42)
        XCTAssertFalse(p.isPlaying, "resuming must not start playback by itself")
        XCTAssertEqual(p.nowPlaying, "Track 3")
        XCTAssertEqual(p.history.current?.path, all[2].path)
        XCTAssertEqual(p.resumePoint, ResumePoint(path: all[2].path, playlist: "Chill", elapsed: 12))
        p.togglePause()
        XCTAssertTrue(p.isPlaying)
        XCTAssertEqual(b.loaded, [all[2]], "Play continues the cued track instead of loading another")
        p.next()
        XCTAssertNotEqual(b.loaded.last, all[2], "Next moves on from the resumed track")
    }

    func testResumeFallsBackQuietlyWhenTheTrackIsGoneOrUnreadable() {
        let all = tracks(3)
        for broken in ["missing", "unreadable"] {
            let b = FakeBackend()
            if broken == "unreadable" { b.unreadable = [all[0]] }
            let p = MusicPlayer(backend: b, fileExists: { broken == "missing" ? $0 != all[0] : true })
            p.cue(Playlist(name: "Rock", tracks: all), weight: 1, resuming: all[0], at: 30)
            XCTAssertEqual(p.current?.name, "Rock", broken)
            XCTAssertNil(p.currentTrack, broken)
            XCTAssertNil(p.lastError, "no error shown when the saved track is \(broken)")
            p.togglePause()                                   // Play starts the playlist as usual
            XCTAssertTrue(p.isPlaying, broken)
        }
    }

    func testResumeStoreRoundTrip() {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ResumeStore(defaults: defaults)
        XCTAssertNil(store.point)
        store.point = ResumePoint(path: "/m/01 A.mp3", playlist: "Chill", elapsed: 73.5)
        XCTAssertEqual(ResumeStore(defaults: defaults).point, ResumePoint(path: "/m/01 A.mp3", playlist: "Chill", elapsed: 73.5))
        store.point = nil
        XCTAssertNil(ResumeStore(defaults: defaults).point)
    }

    func testMasterVolumeAppliesLive() {
        let b = FakeBackend()
        let p = MusicPlayer(backend: b, volumePercent: 25, fileExists: { _ in true })
        p.play(Playlist(name: "Chill", tracks: tracks(2)), weight: 0.9)
        p.volumePercent = 40
        XCTAssertEqual(b.amplitudes.last!, amplitude(weight: 0.9, percent: 40), accuracy: 1e-9)
    }

    func testSkipsMissingAndUnreadableFiles() {
        let b = FakeBackend()
        let all = tracks(4)
        b.unreadable = [all[1]]
        let p = MusicPlayer(backend: b, fileExists: { $0 != all[0] })
        p.play(Playlist(name: "Mix", tracks: all), weight: 0.84)
        for _ in 0..<6 { b.finishTrack() }
        XCTAssertFalse(b.loaded.contains(all[0]))           // missing file never loaded
        XCTAssertFalse(b.loaded.contains(all[1]))           // unreadable file dropped
        XCTAssertEqual(Set(b.loaded), [all[2], all[3]])
    }

    func testCrossfadesIntoNextTrackNearTheEnd() {
        let b = FakeBackend()
        let p = MusicPlayer(backend: b, fileExists: { _ in true })
        p.play(Playlist(name: "Chill", tracks: tracks(4)), weight: 1)
        let first = p.currentTrack
        b.nearEnd()
        XCTAssertEqual(b.crossfades.count, 1)
        XCTAssertNotEqual(b.crossfades[0], first)
        XCTAssertEqual(p.currentTrack, b.crossfades[0])
        for _ in 0..<9 { b.nearEnd() }                    // keeps crossfading across passes
        XCTAssertEqual(b.crossfades.count, 10)
        XCTAssertEqual(b.loaded.count, 1, "only the first track starts without a fade")
    }

    func testCrossfadeSkipsUnreadableNextTrack() {
        let b = FakeBackend()
        let all = tracks(3)
        let p = MusicPlayer(backend: b, fileExists: { _ in true })
        p.play(Playlist(name: "Mix", tracks: all), weight: 1)
        b.unreadable = Set(all.filter { $0 != p.currentTrack }.prefix(1))
        b.nearEnd()
        XCTAssertEqual(b.crossfades.count, 1)
        XCTAssertFalse(b.unreadable.contains(b.crossfades[0]))
    }

    func testCueSelectsWithoutPlayingThenPlayStarts() {
        let b = FakeBackend()
        let p = MusicPlayer(backend: b, volumePercent: 25, fileExists: { _ in true })
        p.cue(Playlist(name: "Chill", tracks: tracks(3)), weight: 0.99)
        XCTAssertEqual(p.current?.name, "Chill")
        XCTAssertFalse(p.isPlaying)
        XCTAssertTrue(b.loaded.isEmpty, "nothing loads until Play")
        XCTAssertEqual(b.amplitudes.last!, amplitude(weight: 0.99, percent: 25), accuracy: 1e-9)
        p.togglePause()
        XCTAssertTrue(p.isPlaying)
        XCTAssertEqual(b.loaded.count, 1)
    }

    func testBackAndForwardThroughHistory() {
        let b = FakeBackend()
        let p = MusicPlayer(backend: b, fileExists: { _ in true })
        p.play(Playlist(name: "Chill", tracks: tracks(5)), weight: 1)
        var played = [p.currentTrack!]
        for _ in 0..<3 { p.next(); played.append(p.currentTrack!) }
        XCTAssertTrue(p.canGoBack)
        p.previous(); XCTAssertEqual(p.currentTrack, played[2])
        p.previous(); XCTAssertEqual(p.currentTrack, played[1])
        p.next();     XCTAssertEqual(p.currentTrack, played[2], "forward replays history")
        p.next();     XCTAssertEqual(p.currentTrack, played[3])
        p.next();     XCTAssertFalse(played.suffix(1).contains(p.currentTrack!), "then fresh tracks")
    }

    func testBackCrossesIntoAnotherPlaylistWithItsWeight() {
        let chill = Playlist(name: "Chill", tracks: tracks(3), weight: 0.99)
        let rock = Playlist(name: "Rock", tracks: [URL(fileURLWithPath: "/rock/01 R.mp3")], weight: 0.86)
        let b = FakeBackend()
        let p = MusicPlayer(backend: b, volumePercent: 25, fileExists: { _ in true },
                            resolve: { ["Chill": chill, "Rock": rock][$0] })
        p.play(rock, weight: rock.weight)
        let rockTrack = p.currentTrack
        p.play(chill, weight: chill.weight)
        p.previous()
        XCTAssertEqual(p.currentTrack, rockTrack)
        XCTAssertEqual(p.current?.name, "Rock")
        XCTAssertEqual(b.amplitudes.last!, amplitude(weight: 0.86, percent: 25), accuracy: 1e-9)
    }

    func testHistoryKeepsLast1000AndPersists() {
        var h = TrackHistory(capacity: 1000)
        for i in 0..<1005 { h.record(HistoryEntry(path: "/t\(i).mp3", playlist: "Chill")) }
        XCTAssertEqual(h.entries.count, 1000)
        XCTAssertEqual(h.entries.first?.path, "/t5.mp3")
        XCTAssertEqual(h.current?.path, "/t1004.mp3")
        _ = h.back(); _ = h.back()
        h.record(HistoryEntry(path: "/new.mp3", playlist: "Rock"))      // drops the forward part
        XCTAssertFalse(h.canGoForward)
        XCTAssertEqual(h.current?.path, "/new.mp3")
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        HistoryStore(defaults: defaults).save(h)
        XCTAssertEqual(HistoryStore(defaults: defaults).load(), h)
    }

    func testSeekPassesThroughOnlyWhilePlaying() {
        let b = FakeBackend()
        let p = MusicPlayer(backend: b, fileExists: { _ in true })
        p.seek(by: 10)
        XCTAssertTrue(b.seeks.isEmpty)
        p.play(Playlist(name: "Chill", tracks: tracks(2)), weight: 1)
        p.seek(by: -10); p.seek(by: 10)
        XCTAssertEqual(b.seeks, [-10, 10])
        XCTAssertEqual(p.progress?.total, 120)
    }

    func testDeviceErrorKeepsHistoryAndQueue() {
        let b = FakeBackend()
        let p = MusicPlayer(backend: b, fileExists: { _ in true })
        p.play(Playlist(name: "Chill", tracks: tracks(6)), weight: 1)
        for _ in 0..<3 { p.next() }
        let before = p.history
        b.engineDown = true
        p.previous(); p.next(); p.next()
        XCTAssertEqual(p.history.entries, before.entries, "a device error must not delete history")
        XCTAssertEqual(p.history.cursor, before.cursor)
        XCTAssertEqual(p.lastError, "audio output unavailable")
        b.engineDown = false
        p.next()
        XCTAssertNotNil(p.currentTrack, "queue survived the outage")
        XCTAssertNil(p.lastError)
    }

    func testPlayAfterDeviceErrorReloadsInsteadOfPlayingSilence() {
        let b = FakeBackend()
        let p = MusicPlayer(backend: b, fileExists: { _ in true })
        p.play(Playlist(name: "Chill", tracks: tracks(4)), weight: 1)
        b.engineDown = true
        p.next()
        XCTAssertNil(p.currentTrack, "nothing is loaded after a failed start")
        XCTAssertFalse(p.isPlaying)
        b.engineDown = false
        let loadsBefore = b.loaded.count
        p.togglePause()
        XCTAssertEqual(b.loaded.count, loadsBefore + 1, "Play loads a track again")
        XCTAssertTrue(p.isPlaying)
    }

    func testMissingHistoryFilesAreSkippedNotDeleted() {
        let all = tracks(5)
        var present = Set(all)
        let b = FakeBackend()
        let p = MusicPlayer(backend: b, fileExists: { present.contains($0) })
        p.play(Playlist(name: "Chill", tracks: all), weight: 1)
        for _ in 0..<4 { p.next() }
        let entries = p.history.entries
        present = [entries[0].url]                     // drive unplugged except one file
        present.insert(entries[4].url)
        p.previous()
        XCTAssertEqual(p.currentTrack, entries[0].url, "skips the missing ones")
        XCTAssertEqual(p.history.entries, entries, "nothing deleted")
        present = Set(all)
        p.next()
        XCTAssertEqual(p.currentTrack, entries[1].url, "forward replays the next entry, none skipped")
    }

    func testBackToMissingTrackInAnotherPlaylistDoesNotSwitch() {
        let chill = Playlist(name: "Chill", tracks: tracks(3), weight: 1)
        let rock = Playlist(name: "Rock", tracks: [URL(fileURLWithPath: "/rock/01 R.mp3")], weight: 0.5)
        var rockThere = true
        let b = FakeBackend()
        let p = MusicPlayer(backend: b, volumePercent: 25, fileExists: { $0.path.hasPrefix("/rock") ? rockThere : true },
                            resolve: { ["Chill": chill, "Rock": rock][$0] })
        p.play(rock, weight: rock.weight)
        p.play(chill, weight: chill.weight)
        let playing = p.currentTrack
        rockThere = false
        p.previous()
        XCTAssertEqual(p.current?.name, "Chill")
        XCTAssertEqual(p.currentTrack, playing)
        XCTAssertEqual(b.amplitudes.last!, amplitude(weight: 1, percent: 25), accuracy: 1e-9)
    }

    func testPlayRebuildsQueueWhenFilesAppearLater() {
        var mounted = false
        let b = FakeBackend()
        let p = MusicPlayer(backend: b, fileExists: { _ in mounted })
        p.cue(Playlist(name: "Chill", tracks: tracks(3)), weight: 1)   // drive not mounted at launch
        p.togglePause()
        XCTAssertNil(p.currentTrack)
        mounted = true
        p.togglePause()
        XCTAssertNotNil(p.currentTrack)
        XCTAssertTrue(p.isPlaying)
    }

    func testSwitchingPlaylistReplacesQueue() {
        let b = FakeBackend()
        let p = MusicPlayer(backend: b, fileExists: { _ in true })
        p.play(Playlist(name: "A", tracks: tracks(3)), weight: 0.84)
        let other = [URL(fileURLWithPath: "/other/01 X.mp3")]
        p.play(Playlist(name: "B", tracks: other), weight: 0.9)
        XCTAssertEqual(p.current?.name, "B")
        XCTAssertEqual(b.loaded.last, other[0])
    }
}

final class MenuTests: XCTestCase {
    func testLayoutWhilePlaying() {
        let e = menuEntries(for: MenuState(playlists: ["Calm", "Chill"], current: "Chill", isPlaying: true,
                                           nowPlaying: "Highland", volumePercent: 80, openAtLogin: true))
        XCTAssertEqual(e.first, .transport(playing: true, enabled: true, canGoBack: false))
        XCTAssertEqual(e.last, .exit)
        XCTAssertTrue(e.contains(.nowPlaying("Chill: Highland")))
        XCTAssertTrue(e.contains(.volume(percent: 80)))
        XCTAssertTrue(e.contains(.playlist(name: "Chill", symbol: "cup.and.saucer.fill", checked: true)))
        XCTAssertTrue(e.contains(.playlist(name: "Calm", symbol: "leaf.fill", checked: false)))
        XCTAssertTrue(e.contains(.openAtLogin(on: true)))
    }

    func testScanFollowsThePlaylistsInTheirSection() {
        let names = (1...12).map { "Mood \($0)" }
        let e = menuEntries(for: MenuState(playlists: names, current: nil, isPlaying: false, nowPlaying: nil,
                                           volumePercent: 25, openAtLogin: false))
        let lastPlaylist = e.lastIndex { if case .playlist = $0 { return true }; return false }!
        XCTAssertEqual(e[lastPlaylist + 1], .scanFolder(highlighted: false), "right under the list, outside its scroll")
        XCTAssertEqual(e[lastPlaylist + 2], .separator)
        XCTAssertEqual(e[lastPlaylist + 3], .welcome)
    }

    func testLayoutWhenIdleAndEmpty() {
        let e = menuEntries(for: MenuState(playlists: [], current: nil, isPlaying: false, nowPlaying: nil,
                                           volumePercent: 100, openAtLogin: false))
        XCTAssertEqual(e.first, .transport(playing: false, enabled: false, canGoBack: false))
        XCTAssertTrue(e.contains(.noPlaylists))
        XCTAssertEqual(e.last, .exit)
    }

    func testUnknownPlaylistGetsGenericIcon() {
        let e = menuEntries(for: MenuState(playlists: ["Untitled Mix"], current: nil, isPlaying: false, nowPlaying: nil,
                                           volumePercent: 100, openAtLogin: false))
        XCTAssertTrue(e.contains(.playlist(name: "Untitled Mix", symbol: "music.note.list", checked: false)))
    }
}

/// Plays real (generated) audio files through AVAudioEngine.
final class EngineIntegrationTests: XCTestCase {
    func makeTone(seconds: Double, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<2 { for i in 0..<Int(frames) { buffer.floatChannelData![ch][i] = 0.1 * sin(Float(i) * 0.06) } }
        try file.write(from: buffer)
        return url
    }

    /// A tone with silence before and after, like many StreamBeats tracks.
    func makePaddedTone(lead: Double, tone: Double, tail: Double, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let total = AVAudioFrameCount((lead + tone + tail) * 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total)!
        buffer.frameLength = total
        let a = Int(lead * 44_100), z = Int((lead + tone) * 44_100)
        for ch in 0..<2 { for i in 0..<Int(total) { buffer.floatChannelData![ch][i] = (a..<z).contains(i) ? 0.2 * sin(Float(i) * 0.06) : 0 } }
        try file.write(from: buffer)
        return url
    }

    func testAudibleRangeSkipsSilence() throws {
        let url = try makePaddedTone(lead: 1.0, tone: 1.0, tail: 2.0, name: "range")
        defer { try? FileManager.default.removeItem(at: url) }
        let r = audibleRange(of: try AVAudioFile(forReading: url))
        XCTAssertEqual(Double(r.start) / 44_100, 1.0, accuracy: 0.01)
        XCTAssertEqual(Double(r.end) / 44_100, 2.0, accuracy: 0.01)
    }

    func testRealCrossfadeStartsNextTrackBeforeTheSilentTail() throws {
        // 1.5 s of sound followed by 3 s of silence: without trimming there would be a long gap.
        let urls = [try makePaddedTone(lead: 0.5, tone: 1.5, tail: 3.0, name: "a"),
                    try makePaddedTone(lead: 0.5, tone: 1.5, tail: 3.0, name: "b")]
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let backend = EngineBackend(fadeSeconds: 0.5, muted: true)
        let player = MusicPlayer(backend: backend, volumePercent: 25)
        player.play(Playlist(name: "Test", tracks: urls), weight: 1)
        XCTAssertTrue(player.isPlaying)
        let first = player.currentTrack
        let started = Date()
        let switched = expectation(description: "next track started during the first one's sound")
        var elapsed = 0.0
        player.onChange = {
            if player.currentTrack != first, elapsed == 0 { elapsed = Date().timeIntervalSince(started); switched.fulfill() }
        }
        wait(for: [switched], timeout: 4)
        // Audible part is 1.5 s; the fade (0.5 s) should begin about 1.0 s in, long before the 5 s file ends.
        XCTAssertLessThan(elapsed, 1.6)
        XCTAssertGreaterThan(elapsed, 0.6)
        player.stop()
        XCTAssertFalse(player.isPlaying)
    }

    func testRealResumeStartsPausedAtThePositionAndPlaysOnFromThere() throws {
        let url = try makeTone(seconds: 3, name: "resume")
        defer { try? FileManager.default.removeItem(at: url) }
        let backend = EngineBackend(fadeSeconds: 0.5, muted: true)
        let player = MusicPlayer(backend: backend, volumePercent: 25)
        player.cue(Playlist(name: "Test", tracks: [url]), weight: 1, resuming: url, at: 1.5)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.progress?.elapsed ?? -1, 1.5, accuracy: 0.05)
        player.togglePause()
        XCTAssertTrue(player.isPlaying)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let elapsed = player.progress?.elapsed ?? 0
        XCTAssertGreaterThan(elapsed, 1.6, "continues after the saved position")
        XCTAssertLessThan(elapsed, 2.5)
        player.stop()
    }

    func testRealPauseKeepsThePosition() throws {
        let url = try makeTone(seconds: 3, name: "pause")
        defer { try? FileManager.default.removeItem(at: url) }
        let backend = EngineBackend(fadeSeconds: 0.5, muted: true)
        let player = MusicPlayer(backend: backend, volumePercent: 25)
        player.play(Playlist(name: "Test", tracks: [url]), weight: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        player.togglePause()
        XCTAssertFalse(player.isPlaying)
        let paused = player.progress?.elapsed ?? 0
        XCTAssertGreaterThan(paused, 0.4, "a paused track reports where it stopped, not 0")
        XCTAssertEqual(player.resumePoint?.elapsed ?? 0, paused, accuracy: 0.01)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(player.progress?.elapsed ?? 0, paused, accuracy: 0.01, "and stays there while paused")
        player.togglePause()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertGreaterThan(player.progress?.elapsed ?? 0, paused + 0.15, "then plays on from there")
        player.stop()
    }

    func testRealSeekMovesPositionWithinTheTrack() throws {
        let url = try makePaddedTone(lead: 0, tone: 30, tail: 0, name: "seek")
        defer { try? FileManager.default.removeItem(at: url) }
        let player = MusicPlayer(backend: EngineBackend(muted: true), volumePercent: 10)
        player.play(Playlist(name: "Seek", tracks: [url]), weight: 1)
        let done = expectation(description: "seeked")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            player.seek(by: 10)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let e = player.progress?.elapsed ?? 0
                XCTAssertGreaterThan(e, 9.5); XCTAssertLessThan(e, 12)
                player.seek(by: -10)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    XCTAssertLessThan(player.progress?.elapsed ?? 99, 2.5)
                    done.fulfill()
                }
            }
        }
        wait(for: [done], timeout: 3)
        player.stop()
    }

    func testMutedEngineIsSilentButStillPlays() throws {
        let url = try makePaddedTone(lead: 0, tone: 2, tail: 0, name: "muted")
        defer { try? FileManager.default.removeItem(at: url) }
        let backend = EngineBackend(muted: true)
        let player = MusicPlayer(backend: backend, volumePercent: 100)
        player.play(Playlist(name: "Muted", tracks: [url]), weight: 1)
        XCTAssertTrue(player.isPlaying, "still plays and times normally")
        XCTAssertEqual(backend.outputLevel, 0, "nothing reaches the speakers")
        XCTAssertFalse(EngineBackend().isMuted)
        player.stop()
    }

    func testUnreadableFileThrows() {
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID().uuidString).mp3")
        try? "not audio".write(to: bad, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bad) }
        XCTAssertThrowsError(try EngineBackend(muted: true).load(bad))
    }
}
