// DockSwing — macOS Dock'una Windows görev çubuğu davranışı kazandırır.
//
//  • Öndeki uygulamanın Dock simgesine tıklanınca pencereleri küçültülür (veya gizlenir).
//  • ⌘Tab ile tüm pencereleri küçültülmüş bir uygulamaya geçilince pencereler geri gelir.
//
// Gereken izin: Sistem Ayarları › Gizlilik ve Güvenlik › Erişilebilirlik

import Cocoa

// İkinci bir kopya açılırsa (elle açma + Hammerspoon gibi) sessizce çık.
let myPID = ProcessInfo.processInfo.processIdentifier
if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .contains(where: { $0.processIdentifier != myPID }) {
    exit(0)
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
