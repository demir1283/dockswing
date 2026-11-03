// ⌘Tab ile öne gelen uygulamanın küçültülmüş pencerelerini geri getirir.
//
// macOS, ⌘Tab ile seçilen uygulamanın tüm pencereleri küçültülmüşse ekrana hiçbir
// pencere getirmez. Uygulama etkinleştirme bildirimi dinlenir; klavyeyle (⌘Tab,
// Spotlight, kısayollar) öne gelen bir uygulamanın görünür penceresi yoksa
// küçültülmüş pencereleri geri açılır.
//
// Fareyle yapılan etkinleştirmelere dokunulmaz: masaüstüne tıklamak Finder'ı öne
// getirir ve küçültülmüş Finder pencerelerinin açılması istenmez; Dock tıklamalarını
// Dock zaten kendisi yönetir. Ek olay dinleme yoktur.

import Cocoa
import ApplicationServices

enum ActivationRestorer {
    /// Etkinleşmeden önceki bu süre içinde tıklama olduysa etkinleşme fareyle yapılmıştır.
    static let mouseWindow: TimeInterval = 0.5

    /// Ana iş parçacığında, uygulama etkinleştirme bildiriminde çağrılır.
    static func handle(_ app: NSRunningApplication) {
        let name = app.localizedName ?? "?"
        let mode = Settings.restore
        guard Settings.enabled, mode != .off,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }

        let sinceClick = uptime - SharedState.shared.snapshot.lastMouseDown
        guard sinceClick > mouseWindow else {
            logger.debug("Etkinleşti: \(name, privacy: .public) — fareyle (\(sinceClick, format: .fixed(precision: 2)) sn önce tıklama), dokunulmadı")
            return
        }

        // Uygulamanın kendisi bir pencere açacaksa (yeniden açılma davranışı) ona fırsat ver.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }

            let all = AX.windows(of: app.processIdentifier, timeout: 0.2)
            logger.debug("Etkinleşti: \(name, privacy: .public) — pencereler: \(AX.describe(all), privacy: .public)")

            // Görünür bir standart pencere varsa ekranda zaten bir şey var; dokunma.
            if all.contains(where: { AX.isStandard($0) && !AX.isMinimized($0) }) { return }

            // Küçültülmüş her pencere aday: bazı uygulamalar (ör. Firefox) küçültülmüş
            // penceresini AXDialog alt rolüyle bildirir. Gerçek iletişim kutuları
            // küçültülemediği için bu güvenlidir.
            let minimized = all.filter(AX.isMinimized)
            guard !minimized.isEmpty else { return }

            let targets = mode == .all ? minimized : [minimized[0]]
            logger.info("Geri getiriliyor: \(name, privacy: .public) (\(targets.count) pencere)")

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
