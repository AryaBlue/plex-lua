-- Plex Media Server requests for one connected server. Paths and parameters
-- follow the PMS OpenAPI spec (docs/pms-openapi.json).

local http = require("lib.http")
local client = require("plex.client")

local api = {}

local function url(server, path, params)
    return http.withQuery(server:baseUrl() .. path, params)
end

local function get(server, path, params, callback, opts)
    opts = opts or {}
    local headers = client.headers(server.accessToken)
    if opts.start then
        headers["X-Plex-Container-Start"] = opts.start
        headers["X-Plex-Container-Size"] = opts.size or 50
    end
    return http.json({ url = url(server, path, params), headers = headers, timeout = opts.timeout or 20 },
        function(data, err, res)
            if not data then return callback(nil, err, res) end
            callback(data.MediaContainer or data, nil, res)
        end)
end
api.get = get

-- Home hubs (Continue Watching, Recently Added..., per-library rows).
function api.hubs(server, callback)
    return get(server, "/hubs", { count = 20 }, function(mc, err)
        if not mc then return callback(nil, err) end
        callback(mc.Hub or {})
    end)
end

function api.continueWatching(server, callback)
    return get(server, "/hubs/continueWatching", { count = 20 }, function(mc, err)
        if not mc then return callback(nil, err) end
        local hub = (mc.Hub or {})[1]
        callback(hub and hub.Metadata or {})
    end)
end

function api.promoted(server, callback)
    return get(server, "/hubs/promoted", { count = 12 }, function(mc, err)
        if not mc then return callback(nil, err) end
        callback(mc.Hub or {})
    end)
end

function api.sections(server, callback)
    return get(server, "/library/sections", nil, function(mc, err)
        if not mc then return callback(nil, err) end
        callback(mc.Directory or {})
    end)
end

-- One page of a library: GET /library/sections/{id}/all with a media query sort.
-- genre: optional genre id (from api.genres) to show only that genre.
-- callback(items, totalSize | nil, err)
function api.sectionItems(server, sectionKey, sort, start, size, callback, genre)
    return get(server, "/library/sections/" .. sectionKey .. "/all", { sort = sort, genre = genre }, function(mc, err)
        if not mc then return callback(nil, err) end
        callback(mc.Metadata or {}, tonumber(mc.totalSize) or tonumber(mc.size) or 0)
    end, { start = start, size = size })
end

