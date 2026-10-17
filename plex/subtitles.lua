-- Subtitles for the player.
--
-- Two ways to show a track, depending on where it lives:
--   * sidecar (a separate file next to the video, Stream.key is set): fetched
--     as SRT from /library/streams/{id}?format=srt and drawn by the player.
--   * embedded in the video file: the server won't hand those out on their
--     own, and Windows' MKV reader doesn't expose them, so the server burns
--     the track into a converted stream (playback.plan with burnSubtitle).
-- The chosen track is saved on the server (PUT /library/parts/{id}), like
-- Plex's own apps do, so it's also the default next time.

local http = require("lib.http")
local client = require("plex.client")

local subs = {}

local IMAGE_CODECS = { pgs = true, hdmv_pgs_subtitle = true, vobsub = true, dvd_subtitle = true,
                       dvb_subtitle = true, dvbsub = true }

-- Subtitle tracks of an item (full metadata): { id, label, codec, sidecar, forced, selected, key }
function subs.streams(item)
    local part = item.Media and item.Media[1] and item.Media[1].Part and item.Media[1].Part[1]
    local out = {}
    for _, st in ipairs(part and part.Stream or {}) do
        if tonumber(st.streamType) == 3 then
            local codec = (st.codec or "?"):lower()
            out[#out + 1] = {
                id = st.id, codec = codec, key = st.key,
                sidecar = st.key ~= nil and not IMAGE_CODECS[codec],
                image = IMAGE_CODECS[codec] == true,
                forced = st.forced == true or st.forced == 1 or st.forced == "1",
                selected = st.selected == true or st.selected == 1 or st.selected == "1",
                label = st.extendedDisplayTitle or st.displayTitle or st.language or ("Track " .. tostring(st.id)),
                title = st.title,
            }
        end
    end
    return out, part and part.id
end

-- Remember the choice on the server (stream = nil for off).
function subs.select(server, partId, stream)
    if not partId then return end
    return http.request({
        method = "PUT", headers = client.headers(server.accessToken), timeout = 15,
        url = http.withQuery(server:baseUrl() .. "/library/parts/" .. partId,
            { subtitleStreamID = stream and stream.id or 0, allParts = 1 }),
    }, function(res, err)
        if not res or res.status >= 300 then print("[subs] couldn't save the choice: " .. tostring(err or res.status)) end
    end)
end

---------------------------------------------------------------------------
-- SRT

local function seconds(h, m, s, ms)
    return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) + tonumber(ms) / (10 ^ #ms)
end

-- Markup subtitles carry that we don't style: <i>, <font ...>, {\an8}, ASS \N breaks.
local function clean(text)
    text = text:gsub("\\[Nn]", "\n"):gsub("\\h", " ")
    text = text:gsub("%b{}", ""):gsub("</?%a[^>]*>", "")
    text = text:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&nbsp;", " ")
    text = text:gsub("[ \t]+\n", "\n"):gsub("\n[ \t]+", "\n"):gsub("^%s+", ""):gsub("%s+$", "")
    return text
end

-- Cues sorted by start time: { start, stop, text }.
function subs.parseSrt(data)
    data = data:gsub("^\239\187\191", ""):gsub("\r\n?", "\n")   -- BOM, Windows/Mac line ends
    local cues = {}
    for block in (data .. "\n\n"):gmatch("(.-)\n%s*\n") do
        local h1, m1, s1, ms1, h2, m2, s2, ms2, rest = block:match(
            "(%d+):(%d+):(%d+)[,.](%d+)%s*%-%->%s*(%d+):(%d+):(%d+)[,.](%d+)[^\n]*\n?(.*)")
        if h1 then
            local text = clean(rest)
            if text ~= "" then
                cues[#cues + 1] = { start = seconds(h1, m1, s1, ms1), stop = seconds(h2, m2, s2, ms2), text = text }
            end
        end
    end
    table.sort(cues, function(a, b) return a.start < b.start end)
    return cues
end

-- Fetch a sidecar track as SRT. callback(cues) or nil, err.
function subs.load(server, stream, callback)
    if not stream.key then return callback(nil, "not a separate subtitle file") end
    local url = http.withQuery(server:baseUrl() .. stream.key, {
        format = "srt", encoding = "utf-8",
        ["X-Plex-Token"] = server.accessToken or client.settings.token,
    })
    return http.request({ url = url, timeout = 30, headers = client.headers(server.accessToken) }, function(res, err)
        if not res then return callback(nil, err) end
        if res.status ~= 200 then return callback(nil, "HTTP " .. res.status) end
        local cues = subs.parseSrt(res.body or "")
        if #cues == 0 then return callback(nil, "the subtitle file was empty or not SRT") end
        callback(cues)
    end)
end

-- Text showing at time t (cues may overlap; joined top to bottom), using a
-- remembered index so normal playback is a step, not a search.
function subs.at(cues, t, hint)
    local n = #cues
    if n == 0 then return nil, 1 end
    local i = math.max(1, math.min(hint or 1, n))
    if cues[i].start > t then
        -- jumped back: binary search for the last cue starting at or before t
        local lo, hi = 1, n
        while lo < hi do
            local mid = math.floor((lo + hi + 1) / 2)
            if cues[mid].start <= t then lo = mid else hi = mid - 1 end
        end
        i = lo
    else
        while i < n and cues[i + 1].start <= t do i = i + 1 end
    end
    local lines = {}
    for j = math.max(1, i - 3), i do       -- a few back for long cues still showing
        local c = cues[j]
        if c.start <= t and t < c.stop then lines[#lines + 1] = c.text end
    end
    return #lines > 0 and table.concat(lines, "\n") or nil, i
end

return subs
