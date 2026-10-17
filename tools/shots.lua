-- lovec E:\PlexLove --shots : drive the UI with scripted inputs and save
-- screenshots to the save directory (shots/*.png). Browsing only, no playback.

local T = {}

local script = {
    { wait = "home" }, { wait = 4 }, { shot = "01-home-hero" },
    { action = "right" }, { wait = 0.6 }, { shot = "02-hero-more-info-focus" },
    { action = "down" }, { wait = 2.5 }, { shot = "03-first-row" },
    { action = "right" }, { action = "right" }, { wait = 2 }, { shot = "04-row-scrolled" },
    { action = "down" }, { wait = 2.5 }, { shot = "05-second-row" },
    { action = "accept" }, { wait = 4 }, { shot = "06-detail" },
    { action = "down" }, { wait = 2.5 }, { shot = "07-detail-next-section" },
    { action = "down" }, { wait = 2.5 }, { shot = "08-detail-lower" },
    { action = "back" }, { wait = 1 },
    { action = "up" }, { action = "up" }, { action = "up" }, { wait = 1 }, { shot = "09-nav-focus" },
    { action = "right" }, { wait = 0.5 }, { action = "accept" }, { wait = 4 }, { shot = "10-library" },
    { action = "down" }, { action = "down" }, { action = "right" }, { wait = 2 }, { shot = "11-library-scrolled" },
    { action = "menu" }, { wait = 4 }, { shot = "12-library-sorted" },
    { quit = true },
}

-- lovec . --shots tv : show page with seasons and episodes
local tvScript = {
    { wait = "home" }, { wait = 2 },
    { action = "up" }, { action = "right" }, { action = "right" }, { action = "right" }, { action = "accept" }, { wait = 4 },
    { shot = "20-tv-library" },
    { action = "right" }, { action = "accept" }, { wait = 5 }, { shot = "21-show-detail" },
    { action = "down" }, { wait = 1 }, { shot = "22-show-seasons-focus" },
    { action = "right" }, { wait = 3 }, { shot = "23-show-season-2" },
    { action = "down" }, { wait = 2.5 }, { shot = "24-show-episodes" },
    { action = "right" }, { action = "right" }, { wait = 2 }, { shot = "25-show-episodes-scrolled" },
    { action = "down" }, { wait = 3 }, { shot = "26-show-related" },
    { quit = true },
}

-- lovec . --shots search : search from the nav tab, typing, on-screen keyboard and mouse.
local searchScript = {
    { wait = "home" }, { wait = 1 },
    { action = "up" }, { action = "up" }, { action = "up" }, { action = "right" }, { action = "accept" }, { wait = 1 },
    { shot = "60-search-empty" },
    { text = "bab" }, { wait = 2.5 }, { shot = "61-search-typed" },
    { action = "accept" }, { wait = 0.8 }, { shot = "62-search-results-focus" },
    { action = "right" }, { action = "down" }, { wait = 1.5 }, { shot = "63-search-results-moved" },
    { action = "back" }, { key = "backspace" }, { key = "backspace" }, { key = "backspace" }, { wait = 0.5 },
    { action = "down" }, { action = "right" }, { action = "accept" }, { action = "right" }, { action = "accept" },
    { wait = 2.5 }, { shot = "64-search-onscreen-keys" },
    { move = { 600, 280 } }, { wait = 1.5 }, { shot = "65-search-mouse-hover" },
    { click = { 600, 280 } }, { wait = 3 }, { shot = "66-search-opened-detail" },
    { action = "back" }, { wait = 0.5 }, { report = "search" },
    { action = "back" }, { key = "backspace" }, { key = "backspace" }, { key = "backspace" },
    { wait = 0.5 }, { shot = "67-search-recent" },
    { quit = true },
}

-- lovec . --shots detail : a show's episode row paged with the mouse arrows, and the back button.
local function episodeRow(fx)
    return function()
        local d, w = app.top(), love.graphics.getWidth()
        local r = d.episodeRow
        if not r then return print("[shots] no episode row") end
        local x, y = fx * w, r.y + r.h / 2
        love.mouse.setPosition(x, y)
        love.mousemoved(x, y, 0, 0, false)
        return x, y
    end
end
local detailScript = {
    { wait = "home" }, { wait = 1 },
    { action = "up" }, { action = "right" }, { action = "right" }, { action = "right" }, { action = "accept" }, { wait = 4 },
    { action = "right" }, { action = "accept" }, { wait = 5 },
    { call = episodeRow(0.5) }, { wait = 1 }, { shot = "70-detail-row-arrows" },
    { call = episodeRow(0.99) }, { call = function() local x, y = love.mouse.getPosition(); love.mousepressed(x, y, 1, false); love.mousereleased(x, y, 1, false) end },
    { wait = 1 }, { shot = "71-detail-paged-right" },
    { call = function() local d = app.top(); print(("[shots] episodes=%d visible=%d first=%d"):format(#d.episodes, d.epVisible, d.epScroll)) end },
    { call = episodeRow(0.01) }, { call = function() local x, y = love.mouse.getPosition(); love.mousepressed(x, y, 1, false); love.mousereleased(x, y, 1, false) end },
    { wait = 1 }, { shot = "72-detail-paged-left" },
    { action = "up" }, { action = "up" }, { action = "up" }, { action = "up" }, { wait = 0.5 }, { shot = "73-detail-back-focus" },
    { move = { 52, 54 } }, { wait = 0.3 }, { shot = "74-detail-back-hover" },
    { click = { 52, 54 } }, { wait = 1 }, { shot = "75-library-after-back" },
    { call = function() print("[shots] top after back: " .. tostring(app.top().section and "library" or "?")) end },
    { quit = true },
}

-- lovec . --shots request : search hits that aren't on the server, and their request page.
-- Never presses Request (that would file a real request).
local requestScript = {
    { wait = "home" }, { wait = 1 },
    { action = "up" }, { action = "up" }, { action = "up" }, { action = "right" }, { action = "accept" }, { wait = 1 },
    { text = "dune" }, { wait = 4 }, { shot = "80-request-search" },
    { call = function()
        local p = app.top()
        for i, r in ipairs(p.rows) do print(("[shots] row %d: %s (%d)%s"):format(i, r.title, #r.items, r.request and " [request]" or "")) end
        if p.requestError then print("[shots] seerr error: " .. p.requestError) end
    end },
    { action = "accept" }, { action = "down" }, { action = "down" }, { action = "down" }, { action = "down" }, { wait = 1.5 },
    { shot = "81-request-row-focus" },
    { call = function()
        local p = app.top()
        print("[shots] zone", p.zone, "row", p.row, "#rows", #p.rows)
        for i, r in ipairs(p.rows) do
            local a = {}
            for c = 1, 3 do a[#a + 1] = ("%.2f"):format(r.anim[c] or 0) end
            print(("[shots]   row %d col %d anim %s  same-anim-as-prev=%s"):format(i, r.col, table.concat(a, ","),
                tostring(i > 1 and p.rows[i - 1].anim == r.anim)))
        end
    end },
    { action = "accept" }, { wait = 3 }, { shot = "82-request-page" },
    { call = function()
        local p = app.top()
        local labels = {}
        for _, b in ipairs(p.buttons or {}) do labels[#labels + 1] = b.label end
        print(("[shots] request page: %s  status=%s  buttons=%s  error=%s"):format(p.item and p.item.title or "?",
            tostring(p.status), table.concat(labels, " | "), tostring(p.error)))
    end },
    { action = "back" }, { wait = 0.5 }, { action = "right" }, { wait = 0.3 }, { action = "accept" }, { wait = 3 },
    { shot = "83-request-page-2" },
    { call = function()
        local p = app.top()
        local labels = {}
        for _, b in ipairs(p.buttons or {}) do labels[#labels + 1] = b.label end
        print(("[shots] request page: %s  status=%s  buttons=%s"):format(p.item and p.item.title or "?",
            tostring(p.status), table.concat(labels, " | ")))
    end },
    { quit = true },
}

-- lovec . --shots hover : moving the pointer card to card must not blank the previous card.
local function hoverCard(col)
    return { call = function()
        local home = app.top()
        local m = home:metrics()
        local row = home.rows[1]
        local cw = row.kind == "wide" and m.wideW or m.posterW
        local x = m.pad + (col - 1) * (cw + m.cardGap) - (row.scrollAnim or 0) + cw / 2
        local y = home:rowY(1, m) - home.scrollY + m.titleH + 40 * m.u
        love.mouse.setPosition(x, y)
        love.mousemoved(x, y, 0, 0, false)
    end }
end
local function rowEdgePoint(rowIndex, side)
    local home = app.top()
    local m = home:metrics()
    local row = home.rows[rowIndex]
    local ch = row.kind == "wide" and m.wideH or m.posterH
    return side > 0 and m.w - 20 * m.u or 20 * m.u, home:rowY(rowIndex, m) - home.scrollY + m.titleH + ch / 2
end
local function rowEdgeHover(rowIndex, side)
    return { call = function()
        local x, y = rowEdgePoint(rowIndex, side)
        love.mouse.setPosition(x, y)
        love.mousemoved(x, y, 0, 0, false)
    end }
end
local function rowEdge(rowIndex, side)
    return { call = function()
        local home = app.top()
        local m = home:metrics()
        local row = home.rows[rowIndex]
        local ch = row.kind == "wide" and m.wideH or m.posterH
        local x = side > 0 and m.w - 20 * m.u or 20 * m.u
        local y = home:rowY(rowIndex, m) - home.scrollY + m.titleH + ch / 2
        love.mousepressed(x, y, 1, false)
        love.mousereleased(x, y, 1, false)
        print(("[shots] row %d (%s): clicked %s arrow, first card now %d of %d (visible %d)"):format(rowIndex, row.title,
            side > 0 and "right" or "left", row.scroll, #row.items, row.visible or -1))
    end }
end
local rowsScript = {
    { wait = "home" }, { wait = 2 }, { wheel = { 0, -3 } }, { wait = 1.5 },
    rowEdgeHover(3, 1), { wait = 0.3 }, rowEdge(3, 1), { wait = 1 }, { shot = "97-home-row-paged-right" },
    rowEdge(3, 1), { wait = 1 },
    rowEdgeHover(3, -1), { wait = 0.3 }, rowEdge(3, -1), { wait = 1 }, { shot = "98-home-row-paged-left" },
    { quit = true },
}

local hoverScript = {
    { wait = "home" }, { wait = 2 }, { wheel = { 0, -3 } }, { wait = 1.5 },
    hoverCard(1), { wait = 1.5 }, hoverCard(2), { wait = 0.06 }, { shot = "96-hover-mid-transition" },
    { call = function()
        local row = app.top().rows[1]
        print(("[shots] anim card1=%.2f card2=%.2f (both drawn while fading)"):format(row.anim[1] or 0, row.anim[2] or 0))
    end },
    { quit = true },
}

-- lovec . --shots controls : the player's control row, back button, volume and
-- double-click fullscreen (same local clip; coordinates are for a 1600x900 window).
local controlsScript = {
    { wait = 0.6 }, { action = "playpause" }, { wait = 0.5 }, { shot = "50-controls-paused" },
    { action = "down" }, { wait = 0.3 }, { shot = "51-kb-controls-focus" },
    { action = "right" }, { action = "right" }, { action = "right" }, { action = "down" }, { action = "down" },
    { wait = 0.3 }, { shot = "52-kb-volume-down" },
    { action = "left" }, { action = "up" }, { action = "up" }, { wait = 0.3 }, { shot = "53-kb-back-focus" },
    { action = "down" },
    { move = { 379, 833 } }, { click = { 379, 833 } }, { wait = 0.3 }, { shot = "54-mouse-volume-30" },
    { wheel = { 0, 2 } }, { wait = 0.2 }, { shot = "55-mouse-wheel-volume" },
    { move = { 1515, 833 } }, { wait = 0.3 }, { shot = "56-mouse-hover-fullscreen" },
    { action = "playpause" }, { wait = 0.3 },   -- double-click while playing, as when watching
    { click = { 800, 400 } }, { click = { 800, 400 } }, { wait = 1.2 }, { shot = "57-double-click-fullscreen" },
    { report = "fullscreen" },
    { call = function() local p = app.top(); print(("[shots] overlay after double-click: %s (counting down = will hide)"):format(tostring(p.overlay))) end },
    { action = "playpause" },   -- pause again so the 3 s clip doesn't run out mid-test
    { click = { 800, 400 } }, { click = { 800, 400 } }, { wait = 1.2 }, { shot = "58-double-click-windowed" },
    { report = "fullscreen" },
    { move = { 60, 66 } }, { wait = 0.3 }, { shot = "59-back-button-hover" },
    { click = { 60, 66 } }, { wait = 0.3 }, { report = "player closed" },
    { quit = true },
}

-- lovec . --shots player : the player on a local test clip (no server stream).
local playerScript = {
    { wait = 1.2 }, { shot = "30-player-overlay" },
    { action = "playpause" }, { wait = 0.5 }, { shot = "31-player-paused" },
    { action = "right" }, { wait = 0.1 }, { shot = "32-player-seek-pending" },
    { wait = 1 }, { shot = "33-player-after-seek" },
    { click = { 300, 793 } }, { shot = "34a-pending-seek-from-click" }, { wait = 0.1 }, { shot = "34-player-mouse-seekbar-click" },
    { click = { 800, 400 } }, { wait = 0.3 }, { shot = "35-player-mouse-click-picture" },
    -- the user's crash: a network read failing mid-stream
    { wait = 0.3 }, { inject = true }, { wait = 0.15 }, { shot = "36-player-reconnecting" },
    { wait = 0.5 }, { shot = "37-player-after-reconnect" },
    { inject = true }, { wait = 0.5 }, { inject = true }, { wait = 0.5 }, { inject = true }, { wait = 0.5 },
    { shot = "38-player-gave-up" },
    { action = "back" }, { wait = 0.3 }, { action = "back" }, { wait = 0.5 },
    { quit = true },
}

-- lovec . --shots subs : the subtitle menu, a separate subtitle file drawn by the
-- player, and switching to a burned-in track (stand-ins: local clip, no server).
local SUBS_DIR = os.getenv("TEMP"):gsub("\\", "/") .. "/plexsub/mf/"
local function subsReport(tag)
    return { call = function()
        local p = app.top()
        print(("[shots] %s: sub=%s burn=%s state=%s mode=%s cues=%s menu=%s"):format(tag,
            p.sub and p.sub.label or "off", tostring(p.burn), tostring(p.state), p.plan and p.plan.mode or "-",
            p.cues and #p.cues or "-", tostring(p.subMenu ~= nil)))
    end }
end
local subsScript = {
    { wait = 1.0 }, { shot = "90-subs-off" }, subsReport("start"),
    { key = "c" }, { wait = 0.3 }, { shot = "91-subs-menu" },
    { action = "down" }, { action = "accept" }, { wait = 0.8 }, { shot = "92-subs-sidecar" }, subsReport("sidecar"),
    { wait = 4.2 }, { shot = "93-subs-sidecar-no-overlay" },
    { key = "c" }, { action = "down" }, { action = "accept" }, { wait = 0.05 }, { shot = "94-subs-burn-starting" },
    subsReport("burn requested"), { wait = 1.5 }, { shot = "95-subs-burned" }, subsReport("burn playing"),
    { key = "c" }, { action = "up" }, { action = "up" }, { action = "accept" }, { wait = 1.5 }, subsReport("off again"),
    { quit = true },
}

-- lovec . --shots profile : avatar menu, Settings, theme presets. Puts the
-- user's own settings back afterwards.
local saved = {}
local function keepSettings()
    local c = require("plex.client").settings
    saved = { theme = c.theme, autoPlay = c.autoPlay, autoPlayDelay = c.autoPlayDelay }
end
local function restoreSettings()
    local client = require("plex.client")
    for k, v in pairs(saved) do client.settings[k] = v end
    client.save()
    require("theme").apply(client.settings.theme)
    print(("[shots] settings restored: theme=%s autoPlay=%s delay=%s"):format(tostring(saved.theme),
        tostring(saved.autoPlay), tostring(saved.autoPlayDelay)))
end
local function avatarClick(press)
    return { call = function()
        local home = app.top()
        for _, tab in ipairs(home.tabs) do
            if tab.profile and tab._x then
                local x, y = tab._x + tab._w / 2, 53 * love.graphics.getHeight() / 1080
                love.mouse.setPosition(x, y)
                love.mousemoved(x, y, 0, 0, false)
                if press then love.mousepressed(x, y, 1, false); love.mousereleased(x, y, 1, false) end
                return
            end
        end
        print("[shots] no avatar tab")
    end }
end
local function settingsReport(tag)
    return { call = function()
        local c = require("plex.client").settings
        local top = app.top()
        print(("[shots] %s: top=%s theme=%s autoPlay=%s delay=%s user=%s thumb=%s"):format(tag,
            top.rows and top.rows[1] and top.rows[1].title or (top.entries and "profile menu") or "?",
            tostring(c.theme), tostring(c.autoPlay), tostring(c.autoPlayDelay), tostring(c.userName),
            c.userThumb and "yes" or "no"))
    end }
end
local profileScript = {
    { call = keepSettings }, { wait = "home" }, { wait = 2 },
    { action = "up" }, { action = "up" }, { action = "up" }, { action = "right" }, { wait = 0.6 }, { shot = "099-nav-pill" },
    { action = "down" }, avatarClick(false), { wait = 0.5 }, { shot = "100-avatar-hover" },
    avatarClick(true), { wait = 1.5 }, { shot = "101-profile-menu" }, settingsReport("menu open"),
    { action = "accept" }, { wait = 0.8 }, { shot = "102-settings" }, settingsReport("settings"),
    { action = "down" }, { action = "right" }, { action = "right" }, { wait = 0.5 }, { shot = "103-settings-countdown-15" },
    { action = "down" }, { action = "right" }, { action = "right" }, { action = "right" }, { wait = 0.8 },
    { shot = "104-settings-theme-ocean" }, settingsReport("theme changed"),
    { action = "right" }, { action = "right" }, { action = "right" }, { action = "right" }, { wait = 0.8 },
    { shot = "105-settings-theme-oled" },
    { action = "down" }, { wait = 0.8 }, { shot = "106-settings-account" },
    { action = "back" }, { wait = 1.5 }, { shot = "107-home-in-oled-theme" },
    { action = "down" }, { wait = 2 }, { shot = "108-home-rows-oled" },
    { call = restoreSettings }, { wait = 1 }, { shot = "109-home-restored" },
    { quit = true },
}

-- lovec . --shots upnext : an "episode" (local clip) reaching its end shows
-- Playing Next and moves on to the stand-in next episode after the countdown.
local function upnextReport(tag)
    return { call = function()
        local p = app.top()
        print(("[shots] %s: playing=%s t=%.1f/%.1f state=%s card=%s left=%s"):format(tag, tostring(p.item and p.item.title),
            p.mediaTime and p:mediaTime() or -1, p.duration or -1, tostring(p.state), tostring(p.upNext ~= nil),
            p.upNext and ("%.1f"):format(p.upNext.left) or "-"))
    end }
end
local upnextScript = {
    { call = keepSettings }, { call = function()
        local c = require("plex.client")
        c.settings.autoPlay, c.settings.autoPlayDelay = true, 5
    end },
    { wait = 1.0 }, upnextReport("start"),
    { call = function() local p = app.top(); p:requestSeek(p.duration - 7) end }, { wait = 1.5 }, upnextReport("before card"),
    { wait = 1.5 }, { shot = "110-upnext-card" }, upnextReport("card shown"),
    { action = "back" }, { wait = 0.3 }, upnextReport("cancelled"), { shot = "111-upnext-cancelled" },
    { call = function() local p = app.top(); p:requestSeek(p.duration - 5.5); p.upNext = nil end }, { wait = 1.2 },
    { shot = "112-upnext-again" }, upnextReport("card again"),
    { wait = 5.5 }, upnextReport("after countdown"), { shot = "113-next-episode-playing" },
    { call = restoreSettings },
    { quit = true },
}

-- lovec . --shots nextep : which episode auto play would pick after each
-- episode in Continue Watching (read-only lookups, nothing plays).
local nextepScript = {
    { wait = "home" }, { call = function()
        local home = app.top()
        local api = require("plex.api")
        local function tag(e) return e and ("%s S%sE%s %s"):format(e.grandparentTitle or "?", e.parentIndex or "?", e.index or "?", e.title or "") or "nothing (end of show)" end
        for _, row in ipairs(home.rows) do
            for _, it in ipairs(row.items) do
                if it.type == "episode" then
                    api.nextEpisode(home.server, it, function(n) print("[shots] after " .. tag(it) .. " -> " .. tag(n)) end)
                end
            end
            break
        end
    end }, { wait = 6 },
    { quit = true },
}

local function startPlayerTest()
    local clip = "E:/Documents/nativevideo/test/media/vp9.webm"
    -- stand-ins: no network, timeline reports go to a closed local port
    local server = { name = "Local test", accessToken = "test",
                     baseUrl = function() return "http://127.0.0.1:9" end }
    local item = { title = "Player test clip", type = "movie", year = 2026, ratingKey = "0", key = "/test",
                   duration = 3000, Media = { { videoCodec = "vp9", container = "webm",
                   Part = { { key = clip, container = "webm" } } } } }
    if T.subsTest then
        clip = SUBS_DIR .. "long.mp4"
        item.duration = 20000
        item.Media[1].Part[1].id = 99
        item.Media[1].Part[1].Stream = {
            { streamType = 3, id = 1, codec = "srt", key = "/library/streams/1", displayTitle = "English (SRT External)" },
            { streamType = 3, id = 2, codec = "pgs", displayTitle = "English (PGS)" },
        }
        local subs = require("plex.subtitles")
        subs.select = function(_, partId, st) print(("[shots] saved choice: part %s -> %s"):format(partId, st and st.id or 0)) end
        subs.load = function(_, st, cb)
            local f = assert(io.open(SUBS_DIR .. "long.srt", "rb")); local data = f:read("*a"); f:close()
            cb(subs.parseSrt(data))
        end
    end
    if T.upnextTest then
        clip = SUBS_DIR .. "long.mp4"
        item.title, item.type, item.duration = "Pilot", "episode", 20000
        item.grandparentTitle, item.parentIndex, item.index = "Test Show", 1, 1
        local api = require("plex.api")
        api.nextEpisode = function(_, ep, cb)
            cb({ title = "The Second One", type = "episode", grandparentTitle = "Test Show", parentIndex = 1,
                 index = (ep.index or 1) + 1, ratingKey = "1", key = "/test2", duration = 20000,
                 Media = item.Media })
        end
    end
    require("plex.playback").plan = function(_, _, _, opts, cb)
        if opts.burnSubtitle then
            print("[shots] plan: convert with subtitle " .. tostring(opts.burnSubtitle) .. " burned in")
            return cb({ url = clip, mode = "transcode", offsetBase = opts.offset or 0, duration = 20, container = "mkv",
                        videoCodec = "h264", audioCodec = "aac", burnSubtitle = opts.burnSubtitle,
                        describe = "Converting (subtitles burned in)" })
        end
        cb({ url = clip, mode = "direct", offsetBase = 0, duration = item.duration / 1000, container = "webm",
             videoCodec = "vp9", audioCodec = "none", describe = "Direct play" })
    end
    app.push(require("player.scene").new(server, item, { startAt = 0 }))
end

-- lovec . --shots mouse : the same screens driven only by the mouse.
local mouseScript = {
    { wait = "home" }, { wait = 3 },
    { move = { 560, 650 } }, { wait = 1.5 }, { shot = "40-mouse-hover-card" },
    { move = { 270, 440 } }, { wait = 0.6 }, { shot = "41-mouse-hover-more-info" },
    { wheel = { 0, -3 } }, { wait = 1.5 }, { move = { 900, 560 } }, { wait = 1.5 }, { shot = "42-mouse-wheel-down" },
    { wheel = { 2, 0 } }, { wait = 1 }, { shot = "43-mouse-row-horizontal" },
    { click = { 900, 560 } }, { wait = 4 }, { shot = "44-mouse-click-detail" },
    { move = { 200, 470 } }, { wait = 0.6 }, { shot = "45-mouse-detail-button-hover" },
    { rclick = { 800, 450 } }, { wait = 1.5 }, { shot = "46-mouse-right-click-back" },
    { wheel = { 0, 5 } }, { wait = 1.5 }, { move = { 318, 48 } }, { wait = 0.5 }, { shot = "47-mouse-nav-hover" },
    { click = { 318, 48 } }, { wait = 4 }, { shot = "48-mouse-library" },
    { wheel = { 0, -4 } }, { wait = 1.5 }, { move = { 520, 500 } }, { wait = 1 }, { shot = "49-mouse-library-wheel-hover" },
    { quit = true },
}

local step, timer = 1, 0
local dir

T.startPlayer = startPlayerTest

function T.start(args)
    for i, a in ipairs(args or {}) do
        if a == "--shots" and args[i + 1] == "tv" then script = tvScript end
        if a == "--shots" and args[i + 1] == "player" then script = playerScript; T.player = true end
        if a == "--shots" and args[i + 1] == "mouse" then script = mouseScript end
        if a == "--shots" and args[i + 1] == "rows" then script = rowsScript end
        if a == "--shots" and args[i + 1] == "profile" then script = profileScript end
        if a == "--shots" and args[i + 1] == "nextep" then script = nextepScript end
        if a == "--shots" and args[i + 1] == "upnext" then script = upnextScript; T.player = true; T.upnextTest = true end
        if a == "--shots" and args[i + 1] == "hover" then script = hoverScript end
        if a == "--shots" and args[i + 1] == "subs" then script = subsScript; T.player = true; T.subsTest = true end
        if a == "--shots" and args[i + 1] == "request" then script = requestScript end
        if a == "--shots" and args[i + 1] == "detail" then script = detailScript end
        if a == "--shots" and args[i + 1] == "search" then script = searchScript end
        if a == "--shots" and args[i + 1] == "controls" then script = controlsScript; T.player = true end
    end
    io.stdout:setvbuf("no")
    love.filesystem.createDirectory("shots")
    dir = love.filesystem.getSaveDirectory() .. "/shots"
    print("[shots] saving to " .. dir)
end

function T.update(dt)
    local s = script[step]
    if not s then return end
    if s.wait == "home" then
        local top = app.top()
        if top and top.rows and #top.rows > 0 then step = step + 1 end
        timer = timer + dt
        if timer > 60 then print("[shots] home never loaded"); love.event.quit(1) end
        return
    elseif s.wait then
        timer = timer + dt
        if timer < s.wait then return end
        timer = 0
    elseif s.action then
        require("lib.input").lastDevice = "keyboard"   -- as a real key press would
        local top = app.top()
        if top and top.action then top:action(s.action, false) end
    elseif s.move then
        -- through the real LÖVE callbacks, as a physical mouse would
        love.mouse.setPosition(s.move[1], s.move[2])
        love.mousemoved(s.move[1], s.move[2], 0, 0, false)
    elseif s.click or s.rclick then
        local p = s.click or s.rclick
        love.mouse.setPosition(p[1], p[2])
        love.mousemoved(p[1], p[2], 0, 0, false)
        love.mousepressed(p[1], p[2], s.click and 1 or 2, false)
        love.mousereleased(p[1], p[2], s.click and 1 or 2, false)
    elseif s.call then
        s.call()
    elseif s.text then
        -- typed on the physical keyboard
        for ch in s.text:gmatch(".") do love.keypressed(ch, ch, false); love.textinput(ch) end
    elseif s.key then
        love.keypressed(s.key, s.key, false)
    elseif s.wheel then
        love.wheelmoved(s.wheel[1], s.wheel[2])
    elseif s.report == "search" then
        local p = app.top()
        print(("[shots] query=%q  results=%s  zone=%s  recent=%s"):format(p.query or "?",
            p.count and p:count() or "-", tostring(p.zone), table.concat(require("plex.client").settings.recentSearches or {}, ", ")))
    elseif s.report then
        local p = app.top()
        print(("[shots] fullscreen=%s  player open=%s  volume=%s muted=%s  state=%s"):format(
            tostring(love.window.getFullscreen()), tostring(p and p.video ~= nil),
            p and p.volume and ("%.2f"):format(p.volume) or "-", tostring(p and p.muted), tostring(p and p.state)))
    elseif s.inject then
        -- make the next video read fail exactly like the reported crash
        local p = app.top()
        if p and p.video then
            if p.state ~= "playing" then p:setPlaying(true) end
            p.video._decodeIntoBack = function() error("NativeVideo: ReadSample failed (0x80072f78)", 3) end
            print(("[shots] injected read failure at %.2fs"):format(p:mediaTime()))
        else
            print("[shots] inject: no video open (state " .. tostring(p and p.state) .. ")")
        end
    elseif s.shot then
        love.graphics.captureScreenshot("shots/" .. s.shot .. ".png")
        print("[shots] " .. s.shot)
    elseif s.quit then
        print("[shots] done")
        love.event.quit(0)
    end
    step = step + 1
end

return T
