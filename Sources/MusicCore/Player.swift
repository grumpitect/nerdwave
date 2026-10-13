import AVFoundation
import Foundation

/// What the player needs from an audio output. The real one is `EngineBackend`;
/// tests use a fake so the player logic can be checked without sound.
public protocol AudioBackend: AnyObject {
    /// Called once per track when it is within the crossfade window of its audible end.
    var onNearEnd: (() -> Void)? { get set }
    /// Called when a track ends without a crossfade having started (for example a very short track).
    var onFinished: (() -> Void)? { get set }
    var isPlaying: Bool { get }
    /// Starts a track immediately (no fade).
    func load(_ url: URL) throws
    /// Fades from the current track into this one.
    func crossfade(to url: URL) throws
    func play()
    func pause()
    func stop()
    func setAmplitude(_ value: Float)
    /// Jumps within the current track (negative = back), staying inside its audible part.
    func seek(by seconds: Double)
    /// Elapsed and total audible seconds of the current track.
    var progress: (elapsed: Double, total: Double)? { get }
}

/// Why a backend could not play something. Only `unreadable` means the file itself is bad;
/// the others are temporary (audio device unavailable, a fade already running) and must not
/// cause tracks or history to be dropped.
public enum BackendError: Error {
    case unreadable(URL)
    case engineUnavailable(Error)
    case busy
}

public final class MusicPlayer {
    private enum Attempt { case played, skip, failed }

    private let backend: AudioBackend
    private let fileExists: (URL) -> Bool
    private let resolve: (String) -> Playlist?
    private var queue: PlayQueue<SystemRandomNumberGenerator>?
    private var weight = 1.0
    public private(set) var current: Playlist?
    public private(set) var currentTrack: URL?
    /// Set when the audio output could not start (for example no device); cleared on the next success.
    public private(set) var lastError: String?
    /// The last 1000 played tracks, across playlists, for back/forward.
    public private(set) var history: TrackHistory { didSet { onHistoryChange?(history) } }
    /// The volume slider (0 to 100%). The playlist's weight is applied on top.
    public var volumePercent: Int { didSet { applyVolume() } }
    public var onChange: (() -> Void)?
    public var onHistoryChange: ((TrackHistory) -> Void)?

    /// `resolve` finds a playlist by name; back/forward uses it when a history entry
    /// belongs to a different playlist than the one playing now.
    public init(backend: AudioBackend, volumePercent: Int = VolumeSetting.defaultPercent,
                history: TrackHistory = TrackHistory(),
                fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
                resolve: @escaping (String) -> Playlist? = { _ in nil }) {
        self.backend = backend
        self.volumePercent = volumePercent
        self.history = history
        self.fileExists = fileExists
        self.resolve = resolve
        backend.onNearEnd = { [weak self] in self?.advance(crossfade: true) }
        backend.onFinished = { [weak self] in self?.advance(crossfade: false) }
    }

    public var isPlaying: Bool { currentTrack != nil && backend.isPlaying }
    public var nowPlaying: String? { currentTrack.map(trackDisplayName) }
    public var progress: (elapsed: Double, total: Double)? { currentTrack == nil ? nil : backend.progress }
    public var canGoBack: Bool { history.canGoBack }

    /// `weight` (0 to 1) is the playlist's calibrated level relative to the one that needs the most volume.
    public func play(_ playlist: Playlist, weight: Double) {
        select(playlist, weight: weight)
        startFromQueue()
    }

    /// Selects a playlist without playing it (used to restore the last one at launch).
    /// The next Play starts it.
    public func cue(_ playlist: Playlist, weight: Double) {
        select(playlist, weight: weight)
        currentTrack = nil
        onChange?()
    }

    /// Applies a new weight for the current playlist (after a rescan) without interrupting playback.
    public func updateWeight(_ weight: Double) {
        self.weight = weight
        applyVolume()
    }

    public func togglePause() {
        guard current != nil else { return }
        if currentTrack == nil { startFromQueue(); return }       // cued (or stopped by an error): start
        if backend.isPlaying { backend.pause() } else { backend.play() }
        onChange?()
    }

    public func stop() {
        backend.stop()
        current = nil
        currentTrack = nil
        queue = nil
        onChange?()
    }

