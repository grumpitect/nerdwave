// Nerdwave: a menu bar music player for streamers (AppKit + SwiftUI glue around MusicCore).
import AppKit
import MusicCore
import ServiceManagement
import SwiftUI

/// Shared state for the panel, refreshed whenever the player changes.
final class AppModel: ObservableObject {
    let player: MusicPlayer
    private let volume = VolumeSetting()
    private let last = LastPlaylistSetting()
    private let historyStore = HistoryStore()
    private let resumeStore = ResumeStore()
    private var resumeTimer: Timer?
    @Published var entries: [MenuEntry] = []
    @Published var volumePercent: Int
    @Published var current: String?
    @Published var nowPlaying: String?
    @Published var isPlaying = false
    @Published var time = ""
    @Published var scanStatus: String?
    var onQuit: (() -> Void)?
    /// Called before the folder picker opens (the panel closes so the picker can take focus).
    var onWillPickFolder: (() -> Void)?
    var showWelcome: (() -> Void)?
    /// Closes the menu panel (used after opening a link).
    var closePanel: (() -> Void)?
    /// Called after every refresh (the menu bar icon follows playing/scanning state).
    var onRefresh: (() -> Void)?

    /// Opens a link in the browser and closes the panel.
    func open(_ url: URL) {
        closePanel?()
        NSWorkspace.shared.open(url)
    }
    var hasPlaylists: Bool { !loadPlaylists(in: AppPaths.playlists).isEmpty }

    init() {
        volumePercent = volume.percent
        let store = historyStore
        player = MusicPlayer(backend: EngineBackend(), volumePercent: volume.percent, history: store.load(),
                             resolve: { name in loadPlaylists(in: AppPaths.playlists).first { $0.name == name } })
        player.onHistoryChange = { store.save($0) }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.saveResumePoint() }
        RunLoop.main.add(t, forMode: .common)
        resumeTimer = t
    }

    /// Remembers the track and position (every few seconds, on pause and track changes, and at quit).
    func saveResumePoint() {
        guard let point = player.resumePoint, point != resumeStore.point else { return }
        resumeStore.point = point
    }

    func refresh() {
        current = player.current?.name
        if let name = current {
            last.name = name                                   // back/forward may switch playlists
            if let fresh = loadPlaylists(in: AppPaths.playlists).first(where: { $0.name == name }) {
                player.updateWeight(fresh.weight)              // picks up rescans and hand edits
            }
        }
        nowPlaying = player.nowPlaying
        isPlaying = player.isPlaying
        if let p = player.progress {
            func mmss(_ s: Double) -> String { String(format: "%02d:%02d", Int(s) / 60, Int(s) % 60) }
            time = "\(mmss(p.elapsed)) / \(mmss(p.total))"
        } else { time = "--:-- / --:--" }
        let lists = loadPlaylists(in: AppPaths.playlists)
        // `#ICON:` overrides, ignored when the symbol doesn't exist on this macOS (then the guess is used).
        let icons = Dictionary(lists.compactMap { p in
            p.icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil ? (p.name, $0) : nil }
        }, uniquingKeysWith: { a, _ in a })
        entries = menuEntries(for: MenuState(
            playlists: lists.map(\.name), current: current,
            isPlaying: isPlaying, nowPlaying: nowPlaying, volumePercent: volumePercent,
            openAtLogin: SMAppService.mainApp.status == .enabled, canGoBack: player.canGoBack,
            scanStatus: scanStatus, notice: player.lastError, icons: icons))
        onRefresh?()
    }

    func setVolume(_ p: Int) {
        volumePercent = p
        volume.percent = p
        player.volumePercent = p
        refresh()
    }

    func choose(_ name: String) {
        guard let playlist = loadPlaylists(in: AppPaths.playlists).first(where: { $0.name == name }) else { return }
        last.name = name
        player.play(playlist, weight: playlist.weight)
    }

    /// Restores the last playlist at launch without playing it. If the last track is still there it is loaded
    /// at the saved position, so Play resumes it; picking a playlist from the menu starts fresh instead.
    func restoreLast() {
        let lists = loadPlaylists(in: AppPaths.playlists)
        if let point = resumeStore.point, let playlist = lists.first(where: { $0.name == point.playlist }) {
            last.name = playlist.name
            player.cue(playlist, weight: playlist.weight, resuming: point.url, at: point.elapsed)
            return
        }
        guard let name = last.name, let playlist = lists.first(where: { $0.name == name }) else { return }
        player.cue(playlist, weight: playlist.weight)
    }

    /// Lets the user pick a music folder, then builds balanced playlists from it in the background.
    func pickMusicFolder() {
        guard !isScanning else { return }
        onWillPickFolder?()
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Choose your music folder"
        panel.message = "Each subfolder becomes a playlist. Nerdwave measures loudness to balance them."
        panel.prompt = "Scan"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let last = UserDefaults.standard.url(forKey: "musicFolder") { panel.directoryURL = last }
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        UserDefaults.standard.set(folder, forKey: "musicFolder")
        scan(folder)
    }

    private(set) var isScanning = false

    func scan(_ folder: URL) {
        guard !isScanning else { return }
        isScanning = true
        scanStatus = "scanning…"
        refresh()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Result<[(name: String, weight: Int, tracks: Int)], Error> = Result {
                try buildPlaylists(from: folder) { done, total in
                    DispatchQueue.main.async { self?.scanStatus = "measuring loudness \(done)/\(total)"; self?.refresh() }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isScanning = false
                switch outcome {
                case .success(let found) where found.isEmpty: self.flash("no audio files found there")
                case .success(let found): self.flash("added \(found.count) playlist\(found.count == 1 ? "" : "s")")
                case .failure: self.flash("scan failed: can't read that folder")
                }
            }
        }
    }

    /// Shows a short message in the scan row for a few seconds.
    private func flash(_ message: String) {
        scanStatus = message
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, !self.isScanning, self.scanStatus == message else { return }
            self.scanStatus = nil
            self.refresh()
        }
    }

    func openFeedback() { open(feedbackURL) }

    func togglePause() { player.togglePause() }
    func next() { player.next() }
    func previous() { player.previous() }
    func seek(_ s: Double) { player.seek(by: s); refresh() }
    func toggleLogin() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        else { try? SMAppService.mainApp.register() }
        refresh()
    }
}

