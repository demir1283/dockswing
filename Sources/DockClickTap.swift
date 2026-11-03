// Dock tıklamalarını yakalayan olay dinleyici.
//
// Dinleyici kendi iş parçacığında çalışır; ana iş parçacığı meşgulken bile tıklamalar
// gecikmez. Geri çağırma AppKit'e hiç dokunmaz: yalnızca kilitli anlık görüntüyü okur
// ve iş parçacığı güvenli AX C API'lerini kısa zaman aşımıyla çağırır. Asıl eylem
// (küçültme / gizleme) ana iş parçacığına gönderilir.
//
// Her sol tıklama ucuzdan pahalıya elenir:
//   1. Ayar kapalı, Mission Control açık ya da değiştirici tuş basılı → geç.
//   2. Saf aritmetik: tıklama Dock kenarındaki şeritte değil → geç (tıklamaların neredeyse tamamı).
//   3. Tek AX sorgusu: noktadaki öğe, öndeki uygulamanın Dock simgesi değil → geç.
//   4. Tam ekran ya da görünür pencere yok (eylemin görünür etkisi olmaz) → geç.
//   5. Tıklamayı yut, ana iş parçacığında küçült / gizle.

import Cocoa
import ApplicationServices

final class DockClickTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let runLoop: CFRunLoop = DockClickTap.spawnThread()
    private let systemWide: AXUIElement = {
        let el = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(el, AX.quickTimeout)
        return el
    }()

    /// Yalnızca dinleyici iş parçacığında okunur ve yazılır.
    private var swallowNextMouseUp = false

    var isRunning: Bool { tap != nil }

    // MARK: Yaşam döngüsü (ana iş parçacığı)

    /// Erişilebilirlik izni yoksa `false` döner.
    func start() -> Bool {
        if tap != nil { return true }

        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
                 | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let me = Unmanaged<DockClickTap>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CFRunLoopWakeUp(runLoop)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// İzin geri alındığında dinleyiciyi söker (ölü bir dinleyici bırakmaz).
    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
        CFMachPortInvalidate(tap)
        CFRunLoopWakeUp(runLoop)
        self.tap = nil
        self.source = nil
    }

    /// Dinleyici için uykuda bekleyen, kendi run loop'u olan bir iş parçacığı başlatır.
    private final class LoopBox: @unchecked Sendable { var loop: CFRunLoop? }

    private static func spawnThread() -> CFRunLoop {
        let box = LoopBox()
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.loop = CFRunLoopGetCurrent()
            // Boş bir run loop hemen döner; bir port onu canlı ve uykuda tutar.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            while true {
                RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
        thread.name = "DockSwing.tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return box.loop!
    }

    // MARK: Geri çağırma (dinleyici iş parçacığı)

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Yarım kalmış bir tıklamanın durumu artık güvenilir değil.
            swallowNextMouseUp = false
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass

        case .leftMouseUp:
            if swallowNextMouseUp {
                swallowNextMouseUp = false
                return nil
            }
            return pass

        case .leftMouseDown:
            let now = uptime
            SharedState.shared.update { $0.lastMouseDown = now }
            swallowNextMouseUp = false
            return decide(event, now) ? nil : pass

        default:
            return pass
        }
    }

    /// Tıklama yutulacaksa `true` döner ve eylemi ana iş parçacığına gönderir.
    private func decide(_ event: CGEvent, _ now: TimeInterval) -> Bool {
        guard Settings.enabled else { return false }

        let s = SharedState.shared.snapshot
        // Mission Control / App Exposé / Masaüstünü Göster: tıklama uygulamayı öne getirmeli.
        guard !s.missionControl else { return false }

        // ⌘/⌥/⌃/⇧ ile yapılan tıklamalar (bağlam menüsü, "Finder'da göster"…) Dock'a kalsın.
        let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        guard event.flags.intersection(modifiers).isEmpty else { return false }

        // Bayat geometriyi ana iş parçacığında tazele; bu tıklama mevcut veriyle sürer.
        if now - s.geometryAt > DockGeometry.maxAge {
            SharedState.shared.update { $0.geometryAt = now }   // art arda istek gönderme
            DispatchQueue.main.async { DockGeometry.refresh() }
        }

        let p = event.location
        guard DockGeometry.mayContain(p, s) else { return false }

        guard let item = dockItem(at: p, dockPID: s.dockPID) else {
            logger.debug("Şeritte tıklama, Dock uygulama simgesi değil (\(Double(p.x)), \(Double(p.y)))")
            return false
        }
        let isFront: Bool
        if let path = item.path, let frontPath = s.frontPath {
            isFront = path == frontPath
        } else if let title = item.title, let frontName = s.frontName {
            isFront = title == frontName
        } else {
            isFront = false
        }
        guard isFront, s.frontPID != 0 else {
            logger.debug("Simge: \(item.title ?? "?", privacy: .public) — öndeki uygulama değil, Dock'a bırakıldı")
            return false
        }

        let name = s.frontName ?? "?"
        // Eylemin görünür etkisi olmayacaksa tıklamayı yutma (ölü tık üretme).
        if AX.focusedWindowIsFullScreen(s.frontPID, timeout: AX.quickTimeout) {
            logger.debug("Simge: \(name, privacy: .public) — tam ekran, Dock'a bırakıldı")
            return false
        }
        let visible = AX.windows(of: s.frontPID, timeout: AX.quickTimeout)
            .filter { AX.isStandard($0) && !AX.isMinimized($0) }
        guard !visible.isEmpty else {
            logger.debug("Simge: \(name, privacy: .public) — görünür pencere yok, Dock'a bırakıldı")
            return false
        }

        let mode = Settings.mode
        let pid = s.frontPID
        logger.info("\(mode == .minimize ? "Küçültülüyor" : "Gizleniyor", privacy: .public): \(name, privacy: .public) (\(visible.count) pencere)")
        DispatchQueue.main.async {
            switch mode {
            case .minimize:
                for w in visible {
                    AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                }
            case .hide:
                NSRunningApplication(processIdentifier: pid)?.hide()
            }
        }
        swallowNextMouseUp = true
        return true
    }

    /// Noktadaki Dock uygulama simgesinin paket yolu ve başlığı.
    private func dockItem(at p: CGPoint, dockPID: pid_t) -> (path: String?, title: String?)? {
        var hit: AXUIElement?
        guard dockPID != 0,
              AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &hit) == .success,
              var el = hit,
              AX.pid(el) == dockPID      // şeritteki bir uygulama penceresi değil, Dock
        else { return nil }

        // Tıklanan öğe simgenin bir alt öğesi olabilir; birkaç seviye yukarı çık.
        for _ in 0..<3 {
            AXUIElementSetMessagingTimeout(el, AX.quickTimeout)
            if (AX.attr(el, kAXSubroleAttribute) as String?) == "AXApplicationDockItem" {
                let url: URL? = AX.attr(el, kAXURLAttribute)
                let title: String? = AX.attr(el, kAXTitleAttribute)
                return (normalizedPath(url), title)
            }
            guard let parent = AX.element(el, kAXParentAttribute) else { break }
            el = parent
        }
        return nil
    }
}
