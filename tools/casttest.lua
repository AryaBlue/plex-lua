-- lovec E:\PlexLove --casttest : casting against the stand-in devices of tools/fakecast.py
-- (start that first). Everything stays on this PC: the devices are on 127.0.0.1, the
-- server and title are made up, and the play queue request is answered locally.
-- Checks discovery (and that a device named in castBlock is dropped), the Chromecast
-- launch / LOAD / pause / seek / mute / stop exchange driven from the player's timeline,
-- the LOAD message Plex's receiver gets, opening Plex over DIAL, and the Fire TV remote
-- over ADB (sign-in with a new key and again with the saved one, the TV's media session,
-- pause / skip / seek key presses). Saves screenshots of the picker and remote to shots/.

local json = require("lib.json")
local cast = require("cast")
local client = require("plex.client")
local api = require("plex.api")

local T = {}
local failures, checks = 0, 0
local saved = {}

local function check(name, got, want)
    checks = checks + 1
    local ok = got == want
    if ok then print(("  ok   %-52s %s"):format(name, tostring(got)))
    else failures = failures + 1; print(("  FAIL %-52s got %s, want %s"):format(name, tostring(got), tostring(want))) end
    return ok
end

local LOG = love.filesystem.getSource() .. "/tools/fakecast.log"
local function logEntries()
    local out = {}
    local f = io.open(LOG, "r")
    if not f then return out end
    for line in f:lines() do
        local ok, e = pcall(json.decode, line)
        if ok then out[#out + 1] = e end
    end
    f:close()
    return out
end

local function findLog(pred)
    for _, e in ipairs(logEntries()) do if pred(e) then return e end end
end

local server = {
    id = "fakeserver0001", name = "Test Server", accessToken = "tok-123", productVersion = "1.41.0.1",
    active = { uri = "https://1-2-3-4.abc123.plex.direct:32400", protocol = "https", https = true, port = 32400,
               address = "1.2.3.4" },
    connections = {},
}
function server:baseUrl() return "http://127.0.0.1:9" end   -- never asked (no artwork, play queue stubbed)

local item = { ratingKey = "777", key = "/library/metadata/777", type = "episode", title = "Pilot",
               grandparentTitle = "Fake Show", parentIndex = 1, index = 1, duration = 1800000 }

local steps, step, waited = {}, 1, 0
local function add(name, fn) steps[#steps + 1] = { name = name, fn = fn } end

local function shot(name) love.graphics.captureScreenshot("shots/" .. name .. ".png") end

add("discover", function()
    if not T.started then
        T.started = true
        app.push(require("ui.castpicker").new(server, item, { offset = 95 }))
    end
    if cast.scanning then return false end
    local cc, stick, blocked
    for _, d in ipairs(cast.devices) do
        if d.kind == "chromecast" then cc = d end
        if d.name == "Fake FireTVStick" then stick = d end
        if d.name == "Blocked FireTVStick" then blocked = d end
    end
    check("chromecast found", cc and cc.name, "Fake Living Room TV")
    check("chromecast model", cc and cc.model, "Chromecast")
    check("chromecast port from SRV", cc and cc.port, 18009)
    check("fire tv stick found", stick and stick.name, "Fake FireTVStick")
    check("fire tv app url", stick and stick.appUrl, "http://127.0.0.1:18080/apps")
    check("blocked stick not listed", blocked == nil, true)
    T.cc, T.stick = cc, stick
    shot("cast-picker")
    return true
end)

local function player() return app.top() and app.top().casting and app.top() or nil end

add("cast to chromecast", function()
    if not T.cc then return true end
    if not T.chose then
        T.chose = true
        api.metadata = function(_, _, cb) cb(item) end
        cast.createPlayQueue = function(_, _, cb) cb({ playQueueID = 4242 }) end
        api.nextEpisode = function() end
        app.top():choose(T.cc)
    end
    local s = cast.session
    if s and s.state == "closed" then check("cast session", s.err, nil); return true end
    if not (s and s.state == "playing") then return false end
    check("the player is the remote", player() ~= nil, true)
    check("starts at the offset", math.floor(cast.position()), 95)
    return true
end)

add("remote screenshot", function()
    waited = waited + love.timer.getDelta()
    if waited < 0.6 then return false end
    shot("cast-remote")
    player():runControl("playpause")
    return true
end)

add("pause from the timeline", function()
    local s = cast.session
    if not s or s.player.state ~= "PAUSED" then return false end
    check("paused on the TV", s.player.state, "PAUSED")
    player():requestSeek(600)              -- as a click on the seek bar does
    T.seekAt = love.timer.getTime()
    return true
end)

add("seek from the timeline", function()
    if love.timer.getTime() - T.seekAt < 1 then return false end
    check("seeked to 10:00", math.floor(cast.position()), 600)
    player():runControl("playpause")
    return true
end)

add("check messages", function()
    local s = cast.session
    if s.player.state ~= "PLAYING" then return false end
    local launch = findLog(function(e) return e.kind == "cast" and e.payload.type == "LAUNCH" end)
    check("launched Plex's receiver", launch and launch.payload.appId, "9AC194DC")
    local load = findLog(function(e) return e.kind == "cast" and e.payload.type == "LOAD" end)
    local p = load and load.payload
    local m = p and p.media or {}
    local cd = m.customData or {}
    local sv = cd.server or {}
    check("LOAD sent to the app's transport", load and load.dst, "web-7")
    check("LOAD carries the app session", p and p.sessionId, "session-1")
    check("contentId", m.contentId, "/library/metadata/777")
    check("offset", cd.offset, 95)
    check("currentTime", p and p.currentTime, 95)
    check("containerKey", cd.containerKey, "/playQueues/4242?own=1&window=200")
    check("server id", sv.machineIdentifier, "fakeserver0001")
    check("server address (TV-reachable host)", sv.address, "1-2-3-4.abc123.plex.direct")
    check("server port", sv.port, 32400)
    check("server protocol", sv.protocol, "https")
    check("verified hostname", sv.isVerifiedHostname, true)
    check("token", sv.accessToken, "tok-123")
    local seek = findLog(function(e) return e.kind == "cast" and e.payload.type == "SEEK" end)
    check("seek has the media session", seek and seek.payload.mediaSessionId, 1)
    check("seek time", seek and seek.payload.currentTime, 600)
    player():runControl("volume")          -- mute
    T.at = love.timer.getTime()
    return true
end)

add("mute and cast menu", function()
    if love.timer.getTime() - T.at < 0.5 then return false end
    local vol = findLog(function(e) return e.kind == "cast" and e.payload.type == "SET_VOLUME" end)
    check("mute reaches the TV", vol and vol.payload.volume.muted, true)
    player():runControl("cast")
    local m = player().subMenu
    check("cast button opens the cast menu", m and m.cast, true)
    check("menu offers playing here", m and m.entries[1].label, "Play on this computer")
    waited = 0
    return true
end)

add("cast menu screenshot", function()
    waited = waited + love.timer.getDelta()
    if waited < 0.4 then return false end
    shot("cast-menu")
    return true
end)

add("stop from the cast menu", function()
    player():chooseSubtitle(2)             -- Stop casting (a frame after the screenshot)
    T.stopAt = love.timer.getTime()
    return true
end)

add("stop", function()
    if love.timer.getTime() - T.stopAt < 0.5 then return false end
    local stop = findLog(function(e) return e.kind == "cast" and e.payload.type == "STOP" end)
    check("stop closes the app on the TV", stop and stop.payload.sessionId, "session-1")
    check("no session after stop", cast.session, nil)
    check("remote closed", player(), nil)
    while #app.stack > 1 do app.pop() end
    return true
end)

add("open plex over dial", function()
    if not T.stick then return true end
    if not T.dialStarted then
        T.dialStarted = true
        cast.start(T.stick, server, item, 0, function(ok, err) T.dialDone = { ok, err } end)
        app.push(require("player.scene").new(server, item, { cast = true }))
    end
    if not T.dialDone then return false end
    check("dial launch ok", T.dialDone[1], true)
    local launch = findLog(function(e) return e.kind == "dial-launch" end)
    check("launched on the right stick", launch and launch.device, "Fake FireTVStick")
    check("launched Plex's DIAL app", launch and launch.path, "/apps/com.plexapp.android")
    check("nothing launched on the blocked stick",
        findLog(function(e) return e.kind == "dial-launch" and e.device == "Blocked FireTVStick" end), nil)
    check("remote shows opened", cast.session and cast.session.state, "opened")
    return true
end)

add("fire tv remote signs in", function()
    local s = cast.session
    local r = s and s.remote
    if r and r.state == "closed" then check("adb", r.err, nil); return true end
    if not (r and r.state == "ready") then return false end
    local key = findLog(function(e) return e.kind == "adb-key" end)
    check("adb key accepted (format, n0inv, rr, exponent)", key and key.ok, true)
    check("adb key name", key and key.name, "Reel@PC")
    return true
end)

add("fire tv playing", function()
    local s = cast.session
    if s.state ~= "playing" then return false end
    check("title from the TV", s.remote.title, "Pilot, Fake Show")
    check("length from the item", s.player.duration, 1800)
    check("controls live", cast.canControl(), true)
    waited = 0
    return true
end)

add("fire tv screenshot", function()
    waited = waited + love.timer.getDelta()
    if waited < 1.2 then return false end
    shot("cast-firetv")
    check("position from the TV", math.abs(cast.position() - 1.2) < 1, true)
    player():runControl("playpause")
    T.at = love.timer.getTime()
    return true
end)

add("fire tv pause", function()
    if cast.session.player.state ~= "PAUSED" then
        if love.timer.getTime() - T.at > 5 then check("paused over adb", cast.session.player.state, "PAUSED"); return true end
        return false
    end
    local ev = findLog(function(e) return e.kind == "adb-key-event" end)
    check("pause key", ev and ev.codes[1], 127)
    T.pos = cast.position()
    player():runControl("skipfwd")
    T.at = love.timer.getTime()
    return true
end)

add("fire tv skip", function()
    if love.timer.getTime() - T.at < 2.2 then return false end
    check("skip forward 30 s", math.floor(cast.position() - T.pos + 0.5), 30)
    T.pos = cast.position()
    player():requestSeek(T.pos + 65)
    T.at = love.timer.getTime()
    return true
end)

add("fire tv seek", function()
    if love.timer.getTime() - T.at < 2.5 then return false end
    local last
    for _, e in ipairs(logEntries()) do if e.kind == "adb-key-event" then last = e end end
    check("seek +65 s = two skips", last and #last.codes == 2 and last.codes[1] == 90, true)
    check("position after the seek", math.floor(cast.position() - T.pos + 0.5), 60)
    cast.stop(false)
    while #app.stack > 1 do app.pop() end
    T.at = love.timer.getTime()
    return true
end)

add("fire tv signs in again with the saved key", function()
    if love.timer.getTime() - T.at < 0.5 then return false end
    if not T.again then
        T.again = true
        cast.start(T.stick, server, item, 0)
    end
    local r = cast.session and cast.session.remote
    if not (r and (r.state == "ready" or r.state == "closed")) then return false end
    local sig
    for _, e in ipairs(logEntries()) do if e.kind == "adb-auth-signature" then sig = e end end
    check("signature verified by the TV", sig and sig.ok, true)
    cast.stop(false)
    return true
end)

add("disconnect", function()
    check("dial session ended", cast.session, nil)
    return true
end)

function T.start()
    love.filesystem.createDirectory("shots")
    for _, k in ipairs({ "castDialHosts", "castDialScan", "castBlock" }) do saved[k] = client.settings[k] end
    client.settings.castDialHosts = { "127.0.0.1" }
    client.settings.castDialScan = false
    client.settings.castBlock = { "Blocked FireTVStick" }
    cast.testHooks = { mdnsTarget = { "127.0.0.1", 15353 }, ssdpPort = 11900, wait = 1.5, adbPort = 15555,
                       dialDescriptions = { "http://%s:18080/dd.xml" } }
    app.push({})
    print("cast test (needs tools/fakecast.py running)")
end

local total = 0
function T.update(dt)
    total = total + dt
    local s = steps[step]
    if not s then
        for k, v in pairs(saved) do client.settings[k] = v end
        cast.stop(false)
        print(("%d checks, %d failed"):format(checks, failures))
        love.event.quit(failures == 0 and 0 or 1)
        steps = {}
        return
    end
    if total > 60 then
        failures = failures + 1
        print("  FAIL timed out at step: " .. s.name)
        step = #steps + 1
        return
    end
    if s.fn() then step = step + 1; waited = 0 end
end

return T
