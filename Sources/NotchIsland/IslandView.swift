import AppKit
import SwiftUI

// MARK: - Корневой вид

struct IslandRootView: View {
    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var music: MusicService
    @EnvironmentObject var calendar: CalendarService

    var body: some View {
        let expanded = model.expanded
        let notch = model.notchSize
        let size = expanded
            ? IslandModel.expandedSize
            : CGSize(width: model.collapsedWidth, height: notch.height)
        // Раскрытый островок: узкая «шейка» шириной с вырез в полосе меню-бара
        // и широкое тело ниже меню-бара. В полосе меню-бара по бокам от выреза
        // мы ничего не рисуем — поэтому меню приложений (Chrome и т.д.)
        // больше не накладываются на островок.
        let shape = IslandShape(
            neckWidth: model.hasNotch ? notch.width : min(notch.width, size.width),
            bodyWidth: size.width,
            bodyTop: expanded ? notch.height : 0,
            topRadius: expanded ? 18 : 0,
            bottomRadius: expanded ? 26 : 10,
            leftFill: model.topLeftFree ? 1 : 0,
            rightFill: model.topRightFree ? 1 : 0
        )

        ZStack(alignment: .top) {
            shape.fill(Color.black)
            // Оба вида всегда в дереве и только меняют прозрачность —
            // так подложка и содержимое не могут «разъехаться» (пустой чёрный островок).
            ExpandedView()
                .frame(width: IslandModel.expandedSize.width, height: IslandModel.expandedSize.height)
                .scaleEffect(expanded ? 1 : 0.96, anchor: .top)
                .opacity(expanded ? 1 : 0)
                .allowsHitTesting(expanded)
            CollapsedView()
                .frame(width: size.width, height: size.height)
                .opacity(expanded ? 0 : 1)
                .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: expanded)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.showWings)
        .environment(\.colorScheme, .dark)
    }
}

/// Форма островка: «шейка» по центру сверху (под вырезом) + скруглённое тело.
/// Все параметры анимируются, поэтому свёрнутый вид плавно перетекает в раскрытый.
struct IslandShape: Shape {
    var neckWidth: CGFloat
    var bodyWidth: CGFloat
    var bodyTop: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// 1 — полоса меню-бара с этой стороны свободна, островок закрывает её до верха.
    var leftFill: CGFloat = 0
    var rightFill: CGFloat = 0

    var animatableData: AnimatablePair<AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>,
                                       AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>> {
        get {
            AnimatablePair(
                AnimatablePair(AnimatablePair(neckWidth, bodyWidth), AnimatablePair(leftFill, rightFill)),
                AnimatablePair(bodyTop, AnimatablePair(topRadius, bottomRadius))
            )
        }
        set {
            neckWidth = newValue.first.first.first
            bodyWidth = newValue.first.first.second
            leftFill = newValue.first.second.first
            rightFill = newValue.first.second.second
            bodyTop = newValue.second.first
            topRadius = newValue.second.second.first
            bottomRadius = newValue.second.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let bw = min(bodyWidth, rect.width)
        let body = CGRect(x: rect.midX - bw / 2, y: rect.minY + bodyTop,
                          width: bw, height: max(rect.height - bodyTop, 1))
        let maxR = min(body.width, body.height) / 2
        path.addRoundedRect(
            in: body,
            cornerRadii: RectangleCornerRadii(
                topLeading: min(topRadius, maxR),
                bottomLeading: min(bottomRadius, maxR),
                bottomTrailing: min(bottomRadius, maxR),
                topTrailing: min(topRadius, maxR)
            ),
            style: .continuous
        )
        if bodyTop > 0.5 {
            // Шейка заходит в тело, чтобы не было щели между ними.
            let nw = min(neckWidth, bw)
            path.addRect(CGRect(x: rect.midX - nw / 2, y: rect.minY,
                                width: nw, height: bodyTop + topRadius + 1))
        }
        // «Плечи»: если полоса меню-бара с какой-то стороны свободна,
        // островок закрывает её до верхнего края (растёт снизу вверх).
        let shoulder = bodyTop + topRadius + 1
        if bodyTop > 0.5, leftFill > 0.01 {
            let h = shoulder * min(leftFill, 1)
            path.addRect(CGRect(x: body.minX, y: rect.minY + shoulder - h,
                                width: rect.midX - body.minX, height: h))
        }
        if bodyTop > 0.5, rightFill > 0.01 {
            let h = shoulder * min(rightFill, 1)
            path.addRect(CGRect(x: rect.midX, y: rect.minY + shoulder - h,
                                width: body.maxX - rect.midX, height: h))
        }
        return path
    }
}

// MARK: - Свёрнутый вид (вырез + «ушки»)

struct CollapsedView: View {
    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var music: MusicService
    @EnvironmentObject var calendar: CalendarService

