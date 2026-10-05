import AppKit
import SwiftUI

/// Прозрачная панель поверх меню-бара, в которой живёт островок.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Не даём системе «подвинуть» окно ниже меню-бара.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

enum IslandPrefs {
    static let hideInFullscreen = "island.hideInFullscreen"
}

/// Хостинг, который принимает первый клик без активации приложения.
final class IslandHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchController {
    private let model: IslandModel
    private var panel: NotchPanel!
    private var screen: NSScreen?
    private var timer: Timer?
    private var hoverStart: Date?
    private var lastInside = Date.distantPast
    /// Открыто какое-то меню (меню-бар любого приложения, контекстное меню).
    private var menuOpenSince: Date?
    /// После принудительного сворачивания ждём, пока курсор уйдёт с выреза.
    private var needsExitBeforeExpand = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var shrinkWork: DispatchWorkItem?
    private var rebuildWork: DispatchWorkItem?
    /// Спрятан ли островок (полноэкранное приложение).
    private var hiddenForFullscreen = false
    private var tickCount = 0

    init(model: IslandModel) {
        self.model = model
        panel = makePanel()
    }

    // MARK: Окно

    private func makePanel() -> NotchPanel {
        let p = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.animationBehavior = .none
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false

        let root = IslandRootView()
            .environmentObject(model)
            .environmentObject(model.calendar)
            .environmentObject(model.music)
            .environmentObject(model.lyrics)
            .environmentObject(model.shelf)
            .environmentObject(model.system)
        let host = IslandHostingView(rootView: AnyView(root))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.isOpaque = false
        p.contentView = host
        return p
    }

    func show() {
        reposition()
        panel.orderFrontRegardless()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        observeMenuTracking()
        observeSystemEvents()
    }

    /// Полностью пересоздаёт окно островка. Лечит «чёрный прямоугольник»,
    /// который macOS иногда оставляет после сна, смены рабочего стола или полноэкранного режима.
    func rebuild() {
        rebuildWork?.cancel()
        shrinkWork?.cancel()
        hoverStart = nil
        needsExitBeforeExpand = true
        model.expanded = false

        let old = panel
        panel = makePanel()
        reposition()
        updateFullscreenState(force: true)
        if !hiddenForFullscreen { panel.orderFrontRegardless() }
        old?.orderOut(nil)
        old?.close()
    }

