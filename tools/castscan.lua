-- lovec E:\PlexLove --castscan [dial-only] : list the cast targets Reel can see, then quit.
-- Only looks (mDNS query, SSDP to settings.castDialHosts, each DIAL device's description);
-- never launches anything. dial-only skips the mDNS (Chromecast) query.

local cast = require("cast")

local T = {}
local t = 0

function T.start(args)
    for _, a in ipairs(args) do
        if a == "dial-only" then cast.testHooks = { chromecast = false } end
    end
    local s = require("plex.client").settings
    print(("[castscan] DIAL hosts: %s; whole-network DIAL: %s; blocked: %s"):format(
        table.concat(s.castDialHosts or {}, ", "), tostring(s.castDialScan), table.concat(s.castBlock or {}, ", ")))
    app.push({})
    cast.scan()
end

function T.update(dt)
    t = t + dt
    if cast.scanning and t < 15 then return end
    print(("[castscan] %d device(s)"):format(#cast.devices))
    for _, d in ipairs(cast.devices) do
        print(("  %-10s %-30s %s  %s"):format(d.kind, d.name, d.host, d.appUrl or ("port " .. tostring(d.port))))
    end
    love.event.quit(0)
    T.update = function() end
end

return T
