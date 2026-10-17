-- Full-screen player: NativeVideo for picture, NativeVideo.Audio for sound,
-- picture slaved to the audio clock. Overlay with title, seek bar and controls.
-- Subtitles: separate subtitle files are drawn here; tracks inside the video
-- file are burned in by the server (see plex/subtitles.lua).
-- Auto play: for episodes, a "Playing Next" card (as in Plex's AudioVideoUpNext)
-- appears when the credits start, or the countdown's length before the end
-- when the server has no credits marker, and starts the next episode when the
-- countdown runs out (Settings: autoPlay, autoPlayDelay).
--
-- Streams come from plex/playback.lua: the original file (direct play) when
-- Windows can decode it, otherwise the server's converted stream. Converted
-- streams can't seek inside the file, so seeking restarts them at an offset.

local NativeVideo = require("lib.NativeVideo")
local theme = require("theme")
local gfx = require("ui.gfx")
local W = require("ui.widgets")
local api = require("plex.api")
local client = require("plex.client")
local playback = require("plex.playback")
local input = require("lib.input")
local mouse = require("ui.mouse")
local subs = require("plex.subtitles")

local Player = {}
Player.__index = Player

local OVERLAY_TIME = 3.5
local SEEK_STEP = 10
local SEEK_SETTLE = 0.45        -- wait this long after the last seek press before seeking
local TIMELINE_INTERVAL = 10
local DOUBLE_CLICK = 0.35       -- seconds between clicks that count as a double click
local VOLUME_STEP = 0.1

-- The row under the seek bar, left to right (fullscreen sits at the far right).
local CONTROLS = { "playpause", "back10", "fwd10", "volume", "subtitles", "fullscreen" }

function Player.new(server, item, opts)
    opts = opts or {}
    local self = setmetatable({
        server = server, item = item,
        state = "preparing",      -- preparing | opening | playing | paused | ended | error
        overlay = OVERLAY_TIME,
        sessionId = client.settings.clientIdentifier .. "-" .. tostring(os.time()),
        timelineTimer = 0,
        duration = (tonumber(item.duration) or 0) / 1000,
        focus = "bar",            -- keyboard/controller focus: back | bar | controls
        ctrl = 1,                 -- focused entry of CONTROLS
        volume = tonumber(client.settings.volume) or 1,
        muted = client.settings.muted == true,
        anim = {},
    }, Player)
    self.subStreams, self.partId = subs.streams(item)
    self.creditsAt = api.creditsStart(item)
    local off = tonumber(item.viewOffset)
    self.startAt = opts.startAt or (off and off / 1000 or 0)
    if self.startAt < 5 or self.startAt > self.duration - 10 then self.startAt = 0 end
    return self
end

function Player:enter()
    if self.item.type == "episode" then
        api.nextEpisode(self.server, self.item, function(nextItem)
            if not self.closed then self.nextItem = nextItem end
        end)
    end
    -- start with the track chosen last time (saved on the server)
    for _, st in ipairs(self.subStreams) do
        if st.selected then self:setSubtitle(st, true) end
    end
    self:prepare(self.startAt)
end

-- Ask playback.plan for a stream starting at `offset`, then open it on the next frames.
function Player:prepare(offset, forceTranscode)
    self.state = "preparing"
    self.prepareOffset = offset
    self.prepareGen = (self.prepareGen or 0) + 1
    local gen = self.prepareGen
    local opts = { offset = offset, forceTranscode = forceTranscode, burnSubtitle = self.burn }
    local function got(plan, err)
        if self.closed or gen ~= self.prepareGen then return end   -- replaced by a newer prepare
        if not plan then
            self.state = "error"
            self.error = err
            return
        end
        self.plan = plan
        self.state = "opening"
        self.openDelay = 2          -- let the "Starting" frame draw before blocking
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
    ["0xc00d2ee2"] = "the server refused the stream (it may be busy or at its stream limit)",
}
local function describeError(err)
    local msg = tostring(err):gsub("^.-NativeVideo: ", "")
    local code = msg:match("0x%x+")
    local nice = code and NET_ERRORS[code:lower()]
    return nice and (nice .. " (" .. code .. ")") or msg
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
        self.error = "Playback stopped: " .. reason .. ". It kept failing after " .. RECOVERY_LIMIT ..
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
    self.volume = math.max(0, math.min(1, v))
    if muted ~= nil then self.muted = muted elseif v > 0 then self.muted = false end
    self:applyVolume()
    client.settings.volume, client.settings.muted = self.volume, self.muted
    self.volumeDirty = true      -- saved to disk once the user stops adjusting (see update)
    self.overlay = math.max(self.overlay, OVERLAY_TIME)