    var body: some View {
        if model.showWings {
            HStack(spacing: 0) {
                leftWing
                    .frame(width: model.wingWidth, height: model.notchSize.height)
                Spacer(minLength: 0)
                rightWing
                    .frame(width: model.wingWidth, height: model.notchSize.height)
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder private var leftWing: some View {
        if music.isPlaying {
            ArtworkView(image: music.artwork, cornerRadius: 5)
                .frame(width: model.notchSize.height - 12, height: model.notchSize.height - 12)
        } else if let ev = calendar.soonEvent {
            Image(systemName: ev.meetingURL != nil ? "video.fill" : "calendar")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ev.color)
        }
    }

    @ViewBuilder private var rightWing: some View {
        if let ev = calendar.soonEvent {
            Text(Self.countdown(ev))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.orange)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else if music.isPlaying {
            EqualizerView(playing: true)
        }
    }

    static func countdown(_ ev: EventItem) -> String {
        let diff = ev.start.timeIntervalSinceNow
        if diff <= 0 { return "сейчас" }
        return "\(Int((diff / 60).rounded(.up)))м"
    }
}

struct EqualizerView: View {
    var playing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 3,
                               height: playing ? 4 + 10 * abs(sin(t * (2.3 + Double(i) * 0.8) + Double(i))) : 4)
                }
            }
            .frame(height: 16)
        }
    }
}

// MARK: - Раскрытый вид

struct ExpandedView: View {
    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var system: SystemMonitor

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)
                .padding(.vertical, 4)
            Group {
                switch model.tab {
                case .calendar: CalendarTabView()
                case .music: MusicTabView()
                case .shelf: ShelfTabView()
                case .system: SystemTabView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, 16)
            .padding(.trailing, 18)
        }
        // Всё содержимое — ниже полосы меню-бара.
        .padding(.top, model.notchSize.height + 14)
        .padding(.bottom, 16)
        .foregroundStyle(Color.white)
    }

    /// Вертикальное меню вкладок слева.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(IslandTab.allCases) { tab in
                Button {
                    model.tab = tab
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 18)
                        Text(tab.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(model.tab == tab ? Color.white.opacity(0.16) : Color.clear)
                    )
                    .foregroundStyle(model.tab == tab ? Color.white : Color.white.opacity(0.55))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 4) {
                TimelineView(.periodic(from: .now, by: 20)) { ctx in
                    Text(ctx.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                if let level = system.battery {
                    BatteryView(level: level, charging: system.charging)
                }
            }
            .padding(.horizontal, 10)
            .allowsHitTesting(false)
        }
        .frame(width: 128)
        .padding(.leading, 12)
        .padding(.trailing, 8)
    }
}

// MARK: - Общие компоненты

struct BatteryView: View {
    let level: Int
    let charging: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: charging ? "battery.100.bolt" : symbol)
            Text("\(level)%")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(level <= 20 && !charging ? Color.red : Color.white.opacity(0.7))
    }

    private var symbol: String {
        switch level {
        case 88...: return "battery.100"
        case 63..<88: return "battery.75"
        case 38..<63: return "battery.50"
        case 13..<38: return "battery.25"
        default: return "battery.0"
        }
    }
}

struct ArtworkView: View {
    let image: NSImage?
    var cornerRadius: CGFloat = 12

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color.pink.opacity(0.8), Color.purple.opacity(0.8)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.white)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct EmptyStateView<Actions: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(Color.white.opacity(0.45))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            HStack(spacing: 8) { actions() }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(icon: String, title: String, subtitle: String) {
        self.init(icon: icon, title: title, subtitle: subtitle, actions: { EmptyView() })
    }
}

struct PillButtonStyle: ButtonStyle {
    var color: Color = Color.white.opacity(0.15)
    var foreground: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(color))
            .foregroundStyle(foreground)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

struct UsageBar: View {
    let fraction: Double
    var color: Color = .white

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule().fill(color)
                    .frame(width: geo.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

enum Links {
    static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
