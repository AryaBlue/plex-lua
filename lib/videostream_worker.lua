-- Decoding thread for lib/VideoStream.lua. Owns one NativeVideo reader (picture
-- and sound from one connection) and does every call that can block on the
-- network or the decoder: the open, seeks, and reading frames and sound.
--
-- Channels (created per stream by VideoStream):
--   cmd    main -> here   { cmd = "seek", t, gen } | { cmd = "close" }
--   ctl    here -> main   { kind = "opened", ... } | { kind = "error", gen, msg }
--   video  here -> main   { gen, pts, img } | { gen, eof = true }
--   audio  here -> main   { gen, pts, sd, frames } | { gen, eof = true }
--   free   main -> here   ImageData the main thread has finished with
-- Every frame and chunk carries the generation of the seek it follows, so the
-- main thread can drop what was decoded before a seek.
require("love.image")
require("love.sound")
require("love.timer")
local ffi = require("ffi")

local libPath, url, opts, cmd, ctl, videoCh, audioCh, free = ...

ffi.cdef[[
typedef struct nv_video nv_video;
typedef struct nv_info { int32_t width, height; double fps, duration; } nv_info;
int         nv_read_frame(nv_video* v, uint8_t* rgba_out, double* pts_out);
int         nv_seek(nv_video* v, double seconds);
void        nv_close(nv_video* v);
const char* nv_last_error(void);
void        nv_get_info(nv_video* v, nv_info* out);
typedef struct nv_audio nv_audio;
typedef struct nv_audio_info { int32_t sample_rate, channels, source_channels; double duration; } nv_audio_info;
void        nv_audio_get_info(nv_audio* a, nv_audio_info* out);
int         nv_audio_read(nv_audio* a, int16_t* out, int max_frames, double* pts_out);
int         nv_audio_seek(nv_audio* a, double seconds);
void        nv_audio_close(nv_audio* a);
nv_audio*   nv_audio_open_shared(nv_video* v);
nv_video*   nv_open_av(const char* path_utf8);
void        nv_set_audio_track(int index);
]]
local L = ffi.load(libPath)

local AUDIO_AHEAD = opts.audioAhead or 12   -- chunks waiting beyond OpenAL's own buffers (~1 s)
local CHUNK_FRAMES = opts.chunkFrames or 4096

local function lastError() return ffi.string(L.nv_last_error()) end

L.nv_set_audio_track(math.max(0, (opts.track or 1) - 1))
local v = L.nv_open_av(url)
if v == nil then
    ctl:push({ kind = "error", gen = 0, msg = lastError(), open = true })
    return
end

local info = ffi.new("nv_info")
L.nv_get_info(v, info)
local w, h = info.width, info.height
local fps = info.fps > 0 and info.fps or 30

local a, audioError, ainfo = nil, nil, nil
if opts.audio ~= false then
    local ok, handle = pcall(L.nv_audio_open_shared, v)
    if ok and handle ~= nil then
        a = handle
        local ai = ffi.new("nv_audio_info")
        L.nv_audio_get_info(a, ai)
        ainfo = { rate = ai.sample_rate, channels = ai.channels, duration = ai.duration }
    else
        audioError = ok and lastError() or tostring(handle)
    end
end

ctl:push({ kind = "opened", width = w, height = h, fps = fps, duration = info.duration,
           audio = ainfo, audioError = audioError })

-- frames in flight (one on screen, the rest decoded ahead); fewer for 4K (33 MB each)
local POOL = opts.pool or (w * h > 2300000 and 4 or 6)
local pool = {}                      -- ImageData this thread may write into
for _ = 1, POOL do pool[#pool + 1] = love.image.newImageData(w, h, "rgba8") end
local pts = ffi.new("double[1]")
local gen, veof, aeof = 0, false, a == nil
local failed = false
local closing = false

local function fail(msg)
    failed = true
    ctl:push({ kind = "error", gen = gen, msg = msg })
end

local function takeImage()
    local img = free:pop()
    if img then pool[#pool + 1] = img end
    return table.remove(pool)
end

-- Decode the next frame into img. true, false at the end, or nil after an error.
local function readInto(img)
    local r = L.nv_read_frame(v, ffi.cast("uint8_t*", img:getFFIPointer()), pts)
    if r == 1 then return true end
    if r == 0 then return false end
    fail(lastError())
end

-- Seek to t; the first frame pushed is the last one starting at or before t
-- when the decoder lands early, as Media Foundation often lands on a later
-- keyframe: then seek earlier and try again.
local function seek(t)
    veof, aeof = false, a == nil
    local margin, img = 0, takeImage()
    for _ = 1, 5 do
        if L.nv_seek(v, math.max(0, t - margin)) ~= 1 then return fail("seek failed: " .. lastError()) end
        if not img then break end
        local got = readInto(img)
        if got == nil then return end
        if not got then veof = true; break end
        if pts[0] <= t + 1e-6 or t - margin <= 0 then
            videoCh:push({ gen = gen, pts = pts[0], img = img })
            img = nil
            break
        end
        margin = margin + (pts[0] - t) + 1 / fps
    end
    if img then pool[#pool + 1] = img end
    if a and L.nv_audio_seek(a, t) ~= 1 then return fail("seek failed: " .. lastError()) end
end

local function handle(m)
    if m.cmd == "close" then closing = true
    elseif m.cmd == "seek" then
        gen = m.gen
        failed = false
        seek(m.t)
    end
end

if opts.startAt and opts.startAt > 0 then seek(opts.startAt) end

while not closing do
    local m = cmd:pop()
    while m and not closing do handle(m); m = cmd:pop() end
    if closing then break end

    local busy = false
    if not failed and not aeof and audioCh:getCount() < AUDIO_AHEAD then
        -- sound first: a gap in it is heard, a late frame barely seen
        local sd = love.sound.newSoundData(CHUNK_FRAMES, ainfo.rate, 16, ainfo.channels)
        local n = L.nv_audio_read(a, ffi.cast("int16_t*", sd:getFFIPointer()), CHUNK_FRAMES, pts)
        if n < 0 then
            fail(lastError())
        elseif n == 0 then
            aeof = true
            audioCh:push({ gen = gen, eof = true })
        else
            audioCh:push({ gen = gen, pts = pts[0], sd = sd, frames = n })
        end
        sd:release()
        busy = true
    end
    if not failed and not veof then
        local img = takeImage()
        if img then
            local got = readInto(img)
            if got then
                videoCh:push({ gen = gen, pts = pts[0], img = img })
            else
                pool[#pool + 1] = img
                if got == false then veof = true; videoCh:push({ gen = gen, eof = true }) end
            end
            busy = true
        end
    end
    if not busy then
        -- buffers full (or finished): sleep until the main thread wants something
        m = cmd:demand(0.01)
        if m then handle(m) end
        if not m then
            local img = free:pop()
            if img then pool[#pool + 1] = img end
        end
    end
end

if a then L.nv_audio_close(a) end
L.nv_close(v)
