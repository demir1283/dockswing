<p align="center">
  <img src="assets/icon.png" alt="DockSwing ikonu" width="128">
</p>

<h1 align="center">DockSwing</h1>

<p align="center">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey">
  <img alt="Swift" src="https://img.shields.io/badge/swift-AppKit-orange">
  <img alt="RAM" src="https://img.shields.io/badge/RAM-~8MB-success">
  <img alt="CPU idle" src="https://img.shields.io/badge/CPU%20(idle)-%7E0%25-success">
</p>

macOS Dock'una Windows görev çubuğu davranışı kazandıran, minimum kaynak tüketen, native bir araç.

macOS'ta öndeki uygulamanın Dock simgesine tıklamak hiçbir şey yapmaz; ⌘Tab ile tüm pencereleri küçültülmüş bir uygulamaya geçmek de ekrana pencere getirmez. DockSwing bu iki boşluğu Windows'taki gibi doldurur. Menü çubuğu simgesi ya da penceresi yoktur; tamamen arka planda, olay tabanlı çalışır.

## Özellikler

- **Dock'tan küçült:** Öndeki uygulamanın Dock simgesine tıklayınca pencereleri küçültülür (veya ayara göre uygulama gizlenir). Tekrar tıklayınca macOS'un kendi davranışıyla geri açılır.
- **⌘Tab ile geri getir:** ⌘Tab, Spotlight ya da bir klavye kısayoluyla seçilen uygulamanın tüm pencereleri küçültülmüşse pencereler geri açılır. Fareyle yapılan geçişlere (masaüstü tıklaması, Dock) dokunulmaz.
- **Araya girmez:** Mission Control, App Exposé ve "Masaüstünü Göster" açıkken, tam ekran pencerelerde ve ⌘ / ⌥ / ⌃ / ⇧ basılıyken tıklamalar macOS'a bırakılır. Etkisi olmayacak bir tıklama asla yutulmaz.
- Çoklu ekran, farklı ölçekleme, Dock konumu (alt/sol/sağ), otomatik gizleme ve büyütmeyle çalışır
- Olay dinleyici kendi iş parçacığında çalışır; ana iş parçacığı meşgulken tıklamalar gecikmez
- Sabit imza sertifikasıyla Erişilebilirlik izni derlemeler arasında korunur
- [Hammerspoon](https://www.hammerspoon.org/) ile girişte başlatılabilir
- Polling yok: boşta ~0% CPU, ~8 MB RAM

## Kurulum

Xcode'a gerek yok, sadece Command Line Tools yeterli:

```bash
xcode-select --install   # zaten kuruluysa atla
```

```bash
git clone https://github.com/demir1283/dockswing.git
cd dockswing
./make-cert.sh          # bir kez: kalıcı izin için yerel imza sertifikası
./build.sh --install
```

`build.sh --install` uygulamayı derler, `/Applications`'a kurar ve başlatır. İlk açılışta **Erişilebilirlik** izni istenir (Sistem Ayarları › Gizlilik ve Güvenlik › Erişilebilirlik); izni verdiğin anda kendiliğinden çalışmaya başlar.

Sadece derleyip kurmadan denemek istersen `./build.sh` yeterli; çıktı `build/` klasörüne gelir. Bu klasör Spotlight ve Launchpad'den gizlenir, bu yüzden uygulama listesinde iki kopya görünmez.

### İmza ve Erişilebilirlik izni

macOS Erişilebilirlik iznini uygulamanın imzasına bağlar.

- **`./make-cert.sh` ile (önerilen):** Bu Mac'e özel, ayrı bir keychain'de sabit bir self-signed sertifika oluşturulur. Uygulama her derlemede bu sertifikayla imzalanır ve izin korunur. Sertifikaya geçişten sonraki ilk kurulumda izni bir kez daha vermen gerekir. Kurulum sırasında macOS, sertifikaya kod imzalama güveni eklemek için bir kez parola sorabilir.
- **Sertifikasız:** Uygulama ad-hoc imzalanır. Ad-hoc imza her derlemede değiştiği için `--install` eski izin kaydını sıfırlar ve izin her kurulumda yeniden istenir.

Sertifikanın parolası `.signing/` klasöründe tutulur ve depoya girmez.

### Hazır paket

[Releases](https://github.com/demir1283/dockswing/releases) sayfasında derlenmiş bir paket varsa indirip `/Applications`'a taşıyabilirsin. Paket notarize edilmemişse ilk açılıştan önce:

```bash
xattr -dr com.apple.quarantine /Applications/DockSwing.app
```

Paket oluşturmak için `./release.sh`, GitHub'da yayınlamak için `./release.sh --publish` kullanılır. Apple Developer hesabın varsa `DEVELOPER_ID` ve `NOTARY_PROFILE` değişkenleriyle paket notarize edilir (ayrıntılar betiğin başında).

## Kullanım

Arayüz yoktur; ayarlar `defaults` ile değiştirilir ve anında geçerli olur:

```bash
# Öndeki uygulamanın Dock simgesine tıklanınca
defaults write com.demir1283.dockswing mode -string minimize   # pencereleri küçült (varsayılan)
defaults write com.demir1283.dockswing mode -string hide       # uygulamayı gizle (⌘H)

# ⌘Tab ile tüm pencereleri küçültülmüş bir uygulamaya geçilince
defaults write com.demir1283.dockswing restore -string all     # tüm pencereleri aç (varsayılan)
defaults write com.demir1283.dockswing restore -string one     # yalnızca bir pencereyi aç
defaults write com.demir1283.dockswing restore -string off     # kapalı

# Tümünü geçici olarak kapat / aç
defaults write com.demir1283.dockswing enabled -bool false
defaults write com.demir1283.dockswing enabled -bool true
```

Kapatmak için: `pkill -x DockSwing`

## Hammerspoon entegrasyonu

DockSwing'in kendi "girişte başlat" ayarı yoktur; başlatmayı Hammerspoon'a bırakır. `examples/hammerspoon-example.lua` dosyasına bak. Özetle:

```lua
local function ensureDockSwing()
    if not hs.application.get("com.demir1283.dockswing") then
        hs.task.new("/usr/bin/open", nil, { "-g", "-b", "com.demir1283.dockswing" }):start()
    end
end

ensureDockSwing()
```

Fonksiyon DockSwing zaten çalışıyorsa hiçbir şey yapmaz; config yeniden yüklendiğinde tekrar açmaz. Ekran değişimi ya da uyanma izleyicilerine de ekleyebilirsin; DockSwing kapanmışsa geri gelir. Uygulama ikinci bir kopyanın açılmasını kendisi de engeller.

## Nasıl çalışır

**Dock tıklamaları.** Bir `CGEventTap` sol tıklamaları kendi iş parçacığında dinler. Geri çağırma AppKit'e hiç dokunmaz: öndeki uygulama, Dock geometrisi ve Mission Control durumu ana iş parçacığında hazırlanıp kilitli bir anlık görüntüyle paylaşılır. Her tıklama ucuzdan pahalıya elenir:

1. **Hızlı kontroller:** Ayar kapalı, Mission Control açık ya da değiştirici tuş basılıysa tıklama geçer.
2. **Kenar şeridi (IPC'siz):** Dock'un kenarı ve kalınlığı Dock'un tercihlerinden ve gerçek boyutundan bilinir. Tıklama, bulunduğu ekranın o kenarındaki şeritte değilse hiçbir işlem yapılmadan geçer. Tıklamaların neredeyse tamamı burada elenir.
3. **Tek Accessibility sorgusu:** Noktadaki öğe, öndeki uygulamanın Dock simgesi (`AXApplicationDockItem`) mi? Sorgular 0,05 sn zaman aşımıyla yapılır; yanıt vermeyen bir uygulama tıklamayı bekletmez.
4. **Etki kontrolü:** Odaktaki pencere tam ekransa ya da görünür pencere yoksa tıklama geçer.
5. **Eylem:** Tıklama yutulur, pencereler ana iş parçacığında küçültülür (veya uygulama gizlenir).

**Mission Control.** Dock'a bağlanan bir `AXObserver`, Dock'un Mission Control / App Exposé / Masaüstünü Göster için yayınladığı bildirimleri dinler. Ek izin ya da zamanlayıcı gerekmez.

**⌘Tab geri getirme.** Ek bir olay dinlemez: uygulama değişiminde gelen sistem bildirimiyle çalışır ve etkinleşen uygulamaya tek bir Accessibility sorgusu yapar. Etkinleşmeden önceki 0,5 saniye içinde fare tıklaması olduysa geçişin fareyle yapıldığı kabul edilir ve dokunulmaz.

**İzin.** İznin verildiği ya da geri alındığı sistem bildirimiyle anında yakalanır; izin geri alınırsa dinleyici sökülür. Sürekli çalışan bir zamanlayıcı yoktur.

Tanılama kayıtlarını izlemek için:

```bash
log stream --level debug --predicate 'subsystem == "com.demir1283.dockswing"'
```

**Bilinen sınırlamalar:**

- ⌘Tab'ın gezinme sırasında üzerine gelinen uygulamayı canlı göstermek, sistem değiştiricisini tamamen değiştirmeyi gerektirir (AltTab gibi). DockSwing bunun yerine ⌘ bırakıldığında çalışır.
- Bir uygulamanın son penceresini küçülttükten sonra uygulama hâlâ öndeyse, ⌘Tab ile ona yeniden geçmek bir "uygulama değişti" bildirimi üretmez; pencere bu durumda geri gelmez.
- Mission Control algılaması Dock'un belgelenmemiş bildirim adlarına dayanır. Bir macOS güncellemesi bunları değiştirirse algılama sessizce devre dışı kalır ve uygulama eski davranışla çalışmaya devam eder.
- Bazı uygulamalar (ör. bazı Electron/Java uygulamaları) Accessibility üzerinden küçültmeyi yok sayabilir; bunlar için `mode hide` daha güvenilirdir.

## Lisans

MIT — bkz. [LICENSE](LICENSE).
