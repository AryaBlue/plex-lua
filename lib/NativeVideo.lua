local ffi = require("ffi")

ffi.cdef[[
typedef struct nv_video nv_video;
typedef struct nv_info { int32_t width, height; double fps, duration; } nv_info;
nv_video*   nv_open(const char* path_utf8);
void        nv_get_info(nv_video* v, nv_info* out);
int         nv_read_frame(nv_video* v, uint8_t* rgba_out, double* pts_out);
int         nv_seek(nv_video* v, double seconds);
void        nv_close(nv_video* v);
const char* nv_last_error(void);
const char* nv_backend(void);

typedef struct nv_audio nv_audio;
typedef struct nv_audio_info { int32_t sample_rate, channels, source_channels; double duration; } nv_audio_info;
nv_audio*   nv_audio_open(const char* path_utf8);
void        nv_audio_get_info(nv_audio* a, nv_audio_info* out);
int         nv_audio_read(nv_audio* a, int16_t* out, int max_frames, double* pts_out);
int         nv_audio_seek(nv_audio* a, double seconds);
void        nv_audio_close(nv_audio* a);
nv_audio*   nv_audio_open_shared(nv_video* v);
nv_video*   nv_open_av(const char* path_utf8);
int         nv_has_video_decoder(const char* codec);
void        nv_set_audio_track(int index);
int         nv_can_decode_opus_surround(void);
]]

local NativeVideo = {}
NativeVideo.__index = NativeVideo

local SEEK_THRESHOLD = 1.0
local CATCHUP_FRAMES = 8    -- frames a stream that can't seek may decode per update to catch up
local lib, libPath

local lf = love.filesystem
local newImage = love.graphics.newImage or love.graphics.newTexture
 
local function load_library()
    if lib then return lib end
    local os_name = love.system.getOS()
    local file = os_name == "Windows" and "nativevideo.dll"
              or os_name == "OS X"    and "libnativevideo.dylib"
              or "libnativevideo.so"

    --for packing
    local candidates = {}
    if not lf.isFused() then
        table.insert(candidates, lf.getSource() .. "/" .. file)
    end
    table.insert(candidates, lf.getSourceBaseDirectory() .. "/" .. file)
    table.insert(candidates, "nativevideo")

    local errors = {}
    for _, path in ipairs(candidates) do
        local ok, result = pcall(ffi.load, path)
        if ok then lib, libPath = result, path; return lib end
        table.insert(errors, result)
    end
    error("NativeVideo: could not load " .. file .. ":\n  " .. table.concat(errors, "\n  "), 3)
end


local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

local function is_absolute(path)
    return path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil
end

-- "http://...", "https://..." (but not "C:/...") go straight to the OS decoder.
local function is_url(path)
    return path:match("^%a[%w+.-]+://") ~= nil
end

local function resolve_path(path)
    if is_url(path) then return path end
    if is_absolute(path) and file_exists(path) then return path end

    if lf.getInfo(path, "file") then
        local dir = lf.getRealDirectory(path)
        if dir then
            local real = dir .. "/" .. path
            if file_exists(real) then return real end
        end

        local cache = "nativevideo_cache/" .. path:gsub("[/\\]", "_")
        if not lf.getInfo(cache, "file") then
            lf.createDirectory("nativevideo_cache")
            local data = assert(lf.read("data", path))
            assert(lf.write(cache, data))
            data:release()
        end
        return lf.getSaveDirectory() .. "/" .. cache
    end

    error("NativeVideo: file not found: " .. tostring(path), 3)
end

-- opts.audio = true: also carry the audio track, for NativeVideo.newAudio(video)
-- (one file handle / connection for picture and sound).
-- opts.seekable = false: a live stream (e.g. one a server is converting) that
-- can't seek; following a clock then only ever decodes forward.
function NativeVideo.new(path, opts)
    local L = load_library()
    local real_path = resolve_path(path)

    local handle = (opts and opts.audio) and L.nv_open_av(real_path) or L.nv_open(real_path)
    if handle == nil then
        error("NativeVideo: " .. ffi.string(L.nv_last_error()), 2)
    end
    handle = ffi.gc(handle, L.nv_close)   -- closed automatically

    local info = ffi.new("nv_info")
    L.nv_get_info(handle, info)

    local self = setmetatable({}, NativeVideo)
    self.handle   = handle
    self.path     = real_path
    self.width    = info.width
    self.height   = info.height
    self.fps      = info.fps > 0 and info.fps or 30
    self.duration = info.duration

    -- Two CPU-side frames: front is what's on screen back holds the next
    self.front = love.image.newImageData(self.width, self.height, "rgba8")
    self.back  = love.image.newImageData(self.width, self.height, "rgba8")
    self.image = love.graphics.newImage(self.front)
    self.pts   = ffi.new("double[1]")

    self.time     = 0       -- current playback position (seconds)
    self.backPts  = nil
    self.eof      = false
    self.playing  = false
    self.loop     = false
    self.speed    = 1
    self.frameIndex = 0     -- frames shown so far (for stats)
    self.seekable = not (opts and opts.seekable == false)

    self:_decodeIntoBack()
    self:_presentBack()
    return self
