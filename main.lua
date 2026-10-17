-- Reel: a Plex client for LoVE.
-- Scenes live in ui/; each has optional enter/leave/update/draw/action/resize methods.

io.stdout:setvbuf("no")     -- log lines show up immediately even when redirected (Windows CRT has no line buffering)

local http = require("lib.http")
local input = require("lib.input")
local client = require("plex.client")
local theme = require("theme")
local gfx = require("ui.gfx")
local mouse = require("ui.mouse")

local app = {
    stack = {},
    toast = nil,
}
_G.app = app

function app.push(scene, ...)
    local top = app.stack[#app.stack]
    if top and top.pause then top:pause() end
    app.stack[#app.stack + 1] = scene
    if scene.enter then scene:enter(...) end
end

function app.pop()
    local scene = table.remove(app.stack)
    if scene and scene.leave then scene:leave() end
    local top = app.stack[#app.stack]
    if top and top.resume then top:resume() end
end

-- Replace the whole stack (e.g. after sign-in / server change).
function app.reset(scene, ...)
    while #app.stack > 0 do app.pop() end
    app.push(scene, ...)
end

function app.top() return app.stack[#app.stack] end

function app.toggleFullscreen()
    love.window.setFullscreen(not love.window.getFullscreen(), "desktop")
end

function app.notify(msg, kind)
    app.toast = { msg = msg, kind = kind or "info", t = 0 }
    print("[" .. (kind or "info") .. "] " .. msg)
end

function love.load(args)
    love.keyboard.setKeyRepeat(false)
    client.load()
    theme.apply(client.settings.theme)
    http.init()

    -- Which video codecs Windows can decode decides direct play vs server conversion.
    local NativeVideo = require("lib.NativeVideo")
    app.videoCodecs = {}
    for _, codec in ipairs({ "h264", "hevc", "vp9", "av1", "mpeg4", "mpeg2video", "vc1" }) do
        if NativeVideo.hasVideoDecoder(codec) then app.videoCodecs[#app.videoCodecs + 1] = codec end
    end
    require("plex.playback").setCapabilities(app.videoCodecs)
    print("[video] Windows decoders: " .. table.concat(app.videoCodecs, ", "))
    input.setHandler(function(action, isRepeat)
        local top = app.top()
        if top and top.action then top:action(action, isRepeat) end
    end)
    app.args = args or {}
    for _, a in ipairs(app.args) do
        if a == "--nvtest" then return require("tools.nvtest").start(app.args) end
        if a == "--audiotest" then
            app.selftest = require("tools.audiotest")
            return app.selftest.start(app.args)
        end
        if a == "--playtest" then
            app.selftest = require("tools.playtest")
            return app.selftest.start(app.args)
        end
        if a == "--transcodetest" then
            app.selftest = require("tools.transcodetest")
            return app.selftest.start(app.args)
        end
        if a == "--shots" then
            app.selftest = require("tools.shots")
            app.selftest.start(app.args)
            if app.selftest.player then
                app.push({})   -- empty base scene for the player to return to
                return require("tools.shots").startPlayer()
            end
        end
        if a == "--selftest" then
            app.selftest = require("tools.selftest")
            return app.selftest.start()
        end
    end
    app.push(require("ui.signin").new())
end

function love.update(dt)
    dt = math.min(dt, 0.1)
    http.update()
    input.update(dt)
    gfx.update()
    if app.selftest then app.selftest.update(dt) end
    local top = app.top()
    if top and top.update then top:update(dt) end
    -- Scenes below the top that need ticking (e.g. a player behind an overlay) set alwaysUpdate.
    for i = 1, #app.stack - 1 do
        local s = app.stack[i]
        if s.alwaysUpdate and s.update then s:update(dt) end
    end
    if app.toast then
        app.toast.t = app.toast.t + dt
        if app.toast.t > 4 then app.toast = nil end
    end
end

local w, h = love.graphics.getDimensions()
function love.draw()
    -- Draw from the topmost opaque scene upward.
    local first = #app.stack
    while first > 1 and app.stack[first].overlay do first = first - 1 end
    mouse.beginFrame()
    for i = math.max(first, 1), #app.stack do
        local s = app.stack[i]
        mouse.active = (i == #app.stack)   -- only the top scene takes clicks
        if s.draw then s:draw() end
    end
    mouse.active = true

    if app.toast then
        local u = gfx.unit()
        local a = math.min(1, (4 - app.toast.t) * 3)
        local msg = gfx.fit(app.toast.msg, 26 * u, w * 0.6)
        local tw = gfx.width(msg, 26 * u) + 48 * u
        local col = app.toast.kind == "error" and theme.danger or theme.surfaceHi
        -- top centre, clear of seek bars and button hints
        local ty = 110 * u
        gfx.color(col, 0.95 * a)
        gfx.roundRect("fill", (w - tw) / 2, ty, tw, 56 * u, 12 * u)
        gfx.textCentered(msg, w / 2, ty + 13 * u, 26 * u, theme.text, a)
    end
end

function love.keypressed(key, scancode, isrepeat)
    if key == "f11" or (key == "return" and love.keyboard.isDown("lalt", "ralt")) then
        app.toggleFullscreen()
        return
    end
    local top = app.top()
    if top and top.searchable and (key == "/" or (key == "f" and love.keyboard.isDown("lctrl", "rctrl"))) then
        app.push(require("ui.search").new(top.server))
        return
    end
    if top and top.keypressed and top:keypressed(key) then return end
    input.keypressed(key, scancode, isrepeat)
end

function love.keyreleased(key) input.keyreleased(key) end

function love.mousemoved(x, y, dx, dy, istouch) mouse.moved(x, y, dx, dy, istouch) end

function love.mousepressed(x, y, button, istouch)
    if istouch then return end
    if mouse.pressed(x, y, button) then return end
    local top = app.top()
    if not top then return end
    if button == 2 or button == 4 then
        if top.action then top:action("back") end
    elseif button == 1 and top.mouseclick then
        top:mouseclick(x, y)
    end
end

function love.mousereleased(x, y, button)
    local top = app.top()
    if top and top.mousereleased then top:mousereleased(x, y, button) end
end

function love.wheelmoved(dx, dy)
    -- Shift turns the vertical wheel into horizontal scrolling.
    if love.keyboard.isDown("lshift", "rshift") and dx == 0 then dx, dy = -dy, 0 end
    if mouse.wheel(dx, dy) then return end
    local top = app.top()
    if top and top.wheel then top:wheel(dx, dy) end
end
function love.gamepadpressed(js, button) input.gamepadpressed(js, button) end
function love.gamepadreleased(js, button) input.gamepadreleased(js, button) end

function love.textinput(t)
    local top = app.top()
    if top and top.textinput then top:textinput(t) end
end

function love.resize(w, h)
    for _, s in ipairs(app.stack) do
        if s.resize then s:resize(w, h) end
    end
end

function love.quit()
    for i = #app.stack, 1, -1 do
        local s = app.stack[i]
        if s.leave then s:leave() end
    end
    http.shutdown()
end
