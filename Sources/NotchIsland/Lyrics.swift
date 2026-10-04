import AppKit
import Combine
import SwiftUI

// MARK: - Модели

struct LyricLine: Identifiable, Sendable {
    let id: Int
    let time: Double?
    let text: String
}

struct LyricsResult: Sendable {
    let lines: [LyricLine]
    let synced: Bool
    let instrumental: Bool
}

enum LyricsState {
    case idle, loading, loaded, notFound, instrumental
}

// MARK: - Загрузка текста (LRCLIB — открытая база текстов с таймкодами)

enum LyricsFetcher {
    private struct Entry: Decodable {
        let plainLyrics: String?
        let syncedLyrics: String?
        let instrumental: Bool?
        let duration: Double?
    }

    static func fetch(title: String, artist: String, album: String, duration: Double) async -> LyricsResult? {
        // 1. Точное совпадение по названию, артисту, альбому и длительности.
        var exact = URLComponents(string: "https://lrclib.net/api/get")!
        exact.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded())))
        ]
        if let url = exact.url, let entry: Entry = await get(url), let result = makeResult(entry) {
            return result
        }

        // 2. Поиск по названию и первому артисту (для фитов вроде «A & B»).
        let mainArtist = artist
            .components(separatedBy: CharacterSet(charactersIn: "&,"))
            .first?
            .components(separatedBy: " feat")
            .first?
            .trimmingCharacters(in: .whitespaces) ?? artist
        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: mainArtist)
        ]
        guard let url = search.url, let entries: [Entry] = await get(url), !entries.isEmpty else { return nil }

        let close = entries.filter { e in
            guard let d = e.duration, duration > 0 else { return true }
            return abs(d - duration) < 6
        }
        let pool = close.isEmpty ? entries : close
        let candidate = pool.first { !($0.syncedLyrics ?? "").isEmpty }
            ?? pool.first { !($0.plainLyrics ?? "").isEmpty }
            ?? pool.first
        return candidate.flatMap { makeResult($0) }
    }

    private static func get<T: Decodable>(_ url: URL) async -> T? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("NotchIsland/1.0 (macOS widget)", forHTTPHeaderField: "User-Agent")
        guard let reply = try? await URLSession.shared.data(for: request),
              let http = reply.1 as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: reply.0)
    }

    private static func makeResult(_ e: Entry) -> LyricsResult? {
        if e.instrumental == true {
            return LyricsResult(lines: [], synced: false, instrumental: true)
        }
        if let synced = e.syncedLyrics, !synced.isEmpty {
            let lines = parseLRC(synced)
            if !lines.isEmpty { return LyricsResult(lines: lines, synced: true, instrumental: false) }
        }
        if let plain = e.plainLyrics, !plain.isEmpty {
            return LyricsResult(lines: parsePlain(plain), synced: false, instrumental: false)
        }
        return nil
    }

    private static let timeTag = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:[.:]\d+)?)\]"#)

    /// Разбирает формат LRC: «[01:23.45] строка».
    static func parseLRC(_ text: String) -> [LyricLine] {
        var raw: [(Double, String)] = []
        for line in text.components(separatedBy: .newlines) {
            let ns = line as NSString
            let matches = timeTag.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            let lastEnd = matches.last!.range.location + matches.last!.range.length
            let body = ns.substring(from: lastEnd).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                raw.append((minutes * 60 + seconds, body))
            }
        }
        return raw.sorted { $0.0 < $1.0 }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }

    static func parsePlain(_ text: String) -> [LyricLine] {
        text.components(separatedBy: .newlines)
            .enumerated()
            .map { LyricLine(id: $0.offset, time: nil, text: $0.element.trimmingCharacters(in: .whitespaces)) }
    }
}

// MARK: - Сервис

@MainActor
final class LyricsService: ObservableObject {
    /// Показан ли текст (кнопка «Текст»). Выключение прячет и отдельный виджет.
    @Published var visible: Bool {
        didSet {
            UserDefaults.standard.set(visible, forKey: "lyrics.visible")
            if visible { loadIfNeeded() } else { detached = false }
        }
    }
    /// Вынесен ли текст в отдельный плавающий виджет.
    @Published var detached: Bool {
        didSet { UserDefaults.standard.set(detached, forKey: "lyrics.detached") }
    }
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var synced = false
    @Published private(set) var state: LyricsState = .idle