// MARK: - Nerdy panel

enum Theme {
    static let bg = Color(red: 0.07, green: 0.04, blue: 0.14)
    static let text = Color(red: 0.90, green: 0.90, blue: 0.98)
    static let dim = Color(red: 0.55, green: 0.50, blue: 0.70)
    static let cyan = Color(red: 0.35, green: 0.90, blue: 1.00)
    static let magenta = Color(red: 1.00, green: 0.31, blue: 0.78)
    static let sun = Color(red: 1.00, green: 0.78, blue: 0.40)
    static let font = Font.system(size: 13, design: .monospaced)
    static let nsFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let textNS = NSColor(red: 0.90, green: 0.90, blue: 0.98, alpha: 1)
    static let dimNS = NSColor(red: 0.55, green: 0.50, blue: 0.70, alpha: 1)
    static let cyanNS = NSColor(red: 0.35, green: 0.90, blue: 1.00, alpha: 1)
    static let magentaNS = NSColor(red: 1.00, green: 0.31, blue: 0.78, alpha: 1)
}

/// A row that lights up on hover, like a selected line in a terminal UI.
struct RowButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 8).padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Theme.magenta.opacity(0.18) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hover = $0 }
    }
}

/// Square, outlined transport button that fills on hover.
struct KeyButton: View {
    let symbol: String
    let help: String
    let enabled: Bool
    var big = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: big ? 15 : 12, weight: .bold))
                .frame(width: big ? 40 : 34, height: big ? 30 : 26)
                .foregroundColor(enabled ? (hover ? Theme.bg : (big ? Theme.magenta : Theme.cyan)) : Theme.dim.opacity(0.6))
                .background(RoundedRectangle(cornerRadius: 6).fill(hover && enabled ? (big ? Theme.magenta : Theme.cyan) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(enabled ? (big ? Theme.magenta : Theme.cyan).opacity(0.7) : Theme.dim.opacity(0.35)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)              // mouse-only, like a media player: no focus ring after a click
        .disabled(!enabled)
        .help(help)
        .onHover { hover = $0 }
    }
}

struct NerdView: View {
    @ObservedObject var model: AppModel

