-- DockSwing Hammerspoon entegrasyon ornegi
--
-- DockSwing'in arayuzu yoktur; girisle birlikte baslamasi icin Hammerspoon'a
-- birakilmistir. Asagidaki fonksiyon DockSwing calismiyorsa onu arka planda
-- baslatir, calisiyorsa hicbir sey yapmaz. Bu yuzden config yeniden
-- yuklendiginde tekrar acmaz ve guvenle birden fazla yerden cagrilabilir.

local dockSwingID = "com.demir1283.dockswing"

local function ensureDockSwing()
    if not hs.application.get(dockSwingID) then
        hs.task.new("/usr/bin/open", nil, { "-g", "-b", dockSwingID }):start()
    end
end

-- Hammerspoon acilisinda baslat
ensureDockSwing()

-- Istege bagli: DockSwing bir sebeple kapanirsa (cokme, pkill) uyanmada veya
-- monitor tak/cikar sirasinda geri gelsin.
dockSwingWake = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.systemDidWake then ensureDockSwing() end
end)
dockSwingWake:start()

dockSwingScreens = hs.screen.watcher.new(ensureDockSwing)
dockSwingScreens:start()
