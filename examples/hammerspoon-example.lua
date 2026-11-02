-- DockToggle Hammerspoon entegrasyon ornegi
--
-- DockToggle'in arayuzu yoktur; girisle birlikte baslamasi icin Hammerspoon'a
-- birakilmistir. Asagidaki fonksiyon DockToggle calismiyorsa onu arka planda
-- baslatir, calisiyorsa hicbir sey yapmaz. Bu yuzden config yeniden
-- yuklendiginde tekrar acmaz ve guvenle birden fazla yerden cagrilabilir.

local function ensureDockToggle()
    if not hs.application.get("com.local.docktoggle") then
        hs.task.new("/usr/bin/open", nil, { "-g", "-b", "com.local.docktoggle" }):start()
    end
end

-- Hammerspoon acilisinda baslat
ensureDockToggle()

-- Istege bagli: DockToggle bir sebeple kapanirsa (cokme, pkill) uyanmada veya
-- monitor tak/cikar sirasinda geri gelsin.
dockToggleWake = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.systemDidWake then ensureDockToggle() end
end)
dockToggleWake:start()

dockToggleScreens = hs.screen.watcher.new(ensureDockToggle)
dockToggleScreens:start()