end

-- Show subtitle track `st` (nil = off). A separate file is fetched and drawn
-- here; a track inside the video needs the server to burn it in, which means
-- reopening the stream (converted) at the current point. initial: before the
-- first open, and not a new choice to save.
function Player:setSubtitle(st, initial)
    self.sub, self.cues, self.cueHint = st, nil, 1
    if not initial then subs.select(self.server, self.partId, st) end
    if st and st.sidecar then
        subs.load(self.server, st, function(cues, err)
            if self.sub ~= st or self.closed then return end
            if not cues then return app.notify("Couldn't load subtitles: " .. tostring(err), "error") end
            self.cues = cues
        end)
    end
    local burn = st and not st.sidecar and st.id or nil
    if burn == self.burn then return end
    self.burn = burn
    if initial or not (self.video or self.plan) then return end
    local t = self:mediaTime()
    self.resumePaused = self.state == "paused"
    if self.video then self:report("stopped") end
    self:closeStreams()
    self.pendingSeek = nil
    if burn then app.notify("Adding subtitles: the server is converting the video with them drawn in…") end
    self:prepare(t)
end

function Player:openSubtitleMenu()
    local sel = 1
    for i, st in ipairs(self.subStreams) do if st == self.sub then sel = i + 1 end end
    self.subMenu = { sel = sel }
    self.overlay = math.huge
end

function Player:closeSubtitleMenu()
    self.subMenu = nil
    self.overlay = self.state == "paused" and math.huge or OVERLAY_TIME
end

function Player:chooseSubtitle(i)
    local st = self.subStreams[i - 1]       -- entry 1 is "Off"
    self:closeSubtitleMenu()
    if st ~= self.sub then self:setSubtitle(st) end
end

function Player:toggleFullscreen()
    app.toggleFullscreen()
    self.overlay = math.max(self.overlay, OVERLAY_TIME)
end

function Player:closeStreams()
    if self.audio then self.audio:release(); self.audio = nil end
    if self.video then self.video:release(); self.video = nil end
end

function Player:open()
    local plan = self.plan
    -- one reader (one connection) for picture and sound; two would download the file twice
    local ok, v = pcall(NativeVideo.new, plan.url, { audio = true })
    if not ok then
        local msg = tostring(v):gsub("^.-NativeVideo: ", "")
        if plan.mode == "direct" and msg:find("no Windows decoder", 1, true) then
            return self:prepare(self.prepareOffset, true)
        end
        -- while reconnecting, a failed reopen counts as another attempt
        if self.recoveries and #self.recoveries > 0 then return self:streamFailed(v) end
        self.state = "error"
        self.error = describeError(v)
        return
    end
    self.video = v

    local aok, a = pcall(NativeVideo.newAudio, v)
    if aok then
        self.audio = a
        self.audioError = nil
        self:applyVolume()
    else
        self.audioError = describeError(a)
        -- A missing track or an undecodable format won't fix itself. Anything else
        -- (refused connection, busy server, stream limit) gets a reconnect shortly.
        local permanent = self.audioError:find("no audio track", 1, true) or self.audioError:find("decoder", 1, true)
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
    -- media time = offsetBase + (stream clock - origin); origin is where this stream's clock starts
    self.offsetBase = plan.offsetBase or 0
    if plan.mode == "direct" then
        self.origin = 0
        if self.prepareOffset and self.prepareOffset > 0 then
            local sok, serr = pcall(self.seekStream, self, self.prepareOffset)
            if not sok then return self:streamFailed(serr) end
        end
    else
        self.origin = self.audio and self.audio:tell() or 0
    end
    self:setPlaying(true)
end

function Player:mediaTime()
    if self.pendingSeek then return self.pendingSeek end
    if self.audio then return self.offsetBase + self.audio:tell() - self.origin end
    if self.video then return self.offsetBase + self.video:tell() end
    return self.prepareOffset or 0
