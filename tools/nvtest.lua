-- Headless check: can NativeVideo's nv_open play a Plex direct-play URL?
--   lovec E:\PlexLove --nvtest [ratingKey]
-- Uses the saved sign-in, connects to the last server, picks an item, opens its
-- direct-play URL with nv_open and decodes frames. Prints results and quits.

local ffi = require("ffi")
local client = require("plex.client")
local servers = require("plex.servers")
local api = require("plex.api")
local auth = require("plex.auth")

local T = {}

io.stdout:setvbuf("no")
local t0Test = love.timer.getTime()
local function log(fmt, ...) print(("[nvtest %6.2fs] " .. fmt):format(love.timer.getTime() - t0Test, ...)) end

local function finish(code)
    log("done")
    love.event.quit(code or 0)
end

local function redact(url)
    return (url:gsub("X%-Plex%-Token=[^&]+", "X-Plex-Token=<redacted>"))
end

local nv
local function load_nv()
    if nv then return end
    ffi.cdef[[
    typedef struct nv_video nv_video;
    typedef struct nv_info { int32_t width, height; double fps, duration; } nv_info;
    nv_video* nv_open(const char* path_utf8);
    void nv_get_info(nv_video* v, nv_info* out);
    int nv_read_frame(nv_video* v, uint8_t* rgba_out, double* pts_out);
    int nv_seek(nv_video* v, double seconds);
    void nv_close(nv_video* v);
    const char* nv_last_error(void);
    const char* nv_backend(void);
    ]]
    nv = ffi.load(love.filesystem.getSource() .. "/nativevideo.dll")
end

local function run_nv(url)
    load_nv()
    log("backend: %s", ffi.string(nv.nv_backend()))
    log("nv_open(%s)", redact(url))
    local t0 = love.timer.getTime()
    local v = nv.nv_open(url)
    local openTime = love.timer.getTime() - t0
    if v == nil then
        log("FAIL nv_open after %.2fs: %s", openTime, ffi.string(nv.nv_last_error()))
        return false
    end
    local info = ffi.new("nv_info")
    nv.nv_get_info(v, info)
    log("opened in %.2fs: %dx%d %.3f fps, duration %.1fs", openTime, info.width, info.height, info.fps, info.duration)

    local buf = ffi.new("uint8_t[?]", info.width * info.height * 4)
    local pts = ffi.new("double[1]")
    local frames, first, last, worst = 0, nil, nil, 0
    t0 = love.timer.getTime()
    for _ = 1, 120 do
        local f0 = love.timer.getTime()
        local r = nv.nv_read_frame(v, buf, pts)
        worst = math.max(worst, love.timer.getTime() - f0)
        if r ~= 1 then
            log("nv_read_frame returned %d (%s)", r, r < 0 and ffi.string(nv.nv_last_error()) or "end of stream")
            break
        end
        frames = frames + 1
        first = first or pts[0]
        last = pts[0]
    end
    local elapsed = love.timer.getTime() - t0
    log("decoded %d frames in %.2fs (%.1f fps decode, worst frame %.0f ms), pts %.3f -> %.3f",
        frames, elapsed, frames / math.max(elapsed, 1e-6), worst * 1000, first or -1, last or -1)

    -- sample a pixel row to prove it isn't blank
    if frames > 0 then
        local sum = 0
        local row = math.floor(info.height / 2) * info.width * 4
        for x = 0, info.width - 1, 16 do sum = sum + buf[row + x * 4] + buf[row + x * 4 + 1] + buf[row + x * 4 + 2] end
        log("mid-row brightness sample: %d", sum)
    end

    local seekTo = math.min(60, info.duration > 0 and info.duration / 2 or 60)
    t0 = love.timer.getTime()
    local ok = nv.nv_seek(v, seekTo)
    local r = ok == 1 and nv.nv_read_frame(v, buf, pts) or -1
    log("seek(%.0f) -> %s, first frame pts %.3f, took %.2fs", seekTo, r == 1 and "ok" or ("FAIL " .. ffi.string(nv.nv_last_error())),
        pts[0], love.timer.getTime() - t0)
    nv.nv_close(v)

    -- Audio track through the new nv_audio API.
    if not T.audioDeclared then T.audioDeclared = true; ffi.cdef[[
    typedef struct nv_audio nv_audio;
    typedef struct nv_audio_info { int32_t sample_rate, channels, source_channels; double duration; } nv_audio_info;
    nv_audio* nv_audio_open(const char* path_utf8);
    void nv_audio_get_info(nv_audio* a, nv_audio_info* out);
    int nv_audio_read(nv_audio* a, int16_t* out, int max_frames, double* pts_out);
    int nv_audio_seek(nv_audio* a, double seconds);
    void nv_audio_close(nv_audio* a);
    ]] end
    t0 = love.timer.getTime()
    local a = nv.nv_audio_open(url)
    if a == nil then
        log("AUDIO FAIL nv_audio_open after %.2fs: %s", love.timer.getTime() - t0, ffi.string(nv.nv_last_error()))
    else
        local ai = ffi.new("nv_audio_info")
        nv.nv_audio_get_info(a, ai)
        log("audio opened in %.2fs: %d Hz, %d ch (source %d ch)", love.timer.getTime() - t0, ai.sample_rate, ai.channels, ai.source_channels)
        local abuf = ffi.new("int16_t[?]", 48000 * 2)
        local total, peak, firstPts = 0, 0, nil
        t0 = love.timer.getTime()
        while total < ai.sample_rate * 5 do
            local n = nv.nv_audio_read(a, abuf, 4096, pts)
            if n <= 0 then log("nv_audio_read returned %d", n); break end
            firstPts = firstPts or pts[0]
            for i = 0, n * ai.channels - 1, 7 do peak = math.max(peak, math.abs(abuf[i])) end
            total = total + n
        end
        log("decoded %.2fs of audio in %.2fs, first pts %.3f, peak level %d/32767",
            total / ai.sample_rate, love.timer.getTime() - t0, firstPts or -1, peak)
        nv.nv_audio_seek(a, seekTo)
        local n = nv.nv_audio_read(a, abuf, 1024, pts)
        log("audio seek(%.0f) -> %d frames at pts %.4f", seekTo, n, pts[0])
        nv.nv_audio_close(a)
    end
    return frames > 0
