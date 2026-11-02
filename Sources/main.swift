// DockToggle — macOS Dock'a Windows görev çubuğu davranışı kazandırır.
//
// Öndeki (aktif) uygulamanın Dock simgesine tıklandığında uygulamanın pencereleri
// küçültülür (veya uygulama gizlenir). Diğer tüm durumlarda tıklama Dock'a olduğu
// gibi iletilir; Dock zaten uygulamayı öne getirir / küçültülmüş pencereyi geri açar.
//
// Mimari (her tıklamada, ucuzdan pahalıya):
//   1. Saf aritmetik: tıklama, Dock'un bulunduğu ekran kenarındaki şeritte mi?
//      (Sıfır IPC — tıklamaların neredeyse tamamı burada elenir.)
//   2. Tek AX sorgusu: noktadaki öğe Dock sürecine ait bir uygulama simgesi mi?
//   3. Yalnızca öndeki uygulamaysa: pencereleri küçült / gizle, tıklamayı yut.
//
// Ek olarak: ⌘Tab vb. klavyeyle öne gelen uygulamanın tüm pencereleri küçültülmüşse
// pencereler geri getirilir (ActivationRestorer).
//
// Gereken izin: Sistem Ayarları › Gizlilik ve Güvenlik › Erişilebilirlik

import Cocoa
import ApplicationServices
import os

/// Tanılama kaydı. İzlemek için:
///   log stream --level debug --predicate 'subsystem == "com.local.docktoggle"'
let logger = Logger(subsystem: "com.local.docktoggle", category: "main")

// MARK: - Ayarlar

enum ToggleMode: String {
    case minimize   // Pencereleri Dock'a küçült (Windows'a en yakın davranış)
    case hide       // Uygulamayı gizle (⌘H ile aynı)
}

enum RestoreMode: String {
    case all    // Küçültülmüş tüm pencereleri geri getir (DockToggle'ın küçültmesiyle simetrik)
    case one    // Yalnızca bir pencereyi geri getir
    case off    // Kapalı
}

enum Settings {
    private static let d = UserDefaults.standard

    static var mode: ToggleMode {
        get { ToggleMode(rawValue: d.string(forKey: "mode") ?? "") ?? .minimize }
        set { d.set(newValue.rawValue, forKey: "mode") }
    }

    /// ⌘Tab vb. klavye ile öne gelen uygulamanın tüm pencereleri küçültülmüşse ne yapılsın.
    static var restore: RestoreMode {
        get { RestoreMode(rawValue: d.string(forKey: "restore") ?? "") ?? .all }
        set { d.set(newValue.rawValue, forKey: "restore") }
    }

    static var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "enabled") }
    }
}

// MARK: - Accessibility yardımcıları

enum AX {
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

    /// Uygulamanın tüm pencereleri (alt rolden bağımsız), AX sırasıyla.
    static func allWindows(of app: NSRunningApplication) -> [AXUIElement] {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        return attr(axApp, kAXWindowsAttribute) ?? []
    }