    /// Next track: forward through history first (after going back), then fresh shuffled tracks.
    public func next() { advance(crossfade: false) }

    /// Previous track from the history, switching playlist if it came from another one.
    /// Entries whose files are missing are skipped, never deleted.
    public func previous() {
        let saved = history.cursor
        while let entry = history.back() {
            switch attempt(entry, crossfade: false) {
            case .played: return
            case .skip: continue
            case .failed: history.moveCursor(to: saved); return
            }
        }
        history.moveCursor(to: saved)              // nothing earlier is playable right now
    }

    public func seek(by seconds: Double) {
        guard currentTrack != nil else { return }
        backend.seek(by: seconds)
        onChange?()
    }

    // MARK: private

    private func select(_ playlist: Playlist, weight: Double) {
        self.weight = weight
        applyVolume()                      // level is set before anything plays
        backend.stop()
        current = playlist
        queue = PlayQueue(tracks: playlist.tracks.filter(fileExists), rng: SystemRandomNumberGenerator())
    }

    private func applyVolume() {
        backend.setAmplitude(amplitude(weight: weight, percent: volumePercent))
    }

    private func advance(crossfade: Bool) {
        let saved = history.cursor
        while let entry = history.forward() {          // replaying history after going back
            switch attempt(entry, crossfade: crossfade) {
            case .played: return
            case .skip: continue
            case .failed: history.moveCursor(to: saved); return
            }
        }
        guard queue != nil else { return }
        if currentTrack != nil { queue?.advance() }
        if crossfade { crossfadeFromQueue() } else { startFromQueue() }
    }

    /// Plays a history entry. A missing or unreadable file is skipped; a device error stops trying.
    /// The playlist (and its volume) only switches once the track is known to be playable.
    private func attempt(_ entry: HistoryEntry, crossfade: Bool) -> Attempt {
        guard fileExists(entry.url) else { return .skip }
        let target = entry.playlist != current?.name ? resolve(entry.playlist) : nil
        let previousWeight = weight
        if let target { weight = target.weight; applyVolume() }
        do {
            if crossfade { try backend.crossfade(to: entry.url) } else { try backend.load(entry.url); backend.play() }
        } catch {
            if target != nil { weight = previousWeight; applyVolume() }
            if note(error) { return .skip }
            if case BackendError.engineUnavailable = error { currentTrack = nil; onChange?() }
            return .failed
        }
        if let target {
            current = target
            queue = PlayQueue(tracks: target.tracks.filter(fileExists), rng: SystemRandomNumberGenerator())
        }
        currentTrack = entry.url
        lastError = nil
        onChange?()
        return .played
    }

    private func startFromQueue() {
        if queue?.isEmpty == true, let playlist = current {     // files may have appeared (drive mounted)
            queue = PlayQueue(tracks: playlist.tracks.filter(fileExists), rng: SystemRandomNumberGenerator())
        }
        while let url = queue?.current {
            do {
                try backend.load(url)
                backend.play()
                started(url)
                return
            } catch {
                if note(error) { queue?.removeCurrent() } else { currentTrack = nil; onChange?(); return }
            }
        }
        backend.stop()                     // nothing playable: don't report "playing" over silence
        currentTrack = nil
        onChange?()
    }

    private func crossfadeFromQueue() {
        while let url = queue?.current {
            do {
                try backend.crossfade(to: url)
                started(url)
                return
            } catch {
                if note(error) { queue?.removeCurrent() } else { currentTrack = nil; onChange?(); return }
            }
        }
    }

    /// Records a failure; returns true when it was the file's fault (so the track should be dropped).
    private func note(_ error: Error) -> Bool {
        if case BackendError.unreadable = error { return true }
        if case BackendError.busy = error { return false }
        lastError = "audio output unavailable"
        return false
    }

    private func started(_ url: URL) {
        currentTrack = url
        lastError = nil
        if let name = current?.name { history.record(HistoryEntry(path: url.path, playlist: name)) }
        onChange?()
    }
}

/// Where a track's sound actually starts and ends, ignoring near-silence at either end.
public struct AudibleRange: Equatable {
    public let start: AVAudioFramePosition
    public let end: AVAudioFramePosition
}