    private func slug(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                HoverLink(text: "nerdwave", color: Theme.magenta, bold: true, url: channelURL, open: { model.open($0) })
                Spacer()
                Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"))
                    .foregroundColor(Theme.dim)
                    .help("build " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"))
            }
            let entries = model.entries
            let isPlaylist: (MenuEntry) -> Bool = { if case .playlist = $0 { return true }; return false }
            if let first = entries.firstIndex(where: isPlaylist), let last = entries.lastIndex(where: isPlaylist) {
                ForEach(Array(entries[..<first].enumerated()), id: \.offset) { _, entry in row(entry) }
                playlistList(Array(entries[first...last]))
                ForEach(Array(entries[(last + 1)...].enumerated()), id: \.offset) { _, entry in row(entry) }
            } else {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in row(entry) }
            }
        }
        .font(Theme.font)
        .foregroundColor(Theme.text)
        .padding(12)
        .frame(width: 330)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(LinearGradient(colors: [Theme.cyan, Theme.magenta], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1.2))
        .shadow(color: Theme.magenta.opacity(0.28), radius: 4)
        .padding(5)           // room for the glow
    }

    static let playlistRowHeight: CGFloat = 22
    static let visiblePlaylists = 7

    /// The playlists. More than seven scroll inside the panel: seven and a half rows show, so the cut-off row
    /// hints that there is more, and the list starts scrolled to the active playlist.
    @ViewBuilder private func playlistList(_ items: [MenuEntry]) -> some View {
        let rows = VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, entry in
                row(entry).frame(height: Self.playlistRowHeight).id(playlistName(entry))
            }
        }
        if items.count > Self.visiblePlaylists {
            ScrollViewReader { proxy in
                ScrollView(.vertical) { rows }
                    .frame(height: (CGFloat(Self.visiblePlaylists) + 0.5) * (Self.playlistRowHeight + 5) - 5)
                    .onAppear { if let c = model.current { proxy.scrollTo(c, anchor: .center) } }
            }
        } else {
            rows
        }
    }

    private func playlistName(_ entry: MenuEntry) -> String? {
        if case let .playlist(name, _, _) = entry { return name }
        return nil
    }

    @ViewBuilder private func row(_ entry: MenuEntry) -> some View {
        switch entry {
        case let .transport(playing, enabled, canGoBack):
            VStack(alignment: .center, spacing: 4) {
                Text("♪ " + (model.nowPlaying ?? (model.current != nil ? "ready: press play" : (model.hasPlaylists ? "pick a mood below" : "scan a music folder to start"))))
                    .foregroundColor(Theme.cyan).bold().lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .center)
                Text(model.time).foregroundColor(Theme.dim)
                    .frame(maxWidth: .infinity, alignment: .center)
                HStack(spacing: 6) {
                    KeyButton(symbol: "backward.end.fill", help: "Previous track", enabled: canGoBack) { model.previous() }
                    KeyButton(symbol: "gobackward.10", help: "Back 10 seconds", enabled: enabled) { model.seek(-10) }
                    KeyButton(symbol: playing ? "pause.fill" : "play.fill", help: playing ? "Pause" : "Play",
                              enabled: enabled, big: true) { model.togglePause() }
                    KeyButton(symbol: "goforward.10", help: "Forward 10 seconds", enabled: enabled) { model.seek(10) }
                    KeyButton(symbol: "forward.end.fill", help: "Next track", enabled: enabled) { model.next() }
                }.frame(maxWidth: .infinity)
            }.padding(.vertical, 4)
        case .nowPlaying:
            EmptyView()     // shown in the transport block above
        case .volume:
            HStack(spacing: 6) {
                Text("vol").foregroundColor(Theme.dim)
                VolumeBar(percent: model.volumePercent) { model.setVolume($0) }
                Text("\(model.volumePercent)%").foregroundColor(Theme.text)
                    .frame(width: 38, alignment: .trailing)
            }.padding(.vertical, 3)
        case .separator:
            DashedLine().stroke(Theme.dim.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .frame(height: 1).padding(.vertical, 5)
        case .noPlaylists:
            Text("// no playlists yet").foregroundColor(Theme.dim)
        case let .scanFolder(highlighted):
            RowButton(action: { model.pickMusicFolder() }) {
                HStack(spacing: 8) {
                    Text(highlighted ? ">" : " ").foregroundColor(Theme.magenta).bold()
                    Image(systemName: "folder.badge.plus").frame(width: 16).foregroundColor(highlighted ? Theme.magenta : Theme.cyan)
                    Text("scan_music_folder…").foregroundColor(highlighted ? Theme.magenta : Theme.text)
                    Spacer()
                }
            }
        case let .notice(text):
            HStack(spacing: 8) {
                Text(" ")
                Image(systemName: "exclamationmark.triangle.fill").frame(width: 16).foregroundColor(Theme.magenta)
                Text(text).foregroundColor(Theme.magenta).lineLimit(1)
                Spacer()
            }.padding(.horizontal, 8).padding(.vertical, 3)
        case let .scanning(status):
            HStack(spacing: 8) {
                Text(" ")
                Image(systemName: "waveform").frame(width: 16).foregroundColor(Theme.sun)
                Text(status).foregroundColor(Theme.sun).lineLimit(1)
                Spacer()
            }.padding(.horizontal, 8).padding(.vertical, 3)
        case .welcome:
            RowButton(action: { model.showWelcome?() }) {
                HStack(spacing: 8) {
                    Text(" ").bold()
                    Image(systemName: "questionmark.circle").frame(width: 16).foregroundColor(Theme.cyan)
                    Text("welcome / how_it_works")
                    Spacer()
                }
            }
        case .feedback:
            RowButton(action: { model.openFeedback() }) {
                HStack(spacing: 8) {
                    Text(" ").bold()
                    Image(systemName: "bubble.left.and.text.bubble.right").frame(width: 16).foregroundColor(Theme.cyan)
                    Text("feedback")
                    Spacer()
                    Text("github ↗").foregroundColor(Theme.dim)
                }
            }
        case let .playlist(name, symbol, checked):
            RowButton(action: { model.choose(name) }) {
                HStack(spacing: 8) {
                    Text(checked ? ">" : " ").foregroundColor(Theme.magenta).bold()
                    Image(systemName: symbol).frame(width: 16).foregroundColor(checked ? Theme.magenta : Theme.cyan)
                    Text(slug(name)).foregroundColor(checked ? Theme.magenta : Theme.text)
                    Spacer()
                    if checked {
                        Group { if model.isPlaying { PulsingDot() } else { Text("◌") } }.foregroundColor(Theme.magenta)
                    }
                }
            }
        case let .openAtLogin(on):
            RowButton(action: { model.toggleLogin() }) {
                HStack(spacing: 8) {
                    Text(on ? ">" : " ").foregroundColor(Theme.magenta).bold()
                    Image(systemName: "sun.horizon.fill").frame(width: 16).foregroundColor(on ? Theme.magenta : Theme.cyan)
                    Text("open_at_login").foregroundColor(on ? Theme.magenta : Theme.text)
                    Spacer()
                }
            }
        case .exit:
            RowButton(action: { model.onQuit?() }) {
                HStack(spacing: 8) {
                    Text(" ").bold()
                    Image(systemName: "power").frame(width: 16).foregroundColor(Theme.cyan)
                    Text("exit()")
                    Spacer()
                    Text("⌘Q").foregroundColor(Theme.dim)
                }
            }
        }
    }
}