    static func isStandard(_ w: AXUIElement) -> Bool {
        (attr(w, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole
    }

    /// Uygulamanın standart pencereleri (küçültülmüşler dahil), AX sırasıyla.
    static func standardWindows(of app: NSRunningApplication) -> [AXUIElement] {
        allWindows(of: app).filter(isStandard)
    }

    /// Tanılama için: uygulamanın tüm pencereleri, alt rol ve küçültülme durumuyla.
    static func allWindowsDescription(of app: NSRunningApplication) -> String {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        guard err == .success, let windows = value as? [AXUIElement] else { return "AX hatası \(err.rawValue)" }
        if windows.isEmpty { return "yok" }
        return windows.map { w in
            let subrole: String = attr(w, kAXSubroleAttribute) ?? "-"
            return "\(subrole)\(isMinimized(w) ? " (küçültülmüş)" : "")"
        }.joined(separator: ", ")
    }

    static func isMinimized(_ w: AXUIElement) -> Bool {
        attr(w, kAXMinimizedAttribute) ?? false
    }

    /// Uygulamanın görünür (küçültülmemiş) standart pencereleri.
    static func visibleWindows(of app: NSRunningApplication) -> [AXUIElement] {
        standardWindows(of: app).filter { !isMinimized($0) }
    }
}

// MARK: - Dock geometrisi (IPC'siz ön eleme)

/// Dock'un hangi kenarda olduğunu ve kalınlığını Dock'un kendi tercihlerinden okur.
/// Dock her zaman bir ekranın alt/sol/sağ kenarına yapışık olduğundan, tıklamanın
/// o kenardaki şeritte olup olmadığı saf aritmetikle bulunabilir. Çoklu ekranda
/// Dock'un ekran değiştirmesi de böylece kendiliğinden kapsanır.
final class DockGeometry {
    enum Edge: String { case bottom, left, right }

    private(set) var edge: Edge = .bottom
    private(set) var thickness: CGFloat = 120
    private(set) var dockPID: pid_t = 0
    private var lastRefresh: TimeInterval = 0

    init() { refresh() }

    func refresh() {
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)
        func num(_ key: String) -> Double? {
            (CFPreferencesCopyAppValue(key as CFString, domain) as? NSNumber)?.doubleValue
        }

        edge = Edge(rawValue: CFPreferencesCopyAppValue("orientation" as CFString, domain) as? String ?? "") ?? .bottom
        dockPID = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier ?? 0

        // Tercihlerden tahmin (anahtar yoksa macOS varsayılanı 64 kabul edilir).
        let tile = num("tilesize") ?? 64
        let magnified = (num("magnification") ?? 0) != 0
        let largest = magnified ? max(tile, num("largesize") ?? 128) : tile
        var estimate = CGFloat(largest) + 48

        // Dock'un simge listesinin gerçek boyutu (tek AX çağrısı, yalnızca tazelemede).
        // Büyütme, listeyi tilesize'dan öteye taşıyabildiği için büyütme payı eklenir.
        if dockPID != 0, let list = dockList(), let size = AX.size(list) {
            let measured = (edge == .bottom ? size.height : size.width) + 16
            let extra = magnified ? CGFloat(largest - tile) : 0
            estimate = max(estimate, measured + extra)
        }
        thickness = estimate
        lastRefresh = ProcessInfo.processInfo.systemUptime
        logger.debug("Dock geometrisi: kenar=\(self.edge.rawValue, privacy: .public) kalınlık=\(Double(self.thickness)) pid=\(self.dockPID)")
    }

    private func dockList() -> AXUIElement? {
        let dock = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(dock, 0.2)
        guard let children: [AXUIElement] = AX.attr(dock, kAXChildrenAttribute) else { return nil }
        return children.first { (AX.attr($0, kAXRoleAttribute) as String?) == kAXListRole }
    }

    /// Dock boyutu Sistem Ayarları'ndan canlı değişebildiği için tercihleri en fazla
    /// 5 saniyede bir, yalnızca bir tıklama olduğunda yeniden okur (zamanlayıcı yok).
    func refreshIfStale() {
        if ProcessInfo.processInfo.systemUptime - lastRefresh > 5 { refresh() }
    }

    /// `p` global CG koordinatındadır (sol üst köşe orijin, y aşağı doğru artar).
    func mayContain(_ p: CGPoint) -> Bool {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(p, 1, &display, &count) == .success, count > 0 else { return false }
        let b = CGDisplayBounds(display)
        switch edge {
        case .bottom: return p.y >= b.maxY - thickness
        case .left:   return p.x <= b.minX + thickness
        case .right:  return p.x >= b.maxX - thickness
        }
    }
}

// MARK: - Dock tıklama yakalayıcı

final class DockClickMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var swallowNextMouseUp = false

    /// Son sol tıklamanın zamanı (systemUptime). Bir uygulamanın fareyle mi yoksa
    /// klavyeyle mi (⌘Tab vb.) öne geldiğini ayırt etmek için kullanılır.
    private(set) var lastMouseDown: TimeInterval = 0
    private let systemWide = AXUIElementCreateSystemWide()
    private let geometry = DockGeometry()

    var isRunning: Bool { eventTap != nil }

