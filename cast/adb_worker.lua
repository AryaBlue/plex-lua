-- The Fire TV remote's connection (cast/adb.lua), on its own thread. Signs in over
-- ADB, then every second reads what Plex is playing from the TV's media session, and
-- presses remote buttons when asked (`input keyevent`, as the TV's own remote does).
--
-- In (cmd channel):  { op = "key", code } | { op = "keys", code, count } | { op = "close" }
-- Out (event channel): { ev = "state", state = "connecting" | "asking" | "ready" | "closed", err }
--                      | { ev = "status", found, state, position, title, at }
require("love.timer")
require("love.filesystem")

local cmdCh, evCh, dllPath, host, port, keyPath, package = ...
local ffi = require("ffi")
local adb = require("cast.adb")

local POLL = 1

local function emit(t) evCh:push(t) end

local okLib, lib = pcall(ffi.load, dllPath)
if not okLib then
    emit({ ev = "state", state = "closed", err = "castsock.dll: " .. tostring(lib) })
    return
end

emit({ ev = "state", state = "connecting" })
local conn, err = adb.connect(lib, keyPath, host, port, function() emit({ ev = "state", state = "asking" }) end, 90)
if not conn then
    emit({ ev = "state", state = "closed", err = err })
    return
end
emit({ ev = "state", state = "ready" })

local polling, lastPoll = false, -math.huge
local STATUS_CMD = "dumpsys media_session; echo @@UPTIME; cat /proc/uptime"

local function run()
    while true do
        while true do
            local c = cmdCh:pop()
            if not c then break end
            if c.op == "close" then return end
            if c.op == "key" then
                conn:shell("input keyevent " .. math.floor(c.code))
            elseif c.op == "keys" then
                -- one command, so the presses land close together
                local codes = {}
                for i = 1, math.min(c.count or 1, 40) do codes[i] = math.floor(c.code) end
                conn:shell("input keyevent " .. table.concat(codes, " "))
            end
            lastPoll = -math.huge        -- show the result soon
        end
        local now = love.timer.getTime()
        if not polling and now - lastPoll >= POLL then
            polling, lastPoll = true, now
            conn:shell(STATUS_CMD, function(out)
                polling = false
                if not out then return end
                local st = adb.parseMediaSession(out, package)
                st.ev, st.at = "status", love.timer.getTime()
                emit(st)
            end)
        end
        local ok, e = conn:pump(0.05)
        if not ok then
            emit({ ev = "state", state = "closed", err = "the TV dropped the connection (" .. tostring(e) .. ")" })
            return "dropped"
        end
    end
end

local okRun, res = pcall(run)
conn:close()
if not okRun then emit({ ev = "state", state = "closed", err = tostring(res) })
elseif res ~= "dropped" then emit({ ev = "state", state = "closed" }) end