/// The volume bar is the control: click or drag anywhere on it to set the volume.
/// Drawn as terminal-style blocks between [ ] that always fill the full width.
struct VolumeBar: View {
    let percent: Int
    let onChange: (Int) -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 3) {
            Text("[").foregroundColor(Theme.dim)
            GeometryReader { geo in
                let cell: CGFloat = 7, gap: CGFloat = 2
                let cells = max(4, Int((geo.size.width + gap) / (cell + gap)))
                let filled = Int((Double(percent) / 100 * Double(cells)).rounded())
                let step = (geo.size.width + gap) / CGFloat(cells)
                Canvas { ctx, size in
                    for i in 0..<cells {
                        let r = CGRect(x: CGFloat(i) * step, y: 3, width: step - gap, height: size.height - 6)
                        ctx.fill(Path(roundedRect: r, cornerRadius: 1),
                                 with: .color(i < filled ? Theme.sun : (hover ? Theme.sun.opacity(0.35) : Theme.dim.opacity(0.35))))
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let x = min(max(0, g.location.x), geo.size.width)
                    onChange(Int((x / max(1, geo.size.width) * 100).rounded()))
                })
            }
            Text("]").foregroundColor(Theme.dim)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 18)
        .onHover { hover = $0 }
        .help("Click or drag to set the volume")
    }
}

/// A horizontal line that always spans the panel width exactly (drawn, not typed).
struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

/// The "●" next to the playlist that is playing: fades smoothly in and out like a recording light.
/// Its brightness is computed from the clock, so nothing else in the panel animates.
struct PulsingDot: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Text("●").opacity(0.6 + 0.4 * cos(2 * .pi * t / 2.4))      // 2.4 s per fade out and back in
        }
    }
}

