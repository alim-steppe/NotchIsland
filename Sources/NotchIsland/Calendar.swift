import AppKit
import EventKit
import SwiftUI

// MARK: - Модели

struct EventItem: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: Color
    let account: String
    let meetingURL: URL?

    var isNow: Bool { start <= Date() && end > Date() }
}

struct CalendarInfo: Identifiable {
    let id: String
    let title: String
    let color: Color
}

struct AccountGroup: Identifiable {
    let id: String
    let title: String
    let calendars: [CalendarInfo]
}

// MARK: - Сервис

/// Берёт события из календарей macOS (туда подключаются Google-аккаунты
/// через «Учётные записи интернета») и фильтрует по выбранным аккаунтам.
@MainActor
final class CalendarService: ObservableObject {
    private let store = EKEventStore()
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    @Published private(set) var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var events: [EventItem] = []
    @Published private(set) var accounts: [AccountGroup] = []

    @Published var disabledSources: Set<String> {
        didSet { persist(); reload() }
    }
    @Published var disabledCalendars: Set<String> {
        didSet { persist(); reload() }
    }

    var hasAccess: Bool { status == .fullAccess }

    init() {
        let d = UserDefaults.standard
        disabledSources = Set(d.stringArray(forKey: "cal.disabledSources") ?? [])
        disabledCalendars = Set(d.stringArray(forKey: "cal.disabledCalendars") ?? [])

        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }

        if status == .notDetermined {
            requestAccess()
        } else {
            reload()
        }
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.reload()
            }
        }
    }

    func requestAccessOrOpenSettings() {
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            requestAccess()
        } else {
            Links.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        }
    }

    // MARK: Выбор аккаунтов/календарей

    func isSourceEnabled(_ id: String) -> Bool { !disabledSources.contains(id) }
    func isCalendarEnabled(_ id: String) -> Bool { !disabledCalendars.contains(id) }

    func setSource(_ id: String, enabled: Bool) {
        if enabled { disabledSources.remove(id) } else { disabledSources.insert(id) }
    }

    func setCalendar(_ id: String, enabled: Bool) {
        if enabled { disabledCalendars.remove(id) } else { disabledCalendars.insert(id) }
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(Array(disabledSources), forKey: "cal.disabledSources")
        d.set(Array(disabledCalendars), forKey: "cal.disabledCalendars")
    }

    private static func sourceID(_ cal: EKCalendar) -> String {
        cal.source?.sourceIdentifier ?? "local"
    }

    private static func color(_ cal: EKCalendar) -> Color {
        if let cg = cal.cgColor { return Color(cgColor: cg) }
        return .gray
    }

    // MARK: Загрузка событий

    func reload() {
        status = EKEventStore.authorizationStatus(for: .event)
        guard hasAccess else {
            events = []
            accounts = []
            return
        }

        let calendars = store.calendars(for: .event)
        let grouped = Dictionary(grouping: calendars, by: { Self.sourceID($0) })
        accounts = grouped.map { sid, cals in
            AccountGroup(
                id: sid,
                title: cals.first?.source?.title ?? "Аккаунт",
                calendars: cals
                    .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                    .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, color: Self.color($0)) }
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        let enabled = calendars.filter {
            isCalendarEnabled($0.calendarIdentifier) && isSourceEnabled(Self.sourceID($0))
        }
        guard !enabled.isEmpty else {
            events = []
            return
        }

        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: 2, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: enabled)
        let now = Date()

        events = store.events(matching: predicate)
            .filter { ev in
                guard ev.endDate > now, ev.status != .canceled else { return false }
                // Скрываем встречи, от которых я отказался.
                if let me = ev.attendees?.first(where: { $0.isCurrentUser }),
                   me.participantStatus == .declined {
                    return false
                }
                return true
            }
            .sorted { a, b in
                if a.startDate != b.startDate { return a.startDate < b.startDate }
                return a.isAllDay && !b.isAllDay
            }
            .map { ev in
                EventItem(
                    id: "\(ev.calendarItemIdentifier)-\(ev.startDate.timeIntervalSince1970)",
                    title: ev.title ?? "Без названия",
                    start: ev.startDate,
                    end: ev.endDate,
                    isAllDay: ev.isAllDay,
                    color: Self.color(ev.calendar),
                    account: ev.calendar.source?.title ?? ev.calendar.title,
                    meetingURL: Self.meetingURL(for: ev)
                )
            }
    }

    /// Ближайшая встреча (через ≤30 мин или идёт не больше 10 мин) — для «ушек».
    var soonEvent: EventItem? {
        let now = Date()
        return events.first { ev in
            guard !ev.isAllDay else { return false }
            let diff = ev.start.timeIntervalSince(now)
            return (diff > 0 && diff <= 30 * 60) || (diff <= 0 && diff > -10 * 60)
        }
    }

    // MARK: Ссылки на Meet / Zoom / Teams

    private static let linkRegex = try! NSRegularExpression(
        pattern: #"https?://(?:meet\.google\.com/[a-z0-9-]+|[a-z0-9.-]*zoom\.us/(?:j|my)/[^\s<>"]+|teams\.microsoft\.com/l/meetup-join/[^\s<>"]+|teams\.live\.com/meet/[^\s<>"]+)"#,
        options: [.caseInsensitive]
    )

    private static func meetingURL(for ev: EKEvent) -> URL? {
        let texts = [ev.url?.absoluteString, ev.location, ev.notes].compactMap { $0 }
        for text in texts {
            let range = NSRange(text.startIndex..., in: text)
            if let match = linkRegex.firstMatch(in: text, range: range),
               let r = Range(match.range, in: text) {
                return URL(string: String(text[r]))
            }
        }
        return nil
    }
}