    let music: MusicService
    private var loadedFor = ""
    private var cache: [String: LyricsResult] = [:]
    private var task: Task<Void, Never>?
    private var cancellable: AnyCancellable?

    init(music: MusicService) {
        self.music = music
        let d = UserDefaults.standard
        visible = d.bool(forKey: "lyrics.visible")
        detached = d.bool(forKey: "lyrics.detached")
        cancellable = music.$trackID
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.loadIfNeeded() }
            }
    }

    func toggleVisible() { visible.toggle() }

    func toggleDetached() {
        if !visible { visible = true }
        detached.toggle()
    }

    func loadIfNeeded() {
        guard visible else { return }
        let id = music.trackID
        guard !id.isEmpty else {
            loadedFor = ""
            lines = []
            state = .idle
            return
        }
        guard id != loadedFor else { return }
        loadedFor = id

        if let cached = cache[id] {
            apply(cached)
            return
        }

        state = .loading
        lines = []
        let title = music.title, artist = music.artist, album = music.album, duration = music.duration
        task?.cancel()
        task = Task { [weak self] in
            var result = await LyricsFetcher.fetch(title: title, artist: artist, album: album, duration: duration)
            guard let self, !Task.isCancelled, self.loadedFor == id else { return }
            if result == nil, let embedded = self.music.embeddedLyrics() {
                result = LyricsResult(lines: LyricsFetcher.parsePlain(embedded), synced: false, instrumental: false)
            }
            if let result {
                self.cache[id] = result
                self.apply(result)
            } else {
                self.lines = []
                self.state = .notFound
            }
        }
    }

    func retry() {
        cache[loadedFor] = nil
        loadedFor = ""
        loadIfNeeded()
    }

    private func apply(_ r: LyricsResult) {
        lines = r.lines
        synced = r.synced
        state = r.instrumental ? .instrumental : (r.lines.isEmpty ? .notFound : .loaded)
    }

    /// Индекс текущей строки для синхронного текста.
    func currentIndex(at position: Double) -> Int? {
        guard synced else { return nil }
        var result: Int?
        for line in lines {
            guard let t = line.time else { continue }
            if t <= position + 0.15 { result = line.id } else { break }
        }
        return result
    }
}

// MARK: - Вид текста (общий для островка и виджета)

struct LyricsView: View {
    @EnvironmentObject var lyrics: LyricsService
    @EnvironmentObject var music: MusicService
    var fontSize: CGFloat = 14
    /// false — не обновлять (островок свёрнут и текст не виден).
    var active: Bool = true

    var body: some View {
        switch lyrics.state {
        case .idle:
            message("Ничего не играет", icon: "music.note")
        case .loading:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Ищу текст…").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notFound:
            VStack(spacing: 6) {
                message("Текст не найден", icon: "text.badge.xmark")
                Button("Попробовать ещё раз") { lyrics.retry() }
                    .buttonStyle(PillButtonStyle())
            }
        case .instrumental:
            message("Инструментал", icon: "pianokeys")
        case .loaded:
            if lyrics.synced {
                TimelineView(.animation(minimumInterval: 0.1, paused: !active)) { ctx in
                    SyncedLyricsList(
                        lines: lyrics.lines,
                        current: lyrics.currentIndex(at: music.estimatedPosition(at: ctx.date)),
                        fontSize: fontSize
                    ) { time in music.seek(to: time) }
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(lyrics.lines) { line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(size: fontSize, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func message(_ text: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(Color.white.opacity(0.4))
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LineFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Синхронный текст в стиле Apple Music: весь столбец плавно «едет» пружиной,
/// текущая строка мягко подсвечивается. Размер шрифта не меняется,
/// поэтому вёрстка не прыгает — меняются только прозрачность, масштаб и размытие.
struct SyncedLyricsList: View {
    let lines: [LyricLine]
    let current: Int?
    let fontSize: CGFloat
    let onSeek: (Double) -> Void

    @State private var frames: [Int: CGRect] = [:]

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: fontSize * 0.75) {
                ForEach(lines) { line in
                    LyricLineView(
                        text: line.text,
                        distance: line.id - (current ?? -1),
                        hasCurrent: current != nil,
                        fontSize: fontSize
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { if let t = line.time { onSeek(t) } }
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(
                                key: LineFramesKey.self,
                                value: [line.id: g.frame(in: .named("lyricsStack"))]
                            )
                        }
                    )
                }
            }
            .coordinateSpace(name: "lyricsStack")
            .onPreferenceChange(LineFramesKey.self) { frames = $0 }
            .offset(y: offset(for: geo.size.height))
            .animation(.spring(response: 0.75, dampingFraction: 0.9), value: current)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .clipped()
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.15),
                .init(color: .black, location: 0.8),
                .init(color: .clear, location: 1)
            ], startPoint: .top, endPoint: .bottom)
        )
    }

    /// Сдвиг столбца так, чтобы текущая строка стояла чуть выше центра.
    private func offset(for height: CGFloat) -> CGFloat {
        let anchor = height * 0.38
        if let c = current, let f = frames[c] { return anchor - f.midY }
        if let first = frames[0] { return anchor - first.midY + fontSize * 2 }
        return anchor
    }
}

private struct LyricLineView: View {
    let text: String
    /// 0 — текущая строка, <0 — уже спетые, >0 — следующие.
    let distance: Int
    let hasCurrent: Bool
    let fontSize: CGFloat

