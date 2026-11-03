// Arayüzsüz arka plan uygulaması: menü çubuğu simgesi ya da pencere yoktur.
// Başlatma Hammerspoon'a (veya başka bir başlatıcıya) bırakılmıştır.

import Cocoa
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let tap = DockClickTap()
    private let missionControl = MissionControlWatcher()

    /// Yalnızca izin beklenirken çalışan yedek kontrol; izin gelince durur.
    private var permissionFallback: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        observeWorkspace()
        refreshFront()
        DockGeometry.refresh()

        // İzin verildiğinde ya da geri alındığında sistem bu bildirimi yayınlar.
        // TCC kaydı bildirimden biraz sonra güncellendiği için kısa bir gecikmeyle bakılır.
        _ = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.syncPermission() }
        }

        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)
        syncPermission()
    }

    // MARK: İzin

    private func syncPermission() {
        if AXIsProcessTrusted() {
            permissionFallback?.invalidate()
            permissionFallback = nil
            guard !tap.isRunning else { return }
            if tap.start() {
                missionControl.start()
                DockGeometry.refresh()   // izin öncesi ölçülemeyen Dock boyutu
                logger.info("Başladı: Dock tıklamaları dinleniyor")
            } else {
                logger.error("İzin var ama olay dinleyici oluşturulamadı")
            }
        } else {
            if tap.isRunning {
                tap.stop()
                missionControl.stop()
                logger.error("Erişilebilirlik izni geri alındı; dinleyici durduruldu")
            } else {
                logger.error("Erişilebilirlik izni yok; izin bekleniyor")
            }
            // Bildirim kaçarsa diye, yalnızca izin beklenirken yedek kontrol.
            if permissionFallback == nil {
                permissionFallback = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    if AXIsProcessTrusted() { self?.syncPermission() }
                }
                permissionFallback?.tolerance = 1
            }
        }
    }

    // MARK: Çalışma alanı bildirimleri

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter

        _ = nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            self?.refreshFront()
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                ActivationRestorer.handle(app)
            }
        }
        for name in [NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            _ = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshFront() }
        }

        // Dock yeniden başlarsa (ör. `killall Dock`, konum değişikliği) PID ve tercihler değişir.
        _ = nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == "com.apple.dock" { DockGeometry.refresh() }
        }

        // Monitör takma/çıkarma, çözünürlük değişimi
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in DockGeometry.refresh() }
    }

    private func refreshFront() {
        let front = NSWorkspace.shared.frontmostApplication
        let pid = front?.processIdentifier ?? 0
        let path = normalizedPath(front?.bundleURL)
        let name = front?.localizedName
        SharedState.shared.update {
            $0.frontPID = pid
            $0.frontPath = path
            $0.frontName = name
        }
    }
}
