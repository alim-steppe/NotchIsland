import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Equatable {
    let url: URL
    let date: Date
    let fromClipboard: Bool
    var id: URL { url }
}

/// Файловые помощники без привязки к главному потоку.
enum ShelfFiles {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "webp"]

    static func screenshotFolder() -> URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let expanded = (path as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    static func isScreenshot(_ url: URL) -> Bool {
        // macOS помечает скриншоты этим атрибутом независимо от языка системы.
        if getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0 {
            return true
        }
        let name = url.lastPathComponent.lowercased()
        return name.hasPrefix("screenshot") || name.hasPrefix("screen shot")
            || name.hasPrefix("снимок экрана") || name.hasPrefix("cleanshot")
    }

    static func scan(folders: [(URL, Bool)], hidden: Set<String>, limit: Int) -> [ShelfItem] {
        let fm = FileManager.default
        var found: [ShelfItem] = []
        for (folder, isClipboard) in folders {
            guard let urls = try? fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in urls where imageExtensions.contains(url.pathExtension.lowercased()) {
                if hidden.contains(url.path) { continue }
                if !isClipboard && !isScreenshot(url) { continue }
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                found.append(ShelfItem(url: url, date: date, fromClipboard: isClipboard))
            }
        }
        found.sort { $0.date > $1.date }
        return Array(found.prefix(limit))
    }

    static func thumbnail(_ url: URL, maxPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    static func pruneClipboardFolder(_ folder: URL, keep: Int) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let sorted = urls.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            return a > b
        }
        for url in sorted.dropFirst(keep) {
            try? fm.removeItem(at: url)
        }
    }
}

@MainActor
final class ScreenshotService: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var thumbnails: [URL: NSImage] = [:]
    @Published private(set) var justCopied: URL?
    @Published var captureClipboard: Bool {
        didSet { UserDefaults.standard.set(captureClipboard, forKey: "shelf.captureClipboard") }
    }

    let screenshotFolder: URL
    let clipboardFolder: URL

    private var hidden: Set<String>
    private var dirSource: DispatchSourceFileSystemObject?
    private var pasteboardTimer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var ownChangeCount = -1
    private var rescanWork: DispatchWorkItem?
    private let limit = 24

    private static let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        return f
    }()

    init() {
        let d = UserDefaults.standard
        captureClipboard = d.object(forKey: "shelf.captureClipboard") as? Bool ?? true
        hidden = Set((d.stringArray(forKey: "shelf.hidden") ?? []).filter {
            FileManager.default.fileExists(atPath: $0)
        })
        screenshotFolder = ShelfFiles.screenshotFolder()

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchIsland/Clipboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        clipboardFolder = support

        watch(screenshotFolder)
        pasteboardTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPasteboard() }
        }
        rescan()
    }

    // MARK: Наблюдение за папкой

    private func watch(_ folder: URL) {
        let fd = Darwin.open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRescan() }
        }
        source.setCancelHandler { _ = Darwin.close(fd) }
        source.resume()
        dirSource = source
    }

    private func scheduleRescan() {
        rescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rescan() }
        }
        rescanWork = work
        // Небольшая задержка: macOS дописывает файл и атрибуты не мгновенно.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func rescan() {
        let folders: [(URL, Bool)] = [(screenshotFolder, false), (clipboardFolder, true)]
        let hidden = self.hidden
        let limit = self.limit
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = ShelfFiles.scan(folders: folders, hidden: hidden, limit: limit)
            Task { @MainActor [weak self] in
                self?.items = found
                self?.loadThumbnails()
            }
        }
    }

    private func loadThumbnails() {
        let current = Set(items.map(\.url))
        thumbnails = thumbnails.filter { current.contains($0.key) }
        let missing = items.map(\.url).filter { thumbnails[$0] == nil }
        guard !missing.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var result: [URL: NSImage] = [:]
            for url in missing {
                if let img = ShelfFiles.thumbnail(url, maxPixels: 400) { result[url] = img }
            }
            let ready = result
            Task { @MainActor [weak self] in
                self?.thumbnails.merge(ready) { _, new in new }
            }
        }
    }

    // MARK: Буфер обмена (⌃⇧⌘4 копирует скриншот без файла)

    private func checkPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard captureClipboard, pb.changeCount != ownChangeCount else { return }

        let types = pb.types ?? []
        guard !types.contains(.fileURL), types.contains(.png) || types.contains(.tiff) else { return }

        var data = pb.data(forType: .png)
        if data == nil, let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
            data = rep.representation(using: .png, properties: [:])
        }
        guard let png = data else { return }

        let name = "Буфер " + Self.fileDateFormatter.string(from: Date()) + ".png"
        let url = clipboardFolder.appendingPathComponent(name)
        let folder = clipboardFolder
        DispatchQueue.global(qos: .utility).async { [weak self] in
            try? png.write(to: url)
            ShelfFiles.pruneClipboardFolder(folder, keep: 30)
            Task { @MainActor [weak self] in self?.rescan() }
        }
    }

    // MARK: Действия

    func copy(_ item: ShelfItem) {
        guard let image = NSImage(contentsOf: item.url) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        ownChangeCount = pb.changeCount
        lastChangeCount = pb.changeCount
        justCopied = item.url
        let url = item.url
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if self?.justCopied == url { self?.justCopied = nil }
        }
    }

    func open(_ item: ShelfItem) {
        NSWorkspace.shared.open(item.url)
    }

    func reveal(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func revealFolder() {
        NSWorkspace.shared.open(screenshotFolder)
    }

    /// Убирает из буфера (сам файл скриншота остаётся на месте).
    func remove(_ item: ShelfItem) {
        if item.fromClipboard {
            try? FileManager.default.removeItem(at: item.url)
        } else {
            hidden.insert(item.url.path)
            saveHidden()
        }
        items.removeAll { $0 == item }
    }

    func moveToTrash(_ item: ShelfItem) {
        try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        items.removeAll { $0 == item }
    }

    func clearAll() {
        for item in items { remove(item) }
        items = []
    }

    private func saveHidden() {
        UserDefaults.standard.set(Array(hidden), forKey: "shelf.hidden")
    }
}

