-- The account's Plex watchlist (plex.tv Discover, shared with Plex's own apps).
--   GET https://discover.provider.plex.tv/library/sections/watchlist/all  the list (includeGuids=1 adds tmdb:// ids)
--   PUT .../actions/addToWatchlist?ratingKey=ID       (the provider's action, as Plex Web sends it)
--   PUT .../actions/removeFromWatchlist?ratingKey=ID
-- ID is the last part of the item's plex:// guid (plex://movie/5d77...), so a
-- library item maps to it directly; an episode's or season's show is used.
-- Entries are matched to the server's own items with one
-- GET /library/all?guid=a,b,... ; titles not on the server stay as plex.tv
-- entries (and can be requested through Seerr).

local http = require("lib.http")
local client = require("plex.client")

local watchlist = {}

local PROVIDER = "https://discover.provider.plex.tv"
local PAGE = 100

local entries = nil          -- plex.tv metadata, newest first; nil until loaded
local guids = {}             -- plex:// guid -> true
watchlist.version = 0        -- bumps on every change, so screens know to refresh

-- The plex:// guid an item is watchlisted under (episodes/seasons: their show).
function watchlist.guidOf(item)
    if not item then return nil end
    local g
    if item.type == "movie" or item.type == "show" then g = item.guid
    elseif item.type == "episode" then g = item.grandparentGuid
    elseif item.type == "season" then g = item.parentGuid end
    if type(g) == "string" and g:match("^plex://%a+/%w+$") then return g end
    return nil
end

function watchlist.loaded() return entries ~= nil end

function watchlist.has(item)
    local g = watchlist.guidOf(item)
    return g ~= nil and guids[g] == true
end

-- Fetch the whole list (all pages). callback(entries) or nil, err.
function watchlist.load(callback)
    local all = {}
    local function page(start)
        http.json({
            url = http.withQuery(PROVIDER .. "/library/sections/watchlist/all", {
                includeGuids = 1, ["X-Plex-Container-Start"] = start, ["X-Plex-Container-Size"] = PAGE,
            }),
            headers = client.headers(), timeout = 20,
        }, function(data, err)
            local mc = data and data.MediaContainer
            if not mc then return callback and callback(nil, err) end
            for _, m in ipairs(mc.Metadata or {}) do all[#all + 1] = m end
            local total = tonumber(mc.totalSize) or #all
            if #all < total and #(mc.Metadata or {}) > 0 then return page(#all) end
            entries, guids = all, {}
            for _, m in ipairs(all) do if m.guid then guids[m.guid] = true end end
            watchlist.version = watchlist.version + 1
            if callback then callback(all) end
        end)
    end
    page(0)
end

-- Add or remove `item`. callback(ok, err)
function watchlist.set(item, on, callback)
    local g = watchlist.guidOf(item)
    if not g then return callback and callback(false, "this title isn't from Plex's catalogue") end
    local id = g:match("/(%w+)$")
    http.request({
        method = "PUT", headers = client.headers(), timeout = 15,
        url = http.withQuery(PROVIDER .. "/actions/" .. (on and "addToWatchlist" or "removeFromWatchlist"),
            { ratingKey = id }),
    }, function(res, err)
        local ok = res and res.status >= 200 and res.status < 300
        if ok then
            guids[g] = on or nil
            if entries then
                if on then
                    local title = item.type == "episode" and item.grandparentTitle
                        or item.type == "season" and item.parentTitle or item.title
                    table.insert(entries, 1, { guid = g, ratingKey = id, title = title,
                                               type = item.type == "movie" and "movie" or "show" })
                else
                    for i = #entries, 1, -1 do if entries[i].guid == g then table.remove(entries, i) end end
                end
            end
            watchlist.version = watchlist.version + 1
        end
        if callback then callback(ok, err or (res and "HTTP " .. res.status)) end
    end)
end

local function externalId(m, scheme)
    for _, g in ipairs(m.Guid or {}) do
        local v = type(g.id) == "string" and g.id:match("^" .. scheme .. "://(.+)$")
        if v then return v end
    end
end

-- The watchlist as cards for `server`: its own item where the server has the
-- title, otherwise the plex.tv entry marked notOnServer (with mediaType and
-- tmdbId so Seerr can request it). callback(items) or nil, err.
function watchlist.items(server, callback)
    if not entries then
        return watchlist.load(function(list, err)
            if not list then return callback(nil, err) end
            watchlist.items(server, callback)
        end)
    end
    local list = entries
    local found = {}
    local pending = 0
    local function done()
        local out = {}
        for _, m in ipairs(list) do
            local local_ = found[m.guid]
            if local_ then
                out[#out + 1] = local_
            else
                out[#out + 1] = {
                    notOnServer = true, guid = m.guid,
                    type = m.type, mediaType = m.type == "show" and "tv" or "movie",
                    tmdbId = tonumber(externalId(m, "tmdb")),
                    ratingKey = "watchlist:" .. tostring(m.ratingKey),
                    title = m.title or "?", year = m.year, summary = m.summary,
                    thumb = m.thumb, art = m.art,       -- full URLs; W.itemImage loads them as is
                    badge = "Not in library",
                }
            end
        end
        callback(out)
    end
    -- look the guids up on the server, 40 to a request to keep URLs short
    local batch = {}
    local function send(b)
        pending = pending + 1
        http.json({
            url = http.withQuery(server:baseUrl() .. "/library/all", { guid = table.concat(b, ",") }),
            headers = client.headers(server.accessToken), timeout = 20,
        }, function(data)
            local mc = data and data.MediaContainer
            for _, it in ipairs(mc and mc.Metadata or {}) do
                if it.guid and not found[it.guid] then found[it.guid] = it end
            end
            pending = pending - 1
            if pending == 0 then done() end
        end)
    end
    for _, m in ipairs(list) do
        if m.guid then
            batch[#batch + 1] = m.guid
            if #batch == 40 then send(batch); batch = {} end
        end
    end
    if #batch > 0 then send(batch) end
    if pending == 0 then done() end
end

return watchlist