/// Scans the first and last seconds of a file for samples louder than `threshold`
/// (default about -45 dBFS). Falls back to the whole file if nothing is found.
public func audibleRange(of file: AVAudioFile, threshold: Float = 0.0056,
                         scanSeconds: Double = 15) -> AudibleRange {
    let total = file.length
    let format = file.processingFormat
    let scan = min(total, AVAudioFramePosition(scanSeconds * format.sampleRate))
    func loud(from start: AVAudioFramePosition, count: AVAudioFramePosition, last: Bool) -> AVAudioFramePosition? {
        guard count > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return nil }
        file.framePosition = start
        guard (try? file.read(into: buf, frameCount: AVAudioFrameCount(count))) != nil,
              let data = buf.floatChannelData else { return nil }
        let n = Int(buf.frameLength), chans = Int(format.channelCount)
        let indices = last ? stride(from: n - 1, through: 0, by: -1) : stride(from: 0, through: n - 1, by: 1)
        for i in indices where (0..<chans).contains(where: { abs(data[$0][i]) > threshold }) {
            return start + AVAudioFramePosition(i)
        }
        return nil
    }
    let first = loud(from: 0, count: scan, last: false) ?? 0
    let lastLoud = loud(from: total - scan, count: scan, last: true).map { $0 + 1 } ?? total
    file.framePosition = 0
    return lastLoud > first ? AudibleRange(start: first, end: lastLoud) : AudibleRange(start: 0, end: total)
}

/// Plays through AVAudioEngine with two "decks" so tracks can overlap and crossfade.
/// AVAudioEngine renders inside this process, which OBS's per-app audio capture needs.
public final class EngineBackend: AudioBackend {
    final class Deck {
        let node = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        var file: AVAudioFile?
        var range = AudibleRange(start: 0, end: 0)
        var segmentStart: AVAudioFramePosition = 0   // where the current segment began (moves on seek)
        var sampleRate = 44_100.0
        var generation = 0
        var nearEndSent = false

        /// Current frame in the file.
        var position: AVAudioFramePosition {
            guard let nodeTime = node.lastRenderTime, let t = node.playerTime(forNodeTime: nodeTime) else { return segmentStart }
            return min(range.end, segmentStart + max(0, t.sampleTime))
        }
        /// Seconds of audible sound left.
        var remainingSeconds: Double { Double(range.end - position) / sampleRate }
    }

    public let fadeSeconds: Double
    private let engine = AVAudioEngine()
    private let decks = [Deck(), Deck()]
    private var active = 0
    private var fadeProgress: Double?          // seconds into a running crossfade
    private var fadeLength = 0.0
    private var timer: Timer?
    private var lastTick = Date()
    private var wantsPlaying = false
    private var lastPosition: AVAudioFramePosition = 0
    public var onNearEnd: (() -> Void)?
    public var onFinished: (() -> Void)?

    public init(fadeSeconds: Double = 3) {
        self.fadeSeconds = fadeSeconds
        for d in decks {
            engine.attach(d.node)
            engine.attach(d.mixer)
            engine.connect(d.mixer, to: engine.mainMixerNode, format: nil)
        }
        // The engine stops itself when the output device changes (AirPods, USB interface...):
        // restart it and continue the current track from where it was.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                               queue: .main) { [weak self] _ in self?.recoverAfterDeviceChange() }
    }

    private func recoverAfterDeviceChange() {
        let d = current
        guard let file = d.file else { return }
        let resume = wantsPlaying
        let position = lastPosition
        if fadeProgress != nil { other.generation += 1; other.node.stop(); endFade() }
        do { try engine.start() } catch { return }
        schedule(file, from: min(max(d.range.start, position), d.range.end - 1), on: d)
        if resume { d.node.play() }
    }

    private var current: Deck { decks[active] }
    private var other: Deck { decks[1 - active] }

    public var isPlaying: Bool { current.node.isPlaying }

    public func load(_ url: URL) throws {
        endFade()
        other.generation += 1
        other.node.stop()
        try start(url, on: current, volume: 1)
    }

    public func crossfade(to url: URL) throws {
        guard fadeProgress == nil else { throw BackendError.busy }
        let outgoing = current
        try start(url, on: other, volume: 0)
        active = 1 - active
        fadeLength = min(fadeSeconds, max(0.05, outgoing.remainingSeconds))
        fadeProgress = 0
    }

