-- lovec E:\PlexLove --audiotest <ratingKey>
-- Sound only, one connection, no timeline reports: decodes a direct-play
-- file's audio with nv_audio_read, then plays a few seconds through the
-- player's QueueableSource path (muted) and logs whether it ever starts.

local ffi = require("ffi")
local client = require("plex.client")
local servers = require("plex.servers")
local api = require("plex.api")
local auth = require("plex.auth")
local NativeVideo = require("lib.NativeVideo")

local T = {}
local t0 = love.timer.getTime()
local function log(fmt, ...) print(("[audio %6.2fs] " .. fmt):format(love.timer.getTime() - t0, ...)) end

function T.start(args)
    local key
    for i, a in ipairs(args) do if a == "--audiotest" then key = args[i + 1] end end
    auth.verify(function(user)
        if not user then log("not signed in"); return love.event.quit(1) end
        servers.fetch(function(list)
            for _, s in ipairs(list or {}) do
                if s.id == client.settings.serverId then
                    s:connect(function(server)
                        if server.state ~= "online" or T.requested then return end
                        T.requested = true
                        api.metadata(server, key, function(item)
                            local dp = item and api.directPlay(server, item)
                            if not dp then log("no direct-play part"); return love.event.quit(1) end
                            local m = dp.media
                            log("%s: %s %s/%s %sch", item.title, m.container, m.videoCodec, m.audioCodec, tostring(m.audioChannels))
                            T.url = dp.url
                        end)
                    end)
                end
            end
        end)
    end)
end

local function decodeTest(url)
    local L = ffi.load(love.filesystem.getSource() .. "/nativevideo.dll")
    local t = love.timer.getTime()
    local a = L.nv_audio_open(url)
    if a == nil then log("nv_audio_open FAILED: %s", ffi.string(L.nv_last_error())); return end
    local info = ffi.new("nv_audio_info")
    L.nv_audio_get_info(a, info)
    log("opened in %.2fs: %d Hz, %d ch out (source %d ch)", love.timer.getTime() - t, info.sample_rate, info.channels, info.source_channels)
    local buf = ffi.new("int16_t[?]", 4096 * 2)
    local pts = ffi.new("double[1]")
    local total, worst, peak, expect, gaps = 0, 0, 0, nil, 0
    t = love.timer.getTime()
    while total < info.sample_rate * 10 do
        local r0 = love.timer.getTime()
        local n = L.nv_audio_read(a, buf, 4096, pts)
        worst = math.max(worst, love.timer.getTime() - r0)
        if n <= 0 then log("nv_audio_read returned %d after %.2fs of audio: %s", n, total / info.sample_rate,
                           n < 0 and ffi.string(L.nv_last_error()) or "end"); break end
        if expect and math.abs(pts[0] - expect) > 0.002 then gaps = gaps + 1
            if gaps <= 3 then log("  timestamp jump: expected %.4f got %.4f", expect, pts[0]) end end
        expect = pts[0] + n / info.sample_rate
        for i = 0, n * info.channels - 1, 5 do peak = math.max(peak, math.abs(buf[i])) end
        total = total + n
    end
    log("decoded %.2fs of audio in %.2fs (worst read %.0f ms), %d timestamp jumps, peak %d",
        total / info.sample_rate, love.timer.getTime() - t, worst * 1000, gaps, peak)
    L.nv_audio_close(a)
end

function T.update()
    if T.quitAt and love.timer.getTime() > T.quitAt then return love.event.quit(0) end
    if T.url and not T.done then
        T.done = true
        decodeTest(T.url)
        -- the player path: Audio object -> QueueableSource, muted, real time
        local ok, a = pcall(NativeVideo.newAudio, T.url)
        if not ok then log("newAudio FAILED: %s", tostring(a)); T.quitAt = love.timer.getTime(); return end
        a:setVolume(0)
        a:play()
        T.audio, T.playStart = a, love.timer.getTime()
        log("playing through QueueableSource (%d Hz %d ch)", a.sampleRate, a.channels)
    end
    local a = T.audio
    if a then
        local ok, err = pcall(a.update, a)
        if not ok then log("update ERROR: %s", tostring(err)) end
        local el = love.timer.getTime() - T.playStart
        if math.floor(el * 2) ~= T.lastHalf then
            T.lastHalf = math.floor(el * 2)
            log("  wall %.1f  clock %.3f  source playing=%s  free=%d/%d  chunks=%d  starved=%s  eof=%s",
                el, a:tell(), tostring(a.source:isPlaying()), a.source:getFreeBufferCount(), a.bufferCount,
                #a.chunks, tostring(a:isStarved()), tostring(a.eof))
        end
        if el > 6 or not ok then a:release(); T.audio = nil; T.quitAt = love.timer.getTime() + 0.5 end
    end
end

return T