/// A single clickable word: no underline until hovered, pointer cursor, opens a URL.
struct HoverLink: View {
    let text: String
    let color: Color
    var bold = false
    let url: URL
    /// Opens the link; defaults to the browser.
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    @State private var hover = false
    var body: some View {
        Text(text).bold(bold).foregroundColor(color).underline(hover)
            .onHover { inside in
                hover = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onTapGesture {
                if hover { hover = false; NSCursor.pop() }      // don't leave the hand cursor behind
                open(url)
            }
            .help(url.absoluteString)
    }
}

/// Wrapping paragraph with inline links (teal, underlined only while hovered).
struct LinkedText: NSViewRepresentable {
    let segments: [(String, URL?)]
    let color: NSColor

    final class HoverTextView: NSTextView {
        private var hovered: NSRange?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
        override func mouseMoved(with event: NSEvent) {
            guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return }
            let p = convert(event.locationInWindow, from: nil)
            var range = NSRange(location: NSNotFound, length: 0)
            let i = lm.characterIndex(for: p, in: tc, fractionOfDistanceBetweenInsertionPoints: nil)
            let glyphRect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: NSRange(location: i, length: 1), actualCharacterRange: nil), in: tc)
            let onLink = i < storage.length && glyphRect.contains(p) && storage.attribute(.link, at: i, effectiveRange: &range) != nil
            setHovered(onLink ? range : nil)
        }
        override func mouseExited(with event: NSEvent) { setHovered(nil) }
        private func setHovered(_ r: NSRange?) {
            guard r != hovered, let lm = layoutManager else { return }
            if let old = hovered { lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: old) }
            if let new = r { lm.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: new) }
            hovered = r
        }
    }

    func makeNSView(context: Context) -> HoverTextView {
        let v = HoverTextView()
        v.isEditable = false
        v.isSelectable = true                    // needed for links to be clickable
        v.drawsBackground = false
        v.textContainerInset = .zero
        v.textContainer?.lineFragmentPadding = 0
        v.textContainer?.widthTracksTextView = false     // width comes from SwiftUI's proposal (sizeThatFits)
        v.isVerticallyResizable = false
        v.isHorizontallyResizable = false
        v.linkTextAttributes = [.foregroundColor: Theme.cyanNS, .cursor: NSCursor.pointingHand]
        v.selectedTextAttributes = [:]
        let text = NSMutableAttributedString()
        for (part, url) in segments {
            var attrs: [NSAttributedString.Key: Any] = [.font: Theme.nsFont, .foregroundColor: color]
            if let url { attrs[.link] = url }
            text.append(NSAttributedString(string: part, attributes: attrs))
        }
        v.textStorage?.setAttributedString(text)
        return v
    }

    func updateNSView(_ v: HoverTextView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView v: HoverTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }   // let SwiftUI propose a width
        guard let tc = v.textContainer, let lm = v.layoutManager else { return nil }
        tc.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        return CGSize(width: width, height: ceil(lm.usedRect(for: tc).height))
    }
}

/// First-launch welcome: what Nerdwave is, how it works, and a shoutout request.
struct WelcomeView: View {
    let hasPlaylists: Bool
    let onPickFolder: () -> Void
    let onClose: () -> Void

