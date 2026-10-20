-- A video with its sound, decoded on its own thread (lib/videostream_worker.lua)
-- so a slow network or decoder never holds up the rest of the app. The main
-- thread only queues sound into OpenAL, picks the frame for the sound's clock
-- and uploads it.
--
--   local s = VideoStream.open(url, { track = 1, seekable = true, startAt = 0, relative = false })
--   s:poll()            -- each frame while s.state == "opening"; then "ready" or "failed" (s.error)
--   s:play() / s:pause() / s:seek(t)
--   s:update(dt)        -- each frame while playing; raises "NativeVideo: ..." if a read failed
--   s:tell(), s:draw(...), s:release()
--
-- Times are the stream's own (media time when playing the file itself). With
-- relative = true, tell() counts from the first sound (or picture) instead: a
-- converted stream's clock starts wherever the server's conversion started.
-- s.audio is nil when the file has no sound the decoder can play (s.audioError).

local NativeVideo = require("lib.NativeVideo")

local VideoStream = {}
VideoStream.__index = VideoStream

local Audio = {}
Audio.__index = Audio

-- threads of released streams, kept referenced until they finish their last read
local closing = {}

local CHUNK_FRAMES = 4096   -- ~85 ms at 48 kHz per buffer
local BUFFER_COUNT = 8      -- OpenAL buffers (~0.7 s); the worker keeps ~1 s more waiting

function VideoStream.open(url, opts)
    opts = opts or {}
    local self = setmetatable({
        state = "opening",
        seekable = opts.seekable ~= false,
        relative = opts.relative,
        gen = 0,
        clock = opts.startAt or 0,     -- stream time being shown / heard
        playing = false,
        seeking = true,                -- show the first picture as soon as it arrives
        eof = false,                   -- no more pictures
        frames = {},                   -- decoded, not yet shown: { pts, img }
        frameIndex = 0,
    }, VideoStream)
    self.cmd = love.thread.newChannel()
    self.ctl = love.thread.newChannel()
    self.videoCh = love.thread.newChannel()
    self.audioCh = love.thread.newChannel()
    self.free = love.thread.newChannel()
    self.thread = love.thread.newThread("lib/videostream_worker.lua")
    self.thread:start(NativeVideo.libraryPath(), NativeVideo.resolve(url),
        { track = opts.track, startAt = opts.startAt, chunkFrames = CHUNK_FRAMES },
        self.cmd, self.ctl, self.videoCh, self.audioCh, self.free)
    return self
end

-- Handle messages from the worker. Raises on a read error once ready.
function VideoStream:poll()
    local err = self.thread and self.thread:getError()
    if err then print("[video] stream thread failed: " .. err) end
    if err then self:_fail(err) end
    while true do
        local m = self.ctl:pop()
        if not m then break end
        if m.kind == "opened" then
            self:_opened(m)
        elseif m.kind == "error" and m.gen == self.gen then
            self:_fail(m.msg)
        end
    end
    if self.state == "ready" and self.error then error("NativeVideo: " .. self.error, 0) end
end

function VideoStream:_fail(msg)
    if self.state == "opening" then self.state = "failed" end
    self.error = self.error or tostring(msg)
end

function VideoStream:_opened(m)
    self.state = "ready"
    self.width, self.height, self.fps, self.duration = m.width, m.height, m.fps, m.duration
    self.image = love.graphics.newImage(love.image.newImageData(m.width, m.height, "rgba8"))
    if m.audio then
        self.audio = setmetatable({
            stream = self,
            sampleRate = m.audio.rate, channels = m.audio.channels, duration = m.audio.duration,
            source = love.audio.newQueueableSource(m.audio.rate, 16, m.audio.channels, BUFFER_COUNT),
            chunks = {}, eof = false, volume = 1,
        }, Audio)
    end
    self.audioError = m.audioError
end

function VideoStream:play()
    self.playing = true
    if self.audio then self.audio:_play() end
end

function VideoStream:pause()
    self.playing = false
    if self.audio then self.audio.source:pause() end
end

function VideoStream:isPlaying() return self.playing end

-- Jump to stream time t (files played as they are only). Pictures and sound
-- decoded before the jump are dropped as they arrive.
function VideoStream:seek(t)
    t = math.max(0, t)
    self.gen = self.gen + 1
    self.cmd:push({ cmd = "seek", t = t, gen = self.gen })
    self:_dropFrames()
    self.eof = false
    self.clock = t
    self.seeking = true                -- until the first picture of the new position
    if self.audio then self.audio:_reset(t) end
end

function VideoStream:_dropFrames()
    for _, f in ipairs(self.frames) do self.free:push(f.img) end
    self.frames = {}
end

