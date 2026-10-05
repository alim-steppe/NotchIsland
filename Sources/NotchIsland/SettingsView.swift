import AppKit
import Combine
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var calendar: CalendarService
    @EnvironmentObject var shelf: ScreenshotService
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(IslandPrefs.hideInFullscreen) private var hideInFullscreen = true
    @State private var axGranted = MenuBarSpace.hasAccessibility

    var body: some View {
        Form {
            Section {
                if !calendar.hasAccess {
                    HStack {
                        Text("Нет доступа к календарю")
                        Spacer()
                        Button("Разрешить") { calendar.requestAccessOrOpenSettings() }
                    }
                } else if calendar.accounts.isEmpty {
                    Text("Аккаунтов с календарями пока нет").foregroundStyle(.secondary)
                } else {
                    ForEach(calendar.accounts) { account in
                        Toggle(isOn: Binding(
                            get: { calendar.isSourceEnabled(account.id) },
                            set: { calendar.setSource(account.id, enabled: $0) }
                        )) {
                            Label(account.title, systemImage: "person.crop.circle.fill")
                                .fontWeight(.semibold)
                        }
                        if calendar.isSourceEnabled(account.id) {
                            ForEach(account.calendars) { cal in
                                Toggle(isOn: Binding(
                                    get: { calendar.isCalendarEnabled(cal.id) },
                                    set: { calendar.setCalendar(cal.id, enabled: $0) }
                                )) {
                                    HStack(spacing: 8) {
                                        Circle().fill(cal.color).frame(width: 9, height: 9)
                                        Text(cal.title)
                                    }
                                }
                                .padding(.leading, 24)
                            }
                        }
                    }
                }
            } header: {
                Text("Календари и аккаунты")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Корпоративный Google-аккаунт подключается в macOS: Системные настройки → Учётные записи интернета → Google → войти → включить «Календари». После этого он появится здесь, и можно выбрать, что показывать.")
                    Button("Открыть «Учётные записи интернета»") {
                        Links.open("x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Буфер скриншотов") {
                LabeledContent("Папка скриншотов") {
                    Text(shelf.screenshotFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .foregroundStyle(.secondary)
                }
                Toggle("Сохранять картинки из буфера обмена (⌃⇧⌘4)", isOn: $shelf.captureClipboard)
                HStack {
                    Button("Открыть папку") { shelf.revealFolder() }
                    Button("Очистить буфер") { shelf.clearAll() }
                }
            }

            Section("Общее") {
                Toggle("Запускать при входе в систему", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Прятать островок в полноэкранных приложениях", isOn: $hideInFullscreen)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Универсальный доступ")
                        Text(axGranted
                             ? "Есть: островок раскрывается от самого верха, когда меню приложения не мешает."
                             : "Нужен, чтобы видеть, где заканчиваются меню приложения. Без него слева островок всегда раскрывается «шейкой».")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if axGranted {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Разрешить") {
                            MenuBarSpace.requestAccessibility()
                        }
                    }
                }
                .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
                    axGranted = MenuBarSpace.hasAccessibility
                }
                Text("Наведи курсор на вырез экрана, чтобы раскрыть островок.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 600)
    }
}
