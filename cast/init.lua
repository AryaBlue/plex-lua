-- Casting: play a title on a TV with the TV's own Plex app, using Reel as the remote.
--
--   Chromecast / Google TV: Cast v2 (cast/session_worker.lua). Reel launches Plex's
--   receiver app (9AC194DC, the id Plex Web uses: PlexRE web client module 3229)
--   and sends a media LOAD whose customData names the server, token and play queue,
--   the message Plex's own senders send (as pychromecast's Plex controller documents).
--   The TV streams from the server itself and reports progress to it.
--
--   DIAL (Fire TV sticks, smart TVs): cast/dial.lua opens Plex on the device. Plex
--   there takes no remote control, so on Fire TV Reel drives it over ADB instead
--   (cast/adb_worker.lua, when the stick has ADB debugging on): it reads what Plex is
--   playing from the TV's media session and presses the remote's media buttons.
--
-- Discovery (cast/discovery_worker.lua) finds Chromecasts with mDNS and DIAL devices
-- at settings.castDialHosts (SSDP sent to each, plus their usual description addresses;
-- castDialScan = true also asks the whole network). Devices named in settings.castBlock are never listed or contacted after
-- their description is read.
--
-- cast.session (nil when not casting):
--   { device, item, server, state = "starting" | "connecting" | "launching" | "loading" | "opened"
--     | "playing" | "finished" | "closed", err, player = { state, time, duration, at }, volume, muted,
--     remote = { state = "connecting" | "asking" | "ready" | "off" | "closed", err, title } (Fire TV) }

local json = require("lib.json")
local http = require("lib.http")
local client = require("plex.client")
local dial = require("cast.dial")

local cast = {}

local PLEX_APP_ID = "9AC194DC"

cast.devices = {}         -- found by the last scan, in the order they answered
cast.scanning = false
cast.session = nil

local scanCh, scanThread
local session                -- private: { thread, cmd, ev } of the running Chromecast connection
local remote                 -- private: { thread, cmd, ev } of the running Fire TV (ADB) connection

local PLEX_ANDROID = "com.plexapp.android"
-- Android key codes for the remote's buttons
local KEY = { play = 126, pause = 127, rewind = 89, ffwd = 90, stop = 86, volUp = 24, volDown = 25, mute = 164 }
-- How far Plex skips for one press of fast forward / rewind (its default skip lengths)
local ADB_SKIP_FWD, ADB_SKIP_BACK = 30, 10

-- Overrides for tests (tools/casttest.lua): mdnsTarget, ssdpPort, extraDevices, castPort.
cast.testHooks = nil