end

local function pick_item(server, wanted, cb)
    if wanted then return api.metadata(server, wanted, cb) end
    api.hubs(server, function(hubs, err)
        if not hubs then return cb(nil, err) end
        local candidates = {}
        for _, hub in ipairs(hubs) do
            for _, m in ipairs(hub.Metadata or {}) do
                if m.type == "movie" or m.type == "episode" then candidates[#candidates + 1] = m end
            end
        end
        if #candidates == 0 then return cb(nil, "no movie/episode in /hubs") end
        api.metadata(server, candidates[1].ratingKey, cb)
    end)
end

function T.start(args)
    local wanted
    for i, a in ipairs(args) do if a == "--nvtest" then wanted = args[i + 1] end end
    if wanted and not wanted:match("^%d+$") then wanted = nil end

    auth.verify(function(user, err)
        if not user then log("not signed in (%s); run the app normally once to sign in", tostring(err)); return finish(1) end
        log("signed in as %s", user.title or user.username or "?")
        servers.fetch(function(list, ferr)
            if not list or #list == 0 then log("no servers: %s", tostring(ferr)); return finish(1) end
            local chosen
            local pendingCount = #list
            for _, s in ipairs(list) do
                s:connect(function(server)
                    if server.state == "testing" then return end
                    if server.state ~= "online" or server._reported then
                        if server.state ~= "online" then pendingCount = pendingCount - 1 end
                        if pendingCount == 0 and not chosen then log("no server online"); finish(1) end
                        return
                    end
                    server._reported = true
                    pendingCount = pendingCount - 1
                    log("server %s online via %s [%s]", server.name, server:connectionLabel(), redact(server:baseUrl()))
                    for _, c in ipairs(server.connections) do
                        log("   %-7s relay=%-5s private=%-5s %s %s", c.state, tostring(c.relay), tostring(c.private),
                            c.uri, c.latency and ("%dms"):format(c.latency * 1000) or (c.error or ""))
                    end
                    local preferred = client.settings.serverId
                    if chosen or (preferred and server.id ~= preferred and pendingCount > 0) then return end
                    chosen = server
                    pick_item(server, wanted, function(item, ierr)
                        if not item then log("no item: %s", tostring(ierr)); return finish(1) end
                        local dp = api.directPlay(server, item)
                        if not dp then log("item %s has no media part", item.title or "?"); return finish(1) end
                        log("item: %s (%s) ratingKey=%s container=%s video=%s audio=%s %dx%s",
                            api.displayTitle(item), item.type, item.ratingKey, tostring(dp.container), tostring(dp.videoCodec),
                            tostring(dp.audioCodec), tonumber(dp.media.width) or 0, tostring(dp.media.height))
                        local ok = run_nv(dp.url)
                        log(ok and "RESULT: direct play URL works with nv_open" or "RESULT: nv_open could NOT play the URL")
                        if ok then return finish(0) end

                        -- Fall back to the server converting the video (what the player does).
                        local playback = require("plex.playback")
                        local sid = "reel-nvtest-" .. os.time()
                        playback.plan(server, item, sid, { offset = 0 }, function(plan, perr)
                            if not plan then log("transcode plan failed: %s", tostring(perr)); return finish(2) end
                            log("plan: %s", plan.describe)
                            local tok = run_nv(plan.url)
                            log(tok and "RESULT: converted stream works with nv_open" or "RESULT: converted stream failed too")
                            api.timeline(server, item, "stopped", 0, plan.duration, sid)
                            finish(tok and 0 or 2)
                        end)
                    end)
                end)
            end
        end)
    end)
end

return T
