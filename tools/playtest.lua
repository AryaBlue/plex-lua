-- lovec E:\PlexLove --playtest <ratingKey> [seconds]
-- Runs the real player scene (muted) on an item for a while and logs its
-- state, clock and any stream errors / reconnects. Reports "stopped" at the end.

local client = require("plex.client")
local servers = require("plex.servers")
local api = require("plex.api")
local auth = require("plex.auth")

local T = {}
local t0 = love.timer.getTime()
local function log(fmt, ...) print(("[play %6.1fs] " .. fmt):format(love.timer.getTime() - t0, ...)) end

function T.start(args)
    local key, secs
    for i, a in ipairs(args) do
        if a == "--playtest" then key, secs = args[i + 1], tonumber(args[i + 2]) end
    end
    T.duration = secs or 150
    love.audio.setVolume(0)
    app.push({})   -- base scene to return to
    auth.verify(function(user)
        if not user then log("not signed in"); return love.event.quit(1) end
        servers.fetch(function(list)
            for _, s in ipairs(list or {}) do
                if s.id == client.settings.serverId then
                    s:connect(function(server)
                        -- connect() reports every successful connection; start exactly one player
                        if server.state ~= "online" or T.requested then return end
                        T.requested = true
                        log("server via %s", server:connectionLabel())
                        api.metadata(server, key, function(item)
                            if not item then log("no item"); return love.event.quit(1) end
                            log("playing %s", item.title)
                            T.player = require("player.scene").new(server, item, { startAt = 0 })
                            app.push(T.player)
                            T.started = love.timer.getTime()
                        end)
                    end)
                end
            end
        end)
    end)
end

local lastLog = 0
function T.update()
    local p = T.player
    if not p then return end
    local now = love.timer.getTime()
    if p.state ~= T.lastState then
        log("state -> %s%s", p.state, p.error and (": " .. p.error) or "")
        T.lastState = p.state
    end
    if now - lastLog >= 5 then
        lastLog = now
        local starved = p.audio and p.audio:isStarved()
        log("t=%.1f  state=%s  starved=%s  recoveries=%d  fps=%d", p:mediaTime(), p.state, tostring(starved),
            p.recoveries and #p.recoveries or 0, love.timer.getFPS())
    end
    if now - T.started > T.duration or p.state == "error" or app.top() ~= p then
        log("finished: state=%s t=%.1f", p.state, p:mediaTime())
        if app.top() == p then app.pop() end    -- leave() reports "stopped"
        T.player = nil
        T.quitAt = now + 1.5
    end
end

local base = T.update
T.update = function(dt)
    if T.quitAt and love.timer.getTime() > T.quitAt then return love.event.quit(0) end
    base(dt)
end

return T
