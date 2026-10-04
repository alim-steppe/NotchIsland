import AppKit
import SwiftUI

enum AppleScript {
    /// Выполняет AppleScript. Код -1743 = нет разрешения в «Автоматизации».
    @discardableResult
    static func run(_ source: String, permissionDenied: inout Bool) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            if let code = error[NSAppleScript.errorNumber] as? Int, code == -1743 {
                permissionDenied = true
            }
            return nil
        }
        permissionDenied = false
        return result
    }
}

@MainActor
final class MusicService: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isPlaying = false
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var duration: Double = 0
    @Published private(set) var position: Double = 0 {
        didSet { positionDate = Date() }
    }
    /// Меняется при смене трека (нужно для подгрузки текста песни).
    @Published private(set) var trackID = ""
    private(set) var positionDate = Date()
    @Published private(set) var artwork: NSImage?
    @Published private(set) var permissionDenied = false

    private static let bundleID = "com.apple.Music"
    private var trackKey = ""
    private var tickCount = 0
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    init() {
        // Music шлёт это уведомление при смене трека / паузе.
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        refresh()
    }

    private var musicIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    private func tick() {
        tickCount += 1
        if tickCount % 3 == 0 {
            refresh()
        } else if isPlaying {
            // Без скачков: берём ту же оценку, что и текст песни.
            position = estimatedPosition(at: Date())
        }
    }

    func refresh() {
        // Проверяем заранее, чтобы AppleScript не запускал Music сам.
        guard musicIsRunning else {
            reset(running: false)
            return
        }
        isRunning = true

        let script = """
        tell application "Music"
            set ps to (player state as string)
            if ps is "stopped" then return "stopped"
            set t to current track
            set sep to (character id 31)
            return ps & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & ((duration of t) as string) & sep & ((player position) as string)
        end tell
        """
        var denied = false
        let result = AppleScript.run(script, permissionDenied: &denied)?.stringValue
        permissionDenied = denied
        guard let result else { return }

        if result == "stopped" {
            reset(running: true)
            return
        }
        let parts = result.components(separatedBy: "\u{1F}")
        guard parts.count >= 6 else { return }

        let key = parts[1] + "|" + parts[2] + "|" + parts[3]
        let wasPlaying = isPlaying
        let nowPlaying = parts[0] == "playing"
        let newPosition = Self.number(parts[5])
        let drift = abs(newPosition - estimatedPosition(at: Date()))

        isPlaying = nowPlaying
        title = parts[1]
        artist = parts[2]
        album = parts[3]
        duration = Self.number(parts[4])
        // Корректируем позицию только при заметном расхождении (перемотка, смена трека),
        // иначе текст и прогресс-бар двигаются ровно, без рывков назад.
        if !(key == trackKey && wasPlaying && nowPlaying && drift < 1.0) {
            position = newPosition
        }
        if key != trackKey {
            trackKey = key
            trackID = key
            loadArtwork()
        }
    }

    private func reset(running: Bool) {
        isRunning = running
        isPlaying = false
        title = ""
        artist = ""
        album = ""
        duration = 0
        position = 0
        artwork = nil
        trackKey = ""
        if !trackID.isEmpty { trackID = "" }
    }

    private func loadArtwork() {
        let script = """
        tell application "Music"
            if (count of artworks of current track) > 0 then return raw data of artwork 1 of current track
        end tell
        """
        var denied = false
        if let data = AppleScript.run(script, permissionDenied: &denied)?.data,
           let image = NSImage(data: data) {
            artwork = image
        } else {
            artwork = nil
        }
    }

    /// В русской локали AppleScript отдаёт дробные числа через запятую.
    private static func number(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// Позиция с учётом времени, прошедшего с последнего обновления (для синхронного текста).
    func estimatedPosition(at date: Date) -> Double {
        guard isPlaying else { return position }
        return min(position + date.timeIntervalSince(positionDate), max(duration, position))
    }

    /// Текст, сохранённый в самой медиатеке Music (если есть).
    func embeddedLyrics() -> String? {
        var denied = false
        let text = AppleScript.run("tell application \"Music\" to get lyrics of current track", permissionDenied: &denied)?.stringValue
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    // MARK: Управление

    func playPause() {
        position = estimatedPosition(at: Date())
        isPlaying.toggle()
        command("playpause")
    }

    func next() { command("next track") }
    func previous() { command("previous track") }

    func seek(to seconds: Double) {
        position = seconds
        let value = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), seconds)
        command("set player position to \(value)")
    }

    func openMusic() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    private func command(_ cmd: String) {
        var denied = false
        AppleScript.run("tell application \"Music\" to \(cmd)", permissionDenied: &denied)
        permissionDenied = denied
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.refresh()
        }
    }
}

