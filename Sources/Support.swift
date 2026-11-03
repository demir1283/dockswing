// Ortak yardımcılar: kayıt, ayarlar, Accessibility sarmalayıcıları ve iş parçacıkları
// arasında paylaşılan durum.

import Cocoa
import ApplicationServices
import os

let bundleID = Bundle.main.bundleIdentifier ?? "com.demir1283.dockswing"

/// Tanılama kaydı. İzlemek için:
///   log stream --level debug --predicate 'subsystem == "com.demir1283.dockswing"'
let logger = Logger(subsystem: bundleID, category: "main")

// MARK: - Ayarlar

enum ToggleMode: String {
    case minimize   // Pencereleri Dock'a küçült (Windows'a en yakın davranış)
    case hide       // Uygulamayı gizle (⌘H ile aynı)
}

enum RestoreMode: String {
    case all    // Küçültülmüş tüm pencereleri geri getir
    case one    // Yalnızca bir pencereyi geri getir
    case off    // Kapalı
}

/// `UserDefaults` iş parçacığı güvenlidir; ayarlar her iki iş parçacığından da okunur.
/// `defaults write` ile yapılan değişiklikler bir sonraki tıklamada geçerli olur.
enum Settings {
    private static let d = UserDefaults.standard

    static var mode: ToggleMode {
        ToggleMode(rawValue: d.string(forKey: "mode") ?? "") ?? .minimize
    }

    static var restore: RestoreMode {
        RestoreMode(rawValue: d.string(forKey: "restore") ?? "") ?? .all
    }

    static var enabled: Bool {
        d.object(forKey: "enabled") as? Bool ?? true
    }
}

// MARK: - Accessibility yardımcıları

/// AX C API'leri iş parçacığı güvenlidir; bu yardımcılar hem olay dinleyici iş
/// parçacığından hem ana iş parçacığından çağrılır.
enum AX {
    /// Olay dinleyici yolundaki sorgular için: yanıt vermeyen bir uygulama
    /// tıklamayı en fazla bu kadar bekletir.
    static let quickTimeout: Float = 0.05

    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func pid(_ el: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        return pid
    }

    static func size(_ el: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &s) ? s : nil
    }

    static func app(_ pid: pid_t, timeout: Float) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, timeout)
        return el
    }

    /// Uygulamanın tüm pencereleri (alt rolden bağımsız), AX sırasıyla.
    static func windows(of pid: pid_t, timeout: Float) -> [AXUIElement] {
        attr(app(pid, timeout: timeout), kAXWindowsAttribute) ?? []
    }

    static func isStandard(_ w: AXUIElement) -> Bool {
        (attr(w, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole
    }

    static func isMinimized(_ w: AXUIElement) -> Bool {
        attr(w, kAXMinimizedAttribute) ?? false
    }

    /// Uygulamanın odaktaki penceresi tam ekran mı?
    static func focusedWindowIsFullScreen(_ pid: pid_t, timeout: Float) -> Bool {
        guard let win = element(app(pid, timeout: timeout), kAXFocusedWindowAttribute) else { return false }
        return attr(win, "AXFullScreen") ?? false
    }

    /// Tanılama için: pencerelerin alt rolleri ve küçültülme durumları.
    static func describe(_ windows: [AXUIElement]) -> String {
        if windows.isEmpty { return "yok" }
        return windows.map { w in
            let subrole: String = attr(w, kAXSubroleAttribute) ?? "-"
            return subrole + (isMinimized(w) ? " (küçültülmüş)" : "")
        }.joined(separator: ", ")
    }
}

// MARK: - Paylaşılan durum

enum DockEdge: String { case bottom, left, right }

/// Ana iş parçacığında üretilip olay dinleyici iş parçacığında okunan durum.
/// Olay dinleyici AppKit'e hiç dokunmaz; yalnızca bu kilitli anlık görüntüyü okur.
struct Snapshot {
    // Öndeki uygulama (NSWorkspace bildirimiyle güncellenir)
    var frontPID: pid_t = 0
    var frontPath: String?
    var frontName: String?

    // Dock geometrisi
    var dockPID: pid_t = 0
    var edge: DockEdge = .bottom
    var thickness: CGFloat = 120
    var geometryAt: TimeInterval = 0

    // Mission Control / App Exposé / Masaüstünü Göster açık mı?
    var missionControl = false

    // Son sol tıklamanın zamanı (systemUptime)
    var lastMouseDown: TimeInterval = 0
}

final class SharedState {
    static let shared = SharedState()

    private let lock = NSLock()
    private var value = Snapshot()

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func update(_ change: (inout Snapshot) -> Void) {
        lock.lock(); defer { lock.unlock() }
        change(&value)
    }
}

/// Karşılaştırma için normalleştirilmiş paket yolu.
func normalizedPath(_ url: URL?) -> String? {
    url?.resolvingSymlinksInPath().standardizedFileURL.path
}

var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