end

-- Seek inside an open direct-play stream.
function Player:seekStream(t)
    -- shared reader: the video seek moves it, then the audio drops to exactly t
    if self.video then self.video:seek(math.max(0, t - (self.video.ptsOffset or 0))) end
    if self.audio then self.audio:seek(t) end
end

-- Request a seek; applied once the user stops pressing (see update).
function Player:requestSeek(t)
    if not self.video then return end
    t = math.max(0, math.min(t, self.duration - 2))
    self.pendingSeek = t
    self.seekTimer = SEEK_SETTLE
    self.overlay = OVERLAY_TIME
end

function Player:applySeek()
    local t = self.pendingSeek
    self.pendingSeek = nil
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
    if not self.video then return end
    if on then
        self.video:play()
        -- resuming refills audio buffers from the network (e.g. after a long pause the
        -- server or a proxy may have dropped the idle connection)
        if self.audio then
            local ok, err = pcall(self.audio.play, self.audio)
            if not ok then return self:streamFailed(err) end
        end
        self.state = "playing"
        -- pausing pinned the controls; let them hide again (e.g. the double-click's
        -- first click paused and the second resumed)
        if self.overlay == math.huge and not self.subMenu then self.overlay = OVERLAY_TIME end
    else
        self.video:pause()
        if self.audio then self.audio:pause() end
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

function Player:update(dt)
    if self.upNext and not self.upNext.dismissed and client.settings.autoPlay ~= false
        and (self.state == "playing" or self.state == "ended") and not self.pendingSeek then
        self.upNext.left = self.upNext.left - dt
        if self.upNext.left <= 0 then return self:playNext() end
    end
    if self.state == "ended" then love.mouse.setVisible(true); return end   -- waiting on "Playing Next"
    if self.state == "opening" then
        self.openDelay = self.openDelay - 1
        if self.openDelay <= 0 then
            self:open()
            if self.resumePaused and self.video then self:setPlaying(false); self.resumePaused = nil end
        end
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
        local ok, err = pcall(function()
            if self.audio then
                self.audio:update()
                self.video:syncTo(self.audio:tell())
            else
                self.video:update(dt)
            end
        end)
        if not ok then return self:streamFailed(err) end
        self.lastGoodTime = self:mediaTime()
        self:checkUpNext()
        if self.audio then
            if self.audio:isFinished() and (self.video.eof or self:mediaTime() >= self.duration - 1) then self:finish() end
        elseif not self.video:isPlaying() then
            self:finish()
        end
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

    -- dragging the seek bar or volume slider with the left button held
    if self.drag and love.mouse.isDown(1) then
        local mx = love.mouse.getX()
        local d = self.drag
        local frac = math.max(0, math.min(1, (mx - d.x) / d.w))
        if d.kind == "seek" then self:requestSeek(frac * self.duration) else self:setVolume(frac) end
    elseif self.drag then
        self.drag = nil
    end
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

function Player:leave()
    self.closed = true
    love.mouse.setVisible(true)
    if self.video and self.state ~= "ended" then self:report("stopped") end
    self:closeStreams()
end

-- Run one of the on-screen controls (shared by mouse clicks and keyboard focus).
function Player:runControl(name)
    if name == "exit" then return app.pop() end
    if not self.video then return end
    if name == "playpause" then
        self:setPlaying(self.state ~= "playing")
        if self.state == "playing" then self.overlay = OVERLAY_TIME end
    elseif name == "back10" then
        self:requestSeek(self:mediaTime() - SEEK_STEP)
    elseif name == "fwd10" then
        self:requestSeek(self:mediaTime() + SEEK_STEP)
    elseif name == "volume" then
        self:setVolume(self.volume, not self.muted)
    elseif name == "subtitles" then
        if self.subMenu then self:closeSubtitleMenu() else self:openSubtitleMenu() end
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
    if not self.video then return end
    self.overlay = math.max(self.overlay, OVERLAY_TIME)

    if self.subMenu then
        local n = #self.subStreams + 1
        if a == "up" then self.subMenu.sel = math.max(1, self.subMenu.sel - 1)
        elseif a == "down" then self.subMenu.sel = math.min(n, self.subMenu.sel + 1)
        elseif a == "accept" then self:chooseSubtitle(self.subMenu.sel)
        elseif a == "left" or a == "right" or a == "menu" then self:closeSubtitleMenu()
        elseif a == "playpause" then self:runControl("playpause") end
        return
    end

    -- dedicated buttons work regardless of focus
    if a == "playpause" then return self:runControl("playpause") end
    if a == "seekback" then return self:requestSeek(self:mediaTime() - SEEK_STEP * 3) end
    if a == "seekfwd" then return self:requestSeek(self:mediaTime() + SEEK_STEP * 3) end
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
            if name == "volume" then self:setVolume(self.volume + VOLUME_STEP) else self.focus = "bar" end
        elseif a == "down" then
            if name == "volume" then self:setVolume(self.volume - VOLUME_STEP) end
        elseif a == "accept" then self:runControl(name) end
    end