end

---Not gonna pretend to understand this thanks bestie <3
-- Decode the next frame into `back`. Returns true if a frame was read.
function NativeVideo:_decodeIntoBack()
    local ptr = ffi.cast("uint8_t*", self.back:getFFIPointer())
    local r = lib.nv_read_frame(self.handle, ptr, self.pts)
    if r == 1 then

        if not self.ptsOffset then self.ptsOffset = self.pts[0] end
        self.backPts = self.pts[0] - self.ptsOffset
        return true
    elseif r == 0 then
        self.backPts, self.eof = nil, true
        if self.duration <= 0 then self.duration = self.time end
        return false
    else
        error("NativeVideo: " .. ffi.string(lib.nv_last_error()), 3)
    end
end

-- Swap the waiting frame onto the screen and start decoding the next one.
function NativeVideo:_presentBack()
    self.front, self.back = self.back, self.front
    self.dirty = true
    self.frameIndex = self.frameIndex + 1
    self:_decodeIntoBack()
end

-- Show every frame whose time has come (at most `limit` of them, if given)
function NativeVideo:_advanceTo(t, limit)
    -- exact frame time, which would otherwise show the frame one tick late.
    t = t + 1e-6
    local n = 0
    while self.backPts and self.backPts <= t and not (limit and n >= limit) do
        self:_presentBack()
        n = n + 1
    end
    if self.dirty then
        self.image:replacePixels(self.front)
        self.dirty = false
    end
end

function NativeVideo:update(dt)
    if not self.playing then return end
    self.time = self.time + dt * self.speed
    self:_advanceTo(self.time)

    if self.eof and self.duration > 0 and self.time >= self.duration then
        if self.loop then
            self:seek(self.time % self.duration)
        else
            self.playing = false
        end
    end
end

function NativeVideo:seek(t)
    t = math.max(0, t)
    if self.duration > 0 then t = math.min(t, self.duration) end
    local target = t + 1e-6
    local offset = self.ptsOffset or 0

    -- starts at the target, Media Foundation may land on the keyframe before
    local margin = 0
    for _ = 1, 5 do
        if lib.nv_seek(self.handle, math.max(0, t + offset - margin)) ~= 1 then
            error("NativeVideo: " .. ffi.string(lib.nv_last_error()), 2)
        end
        self.eof = false
        local got = self:_decodeIntoBack()
        if not got or self.backPts <= target or t + offset - margin <= 0 then break end
        margin = margin + (self.backPts - t) + 1 / self.fps
    end
    self.time = t

    -- Show the last frame that starts at or before t.
    if self.backPts then
        self:_presentBack()
        while self.backPts and self.backPts <= target do
            self:_presentBack()
        end
    end
    self.image:replacePixels(self.front)
    self.dirty = false
end

--- Follow an external clock, video:setTime(music:tell()).
function NativeVideo:setTime(t)
    if not self.seekable then
        -- can't seek: behind, decode forward a few frames per update until caught
        -- up; ahead, hold the frame until the clock reaches it
        self.time = t
        self:_advanceTo(t, CATCHUP_FRAMES)
        return
    end
    if t < self.time or t - self.time > SEEK_THRESHOLD then
        self:seek(t)
    else
        self.time = t
        self:_advanceTo(t)
    end
end

function NativeVideo:play()  self.playing = true end
function NativeVideo:pause() self.playing = false end
function NativeVideo:stop()  self.playing = false; self:seek(0) end
function NativeVideo:isPlaying() return self.playing end

function NativeVideo:setLoop(loop) self.loop = not not loop end
function NativeVideo:isLooping() return self.loop end
function NativeVideo:setSpeed(s) self.speed = s end

