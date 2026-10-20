-- Subtitles for the player.
--
-- Two ways to show a track, depending on where it lives:
--   * sidecar (a separate file next to the video, Stream.key is set): fetched
--     as SRT from /library/streams/{id}?format=srt and drawn by the player.
--   * embedded text track (ASS, SRT... inside the MKV): Windows' MKV reader
--     doesn't expose them, so the server extracts just that track, as Plex Web
--     does when it direct-plays with soft subtitles
--     (/subtitles/:/transcode/universal/start, subtitles=sidecar); the video
--     still plays directly and the player draws the text.
--   * embedded picture track (PGS, VobSub), or text that couldn't be
--     extracted: the server burns it into a converted stream (playback.plan
--     with burnSubtitle).
-- The chosen track is saved on the server (PUT /library/parts/{id}), like
-- Plex's own apps do, so it's also the default next time.

local http = require("lib.http")
local client = require("plex.client")

local subs = {}

local TEXT_CODECS = { ass = true, ssa = true, srt = true, subrip = true, webvtt = true, vtt = true,
                      mov_text = true, text = true, tx3g = true }
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
                extract = st.key == nil and TEXT_CODECS[codec] == true,
                forced = st.forced == true or st.forced == 1 or st.forced == "1",
                selected = st.selected == true or st.selected == 1 or st.selected == "1",
                label = st.extendedDisplayTitle or st.displayTitle or st.language or ("Track " .. tostring(st.id)),
                title = st.title,
            }
        end
    end
    return out, part and part.id
end