// MARK: - Вкладка

struct ShelfTabView: View {
    @EnvironmentObject var shelf: ScreenshotService

    var body: some View {
        if shelf.items.isEmpty {
            EmptyStateView(
                icon: "camera.viewfinder",
                title: "Буфер скриншотов пуст",
                subtitle: "Сделай скриншот (⇧⌘4, ⇧⌘5) или скопируй картинку — она появится здесь. Папка: \(shelf.screenshotFolder.lastPathComponent)"
            ) {
                Button("Открыть папку") { shelf.revealFolder() }
                    .buttonStyle(PillButtonStyle())
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Клик — скопировать · перетащи в чат или папку")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.45))
                    Spacer()
                    Button("Папка") { shelf.revealFolder() }
                        .buttonStyle(PillButtonStyle())
                    Button("Очистить") { shelf.clearAll() }
                        .buttonStyle(PillButtonStyle())
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(shelf.items) { item in
                            ShelfCard(item: item)
                        }
                    }
                }
            }
        }
    }
}

struct ShelfCard: View {
    @EnvironmentObject var shelf: ScreenshotService
    let item: ShelfItem
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                if let image = shelf.thumbnails[item.url] {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.white.opacity(0.08)
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 176, height: 118)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(hovering ? 0.45 : 0.1), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                if hovering {
                    HStack(spacing: 4) {
                        iconButton("doc.on.doc", help: "Скопировать") { shelf.copy(item) }
                        iconButton("folder", help: "Показать в Finder") { shelf.reveal(item) }
                        iconButton("xmark", help: "Убрать из буфера") { shelf.remove(item) }
                    }
                    .padding(6)
                }
            }
            .overlay {
                if shelf.justCopied == item.url {
                    Label("Скопировано", systemImage: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                }
            }

            HStack(spacing: 4) {
                if item.fromClipboard {
                    Image(systemName: "doc.on.clipboard")
                }
                Text(item.date, format: .relative(presentation: .named))
            }
            .font(.system(size: 10))
            .foregroundStyle(Color.white.opacity(0.5))
            .lineLimit(1)
        }
        .frame(width: 176)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { shelf.open(item) }
        .onTapGesture { shelf.copy(item) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Скопировать") { shelf.copy(item) }
            Button("Открыть") { shelf.open(item) }
            Button("Показать в Finder") { shelf.reveal(item) }
            Divider()
            Button("Убрать из буфера") { shelf.remove(item) }
            Button("Переместить в Корзину") { shelf.moveToTrash(item) }
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.black.opacity(0.7)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