-- Genres used in a library: GET /library/sections/{id}/genre. callback({ {id, title} }) or nil, err.
function api.genres(server, sectionKey, callback)
    return get(server, "/library/sections/" .. sectionKey .. "/genre", nil, function(mc, err)
        if not mc then return callback(nil, err) end
        local list = {}
        for _, d in ipairs(mc.Directory or {}) do
            -- key is the bare id, or a path ending in ?genre=id on some servers
            local id = d.key and (tostring(d.key):match("genre=(%d+)") or tostring(d.key))
            if id and d.title then list[#list + 1] = { id = id, title = d.title } end
        end
        callback(list)
    end)
end

function api.metadata(server, ratingKey, callback)
    return get(server, "/library/metadata/" .. ratingKey, { includeChildren = 1, includeExtras = 0, includeMarkers = 1 },
        function(mc, err)
            if not mc then return callback(nil, err) end
            callback((mc.Metadata or {})[1])
        end)
end

-- Seasons of a show, episodes of a season.
function api.children(server, ratingKey, callback)
    return get(server, "/library/metadata/" .. ratingKey .. "/children", nil, function(mc, err)
        if not mc then return callback(nil, err) end
        callback(mc.Metadata or {})
    end, { start = 0, size = 500 })
end

-- The episode after `ep` (next in its season, else the first of the next
-- season), as full metadata. callback(item) or callback(nil) at the end of the show.
function api.nextEpisode(server, ep, callback)
    if ep.type ~= "episode" or not ep.parentRatingKey then return callback(nil) end
    local function lowest(list, above)
        local best
        for _, it in ipairs(list or {}) do
            local i = tonumber(it.index)
            if i and i > above and (not best or i < tonumber(best.index)) then best = it end
        end
        return best
    end
    local function full(it)
        if not it then return callback(nil) end
        api.metadata(server, it.ratingKey, function(m) callback(m) end)
    end
    api.children(server, ep.parentRatingKey, function(eps)
        local nextEp = lowest(eps, tonumber(ep.index) or math.huge)
        if nextEp or not ep.grandparentRatingKey then return full(nextEp) end
        api.children(server, ep.grandparentRatingKey, function(seasons)
            local season = lowest(seasons, math.max(0, tonumber(ep.parentIndex) or math.huge))
            if not season then return callback(nil) end
            api.children(server, season.ratingKey, function(eps2) full(lowest(eps2, -1)) end)
        end)
    end)
end

-- Where the end credits start (seconds), from the server's credits markers.
function api.creditsStart(item)
    local at
    for _, m in ipairs(item.Marker or {}) do
        if m.type == "credits" and tonumber(m.startTimeOffset) then
            local t = tonumber(m.startTimeOffset) / 1000
            if m.final or not at then at = t end
        end
    end
    return at
end

-- Items of a hub that has more than were inlined (hub.key).
function api.hubItems(server, key, callback)
    return get(server, key, nil, function(mc, err)
        if not mc then return callback(nil, err) end
        callback(mc.Metadata or {})
    end, { start = 0, size = 60 })
end

-- GET /hubs/search: matches across all libraries, one hub per type, best hubs first.
-- callback(hubs) with { title, type, items } for the hubs that hold openable items, or nil, err.
local SEARCHABLE = { movie = true, show = true, season = true, episode = true, clip = true }
function api.search(server, query, callback)
    return get(server, "/hubs/search", { query = query, limit = 30 }, function(mc, err, res)
        -- 404 means "no possible results" (e.g. no libraries), not a failure
        if not mc then
            if res and res.status == 404 then return callback({}) end
            return callback(nil, err)
        end
        local hubs = {}
        for _, hub in ipairs(mc.Hub or {}) do
            if hub.type == "genre" then
                -- one tag per library that has the genre: opens that library filtered to it
                local items = {}
                for _, t in ipairs(hub.Metadata or hub.Directory or {}) do
                    local section = t.librarySectionID or (t.key or ""):match("/sections/(%d+)/")
                    local name = t.tag or t.title
                    if section and t.id and name then
                        items[#items + 1] = { type = "genre", title = name, genre = tostring(t.id),
                                              sectionKey = tostring(section), sectionTitle = t.librarySectionTitle, count = tonumber(t.count),
                                              ratingKey = "genre:" .. section .. ":" .. t.id }
                    end
                end
                if #items > 0 then hubs[#hubs + 1] = { title = "Genres", type = "genre", hub = hub, items = items } end
                goto continue
            end
            local items, seen = {}, {}
            for _, list in ipairs({ hub.Metadata or {}, hub.Directory or {} }) do
                for _, it in ipairs(list) do
                    if SEARCHABLE[it.type] and it.ratingKey and not seen[it.ratingKey] then
                        seen[it.ratingKey] = true
                        items[#items + 1] = it
                    end
                end
            end
            if #items > 0 then hubs[#hubs + 1] = { title = hub.title or "", type = hub.type, hub = hub, items = items } end
            ::continue::
        end
        callback(hubs)
    end)
end

-- Resized artwork through /photo/:/transcode (thumb/art paths are server-relative).
function api.imageUrl(server, path, width, height)
    if not path or path == "" or not server:baseUrl() then return nil end
    return url(server, "/photo/:/transcode", {
        url = path, width = math.floor(width), height = math.floor(height),
        minSize = 1, upscale = 1, format = "jpg", quality = 85,
        ["X-Plex-Token"] = server.accessToken or client.settings.token,
    })
end

-- First playable part of an item: { url, part, media, container, ... } or nil.
function api.directPlay(server, item)
    local media = item and item.Media and item.Media[1]
    local part = media and media.Part and media.Part[1]
    if not part or not part.key then return nil end
    return {
        url = url(server, part.key, { ["X-Plex-Token"] = server.accessToken or client.settings.token }),
        part = part,
        media = media,
        container = part.container or media.container,
        videoCodec = media.videoCodec,
        audioCodec = media.audioCodec,
        duration = (tonumber(part.duration) or tonumber(item.duration) or 0) / 1000,
    }
end

-- POST /:/timeline  state = playing | paused | stopped | buffering; times in seconds.
function api.timeline(server, item, state, time, duration, sessionId)
    local headers = client.headers(server.accessToken)
    headers["X-Plex-Session-Identifier"] = sessionId
    return http.request({
        method = "POST", headers = headers, timeout = 10,
        url = url(server, "/:/timeline", {
            ratingKey = item.ratingKey, key = item.key, state = state,
            time = math.floor(time * 1000), duration = math.floor(duration * 1000),
        }),
    }, function() end)
end

-- GET /video/:/transcode/universal/stop: end a conversion the player has left.
function api.stopTranscode(server, sessionId)
    return http.request({
        method = "GET", headers = client.headers(server.accessToken), timeout = 10,
        url = url(server, "/video/:/transcode/universal/stop", { session = sessionId }),
    }, function() end)
end

-- PUT /:/scrobble or /:/unscrobble (mark watched / unwatched).
function api.setWatched(server, item, watched, callback)
    local path = watched and "/:/scrobble" or "/:/unscrobble"
    return http.request({
        method = "PUT", headers = client.headers(server.accessToken), timeout = 15,
        url = url(server, path, { identifier = "com.plexapp.plugins.library", key = item.ratingKey }),
    }, function(res, err)
        if callback then callback(res and res.status >= 200 and res.status < 300, err) end
    end)
end

-- PUT /actions/removeFromContinueWatching (the library provider's action, as
-- Plex Web sends it): hides an item from Continue Watching.
-- Your star rating (Plex's userRating): 0..10, two per star. nil clears it
-- (rating=-1, what Plex Web sends; the spec only lists 0..10).
function api.rate(server, item, rating, callback)
    return http.request({
        method = "PUT", headers = client.headers(server.accessToken), timeout = 15,
        url = url(server, "/:/rate", { identifier = "com.plexapp.plugins.library", key = item.ratingKey,
                                       rating = rating or -1 }),
    }, function(res, err)
        if callback then callback(res and res.status >= 200 and res.status < 300, err) end
    end)
end

-- A userRating as stars: "4½ stars", "1 star", "Not rated".
function api.starsText(rating)
    local halves = math.floor((tonumber(rating) or 0) + 0.5)
    if halves <= 0 then return "Not rated" end
    local whole = math.floor(halves / 2)
    return (whole > 0 and tostring(whole) or "") .. (halves % 2 == 1 and "½" or "")
        .. (halves == 2 and " star" or " stars")
end

function api.removeFromContinueWatching(server, item, callback)
    return http.request({
        method = "PUT", headers = client.headers(server.accessToken), timeout = 15,
        url = url(server, "/actions/removeFromContinueWatching", { ratingKey = item.ratingKey }),
    }, function(res, err)
        if callback then callback(res and res.status >= 200 and res.status < 300, err or (res and "HTTP " .. res.status)) end
    end)
end

-- An item's own settings (shows: preferred audio and subtitle language,
-- subtitle mode), as Plex Web's Edit > Advanced shows them.
-- callback(settings) or nil, err; each { id, label, value, default, options = { {value, label} } }
function api.itemPrefs(server, ratingKey, callback)
    return get(server, "/library/metadata/" .. ratingKey, { includePreferences = 1 }, function(mc, err)
        local item = mc and mc.Metadata and mc.Metadata[1]
        if not item then return callback(nil, err or "not found") end
        local out = {}
        for _, st in ipairs(item.Preferences and item.Preferences.Setting or {}) do
            local options, seen = {}, {}
            for pair in tostring(st.enumValues or ""):gmatch("[^|]+") do
                local value, label = pair:match("^([^:]*):(.*)$")
                if value then
                    -- the list has e.g. English for "en" and again for "en-US"
                    if seen[label] then label = label .. " (" .. value .. ")" end
                    seen[label] = true
                    options[#options + 1] = { value = value, label = label }
                end
            end
            out[#out + 1] = { id = st.id, label = st.label, value = tostring(st.value or ""),
                              default = tostring(st.default or ""), options = options }
        end
        callback(out)
    end)
end

-- PUT /library/metadata/{id}/prefs?name=value...  callback(ok, err)
function api.setItemPrefs(server, ratingKey, values, callback)
    return http.request({
        method = "PUT", headers = client.headers(server.accessToken), timeout = 15,
        url = url(server, "/library/metadata/" .. ratingKey .. "/prefs", values),
    }, function(res, err)
        if callback then callback(res and res.status >= 200 and res.status < 300, err or (res and "HTTP " .. res.status)) end
    end)
end

-- Watched state of an item: watched (all of it), started (partly, or some episodes).
function api.watchState(item)
    local leaves, viewed = tonumber(item.leafCount), tonumber(item.viewedLeafCount)
    if leaves then return (viewed or 0) >= leaves, (viewed or 0) > 0 end
    local count, offset = tonumber(item.viewCount) or 0, (tonumber(item.viewOffset) or 0) > 0
    return count > 0 and not offset, count > 0 or offset
end

-- Update an item after marking it, so its card redraws without a reload.
function api.applyWatched(item, watched)
    item.viewOffset = nil
    item.viewCount = watched and math.max(1, tonumber(item.viewCount) or 0) or nil
    if item.leafCount then item.viewedLeafCount = watched and item.leafCount or 0 end
end

-- GET /hubs/metadata/{id}/related ("More like this").
function api.related(server, ratingKey, callback)
    return get(server, "/hubs/metadata/" .. ratingKey .. "/related", { count = 20 }, function(mc, err)
        if not mc then return callback(nil, err) end
        for _, hub in ipairs(mc.Hub or {}) do
            if hub.Metadata and #hub.Metadata > 0 then return callback(hub.Metadata, hub.title) end
        end
        callback({})
    end)
end

-- Everything an actor (a Role's id) is in, per film and TV library, newest first.
-- callback({ { title = section title, items } }) or nil, err.
function api.byActor(server, actorId, callback)
    api.sections(server, function(list, err)
        if not list then return callback(nil, err) end
        local libs = {}
        for _, s in ipairs(list) do
            if s.type == "movie" or s.type == "show" then libs[#libs + 1] = s end
        end
        local rows, left, failed = {}, #libs, nil
        if left == 0 then return callback({}) end
        for i, s in ipairs(libs) do
            get(server, "/library/sections/" .. s.key .. "/all", { actor = actorId, sort = "originallyAvailableAt:desc" },
                function(mc, ferr)
                    if mc and mc.Metadata and #mc.Metadata > 0 then rows[i] = { title = s.title, items = mc.Metadata } end
                    if not mc then failed = ferr end
                    left = left - 1
                    if left > 0 then return end
                    local out = {}
                    for j = 1, #libs do if rows[j] then out[#out + 1] = rows[j] end end
                    if #out == 0 and failed then return callback(nil, failed) end
                    callback(out)
                end)
        end
    end)
end

-- Plex-style display helpers.
function api.subtitle(item)
    if item.type == "episode" then
        return ("S%d · E%d  %s"):format(tonumber(item.parentIndex) or 0, tonumber(item.index) or 0,
                                         item.grandparentTitle or "")
    elseif item.type == "season" then
        return item.parentTitle or ""
    end
    return item.year and tostring(item.year) or ""
end

function api.displayTitle(item)
    if item.type == "episode" then return item.grandparentTitle or item.title end
    return item.title or "?"
end

function api.posterPath(item)
    if item.type == "episode" then return item.grandparentThumb or item.parentThumb or item.thumb end
    if item.type == "season" then return item.thumb or item.parentThumb end
    return item.thumb
end

function api.isPlayable(item)
    return item.type == "movie" or item.type == "episode" or item.type == "clip"
end

-- "1h 52m" / "48m" from milliseconds.
-- Seconds as a clock: 4:05, 1:02:03.
function api.clock(t)
    t = math.max(0, math.floor(t or 0))
    local h, m, sec = math.floor(t / 3600), math.floor(t / 60) % 60, t % 60
    if h > 0 then return ("%d:%02d:%02d"):format(h, m, sec) end
    return ("%d:%02d"):format(m, sec)
end

function api.runtime(ms)
    local mins = math.floor((tonumber(ms) or 0) / 60000 + 0.5)
    if mins >= 60 then return ("%dh %dm"):format(math.floor(mins / 60), mins % 60) end
    return mins .. "m"
end

function api.progress(item)
    local off, dur = tonumber(item.viewOffset), tonumber(item.duration)
    if off and dur and dur > 0 then return off / dur end
    return nil
end

return api