    private func step(_ n: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(n).foregroundColor(Theme.magenta).bold()
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundColor(Theme.text).bold()
                Text(detail).foregroundColor(Theme.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("nerdwave").font(.system(size: 22, weight: .bold, design: .monospaced)).foregroundColor(Theme.magenta)
                    Text("background music for your stream, from your menu bar").foregroundColor(Theme.cyan)
                }
            }
            DashedLine().stroke(Theme.dim.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 4])).frame(height: 1)
            Text("// how it works").foregroundColor(Theme.dim)
            step("01", "pick your music folder", "Each subfolder becomes a playlist (a mood). Nerdwave measures every track's loudness so all moods play at the same level.")
            step("02", "click the icon in the menu bar", "Choose a mood. Tracks shuffle forever and crossfade, skipping silent intros and endings. Want it at startup? Turn on open_at_login.")
            HStack(alignment: .top, spacing: 10) {
                Text("03").foregroundColor(Theme.magenta).bold()
                VStack(alignment: .leading, spacing: 2) {
                    Text("use music you're allowed to stream").foregroundColor(Theme.text).bold()
                    LinkedText(segments: [("Nerdwave ships with no music. ", nil), ("StreamBeats", streamBeatsURL),
                                          (" is free and stream-safe.", nil)], color: Theme.dimNS)
                }
            }
            step("04", "optional: its own OBS source", "Desktop audio already includes Nerdwave. For its own slider: Sources > + > macOS Audio Capture > Application: Nerdwave. If Nerdwave restarts while OBS is open, restart OBS.")
            DashedLine().stroke(Theme.dim.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 4])).frame(height: 1)
            HStack(alignment: .top, spacing: 10) {
                Text("<3").foregroundColor(Theme.sun).bold()
                LinkedText(segments: [("Nerdwave is free and open source, made for the ", nil), ("Nerdative", channelURL),
                                      (" channel on YouTube. If you like it, please mention Nerdative on your stream and give us a shoutout. It means a lot!", nil)],
                           color: Theme.textNS)
            }
            HStack(spacing: 8) {
                Spacer()
                if !hasPlaylists {
                    BracketButton(title: "choose music folder…", enabled: true, action: onPickFolder)
                }
                BracketButton(title: hasPlaylists ? "let's go" : "later", enabled: true, action: onClose)
            }
        }
        .font(Theme.font)
        .padding(24)
        .frame(width: 560)
        .background(Theme.bg)
    }
}

/// Outlined text button (used in the welcome window).
struct BracketButton: View {
    let title: String
    let enabled: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title)
                .foregroundColor(enabled ? (hover ? Theme.bg : Theme.cyan) : Theme.dim)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(hover && enabled ? Theme.cyan : .clear))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.cyan.opacity(0.7)))
        }
        .buttonStyle(.plain).disabled(!enabled).onHover { hover = $0 }
    }
}

/// The menu bar icon: the app artwork inside a thick rounded ring. Idle (and while the panel is open) the ring
/// is soft white. Playing: the panel border's cyan-to-magenta gradient, turning once every 2.4 s (the panel's
/// playing dot cycle). Scanning: the same, with orange in place of cyan. Each run fades in from white.
enum StatusIcon {
    enum State { case idle, playing, scanning }
    static let size = NSSize(width: 22, height: 22)
    static let period = 2.4
    static let fadeIn = 0.6
    /// Read straight from the bundle's .icns: `NSImage.applicationIconName` comes back wrapped in the
    /// system's own light frame on recent macOS, which showed up as an inner white border.
    static let appIcon: NSImage = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
        ?? (NSImage(named: NSImage.applicationIconName)?.copy() as? NSImage) ?? NSImage()
    static let ringIdle = NSColor(red: 0.90, green: 0.86, blue: 0.90, alpha: 1)
    static let ringScanning = NSColor(red: 1.00, green: 0.78, blue: 0.40, alpha: 1)

    /// `elapsed` is seconds since this animation run started; nil draws the still white ring.
    static func image(state: State, elapsed: Double?) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            let outer = rect.insetBy(dx: 1, dy: 1)
            let ring: CGFloat = 2.2
            let body = outer.insetBy(dx: ring, dy: ring)
            // Only the ring itself (even-odd), so the menu bar shows around it, not a backing fill.
            let ringPath = NSBezierPath(roundedRect: outer, xRadius: 5.5, yRadius: 5.5)
            ringPath.append(NSBezierPath(roundedRect: body, xRadius: 3.6, yRadius: 3.6))
            ringPath.windingRule = .evenOdd
            if state == .idle || elapsed == nil {
                ringIdle.setFill()
                ringPath.fill()
            } else if let elapsed {
                let fade = CGFloat(min(1, elapsed / fadeIn))
                let colors = [state == .playing ? Theme.cyanNS : ringScanning, Theme.magentaNS]
                    .map { ringIdle.blended(withFraction: fade, of: $0) ?? $0 }
                // -45 degrees is the panel's top-left to bottom-right; the gradient then turns clockwise.
                let angle = -45 - 360 * CGFloat(elapsed / period)
                NSGradient(colors: colors)?.draw(in: ringPath, angle: angle)
            }
            // Artwork without its shadow: only the rounded square body of the 1024 px icon (inset 100 px).
            let src = appIcon.size
            let crop = NSRect(x: src.width * 100 / 1024, y: src.height * 100 / 1024,
                              width: src.width * 824 / 1024, height: src.height * 824 / 1024)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: body, xRadius: 3.6, yRadius: 3.6).addClip()
            appIcon.draw(in: body, from: crop, operation: .sourceOver, fraction: state == .idle ? 0.75 : 1)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }
}