    func start() -> Bool {
        guard eventTap == nil else { return true }
        AXUIElementSetMessagingTimeout(systemWide, 0.2)

        // Dock yeniden başlarsa (ör. `killall Dock` veya konum değişikliği) PID ve
        // tercihler değişir; hemen tazele.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == "com.apple.dock" { self?.geometry.refresh() }
        }

        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
                 | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let monitor = Unmanaged<DockClickMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        // Sistem, yavaş kalan tap'leri kapatabilir; yeniden aç.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return pass
        }

        if type == .leftMouseUp {
            if swallowNextMouseUp {
                swallowNextMouseUp = false
                return nil
            }
            return pass
        }

        guard type == .leftMouseDown else { return pass }
        lastMouseDown = ProcessInfo.processInfo.systemUptime
        guard Settings.enabled else { return pass }

        // ⌘/⌥/⌃/⇧ ile yapılan tıklamalar Dock'un kendi davranışına kalsın.
        let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        guard event.flags.intersection(modifiers).isEmpty else { return pass }

        // 1. aşama: Dock şeridinin dışındaki tıklamalar hiçbir IPC yapılmadan geçer.
        geometry.refreshIfStale()
        guard geometry.mayContain(event.location) else { return pass }

        // 2. aşama: noktadaki öğe gerçekten bir Dock uygulama simgesi mi?
        guard let app = dockApplication(at: event.location) else {
            logger.debug("Şeritte tıklama, Dock uygulama simgesi değil (\(Double(event.location.x)), \(Double(event.location.y)))")
            return pass
        }
        guard let front = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier == front.processIdentifier else {
            logger.debug("Simge: \(app.localizedName ?? "?", privacy: .public) — öndeki uygulama değil, Dock'a bırakıldı")
            return pass
        }

        // Öndeki uygulama ama görünür penceresi yoksa Dock normal davransın
        // (küçültülmüş pencereyi geri açar ya da yeni pencere açar).
        let windows = AX.visibleWindows(of: app)
        guard !windows.isEmpty else {
            logger.debug("Simge: \(app.localizedName ?? "?", privacy: .public) — görünür pencere yok, Dock'a bırakıldı")
            return pass
        }
        logger.info("Küçültülüyor: \(app.localizedName ?? "?", privacy: .public) (\(windows.count) pencere)")

        // 3. aşama: davranışı değiştir.
        swallowNextMouseUp = true
        let mode = Settings.mode
        DispatchQueue.main.async {
            switch mode {
            case .minimize:
                for w in windows {
                    AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                }
            case .hide:
                app.hide()
            }
        }
        return nil
    }

    /// Verilen ekran noktasındaki Dock simgesinin temsil ettiği çalışan uygulama.
    private func dockApplication(at point: CGPoint) -> NSRunningApplication? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              var el = hit else { return nil }

        // Noktadaki öğe Dock sürecine ait değilse (ör. şeritteki bir uygulama penceresi) çık.
        if geometry.dockPID == 0 { geometry.refresh() }
        guard AX.pid(el) == geometry.dockPID else { return nil }

        // Tıklanan öğe simgenin bir alt öğesi olabilir; birkaç seviye yukarı çık.
        var found = false
        for _ in 0..<3 {
            let subrole: String? = AX.attr(el, kAXSubroleAttribute)
            if subrole == "AXApplicationDockItem" { found = true; break }
            guard let parent = AX.element(el, kAXParentAttribute) else { break }
            el = parent
        }
        guard found else { return nil }

        let running = NSWorkspace.shared.runningApplications

        if let url: URL = AX.attr(el, kAXURLAttribute) {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            if let match = running.first(where: {
                $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == path
            }) { return match }
        }

        if let title: String = AX.attr(el, kAXTitleAttribute) {
            return running.first(where: { $0.localizedName == title })
        }
        return nil
    }
}

// MARK: - ⌘Tab ile öne gelen uygulamanın pencerelerini geri getirme

/// macOS, ⌘Tab ile seçilen uygulamanın tüm pencereleri küçültülmüşse ekrana hiçbir
/// pencere getirmez. Bu sınıf uygulama etkinleştirme bildirimini dinler ve
/// klavyeyle (⌘Tab, Spotlight, kısayollar) öne gelen bir uygulamanın görünür penceresi
/// yoksa küçültülmüş pencerelerini geri getirir.
///
/// Fareyle yapılan etkinleştirmelere dokunulmaz: masaüstüne tıklamak Finder'ı öne
/// getirir ve küçültülmüş Finder pencerelerinin açılması istenmez; Dock tıklamalarını
/// ise Dock zaten kendisi yönetir. Ek olay dinleme yoktur: yalnızca uygulama
/// değişiminde gelen bir bildirim ve etkinleşen uygulamaya tek bir AX sorgusu.
final class ActivationRestorer {
    private let lastMouseDown: () -> TimeInterval
    private var observer: NSObjectProtocol?

