-- One Chromecast connection, on its own thread so a slow or vanished device
-- never holds up the app. Talks Cast v2 over TLS (castsock.dll):
--   connect to the platform receiver ("receiver-0"), launch the app (Plex's
--   receiver, 9AC194DC), connect to the app's transport, then relay media
--   commands and status. Answers heartbeats and pings every 5 s.
--
-- In (cmd channel):  { op = "load", payload = json } | { op = "media", type, currentTime }
--                    | { op = "volume", level | muted } | { op = "stopApp" } | { op = "close" }
-- Out (event channel): { ev = "state", state = "connecting" | "launching" | "ready" | "closed", err }
--                      | { ev = "media", payload = json } | { ev = "receiver", payload = json }
--                      | { ev = "error", err }
require("love.timer")
require("love.filesystem")

local cmdCh, evCh, dllPath, host, port, appId = ...
local ffi = require("ffi")
local json = require("lib.json")
local proto = require("cast.proto")

ffi.cdef [[
typedef struct cs_conn cs_conn;
cs_conn *cs_open(const char *host, int port, int timeout_ms);
const char *cs_open_error(void);
int cs_send(cs_conn *c, const char *buf, int len);
int cs_recv(cs_conn *c, char *buf, int cap, int timeout_ms);
const char *cs_error(cs_conn *c);
void cs_close(cs_conn *c);
]]

local NS = {
    conn = "urn:x-cast:com.google.cast.tp.connection",
    heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat",
    receiver = "urn:x-cast:com.google.cast.receiver",
    media = "urn:x-cast:com.google.cast.media",
}
local SENDER = "sender-reel"
local PLATFORM = "receiver-0"

local function emit(t) evCh:push(t) end

local ok, lib = pcall(ffi.load, dllPath)
if not ok then
    emit({ ev = "state", state = "closed", err = "castsock.dll: " .. tostring(lib) })
    return
end

emit({ ev = "state", state = "connecting" })
local conn = lib.cs_open(host, port, 5000)
if conn == nil then
    emit({ ev = "state", state = "closed", err = "couldn't connect: " .. ffi.string(lib.cs_open_error()) })
    return
end

local requestId = 0
local function send(dest, ns, msg)
    if msg.type ~= "PING" and msg.type ~= "PONG" and msg.type ~= "CONNECT" then
        requestId = requestId + 1
        msg.requestId = requestId
    end
    local frame = proto.encode(SENDER, dest, ns, json.encode(msg))
    if lib.cs_send(conn, frame, #frame) ~= 0 then error("send: " .. ffi.string(lib.cs_error(conn))) end
    return requestId
end

local transport, appSession, mediaSession
local launched = false
local lastHeard = love.timer.getTime()
local lastPing = 0
local feed = proto.reader()
local buf = ffi.new("char[?]", 16384)

local function connectTo(dest)
    send(dest, NS.conn, { type = "CONNECT", userAgent = "Reel" })
end

local function onReceiverStatus(st)
    local apps = st.status and st.status.applications
    local app
    if type(apps) == "table" then
        for _, a in ipairs(apps) do if a.appId == appId then app = a end end
    end
    if app and app.transportId then
        if transport ~= app.transportId then
            transport, appSession = app.transportId, app.sessionId
            connectTo(transport)
            send(transport, NS.media, { type = "GET_STATUS" })
            emit({ ev = "state", state = "ready" })
        end
    elseif transport then
        -- our app was closed on the TV (or replaced by another)
        transport, appSession, mediaSession = nil, nil, nil
        emit({ ev = "state", state = "closed", err = "the app on the TV was closed" })
        return "stop"
    elseif not launched then
        launched = true
        emit({ ev = "state", state = "launching" })
        send(PLATFORM, NS.receiver, { type = "LAUNCH", appId = appId })
    end
end

local function handle(m)
    lastHeard = love.timer.getTime()
    local okDecode, data = pcall(json.decode, m.payload or "")
    if not okDecode or type(data) ~= "table" then return end
    local t = data.type
    if m.namespace == NS.heartbeat then
        if t == "PING" then send(m.source, NS.heartbeat, { type = "PONG" }) end
    elseif m.namespace == NS.conn then
        if t == "CLOSE" and m.source == transport then
            emit({ ev = "state", state = "closed", err = "the TV closed the connection" })
            return "stop"
        end
    elseif m.namespace == NS.receiver then
        if t == "RECEIVER_STATUS" then
            emit({ ev = "receiver", payload = m.payload })
            return onReceiverStatus(data)
        elseif t == "LAUNCH_ERROR" or t == "INVALID_REQUEST" then
            emit({ ev = "state", state = "closed", err = "the TV couldn't open Plex (" .. tostring(data.reason or t) .. ")" })
            return "stop"
        end
    elseif m.namespace == NS.media then
        if t == "MEDIA_STATUS" then
            local s = type(data.status) == "table" and data.status[1]
            if s and s.mediaSessionId then mediaSession = s.mediaSessionId end
            emit({ ev = "media", payload = m.payload })
        elseif t == "LOAD_FAILED" or t == "LOAD_CANCELLED" or t == "INVALID_REQUEST" or t == "ERROR" then
            emit({ ev = "error", err = tostring(data.reason or data.detailedErrorCode or t) })
        end
    end
end

local function command(c)
    if c.op == "close" then
        if transport then send(transport, NS.conn, { type = "CLOSE" }) end
        send(PLATFORM, NS.conn, { type = "CLOSE" })
        return "stop"
    elseif c.op == "stopApp" then
        if appSession then send(PLATFORM, NS.receiver, { type = "STOP", sessionId = appSession }) end
        return "stop"
    elseif c.op == "volume" then
        send(PLATFORM, NS.receiver, { type = "SET_VOLUME", volume = c.muted ~= nil and { muted = c.muted } or { level = c.level } })
    elseif not transport then
        emit({ ev = "error", err = "not connected to the app yet" })
    elseif c.op == "load" then
        local msg = json.decode(c.payload)
        msg.sessionId = appSession
        send(transport, NS.media, msg)
    elseif c.op == "media" then
        if c.type == "GET_STATUS" then
            send(transport, NS.media, { type = "GET_STATUS" })
        elseif mediaSession then
            send(transport, NS.media, { type = c.type, mediaSessionId = mediaSession,
                currentTime = c.currentTime, resumeState = c.currentTime and "PLAYBACK_START" or nil })
        end
    end
end

local function run()
    connectTo(PLATFORM)
    send(PLATFORM, NS.receiver, { type = "GET_STATUS" })
    while true do
        while true do
            local c = cmdCh:pop()
            if not c then break end
            if command(c) == "stop" then return end
        end
        local now = love.timer.getTime()
        if now - lastPing > 5 then
            lastPing = now
            send(PLATFORM, NS.heartbeat, { type = "PING" })
        end
        if now - lastHeard > 16 then
            emit({ ev = "state", state = "closed", err = "the TV stopped answering" })
            return
        end
        local n = lib.cs_recv(conn, buf, 16384, 100)
        if n < 0 then
            emit({ ev = "state", state = "closed", err = ffi.string(lib.cs_error(conn)) })
            return
        elseif n > 0 then
            for _, m in ipairs(feed(ffi.string(buf, n))) do
                if handle(m) == "stop" then return end
            end
        end
    end
end

local okRun, err = pcall(run)
lib.cs_close(conn)
if not okRun then emit({ ev = "state", state = "closed", err = tostring(err) }) end
emit({ ev = "state", state = "closed" })
