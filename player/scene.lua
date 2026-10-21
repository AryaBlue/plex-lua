-- Full-screen player: lib/VideoStream.lua decodes picture and sound on its own
-- thread (a stalled network or slow decoder doesn't hold up the app), picture
-- slaved to the audio clock. Overlay with title, seek bar and controls.
-- Subtitles: separate subtitle files are drawn here; tracks inside the video
-- file are pulled out by the server (text) or burned in (pictures); see plex/subtitles.lua.
-- Audio: the track menu (C) also lists the audio tracks. Direct play picks the
-- track in the file (VideoStream's track option); converted streams use the
-- choice saved on the server; a track Windows can't decode (DTS, TrueHD) makes
-- the server convert the sound.
-- Quality: the same menu ends with the quality list (playback.QUALITIES);
-- a choice is saved as the default for this kind of connection (home/away)
-- and the stream reopens at the current point.
-- Auto play: for episodes, a "Playing Next" card (as in Plex's AudioVideoUpNext)
-- appears when the credits start, or the countdown's length before the end
-- when the server has no credits marker, and starts the next episode when the
-- countdown runs out (Settings: autoPlay, autoPlayDelay).
--
-- Streams come from plex/playback.lua: the original file (direct play) when
-- Windows can decode it, otherwise the server's converted stream. Converted
-- streams can't seek inside the file, so seeking restarts them at an offset.
--
-- Casting (cast/init.lua): the Cast button beside Subtitles sends the title to a TV
-- (ui/castpicker.lua) and this screen becomes its remote: the picture is the title's
-- art, and the seek bar, play / pause, skips, volume and subtitles drive the TV.
-- The Cast button then offers playing it here again, stopping, or disconnecting
-- (leaving it playing). Player.new(server, item, { cast = true }) opens the remote
-- for what is already casting.

local VideoStream = require("lib.VideoStream")
local theme = require("theme")
local gfx = require("ui.gfx")
local W = require("ui.widgets")
local api = require("plex.api")
local http = require("lib.http")
local client = require("plex.client")
local playback = require("plex.playback")
local input = require("lib.input")
local mouse = require("ui.mouse")
local subs = require("plex.subtitles")
local cast = require("cast")

local Player = {}
Player.__index = Player

local OVERLAY_TIME = 3.5
local SEEK_STEP = 30             -- arrows and the skip buttons
local SEEK_SETTLE = 0.45        -- wait this long after the last seek press before seeking
local TIMELINE_INTERVAL = 10
local DOUBLE_CLICK = 0.35       -- seconds between clicks that count as a double click
local VOLUME_STEP = 0.1

-- The row under the seek bar, left to right (fullscreen sits at the far right).
local CONTROLS = { "playpause", "skipback", "skipfwd", "volume", "cast", "subtitles", "fullscreen" }

local sessions = 0
local function nextSession()
    sessions = sessions + 1
    return sessions
end

function Player.new(server, item, opts)
    opts = opts or {}
    local self = setmetatable({
        server = server, item = item,
        state = "preparing",      -- preparing | opening | playing | paused | ended | error
        overlay = OVERLAY_TIME,
        sessionId = client.settings.clientIdentifier .. "-" .. tostring(os.time()) .. "-" .. nextSession(),
        timelineTimer = 0,
        duration = (tonumber(item.duration) or 0) / 1000,
        focus = "bar",            -- keyboard/controller focus: back | bar | controls
        ctrl = 1,                 -- focused entry of CONTROLS
        volume = tonumber(client.settings.volume) or 1,
        muted = client.settings.muted == true,
        anim = {},
    }, Player)
    self.subStreams, self.partId = subs.streams(item)
    self.audioStreams = subs.audioStreams(item)
    for _, st in ipairs(self.audioStreams) do
        if st.selected then self.audioTrack = st end
    end
    self.audioTrack = self.audioTrack or self.audioStreams[1]
    self.quality = playback.quality(server)
    self.creditsAt = api.creditsStart(item)
    local off = tonumber(item.viewOffset)
    self.startAt = opts.startAt or (off and off / 1000 or 0)
    if self.startAt < 5 or self.startAt > self.duration - 10 then self.startAt = 0 end
    if opts.cast then self.casting, self.state, self.overlay = true, "casting", math.huge end
    return self
end

function Player:enter()
    if self.item.type == "episode" then
        api.nextEpisode(self.server, self.item, function(nextItem)
            if not self.closed then self.nextItem = nextItem end
        end)
    end
    if self.casting then return end
    self:startHere(self.startAt)
end

-- Start playing here at `t`, with the tracks chosen last time (saved on the server).
function Player:startHere(t)
    if not self.tracksSet then
        self.tracksSet = true
        for _, st in ipairs(self.subStreams) do
            if st.selected then self:setSubtitle(st, true) end
        end
    end
    self:prepare(t)
end

-- Ask playback.plan for a stream starting at `offset`, then open it on the next frames.
function Player:prepare(offset, forceTranscode)
    if self.connecting then self.connecting:release(); self.connecting = nil end
    self.state = "preparing"
    self.prepareOffset = offset
    self.prepareGen = (self.prepareGen or 0) + 1
    local gen = self.prepareGen
    -- sound Windows can't decode: the server converts it (the picture can still be copied)
    if self.audioTrack and not playback.canDecodeAudio(self.audioTrack.codec, self.audioTrack.channels) then forceTranscode = true end
    -- the server wouldn't send the file itself (see open), or Windows couldn't decode
    -- its sound (see opened): keep asking it to convert
    if self.fileError or self.audioConvert then forceTranscode = true end
    local opts = { offset = offset, forceTranscode = forceTranscode, burnSubtitle = self.burn, quality = self.quality }
    local function got(plan, err)
        if self.closed or gen ~= self.prepareGen then return end   -- replaced by a newer prepare
        if not plan then
            self.state = "error"
            self.error = self:explain(err)
            return
        end
        self.plan = plan
        self.state = "opening"
        self.openDelay = 2          -- let the "Starting" frame draw first
    end
    playback.plan(self.server, self.item, self.sessionId, opts, got)
end

-- Readable text for the network errors Media Foundation reports while streaming.
local NET_ERRORS = {
    ["0x80072f78"] = "the server sent an invalid response",
    ["0x80072efe"] = "the connection to the server was dropped",
    ["0x80072eff"] = "the connection to the server was reset",
    ["0x80072ee2"] = "the server stopped responding",
    ["0x80072efd"] = "couldn't connect to the server",
    ["0xc00d2ee2"] = "the server took too long to start the stream (it may be busy converting)",
}
local function describeError(err)
    local msg = tostring(err):gsub("^.-NativeVideo: ", "")
    local code = msg:match("0x%x+")
    local nice = code and NET_ERRORS[code:lower()]
    return nice and (nice .. " (" .. code .. ")") or msg
end

-- An error to show, led by the file's own problem when the server refused to send it.
function Player:explain(err)
    if not self.fileError then return err end
    return ("The server couldn't send this file (%s), so it may be damaged or unreadable on the server. " ..
            "Converting it instead failed too: %s"):format(self.fileError, tostring(err))
end

local AUDIO_RETRIES = 2           -- reconnects when only the sound failed to open
local RECOVERY_LIMIT = 3          -- reconnect attempts...
local RECOVERY_WINDOW = 60        -- ...within this many seconds before giving up

-- A read or seek failed mid-stream: reopen at the last good position, or give up.
function Player:streamFailed(err)
    local reason = describeError(err)
    print("[player] stream error: " .. tostring(err))
    local now = love.timer.getTime()
    self.recoveries = self.recoveries or {}
    while self.recoveries[1] and now - self.recoveries[1] > RECOVERY_WINDOW do table.remove(self.recoveries, 1) end
    self.recoveries[#self.recoveries + 1] = now
    local t = self.lastGoodTime or self.prepareOffset or 0
    self:closeStreams()
    if #self.recoveries > RECOVERY_LIMIT then
        self.state = "error"
        self.error = "Playback stopped: " .. self:explain(reason) .. ". It kept failing after " .. RECOVERY_LIMIT ..
                     " reconnect attempts, so check that the server is reachable and try again."
        app.toast = nil
        api.timeline(self.server, self.item, "stopped", t, self.duration, self.sessionId)
        return
    end
    app.notify("Reconnecting: " .. reason)
    self.pendingSeek = nil
    self.resumePaused = self.state == "paused"
    self:prepare(t)
end

-- Volume 0..1 and mute, applied to the sound and remembered between sessions.
function Player:applyVolume()
    if self.audio then self.audio:setVolume(self.muted and 0 or self.volume ^ 2) end   -- squared: closer to how loudness is heard
end

function Player:setVolume(v, muted)
    if self.casting then
        if muted ~= nil then cast.setMuted(muted) else cast.setVolume(v) end
        return
    end
    self.volume = math.max(0, math.min(1, v))
    if muted ~= nil then self.muted = muted elseif v > 0 then self.muted = false end
    self:applyVolume()
    client.settings.volume, client.settings.muted = self.volume, self.muted
    self.volumeDirty = true      -- saved to disk once the user stops adjusting (see update)
    self.overlay = math.max(self.overlay, OVERLAY_TIME)
end

-- One volume step up (dir = 1) or down (-1), here or on the TV.
function Player:stepVolume(dir, step)
    if self.casting then return cast.volumeStep(dir) end
    self:setVolume(self.volume + dir * (step or VOLUME_STEP))
end

-- Show subtitle track `st` (nil = off). A separate file, or a text track the
-- server can pull out of the video, is fetched and drawn here; a picture track
-- (or text that couldn't be pulled out) needs the server to burn it in, which
-- means reopening the stream (converted) at the current point. initial:
-- before the first open, and not a new choice to save.
function Player:setSubtitle(st, initial, forceBurn)
    self.sub, self.cues, self.cueHint = st, nil, 1
    if not initial then subs.select(self.server, self.partId, st) end
    if st and (st.sidecar or (st.extract and not forceBurn)) then
        local function got(cues, err)
            if self.sub ~= st or self.closed then return end
            if cues then self.cues = cues; return end
            if st.sidecar then return app.notify("Couldn't load subtitles: " .. tostring(err), "error") end
            print("[subs] couldn't extract track " .. tostring(st.id) .. ": " .. tostring(err) .. "; burning it in")
            self:setSubtitle(st, false, true)
        end
        if st.sidecar then subs.load(self.server, st, got)
        else subs.loadEmbedded(self.server, self.item, st, self.sessionId, got) end
    end
    local burn = st and (forceBurn or not (st.sidecar or st.extract)) and st.id or nil
    if burn == self.burn then return end
    self.burn = burn
    if initial then return end
    if burn then app.notify("Adding subtitles: the server is converting the video with them drawn in…") end
    self:restart()
end

-- Reopen the stream at the current point (a track changed).
function Player:restart()
    if not (self.video or self.plan) then
        -- still working out the first stream: start over with the new choice
        if self.state == "preparing" then self:prepare(self.prepareOffset) end
        return
    end
    local t = self:mediaTime()
    self.resumePaused = self.state == "paused"
    if self.video then self:report("stopped") end
    self:closeStreams()
    self.pendingSeek = nil
    self:prepare(t)
end

-- Switch to audio track `st`: saved on the server (as Plex's apps do), then
-- the stream reopens where it was. A converted stream waits for the save,
-- since the server reads the choice from there.
function Player:setAudio(st)
    if not st or st == self.audioTrack then return end
    self.audioTrack = st
    self.audioConvert = nil
    local direct = self.plan and self.plan.mode == "direct" and playback.canDecodeAudio(st.codec, st.channels)
    if direct then
        subs.selectAudio(self.server, self.partId, st)
        return self:restart()
    end
    local t = self:mediaTime()
    self.resumePaused = self.state == "paused"
    if self.video then self:report("stopped") end
    self:closeStreams()
    self.pendingSeek = nil
    self.state, self.prepareOffset = "preparing", t
    local gen = (self.prepareGen or 0) + 1
    self.prepareGen = gen                       -- anything already being prepared is stale now
    subs.selectAudio(self.server, self.partId, st, function()
        if self.closed or self.prepareGen ~= gen or self.audioTrack ~= st then return end
        self:prepare(t)
    end)
end

-- Switch quality: remembered for this kind of connection, then reopen here.
function Player:setQuality(q)
    if q == self.quality then return end
    self.quality = q
    client.set(playback.settingKey(self.server), q.kbps)
    self:restart()
end

local MENU_SHOWN = 5     -- tracks listed per section before a "Show N more" row

-- Menu entries: the audio tracks (when there are any), "Off" and the subtitle
-- tracks, then the qualities. { kind = "audio" | "sub" | "quality" | "more", stream, label, note, heading }
-- A long section lists its first MENU_SHOWN tracks (and the one in use) and a
-- "more" entry (section = its kind) until expanded[kind].
function Player:menuEntries(expanded)
    expanded = expanded or {}
    local list = {}
    local function addTracks(kind, streams, current, make)
        local hidden = 0
        for i, st in ipairs(streams) do
            if expanded[kind] or i <= MENU_SHOWN or st == current then
                list[#list + 1] = make(i, st)
            else
                hidden = hidden + 1
            end
        end
        if hidden > 0 then
            list[#list + 1] = { kind = "more", section = kind, label = ("Show %d more"):format(hidden) }
        end
    end
    addTracks("audio", self.audioStreams, self.audioTrack, function(i, st)
        return { kind = "audio", stream = st, label = st.label, heading = i == 1 and "Audio" or nil,
                 note = not playback.canDecodeAudio(st.codec, st.channels) and "server converts it" or nil }
    end)
    list[#list + 1] = { kind = "sub", label = "Off", heading = "Subtitles",
                        note = #self.subStreams == 0 and "this video has none" or nil }
    addTracks("sub", self.subStreams, self.sub, function(_, st)
        local note = not (st.sidecar or st.extract) and "server draws it in" or nil
        if st.forced and not st.label:lower():find("forced", 1, true) then note = "forced" .. (note and ", " .. note or "") end
        return { kind = "sub", stream = st, label = st.label, note = note }
    end)
    if self.casting then return list end     -- the TV picks its own quality
    local media = self.item.Media and self.item.Media[1]
    local bitrate = media and tonumber(media.bitrate)
    for i, q in ipairs(playback.QUALITIES) do
        local note
        if q.kbps == 0 then note = bitrate and ("%.1f Mbps file"):format(bitrate / 1000)
        elseif bitrate and q.kbps >= bitrate then note = "same as Original" end
        list[#list + 1] = { kind = "quality", stream = q, label = q.label, note = note,
                            heading = i == 1 and (playback.isHome(self.server) and "Quality (home)" or "Quality (away)") or nil }
    end
    return list
end

function Player:openSubtitleMenu()
    local entries = self:menuEntries()
    local sel = 1
    for i, e in ipairs(entries) do
        if e.kind == "sub" and e.stream == self.sub then sel = i end      -- start on the subtitle in use
    end
    self.subMenu = { sel = sel, entries = entries, scroll = 0, expanded = {} }
    self.overlay = math.huge
end

function Player:closeSubtitleMenu()
    self.subMenu = nil
    self.overlay = (self.state == "paused" or self.casting) and math.huge or OVERLAY_TIME
end

function Player:chooseSubtitle(i)
    local m = self.subMenu
    local e = m and m.entries[i]
    if e and e.run then
        self:closeSubtitleMenu()
        return e.run()
    end
    if e and e.kind == "more" then
        -- list the rest of that section; the selection lands on the first one revealed
        m.expanded[e.section] = true
        m.entries = self:menuEntries(m.expanded)
        return
    end
    self:closeSubtitleMenu()
    if not e then return end
    if self.casting then
        -- saved on the server, then the TV loads the title again with it
        if e.kind == "audio" and e.stream ~= self.audioTrack then
            self.audioTrack = e.stream
            subs.selectAudio(self.server, self.partId, e.stream, function() cast.reload() end)
        elseif e.kind == "sub" and e.stream ~= self.sub then
            self.sub, self.cues = e.stream, nil
            subs.select(self.server, self.partId, e.stream, function() cast.reload() end)
        end
        return
    end
    if e.kind == "audio" then return self:setAudio(e.stream) end
    if e.kind == "quality" then return self:setQuality(e.stream) end
    if e.stream ~= self.sub then self:setSubtitle(e.stream) end
end

function Player:toggleFullscreen()
    app.toggleFullscreen()
    self.overlay = math.max(self.overlay, OVERLAY_TIME)
end

function Player:closeStreams()
    if self.connecting then self.connecting:release(); self.connecting = nil end
    self.audio = nil                  -- part of the video's stream
    if self.video then self.video:release(); self.video = nil end
end

-- Start opening the stream on its own thread (lib/VideoStream.lua); update()
-- polls it and calls opened() or openFailed().
function Player:open()
    local plan = self.plan
    -- one reader (one connection) for picture and sound; two would download the file twice.
    -- The file holds every audio track; a converted stream only the chosen one, and
    -- can't seek: its clock starts where the server's conversion did (relative).
    local direct = plan.mode == "direct"
    self.connecting = VideoStream.open(plan.url, {
        track = direct and self.audioTrack and self.audioTrack.ordinal or 1,
        seekable = direct, relative = not direct,
        startAt = direct and self.prepareOffset and self.prepareOffset > 0 and self.prepareOffset or nil,
    })
end

function Player:pollOpen()
    local s = self.connecting
    s:poll()
    if s.state == "ready" then
        self.connecting = nil
        self:opened(s)
        if self.resumePaused and self.video then self:setPlaying(false); self.resumePaused = nil end
    elseif s.state == "failed" then
        self.connecting = nil
        s:release()
        self:openFailed("NativeVideo: " .. tostring(s.error))
    end
end

function Player:openFailed(v)
    local plan = self.plan
    local msg = tostring(v):gsub("^.-NativeVideo: ", "")
    if plan.mode == "direct" and msg:find("no Windows decoder", 1, true) then
        return self:prepare(self.prepareOffset, true)
    end
    local function fail()
        -- while reconnecting, a failed reopen counts as another attempt
        if self.recoveries and #self.recoveries > 0 then return self:streamFailed(v) end
        self.state = "error"
        self.error = self:explain(describeError(v))
    end
    -- Media Foundation reports a refused file as a network error (often a timeout).
    -- Ask for the file's first byte to tell the two apart: a server that won't send
    -- the file may still convert it, since the converter reads it from disk itself.
    if plan.mode == "direct" and not self.fileError and plan.url:match("^https?://") then
        self.state = "preparing"
        local gen = self.prepareGen
        http.request({ url = plan.url, headers = { Range = "bytes=0-0" }, timeout = 15 }, function(res)
            if self.closed or gen ~= self.prepareGen then return end
            if res and res.status >= 400 then
                self.fileError = "HTTP " .. res.status
                print("[player] the server answered " .. self.fileError .. " for the file; asking it to convert instead")
                return self:prepare(self.prepareOffset, true)
            end
            fail()
        end)
        return
    end
    return fail()
end

function Player:opened(v)
    local plan = self.plan
    self.video = v
    if v.audio then
        self.audio = v.audio
        self.audioError = nil
        self:applyVolume()
    else
        self.audioError = describeError(v.audioError or "no audio track")
        -- A missing track or an undecodable format won't fix itself. Anything else
        -- (refused connection, busy server, stream limit) gets a reconnect shortly.
        local permanent = self.audioError:find("no audio track", 1, true) or self.audioError:find("decoder", 1, true)
        -- sound Windows can't decode in a file played as it is: the server converts it
        if plan.mode == "direct" and self.audioError:find("decoder", 1, true) and not self.audioConvert then
            print("[player] no decoder for the sound, asking the server to convert: " .. self.audioError)
            self.audioConvert = true
            self:closeStreams()
            return self:prepare(self.prepareOffset or 0)
        end
        self.audioRetries = self.audioRetries or 0
        if not permanent and self.audioRetries < AUDIO_RETRIES then
            self.audioRetries = self.audioRetries + 1
            self.audioRetryAt = love.timer.getTime() + 3
            app.notify(("No sound yet (%s). Retrying…"):format(self.audioError), "error")
        else
            self.audioRetryAt = nil
            if self.notifiedAudioError ~= self.audioError then
                app.notify("No sound: " .. self.audioError, "error")
                self.notifiedAudioError = self.audioError
            end
        end
    end

    if self.duration <= 0 then self.duration = plan.duration > 0 and plan.duration or v:getDuration() end
    -- media time = offsetBase + the stream's clock (a converted stream's counts from its start)
    self.offsetBase = plan.offsetBase or 0
    self:setPlaying(true)
end

function Player:mediaTime()
    if self.pendingSeek then return self.pendingSeek end
    if self.casting then return cast.position() end
    if self.video then return self.offsetBase + self.video:tell() end
    return self.prepareOffset or 0
end

-- Seek inside an open direct-play stream.
function Player:seekStream(t)
    -- picture and sound together, on the stream's thread
    if self.video then self.video:seek(t) end
end

-- Request a seek; applied once the user stops pressing (see update).
function Player:requestSeek(t)
    if self.casting then
        if not cast.canControl() then return end
    elseif not self.video then
        return
    end
    t = math.max(0, self.duration > 0 and math.min(t, self.duration - 2) or t)
    self.pendingSeek = t
    self.seekTimer = SEEK_SETTLE
    self.overlay = OVERLAY_TIME
end

function Player:applySeek()
    local t = self.pendingSeek
    self.pendingSeek = nil
    if self.casting then return cast.seek(t) end
    if self.plan.mode == "direct" then
        self.lastGoodTime = t
        local ok, err = pcall(self.seekStream, self, t)
        if not ok then return self:streamFailed(err) end
        self:report()
    else
        local wasPaused = self.state == "paused"
        self:report("stopped")
        self:closeStreams()
        self.resumePaused = wasPaused
        self:prepare(t)
    end
end

function Player:setPlaying(on)
    if self.casting then
        if on then cast.play() else cast.pause() end
        return
    end
    if not self.video then return end
    if on then
        self.video:play()
        self.state = "playing"
        -- pausing pinned the controls; let them hide again (e.g. the double-click's
        -- first click paused and the second resumed)
        if self.overlay == math.huge and not self.subMenu then self.overlay = OVERLAY_TIME end
    else
        self.video:pause()
        self.state = "paused"
        self.overlay = math.huge
    end
    self:report()
end

function Player:report(state)
    if not self.video then return end
    state = state or (self.state == "paused" and "paused" or self.state == "ended" and "stopped" or "playing")
    if state == "playing" and self.audio and self.audio:isStarved() then state = "buffering" end
    api.timeline(self.server, self.item, state, self:mediaTime(), self.duration, self.sessionId)
    self.timelineTimer = 0
end

-- Whether it's playing (here or on the TV).
function Player:isPlaying()
    if self.casting then
        local s = cast.session
        return s ~= nil and (s.player.state == "PLAYING" or s.player.state == "BUFFERING")
    end
    return self.state == "playing"
end

-- Dragging the seek bar or volume slider with the left button held.
function Player:updateDrag()
    if self.drag and love.mouse.isDown(1) then
        local mx = love.mouse.getX()
        local d = self.drag
        local frac = math.max(0, math.min(1, (mx - d.x) / d.w))
        if d.kind == "seek" then self:requestSeek(frac * self.duration) else self:setVolume(frac) end
    elseif self.drag then
        self.drag = nil
    end
end

function Player:updateCasting(dt)
    love.mouse.setVisible(true)
    local s = cast.session
    if not s or s.state == "closed" then
        -- stopped here, on the TV, or it never started
        if s then
            app.notify("Casting stopped" .. (s.err and (": " .. s.err) or ""), s.err and "error" or nil)
            cast.stop(false)
        end
        return app.pop()
    end
    self.duration = s.player.duration
    if self.pendingSeek then
        self.seekTimer = self.seekTimer - dt
        if self.seekTimer <= 0 then self:applySeek() end
    end
    self:updateDrag()
end

function Player:update(dt)
    if self.casting then return self:updateCasting(dt) end
    if self.upNext and not self.upNext.dismissed and client.settings.autoPlay ~= false
        and (self.state == "playing" or self.state == "ended") and not self.pendingSeek then
        self.upNext.left = self.upNext.left - dt
        if self.upNext.left <= 0 then return self:playNext() end
    end
    if self.state == "ended" then love.mouse.setVisible(true); return end   -- waiting on "Playing Next"
    if self.state == "opening" then
        if self.connecting then return self:pollOpen() end
        self.openDelay = self.openDelay - 1
        if self.openDelay <= 0 then self:open() end
        return
    end
    if not self.video then return end

    if self.pendingSeek then
        self.seekTimer = self.seekTimer - dt
        if self.seekTimer <= 0 then self:applySeek() end
        if not self.video then return end
    end

    if self.state == "playing" and not self.pendingSeek then
        -- reads go over the network; a failure reconnects instead of crashing
        local ok, err = pcall(self.video.update, self.video, dt)
        if not ok then return self:streamFailed(err) end
        self.lastGoodTime = self:mediaTime()
        self:checkUpNext()
        if self.audio then
            if self.audio:isFinished() and (self.video.eof or self:mediaTime() >= self.duration - 1) then self:finish() end
        elseif not self.video:isPlaying() then
            self:finish()
        end
    elseif self.state == "paused" and not self.pendingSeek then
        -- keep taking what the stream's thread decodes (a seek while paused shows its frame)
        local ok, err = pcall(self.video.update, self.video, 0)
        if not ok then return self:streamFailed(err) end
    end

    -- sound failed to open for a transient reason: reopen both streams at the current point
    -- (a converted stream can't be joined mid-way, so audio alone can't be reopened)
    if self.audioRetryAt and love.timer.getTime() >= self.audioRetryAt and self.video and not self.pendingSeek then
        self.audioRetryAt = nil
        local t = self:mediaTime()
        print(("[player] reopening at %.1fs to get sound (attempt %d)"):format(t, self.audioRetries))
        self.resumePaused = self.state == "paused"
        self:closeStreams()
        return self:prepare(t)
    end

    self:updateDrag()
    if self.volumeDirty and not self.drag then
        self.volumeDirty = nil
        client.save()
    end

    if self.overlay ~= math.huge then self.overlay = math.max(0, self.overlay - dt) end
    -- hide the pointer while watching
    love.mouse.setVisible(self.state ~= "playing" or love.timer.getTime() - mouse.lastMove < 2.5)
    self.timelineTimer = self.timelineTimer + dt
    if self.timelineTimer >= TIMELINE_INTERVAL then self:report() end
end

function Player:finish()
    if self.state == "ended" then return end
    self.state = "ended"
    self:report("stopped")
    -- the next episode is coming up: stay on the card until it starts or is cancelled
    if self.nextItem and not (self.upNext and self.upNext.dismissed) then
        if not self.upNext then self:showUpNext() end
        return
    end
    app.pop()
end

-- How long "Playing Next" counts down (seconds).
local function autoPlayDelay()
    return math.max(1, tonumber(client.settings.autoPlayDelay) or 10)
end

-- Show the card once playback reaches the credits (or the countdown's length
-- before the end); hide it again if the viewer seeks back out of them.
function Player:checkUpNext()
    if not self.nextItem or self.duration <= 0 then return end
    local at = self.creditsAt or (self.duration - autoPlayDelay())
    local t = self:mediaTime()
    if t >= at then
        if not self.upNext then self:showUpNext() end
    elseif self.upNext and t < at - 2 then
        self.upNext = nil
    end
end

function Player:showUpNext()
    self.upNext = { left = autoPlayDelay(), total = autoPlayDelay(), button = 1 }
end

-- Cancel: keep watching (the credits), or leave if this one has ended.
function Player:dismissUpNext()
    if not self.upNext then return end
    self.upNext.dismissed = true
    if self.state == "ended" then app.pop() end
end

function Player:playNext()
    local nextItem = self.nextItem
    if not nextItem or self.closed then return end
    local server = self.server
    app.pop()                              -- reports this one stopped
    app.push(Player.new(server, nextItem))
end

-- The title went to a TV (ui/castpicker.lua): stop here and become its remote.
function Player:castStarted()
    if self.video then self:report("stopped") end
    if self.plan and self.plan.mode == "transcode" then api.stopTranscode(self.server, self.sessionId) end
    self:closeStreams()
    self.prepareGen = (self.prepareGen or 0) + 1      -- a stream still being prepared is dropped
    self.plan, self.pendingSeek, self.upNext, self.subMenu, self.drag = nil, nil, nil, nil, nil
    self.casting, self.state, self.overlay = true, "casting", math.huge
end

-- "Play on this computer": take it back from the TV at the point it reached.
function Player:castHere()
    local t = cast.position()
    cast.stop(true)
    self.casting = false
    self.duration = (tonumber(self.item.duration) or 0) / 1000
    self.overlay = OVERLAY_TIME
    self:startHere(t)
end

function Player:openCastMenu()
    local s = cast.session
    if not s then return end
    local tv = s.device.kind == "chromecast"
    self.subMenu = { sel = 1, scroll = 0, expanded = {}, cast = true, entries = {
        { kind = "cast", label = "Play on this computer", heading = "Casting to " .. s.device.name,
          run = function() self:castHere() end },
        { kind = "cast", label = "Stop casting", note = tv and "closes Plex on the TV" or "stops it on the TV",
          run = function() cast.stop(true); app.pop() end },
        { kind = "cast", label = "Disconnect", note = "keeps playing on the TV",
          run = function() cast.stop(false); app.pop() end },
    } }
end

-- The controls while casting.
function Player:runCastControl(name)
    local s = cast.session
    if not s then return end
    if name == "cast" then
        if self.subMenu and self.subMenu.cast then return self:closeSubtitleMenu() end
        return self:openCastMenu()
    elseif name == "fullscreen" then
        return self:toggleFullscreen()
    elseif name == "subtitles" then
        if s.device.kind ~= "chromecast" then
            return app.notify("Change audio and subtitles with the TV's remote: Plex on Fire TV doesn't take them from Reel")
        end
        if self.subMenu and not self.subMenu.cast then return self:closeSubtitleMenu() end
        return self:openSubtitleMenu()
    end
    if not cast.canControl() then return end
    if name == "playpause" then
        self:setPlaying(not self:isPlaying())
    elseif name == "skipback" or name == "skipfwd" then
        local dir = name == "skipfwd" and 1 or -1
        -- Fire TV: one press of Plex's own skip; Chromecast: a seek (presses add up)
        if s.device.kind == "dial" then cast.skip(dir * SEEK_STEP)
        else self:requestSeek(self:mediaTime() + dir * SEEK_STEP) end
    elseif name == "volume" then
        cast.setMuted(not s.muted)
    end
end

-- Under the controls while casting: the title's art and what the TV is doing.
-- Returns the status line and its colour.
function Player:castStatus()
    local s = cast.session
    if not s then return "Not casting", theme.textDim end
    if s.device.kind == "dial" then
        local r = s.remote
        if s.state == "starting" then return "Opening Plex on the TV…", theme.textDim end
        if r and r.state == "connecting" then return "Connecting to the TV's remote control…", theme.textDim end
        if r and r.state == "asking" then
            return "On the TV, choose Allow for \"Allow USB debugging?\" (tick Always allow) so Reel can control it",
                theme.accent
        end
        if r and r.state == "ready" then
            if s.state ~= "playing" then return "Plex is open on the TV. Choose something there and control it here.", theme.textDim end
            local title = r.title and r.title ~= "" and ("On the TV: " .. r.title) or nil
            return title, theme.textDim
        end
        if r and r.err == "refused" then
            return "To control it from here, turn on ADB debugging on the stick (Settings > My Fire TV > " ..
                "Developer options), then cast again. Until then, use the TV's remote.", theme.textDim
        end
        return "Remote control isn't available" .. (r and r.err and (" (" .. r.err .. ")") or "") ..
            ". Use the TV's remote.", theme.textDim
    end
    local text = { connecting = "Connecting…", launching = "Opening Plex on the TV…", loading = "Loading…",
                   starting = "Starting…", finished = "Finished" }
    return text[s.state], theme.textDim
end

function Player:drawCasting(w, h, u)
    local s = cast.session
    local art = self.item.art or self.item.grandparentArt
    local img = art and W.itemImage(self.server, art, w, h)
    if img then gfx.drawCover(img, 0, 0, w, h, 0.3) end
    mouse.region(0, 0, w, h, { click = function() self:runCastControl("playpause") end })

    local cy = h * 0.4
    gfx.color(theme.accent)
    W.castIcon(w / 2, cy - 50 * u, 90 * u, u)
    gfx.textCentered("Playing on " .. (s and s.device.name or "the TV"), w / 2, cy + 10 * u, 36 * u, theme.text)
    local msg, col = self:castStatus()
    local busy = s and (s.state == "starting" or s.state == "connecting" or s.state == "launching"
        or s.state == "loading" or (s.remote and (s.remote.state == "connecting" or s.remote.state == "asking")))
    local my = cy + 66 * u
    if busy then
        gfx.spinner(w / 2, my + 14 * u, 14 * u)
        my = my + 44 * u
    end
    if msg then
        local f = gfx.font(24 * u, msg)
        local _, lines = f:getWrap(msg, w * 0.5)
        for i, line in ipairs(lines) do
            gfx.textCentered(line, w / 2, my + (i - 1) * f:getHeight() * 1.15, 24 * u, col)
        end
    end
    self:drawControls(w, h, u, 1, false)
end

function Player:leave()
    self.closed = true
    love.mouse.setVisible(true)
    if self.video and self.state ~= "ended" then self:report("stopped") end
    -- end the server's conversion too, or it keeps running (and slows the next
    -- episode's start) until the server notices nobody's reading it
    if self.plan and self.plan.mode == "transcode" then api.stopTranscode(self.server, self.sessionId) end
    self:closeStreams()
end

-- Run one of the on-screen controls (shared by mouse clicks and keyboard focus).
function Player:runControl(name)
    if name == "exit" then return app.pop() end
    if self.casting then return self:runCastControl(name) end
    if not self.video then return end
    if name == "playpause" then
        self:setPlaying(self.state ~= "playing")
        if self.state == "playing" then self.overlay = OVERLAY_TIME end
    elseif name == "skipback" then
        self:requestSeek(self:mediaTime() - SEEK_STEP)
    elseif name == "skipfwd" then
        self:requestSeek(self:mediaTime() + SEEK_STEP)
    elseif name == "volume" then
        self:setVolume(self.volume, not self.muted)
    elseif name == "subtitles" then
        if self.subMenu then self:closeSubtitleMenu() else self:openSubtitleMenu() end
    elseif name == "cast" then
        -- carry on from here on a TV; this screen becomes the remote once one is chosen
        self:setPlaying(false)
        app.push(require("ui.castpicker").new(self.server, self.item, { offset = self:mediaTime(),
            onCast = function() self:castStarted() end }))
    elseif name == "fullscreen" then
        self:toggleFullscreen()
    end
end

function Player:action(a)
    local card = self.upNext and not self.upNext.dismissed and self.upNext
    if card and not self.subMenu then
        if a == "left" or a == "right" then card.button = a == "left" and 1 or 2; return end
        if a == "accept" then
            if card.button == 1 then return self:playNext() end
            return self:dismissUpNext()
        end
        if a == "back" then return self:dismissUpNext() end
    end
    local hidden = self.overlay <= 0
    if a == "back" and self.subMenu then return self:closeSubtitleMenu() end
    if a == "back" then
        if not hidden and self.overlay ~= math.huge and self.state == "playing" then self.overlay = 0; return end
        return app.pop()
    end
    if not self.video and not self.casting then return end
    self.overlay = math.max(self.overlay, OVERLAY_TIME)

    if self.subMenu then
        local n = #self.subMenu.entries
        if a == "up" then self.subMenu.sel = math.max(1, self.subMenu.sel - 1)
        elseif a == "down" then self.subMenu.sel = math.min(n, self.subMenu.sel + 1)
        elseif a == "accept" then self:chooseSubtitle(self.subMenu.sel)
        elseif a == "left" or a == "right" or a == "menu" then self:closeSubtitleMenu()
        elseif a == "playpause" then self:runControl("playpause") end
        return
    end

    -- dedicated buttons work regardless of focus
    if a == "playpause" then return self:runControl("playpause") end
    if a == "seekback" then return self:requestSeek(self:mediaTime() - SEEK_STEP) end
    if a == "seekfwd" then return self:requestSeek(self:mediaTime() + SEEK_STEP) end
    if hidden and a == "accept" then return end          -- first press just shows the controls

    if self.focus == "back" then
        if a == "down" then self.focus = "bar"
        elseif a == "accept" then self:runControl("exit") end
    elseif self.focus == "bar" then
        if a == "left" then self:requestSeek(self:mediaTime() - SEEK_STEP)
        elseif a == "right" then self:requestSeek(self:mediaTime() + SEEK_STEP)
        elseif a == "up" then self.focus = "back"
        elseif a == "down" then self.focus = "controls"
        elseif a == "accept" then self:runControl("playpause") end
    else -- controls row
        local name = CONTROLS[self.ctrl]
        if a == "left" then self.ctrl = math.max(1, self.ctrl - 1)
        elseif a == "right" then self.ctrl = math.min(#CONTROLS, self.ctrl + 1)
        elseif a == "up" then
            if name == "volume" then self:stepVolume(1) else self.focus = "bar" end
        elseif a == "down" then
            if name == "volume" then self:stepVolume(-1) end
        elseif a == "accept" then self:runControl(name) end
    end
end

function Player:keypressed(key)
    if key == "=" or key == "+" or key == "kp+" then self:stepVolume(1); return true end
    if key == "-" or key == "kp-" then self:stepVolume(-1); return true end
    if key == "f" then self:toggleFullscreen(); return true end
    if key == "c" and (self.video or self.casting) then self:runControl("subtitles"); return true end
    if key == "n" and self.nextItem and not self.casting then self:playNext(); return true end
    return false
end

function Player:wheel(dx, dy)
    if dy ~= 0 then self:stepVolume(dy > 0 and 1 or -1, VOLUME_STEP / 2) end
end

-- Line icons for the control row, centred on (cx, cy), roughly s pixels across.
local function drawIcon(name, cx, cy, s, p)
    local lw = math.max(2, s * 0.09)
    love.graphics.setLineWidth(lw)
    love.graphics.setLineJoin("miter")
    if name == "play" then
        love.graphics.polygon("fill", cx - s * 0.3, cy - s * 0.4, cx - s * 0.3, cy + s * 0.4, cx + s * 0.42, cy)
    elseif name == "pause" then
        love.graphics.rectangle("fill", cx - s * 0.32, cy - s * 0.38, s * 0.22, s * 0.76)
        love.graphics.rectangle("fill", cx + s * 0.1, cy - s * 0.38, s * 0.22, s * 0.76)
    elseif name == "skipback" or name == "skipfwd" then
        local dir = name == "skipfwd" and 1 or -1
        local r = s * 0.42
        -- a circle open at the top, the skip length inside; the arrowhead continues the
        -- stroke across the gap: clockwise (pointing right) forward, anticlockwise back
        love.graphics.arc("line", "open", cx, cy, r, -math.pi / 3, math.pi * 4 / 3)
        local ex, ey = cx - dir * r * 0.5, cy - r * 0.866       -- the stroke's end the head sits on
        local tx, ty = dir * 0.866, -0.5                         -- direction of travel there
        local h, wd = s * 0.2, s * 0.13
        love.graphics.polygon("fill", ex + tx * h, ey + ty * h,
            ex - ty * wd, ey + tx * wd, ex + ty * wd, ey - tx * wd)
        local f = gfx.font(s * 0.36)
        love.graphics.setFont(f)
        local n = tostring(SEEK_STEP)
        love.graphics.print(n, math.floor(cx - f:getWidth(n) / 2), math.floor(cy - f:getHeight() / 2))
    elseif name == "volume" then
        local x0 = cx - s * 0.38
        love.graphics.polygon("fill", x0, cy - s * 0.14, x0 + s * 0.16, cy - s * 0.14, x0 + s * 0.38, cy - s * 0.36,
            x0 + s * 0.38, cy + s * 0.36, x0 + s * 0.16, cy + s * 0.14, x0, cy + s * 0.14)
        if p.muted or p.volume <= 0 then
            love.graphics.line(cx + s * 0.12, cy - s * 0.14, cx + s * 0.4, cy + s * 0.14)
            love.graphics.line(cx + s * 0.12, cy + s * 0.14, cx + s * 0.4, cy - s * 0.14)
        else
            love.graphics.arc("line", "open", cx + s * 0.02, cy, s * 0.2, -0.8, 0.8)
            if p.volume > 0.35 then love.graphics.arc("line", "open", cx + s * 0.02, cy, s * 0.36, -0.8, 0.8) end
            if p.volume > 0.7 then love.graphics.arc("line", "open", cx + s * 0.02, cy, s * 0.52, -0.8, 0.8) end
        end
    elseif name == "fullscreen" or name == "windowed" then
        local o, l = s * 0.38, s * 0.16           -- corner offset and arm length
        for _, c in ipairs({ { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }) do
            local x, y = cx + c[1] * o, cy + c[2] * o
            if name == "fullscreen" then          -- corners pointing out
                love.graphics.line(x, y - c[2] * l, x, y, x - c[1] * l, y)
            else                                  -- corners pointing in
                local ix, iy = cx + c[1] * (o - l), cy + c[2] * (o - l)
                love.graphics.line(ix, iy + c[2] * l, ix, iy, ix + c[1] * l, iy)
            end
        end
    elseif name == "subtitles" then
        -- speech box with two text lines
        local bw, bh = s * 0.84, s * 0.62
        gfx.roundRect("line", cx - bw / 2, cy - bh / 2, bw, bh, s * 0.1)
        love.graphics.line(cx - bw * 0.3, cy + bh * 0.05, cx + bw * 0.08, cy + bh * 0.05)
        love.graphics.line(cx + bw * 0.18, cy + bh * 0.05, cx + bw * 0.3, cy + bh * 0.05)
        love.graphics.line(cx - bw * 0.3, cy + bh * 0.28, cx - bw * 0.12, cy + bh * 0.28)
        love.graphics.line(cx - bw * 0.02, cy + bh * 0.28, cx + bw * 0.3, cy + bh * 0.28)
    elseif name == "cast" then
        W.castIcon(cx, cy, s * 0.8, gfx.unit())
    elseif name == "exit" then
        love.graphics.line(cx + s * 0.38, cy, cx - s * 0.36, cy)
        love.graphics.line(cx - s * 0.08, cy - s * 0.3, cx - s * 0.38, cy, cx - s * 0.08, cy + s * 0.3)
    end
end

-- Current cue, centred near the bottom (raised while the controls show), white
-- with a dark outline so it reads on any picture.
function Player:drawSubtitles(w, h, u, overlayAlpha)
    if not self.cues then return end
    local text
    text, self.cueHint = subs.at(self.cues, self:mediaTime(), self.cueHint)
    if not text then return end
    local size = math.max(18, 40 * u)
    local o = math.max(1, 2.2 * u)
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local f = gfx.font(size, line)
        local _, wrapped = f:getWrap(line, w * 0.8)
        for _, l in ipairs(wrapped) do lines[#lines + 1] = { text = l, font = f } end
    end
    local lh = gfx.font(size):getHeight() * 1.08
    local bottom = h - 60 * u - overlayAlpha * 170 * u
    local y = bottom - #lines * lh
    for _, l in ipairs(lines) do
        love.graphics.setFont(l.font)
        local x = math.floor((w - l.font:getWidth(l.text)) / 2)
        love.graphics.setColor(0, 0, 0, 0.85)
        for dx = -1, 1 do
            for dy = -1, 1 do
                if dx ~= 0 or dy ~= 0 then love.graphics.print(l.text, x + dx * o, math.floor(y) + dy * o) end
            end
        end
        love.graphics.setColor(1, 1, 1)
        love.graphics.print(l.text, x, math.floor(y))
        y = y + lh
    end
end

-- Track list above the subtitles button, right edge at `right`, bottom at `bottom`:
-- an AUDIO section, then SUBTITLES (small uppercase headings, as in the library menus).
function Player:drawSubtitleMenu(w, h, u, right, bottom, pointer)
    local m = self.subMenu
    local entries = m.entries
    local rowH, headH, mw = 54 * u, 46 * u, 480 * u
    -- content height, and each row's offset in it
    local tops, cy = {}, 12 * u
    for i, e in ipairs(entries) do
        if e.heading then cy = cy + headH end
        tops[i] = cy
        cy = cy + rowH
    end
    local contentH = cy + 10 * u
    local mh = math.min(contentH, bottom - 40 * u)
    local x, y = right - mw, bottom - mh
    -- keep the focused row in view when the list is taller than the screen
    local maxScroll = math.max(0, contentH - mh)
    if not pointer then
        local top = tops[m.sel] - (entries[m.sel].heading and headH or 0)
        if top < m.scroll then m.scroll = top
        elseif tops[m.sel] + rowH > m.scroll + mh then m.scroll = tops[m.sel] + rowH - mh end
    end
    m.scroll = math.max(0, math.min(maxScroll, m.scroll))
    -- clicking anywhere else closes the menu
    mouse.region(0, 0, w, h, { click = function() self:closeSubtitleMenu() end })
    gfx.color({ 0.08, 0.08, 0.1 })
    gfx.roundRect("fill", x, y, mw, mh, 12 * u)
    mouse.region(x, y, mw, mh, { click = function() end, wheel = function(_, dy)
        m.scroll = math.max(0, math.min(maxScroll, m.scroll - dy * rowH))
        return true
    end })
    love.graphics.setScissor(x, y, mw, mh)
    local mx, my = love.mouse.getPosition()
    for i, e in ipairs(entries) do
        local ry = y + tops[i] - m.scroll
        if e.heading then
            gfx.text(e.heading:upper(), x + 24 * u, ry - headH + 16 * u, 17 * u, theme.textDim)
            if i > 1 then
                gfx.color(theme.text, 0.08)
                love.graphics.rectangle("fill", x + 16 * u, ry - headH + 4 * u, mw - 32 * u, 1)
            end
        end
        local visible = ry >= y - 1 and ry + rowH <= y + mh + 1
        local hover = visible and pointer and mx >= x and mx < x + mw and my >= ry and my < ry + rowH
        if hover then m.sel = i end
        local focused = m.sel == i
        if focused then
            gfx.color(theme.text, 0.12)
            love.graphics.rectangle("fill", x, ry, mw, rowH)
        end
        local current
        if e.kind == "audio" then current = e.stream == self.audioTrack
        elseif e.kind == "quality" then current = e.stream == self.quality
        elseif e.kind == "sub" then current = e.stream == self.sub end
        if current then
            gfx.color(theme.accent)
            love.graphics.setLineWidth(3 * u)
            love.graphics.line(x + 22 * u, ry + rowH * 0.5, x + 30 * u, ry + rowH * 0.66, x + 44 * u, ry + rowH * 0.32)
        end
        local noteW = e.note and gfx.width(e.note, 17 * u) + 16 * u or 0
        local label = gfx.fit(e.label, 22 * u, mw - 80 * u - noteW)
        local color = (focused or current) and theme.text or theme.textDim
        if e.kind == "more" then color = theme.accent end
        gfx.text(label, x + 60 * u, ry + (rowH - gfx.font(22 * u):getHeight()) / 2, 22 * u, color)
        if e.note then
            gfx.text(e.note, x + mw - 20 * u - gfx.width(e.note, 17 * u), ry + (rowH - gfx.font(17 * u):getHeight()) / 2,
                17 * u, theme.textDim)
        end
        if visible then mouse.region(x, ry, mw, rowH, { click = function() self:chooseSubtitle(i) end }) end
    end
    love.graphics.setScissor()
end

local function clock(t)
    t = math.max(0, math.floor(t or 0))
    local h, m, s = math.floor(t / 3600), math.floor(t / 60) % 60, t % 60
    if h > 0 then return ("%d:%02d:%02d"):format(h, m, s) end
    return ("%d:%02d"):format(m, s)
end

function Player:drawLoading(w, h, u, title, label)
    -- show the artwork while the stream starts
    local art = self.item.art or self.item.grandparentArt
    local img = art and W.itemImage(self.server, art, w, h)
    if img then
        gfx.drawCover(img, 0, 0, w, h, 0.35)
        gfx.vgradient(0, h * 0.4, w, h * 0.6, { 0, 0, 0 }, 0, 0.9)
    end
    gfx.textCentered(title, w / 2, h / 2 - 90 * u, 48 * u)
    gfx.spinner(w / 2, h / 2 + 20 * u, 26 * u)
    gfx.textCentered(label, w / 2, h / 2 + 70 * u, 24 * u, theme.textDim)
end

function Player:draw()
    local w, h = love.graphics.getDimensions()
    local u = gfx.unit()
    love.graphics.clear(0, 0, 0)
    local title = api.displayTitle(self.item)

    if self.casting then return self:drawCasting(w, h, u) end
    if self.state == "preparing" then
        return self:drawLoading(w, h, u, title, "Getting the stream ready…")
    elseif self.state == "opening" then
        local label = self.plan and self.plan.mode == "transcode" and "Your server is converting this video…" or "Starting…"
        if self.plan and self.plan.burnSubtitle then label = "Your server is adding the subtitles…" end
        return self:drawLoading(w, h, u, title, label)
    elseif self.state == "error" then
        gfx.textCentered("Can't play " .. title, w / 2, h / 2 - 80 * u, 40 * u, theme.danger)
        gfx.wrapped(self.error or "", w * 0.2, h / 2 - 10 * u, w * 0.6, 24 * u, theme.textDim, 6)
        W.backButton(40 * u, 40 * u, 64 * u, false, function() app.pop() end)
        return
    end

    if self.video then
        local vw, vh = self.video:getDimensions()
        local s = math.min(w / vw, h / vh)
        love.graphics.setColor(1, 1, 1)
        self.video:draw((w - vw * s) / 2, (h - vh * s) / 2, 0, s, s)
    end

    -- mouse: moving shows the controls, clicking the picture plays/pauses,
    -- double-clicking toggles fullscreen (and undoes the first click's pause, like Netflix)
    mouse.region(0, 0, w, h, {
        hover = function() if self.overlay ~= math.huge then self.overlay = OVERLAY_TIME end end,
        click = function()
            if not self.video or self.state == "ended" then return end
            local now = love.timer.getTime()
            if self.lastClick and now - self.lastClick < DOUBLE_CLICK then
                self.lastClick = nil
                if (self.state == "playing") ~= self.playingBeforeClick then self:setPlaying(self.playingBeforeClick) end
                return self:toggleFullscreen()
            end
            self.lastClick = now
            self.playingBeforeClick = self.state == "playing"
            self:setPlaying(self.state ~= "playing")
            if self.state == "playing" then self.overlay = OVERLAY_TIME end
        end,
    })

    local starved = self.audio and self.audio:isStarved() and not self.pendingSeek
    if starved then gfx.spinner(w / 2, h / 2, 34 * u) end

    local alpha = math.min(1, self.overlay / 0.4)
    self:drawSubtitles(w, h, u, alpha)
    if self.state == "ended" then alpha = 0 end
    if alpha > 0 then self:drawControls(w, h, u, alpha, starved) end
    if self.upNext and not self.upNext.dismissed then self:drawUpNext(w, h, u, alpha) end
end

-- Bottom-right card: "Playing Next", the episode's still with the countdown
-- ring over it, its title, and Play Now / Cancel.
function Player:drawUpNext(w, h, u, overlayAlpha)
    local card, it = self.upNext, self.nextItem
    local pointer = input.lastDevice == "mouse"
    local auto = client.settings.autoPlay ~= false
    local pw = 400 * u
    local ph = pw * 9 / 16
    local pad = 80 * u
    local x = w - pad - pw
    local bottom = h - 60 * u - overlayAlpha * 150 * u      -- above the seek bar while it shows
    local bh = 54 * u
    local y = bottom - (40 * u + ph + 80 * u + bh)
    if self.state == "ended" then
        gfx.color({ 0, 0, 0 }, 0.6)
        love.graphics.rectangle("fill", 0, 0, w, h)
    end
    gfx.color({ 0, 0, 0 }, 0.75)
    gfx.roundRect("fill", x - 20 * u, y - 20 * u, pw + 40 * u, bottom - y + 40 * u, 14 * u)
    mouse.region(x - 20 * u, y - 20 * u, pw + 40 * u, bottom - y + 40 * u, { click = function() end })

    gfx.text("Playing Next", x, y, 22 * u, theme.textDim)
    local py = y + 40 * u
    local img = W.itemImage(self.server, it.thumb or it.art, pw, ph)
    gfx.color(theme.surfaceHi)
    gfx.roundRect("fill", x, py, pw, ph, 8 * u)
    if img then gfx.drawCover(img, x, py, pw, ph, 1, 0.5, 0.5) end
    gfx.color({ 0, 0, 0 }, 0.35)
    love.graphics.rectangle("fill", x, py, pw, ph)
    local cx, cy, r = x + pw / 2, py + ph / 2, 44 * u
    gfx.color({ 0, 0, 0 }, 0.55)
    love.graphics.circle("fill", cx, cy, r)
    if auto then
        -- ring fills as the countdown runs, seconds left in the middle
        local frac = 1 - math.max(0, card.left) / card.total
        gfx.color(theme.text, 0.25)
        love.graphics.setLineWidth(4 * u)
        love.graphics.circle("line", cx, cy, r)
        gfx.color(theme.accent)
        love.graphics.arc("line", "open", cx, cy, r, -math.pi / 2, -math.pi / 2 + frac * math.pi * 2, 48)
        local secs = tostring(math.max(1, math.ceil(card.left)))
        gfx.textCentered(secs, cx, cy - gfx.font(34 * u):getHeight() / 2, 34 * u, theme.text)
    else
        gfx.color(theme.text)
        W.playIcon(cx + 5 * u, cy, 26 * u)
    end
    mouse.region(x, py, pw, ph, { click = function() self:playNext() end })

    local ty = py + ph + 12 * u
    local label = ("S%s · E%s"):format(it.parentIndex or "?", it.index or "?")
    gfx.text(label, x, ty, 20 * u, theme.accent)
    gfx.text(gfx.fit(it.title or "", 24 * u, pw - gfx.width(label, 20 * u) - 16 * u),
        x + gfx.width(label, 20 * u) + 14 * u, ty - 3 * u, 24 * u, theme.text)

    local by = ty + 52 * u
    local dt = love.timer.getDelta()
    local buttons = { { "Play Now", function() self:playNext() end, "play" },
                      { auto and "Cancel" or "Not Now", function() self:dismissUpNext() end } }
    local bx = x
    for i, b in ipairs(buttons) do
        local focus = (card.button == i and not pointer) or W.pointerIn(bx, by, card["w" .. i] or 0, bh)
        card["a" .. i] = gfx.approach(card["a" .. i] or 0, focus and 1 or 0, dt, 16)
        local bw = W.button(b[1], bx, by, bh, card["a" .. i], { primary = i == 1, icon = b[3] })
        card["w" .. i] = bw
        mouse.region(bx, by, bw, bh, { hover = function() card.button = i end, click = b[2] })
        bx = bx + bw + 16 * u
    end
end

function Player:drawControls(w, h, u, alpha, starved)
    local title = api.displayTitle(self.item)
    local pad = 80 * u
    local mx, my = love.mouse.getPosition()
    local pointer = input.lastDevice == "mouse"
    local function hovered(x, y, bw, bh) return pointer and mx >= x and mx < x + bw and my >= y and my < y + bh end

    gfx.vgradient(0, 0, w, 200 * u, { 0, 0, 0 }, 0.8 * alpha, 0)
    gfx.vgradient(0, h - 320 * u, w, 320 * u, { 0, 0, 0 }, 0, 0.92 * alpha)

    -- top left: back button, then the title
    local bs = 64 * u
    local bx, by = pad * 0.5, 40 * u
    local backFocus = (self.focus == "back" and not pointer) or hovered(bx, by, bs, bs)
    if backFocus then
        gfx.color(theme.text, 0.18 * alpha)
        love.graphics.circle("fill", bx + bs / 2, by + bs / 2, bs / 2)
    end
    gfx.color(theme.text, alpha)
    drawIcon("exit", bx + bs / 2, by + bs / 2, bs * 0.6, self)
    mouse.region(bx, by, bs, bs, { click = function() self:runControl("exit") end })

    local tx = bx + bs + 20 * u
    gfx.text(title, tx, 44 * u, 36 * u, theme.text, alpha)
    local sub = api.subtitle(self.item)
    if self.item.type == "episode" then sub = sub:gsub("  .*$", "") .. "  ·  " .. (self.item.title or "") end
    gfx.text(sub, tx, 90 * u, 22 * u, theme.textDim, alpha)

    -- seek bar with the remaining time to its right
    local t, d = self:mediaTime(), self.duration
    local remain = d > 0 and "-" .. clock(d - t) or clock(t)
    local live = not self.casting or cast.canControl()     -- controls that reach the TV dim until they do
    local liveAlpha = live and alpha or alpha * 0.35
    local remainW = gfx.width("-0:00:00", 24 * u)
    local barY, barW = h - 150 * u, w - 2 * pad - remainW - 24 * u
    local frac = d > 0 and math.max(0, math.min(1, t / d)) or 0
    local barFocus = self.focus == "bar" and not pointer
    local barHover = hovered(pad - 12 * u, barY - 22 * u, barW + 24 * u, 50 * u) or (self.drag and self.drag.kind == "seek")
    mouse.region(pad - 12 * u, barY - 22 * u, barW + 24 * u, 50 * u, {
        hover = function() self.overlay = math.max(self.overlay, OVERLAY_TIME) end,
        click = function(cx)
            if d <= 0 then return end
            self.drag = { kind = "seek", x = pad, w = barW }
            self:requestSeek(math.max(0, math.min(1, (cx - pad) / barW)) * d)
        end,
    })
    local thick = (barHover or barFocus) and 9 * u or 6 * u
    gfx.color(theme.text, 0.25 * liveAlpha)
    gfx.roundRect("fill", pad, barY - thick / 2, barW, thick, thick / 2)
    gfx.color(theme.accent, liveAlpha)
    gfx.roundRect("fill", pad, barY - thick / 2, barW * frac, thick, thick / 2)
    love.graphics.circle("fill", pad + barW * frac, barY, ((self.pendingSeek or barHover or barFocus) and 14 or 10) * u)
    if barFocus then
        gfx.color(theme.text, 0.6 * alpha)
        love.graphics.setLineWidth(2 * u)
        love.graphics.circle("line", pad + barW * frac, barY, 18 * u)
    end
    if self.pendingSeek then
        local label = clock(self.pendingSeek)
        local lw = gfx.width(label, 26 * u)
        local lx = math.max(pad, math.min(pad + barW * frac - lw / 2, pad + barW - lw))
        gfx.color({ 0, 0, 0 }, 0.75 * alpha)
        gfx.roundRect("fill", lx - 10 * u, barY - 62 * u, lw + 20 * u, 38 * u, 6 * u)
        gfx.text(label, lx, barY - 58 * u, 26 * u, theme.text, alpha)
    end
    gfx.text(remain, w - pad - gfx.width(remain, 24 * u), barY - 14 * u, 24 * u, theme.text, alpha)

    -- control row: play/pause, back 30, forward 30, volume (+ slider) ... fullscreen
    local cs = 64 * u                      -- button size
    local rowY = h - 112 * u
    local x = pad - 10 * u
    local function indexOf(name)
        for i, n in ipairs(CONTROLS) do if n == name then return i end end
    end
    local cs_ = self.casting and cast.session
    local iconState = cs_ and { muted = cs_.muted, volume = cs_.volume or 1 } or self
    local always = { cast = true, subtitles = true, fullscreen = true }
    local function control(name, iconName, cx, color)
        local focused = (self.focus == "controls" and CONTROLS[self.ctrl] == name and not pointer)
                        or hovered(cx, rowY, cs, cs)
        self.anim[name] = gfx.approach(self.anim[name] or 0, focused and 1 or 0, love.timer.getDelta(), 18)
        local a = self.anim[name]
        if a > 0.01 then
            gfx.color(theme.text, 0.16 * a * alpha)
            love.graphics.circle("fill", cx + cs / 2, rowY + cs / 2, cs / 2)
        end
        gfx.color(color or theme.text, always[name] and alpha or liveAlpha)
        drawIcon(iconName, cx + cs / 2, rowY + cs / 2, cs * (0.55 + 0.08 * a), iconState)
        mouse.region(cx, rowY, cs, cs, { click = function()
            self.focus, self.ctrl = "controls", indexOf(name)
            self:runControl(name)
        end })
        return focused
    end
    control("playpause", self:isPlaying() and "pause" or "play", x); x = x + cs + 24 * u
    control("skipback", "skipback", x); x = x + cs + 24 * u
    control("skipfwd", "skipfwd", x); x = x + cs + 24 * u
    local volFocused = control("volume", "volume", x); x = x + cs + 12 * u

    -- volume slider beside the speaker (not for a TV that doesn't say its volume)
    local sw, sy = 150 * u, rowY + cs / 2
    local level = self.muted and 0 or self.volume
    if cs_ then level = cs_.muted and 0 or (cs_.volume or 0) end
    if not self.casting or cast.hasVolumeLevel() then
    local sliderHover = hovered(x - 6 * u, rowY, sw + 12 * u, cs) or (self.drag and self.drag.kind == "volume")
    local active = volFocused or sliderHover
    gfx.color(theme.text, 0.25 * alpha)
    gfx.roundRect("fill", x, sy - 3 * u, sw, 6 * u, 3 * u)
    gfx.color(theme.text, alpha)
    gfx.roundRect("fill", x, sy - 3 * u, sw * level, 6 * u, 3 * u)
    love.graphics.circle("fill", x + sw * level, sy, (active and 10 or 7) * u)
    if active then
        local pct = ("%d%%"):format(math.floor(level * 100 + 0.5))
        gfx.text(pct, x + sw + 16 * u, sy - 13 * u, 22 * u, theme.textDim, alpha)
    end
    local sliderX = x
    mouse.region(x - 6 * u, rowY, sw + 12 * u, cs, {
        click = function(cx)
            self.drag = { kind = "volume", x = sliderX, w = sw }
            self:setVolume(math.max(0, math.min(1, (cx - sliderX) / sw)))
        end,
    })
    end

    -- centre: status; right: fullscreen
    local status = self.state == "paused" and "Paused" or (starved and "Buffering…" or "")
    if cs_ then
        local ps = cs_.player.state
        status = cs_.state ~= "playing" and "" or ps == "PAUSED" and "Paused" or ps == "BUFFERING" and "Buffering…" or ""
    end
    gfx.textCentered(status, w / 2, rowY + cs / 2 - 14 * u, 24 * u, theme.text, alpha)
    local fsX = w - pad - cs + 10 * u
    control("fullscreen", love.window.getFullscreen() and "windowed" or "fullscreen", fsX)
    local ccX = fsX - cs - 24 * u
    control("subtitles", "subtitles", ccX)
    if self.sub then            -- on: accent bar under the icon
        gfx.color(theme.accent, alpha)
        gfx.roundRect("fill", ccX + cs * 0.3, rowY + cs - 6 * u, cs * 0.4, 4 * u, 2 * u)
    end
    local castX = ccX - cs - 24 * u
    control("cast", "cast", castX, self.casting and theme.accent or nil)
    if self.casting then        -- casting: accent bar under the icon, as for subtitles
        gfx.color(theme.accent, alpha)
        gfx.roundRect("fill", castX + cs * 0.3, rowY + cs - 6 * u, cs * 0.4, 4 * u, 2 * u)
    end
    if self.subMenu then
        local right = self.subMenu.cast and castX + cs or ccX + cs
        self:drawSubtitleMenu(w, h, u, right, rowY - 16 * u, pointer)
    end

    -- centre play glyph when paused
    if self.state == "paused" then
        gfx.color({ 0, 0, 0 }, 0.5 * alpha)
        love.graphics.circle("fill", w / 2, h / 2, 56 * u)
        gfx.color(theme.text, alpha)
        W.playIcon(w / 2 + 6 * u, h / 2, 42 * u)
    end

    if self.casting then
        local s = cast.session
        local kind = s and (s.device.kind == "chromecast" and (s.device.model or "Chromecast")
            or s.device.manufacturer == "Amazon" and "Fire TV" or s.device.model or "TV") or ""
        local tech = "Casting to " .. (s and s.device.name or "TV") .. "  ·  " .. kind
        gfx.text(tech, w - pad - gfx.width(tech, 18 * u), 60 * u, 18 * u, theme.textDim, alpha)
        return
    end
    if not self.audio and self.audioError then
        local note = gfx.fit("No sound: " .. self.audioError .. (self.audioRetryAt and "  (retrying)" or ""), 20 * u, w * 0.5)
        gfx.color({ 0, 0, 0 }, 0.6 * alpha)
        gfx.roundRect("fill", tx - 10 * u, 128 * u, gfx.width(note, 20 * u) + 20 * u, 34 * u, 6 * u)
        gfx.text(note, tx, 132 * u, 20 * u, theme.danger, alpha)
    end
    local tech = self.plan.mode == "direct" and "Direct play" or self.plan.describe
    tech = ("%s  ·  %s / %s"):format(tech, (self.plan.container or "?"):upper(),
        self.audio and (self.plan.audioCodec or "?"):upper() or "no audio")
    gfx.text(tech, w - pad - gfx.width(tech, 18 * u), 60 * u, 18 * u, theme.textDim, alpha)
end

return Player