function NativeVideo:tell() return self.time end
function NativeVideo:getDuration() return self.duration end
function NativeVideo:getDimensions() return self.width, self.height end
function NativeVideo:getWidth() return self.width end
function NativeVideo:getHeight() return self.height end
function NativeVideo:getFPS() return self.fps end
function NativeVideo:getImage() return self.image end

function NativeVideo:draw(...)
    love.graphics.draw(self.image, ...)
end

function NativeVideo:release()
    if self.handle then
        lib.nv_close(ffi.gc(self.handle, nil))
        self.handle = nil
    end
    if self.image then self.image:release(); self.image = nil end
    if self.front then self.front:release(); self.front = nil end
    if self.back then self.back:release(); self.back = nil end
end

-- The library's path, for loading it on another thread (lib/VideoStream.lua).
function NativeVideo.libraryPath()
    load_library()
    return libPath
end

-- A path or URL as the decoder wants it (files inside the game are copied out).
function NativeVideo.resolve(path)
    return resolve_path(path)
end

function NativeVideo.getBackend()
    return ffi.string(load_library().nv_backend())
end

--- true/false if the OS can decode `codec` ("h264", "hevc", "vp9", "av1", ...),
-- nil if this backend can't tell.
-- Audio track for files opened from now on: 1 = the first audio track in the
-- file, 2 = the second... Returns false if this build/backend can't choose.
function NativeVideo.setAudioTrack(n)
    local L = load_library()
    local ok = pcall(function() return L.nv_set_audio_track end)
    if not ok then return false end
    L.nv_set_audio_track(math.max(0, (n or 1) - 1))
    return true
end

function NativeVideo.hasVideoDecoder(codec)
    local L = load_library()
    local ok, r = pcall(function() return L.nv_has_video_decoder(codec) end)
    if not ok or r < 0 then return nil end
    return r == 1
end

-- Whether Opus with more than two channels plays (Windows' decoder doesn't take
-- it; the DLL uses libopus, opus.dll, when it can find it).
function NativeVideo.canDecodeOpusSurround()
    local L = load_library()
    local ok, r = pcall(function() return L.nv_can_decode_opus_surround() end)
    return ok and r == 1
end

--- Keep the picture locked to an audio clock (seconds of media time, e.g. audio:tell()).
-- Tiny backward wobbles are ignored instead of triggering a seek.
function NativeVideo:syncTo(mediaTime)
    local t = mediaTime - (self.ptsOffset or 0)
    if t < self.time and self.time - t < 0.1 then return end
    self:setTime(math.max(0, t))
end

---------------------------------------------------------------------------
-- Audio: decodes the first audio track to 16-bit PCM and plays it through a
-- love.audio QueueableSource. tell() is the playback clock in media time, so
--   video:syncTo(audio:tell())
-- keeps picture and sound together.
--
-- NativeVideo.newAudio(video) shares the video's reader: one file handle / one
-- network connection for both (a separate reader on a streamed file downloads
-- the whole file a second time). When shared, seek the video first, then the audio.

local Audio = {}
Audio.__index = Audio
NativeVideo.Audio = Audio

local CHUNK_FRAMES = 4096   -- ~85 ms at 48 kHz per queued buffer
local BUFFER_COUNT = 8      -- ~0.7 s queued ahead

function NativeVideo.newAudio(source, opts)
    opts = opts or {}
    local L = load_library()
    local ok = pcall(function() return L.nv_audio_open end)
    if not ok then error("NativeVideo: audio is not supported by the " .. NativeVideo.getBackend() .. " backend", 2) end

    local handle, sharedWith
    if getmetatable(source) == NativeVideo then
        handle = L.nv_audio_open_shared(source.handle)
        sharedWith = source
    else
        handle = L.nv_audio_open(resolve_path(source))
    end
    if handle == nil then error("NativeVideo: " .. ffi.string(L.nv_last_error()), 2) end
    handle = ffi.gc(handle, L.nv_audio_close)

    local info = ffi.new("nv_audio_info")
    L.nv_audio_get_info(handle, info)

    local self = setmetatable({}, Audio)
    self.handle = handle
    self.video = sharedWith       -- shared reader: keep the video alive with us
    self.sampleRate = info.sample_rate
    self.channels = info.channels
    self.sourceChannels = info.source_channels
    self.duration = info.duration
    self.chunkFrames = opts.chunkFrames or CHUNK_FRAMES
    self.bufferCount = opts.bufferCount or BUFFER_COUNT
    self.source = love.audio.newQueueableSource(self.sampleRate, 16, self.channels, self.bufferCount)
    self.sd = love.sound.newSoundData(self.chunkFrames, self.sampleRate, 16, self.channels)
    self.pts = ffi.new("double[1]")
    self.chunks = {}        -- queued buffers, oldest first: { pts, frames }
    self.clock = 0          -- media time of the sample being heard
    self.startPts = 0
    self.playing = false
    self.eof = false
    self:_fill()
    if self.chunks[1] then self.clock = self.chunks[1].pts; self.startPts = self.clock end
    return self