end

function Player:keypressed(key)
    if key == "=" or key == "+" or key == "kp+" then self:setVolume(self.volume + VOLUME_STEP); return true end
    if key == "-" or key == "kp-" then self:setVolume(self.volume - VOLUME_STEP); return true end
    if key == "f" then self:toggleFullscreen(); return true end
    if key == "c" and self.video then self:runControl("subtitles"); return true end
    if key == "n" and self.nextItem then self:playNext(); return true end
    return false
end

function Player:wheel(dx, dy)
    if dy ~= 0 then self:setVolume(self.volume + (dy > 0 and 1 or -1) * VOLUME_STEP / 2) end
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
    elseif name == "back10" or name == "fwd10" then
        local dir = name == "fwd10" and 1 or -1
        local r = s * 0.42
        -- open circle with an arrowhead at the top, "10" inside
        if dir > 0 then love.graphics.arc("line", "open", cx, cy, r, -math.pi * 0.35, math.pi * 1.45)
        else love.graphics.arc("line", "open", cx, cy, r, -math.pi * 0.45, math.pi * 1.35) end
        local ax = cx + dir * r * 0.15
        love.graphics.polygon("fill", ax, cy - r - s * 0.13, ax, cy - r + s * 0.13, ax + dir * s * 0.2, cy - r)
        local f = gfx.font(s * 0.36)
        love.graphics.setFont(f)
        love.graphics.print("10", math.floor(cx - f:getWidth("10") / 2), math.floor(cy - f:getHeight() / 2))
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