    public func play() {
        if !engine.isRunning {
            guard (try? engine.start()) != nil else { return }
            let d = current
            if let file = d.file {                 // the engine was stopped: requeue from where we were
                if fadeProgress != nil { other.generation += 1; other.node.stop(); endFade() }
                schedule(file, from: min(max(d.range.start, lastPosition), d.range.end - 1), on: d)
            }
        }
        guard engine.isRunning else { return }
        current.node.play()
        if fadeProgress != nil { other.node.play() }
        wantsPlaying = true
        lastTick = Date()
    }

    public func pause() {
        wantsPlaying = false
        current.node.pause()
        other.node.pause()
    }

    public func stop() {
        wantsPlaying = false
        endFade()
        for d in decks { d.generation += 1; d.node.stop() }
    }

    public func setAmplitude(_ value: Float) { engine.mainMixerNode.outputVolume = value }

    public var progress: (elapsed: Double, total: Double)? {
        let d = current
        guard d.file != nil else { return nil }
        return (Double(d.position - d.range.start) / d.sampleRate, Double(d.range.end - d.range.start) / d.sampleRate)
    }

    public func seek(by seconds: Double) {
        let d = current
        guard let file = d.file else { return }
        if fadeProgress != nil { other.generation += 1; other.node.stop(); endFade() }   // settle a running fade first
        let wasPlaying = d.node.isPlaying
        let target = d.position + AVAudioFramePosition(seconds * d.sampleRate)
        let start = min(max(d.range.start, target), d.range.end - AVAudioFramePosition(0.5 * d.sampleRate))
        schedule(file, from: max(d.range.start, start), on: d)
        d.nearEndSent = false
        if wasPlaying { d.node.play() }
    }

    private func schedule(_ file: AVAudioFile, from frame: AVAudioFramePosition, on deck: Deck) {
        deck.generation += 1
        let gen = deck.generation
        deck.node.stop()
        deck.segmentStart = frame
        if deck === current { lastPosition = frame }
        deck.node.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(max(1, deck.range.end - frame)),
                                  at: nil, completionCallbackType: .dataPlayedBack) { [weak self, weak deck] _ in
            DispatchQueue.main.async {
                guard let self, let deck, gen == deck.generation, deck === self.current,
                      self.fadeProgress == nil else { return }
                self.onFinished?()
            }
        }
    }

    private func start(_ url: URL, on deck: Deck, volume: Float) throws {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw BackendError.unreadable(url) }
        let range = audibleRange(of: file)     // skip silent lead-in and tail
        if !engine.isRunning {
            do { try engine.start() } catch { throw BackendError.engineUnavailable(error) }
        }
        deck.node.stop()
        engine.disconnectNodeOutput(deck.node)
        engine.connect(deck.node, to: deck.mixer, format: file.processingFormat)
        deck.file = file
        deck.range = range
        deck.sampleRate = file.processingFormat.sampleRate
        deck.nearEndSent = false
        deck.mixer.outputVolume = volume
        schedule(file, from: range.start, on: deck)
        deck.node.play()
        wantsPlaying = true
        startTimer()
    }

    private func startTimer() {
        guard timer == nil else { return }
        lastTick = Date()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)   // keeps running while the menu is open
        timer = t
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        if engine.isRunning, current.file != nil, current.node.isPlaying { lastPosition = current.position }
        if let p = fadeProgress {
            guard current.node.isPlaying else { return }   // paused: hold the fade
            let progress = p + dt
            let x = min(1, progress / max(0.01, fadeLength))
            current.mixer.outputVolume = Float(sin(x * .pi / 2))   // equal-power crossfade
            other.mixer.outputVolume = Float(cos(x * .pi / 2))
            if x >= 1 {
                other.generation += 1
                other.node.stop()
                current.mixer.outputVolume = 1
                fadeProgress = nil
            } else {
                fadeProgress = progress
            }
            return
        }
        let d = current
        if d.node.isPlaying, !d.nearEndSent, d.remainingSeconds <= fadeSeconds {
            d.nearEndSent = true
            onNearEnd?()
        }
    }

    private func endFade() {
        fadeProgress = nil
        for d in decks { d.mixer.outputVolume = 1 }
    }
}
