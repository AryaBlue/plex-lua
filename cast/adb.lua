-- ADB over the network (port 5555), just enough to run shell commands on a Fire TV
-- stick: the remote control for Plex there (cast/adb_worker.lua). Android's protocol:
-- every message is a 24-byte header (command, two arguments, payload length, payload
-- byte sum, command xor 0xffffffff) and the payload. CNXN connects; the device answers
-- with AUTH tokens, which are signed with Reel's key (castsock.dll keeps it). The first
-- time, the device doesn't know the key yet, so Reel sends it and the TV asks whether to
-- allow this computer. Each shell command is then a stream: OPEN, the output as WRTEs
-- (each acknowledged with OKAY), CLSE when the command ends.
--
-- Used on a worker thread: everything here blocks for at most the timeouts given.

local socket = require("socket")
local ffi = require("ffi")

local adb = {}

local A = { CNXN = 0x4e584e43, AUTH = 0x48545541, OPEN = 0x4e45504f, OKAY = 0x59414b4f,
            CLSE = 0x45534c43, WRTE = 0x45545257 }
adb.A = A
local VERSION, MAXDATA = 0x01000000, 4096
local TOKEN, SIGNATURE, RSAPUBLICKEY = 1, 2, 3

pcall(ffi.cdef, [[
const char *cs_open_error(void);
int cs_adb_pubkey(const char *keyPath, char *out, int cap);
int cs_adb_sign(const char *keyPath, const unsigned char *token, int len, unsigned char *out, int cap);
]])

local function le32(n)
    n = n % 4294967296
    return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216))
end

local function rd32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end

