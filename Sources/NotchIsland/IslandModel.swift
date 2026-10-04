import SwiftUI

enum IslandTab: String, CaseIterable, Identifiable {
    case calendar, music, shelf, system

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .calendar: return "calendar"
        case .music: return "music.note"
        case .shelf: return "photo.on.rectangle.angled"
        case .system: return "cpu"
        }
    }

    var title: String {
        switch self {
        case .calendar: return "Календарь"
        case .music: return "Музыка"
        case .shelf: return "Скриншоты"
        case .system: return "Система"
        }
    }
}

@MainActor
final class IslandModel: ObservableObject {
    static let expandedSize = CGSize(width: 720, height: 300)

    @Published var expanded = false
    @Published var tab: IslandTab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "island.lastTab") }
    }
    @Published var notchSize = CGSize(width: 190, height: 32)
    @Published var hasNotch = true

    let calendar = CalendarService()
    let music: MusicService
    let lyrics: LyricsService
    let shelf = ScreenshotService()
    let system = SystemMonitor()

    var openSettings: () -> Void = {}

    init() {
        let music = MusicService()
        self.music = music
        self.lyrics = LyricsService(music: music)
        tab = IslandTab(rawValue: UserDefaults.standard.string(forKey: "island.lastTab") ?? "") ?? .calendar
    }

    /// Ширина «ушек» слева и справа от выреза в свёрнутом виде.
    var wingWidth: CGFloat { notchSize.height + 12 }

    /// Показывать ли ушки (играет музыка или скоро встреча).
    var showWings: Bool { music.isPlaying || calendar.soonEvent != nil }

    var collapsedWidth: CGFloat { notchSize.width + (showWings ? wingWidth * 2 : 0) }
}
