-- Notifications for the signed-in user's Seerr requests: checks them every
-- minute and pops up a toast when one is approved or declined, or when what
-- was requested shows up on Plex. The last status seen of each request is kept
-- in settings.seerrSeen, so changes made while the app was closed are announced
-- at the next start; the very first check only records them.

local client = require("plex.client")
local seerr = require("seerr.api")

local notify = {}

local INTERVAL = 60          -- seconds between checks
local RETRY = 300            -- after a failed check (Seerr down, account not allowed...)

local wait = 3               -- first check shortly after start
local busy = false
local queue = {}             -- toasts waiting their turn (app.toast shows one at a time)

-- Which change of a request is worth a toast, given what it was last time.
local function change(prev, req)
    local status = tonumber(req.status)
    local media = type(req.media) == "table" and tonumber(req.media.status) or nil
    if media and (media == seerr.AVAILABLE or media == seerr.PARTIAL)
        and (prev.m or 0) < seerr.PARTIAL then
        return "available"
    end
    if prev.r == seerr.REQUEST_PENDING then
        if status == seerr.REQUEST_DECLINED then return "declined" end
        if status and status ~= seerr.REQUEST_PENDING then return "approved" end
    end
end

local HEADINGS = {
    approved = { "Request approved", "success" },
    declined = { "Request declined", "error" },
    available = { "Now on Plex", "success" },
}

-- Look up the title (requests only carry the TMDB id), then queue the toast.
local function announce(req, what)
    local media = req.media
    local item = { mediaType = media.mediaType, tmdbId = media.tmdbId }
    seerr.details(item, function(d)
        local title = d and (d.title or d.name) or "your request"
        local heading, kind = HEADINGS[what][1], HEADINGS[what][2]
        queue[#queue + 1] = {
            msg = title, heading = heading, kind = kind, duration = 7,
            image = d and seerr.imageUrl(d.posterPath, "w154") or nil,
        }
    end)
end

function notify.check()
    if busy then return end
    busy = true
    seerr.myRequests(function(list, err)
        busy = false
        if not list then
            wait = RETRY
            return print("[seerr] request check failed: " .. tostring(err))
        end
        local seen = client.settings.seerrSeen
        local first = type(seen) ~= "table"
        local now, count, changed = {}, 0, first
        for _, req in ipairs(list) do
            local key = tostring(req.id)
            local media = type(req.media) == "table" and tonumber(req.media.status) or nil
            local entry = { r = tonumber(req.status), m = media }
            local prev = not first and seen[key]
            if prev then
                local what = change(prev, req)
                if what then announce(req, what) end
                if prev.r ~= entry.r or prev.m ~= entry.m then changed = true end
            elseif not first then
                changed = true                      -- new request (made here or on the website)
            end
            now[key] = entry
            count = count + 1
        end
        if not changed then
            for _ in pairs(seen) do count = count - 1 end
            changed = count ~= 0                    -- some dropped off the list
        end
        if changed then client.set("seerrSeen", now) end
    end)
end

function notify.update(dt)
    if not seerr.enabled() then return end
    if not app.toast and #queue > 0 then
        local t = table.remove(queue, 1)
        app.notify(t.msg, t.kind, t)
    end
    wait = wait - dt
    if wait <= 0 then
        wait = INTERVAL
        notify.check()
    end
end

return notify