    var body: some View {
        let isCurrent = distance == 0
        let far = Double(min(abs(distance), 4))
        Text(text.isEmpty ? "♪" : text)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(Color.white)
            .opacity(isCurrent ? 1 : (distance < 0 ? 0.32 : max(0.42 - far * 0.04, 0.26)))
            .blur(radius: isCurrent || !hasCurrent ? 0 : 0.35 * far)
            .scaleEffect(isCurrent ? 1 : 0.95, anchor: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .animation(.easeInOut(duration: 0.55), value: distance)
    }
}

// MARK: - Отдельный плавающий виджет

/// Область, за которую можно таскать окно.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct LyricsWidgetView: View {
    @EnvironmentObject var lyrics: LyricsService
    @EnvironmentObject var music: MusicService

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ArtworkView(image: music.artwork, cornerRadius: 6)
                    .frame(width: 32, height: 32)
                    .allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 1) {
                    Text(music.title.isEmpty ? "Текст песни" : music.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(music.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .lineLimit(1)
                }
                .allowsHitTesting(false)
                Spacer(minLength: 4)
                headerButton("pip.enter", help: "Вернуть в островок") { lyrics.detached = false }
                headerButton("xmark", help: "Скрыть текст") { lyrics.visible = false }
            }
            .padding(.horizontal, 12)
            .frame(height: 52)
            .background(WindowDragArea())

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)

            LyricsView(fontSize: 16)
                .padding(.horizontal, 16)
        }
        .foregroundStyle(Color.white)
        .background(VisualEffectBackground())
        .background(Color.black.opacity(0.35))
        .environment(\.colorScheme, .dark)
    }

    private func headerButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

final class LyricsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Показывает виджет, когда текст включён и вынесен; иначе прячет.
@MainActor
final class LyricsWindowController {
    private let lyrics: LyricsService
    private var panel: LyricsPanel?
    private var cancellable: AnyCancellable?

    init(lyrics: LyricsService) {
        self.lyrics = lyrics
        cancellable = lyrics.$visible
            .combineLatest(lyrics.$detached)
            .map { pair in pair.0 && pair.1 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show in
                MainActor.assumeIsolated { self?.setShown(show) }
            }
    }

    private func setShown(_ show: Bool) {
        if show {
            let p = panel ?? makePanel()
            panel = p
            p.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }

    private func makePanel() -> LyricsPanel {
        let p = LyricsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.appearance = NSAppearance(named: .darkAqua)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.minSize = NSSize(width: 240, height: 200)

        let root = LyricsWidgetView()
            .environmentObject(lyrics)
            .environmentObject(lyrics.music)
        let host = IslandHostingView(rootView: AnyView(root))
        host.sizingOptions = []
        p.contentView = host

        // Запоминаем положение и размер между запусками.
        if !p.setFrameUsingName("LyricsWidget") {
            if let scr = NSScreen.main {
                let f = scr.visibleFrame
                p.setFrameOrigin(NSPoint(x: f.maxX - 340, y: f.maxY - 460))
            }
        }
        p.setFrameAutosaveName("LyricsWidget")
        return p
    }
}