    /// Пересоздание с небольшой задержкой: события часто приходят пачкой.
    private func scheduleRebuild() {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func observeSystemEvents() {
        let ws = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]
        for name in names {
            let token = ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRebuild() }
            }
            observers.append((ws, token))
        }
        let nc = NotificationCenter.default
        let token = nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRebuild() }
        }
        observers.append((nc, token))
    }

    /// macOS рассылает эти уведомления, когда любое приложение открывает/закрывает меню.
    /// Пока меню открыто, островок свёрнут и не мешает.
    private func observeMenuTracking() {
        let center = DistributedNotificationCenter.default()
        let begin = center.addObserver(
            forName: Notification.Name("com.apple.HIToolbox.beginMenuTrackingNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Контекстное меню внутри самого островка (правый клик по скриншоту) — не сворачиваем.
                if self.model.expanded, self.isOverIslandBody(NSEvent.mouseLocation) { return }
                self.menuOpenSince = Date()
                self.needsExitBeforeExpand = true
                self.setExpanded(false)
            }
        }
        let end = center.addObserver(
            forName: Notification.Name("com.apple.HIToolbox.endMenuTrackingNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpenSince = nil }
        }
        observers.append((center, begin))
        observers.append((center, end))
    }

    // MARK: Геометрия

    /// Находит экран с вырезом (или основной) и запоминает размер выреза.
    func reposition() {
        let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        guard let scr = notched ?? NSScreen.main ?? NSScreen.screens.first else { return }
        screen = scr

        if scr.safeAreaInsets.top > 0,
           let left = scr.auxiliaryTopLeftArea,
           let right = scr.auxiliaryTopRightArea {
            model.notchSize = CGSize(width: scr.frame.width - left.width - right.width,
                                     height: scr.safeAreaInsets.top)
            model.hasNotch = true
        } else {
            let menuBar = scr.frame.maxY - scr.visibleFrame.maxY
            model.notchSize = CGSize(width: 180, height: max(26, min(menuBar, 37)))
            model.hasNotch = false
        }
        applyFrame(expanded: model.expanded)
    }

    /// Окно ровно по размеру островка — никакого невидимого запаса,
    /// который мог бы «почернеть».
    private func applyFrame(expanded: Bool) {
        guard let scr = screen else { return }
        let size: CGSize
        if expanded {
            size = IslandModel.expandedSize
        } else {
            // Максимальная ширина свёрнутого вида (с «ушками»).
            size = CGSize(width: model.notchSize.width + model.wingWidth * 2,
                          height: model.notchSize.height)
        }
        let frame = NSRect(x: (scr.frame.midX - size.width / 2).rounded(),
                           y: scr.frame.maxY - size.height,
                           width: size.width, height: size.height)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: Полноэкранные приложения

    private var hideInFullscreen: Bool {
        UserDefaults.standard.object(forKey: IslandPrefs.hideInFullscreen) as? Bool ?? true
    }

    /// Есть ли на экране с вырезом чужое окно во весь экран (видео, презентация).
    private func fullscreenWindowPresent(on scr: NSScreen) -> Bool {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return false }
        let myPid = Int(ProcessInfo.processInfo.processIdentifier)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? scr.frame.height
        let target = CGRect(x: scr.frame.minX, y: primaryHeight - scr.frame.maxY,
                            width: scr.frame.width, height: scr.frame.height)
        for window in info {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowOwnerPID as String] as? Int) != myPid,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            if abs(bounds.minX - target.minX) < 2, abs(bounds.minY - target.minY) < 2,
               abs(bounds.width - target.width) < 2, abs(bounds.height - target.height) < 2 {
                return true
            }
        }
        return false
    }

    private func updateFullscreenState(force: Bool = false) {
        guard let scr = screen else { return }
        let shouldHide = hideInFullscreen && fullscreenWindowPresent(on: scr)
        guard force || shouldHide != hiddenForFullscreen else { return }
        hiddenForFullscreen = shouldHide
        if shouldHide {
            model.expanded = false
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
        } else if !force {
            // Выход из полноэкранного режима — создаём окно заново, чтобы не было чёрной заливки.
            rebuild()
        }
    }

    // MARK: Наведение

    /// Отслеживает курсор: навёл на вырез — раскрываем, увёл — сворачиваем.
    private func tick() {
        tickCount += 1
        if tickCount % 20 == 0 { updateFullscreenState() }   // раз в секунду
        guard let scr = screen, !hiddenForFullscreen else { return }

        let mouse = NSEvent.mouseLocation
        let top = scr.frame.maxY
        let midX = scr.frame.midX
        let now = Date()

        let hotZone: NSRect
        if model.expanded {
            let s = IslandModel.expandedSize
            hotZone = NSRect(x: midX - s.width / 2 - 14, y: top - s.height - 14,
                             width: s.width + 28, height: s.height + 24)
        } else {
            // Только сам вырез, без запаса по бокам: чтобы проезд курсором
            // по меню-бару не раскрывал островок.
            let w = model.collapsedWidth
            let h = model.notchSize.height
            hotZone = NSRect(x: midX - w / 2, y: top - h, width: w, height: h + 4)
        }

        let inside = hotZone.contains(mouse)
        if inside { lastInside = now }

        // Страховка, если уведомление о закрытии меню не пришло.
        if let since = menuOpenSince, now.timeIntervalSince(since) > 30 { menuOpenSince = nil }
        let menuOpen = menuOpenSince != nil
        let mouseDown = NSEvent.pressedMouseButtons != 0
        let outsideFor = now.timeIntervalSince(lastInside)

        if !model.expanded {
            if !inside { needsExitBeforeExpand = false }
            if inside && !menuOpen && !mouseDown && !needsExitBeforeExpand {
                if hoverStart == nil { hoverStart = now }
                if let start = hoverStart, now.timeIntervalSince(start) >= 0.25 {
                    setExpanded(true)
                }
            } else {
                hoverStart = nil
            }
        } else if menuOpen {
            setExpanded(false)
        } else if !inside {
            // Во время перетаскивания (скриншот, перемотка) не схлопываем сразу,
            // но через 2 секунды вне островка — всё равно сворачиваем (страховка от «залипшей» кнопки).
            if (!mouseDown && outsideFor > 0.35) || outsideFor > 2 {
                setExpanded(false)
            }
        }
    }

    /// Курсор над телом раскрытого островка, ниже полосы меню.
    private func isOverIslandBody(_ p: NSPoint) -> Bool {
        guard let scr = screen else { return false }
        let s = IslandModel.expandedSize
        let top = scr.frame.maxY - model.notchSize.height
        let body = NSRect(x: scr.frame.midX - s.width / 2, y: scr.frame.maxY - s.height,
                          width: s.width, height: s.height - model.notchSize.height)
        return body.contains(p) && p.y < top
    }

    /// Свернуть сразу (например, при открытии настроек), не раскрываясь,
    /// пока курсор не покинет вырез.
    func collapseNow() {
        needsExitBeforeExpand = true
        setExpanded(false)
    }

    private func setExpanded(_ value: Bool) {
        hoverStart = nil
        guard model.expanded != value else { return }
        shrinkWork?.cancel()

        if value {
            // Смотрим, свободна ли полоса меню-бара по бокам от выреза.
            if let scr = screen, model.hasNotch {
                let free = MenuBarSpace.freeSides(screen: scr,
                                                  islandWidth: IslandModel.expandedSize.width,
                                                  menuBarHeight: model.notchSize.height)
                model.topLeftFree = free.left
                model.topRightFree = free.right
            } else {
                model.topLeftFree = false
                model.topRightFree = false
            }
            // Сначала окно становится большим, потом островок плавно растёт внутри него.
            applyFrame(expanded: true)
            panel.ignoresMouseEvents = false
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        } else {
            panel.ignoresMouseEvents = true
            // Окно уменьшаем после того, как анимация сворачивания закончится.
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.model.expanded else { return }
                    self.applyFrame(expanded: false)
                }
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }

        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            model.expanded = value
        }
    }
}