end

-- Decode into every free OpenAL buffer.
function Audio:_fill()
    local src = self.source
    while not self.eof and src:getFreeBufferCount() > 0 do
        local ptr = ffi.cast("int16_t*", self.sd:getFFIPointer())
        local n = lib.nv_audio_read(self.handle, ptr, self.chunkFrames, self.pts)
        if n < 0 then error("NativeVideo: " .. ffi.string(lib.nv_last_error()), 3) end
        if n == 0 then self.eof = true; break end
        if n == self.chunkFrames then
            src:queue(self.sd)
        else
            -- short final chunk: queue exactly n frames
            local last = love.sound.newSoundData(n, self.sampleRate, 16, self.channels)
            ffi.copy(last:getFFIPointer(), ptr, n * self.channels * 2)
            src:queue(last)
            last:release()
        end
        self.chunks[#self.chunks + 1] = { pts = self.pts[0], frames = n }
    end
end

-- Drop chunks OpenAL has finished, then read the position in the current one.
function Audio:_updateClock()
    local src = self.source
    local inQueue = self.bufferCount - src:getFreeBufferCount()   -- read before tell()
    while #self.chunks > inQueue do table.remove(self.chunks, 1) end
    local cur = self.chunks[1]
    if not cur then
        if self.eof and self.duration > 0 then self.clock = math.max(self.clock, self.duration) end
        return
    end
    local off = src:tell("samples")
    local t
    if off > cur.frames + 64 then
        -- LÖVE builds where tell() counts from the start of playback
        t = self.startPts + off / self.sampleRate
    else
        t = cur.pts + off / self.sampleRate
    end
    -- At a buffer boundary tell() can wrap before the free count updates; never step back.
    if t > self.clock then self.clock = t end
end

function Audio:update()
    if not self.playing then return end
    self:_updateClock()
    self:_fill()
    if not self.source:isPlaying() then
        if #self.chunks > 0 then
            self.source:play()          -- start, or recover from an underrun
        elseif self.eof then
            self.playing = false        -- finished
        end
    end
end

function Audio:play()
    self.playing = true
    self:_fill()
    if #self.chunks > 0 then self.source:play() end
end

function Audio:pause()
    self.playing = false
    self.source:pause()
end

function Audio:seek(t)
    t = math.max(0, t)
    local wasPlaying = self.playing
    self.source:stop()              -- unqueues every buffer
    if self.source:getFreeBufferCount() < self.bufferCount then
        -- a source that never started keeps its queue through stop() (seeking
        -- right after opening, e.g. resuming part way in): start a fresh one
        local volume = self.source:getVolume()
        self.source:release()
        self.source = love.audio.newQueueableSource(self.sampleRate, 16, self.channels, self.bufferCount)
        self.source:setVolume(volume)
    end
    self.chunks = {}
    if lib.nv_audio_seek(self.handle, t) ~= 1 then
        error("NativeVideo: " .. ffi.string(lib.nv_last_error()), 2)
    end
    self.eof = false
    self.clock, self.startPts = t, t
    self:_fill()
    if self.chunks[1] then self.startPts = self.chunks[1].pts end
    if wasPlaying and #self.chunks > 0 then self.source:play() end
end

function Audio:tell() return self.clock end
function Audio:isPlaying() return self.playing end
function Audio:isFinished() return self.eof and #self.chunks == 0 end
-- True while playback is wanted but OpenAL ran out of data (network stall).
function Audio:isStarved() return self.playing and not self.source:isPlaying() and not self.eof end
function Audio:getDuration() return self.duration end
function Audio:setVolume(v) self.source:setVolume(v) end
function Audio:getVolume() return self.source:getVolume() end
function Audio:getSource() return self.source end

function Audio:release()
    if self.source then self.source:stop(); self.source:release(); self.source = nil end
    if self.handle then
        lib.nv_audio_close(ffi.gc(self.handle, nil))
        self.handle = nil
    end
    if self.sd then self.sd:release(); self.sd = nil end
end

return NativeVideo
