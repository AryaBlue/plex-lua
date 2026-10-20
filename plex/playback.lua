-- Decide how to play an item: direct play the file when Windows can decode it,
-- otherwise ask the server to convert it (universal transcoder, progressive
-- HTTP MKV). The client profile tells the server's decision engine what
-- Media Foundation on this PC can decode.
-- Quality: as in Plex's apps, one choice for streaming at home (the server's
-- address is on this network) and one for away (internet or relay). Original
-- plays the file as it is when it can; a limit makes the server convert any
-- file above it to that bitrate and size.

local http = require("lib.http")
local client = require("plex.client")
local api = require("plex.api")

local playback = {}

-- Filled by playback.setCapabilities() from NativeVideo's decoder probe.
local caps = {
    video = { h264 = true },
    audio = { aac = true, mp3 = true, ac3 = true, eac3 = true, flac = true, alac = true, opus = true, vorbis = true, pcm = true },
    containers = { "mp4", "mkv", "mov", "m4v", "webm", "avi", "ts" },
}

-- kbps = 0: Original. Labels as in Plex's quality menu.
playback.QUALITIES = {
    { kbps = 0, label = "Original" },
    { kbps = 20000, label = "20 Mbps 1080p", resolution = "1920x1080" },
    { kbps = 12000, label = "12 Mbps 1080p", resolution = "1920x1080" },
    { kbps = 8000, label = "8 Mbps 1080p", resolution = "1920x1080" },
    { kbps = 4000, label = "4 Mbps 720p", resolution = "1280x720" },
    { kbps = 2000, label = "2 Mbps 720p", resolution = "1280x720" },
    { kbps = 1500, label = "1.5 Mbps 480p", resolution = "720x480" },
}

function playback.qualityOf(kbps)
    for _, q in ipairs(playback.QUALITIES) do
        if q.kbps == tonumber(kbps) then return q end
    end
    return playback.QUALITIES[1]
end

-- Whether the server is reached over this network (home) or not (away).
function playback.isHome(server)
    return server.active ~= nil and server.active.private and not server.active.relay
end

function playback.settingKey(server)
    return playback.isHome(server) and "qualityHome" or "qualityAway"
end

-- The quality to use for `server`'s current connection.
function playback.quality(server)
    return playback.qualityOf(client.settings[playback.settingKey(server)])
end

-- audio.opusSurround: Opus with more than two channels decodes (libopus found)
function playback.setCapabilities(videoCodecs, audio)
    caps.video = {}
    for _, c in ipairs(videoCodecs) do caps.video[c] = true end
    caps.video.h264 = true
    caps.opusSurround = audio and audio.opusSurround or false
end

function playback.canDecodeVideo(codec) return caps.video[codec or ""] == true end

-- Unknown codec: assume yes (the open reports it if not). DTS ("dca") and TrueHD aren't decodable by Windows.
-- Its Opus decoder only takes mono and stereo: surround Opus needs libopus (see setCapabilities).
function playback.canDecodeAudio(codec, channels)
    if codec == "opus" and channels and channels > 2 and not caps.opusSurround then return false end
    return codec == nil or caps.audio[codec] == true
end

local function keys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out)
    return table.concat(out, ",")
end

