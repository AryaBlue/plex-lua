function love.conf(t)
    t.identity = "plexlove"
    t.window.title = "Reel"
    t.window.width = 1600
    t.window.height = 900
    t.window.minwidth = 960
    t.window.minheight = 540
    t.window.resizable = true
    t.window.vsync = 1
    -- highdpi moved from t.window to t in LÖVE 12
    if (love._version_major or 11) >= 12 then t.highdpi = true else t.window.highdpi = true end
    t.modules.physics = false
    t.modules.touch = false
end