-- Take what the worker decoded: frames into the queue (in order), sound into OpenAL.
function VideoStream:_pump()
    while true do
        local m = self.videoCh:pop()
        if not m then break end
        if m.gen ~= self.gen then
            if m.img then self.free:push(m.img) end
        elseif m.eof then
            self.videoEnd = true
        else
            self.frames[#self.frames + 1] = { pts = m.pts, img = m.img }
            if not self.firstPts then self.firstPts = m.pts end
        end
    end
    if self.audio then self.audio:_pump() end
end

function VideoStream:update(dt)
    self:poll()
    self:_pump()
    local audio = self.audio
    if audio then
        if self.playing then audio:_update() end
        if audio.started then self.clock = audio.clock end
    elseif self.playing and not self.seeking then
        if not self.started and self.frames[1] then self.started = true; self.clock = self.frames[1].pts end
        if self.started then self.clock = self.clock + dt end
    end
    -- show the newest frame whose time has come (all decoding is done; the rest go back)
    local t = self.clock + 1e-6
    local show
    while self.frames[1] and (self.frames[1].pts <= t or self.seeking) do
        if show then self.free:push(show.img) end
        show = table.remove(self.frames, 1)
        self.seeking = false
        self.frameIndex = self.frameIndex + 1
    end
    if show then
        self.image:replacePixels(show.img)
        self.free:push(show.img)
    end
    self.eof = self.videoEnd and not self.frames[1] or false
    if not audio and self.eof and self.playing then self.playing = false end
end

-- Clock: the sound's when there is any, otherwise the pictures'.
function VideoStream:tell()
    local base = 0
    if self.relative then
        base = (self.audio and self.audio.firstPts) or self.firstPts or self.clock
    end
    return self.clock - base
end

function VideoStream:getDuration() return self.duration or 0 end
function VideoStream:getDimensions() return self.width or 0, self.height or 0 end
function VideoStream:getImage() return self.image end
function VideoStream:draw(...)
    if self.image then love.graphics.draw(self.image, ...) end
end

-- Never waits for the worker: it may be stuck in a network read; it closes the
-- reader and ends once that returns.
function VideoStream:release()
    if self.cmd then self.cmd:push({ cmd = "close" }) end
    for i = #closing, 1, -1 do
        if not closing[i]:isRunning() then table.remove(closing, i) end
    end
    if self.thread and self.thread:isRunning() then closing[#closing + 1] = self.thread end
    self.thread = nil
    self:_dropFrames()
    if self.audio then self.audio:_release(); self.audio = nil end
    if self.image then self.image:release(); self.image = nil end
    self.cmd = nil
    self.state = "closed"
end

---------------------------------------------------------------------------
-- Sound: chunks from the worker into a QueueableSource; clock = media time of
-- the sample being heard.

function Audio:_pump()
    local s = self.stream
    local src = self.source
    while src:getFreeBufferCount() > 0 do
        local m = s.audioCh:peek()
        if not m then break end
        s.audioCh:pop()
        if m.gen == s.gen then
            if m.eof then
                self.eof = true
            else
                if m.frames == CHUNK_FRAMES then
                    src:queue(m.sd)
                else
                    -- short final chunk: exactly its frames
                    local last = love.sound.newSoundData(m.frames, self.sampleRate, 16, self.channels)
                    require("ffi").copy(last:getFFIPointer(), m.sd:getFFIPointer(), m.frames * self.channels * 2)
                    src:queue(last)
                    last:release()
                end
                self.chunks[#self.chunks + 1] = { pts = m.pts, frames = m.frames }
                if not self.started then
                    self.started = true
                    self.clock, self.startPts = m.pts, m.pts
                    if not self.firstPts then self.firstPts = m.pts end
                end
            end
        end
        -- the latest chunk stays readable as audio.sd (tools/shots.lua checks the tone)
        if m.sd then
            if self.sd then self.sd:release() end
            self.sd = m.sd
        end
    end
    -- wanted to be playing and now there's sound: start (or recover from an underrun)
    if s.playing and not src:isPlaying() and #self.chunks > 0 then src:play() end
end

-- Drop the chunks OpenAL has finished, then read the position in the current one.
function Audio:_update()
    local src = self.source
    local inQueue = BUFFER_COUNT - src:getFreeBufferCount()   -- read before tell()
    while #self.chunks > inQueue do table.remove(self.chunks, 1) end
    local cur = self.chunks[1]
    if not cur then
        if self.eof and self.duration > 0 then self.clock = math.max(self.clock, self.duration) end
        return
    end
    local off = src:tell("samples")
    local t
    if off > cur.frames + 64 then
        t = self.startPts + off / self.sampleRate     -- LÖVE builds where tell() counts from the start
    else
        t = cur.pts + off / self.sampleRate
    end
    -- at a buffer boundary tell() can wrap before the free count updates; never step back
    if t > self.clock then self.clock = t end
end

function Audio:_play()
    if #self.chunks > 0 then self.source:play() end
end

function Audio:_reset(t)
    -- a stopped source keeps its queue if it never started: start a fresh one
    local volume = self.source:getVolume()
    self.source:stop()
    self.source:release()
    self.source = love.audio.newQueueableSource(self.sampleRate, 16, self.channels, BUFFER_COUNT)
    self.source:setVolume(volume)
    self.chunks = {}
    self.eof = false
    self.started = false
    self.clock, self.startPts = t, t
end

function Audio:_release()
    if self.source then self.source:stop(); self.source:release(); self.source = nil end
    if self.sd then self.sd:release(); self.sd = nil end
end

function Audio:tell() return self.clock end
function Audio:isFinished() return self.eof and #self.chunks == 0 end
-- True while playback is wanted but the sound ran dry (network stall, or a seek in progress).
function Audio:isStarved()
    return self.stream.playing and not self.source:isPlaying() and not self.eof
end
function Audio:setVolume(v) self.source:setVolume(v) end
function Audio:getVolume() return self.source:getVolume() end

return VideoStream