-- Audio tracks of an item (full metadata), in file order:
-- { id, label, codec, channels, selected, ordinal = 1 for the file's first audio track... }
-- The player picks a track by ordinal when playing the file directly.
function subs.audioStreams(item)
    local part = item.Media and item.Media[1] and item.Media[1].Part and item.Media[1].Part[1]
    local list = {}
    for _, st in ipairs(part and part.Stream or {}) do
        if tonumber(st.streamType) == 2 then list[#list + 1] = st end
    end
    table.sort(list, function(a, b) return (tonumber(a.index) or 0) < (tonumber(b.index) or 0) end)
    local out = {}
    for i, st in ipairs(list) do
        out[i] = {
            id = st.id, ordinal = i, codec = st.codec and st.codec:lower() or nil, channels = tonumber(st.channels),
            selected = st.selected == true or st.selected == 1 or st.selected == "1",
            label = st.extendedDisplayTitle or st.displayTitle or st.language or ("Track " .. i),
        }
    end
    return out
end

-- Remember the audio choice on the server; converted streams use it too.
-- callback(ok) once the server has it.
function subs.selectAudio(server, partId, stream, callback)
    if not partId then return callback and callback(false) end
    return http.request({
        method = "PUT", headers = client.headers(server.accessToken), timeout = 15,
        url = http.withQuery(server:baseUrl() .. "/library/parts/" .. partId,
            { audioStreamID = stream.id, allParts = 1 }),
    }, function(res, err)
        local ok = res and res.status < 300
        if not ok then print("[audio] couldn't save the choice: " .. tostring(err or (res and res.status))) end
        if callback then callback(ok) end
    end)
end

-- Remember the choice on the server (stream = nil for off).
function subs.select(server, partId, stream, callback)
    if not partId then return callback and callback(false) end
    return http.request({
        method = "PUT", headers = client.headers(server.accessToken), timeout = 15,
        url = http.withQuery(server:baseUrl() .. "/library/parts/" .. partId,
            { subtitleStreamID = stream and stream.id or 0, allParts = 1 }),
    }, function(res, err)
        local ok = res and res.status < 300
        if not ok then print("[subs] couldn't save the choice: " .. tostring(err or (res and res.status))) end
        if callback then callback(ok) end
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

-- Cues sorted by start time: { start, stop, text }. Also reads WebVTT.
function subs.parseSrt(data)
    data = data:gsub("^\239\187\191", ""):gsub("\r\n?", "\n")   -- BOM, Windows/Mac line ends
    local cues = {}
    for block in (data .. "\n\n"):gmatch("(.-)\n%s*\n") do
        local h1, m1, s1, ms1, h2, m2, s2, ms2, rest = block:match(
            "(%d+):(%d+):(%d+)[,.](%d+)%s*%-%->%s*(%d+):(%d+):(%d+)[,.](%d+)[^\n]*\n?(.*)")
        if not h1 then
            -- WebVTT may leave out the hours: 01:02.500 --> 01:04.000
            m1, s1, ms1, m2, s2, ms2, rest = block:match(
                "(%d+):(%d+)%.(%d+)%s*%-%->%s*(%d+):(%d+)%.(%d+)[^\n]*\n?(.*)")
            if m1 then h1, h2 = "0", "0" end
        end
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

-- ASS/SSA: the Dialogue lines of [Events], in the order its Format line gives.
function subs.parseAss(data)
    data = data:gsub("^\239\187\191", ""):gsub("\r\n?", "\n")
    local fields = { "Layer", "Start", "End", "Style", "Name", "MarginL", "MarginR", "MarginV", "Effect", "Text" }
    local cues = {}
    for line in data:gmatch("[^\n]+") do
        local format = line:match("^Format:%s*(.*)")
        if format and format:find("Text") then
            fields = {}
            for f in format:gmatch("[^,]+") do fields[#fields + 1] = f:match("^%s*(.-)%s*$") end
        end
        local body = line:match("^Dialogue:%s*(.*)")
        if body then
            local values, rest = {}, body
            for i = 1, #fields - 1 do            -- the last field (Text) may contain commas
                local v, r = rest:match("^([^,]*),(.*)$")
                if not v then break end
                values[fields[i]], rest = v, r
            end
            values[fields[#fields]] = rest
            local function t(v)
                local h, m, sec, cs = (v or ""):match("(%d+):(%d+):(%d+)[.:](%d+)")
                return h and seconds(h, m, sec, cs)
            end
            local start, stop = t(values.Start), t(values.End)
            local text = clean(values.Text or "")
            if start and stop and text ~= "" then cues[#cues + 1] = { start = start, stop = stop, text = text } end
        end
    end
    table.sort(cues, function(a, b) return a.start < b.start end)
    return cues
end

-- Whatever format a subtitle came back in.
function subs.parse(data)
    if data:find("[Events]", 1, true) or data:find("\nDialogue:") then return subs.parseAss(data) end
    return subs.parseSrt(data)
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

-- Have the server pull an embedded text track out of the video file (the
-- request Plex Web makes for soft subtitles when it direct-plays).
-- callback(cues) or nil, err.
function subs.loadEmbedded(server, item, stream, sessionId, callback)
    local playback = require("plex.playback")
    local h = client.headers(server.accessToken)
    local url = http.withQuery(server:baseUrl() .. "/subtitles/:/transcode/universal/start", {
        path = "/library/metadata/" .. item.ratingKey,
        mediaIndex = 0, partIndex = 0, protocol = "http",
        directPlay = 1, directStream = 1, directStreamAudio = 1,
        subtitles = "sidecar", advancedSubtitles = "text", subtitleStreamID = stream.id,
        session = sessionId, ["X-Plex-Session-Identifier"] = sessionId,
        ["X-Plex-Client-Identifier"] = h["X-Plex-Client-Identifier"],
        ["X-Plex-Product"] = h["X-Plex-Product"], ["X-Plex-Platform"] = h["X-Plex-Platform"],
        ["X-Plex-Client-Profile-Extra"] = playback.profileExtra(),
        ["X-Plex-Token"] = server.accessToken or client.settings.token,
    })
    return http.request({ url = url, timeout = 60, headers = h }, function(res, err)
        if not res then return callback(nil, err) end
        if res.status ~= 200 then return callback(nil, "HTTP " .. res.status) end
        local cues = subs.parse(res.body or "")
        if #cues == 0 then
            print("[subs] embedded track came back unreadable: " .. (res.body or ""):sub(1, 200))
            return callback(nil, "the server sent no readable subtitles")
        end
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
