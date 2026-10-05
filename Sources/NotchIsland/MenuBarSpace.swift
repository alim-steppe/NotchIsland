import AppKit
import ApplicationServices

/// Определяет, свободна ли полоса меню-бара слева и справа от выреза
/// в пределах ширины раскрытого островка.
/// Если свободна — островок раскрывается «целиком» от верхнего края экрана,
/// если там меню приложения или значки — только узкой «шейкой» под вырезом.
enum MenuBarSpace {
    /// Есть ли разрешение «Универсальный доступ» (нужно, чтобы узнать, где кончаются меню приложения).
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Показывает системный запрос на «Универсальный доступ».
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// (слева свободно, справа свободно) для островка шириной `islandWidth` на экране `screen`.
    static func freeSides(screen: NSScreen, islandWidth: CGFloat, menuBarHeight: CGFloat) -> (left: Bool, right: Bool) {
        // Координаты CG: начало в левом верхнем углу основного экрана.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let top = primaryHeight - screen.frame.maxY
        let midX = screen.frame.midX
        let islandLeft = midX - islandWidth / 2
        let islandRight = midX + islandWidth / 2
        let barRange = (top - 1)...(top + menuBarHeight + 1)

        // Слева: где заканчиваются меню активного приложения.
        // Без разрешения узнать нельзя — считаем, что занято (безопасный вариант).
        var leftFree = false
        if let menusEnd = appMenusMaxX(barRange: barRange, screen: screen) {
            leftFree = menusEnd < islandLeft - 4
        }

        // Справа: самый левый значок в меню-баре (часы, Wi‑Fi, значки приложений).
        let statusStart = statusItemsMinX(barRange: barRange, midX: midX, screen: screen) ?? .infinity
        let rightFree = statusStart > islandRight + 4

        return (leftFree, rightFree)
    }

    /// Правый край последнего пункта меню активного приложения (через Accessibility).
    private static func appMenusMaxX(barRange: ClosedRange<CGFloat>, screen: NSScreen) -> CGFloat? {
        guard hasAccessibility, let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBarValue = menuBarRef, CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else { return nil }
        let menuBar = menuBarValue as! AXUIElement

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let items = childrenRef as? [AXUIElement] else { return nil }

        var maxX: CGFloat = screen.frame.minX
        for item in items {
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let posValue = posRef, let sizeValue = sizeRef,
                  CFGetTypeID(posValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { continue }
            var pos = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
            // Только пункты в полосе меню-бара этого экрана и с ненулевой шириной.
            guard size.width > 0, barRange.contains(pos.y),
                  pos.x >= screen.frame.minX, pos.x < screen.frame.maxX else { continue }
            maxX = max(maxX, pos.x + size.width)
        }
        return maxX
    }

    /// Левый край самого левого значка справа в меню-баре (окна уровня «status bar»).
    private static func statusItemsMinX(barRange: ClosedRange<CGFloat>, midX: CGFloat, screen: NSScreen) -> CGFloat? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        var minX: CGFloat?
        for window in info {
            guard (window[kCGWindowLayer as String] as? Int) == statusLevel,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  b.width > 0, b.width < 400,
                  barRange.contains(b.minY),
                  b.minX > midX, b.minX < screen.frame.maxX else { continue }
            minX = min(minX ?? b.minX, b.minX)
        }
        return minX
    }
}