// MARK: - Вкладка

private struct DaySection: Identifiable {
    let title: String
    let items: [EventItem]
    var id: String { title }
}

struct CalendarTabView: View {
    @EnvironmentObject var calendar: CalendarService
    @EnvironmentObject var model: IslandModel

    var body: some View {
        if !calendar.hasAccess {
            EmptyStateView(
                icon: "calendar.badge.exclamationmark",
                title: "Нет доступа к календарю",
                subtitle: "Разреши доступ, затем выбери нужные аккаунты в настройках."
            ) {
                Button("Разрешить доступ") { calendar.requestAccessOrOpenSettings() }
                    .buttonStyle(PillButtonStyle())
            }
        } else if calendar.events.isEmpty {
            EmptyStateView(
                icon: "checkmark.circle",
                title: "Встреч больше нет",
                subtitle: "Сегодня и завтра свободно — или выбранные календари пусты."
            ) {
                Button("Выбрать аккаунты") { model.openSettings() }
                    .buttonStyle(PillButtonStyle())
            }
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(sections) { section in
                        Text(section.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.45))
                            .padding(.top, 2)
                        ForEach(section.items) { ev in
                            EventRow(event: ev)
                        }
                    }
                }
            }
        }
    }

    private var sections: [DaySection] {
        let cal = Calendar.current
        let now = Date()
        let today = calendar.events.filter { cal.isDateInToday($0.start) || $0.start < now }
        let tomorrow = calendar.events.filter { cal.isDateInTomorrow($0.start) }
        return [DaySection(title: "Сегодня", items: today),
                DaySection(title: "Завтра", items: tomorrow)]
            .filter { !$0.items.isEmpty }
    }
}

struct EventRow: View {
    let event: EventItem

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(event.color)
                .frame(width: 4, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let badge {
                Text(badge.text)
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(badge.color.opacity(0.22)))
                    .foregroundStyle(badge.color)
            }

            if let url = event.meetingURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Войти", systemImage: "video.fill")
                }
                .buttonStyle(PillButtonStyle(color: .green, foreground: .black))
                .help(url.absoluteString)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(event.isNow ? 0.13 : 0.06))
        )
    }

    private var subtitle: String {
        let time: String
        if event.isAllDay {
            time = "Весь день"
        } else {
            let s = event.start.formatted(date: .omitted, time: .shortened)
            let e = event.end.formatted(date: .omitted, time: .shortened)
            time = "\(s)–\(e)"
        }
        return "\(time) · \(event.account)"
    }

    private var badge: (text: String, color: Color)? {
        if event.isAllDay { return nil }
        if event.isNow { return ("Идёт", .green) }
        let diff = event.start.timeIntervalSinceNow
        if diff > 0 && diff < 60 * 60 {
            return ("через \(Int((diff / 60).rounded(.up))) мин", .orange)
        }
        return nil
    }
}
