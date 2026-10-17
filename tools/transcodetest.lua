-- lovec E:\PlexLove --transcodetest <ratingKey>
-- Reproduces the player's conversion path step by step and logs each result:
-- decision -> stream URL headers -> nv_open -> video/audio reads. Ends the
-- session with a "stopped" timeline report.

local ffi = require("ffi")
local winhttp = require("lib.winhttp")
local client = require("plex.client")
local servers = require("plex.servers")
local api = require("plex.api")
local auth = require("plex.auth")
local playback = require("plex.playback")
local NativeVideo = require("lib.NativeVideo")

local T = {}
local t0 = love.timer.getTime()
local function log(fmt, ...) print(("[tc %6.2fs] " .. fmt):format(love.timer.getTime() - t0, ...)) end
local function redact(s) return (tostring(s):gsub("X%-Plex%-Token=[^&]+", "X-Plex-Token=<redacted>")) end

local function probeHeaders(url)
    -- the same request Media Foundation makes first, but only read the headers + a little body
    local thread = love.thread.newThread([[
        require("love.filesystem")
        local url, ch = ...
        local winhttp = require("lib.winhttp")
        local res, err = winhttp.request({ url = url, timeout = 40, headers = { Range = "bytes=0-" } , maxBytes = 65536 })
        ch:push({ status = res and res.status, headers = res and res.headers, bytes = res and #res.body, err = err })
    ]])
    local ch = love.thread.newChannel()
    thread:start(url, ch)
    return ch
end

function T.start(args)
    local key
    for i, a in ipairs(args) do if a == "--transcodetest" then key = args[i + 1] end end
    if not key then log("usage: --transcodetest <ratingKey>"); return love.event.quit(1) end

    auth.verify(function(user, err)
        if not user then log("not signed in: %s", tostring(err)); return love.event.quit(1) end
        servers.fetch(function(list)
            local target
            for _, s in ipairs(list or {}) do if s.id == client.settings.serverId then target = s end end
            if not target then log("saved server not found"); return love.event.quit(1) end
            target:connect(function(server)
                if server.state ~= "online" or T.started then return end
                T.started = true
                log("server via %s", server:connectionLabel())
                api.metadata(server, key, function(item, merr)
                    if not item then log("metadata failed: %s", tostring(merr)); return love.event.quit(1) end
                    local m = item.Media[1]
                    log("item %s: %s %s/%s", item.title, m.container, m.videoCodec, m.audioCodec)
                    local sid = "reel-tctest-" .. os.time()
                    T.server, T.item, T.sid = server, item, sid
                    playback.plan(server, item, sid, { offset = 0 }, function(plan, perr)
                        if not plan then log("PLAN FAILED: %s", tostring(perr)); return T.finish(2) end
                        log("plan: %s", plan.describe or plan.mode)
                        log("url: %s", redact(plan.url))
                        T.plan = plan
                        T.headerCh = probeHeaders(plan.url)
                    end)
                end)
            end)
        end)
    end)
end

function T.finish(code)
    if T.server and T.item then api.timeline(T.server, T.item, "stopped", 0, 1, T.sid) end
    T.quitAt = love.timer.getTime() + 1.5
    T.code = code
end

function T.update()
    if T.quitAt and love.timer.getTime() > T.quitAt then return love.event.quit(T.code or 0) end
    if not T.headerCh then return end
    local r = T.headerCh:pop()
    if not r then return end
    T.headerCh = nil
    log("HTTP probe: status=%s bytes=%s err=%s", tostring(r.status), tostring(r.bytes), tostring(r.err))
    for line in tostring(r.headers or ""):gmatch("[^\r\n]+") do log("   %s", line) end

    -- now exactly what the player does
    local ok, v = pcall(NativeVideo.new, T.plan.url)
    if not ok then log("nv_open FAILED: %s", tostring(v)); return T.finish(2) end
    log("video opened %dx%d fps=%.3f duration=%.1f", v.width, v.height, v.fps, v:getDuration())
    local aok, a = pcall(NativeVideo.newAudio, T.plan.url)
    log(aok and ("audio opened %d Hz %d ch"):format(a.sampleRate, a.channels) or ("audio open FAILED: " .. tostring(a)))
    -- interleave like the player: audio buffers ahead, video follows; ~3 minutes of media
    local frames, lastErr, which = 0, nil, nil
    local start = love.timer.getTime()
    local audioFrames = 0
    local nbuf = ffi.new("int16_t[?]", 4096 * 2)
    local pts = ffi.new("double[1]")
    local L = ffi.load(love.filesystem.getSource() .. "/nativevideo.dll")
    while frames < 24 * 180 do
        local rok, rerr = pcall(v._decodeIntoBack, v)
        if not rok then lastErr, which = rerr, "video"; break end
        if v.eof then log("video EOF after %d frames", frames); break end
        frames = frames + 1
        -- keep audio ~0.7 s ahead of video, as the QueueableSource would
        while aok and audioFrames / a.sampleRate < (v.backPts or 0) + 0.7 do
            local n = L.nv_audio_read(a.handle, nbuf, 4096, pts)
            if n < 0 then lastErr, which = ffi.string(L.nv_last_error()), "audio"; break end
            if n == 0 then break end
            audioFrames = audioFrames + n
        end
        if lastErr then break end
        if frames % 480 == 0 then
            log("  video pts %.1f s, audio %.1f s, wall %.1f s", v.backPts or -1, audioFrames / (aok and a.sampleRate or 1),
                love.timer.getTime() - start)
        end
    end
    log("result: %d video frames (pts %.1f), audio %.1f s, %.1f s wall%s", frames, v.backPts or -1,
        audioFrames / (aok and a.sampleRate or 1), love.timer.getTime() - start,
        lastErr and ("  ERROR in " .. which .. ": " .. tostring(lastErr)) or "")
    if aok then a:release() end
    v:release()
    T.finish(lastErr and 2 or 0)
end

return T