local function dllPath()
    local lf = love.filesystem
    local candidates = {}
    if not lf.isFused() then candidates[#candidates + 1] = lf.getSource() .. "/castsock.dll" end
    candidates[#candidates + 1] = lf.getSourceBaseDirectory() .. "/castsock.dll"
    for _, p in ipairs(candidates) do
        local f = io.open(p, "rb")
        if f then f:close(); return p end
    end
    return "castsock"
end

local function blocked(name, host)
    for _, b in ipairs(client.settings.castBlock or {}) do
        if b == name or b == host then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- Discovery

function cast.scan()
    if cast.scanning then return end
    cast.scanning = true
    cast.devices = {}
    scanCh = love.thread.newChannel()
    scanThread = love.thread.newThread("cast/discovery_worker.lua")
    local hooks = cast.testHooks or {}
    scanThread:start(scanCh, {
        dialHosts = client.settings.castDialHosts or {},
        dialScan = client.settings.castDialScan == true,
        block = client.settings.castBlock or {},
        mdnsTarget = hooks.mdnsTarget, ssdpPort = hooks.ssdpPort, dialDescriptions = hooks.dialDescriptions,
        chromecast = hooks.chromecast,
        wait = hooks.wait or 2.5,
    })
    for _, d in ipairs(hooks.extraDevices or {}) do cast.devices[#cast.devices + 1] = d end
end

local function addDevice(d)
    if blocked(d.name, d.host) then return end
    for _, e in ipairs(cast.devices) do if e.id == d.id then return end end
    -- DIAL devices without Plex, and Chromecast audio-only groups, are still listed;
    -- the picker says what each can do.
    cast.devices[#cast.devices + 1] = d
    print(("[cast] found %s %q at %s%s"):format(d.kind, d.name, d.host, d.model and (" (" .. d.model .. ")") or ""))
end

---------------------------------------------------------------------------
-- The server details the TV's Plex app needs to reach the server on its own.

-- The connection the TV should use: the active one, unless that is this PC's loopback
-- address (then the best LAN address of the same server).
local function tvConnection(server)
    local c = server.active
    if c and c.loopback then
        local best
        for _, o in ipairs(server.connections) do
            if not o.loopback and not o.relay and o.private and o.state == "ok" then best = best or o end
        end
        for _, o in ipairs(server.connections) do
            if not best and not o.loopback and not o.relay then best = o end
        end
        c = best or c
    end
    return c
end

function cast.serverInfo(server)
    local c = tvConnection(server)
    if not c then return nil end
    local host = c.uri:match("^%a+://%[?([^%]/:]+)") or c.address
    local port = tonumber(c.uri:match("^%a+://[^/]-:(%d+)")) or tonumber(c.port) or (c.https and 443 or 80)
    return {
        machineIdentifier = server.id,
        transcoderVideo = true, transcoderVideoRemuxOnly = false, transcoderAudio = true,
        version = server.productVersion or "1.40.0",
        myPlexSubscription = false,
        isVerifiedHostname = host:find("%.plex%.direct$") ~= nil,
        protocol = c.protocol or (c.https and "https" or "http"),
        address = host,
        port = port,
        accessToken = server.accessToken or client.settings.token,
        user = { username = client.settings.userHandle or client.settings.userName or "" },
    }
end

-- POST /playQueues: the queue the TV plays from (episodes continue in order).
-- callback(playQueue | nil, err)
function cast.createPlayQueue(server, item, callback)
    local uri = ("server://%s/com.plexapp.plugins.library%s"):format(server.id, item.key or ("/library/metadata/" .. item.ratingKey))
    local url = http.withQuery(server:baseUrl() .. "/playQueues", {
        type = "video", uri = uri, shuffle = 0, ["repeat"] = 0, continuous = item.type == "episode" and 1 or 0,
        own = 1, includeChapters = 1, includeMarkers = 1,
    })
    return http.json({ url = url, method = "POST", headers = client.headers(server.accessToken), timeout = 15 },
        function(data, err)
            local mc = data and (data.MediaContainer or data)
            if not mc or not mc.playQueueID then return callback(nil, err or "no play queue in the reply") end
            callback(mc)
        end)
end

-- The media LOAD for Plex's receiver. offset in seconds.
function cast.loadMessage(server, item, playQueue, offset)
    offset = math.floor(offset or 0)
    return {
        type = "LOAD",
        media = {
            contentId = item.key or ("/library/metadata/" .. item.ratingKey),
            streamType = "BUFFERED",
            contentType = "video",
            customData = {
                offset = offset,
                directPlay = true, directStream = true,
                subtitleSize = 100, audioBoost = 100,
                server = cast.serverInfo(server),
                containerKey = ("/playQueues/%s?own=1&window=200"):format(tostring(playQueue.playQueueID)),
            },
        },
        autoplay = true,
        currentTime = offset,
    }
end

---------------------------------------------------------------------------
-- Session

local function setState(state, err)
    local s = cast.session
    if not s then return end
    s.state, s.err = state, err or s.err
end

local function send(cmd)
    if session then session.cmd:push(cmd) end
end

-- Start playing `item` (full metadata) on `device` from `offset` seconds.
-- onDone(ok, err) once the TV accepted it or it failed.
function cast.start(device, server, item, offset, onDone)
    cast.stop(false)
    if blocked(device.name, device.host) then return onDone and onDone(false, "that device is blocked") end
    cast.session = { device = device, item = item, server = server, state = "starting", offset = offset or 0,
                     player = { state = "BUFFERING", time = offset or 0, duration = (tonumber(item.duration) or 0) / 1000,
                                at = love.timer.getTime() }, onDone = onDone }

    if device.kind == "dial" then
        return dial.start(device, server, item, offset, function(ok, err)
            local s = cast.session
            if not s or s.device ~= device then return end
            setState(ok and "opened" or "closed", err)
            if ok then cast.connectRemote() end
            if onDone then onDone(ok, err) end
            s.onDone = nil
        end)
    end

    if not server:baseUrl() then
        setState("closed", "not connected to the server")
        return onDone and onDone(false, cast.session.err)
    end
    cast.createPlayQueue(server, item, function(pq, err)
        local s = cast.session
        if not s or s.item ~= item then return end
        if not pq then
            setState("closed", "couldn't create a play queue: " .. tostring(err))
            if s.onDone then s.onDone(false, s.err); s.onDone = nil end
            return
        end
        s.playQueue = pq
        s.load = json.encode(cast.loadMessage(server, item, pq, offset))
        local cmd, ev = love.thread.newChannel(), love.thread.newChannel()
        local thread = love.thread.newThread("cast/session_worker.lua")
        session = { thread = thread, cmd = cmd, ev = ev }
        thread:start(cmd, ev, dllPath(), device.host, (cast.testHooks and cast.testHooks.castPort) or device.port or 8009,
            PLEX_APP_ID)
    end)
end

-- The Fire TV remote (ADB) for the current DIAL session.
function cast.connectRemote()
    local s = cast.session
    if not s or s.device.kind ~= "dial" or remote then return end
    if client.settings.castAdb == false then
        s.remote = { state = "off", err = "turned off in settings" }
        return
    end
    s.remote = { state = "connecting" }
    local cmd, ev = love.thread.newChannel(), love.thread.newChannel()
    local thread = love.thread.newThread("cast/adb_worker.lua")
    remote = { thread = thread, cmd = cmd, ev = ev }
    thread:start(cmd, ev, dllPath(), s.device.host, (cast.testHooks and cast.testHooks.adbPort) or 5555,
        love.filesystem.getSaveDirectory() .. "/adbkey", PLEX_ANDROID)
end

local function key(code, count)
    if remote then remote.cmd:push({ op = count and "keys" or "key", code = code, count = count }) end
end

local function viaAdb()
    local s = cast.session
    return s ~= nil and s.device.kind == "dial"
end

-- Whether play / pause / seek reach the TV now.
function cast.canControl()
    local s = cast.session
    if not s or s.state == "closed" then return false end
    if s.device.kind == "dial" then return s.remote ~= nil and s.remote.state == "ready" end
    return s.state == "playing" or s.state == "finished"
end

-- Playback controls. Seek takes seconds; on Fire TV it is made of skip presses,
-- so it lands near the point, and the TV's report then shows where it is.
function cast.play()
    if viaAdb() then return key(KEY.play) end
    send({ op = "media", type = "PLAY" })
end
function cast.pause()
    if viaAdb() then return key(KEY.pause) end
    send({ op = "media", type = "PAUSE" })
end
function cast.seek(t)
    local s = cast.session
    if not s then return end
    t = math.max(0, t)
    if viaAdb() then
        local delta = t - cast.position()
        local n = delta > 0 and math.floor(delta / ADB_SKIP_FWD + 0.5) or math.floor(-delta / ADB_SKIP_BACK + 0.5)
        if n == 0 and math.abs(delta) >= 5 then n = 1 end
        if n == 0 then return end
        key(delta > 0 and KEY.ffwd or KEY.rewind, n)
        t = cast.position() + (delta > 0 and n * ADB_SKIP_FWD or -n * ADB_SKIP_BACK)
    else
        send({ op = "media", type = "SEEK", currentTime = t })
    end
    s.player.time, s.player.at = math.max(0, t), love.timer.getTime()
end
-- Skip by `delta` seconds (the player's back / forward buttons); on Fire TV one
-- press of Plex's own skip, whatever its length.
function cast.skip(delta)
    local s = cast.session
    if not s then return end
    if viaAdb() then
        key(delta > 0 and KEY.ffwd or KEY.rewind)
        s.player.time = math.max(0, cast.position() + (delta > 0 and ADB_SKIP_FWD or -ADB_SKIP_BACK))
        s.player.at = love.timer.getTime()
        return
    end
    cast.seek(cast.position() + delta)
end
-- Volume 0..1 (Chromecast; the TV reports it back in s.volume).
function cast.setVolume(level)
    local s = cast.session
    level = math.max(0, math.min(1, level))
    if s then s.volume, s.muted = level, false end
    send({ op = "volume", level = level })
end
function cast.setMuted(on)
    local s = cast.session
    if not s then return end
    if viaAdb() then return key(KEY.mute) end
    s.muted = on
    send({ op = "volume", muted = on })
end
-- One step louder (dir = 1) or quieter (-1).
function cast.volumeStep(dir)
    local s = cast.session
    if not s then return end
    if viaAdb() then return key(dir > 0 and KEY.volUp or KEY.volDown) end
    cast.setVolume((s.volume or 0.5) + dir * 0.05)
end
-- Whether Reel knows the TV's volume level (it doesn't over ADB).
function cast.hasVolumeLevel()
    local s = cast.session
    return s ~= nil and s.device.kind == "chromecast" and s.volume ~= nil
end

-- Load the title again where it is (Chromecast): picks up audio and subtitle choices
-- saved on the server.
function cast.reload()
    local s = cast.session
    if not s or s.device.kind ~= "chromecast" or not s.playQueue or not session then return end
    session.cmd:push({ op = "load", payload = json.encode(cast.loadMessage(s.server, s.item, s.playQueue, cast.position())) })
end

-- Stop casting. closeApp = true also stops playback (and on Chromecast closes Plex
-- on the TV); false just disconnects and leaves it playing.
function cast.stop(closeApp)
    if session then
        send({ op = closeApp and "stopApp" or "close" })
        session = nil
    end
    if remote then
        if closeApp then key(KEY.stop) end
        remote.cmd:push({ op = "close" })
        remote = nil
    end
    cast.session = nil
end

function cast.isActive()
    local s = cast.session
    return s ~= nil and s.state ~= "closed"
end

-- Current position in seconds, moving on between status messages while playing.
function cast.position()
    local s = cast.session
    if not s then return 0 end
    local p = s.player
    if p.state == "PLAYING" then
        local t = p.time + (love.timer.getTime() - p.at)
        return p.duration > 0 and math.min(t, p.duration) or t
    end
    return p.time
end

local function onMedia(payload)
    local s = cast.session
    if not s then return end
    local ok, data = pcall(json.decode, payload)
    local st = ok and type(data.status) == "table" and data.status[1]
    if not st then return end
    local p = s.player
    p.state = st.playerState or p.state
    if tonumber(st.currentTime) then p.time, p.at = tonumber(st.currentTime), love.timer.getTime() end
    local media = type(st.media) == "table" and st.media
    if media and tonumber(media.duration) then p.duration = tonumber(media.duration) end
    if p.state == "IDLE" and st.idleReason == "FINISHED" then setState("finished") end
    if p.state == "PLAYING" or p.state == "PAUSED" or p.state == "BUFFERING" then
        if s.state ~= "playing" then
            setState("playing")
            if s.onDone then s.onDone(true); s.onDone = nil end
        end
    end
end

-- What Plex on the Fire TV reports. Its media session names the title but not the
-- length, so the length is the item's when the title is the one Reel sent.
local function onAdbStatus(s, m)
    local p = s.player
    s.remote.title = m.title
    if not m.found then
        p.state = "IDLE"
        if s.state == "playing" then setState("opened") end
        return
    end
    p.state, p.time, p.at = m.state, m.position, m.at
    local mine = not m.title or (s.item.title and m.title:find(s.item.title, 1, true) == 1)
    p.duration = mine and (tonumber(s.item.duration) or 0) / 1000 or 0
    if m.state ~= "IDLE" then setState("playing") elseif s.state == "playing" then setState("opened") end
end

function cast.update(dt)
    if scanThread then
        local err = scanThread:getError()
        if err then print("[cast] discovery crashed: " .. err); cast.scanning = false; scanThread = nil end
        while scanCh do
            local m = scanCh:pop()
            if not m then break end
            if m.ev == "device" then addDevice(m.device)
            elseif m.ev == "done" then cast.scanning = false; scanThread = nil end
        end
    end

    if session then
        local err = session.thread:getError()
        if err then
            setState("closed", "cast connection crashed: " .. err)
            print("[cast] " .. err)
            session = nil
        end
    end
    if remote then
        local s = cast.session
        local err = remote.thread:getError()
        if err then
            print("[cast] remote crashed: " .. err)
            if s and s.remote then s.remote.state, s.remote.err = "closed", err end
            remote = nil
        end
        while remote do
            local m = remote.ev:pop()
            if not m then break end
            if m.ev == "state" then
                if s and s.remote then
                    s.remote.state, s.remote.err = m.state, m.err or s.remote.err
                    if m.state == "closed" and m.err then print("[cast] remote: " .. m.err) end
                end
                if m.state == "closed" then remote = nil end
            elseif m.ev == "status" and s and s.remote then
                onAdbStatus(s, m)
            end
        end
    end

    -- the receiver reports changes itself; this also catches the position drifting
    if session and cast.session and cast.session.state == "playing" then
        session.poll = (session.poll or 0) + dt
        if session.poll > 5 then session.poll = 0; session.cmd:push({ op = "media", type = "GET_STATUS" }) end
    end
    while session do
        local m = session.ev:pop()
        if not m then break end
        local s = cast.session
        if m.ev == "state" then
            if m.state == "ready" then
                setState("loading")
                if s and s.load then session.cmd:push({ op = "load", payload = s.load }); s.load = nil end
            elseif m.state == "closed" then
                setState("closed", m.err)
                if m.err then print("[cast] closed: " .. m.err) end
                if s and s.onDone then s.onDone(false, m.err or "the connection closed"); s.onDone = nil end
                session = nil
            else
                setState(m.state)
            end
        elseif m.ev == "media" then
            onMedia(m.payload)
        elseif m.ev == "receiver" then
            local ok, data = pcall(json.decode, m.payload)
            local vol = ok and data.status and data.status.volume
            if s and type(vol) == "table" then s.volume = tonumber(vol.level); s.muted = vol.muted == true end
        elseif m.ev == "error" then
            print("[cast] error: " .. tostring(m.err))
            if s and s.state == "loading" then
                setState("closed", "the TV couldn't play it (" .. tostring(m.err) .. ")")
                if s.onDone then s.onDone(false, s.err); s.onDone = nil end
            end
        end
    end
end

return cast
