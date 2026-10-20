-- "For You": a library ordered by how well each title matches what you've
-- watched. Content based, worked out on this machine from the server's own
-- listings (no outside service):
--
--   1. Every film and show on the server is read once (GET
--      /library/sections/{id}/all, 1000 at a time). The listing carries the
--      watch state of the signed-in user and a few tags per title: genres,
--      director, writer, the top-billed cast, country, studio, plus year and
--      content rating.
--   2. Each title you've watched adds its tags to a taste profile, weighted by
--      how much you watched it: a film once = 1, rewatches a bit more; a show
--      by how many episodes (10, or the whole show if shorter, = 1); a star
--      rating scales it (2 stars or less counts against); and a title watched
--      years ago counts less than last week's. Watches in the other library
--      (shows for films, films for shows) count half.
--   3. A tag's worth is scaled by how rare it is in the libraries (IDF), so a
--      shared director or actor means more than "Comedy", and a weight per
--      kind of tag (directors highest, content rating lowest).
--   4. A title scores the sum of its tags' worth, divided by sqrt(tag count) so
--      titles with long cast lists don't win by volume. 80% of the rank is
--      that match and 20% the audience rating. Titles you've already watched
--      or started go last.
--   5. For the top titles, the watched title sharing the most people or
--      studio (weighted as above) becomes the reason shown under the poster,
--      "Because you watched X"; with none shared, "Because you like <genre>".

local api = require("plex.api")

local recommend = {}

local KIND_WEIGHT = { g = 1.0, d = 1.3, w = 0.6, a = 0.7, c = 0.35, s = 0.5, y = 0.45, r = 0.3 }
local TAGS = { { "Genre", "g" }, { "Director", "d" }, { "Writer", "w" }, { "Role", "a" }, { "Country", "c" } }
local REASONS = 300          -- titles given a "Because you watched"
local CACHE_FOR = 600        -- seconds the libraries are kept

local cache = nil            -- { server, time, sections = { [key] = items }, pending = { callbacks } }

local function features(item)
    if item._features then return item._features end
    local set = {}
    for _, t in ipairs(TAGS) do
        for _, tag in ipairs(item[t[1]] or {}) do
            if tag.tag then set[t[2] .. ":" .. tag.tag] = true end
        end
    end
    if item.studio then set["s:" .. item.studio] = true end
    local year = tonumber(item.year)
    if year then set["y:" .. math.floor(year / 10) * 10] = true end
    if item.contentRating then set["r:" .. item.contentRating] = true end
    item._features = set
    return set
end

-- How much watching `item` says about your taste (0 = not watched).
function recommend.engagement(item, now)
    local w, rewatch
    if item.type == "show" then
        local eps, n = tonumber(item.viewedLeafCount) or 0, math.max(1, tonumber(item.leafCount) or 1)
        if eps == 0 then return 0 end
        w = 0.2 + 0.8 * math.min(1, eps / math.min(10, n))
        rewatch = (tonumber(item.viewCount) or eps) / eps
    else
        local vc = tonumber(item.viewCount) or 0
        if vc == 0 then return (tonumber(item.viewOffset) or 0) > 0 and 0.25 or 0 end
        w, rewatch = 1, vc
    end
    w = w * (1 + 0.3 * math.log(math.max(1, rewatch)) / math.log(2))
    local rating = tonumber(item.userRating)
    if rating then w = w * (rating - 4) / 4 end
    local seen = tonumber(item.lastViewedAt)
    if seen then
        local days = math.max(0, (now - seen) / 86400)
        w = w * (0.4 + 0.6 * 0.5 ^ (days / 365))
    end
    return w
end