// MARK: - Вкладка

struct MusicTabView: View {
    @EnvironmentObject var music: MusicService
    @EnvironmentObject var lyrics: LyricsService
    @EnvironmentObject var model: IslandModel

    var body: some View {
        if music.permissionDenied {
            EmptyStateView(
                icon: "lock.fill",
                title: "Нет доступа к Apple Music",
                subtitle: "Включи Notch Island → Music в Настройки → Конфиденциальность → Автоматизация."
            ) {
                Button("Открыть настройки") {
                    Links.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
                }
                .buttonStyle(PillButtonStyle())
            }
        } else if !music.isRunning {
            EmptyStateView(icon: "music.note", title: "Apple Music не запущена", subtitle: "") {
                Button("Открыть Music") { music.openMusic() }
                    .buttonStyle(PillButtonStyle())
            }
        } else if music.title.isEmpty {
            EmptyStateView(icon: "music.note.list", title: "Ничего не играет", subtitle: "") {
                Button {
                    music.playPause()
                } label: {
                    Label("Играть", systemImage: "play.fill")
                }
                .buttonStyle(PillButtonStyle())
            }
        } else {
            player
        }
    }

    /// Текст показан прямо в островке (а не в отдельном виджете).
    private var inlineLyrics: Bool { lyrics.visible && !lyrics.detached }

    private var player: some View {
        HStack(spacing: 20) {
            if inlineLyrics {
                VStack(alignment: .leading, spacing: 6) {
                    ArtworkView(image: music.artwork, cornerRadius: 14)
                        .frame(width: 128, height: 128)
                    Text(music.title)
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                    Text(music.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(width: 128)
            } else {
                ArtworkView(image: music.artwork, cornerRadius: 16)
                    .frame(width: 168, height: 168)
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
            }

            VStack(alignment: .leading, spacing: 6) {
                if inlineLyrics {
                    LyricsView(fontSize: 14, active: model.expanded)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text(music.title)
                        .font(.system(size: 18, weight: .bold))
                        .lineLimit(1)
                    Text(music.artist)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .lineLimit(1)
                    Text(music.album)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                SeekBar(value: music.position, total: music.duration) { music.seek(to: $0) }
                HStack {
                    Text(Self.time(music.position))
                    Spacer()
                    Text("-" + Self.time(max(music.duration - music.position, 0)))
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.5))

                HStack(spacing: 0) {
                    toggleButton(
                        lyrics.visible ? "quote.bubble.fill" : "quote.bubble",
                        active: lyrics.visible,
                        help: lyrics.visible ? "Скрыть текст" : "Показать текст"
                    ) { lyrics.toggleVisible() }

                    Spacer()
                    HStack(spacing: 34) {
                        controlButton("backward.fill", size: 18) { music.previous() }
                        controlButton(music.isPlaying ? "pause.fill" : "play.fill", size: 26) { music.playPause() }
                        controlButton("forward.fill", size: 18) { music.next() }
                    }
                    Spacer()

                    toggleButton(
                        lyrics.detached ? "pip.enter" : "pip.exit",
                        active: lyrics.detached,
                        help: lyrics.detached ? "Вернуть текст в островок" : "Вынести текст в отдельный виджет"
                    ) { lyrics.toggleDetached() }
                    .opacity(lyrics.visible ? 1 : 0.3)
                    .disabled(!lyrics.visible)
                }
                .padding(.top, 2)
            }
        }
    }

    private func toggleButton(_ icon: String, active: Bool, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(active ? Color.white.opacity(0.18) : Color.clear)
                )
                .foregroundStyle(active ? Color.white : Color.white.opacity(0.55))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func controlButton(_ icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 36, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func time(_ s: Double) -> String {
        let total = Int(s.isFinite ? s : 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct SeekBar: View {
    let value: Double
    let total: Double
    let onSeek: (Double) -> Void
    @State private var dragValue: Double?

    var body: some View {
        GeometryReader { geo in
            let current = dragValue ?? value
            let fraction = total > 0 ? min(max(current / total, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule().fill(Color.white)
                    .frame(width: geo.size.width * CGFloat(fraction))
            }
            .frame(height: dragValue == nil ? 5 : 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let f = min(max(g.location.x / max(geo.size.width, 1), 0), 1)
                        dragValue = Double(f) * total
                    }
                    .onEnded { _ in
                        if let v = dragValue { onSeek(v) }
                        dragValue = nil
                    }
            )
            .animation(.easeOut(duration: 0.15), value: dragValue == nil)
        }
        .frame(height: 14)
    }
}
