// Mission Control, App Exposé ve "Masaüstünü Göster" durumunu izler.
//
// Dock bu modlara girip çıkarken Accessibility bildirimleri yayınlar. Dock sürecine
// bir AXObserver bağlanarak bu bildirimler dinlenir; ek izin (Ekran Kaydı) gerekmez,
// zamanlayıcı yoktur. Bildirim adları belgelenmemiştir: ileride değişirlerse bayrak
// hiç açılmaz ve uygulama bugünkü gibi çalışmaya devam eder (güvenli taraf).

import Cocoa
import ApplicationServices

final class MissionControlWatcher {
    private static let enterNotifications = [
        "AXExposeShowAllWindows",    // Mission Control
        "AXExposeShowFrontWindows",  // App Exposé
        "AXExposeShowDesktop",       // Masaüstünü Göster
    ]
    private static let exitNotification = "AXExposeExit"

    private var observer: AXObserver?
    private var dockElement: AXUIElement?
    private var launchObserver: NSObjectProtocol?

    var isRunning: Bool { observer != nil }

    /// Ana iş parçacığında, Erişilebilirlik izni varken çağrılır.
    func start() {
        attach()
        guard launchObserver == nil else { return }
        // Dock yeniden başlarsa (yeni PID) gözlemciyi yeniden bağla.
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == "com.apple.dock", self?.observer != nil { self?.attach() }
        }
    }

    func stop() {
        detach()
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        launchObserver = nil
    }

    private func attach() {
        detach()
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return }

        let pid = dock.processIdentifier
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, name, _ in
            let active = (name as String) != MissionControlWatcher.exitNotification
            SharedState.shared.update { $0.missionControl = active }
            logger.debug("Mission Control: \(active ? "açık" : "kapalı", privacy: .public) (\(name as String, privacy: .public))")
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else {
            logger.error("Mission Control gözlemcisi oluşturulamadı")
            return
        }

        let element = AXUIElementCreateApplication(pid)
        for name in Self.enterNotifications + [Self.exitNotification] {
            // Bilinmeyen bir ad sessizce atlanır.
            _ = AXObserverAddNotification(observer, element, name as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = observer
        self.dockElement = element
        SharedState.shared.update { $0.missionControl = false }
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        dockElement = nil
        SharedState.shared.update { $0.missionControl = false }
    }
}
