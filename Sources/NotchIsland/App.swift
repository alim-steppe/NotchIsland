import AppKit
import SwiftUI

@main
enum NotchIslandMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: IslandModel!
    private var notch: NotchController!
    private var lyricsWindow: LyricsWindowController!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        closeOtherInstances()
        model = IslandModel()
        model.openSettings = { [weak self] in self?.openSettings() }
        notch = NotchController(model: model)
        notch.show()
        lyricsWindow = LyricsWindowController(lyrics: model.lyrics)
        setupStatusItem()

    }

    /// Если Notch Island уже запущен (автозапуск + ручной запуск, объект входа добавлен дважды),
    /// закрываем старые копии. Иначе два островка рисуются друг поверх друга:
    /// текст двоится, а меню-бар перекрывает чёрная область.
    private func closeOtherInstances() {
        let me = NSRunningApplication.current.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "com.alim.notchisland"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me }
        for app in others {
            if !app.terminate() { app.forceTerminate() }
        }
        // Страховка: если копия не закрылась сама за секунду — закрываем принудительно.
        if !others.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                for app in others where !app.isTerminated { app.forceTerminate() }
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let img = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Notch Island") {
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "◉"
        }
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let reset = NSMenuItem(title: "Сбросить островок", action: #selector(resetIsland), keyEquivalent: "r")
        reset.target = self
        menu.addItem(reset)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выйти из Notch Island", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc func openSettings() {
        notch.collapseNow()
        if settingsWindow == nil {
            let view = SettingsView()
                .environmentObject(model.calendar)
                .environmentObject(model.shelf)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Notch Island — настройки"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func resetIsland() {
        notch.rebuild()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