-- Track list above the subtitles button, right edge at `right`, bottom at `bottom`.
function Player:drawSubtitleMenu(w, h, u, right, bottom, pointer)
    local entries = { { label = "Off" } }
    for _, st in ipairs(self.subStreams) do
        local note = not st.sidecar and "server draws it in" or nil
        if st.forced and not st.label:lower():find("forced", 1, true) then note = "forced" .. (note and ", " .. note or "") end
        entries[#entries + 1] = { label = st.label, note = note, stream = st }
    end
    local rowH, mw = 54 * u, 460 * u
    local mh = #entries * rowH + 70 * u + (#self.subStreams == 0 and rowH or 0)
    local x, y = right - mw, bottom - mh
    -- clicking anywhere else closes the menu
    mouse.region(0, 0, w, h, { click = function() self:closeSubtitleMenu() end })
    gfx.color({ 0.08, 0.08, 0.1 }, 0.96)
    gfx.roundRect("fill", x, y, mw, mh, 12 * u)
    mouse.region(x, y, mw, mh, { click = function() end })
    gfx.text("Subtitles", x + 24 * u, y + 18 * u, 24 * u, theme.textDim)
    local mx, my = love.mouse.getPosition()
    local ry = y + 60 * u
    for i, e in ipairs(entries) do
        local hover = pointer and mx >= x and mx < x + mw and my >= ry and my < ry + rowH
        if hover then self.subMenu.sel = i end
        local focused = self.subMenu.sel == i
        if focused then
            gfx.color(theme.text, 0.12)
            love.graphics.rectangle("fill", x, ry, mw, rowH)
        end
        local current = e.stream == self.sub
        if current then
            gfx.color(theme.accent)
            love.graphics.setLineWidth(3 * u)
            love.graphics.line(x + 22 * u, ry + rowH * 0.5, x + 30 * u, ry + rowH * 0.66, x + 44 * u, ry + rowH * 0.32)
        end
        local noteW = e.note and gfx.width(e.note, 17 * u) + 16 * u or 0
        local label = gfx.fit(e.label, 22 * u, mw - 80 * u - noteW)
        gfx.text(label, x + 60 * u, ry + (rowH - gfx.font(22 * u):getHeight()) / 2, 22 * u,
            (focused or current) and theme.text or theme.textDim)
        if e.note then
            gfx.text(e.note, x + mw - 20 * u - gfx.width(e.note, 17 * u), ry + (rowH - gfx.font(17 * u):getHeight()) / 2,
                17 * u, theme.textDim)
        end
        mouse.region(x, ry, mw, rowH, { click = function() self:chooseSubtitle(i) end })
        ry = ry + rowH
    end
    if #self.subStreams == 0 then
        gfx.text("This video has no subtitles.", x + 60 * u, ry + 14 * u, 20 * u, theme.textDim)
    end
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
    local remain = "-" .. clock(d - t)
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
    gfx.color(theme.text, 0.25 * alpha)
    gfx.roundRect("fill", pad, barY - thick / 2, barW, thick, thick / 2)
    gfx.color(theme.accent, alpha)
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

    -- control row: play/pause, back 10, forward 10, volume (+ slider) ... fullscreen
    local cs = 64 * u                      -- button size
    local rowY = h - 112 * u
    local x = pad - 10 * u
    local function indexOf(name)
        for i, n in ipairs(CONTROLS) do if n == name then return i end end
    end
    local function control(name, iconName, cx)
        local focused = (self.focus == "controls" and CONTROLS[self.ctrl] == name and not pointer)
                        or hovered(cx, rowY, cs, cs)
        self.anim[name] = gfx.approach(self.anim[name] or 0, focused and 1 or 0, love.timer.getDelta(), 18)
        local a = self.anim[name]
        if a > 0.01 then
            gfx.color(theme.text, 0.16 * a * alpha)
            love.graphics.circle("fill", cx + cs / 2, rowY + cs / 2, cs / 2)
        end
        gfx.color(theme.text, alpha)
        drawIcon(iconName, cx + cs / 2, rowY + cs / 2, cs * (0.55 + 0.08 * a), self)
        mouse.region(cx, rowY, cs, cs, { click = function()
            self.focus, self.ctrl = "controls", indexOf(name)
            self:runControl(name)
        end })
        return focused
    end
    control("playpause", self.state == "playing" and "pause" or "play", x); x = x + cs + 24 * u
    control("back10", "back10", x); x = x + cs + 24 * u
    control("fwd10", "fwd10", x); x = x + cs + 24 * u
    local volFocused = control("volume", "volume", x); x = x + cs + 12 * u

    -- volume slider beside the speaker
    local sw, sy = 150 * u, rowY + cs / 2
    local level = self.muted and 0 or self.volume
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

    -- centre: status; right: fullscreen
    local status = self.state == "paused" and "Paused" or (starved and "Buffering…" or "")
    gfx.textCentered(status, w / 2, rowY + cs / 2 - 14 * u, 24 * u, theme.text, alpha)
    local fsX = w - pad - cs + 10 * u
    control("fullscreen", love.window.getFullscreen() and "windowed" or "fullscreen", fsX)
    local ccX = fsX - cs - 24 * u
    control("subtitles", "subtitles", ccX)
    if self.sub then            -- on: accent bar under the icon
        gfx.color(theme.accent, alpha)
        gfx.roundRect("fill", ccX + cs * 0.3, rowY + cs - 6 * u, cs * 0.4, 4 * u, 2 * u)
    end
    if self.subMenu then self:drawSubtitleMenu(w, h, u, ccX + cs, rowY - 16 * u, pointer) end

    -- centre play glyph when paused
    if self.state == "paused" then
        gfx.color({ 0, 0, 0 }, 0.5 * alpha)
        love.graphics.circle("fill", w / 2, h / 2, 56 * u)
        gfx.color(theme.text, alpha)
        W.playIcon(w / 2 + 6 * u, h / 2, 42 * u)
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