    init(lastMouseDown: @escaping () -> TimeInterval) {
        self.lastMouseDown = lastMouseDown
    }

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self?.handle(app)
        }
    }

    private func handle(_ app: NSRunningApplication) {
        let name = app.localizedName ?? "?"
        let mode = Settings.restore
        guard Settings.enabled, mode != .off,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            logger.debug("Etkinleşti: \(name, privacy: .public) — geri getirme kapalı")
            return
        }

        // Son yarım saniyede tıklama olduysa etkinleştirme fareyle yapılmıştır.
        let sinceClick = ProcessInfo.processInfo.systemUptime - lastMouseDown()
        guard sinceClick > 0.5 else {
            logger.debug("Etkinleşti: \(name, privacy: .public) — fareyle (\(sinceClick, format: .fixed(precision: 2)) sn önce tıklama), dokunulmadı")
            return
        }

        // Uygulamanın kendisi bir pencere açacaksa (yeniden açılma davranışı) ona fırsat ver.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                logger.debug("Etkinleşti: \(name, privacy: .public) — artık önde değil")
                return
            }

            let description = AX.allWindowsDescription(of: app)
            logger.debug("Etkinleşti: \(name, privacy: .public) — pencereler: \(description, privacy: .public)")

            let all = AX.allWindows(of: app)
            // Görünür bir standart pencere varsa ekranda zaten bir şey var; dokunma.
            if all.contains(where: { AX.isStandard($0) && !AX.isMinimized($0) }) {
                logger.debug("Etkinleşti: \(name, privacy: .public) — görünür pencere zaten var")
                return
            }
            // Küçültülmüş her pencere aday: bazı uygulamalar (ör. Firefox) küçültülmüş
            // penceresini AXDialog alt rolüyle bildirir. Gerçek iletişim kutuları
            // küçültülemediği için bu güvenlidir.
            let windows = all.filter(AX.isMinimized)
            guard !windows.isEmpty else {
                logger.debug("Etkinleşti: \(name, privacy: .public) — küçültülmüş pencere yok")
                return
            }

            let targets = mode == .all ? windows : [windows[0]]
            logger.info("Geri getiriliyor: \(app.localizedName ?? "?", privacy: .public) (\(targets.count) pencere)")

            // Sondan başa aç ki AX sırasındaki ilk pencere en üstte kalsın.
            for w in targets.reversed() {
                AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            if let top = targets.first {
                AXUIElementPerformAction(top, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(top, kAXMainAttribute as CFString, kCFBooleanTrue)
            }
        }
    }
}

// MARK: - Uygulama (arayüzsüz arka plan aracı)

/// Menü çubuğu simgesi ve pencere yoktur. Ayarlar `defaults` ile değiştirilir:
///   defaults write com.local.docktoggle mode -string hide      (veya minimize)
///   defaults write com.local.docktoggle restore -string all    (veya one, off)
///   defaults write com.local.docktoggle enabled -bool false
/// Başlatma Hammerspoon'a (veya başka bir başlatıcıya) bırakılmıştır.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = DockClickMonitor()
    private lazy var restorer = ActivationRestorer { [unowned self] in self.monitor.lastMouseDown }
    private var permissionTimer: Timer?

    private func startAll() -> Bool {
        guard monitor.start() else { return false }
        restorer.start()
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            if startAll() { logger.info("Başladı: Dock tıklamaları dinleniyor"); return }
            logger.error("İzin var ama olay dinleyici oluşturulamadı")
        } else {
            logger.error("Erişilebilirlik izni yok; izin bekleniyor")
        }

        // İzin verilene kadar bekle, sonra otomatik başla.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self, AXIsProcessTrusted(), self.startAll() else { return }
            logger.info("İzin alındı, başladı: Dock tıklamaları dinleniyor")
            timer.invalidate()
            self.permissionTimer = nil
        }
    }
}

// MARK: - Giriş noktası

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