/// Borderless floating panel shown under the menu bar icon.
final class NerdPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model = AppModel()
    private var panel: NerdPanel?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var refreshTimer: Timer?
    private var welcomeWindow: NSWindow?

    private func welcomeView(close: @escaping () -> Void) -> WelcomeView {
        WelcomeView(hasPlaylists: model.hasPlaylists,
                    onPickFolder: { [weak self] in close(); self?.model.pickMusicFolder() },
                    onClose: close)
    }

    func showWelcome() {
        closePanel()
        welcomeWindow?.close()
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.backgroundColor = NSColor(red: 0.07, green: 0.04, blue: 0.14, alpha: 1)
        w.contentView = NSHostingView(rootView: welcomeView(close: { [weak w] in w?.close() }))
        w.setContentSize(w.contentView!.fittingSize)
        w.center()
        welcomeWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(true, forKey: "didShowWelcome")
    }

    // OBS's per-app audio capture (ScreenCaptureKit) only lists apps that own a window,
    // and a menu bar app owns none. This invisible, click-through 1x1 window makes the
    // app show up in OBS's "Application Audio Capture" list.
    private let captureAnchor: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.alphaValue = 0
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isExcludedFromWindowsMenu = true
        return w
    }()

    func applicationWillTerminate(_ notification: Notification) { model.saveResumePoint() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--unregister-login` removes this app from Login Items and quits (used before renaming/removing it).
        if CommandLine.arguments.contains("--unregister-login") {
            try? SMAppService.mainApp.unregister()
            print("login item status:", SMAppService.mainApp.status.rawValue)   // 0 = not registered
            exit(0)
        }
        captureAnchor.orderFrontRegardless()

        // `--scan <folder>` builds playlists from a music folder without the UI, prints the weights, and quits.
        if let i = CommandLine.arguments.firstIndex(of: "--scan"), CommandLine.arguments.indices.contains(i + 1) {
            let folder = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            do {
                let result = try buildPlaylists(from: folder) { done, total in
                    if done % 25 == 0 || done == total { print("measured \(done)/\(total)") }
                }
                for r in result { print("\(r.name): #WEIGHT: \(r.weight)% (\(r.tracks) tracks)") }
                print("playlists written to", AppPaths.playlists.path)
            } catch { print("scan failed:", error) }
            exit(0)
        }

        // `--snapshot-welcome <file.png>` renders the welcome screen and quits.
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot-welcome"), CommandLine.arguments.indices.contains(i + 1) {
            // Render through a real window and AppKit drawing, exactly as it appears on screen.
            let host = NSHostingView(rootView: welcomeView(close: {}))
            let size = host.fittingSize
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                rep.size = size                               // 2x, sharp on Retina and in the README
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            }
            exit(0)
        }

        // `--snapshot-icon <file.png>` renders the menu bar icon states (idle, playing, scanning; bright and dim).
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot-icon"), CommandLine.arguments.indices.contains(i + 1) {
            let frames: [(StatusIcon.State, Double?)] = [(.idle, nil), (.playing, 0.3), (.playing, 0.6), (.playing, 1.2), (.playing, 1.8), (.scanning, 0.6), (.scanning, 1.8)]
            let scale = 4, cell = Int(StatusIcon.size.width) * scale, gap = 8
            let width = cell * frames.count + gap * (frames.count - 1)
            if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: cell, bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0),
               let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = ctx
                NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1).setFill()
                NSRect(x: 0, y: 0, width: width, height: cell).fill()
                for (k, f) in frames.enumerated() {
                    StatusIcon.image(state: f.0, elapsed: f.1)
                        .draw(in: NSRect(x: k * (cell + gap), y: 0, width: cell, height: cell))
                }
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            }
            exit(0)
        }

        // `--snapshot <file.png>` renders the panel to an image and quits (for checking the UI without clicking).
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.indices.contains(i + 1) {
            model.restoreLast()
            model.refresh()
            print("entries:", model.entries.count, "playlists:", model.entries.filter { if case .playlist = $0 { return true }; return false }.count)
            let host = NSHostingView(rootView: NerdView(model: model))
            let size = host.fittingSize
            print("fitting size:", size)
            // Drawn through a real (offscreen) window at 2x: ImageRenderer can't draw scroll views.
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.backgroundColor = .clear
            window.isOpaque = false
            window.contentView = host
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))     // let the scroll view lay out and scroll
            if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                rep.size = size
                host.cacheDisplay(in: host.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
                }
            }
            exit(0)
        }

        if let button = statusItem.button {
            // The app icon itself, scaled to menu bar size.
            button.image = StatusIcon.image(state: .idle, elapsed: nil)
            button.imageScaling = .scaleNone
            button.toolTip = "Nerdwave"
            button.target = self
            button.action = #selector(togglePanel)
        }
        model.onQuit = { NSApp.terminate(nil) }
        model.onWillPickFolder = { [weak self] in self?.closePanel() }
        model.showWelcome = { [weak self] in self?.showWelcome() }
        model.closePanel = { [weak self] in self?.closePanel() }
        model.onRefresh = { [weak self] in self?.updateStatusIcon() }
        model.player.onChange = { [weak self] in self?.stateChanged() }


        // `--play <Playlist>` starts a playlist right away (for testing or a Stream Deck);
        // otherwise the last playlist is restored, ready to play.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--play"), args.indices.contains(i + 1) {
            model.choose(args[i + 1])
        } else {
            model.restoreLast()
        }
        stateChanged()
        if !UserDefaults.standard.bool(forKey: "didShowWelcome") { showWelcome() }
    }

    private var iconTimer: Timer?
    private var shownStillState: StatusIcon.State?

    private var iconState: StatusIcon.State {
        model.isScanning ? .scanning : (model.player.isPlaying ? .playing : .idle)
    }

    /// Turns the gradient ring while playing or scanning. When idle, or while the panel is open, the timer stops
    /// and the icon holds still with a white ring.
    private func updateStatusIcon() {
        let state = iconState
        guard state != .idle, panel?.isVisible != true else {
            iconTimer?.invalidate(); iconTimer = nil
            if shownStillState != state { statusItem.button?.image = StatusIcon.image(state: state, elapsed: nil) }
            shownStillState = state
            return
        }
        shownStillState = nil
        guard iconTimer == nil else { return }
        // Every run starts from the white ring and fades into the turning gradient, so closing the panel
        // (or starting to play) never jumps straight to color.
        let start = Date()
        let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            let s = self.iconState
            if s == .idle || self.panel?.isVisible == true { self.updateStatusIcon(); return }
            self.statusItem.button?.image = StatusIcon.image(state: s, elapsed: Date().timeIntervalSince(start))
        }
        RunLoop.main.add(t, forMode: .common)
        iconTimer = t
    }

    private func stateChanged() {
        model.refresh()
        model.saveResumePoint()
        updateStatusIcon()
        resizePanel()
    }

    @objc private func togglePanel() {
        if panel?.isVisible == true { closePanel() } else { openPanel() }
    }

    private func openPanel() {
        closePanel()                        // never stack monitors or timers
        model.refresh()
        let p = panel ?? makePanel()
        panel = p
        resizePanel()
        p.orderFrontRegardless()
        p.makeKey()
        // Clicks outside close the panel, except on our own menu bar icon: that click reaches togglePanel,
        // which closes it (closing here first would make the toggle reopen it).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            if let frame = self.statusItem.button?.window?.frame, frame.contains(NSEvent.mouseLocation) { return }
            self.closePanel()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.closePanel(); return nil }                         // Esc
            if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "q" { NSApp.terminate(nil) }
            return e
        }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.model.refresh() }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
        updateStatusIcon()
    }

    private func closePanel() {
        panel?.orderOut(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil; keyMonitor = nil
        refreshTimer?.invalidate(); refreshTimer = nil
        updateStatusIcon()
    }

    private func makePanel() -> NerdPanel {
        let p = NerdPanel(contentRect: NSRect(x: 0, y: 0, width: 350, height: 460),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: NerdView(model: model))
        return p
    }

    /// Fits the panel to its content and keeps it just under the menu bar icon.
    private func resizePanel() {
        guard let p = panel, let hosting = p.contentView, let button = statusItem.button,
              let bwin = button.window else { return }
        let size = hosting.fittingSize
        let b = bwin.frame
        let screen = bwin.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = b.midX - size.width / 2
        x = min(max(x, screen.minX + 4), screen.maxX - size.width - 4)
        p.setFrame(NSRect(x: x, y: b.minY - size.height + 6, width: size.width, height: size.height), display: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