-- X-Plex-Client-Profile-Extra: what we can direct play, and what to convert to otherwise.
function playback.profileExtra()
    local audio = keys(caps.audio)
    local extra = {
        ("add-direct-play-profile(type=videoProfile&container=%s&videoCodec=%s&audioCodec=%s)")
            :format(table.concat(caps.containers, ","), keys(caps.video), audio),
        ("add-transcode-target(type=videoProfile&context=streaming&protocol=http&container=mkv&videoCodec=h264&audioCodec=%s)")
            :format("aac,ac3,eac3,mp3"),
    }
    if not caps.opusSurround then
        extra[#extra + 1] = "add-limitation(scope=videoAudioCodec&scopeName=opus&type=upperBound&name=audio.channels&value=2)"
    end
    return table.concat(extra, "+")
end

local function transcodeParams(item, sessionId, offset, opts)
    return {
        path = "/library/metadata/" .. item.ratingKey,
        mediaIndex = opts.mediaIndex or 0, partIndex = 0,
        protocol = "http",
        directPlay = 0, directStream = 1, directStreamAudio = 1,
        videoResolution = opts.quality and opts.quality.resolution or "1920x1080",
        maxVideoBitrate = opts.quality and opts.quality.kbps > 0 and opts.quality.kbps or 20000,
        offset = math.floor(offset or 0),
        session = sessionId, transcodeSessionId = sessionId,
        location = opts.location or "lan",
        fastSeek = 1, copyts = 1,
        -- the player draws separate subtitle files itself; burn only what it asks for
        subtitles = opts.burnSubtitle and "burn" or "none",
        subtitleStreamID = opts.burnSubtitle,
        advancedSubtitles = opts.burnSubtitle and "burn" or nil,
        ["X-Plex-Client-Identifier"] = client.settings.clientIdentifier,
        ["X-Plex-Session-Identifier"] = sessionId,
        ["X-Plex-Product"] = client.headers()["X-Plex-Product"],
        ["X-Plex-Platform"] = client.headers()["X-Plex-Platform"],
        ["X-Plex-Client-Profile-Extra"] = playback.profileExtra(),
    }
end

-- Work out how to play `item` (full metadata). callback(plan | nil, err)
-- opts: offset, forceTranscode, burnSubtitle (stream id: convert with that track drawn in),
--   quality (a playback.QUALITIES entry; default Original)
-- plan = { url, mode = "direct" | "transcode", offsetBase, duration, container, videoCodec, audioCodec, describe }
function playback.plan(server, item, sessionId, opts, callback)
    opts = opts or {}
    local media = item.Media and item.Media[1]
    if not media then return callback(nil, "This item has no media.") end
    local dp = api.directPlay(server, item)
    -- a quality limit below the file's bitrate needs the server to convert it
    local q = opts.quality
    local overLimit = q and q.kbps > 0 and (tonumber(media.bitrate) or math.huge) > q.kbps
    if dp and not opts.forceTranscode and not overLimit and not opts.burnSubtitle and playback.canDecodeVideo(media.videoCodec) then
        dp.mode = "direct"
        dp.offsetBase = 0
        dp.describe = "Direct play"
        return callback(dp)
    end

    -- Ask the server's decision engine, then stream the converted file.
    local params = transcodeParams(item, sessionId, opts.offset, opts)
    params.location = server.active and (server.active.private and "lan" or "wan") or "wan"
    api.get(server, "/video/:/transcode/universal/decision", params, function(mc, err)
        if not mc then return callback(nil, "Server conversion check failed: " .. tostring(err)) end
        local code = tonumber(mc.generalDecisionCode)
        if code and code >= 2000 then
            return callback(nil, mc.generalDecisionText or ("Server can't play this (code " .. code .. ")"))
        end
        local m = mc.Metadata and mc.Metadata[1] and mc.Metadata[1].Media and mc.Metadata[1].Media[1] or {}
        local videoDecision, audioDecision = "?", "?"
        for _, st in ipairs(m.Part and m.Part[1] and m.Part[1].Stream or {}) do
            if st.streamType == 1 then videoDecision = st.decision or "?" end
            if st.streamType == 2 then audioDecision = st.decision or "?" end
        end
        local url = http.withQuery(server:baseUrl() .. "/video/:/transcode/universal/start.mkv", params)
        url = url .. "&X-Plex-Token=" .. http.encode(server.accessToken or client.settings.token)
        callback({
            url = url, mode = "transcode", offsetBase = params.offset,
            duration = (tonumber(item.duration) or 0) / 1000,
            container = "mkv", videoCodec = m.videoCodec or "h264", audioCodec = m.audioCodec,
            sourceVideoCodec = media.videoCodec,
            describe = ("Converting %s to %s%s (video %s, audio %s)%s"):format(
                (media.videoCodec or "?"):upper(), (m.videoCodec or "h264"):upper(),
                q and q.kbps > 0 and " at " .. q.label or "", videoDecision, audioDecision,
                opts.burnSubtitle and ", subtitles burned in" or ""),
            burnSubtitle = opts.burnSubtitle,
        })
    end, { timeout = 30 })
end

return playback
