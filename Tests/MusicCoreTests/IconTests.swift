import AppKit
import XCTest
@testable import MusicCore

final class IconTests: XCTestCase {
    func testOurMoodsKeepTheirIcons() {
        let expected = ["Chill": "cup.and.saucer.fill", "Hip-Hop": "headphones", "Upbeat": "bolt.fill",
                        "Late Night": "moon.stars.fill", "Retro Gaming": "gamecontroller.fill",
                        "Calm": "leaf.fill", "Rock": "guitars.fill"]
        for (name, symbol) in expected { XCTAssertEqual(guessPlaylistIcon(name), symbol, name) }
    }

    func testGuessesFromWordsInTheName() {
        let cases = ["Boss Fights": "flame.fill", "Lofi Study Beats": "cup.and.saucer.fill", "Jazz Nights": "music.quarternote.3",
                     "Christmas 2026": "snowflake", "SYNTHWAVE drive": "sunset.fill", "Gym Mix": "figure.run",
                     "8-bit Adventures": "gamecontroller.fill", "Piano & Rain": "pianokeys", "Coding Session": "chevron.left.forwardslash.chevron.right",
                     "Sakura Dreams": "camera.macro", "Spooky Halloween": "eye.fill", "Space Exploration": "atom", "Epic Adventure": "flame.fill", "Late Night Lofi": "moon.stars.fill",
                     "Ocean Waves": "water.waves", "Neko": "cat.fill", "Games": "gamecontroller.fill", "drum and bass": "bolt.fill"]
        for (name, symbol) in cases { XCTAssertEqual(guessPlaylistIcon(name), symbol, name) }
    }

    func testWholeWordsOnly() {
        XCTAssertEqual(guessPlaylistIcon("Nerdwave"), defaultPlaylistIcon, "'wave' inside a word must not match")
        XCTAssertEqual(guessPlaylistIcon("Untitled Mix 3"), defaultPlaylistIcon)
        XCTAssertEqual(guessPlaylistIcon(""), defaultPlaylistIcon)
    }

    func testEveryTableSymbolExistsOnThisMac() {
        for entry in playlistIconTable {
            XCTAssertNotNil(NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil), entry.symbol)
        }
        XCTAssertNotNil(NSImage(systemSymbolName: defaultPlaylistIcon, accessibilityDescription: nil))
    }

    func testIconLineOverridesTheGuess() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "#EXTM3U\n#ICON: trophy.fill\n#WEIGHT: 90%\n/m/a.mp3\n".write(to: dir.appendingPathComponent("Chill.m3u"), atomically: true, encoding: .utf8)
        try "#EXTM3U\n/m/b.mp3\n".write(to: dir.appendingPathComponent("Rock.m3u"), atomically: true, encoding: .utf8)
        let byName = Dictionary(uniqueKeysWithValues: loadPlaylists(in: dir).map { ($0.name, $0) })
        XCTAssertEqual(byName["Chill"]!.icon, "trophy.fill")
        XCTAssertEqual(byName["Chill"]!.displayIcon, "trophy.fill")
        XCTAssertEqual(byName["Chill"]!.tracks.count, 1, "the icon line is not a track")
        XCTAssertNil(byName["Rock"]!.icon)
        XCTAssertEqual(byName["Rock"]!.displayIcon, "guitars.fill")
        XCTAssertEqual(parseIcon("#icon:  star.fill "), "star.fill")
        XCTAssertNil(parseIcon("#ICON:"))
        let e = menuEntries(for: MenuState(playlists: ["Chill"], current: nil, isPlaying: false, nowPlaying: nil,
                                           volumePercent: 25, openAtLogin: false, icons: ["Chill": "trophy.fill"]))
        XCTAssertTrue(e.contains(.playlist(name: "Chill", symbol: "trophy.fill", checked: false)))
    }
}
