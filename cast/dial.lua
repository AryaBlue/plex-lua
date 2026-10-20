-- DIAL (DIscovery And Launch), how Chrome's cast menu reaches Fire TV sticks and
-- smart TVs: each device lists its apps under an Application-URL; GET <url>/<app>
-- gives the app's state, POST <url>/<app> starts it, with an optional text body
-- the device hands to the app as launch data.
--
-- Plex on Fire TV registers as "com.plexapp.android" (checked on a Fire TV stick,
-- 2026-10-19; "Plex" answers 404 there). It doesn't offer Plex Companion remote
-- control, so Reel opens Plex on the device and drives playback over ADB instead
-- (cast/adb_worker.lua).
-- dial.launchData is where a "play this item" payload goes once the Fire TV app's
-- handling of DIAL launch data is known (it needs the app itself, pulled with ADB).

local http = require("lib.http")

local dial = {}

-- App names to try, in order.
local PLEX_APPS = { "com.plexapp.android", "Plex" }

-- Launch data for Plex: none yet (see above), so the app just opens.
function dial.launchData(server, item, offset)
    return nil
end

-- callback(name | nil, state) for the first Plex app the device has.
function dial.findPlex(device, callback, i)
    i = i or 1
    local name = PLEX_APPS[i]
    if not name then return callback(nil) end
    http.request({ url = device.appUrl .. "/" .. name, timeout = 5 }, function(res)
        if res and res.status == 200 and res.body then
            return callback(name, res.body:match("<state>%s*(.-)%s*</state>"))
        end
        dial.findPlex(device, callback, i + 1)
    end)
end

-- Open Plex on the device. callback(ok, err)
function dial.start(device, server, item, offset, callback)
    dial.findPlex(device, function(name, state)
        if not name then return callback(false, "Plex isn't installed on " .. device.name) end
        local body = dial.launchData(server, item, offset)
        if state == "running" and not body then
            return callback(true)       -- already open; a bare launch would do nothing more
        end
        http.request({
            url = device.appUrl .. "/" .. name, method = "POST", timeout = 10, body = body or "",
            headers = { ["Content-Type"] = "text/plain; charset=utf-8" },
        }, function(res, err)
            if res and (res.status == 201 or res.status == 200) then return callback(true) end
            callback(false, res and ("the device answered HTTP " .. res.status) or tostring(err))
        end)
    end)
end

return dial
