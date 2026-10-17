-- Seerr (Overseerr / Jellyseerr) requests: find films and shows that aren't on
-- the Plex server and ask for them. Signs in with the Plex account token
-- (POST /api/v1/auth/plex), so requests are made as the same user; the session
-- cookie it returns is sent with every later call.
--
-- The server URL is settings.seerrUrl (falls back to DEFAULT_URL).

local http = require("lib.http")
local json = require("lib.json")
local client = require("plex.client")

local seerr = {}

local DEFAULT_URL = "https://seerr.proddy.xyz"
local TMDB_IMAGES = "https://image.tmdb.org/t/p/"

-- Media status (mediaInfo.status, also per season)
seerr.UNKNOWN, seerr.PENDING, seerr.PROCESSING = 1, 2, 3
seerr.PARTIAL, seerr.AVAILABLE, seerr.BLOCKLISTED, seerr.DELETED = 4, 5, 6, 7
-- Request status
local REQUEST_DECLINED = 3

local cookie            -- "connect.sid=..." once signed in
local user              -- the signed-in Seerr user
local loginWaiters      -- callbacks waiting on a login in flight

function seerr.baseUrl()
    return ((client.settings.seerrUrl or DEFAULT_URL):gsub("/+$", ""))
end

function seerr.enabled()
    return client.settings.seerrUrl ~= false and client.settings.token ~= nil
end

function seerr.user() return user end

local function sessionCookie(rawHeaders)
    for line in (rawHeaders or ""):gmatch("[^\r\n]+") do
        local v = line:match("^[Ss]et%-[Cc]ookie:%s*(connect%.sid=[^;]+)")
        if v then return v end
    end
end

local function login(callback)
    if loginWaiters then loginWaiters[#loginWaiters + 1] = callback; return end
    loginWaiters = { callback }
    http.json({
        method = "POST", url = seerr.baseUrl() .. "/api/v1/auth/plex", timeout = 20,
        headers = { ["Content-Type"] = "application/json" },
        body = json.encode({ authToken = client.settings.token }),
    }, function(data, err, res)
        local ok
        if data and res then
            cookie = sessionCookie(res.headers)
            user = data
            ok = cookie ~= nil
            if not ok then err = "no session cookie" end
        elseif res and (res.status == 401 or res.status == 403) then
            err = "your Plex account isn't allowed to use " .. seerr.baseUrl()
        end
        local waiters = loginWaiters
        loginWaiters = nil
        for _, cb in ipairs(waiters) do cb(ok, err) end
    end)
end

-- JSON call, signing in first (and once more if the session has expired).
local function call(method, path, params, body, callback, retried)
    if not cookie then
        return login(function(ok, err)
            if not ok then return callback(nil, err) end
            call(method, path, params, body, callback, true)
        end)
    end
    local headers = { Cookie = cookie }
    if body then headers["Content-Type"] = "application/json" end
    http.json({
        method = method, timeout = 20, headers = headers,
        url = http.withQuery(seerr.baseUrl() .. "/api/v1" .. path, params),
        body = body and json.encode(body) or nil,
    }, function(data, err, res)
        if res and res.status == 401 and not retried then
            cookie = nil
            return call(method, path, params, body, callback, true)
        end
        if not data and res and res.body then
            -- Seerr explains refusals (quota, already requested...) in { message }
            local ok, e = pcall(json.decode, res.body)
            if ok and type(e) == "table" and e.message then err = e.message end
        end
        callback(data, err, res)
    end)
end

function seerr.imageUrl(path, size)
    if not path or path == "" or path == json.null then return nil end
    return TMDB_IMAGES .. (size or "w342") .. path
end

-- A Seerr result shaped like a Plex item, so cards and helpers can draw it.
local function toItem(r)
    local date = r.releaseDate or r.firstAirDate
    local info = r.mediaInfo ~= json.null and r.mediaInfo or nil
    return {
        seerr = true,
        type = r.mediaType == "tv" and "show" or "movie",
        mediaType = r.mediaType, tmdbId = r.id,
        ratingKey = "seerr:" .. r.mediaType .. ":" .. tostring(r.id),
        title = r.title or r.name or "?",
        year = type(date) == "string" and tonumber(date:sub(1, 4)) or nil,
        summary = r.overview ~= json.null and r.overview or nil,
        thumb = seerr.imageUrl(r.posterPath, "w342"),       -- full URLs; W.itemImage loads them as is
        art = seerr.imageUrl(r.backdropPath, "w1280"),
        status = info and tonumber(info.status) or nil,
    }
end
seerr.toItem = toItem

-- GET /search: films and shows only (people are skipped). callback(items) or nil, err.
function seerr.search(query, callback)
    return call("GET", "/search", { query = query, page = 1, language = "en" }, nil, function(data, err)
        if not data then return callback(nil, err) end
        local items = {}
        for _, r in ipairs(data.results or {}) do
            if r.mediaType == "movie" or r.mediaType == "tv" then items[#items + 1] = toItem(r) end
        end
        callback(items)
    end)
end

-- GET /movie/{id} or /tv/{id}: full details including seasons and request state.
function seerr.details(item, callback)
    return call("GET", "/" .. item.mediaType .. "/" .. item.tmdbId, { language = "en" }, nil, callback)
end

-- Season numbers of a show that nobody has requested yet and that aren't on the server.
function seerr.missingSeasons(details)
    local taken = {}
    local info = details.mediaInfo ~= json.null and details.mediaInfo or nil
    if info then
        for _, s in ipairs(info.seasons or {}) do
            if (tonumber(s.status) or 1) > seerr.UNKNOWN and tonumber(s.status) ~= seerr.DELETED then
                taken[tonumber(s.seasonNumber)] = true
            end
        end
        for _, req in ipairs(info.requests or {}) do
            if tonumber(req.status) ~= REQUEST_DECLINED then
                for _, s in ipairs(req.seasons or {}) do taken[tonumber(s.seasonNumber)] = true end
            end
        end
    end
    local missing = {}
    for _, s in ipairs(details.seasons or {}) do
        local n = tonumber(s.seasonNumber)
        if n and n > 0 and not taken[n] then missing[#missing + 1] = n end   -- specials aren't requestable here
    end
    return missing
end

-- POST /request. seasons: list of season numbers for a show. callback(request) or nil, err.
function seerr.request(item, seasons, callback)
    local body = { mediaType = item.mediaType, mediaId = item.tmdbId }
    if item.mediaType == "tv" then body.seasons = seasons end
    return call("POST", "/request", nil, body, callback)
end

-- Does the signed-in user's request get approved automatically?
function seerr.autoApproved(mediaType)
    local p = tonumber(user and user.permissions) or 0
    local function has(bit) return math.floor(p / bit) % 2 == 1 end
    if has(2) or has(128) then return true end                -- admin, auto-approve
    return has(mediaType == "tv" and 512 or 256)
end

return seerr
