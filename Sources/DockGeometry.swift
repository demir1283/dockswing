// Dock'un konumu ve kalınlığı. Olay dinleyicinin IPC'siz ön elemesi için kullanılır.

import Cocoa
import ApplicationServices

enum DockGeometry {
    /// Tercihler ve Dock'un gerçek boyutu en fazla bu sıklıkla yeniden okunur.
    static let maxAge: TimeInterval = 5

    /// Ana iş parçacığında çağrılır. Dock'un kenarını ve kalınlığını okuyup
    /// paylaşılan duruma yazar. Zamanlayıcı yoktur: başlangıçta, ekran değişiminde,
    /// Dock yeniden başladığında ve bayatlamış veriyle bir tıklama geldiğinde çalışır.
    static func refresh() {
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)
        func num(_ key: String) -> Double? {
            (CFPreferencesCopyAppValue(key as CFString, domain) as? NSNumber)?.doubleValue
        }

        let edge = DockEdge(rawValue: CFPreferencesCopyAppValue("orientation" as CFString, domain) as? String ?? "") ?? .bottom
        let dockPID = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier ?? 0

        // Tercihlerden tahmin (anahtar yoksa macOS varsayılanı 64 kabul edilir).
        let tile = num("tilesize") ?? 64
        let magnified = (num("magnification") ?? 0) != 0
        let largest = magnified ? max(tile, num("largesize") ?? 128) : tile
        var thickness = CGFloat(largest) + 48

        // Dock'un simge listesinin gerçek boyutu. Büyütme listeyi tilesize'dan öteye
        // taşıyabildiği için büyütme payı eklenir.
        if dockPID != 0, let list = dockList(dockPID), let size = AX.size(list) {
            let measured = (edge == .bottom ? size.height : size.width) + 16
            let extra = magnified ? CGFloat(largest - tile) : 0
            thickness = max(thickness, measured + extra)
        }

        SharedState.shared.update {
            $0.edge = edge
            $0.thickness = thickness
            $0.dockPID = dockPID
            $0.geometryAt = uptime
        }
        logger.debug("Dock geometrisi: kenar=\(edge.rawValue, privacy: .public) kalınlık=\(Double(thickness)) pid=\(dockPID)")
    }

    private static func dockList(_ pid: pid_t) -> AXUIElement? {
        let dock = AX.app(pid, timeout: AX.quickTimeout)
        guard let children: [AXUIElement] = AX.attr(dock, kAXChildrenAttribute) else { return nil }
        return children.first { (AX.attr($0, kAXRoleAttribute) as String?) == kAXListRole }
    }

    /// Tıklama, bulunduğu ekranın Dock kenarındaki şeritte mi? Saf aritmetik, IPC yok.
    /// `p` global CG koordinatındadır (sol üst köşe orijin, y aşağı doğru artar).
    /// Dock her zaman bir ekran kenarına yapışık olduğundan çoklu ekranda, Dock ekran
    /// değiştirdiğinde ve otomatik gizlemede de doğrudur.
    static func mayContain(_ p: CGPoint, _ s: Snapshot) -> Bool {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(p, 1, &display, &count) == .success, count > 0 else { return false }
        let b = CGDisplayBounds(display)
        switch s.edge {
        case .bottom: return p.y >= b.maxY - s.thickness
        case .left:   return p.x <= b.minX + s.thickness
        case .right:  return p.x >= b.maxX - s.thickness
        }
    }
}