function adb.packet(cmd, a0, a1, data)
    data = data or ""
    local sum = 0
    for i = 1, #data do sum = sum + data:byte(i) end
    return le32(cmd) .. le32(a0) .. le32(a1) .. le32(#data) .. le32(sum) .. le32(4294967295 - cmd) .. data
end

local Conn = {}
Conn.__index = Conn

function Conn:send(cmd, a0, a1, data)
    local ok, err = self.sock:send(adb.packet(cmd, a0, a1, data))
    if not ok then error("send: " .. tostring(err), 0) end
end

-- The next message, or nil, err ("timeout" when nothing came within `timeout` seconds).
function Conn:read(timeout)
    self.sock:settimeout(timeout)
    local head, err, part = self.sock:receive(24 - #self.partial)
    if not head then
        self.partial = self.partial .. (part or "")
        return nil, err
    end
    head = self.partial .. head
    self.partial = ""
    local len = rd32(head, 13)
    local data = ""
    if len > 0 then
        self.sock:settimeout(5)
        data, err = self.sock:receive(len)
        if not data then return nil, "closed mid-message: " .. tostring(err) end
    end
    return { cmd = rd32(head, 1), a0 = rd32(head, 5), a1 = rd32(head, 9), data = data }
end

-- Connect and sign in. onAsking() is called when the TV is showing "Allow USB
-- debugging?" for Reel's key (it waits up to askTimeout seconds for an answer).
-- Returns a connection, or nil, err.
function adb.connect(lib, keyPath, host, port, onAsking, askTimeout)
    local sock = socket.tcp()
    sock:settimeout(4)
    local ok, err = sock:connect(host, port)
    if not ok then
        sock:close()
        return nil, err == "connection refused" and "refused" or tostring(err)
    end
    sock:setoption("tcp-nodelay", true)
    local c = setmetatable({ sock = sock, partial = "", nextId = 1, streams = {}, lib = lib }, Conn)
    local okRun, res, why = pcall(function()
        c:send(A.CNXN, VERSION, MAXDATA, "host::\0")
        local sentSig, sentKey, wait = false, false, 8
        while true do
            local m, e = c:read(wait)
            if not m then
                if sentKey then return nil, "not allowed on the TV" end
                return nil, e == "timeout" and "no answer" or tostring(e)
            end
            if m.cmd == A.CNXN then
                c.banner = m.data
                return c
            elseif m.cmd == A.AUTH and m.a0 == TOKEN then
                if not sentSig then
                    sentSig = true
                    local sig = ffi.new("unsigned char[512]")
                    local n = lib.cs_adb_sign(keyPath, m.data, #m.data, sig, 512)
                    if n < 0 then return nil, ffi.string(lib.cs_open_error()) end
                    c:send(A.AUTH, SIGNATURE, 0, ffi.string(sig, n))
                elseif not sentKey then
                    -- the device doesn't know this key: hand it over, the TV asks
                    sentKey = true
                    local buf = ffi.new("char[2048]")
                    local n = lib.cs_adb_pubkey(keyPath, buf, 2048)
                    if n < 0 then return nil, ffi.string(lib.cs_open_error()) end
                    c:send(A.AUTH, RSAPUBLICKEY, 0, ffi.string(buf, n))
                    if onAsking then onAsking() end
                    wait = askTimeout or 60
                else
                    return nil, "not allowed on the TV"
                end
            end
        end
    end)
    if okRun and res then return res end
    sock:close()
    return nil, okRun and why or tostring(res)
end

-- Start a shell command; onDone(output) when it ends (nil, err if the connection broke).
function Conn:shell(cmd, onDone)
    local id = self.nextId
    self.nextId = id + 1
    self.streams[id] = { out = {}, onDone = onDone }
    self:send(A.OPEN, id, 0, "shell:" .. cmd .. "\0")
    return id
end

-- Handle what has arrived, waiting up to `timeout` seconds for the first message.
-- false, err if the connection is gone.
function Conn:pump(timeout)
    local first = true
    while true do
        local m, err = self:read(first and timeout or 0)
        first = false
        if not m then
            if err == "timeout" then return true end
            for id, st in pairs(self.streams) do
                self.streams[id] = nil
                if st.onDone then st.onDone(nil, err) end
            end
            return false, err
        end
        local st = self.streams[m.a1]
        if st then
            if m.cmd == A.OKAY then
                st.remote = m.a0
            elseif m.cmd == A.WRTE then
                st.out[#st.out + 1] = m.data
                self:send(A.OKAY, m.a1, m.a0, "")
            elseif m.cmd == A.CLSE then
                self.streams[m.a1] = nil
                if st.remote then self:send(A.CLSE, m.a1, m.a0, "") end
                if st.onDone then st.onDone(table.concat(st.out)) end
            end
        end
    end
end

-- Run a command and wait for its output (nil, err on failure or after `timeout` s).
function Conn:run(cmd, timeout)
    local out, err, done
    self:shell(cmd, function(o, e) out, err, done = o, e, true end)
    local deadline = socket.gettime() + (timeout or 10)
    while not done do
        if socket.gettime() > deadline then return nil, "timeout" end
        local ok, e = self:pump(0.1)
        if not ok then return nil, e end
    end
    return out, err
end

function Conn:close()
    self.sock:close()
end

---------------------------------------------------------------------------
-- What's playing, from `dumpsys media_session` followed by "@@UPTIME" and /proc/uptime.

-- PlaybackState codes (android.media.session.PlaybackState) as Cast-style player states.
local STATES = { [0] = "IDLE", [1] = "IDLE", [2] = "PAUSED", [3] = "PLAYING", [4] = "PLAYING", [5] = "PLAYING",
                 [6] = "BUFFERING", [7] = "IDLE", [8] = "BUFFERING", [9] = "PLAYING", [10] = "PLAYING",
                 [11] = "PLAYING" }

-- { found, state, position (seconds, now), title } for `package`'s top session.
function adb.parseMediaSession(out, package)
    local body, uptime = out:match("^(.*)@@UPTIME%s+([%d%.]+)")
    body = body or out
    uptime = tonumber(uptime)
    -- each session's lines start at its "package=" line
    local blocks, cur = {}, nil
    for line in (body .. "\n"):gmatch("(.-)\r?\n") do
        local pkg = line:match("^%s+package=(%S+)")
        if pkg then
            cur = { pkg = pkg, lines = {} }
            blocks[#blocks + 1] = cur
        elseif cur then
            cur.lines[#cur.lines + 1] = line
        end
    end
    for _, b in ipairs(blocks) do
        if b.pkg == package then
            local text = table.concat(b.lines, "\n")
            local code, pos = text:match("state=PlaybackState {state=(%d+), position=(%-?%d+)")
            if code then
                local speed = tonumber(text:match("speed=(%-?[%d%.]+)")) or 1
                local updated = tonumber(text:match("updated=(%d+)"))
                local state = STATES[tonumber(code)] or "IDLE"
                local t = tonumber(pos) / 1000
                if state == "PLAYING" and uptime and updated then
                    t = t + math.max(0, uptime * 1000 - updated) / 1000 * speed
                end
                local title = text:match("description=([^\n]*)")
                if title then title = title:gsub(", null$", ""):gsub(", null,", ","):gsub("^null$", "") end
                return { found = true, state = state, position = math.max(0, t), title = title ~= "" and title or nil }
            end
        end
    end
    return { found = false }
end

return adb