-- Every item of one section. callback(items) or callback(nil, err).
local function fetchAll(server, key, callback, genre)
    local items = {}
    local function page()
        api.get(server, "/library/sections/" .. key .. "/all", { genre = genre }, function(mc, err)
            if not mc then return callback(nil, err) end
            for _, it in ipairs(mc.Metadata or {}) do items[#items + 1] = it end
            local total = tonumber(mc.totalSize) or #items
            if #items >= total or #(mc.Metadata or {}) == 0 then return callback(items) end
            page()
        end, { start = #items, size = 1000, timeout = 60 })
    end
    page()
end
recommend.fetchAll = fetchAll

-- All film and show libraries: callback({ [sectionKey] = items }) or nil, err.
local function libraries(server, callback)
    local now = love.timer.getTime()
    if cache and cache.server == server and cache.sections and now - cache.time < CACHE_FOR then
        return callback(cache.sections)
    end
    if cache and cache.server == server and cache.pending then
        cache.pending[#cache.pending + 1] = callback
        return
    end
    cache = { server = server, pending = { callback } }
    local mine = cache
    local function finish(sections, err)
        if cache ~= mine then return end
        local waiting = mine.pending
        mine.pending = nil
        if sections then mine.sections, mine.time = sections, love.timer.getTime() else cache = nil end
        for _, cb in ipairs(waiting) do cb(sections, err) end
    end
    api.sections(server, function(list, err)
        if not list then return finish(nil, err) end
        local keys = {}
        for _, s in ipairs(list) do
            if s.type == "movie" or s.type == "show" then
                keys[#keys + 1] = { key = tostring(s.key), type = s.type, title = s.title, order = #keys + 1 }
            end
        end
        local sections, left, failed = {}, #keys, nil
        if left == 0 then return finish(sections) end
        for _, s in ipairs(keys) do
            fetchAll(server, s.key, function(items, ferr)
                if items then
                    sections[s.key] = { type = s.type, title = s.title, order = s.order, items = items }
                else failed = ferr end
                left = left - 1
                if left == 0 then
                    if failed and not next(sections) then finish(nil, failed) else finish(sections) end
                end
            end)
        end
    end)
end

-- Forget the libraries (after marking something watched, so the next "For
-- You" sees it).
function recommend.invalidate()
    if cache and not cache.pending then cache = nil end
end

-- Rank `section`'s titles. callback(items, info) where info = { watched =
-- titles your taste was taken from }, or callback(nil, err).
-- genre: optional genre id, to rank only that genre's titles.
function recommend.forSection(server, section, callback, genre)
    libraries(server, function(sections, err)
        if not sections then return callback(nil, err) end
        local mine = sections[tostring(section.key)]
        if not mine then return callback(nil, "This library can't be sorted For You") end
        local function rank(onlyKeys)
            callback(recommend.rank(sections, tostring(section.key), onlyKeys, os.time()))
        end
        if not genre then return rank(nil) end
        -- the listing's genre tags are cut short, so ask the server which titles are in the genre
        fetchAll(server, section.key, function(items, ferr)
            if not items then return callback(nil, ferr) end
            local keys = {}
            for _, it in ipairs(items) do keys[tostring(it.ratingKey)] = true end
            rank(keys)
        end, genre)
    end)
end

-- Home's rows: the top `count` unwatched picks of each film and TV library,
-- in the server's library order. callback({ { title, items } }) or nil, err.
function recommend.home(server, count, callback)
    libraries(server, function(sections, err)
        if not sections then return callback(nil, err) end
        local keys = {}
        for key in pairs(sections) do keys[#keys + 1] = key end
        table.sort(keys, function(a, b) return sections[a].order < sections[b].order end)
        local rows = {}
        for _, key in ipairs(keys) do
            local ranked, info = recommend.rank(sections, key, nil, os.time())
            local items = {}
            for _, it in ipairs(ranked) do
                if it._watched or #items >= count or info.watched == 0 then break end
                items[#items + 1] = it
            end
            if #items > 0 then
                rows[#rows + 1] = { title = "Recommended " .. (sections[key].title or ""), items = items }
            end
        end
        callback(rows)
    end)
end

-- sections: { [key] = { type, items } }; target: the key to rank.
-- onlyKeys: optional set of ratingKeys to keep. Pure; returns items, info.
function recommend.rank(sections, target, onlyKeys, now)
    local targetType = sections[target].type

    -- document frequencies over everything, and the taste profile
    local df, n = {}, 0
    local profile, total = {}, 0
    local watched = {}
    for key, sec in pairs(sections) do
        local scale = key == target and 1 or (sec.type == targetType and 0.8 or 0.5)
        for _, it in ipairs(sec.items) do
            n = n + 1
            local f = features(it)
            for tag in pairs(f) do df[tag] = (df[tag] or 0) + 1 end
            local e = recommend.engagement(it, now)
            it._watched = e ~= 0
            if e ~= 0 then
                e = e * scale
                watched[#watched + 1] = { item = it, weight = e }
                total = total + math.abs(e)
                for tag in pairs(f) do profile[tag] = (profile[tag] or 0) + e end
            end
        end
    end
    local worth = {}         -- tag -> kind weight * idf
    for tag, c in pairs(df) do
        worth[tag] = KIND_WEIGHT[tag:sub(1, 1)] * math.log(n / (1 + c))
    end

    local ranked, best = {}, 0
    for _, it in ipairs(sections[target].items) do
        it.reason = nil
        if not onlyKeys or onlyKeys[tostring(it.ratingKey)] then
            local s, count = 0, 0
            if total > 0 then
                for tag in pairs(features(it)) do
                    count = count + 1
                    local p = profile[tag]
                    if p then s = s + p / total * worth[tag] end
                end
                if count > 0 then s = s / math.sqrt(count) end
            end
            it._match = s
            if not it._watched and s > best then best = s end
            ranked[#ranked + 1] = it
        end
    end
    for _, it in ipairs(ranked) do
        local q = (tonumber(it.audienceRating) or tonumber(it.rating) or 6) / 10
        it._score = 0.8 * (best > 0 and it._match / best or 0) + 0.2 * q
    end
    table.sort(ranked, function(a, b)
        if a._watched ~= b._watched then return not a._watched end
        if a._score ~= b._score then return a._score > b._score end
        return (a.titleSort or a.title or "") < (b.titleSort or b.title or "")
    end)

    -- reasons for the top titles: the watched title sharing the most people
    -- (director, writer, cast) or studio; failing that, your favourite of its genres
    if #watched > 0 then
        for i = 1, math.min(REASONS, #ranked) do
            local it = ranked[i]
            if it._watched then break end
            local f = features(it)
            local top, topV = nil, 0
            for _, w in ipairs(watched) do
                if w.weight > 0 then
                    local v = 0
                    for tag in pairs(features(w.item)) do
                        local kind = tag:sub(1, 1)
                        if f[tag] and (kind == "d" or kind == "w" or kind == "a" or kind == "s") then v = v + worth[tag] end
                    end
                    v = v * w.weight * (w.item.type == it.type and 1 or 0.5)
                    if v > topV then top, topV = w.item, v end
                end
            end
            if top then
                it.reason = "Because you watched " .. (top.title or "?")
            else
                local genre, gv = nil, 0
                for tag in pairs(f) do
                    if tag:sub(1, 2) == "g:" and (profile[tag] or 0) > gv then genre, gv = tag:sub(3), profile[tag] end
                end
                it.reason = genre and ("Because you like " .. genre) or nil
            end
        end
    end
    return ranked, { watched = #watched }
end

return recommend
