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
    { action = "right" }, { action = "right" }, { wait = 0.5 }, { action = "accept" }, { wait = 4 }, { shot = "10-library" },
    { action = "down" }, { action = "down" }, { action = "right" }, { wait = 2 }, { shot = "11-library-scrolled" },
    { action = "menu" }, { wait = 0.6 }, { shot = "12-library-item-menu" }, { action = "back" }, { wait = 0.3 },
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

-- lovec . --shots genre : "anime" in Search shows a Genres row that opens the
-- library filtered; the library's Genre picker. Recent searches are put back.
local savedRecent
local function genreReport(tag)
    return { call = function()
        local top = app.top()
        if top.rows then
            for _, r in ipairs(top.rows) do print(("[shots] %s: row %s (%s) %d"):format(tag, r.title, r.kind, #r.items)) end
        else
            print(("[shots] %s: %s genre=%s total=%s loaded=%d"):format(tag, top.section and top.section.title or "?",
                top.genre and top.genre.title or "All", tostring(top.total), #(top.items or {})))
        end
    end }
end
local genreScript = {
    { wait = "home" }, { call = function()
        savedRecent = require("plex.client").settings.recentSearches
        app.push(require("ui.search").new(app.top().server))
    end }, { wait = 0.5 },
    { text = "anime" }, { wait = 3 }, genreReport("search"), { shot = "130-search-genres" },
    { action = "accept" }, { wait = 0.5 }, { action = "accept" }, { wait = 4 }, genreReport("opened"),
    { shot = "131-library-genre-anime" },
    { action = "up" }, { wait = 0.5 }, { shot = "132-library-header-focus" },
    { action = "accept" }, { wait = 0.8 }, { shot = "133-genre-picker" },
    { text = "sci" }, { wait = 0.5 }, { shot = "134-genre-picker-filtered" },
    { action = "accept" }, { wait = 4 }, genreReport("picked"), { shot = "135-library-genre-picked" },
    { action = "up" }, { action = "right" }, { action = "right" }, { wait = 0.4 }, { shot = "136-sort-focus" },
    { action = "accept" }, { wait = 0.6 }, { action = "down" }, { wait = 0.3 }, { shot = "137-sort-menu" },
    { action = "accept" }, { wait = 3 }, { action = "left" }, { wait = 0.3 }, { shot = "138-clear-focus" }, { action = "accept" },
    { wait = 3 }, genreReport("sorted, genre cleared"), { shot = "139-sorted-cleared" },
    { call = function()
        require("plex.client").set("recentSearches", savedRecent)
        print("[shots] recent searches restored")
    end },
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

-- lovec . --shots tracks : a file with many subtitle tracks; the menu lists the
-- first few and a "Show N more" row that expands the section in place.
local function tracksReport(tag)
    return { call = function()
        local m = app.top().subMenu
        local labels = {}
        for _, e in ipairs(m and m.entries or {}) do labels[#labels + 1] = e.label end
        print(("[shots] %s: menu=%s sel=%s entries=%d: %s"):format(tag, tostring(m ~= nil), m and m.sel or "-",
            #labels, table.concat(labels, " | ")))
    end }
end
local function selectMore()
    return { call = function()
        local m = app.top().subMenu
        for i, e in ipairs(m.entries) do if e.kind == "more" then m.sel = i end end
    end }
end
local tracksScript = {
    { wait = 1.0 }, { key = "c" }, { wait = 0.4 }, { shot = "200-tracks-collapsed" }, tracksReport("collapsed"),
    selectMore(), { wait = 0.2 }, { shot = "201-tracks-more-focused" }, { action = "accept" }, { wait = 0.3 },
    { shot = "202-tracks-expanded" }, tracksReport("expanded"),
    { action = "back" }, { wait = 0.3 },
    -- the track in use stays listed when it's past the first few
    { call = function() local p = app.top(); p.sub = p.subStreams[9] end },
    { key = "c" }, { wait = 0.4 }, { shot = "203-tracks-current-listed" }, tracksReport("current is 9th"),
    { action = "back" }, { quit = true },
}

-- lovec . --shots opus51 : 5.1 Opus played as it is. Windows' decoder refuses
-- it, so the DLL decodes it with libopus: expect sound (a 440 Hz tone) with no
-- server conversion.
local function opusReport(tag)
    return { call = function()
        local p = app.top()
        local hz, sd = 0, p.audio and p.audio.sd
        if sd then
            local n, prev, crossings = sd:getSampleCount(), 0, 0
            for i = 0, n - 1 do
                local v = sd:getSample(i, 1)
                if prev < 0 and v >= 0 then crossings = crossings + 1 end
                prev = v
            end
            hz = crossings * sd:getSampleRate() / n
        end
        print(("[shots] " .. tag .. ": state=%s mode=%s audio=%s heard ~%d Hz t=%.1f audioConvert=%s error=%s"):format(
            tostring(p.state), p.plan and p.plan.mode or "-", tostring(p.audio ~= nil), hz, p:mediaTime(),
            tostring(p.audioConvert), tostring(p.audioError)))
        local playback = require("plex.playback")
        print(("[shots] canDecodeAudio opus 6ch=%s 2ch=%s; libopus=%s"):format(tostring(playback.canDecodeAudio("opus", 6)),
            tostring(playback.canDecodeAudio("opus", 2)), tostring(app.opusSurround)))
    end }
end
local opusScript = {
    { wait = 2.0 }, opusReport("opus51"),
    { call = function() app.top():requestSeek(6) end }, { wait = 1.5 }, opusReport("after seek to 6"),
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

-- lovec . --shots audio : a local clip with an English (440 Hz tone) and a
-- Japanese (1760 Hz) track; switch in the track menu and check what's heard.
local function audioReport(tag)
    return { call = function()
        local p = app.top()
        local hz = 0
        local sd = p.audio and p.audio.sd
        if sd then
            -- rising zero crossings in the last decoded chunk (left channel)
            local n, prev, crossings = sd:getSampleCount(), 0, 0
            for i = 0, n - 1 do
                local s = sd:getSample(i, 1)
                if prev < 0 and s >= 0 then crossings = crossings + 1 end
                prev = s
            end
            hz = crossings * sd:getSampleRate() / n
        end
        print(("[shots] %s: state=%s t=%.1f track=%s heard ~%d Hz plan=%s"):format(tag, p.state, p:mediaTime(),
            p.audioTrack and p.audioTrack.label or "?", hz, p.plan and p.plan.mode or "?"))
    end }
end
local audioScript = {
    { wait = 2.0 }, audioReport("start"),
    { call = function() app.top():requestSeek(8) end }, { wait = 1.5 }, audioReport("seek 8 +1"), { wait = 1 }, audioReport("seek 8 +2"),
    { key = "c" }, { wait = 0.4 }, { shot = "140-track-menu" },
    { action = "up" }, { action = "up" }, { wait = 0.3 }, { shot = "141-track-menu-japanese" },
    audioReport("before switch"), { action = "accept" }, audioReport("switch +0"),
    { wait = 0.5 }, audioReport("switch +0.5"), { wait = 0.5 }, audioReport("switch +1"),
    { wait = 1.5 }, audioReport("after switch"), { shot = "142-japanese-playing" },
    { key = "c" }, { action = "up" }, { action = "up" }, { action = "up" }, { action = "accept" },
    { wait = 2.5 }, audioReport("back to English"),
    { key = "c" }, { action = "down" }, { action = "down" }, { action = "down" }, { action = "down" },
    { action = "down" }, { action = "down" }, { wait = 0.4 }, { shot = "143-track-menu-quality" }, { action = "back" },
    { quit = true },
}

-- lovec . --shots options : the poster options menu (keyboard and mouse) on
-- Home and a library, the quality settings, and which stream each quality
-- picks. Marking and removing are stubbed (nothing on the server changes);
-- the quality settings are put back.
local optionCalls = {}
local function optionsReport(tag)
    return { call = function()
        local top = app.top()
        local labels = {}
        for _, e in ipairs(top.entries or {}) do labels[#labels + 1] = e.label end
        print(("[shots] %s: top=%s entries=[%s] sel=%s calls=[%s]"):format(tag,
            top.entries and ("menu for " .. require("plex.api").displayTitle(top.item)) or (top.section and top.section.title)
                or (top.rows and "home") or "?", table.concat(labels, " | "), tostring(top.sel),
            table.concat(optionCalls, "; ")))
    end }
end
local function homeCard()
    local r = app.top().rows[1].rects[2]
    return r.x + r.w * 0.5, r.y + r.h * 0.4
end
local function mouseAt(getPoint, button)
    return { call = function()
        local x, y = getPoint()
        love.mouse.setPosition(x, y)
        love.mousemoved(x, y, 0, 0, false)
        if button then love.mousepressed(x, y, button, false); love.mousereleased(x, y, button, false) end
    end }
end
local savedQuality
local optionsScript = {
    { call = function()
        local api = require("plex.api")
        api.setWatched = function(_, item, watched, cb)
            optionCalls[#optionCalls + 1] = (watched and "watched " or "unwatched ") .. api.displayTitle(item)
            cb(true)
        end
        api.removeFromContinueWatching = function(_, item, cb)
            optionCalls[#optionCalls + 1] = "remove-continue " .. api.displayTitle(item)
            cb(true)
        end
        local c = require("plex.client").settings
        savedQuality = { c.qualityHome, c.qualityAway }
    end },
    { wait = "home" }, { wait = 2 },
    -- keyboard: first row (Continue Watching), Tab
    { action = "down" }, { wait = 1.5 }, { action = "menu" }, { wait = 0.6 }, optionsReport("home row 1"),
    { shot = "150-home-options" },
    { action = "down" }, { action = "down" }, { wait = 0.2 }, optionsReport("moved"), { action = "back" }, { wait = 0.4 },
    -- mouse: hover shows the more button; right click opens the menu
    mouseAt(homeCard), { wait = 1 }, { shot = "151-home-hover-more" },
    mouseAt(homeCard, 2), { wait = 0.6 }, optionsReport("right click"), { shot = "152-home-right-click" },
    -- Remove from Continue Watching if offered, else Mark as Watched
    { call = function()
        local m = app.top()
        for i, e in ipairs(m.entries) do
            if e.label == "Remove from Continue Watching" or e.label == "Mark as Watched" then m.sel = i end
        end
        print("[shots] choosing " .. m.entries[m.sel].label)
        m:action("accept")
    end }, { wait = 3 }, optionsReport("after change"), { shot = "153-home-after-change" },
    -- a film library: Tab on a poster, Mark as Watched / Unwatched
    { call = function()
        require("lib.input").lastDevice = "keyboard"
        local h = app.top()
        for _, t in ipairs(h.tabs) do if t.section and t.section.type == "movie" then return h:openTab(t) end end
    end }, { wait = 4 },
    { action = "right" }, { action = "right" }, { wait = 1 }, { action = "menu" }, { wait = 0.6 },
    optionsReport("library poster"), { shot = "154-library-options" },
    { call = function()
        local m = app.top()
        local item = m.item
        for i, e in ipairs(m.entries) do if e.label:find("^Mark as") then m.sel = i; break end end
        print("[shots] choosing " .. m.entries[m.sel].label)
        m:action("accept")
        print("[shots] card now watched=" .. tostring((require("plex.api").watchState(item))))
    end }, { wait = 0.8 }, { shot = "155-library-marked" },
    { action = "menu" }, { wait = 0.5 }, optionsReport("library poster again"), { action = "back" },
    -- Tab on the toolbar still opens Sort
    { action = "up" }, { action = "up" }, { action = "up" }, { action = "up" }, { action = "menu" }, { wait = 0.5 },
    { call = function() print("[shots] toolbar Tab opens: " .. tostring(app.top().menu and app.top().menu.kind)) end },
    { action = "back" }, { wait = 0.3 },
    -- which stream each quality picks for a film (the server's decision check is stubbed)
    { call = function()
        local api, playback = require("plex.api"), require("plex.playback")
        local lib = app.top()
        local server = lib.server
        local realGet = api.get
        api.get = function(srv, path, params, cb, opts)
            if path:find("transcode") then
                print(("[shots]   decision asked: maxVideoBitrate=%s videoResolution=%s"):format(
                    tostring(params.maxVideoBitrate), tostring(params.videoResolution)))
                return cb({ Metadata = { { Media = { { videoCodec = "h264", audioCodec = "aac" } } } } })
            end
            return realGet(srv, path, params, cb, opts)
        end
        print("[shots] connection is " .. (playback.isHome(server) and "home" or "away"))
        local film = lib.items[1]
        for _, it in ipairs(lib.items) do
            local m = it.Media and it.Media[1]
            if m and m.videoCodec == "h264" and (tonumber(m.bitrate) or 0) > 2500 then film = it; break end
        end
        api.metadata(server, film.ratingKey, function(full)
            local m = full.Media[1]
            print(("[shots] %s: %s %s %s kbps"):format(full.title, tostring(m.videoCodec), tostring(m.videoResolution),
                tostring(m.bitrate)))
            for _, q in ipairs(playback.QUALITIES) do
                playback.plan(server, full, "shots-test", { quality = q }, function(plan, err)
                    print(("[shots]   %-14s -> %s%s"):format(q.label, plan and plan.mode or ("error " .. tostring(err)),
                        plan and plan.mode == "transcode" and ("  (" .. plan.describe .. ")") or ""))
                end)
            end
        end)
    end }, { wait = 3 },
    { action = "back" }, { wait = 0.5 },
    -- quality settings
    { call = function() app.push(require("ui.settings").new(app.top().server)) end }, { wait = 0.6 },
    { action = "down" }, { action = "down" }, { wait = 0.8 }, { shot = "156-settings-quality" },
    { action = "right" }, { action = "right" }, { action = "right" }, { action = "right" }, { wait = 0.5 },
    { shot = "157-settings-quality-4mbps" },
    { call = function()
        local c = require("plex.client").settings
        print(("[shots] qualityHome=%s qualityAway=%s"):format(tostring(c.qualityHome), tostring(c.qualityAway)))
        c.qualityHome, c.qualityAway = savedQuality[1], savedQuality[2]
        require("plex.client").save()
        print("[shots] quality settings restored")
    end },
    { quit = true },
}

-- lovec . --shots watchlist : the Watchlist row on Home, its entries in the
-- poster menu, and a show's Audio & Subtitles panel. Every PUT (watchlist
-- changes, show settings) is answered here instead of sent, so neither the
-- plex.tv watchlist nor the server's settings change.
local puts = {}
local function watchRow()
    local h = app.stack[1]
    for i, r in ipairs(h.rows or {}) do if r.watchlist then return i, r end end
end
local function wlReport(tag)
    return { call = function()
        local top = app.top()
        local i, r = watchRow()
        local missing = 0
        for _, it in ipairs(r and r.items or {}) do if it.notOnServer then missing = missing + 1 end end
        local labels = {}
        for _, e in ipairs(top.entries or {}) do labels[#labels + 1] = e.label end
        for _, row in ipairs(top.rows and top.rows[1] and top.rows[1].setting and top.rows or {}) do
            labels[#labels + 1] = row.title .. "=" .. tostring(row.setting.value)
        end
        print(("[shots] %s: watchlist row %s with %d (%d not in library) | %s | PUTs: %s"):format(tag, tostring(i),
            r and #r.items or 0, missing, table.concat(labels, ", "), table.concat(puts, "; ")))
    end }
end
local watchlistScript = {
    { call = function()
        local http = require("lib.http")
        local real = http.request
        http.request = function(o, cb)
            if o.method == "PUT" then
                puts[#puts + 1] = o.url:gsub("^https?://[^/]+", ""):gsub("[?&]X%-Plex%-Token=[^&]*", "")
                return cb({ status = 200, body = "" })
            end
            return real(o, cb)
        end
    end },
    { wait = "home" },
    { call = function() end }, { wait = 6 }, wlReport("home"),
    { call = function()
        local h = app.top()
        local i = watchRow()
        if i then h.focusRow = i + 1 end
    end }, { wait = 2 }, { shot = "160-home-watchlist" },
    -- a title that isn't on the server: Request / Remove
    { call = function()
        local h = app.top()
        local _, r = watchRow()
        for c, it in ipairs(r.items) do if it.notOnServer then r.col = c; break end end
    end }, { wait = 1.2 }, { action = "menu" }, { wait = 0.5 }, wlReport("not-in-library menu"),
    { shot = "161-watchlist-missing-menu" }, { action = "back" },
    { action = "accept" }, { wait = 3 }, { shot = "162-watchlist-request-page" }, { action = "back" }, { wait = 0.5 },
    -- one that is: remove it from the watchlist
    { call = function()
        local _, r = watchRow()
        for c, it in ipairs(r.items) do if not it.notOnServer then r.col = c; break end end
    end }, { wait = 0.8 }, { action = "menu" }, { wait = 0.5 }, wlReport("in-library menu"),
    { call = function()
        local m = app.top()
        for i, e in ipairs(m.entries) do if e.label:find("Watchlist") then m.sel = i end end
        print("[shots] choosing " .. m.entries[m.sel].label)
        m:action("accept")
    end }, { wait = 3 }, wlReport("after removing"),
    -- an episode in Continue Watching: its show
    { call = function() app.top().focusRow = 2; app.top().rows[1].col = 1 end }, { wait = 0.8 },
    { action = "menu" }, { wait = 0.5 }, wlReport("episode menu"), { action = "back" },
    -- the show's page and its Audio & Subtitles panel
    { call = function()
        local h = app.top()
        local ep = h.rows[1].items[1]
        app.push(require("ui.detail").new(h.server, { type = "show", ratingKey = ep.grandparentRatingKey or ep.ratingKey }))
    end }, { wait = 4 }, { shot = "163-show-buttons" },
    { call = function()
        local d = app.top()
        local labels = {}
        for _, b in ipairs(d.buttons or {}) do labels[#labels + 1] = b.label end
        print("[shots] show buttons: " .. table.concat(labels, " | "))
        for _, b in ipairs(d.buttons or {}) do if b.label == "Audio & Subtitles" then b.run() end end
    end }, { wait = 2 }, wlReport("panel"), { shot = "164-show-prefs" },
    { action = "accept" }, { wait = 0.4 }, { shot = "165-show-prefs-audio-list" },
    { text = "jap" }, { wait = 0.4 }, { shot = "166-show-prefs-filtered" },
    { action = "accept" }, { wait = 0.8 }, wlReport("audio chosen"),
    { action = "down" }, { action = "down" }, { action = "accept" }, { wait = 0.4 }, { shot = "167-show-prefs-mode-list" },
    { action = "down" }, { action = "down" }, { action = "accept" }, { wait = 0.8 }, wlReport("mode chosen"),
    { shot = "168-show-prefs-saved" },
    { quit = true },
}

-- lovec . --shots rate : the Rate button and star picker on a film's page, and
-- Rate in a card's menu. PUTs are caught (nothing is rated on the server); the
-- requests that would have been sent are printed.
local ratePuts = {}
local function rateReport(tag)
    return { call = function()
        local top = app.top()
        local labels = {}
        for _, b in ipairs(top.buttons or {}) do labels[#labels + 1] = b.label end
        for _, e in ipairs(top.entries or {}) do labels[#labels + 1] = e.label end
        print(("[shots] %s: value=%s  labels=%s  puts=%s"):format(tag, tostring(top.value),
            table.concat(labels, " | "), table.concat(ratePuts, " ; ")))
    end }
end
local function rateButton()
    return { call = function()
        for _, b in ipairs(app.top().buttons or {}) do if b.icon == "star" then b.run() end end
    end }
end
local rateScript = {
    { call = function()
        local http = require("lib.http")
        local real = http.request
        http.request = function(o, cb)
            if o.method == "PUT" then
                ratePuts[#ratePuts + 1] = o.url:gsub("^https?://[^/]+", ""):gsub("[?&]X%-Plex%-Token=[^&]*", "")
                return cb({ status = 200, body = "" })
            end
            return real(o, cb)
        end
    end },
    { wait = "home" }, { wait = 2 },
    { call = function()
        local h = app.top()
        for _, r in ipairs(h.rows) do
            for _, it in ipairs(r.items or {}) do
                if it.type == "movie" and not h.rateMovie then h.rateMovie = it end
            end
        end
        print("[shots] rating: " .. tostring(h.rateMovie and h.rateMovie.title))
        app.push(require("ui.detail").new(h.server, h.rateMovie))
    end }, { wait = 4 }, rateReport("page"), { shot = "200-rate-button" },
    rateButton(), { wait = 0.6 }, rateReport("picker"), { shot = "201-rate-picker" },
    { action = "right" }, { action = "right" }, { action = "right" }, { action = "right" },
    { action = "right" }, { action = "right" }, { action = "right" }, { wait = 0.3 }, rateReport("3.5 stars"),
    { shot = "202-rate-picker-chosen" },
    { action = "accept" }, { wait = 1.5 }, rateReport("saved"), { shot = "203-rate-button-rated" },
    rateButton(), { wait = 0.6 }, { action = "down" }, { wait = 0.3 }, { shot = "204-rate-picker-rated" },
    { action = "accept" }, { wait = 1 }, rateReport("removed"),
    rateButton(), { wait = 0.6 }, { key = "4" }, { wait = 1 }, rateReport("key 4"),
    { action = "back" }, { wait = 1 },
    { call = function() local h = app.top(); h.focusRow = 2; h.rows[1].col = 1 end }, { wait = 0.8 },
    { action = "menu" }, { wait = 0.5 }, rateReport("card menu"), { shot = "205-card-menu-rate" },
    { call = function()
        local m = app.top()
        for i, e in ipairs(m.entries) do if e.label:find("Rat") then m.sel = i end end
        m:action("accept")
    end }, { wait = 0.6 }, { shot = "206-card-menu-picker" }, { action = "back" },
    { quit = true },
}

-- lovec . --shots stall : plays a clip from a local server that stops sending
-- for 1.5 s every couple of seconds (start `python tools/slowserve.py` first),
-- and reports the longest gap between app frames: the stream's thread waits on
-- the network, so the app keeps drawing.
local stallFrames = { max = 0, n = 0 }
local stallScript = {
    { wait = 2 },
    { call = function()
        local prev = love.update
        love.update = function(dt)
            if dt > stallFrames.max then stallFrames.max = dt end
            stallFrames.n = stallFrames.n + 1
            return prev(dt)
        end
    end },
    { wait = 9 },
    { call = function()
        local p = app.top()
        print(("[shots] stall: %d frames, longest %.0f ms; player %s at %.1fs, starved %s"):format(stallFrames.n,
            stallFrames.max * 1000, tostring(p.state), p.mediaTime and p:mediaTime() or -1,
            tostring(p.audio and p.audio:isStarved())))
    end }, { shot = "191-stall" },
    { quit = true },
}

-- lovec . --shots fileerror : direct play from a server that answers HTTP 500
-- for the file (start `python tools/refuse500.py` first). The player should ask for
-- a conversion instead of failing with a network error.
local fileErrorScript = {
    { wait = 3.5 },
    { call = function()
        local p = app.top()
        print(("[shots] file error: state %s, mode %s, fileError %s, error %s"):format(tostring(p.state),
            tostring(p.plan and p.plan.mode), tostring(p.fileError), tostring(p.error)))
    end }, { shot = "190-file-error-converted" },
    { quit = true },
}

-- lovec . --shots cast : a show's and a film's Cast row (under More Like
-- This) and an actor's page. Read-only.
local function castReport(tag)
    return { call = function()
        local top = app.top()
        if top.person then
            local parts = {}
            for _, r in ipairs(top.rows or {}) do parts[#parts + 1] = r.title .. "=" .. #r.items end
            print(("[shots] %s: %s, rows %s"):format(tag, top.person.tag, table.concat(parts, ", ")))
        else
            local cast = top.item and top.item.Role or {}
            print(("[shots] %s: %s, sections %s, cast %d, focused %s"):format(tag, top.item and top.item.title or "?",
                table.concat(top.sections or {}, "/"), #cast, tostring(cast[top.castCol] and cast[top.castCol].tag)))
        end
    end }
end
local function openDetail(item)
    return { call = function() app.push(require("ui.detail").new(app.stack[1].server, item)) end }
end
local castScript = {
    { wait = "home" },
    openDetail({ type = "show", ratingKey = "88230" }), { wait = 5 },
    { action = "down" }, { action = "down" }, { action = "down" }, { action = "down" }, { wait = 2 },
    castReport("show cast"), { shot = "180-show-cast" },
    { action = "right" }, { action = "right" }, { wait = 1.5 }, { shot = "181-show-cast-focus" },
    { action = "accept" }, { wait = 4 }, castReport("person"), { shot = "182-person" },
    { action = "down" }, { wait = 1.5 }, { shot = "183-person-second-row" },
    { action = "back" }, { action = "back" }, { wait = 0.5 },
    openDetail({ type = "movie", ratingKey = "149061" }), { wait = 5 },
    { action = "down" }, { action = "down" }, { wait = 2 },
    castReport("film cast"), { shot = "184-film-cast" },
    { quit = true },
}

-- lovec . --shots foryou : the "For You" sort on the film and TV libraries,
-- then For You within one genre. Read-only.
local function forYouReport(tag)
    return { call = function()
        local top = app.top()
        print(("[shots] %s: %s genre=%s total=%s from %s watched"):format(tag, top.section and top.section.title or "?",
            top.genre and top.genre.title or "All", tostring(top.total), tostring(top.basedOn)))
        for i = 1, math.min(12, #(top.items or {})) do
            local it = top.items[i]
            print(("[shots]   %2d %.2f %s (%s) - %s"):format(i, it._score or 0, it.title or "?", tostring(it.year), it.reason or ""))
        end
    end }
end
local function openLibrary(kind)
    return { call = function()
        require("lib.input").lastDevice = "keyboard"
        while #app.stack > 1 do app.pop() end
        local h = app.top()
        for _, t in ipairs(h.tabs) do if t.section and t.section.type == kind then return h:openTab(t) end end
    end }
end
local forYouScript = {
    { wait = "home" }, { wait = 1 },
    openLibrary("movie"), { wait = 3 },
    { action = "up" }, { action = "right" }, { wait = 0.3 }, { action = "accept" }, { wait = 0.6 },
    { shot = "170-sort-menu-foryou" },
    { action = "up" }, { action = "accept" },
    { call = function() print("[shots] ranking films...") end }, { wait = 8 }, { action = "down" }, { wait = 1 },
    forYouReport("films"), { shot = "171-films-for-you" },
    { action = "right" }, { action = "right" }, { wait = 1 }, { shot = "172-films-for-you-third" },
    openLibrary("show"), { wait = 3 },
    { call = function() app.top():setSort(1) end }, { wait = 6 }, { action = "right" }, { wait = 1 },
    forYouReport("shows"), { shot = "173-shows-for-you" },
    { call = function()
        local lib = app.top()
        for _, g in ipairs(lib.genres or {}) do if g.title == "Animation" then lib:setGenre(g) end end
    end }, { wait = 5 }, forYouReport("shows, Animation"), { shot = "174-shows-for-you-animation" },
    -- Home's Recommended rows
    { call = function() while #app.stack > 1 do app.pop() end end }, { wait = 2 },
    { call = function()
        local h = app.top()
        for i, r in ipairs(h.rows) do
            local first = {}
            for j = 1, math.min(4, #r.items) do first[j] = r.items[j].title or "?" end
            print(("[shots] home row %d: %s (%d) %s"):format(i, r.title, #r.items, table.concat(first, ", ")))
            if r.recommended and not h.recRow then h.recRow = i end
        end
        if h.recRow then h.focusRow = h.recRow + 1; h.rows[h.recRow].col = 2 end
        h.recRow = nil
    end }, { wait = 2 }, { shot = "175-home-recommended" },
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

-- lovec . --shots notify : request notifications against the real Seerr request
-- list (read-only). Two requests are marked as if they were still pending /
-- not yet downloaded, so the next check announces them; the user's own record
-- of seen requests is put back afterwards.
local notifySaved
local notifyScript = {
    { wait = "home" }, { call = function()
        local client = require("plex.client")
        notifySaved = client.settings.seerrSeen
        client.settings.seerrSeen = nil
        T.tickNotify = true
        require("seerr.notify").check()             -- first check: only records
    end }, { wait = 5 },
    { call = function()
        local seen = require("plex.client").settings.seerrSeen
        local keys = {}
        for k in pairs(seen or {}) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tonumber(a) > tonumber(b) end)
        print(("[shots] recorded %d requests"):format(#keys))
        if keys[1] then seen[keys[1]].r = 1 end                         -- was pending -> approved
        if keys[2] then seen[keys[2]].r, seen[keys[2]].m = 2, 3 end     -- was processing -> on Plex
        for i = 1, 2 do if keys[i] then print(("[shots] faked request %s as %s"):format(keys[i], require("lib.json").encode(seen[keys[i]]))) end end
        require("seerr.notify").check()
    end }, { wait = 3 }, { shot = "120-notify-approved" },
    { call = function() print("[shots] toast: " .. tostring(app.toast and app.toast.heading) .. " / " .. tostring(app.toast and app.toast.msg)) end },
    { wait = 7.2 }, { shot = "121-notify-on-plex" },
    { call = function() print("[shots] toast: " .. tostring(app.toast and app.toast.heading) .. " / " .. tostring(app.toast and app.toast.msg)) end },
    { call = function()
        local client = require("plex.client")
        if notifySaved ~= nil then client.set("seerrSeen", notifySaved) end   -- else keep the fresh record
        print("[shots] seerrSeen restored")
    end },
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
    if T.audioTest then
        clip = os.getenv("TEMP"):gsub("\\", "/") .. "/plexaudio/two.mkv"
        item.title, item.duration = "Two audio tracks", 20000
        item.Media[1].videoCodec, item.Media[1].container = "h264", "mkv"
        item.Media[1].Part[1].id = 98
        item.Media[1].Part[1].Stream = {
            { streamType = 1, id = 10, index = 0, codec = "h264" },
            { streamType = 2, id = 11, index = 1, codec = "aac", displayTitle = "English (AAC Stereo)", selected = true },
            { streamType = 2, id = 12, index = 2, codec = "aac", displayTitle = "Japanese (AAC Stereo)" },
            { streamType = 2, id = 13, index = 3, codec = "dca", displayTitle = "English (DTS 5.1)" },
        }
        require("plex.subtitles").selectAudio = function(_, partId, st, cb)
            print(("[shots] saved audio choice: part %s -> %s"):format(partId, st.id))
            if cb then cb(true) end
        end
    end
    if T.tracksTest then
        clip = SUBS_DIR .. "long.mp4"
        item.duration = 20000
        item.Media[1].Part[1].id = 97
        local streams = {}
        local langs = { "English", "English SDH", "Spanish", "French", "German", "Italian", "Japanese",
                        "Korean", "Portuguese", "Arabic", "Chinese", "Dutch" }
        for i, l in ipairs(langs) do
            streams[i] = { streamType = 3, id = 300 + i, codec = "srt", key = "/library/streams/" .. (300 + i),
                           displayTitle = l .. " (SRT External)" }
        end
        item.Media[1].Part[1].Stream = streams
        require("plex.subtitles").select = function() end
    end
    if T.opusTest then
        clip = os.getenv("TEMP"):gsub("\\", "/") .. "/plexaudio/opus51.mkv"
        item.duration = 10000
        item.Media[1].videoCodec, item.Media[1].container = "h264", "mkv"
        item.Media[1].Part[1].Stream = { { streamType = 2, id = 21, index = 1, codec = "opus", channels = 6, displayTitle = "English (OPUS 5.1)" } }
    end
    if T.stallTest then item.duration = 20000 end
    if T.fileErrorTest then clip, item.duration = SUBS_DIR .. "long.mp4", 20000 end
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
        if T.fileErrorTest and not opts.forceTranscode then
            -- a local server that answers 500 for everything (python tools/refuse500.py)
            print("[shots] plan: direct play from a server that refuses the file")
            return cb({ url = "http://127.0.0.1:18765/library/parts/1/file.mkv", mode = "direct", offsetBase = 0,
                        duration = 20, container = "mkv", videoCodec = "h264", audioCodec = "aac", describe = "Direct play" })
        end
        if T.stallTest then
            return cb({ url = "http://127.0.0.1:18766/long.mp4", mode = "direct", offsetBase = 0, duration = 20,
                        container = "mp4", videoCodec = "h264", audioCodec = "aac", describe = "Direct play (slow)" })
        end
        if T.fileErrorTest then
            print("[shots] plan: converting instead (forceTranscode)")
            return cb({ url = clip, mode = "transcode", offsetBase = opts.offset or 0, duration = 20, container = "mkv",
                        videoCodec = "h264", audioCodec = "aac", describe = "Converting" })
        end
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
        if a == "--shots" and args[i + 1] == "rate" then script = rateScript end
        if a == "--shots" and args[i + 1] == "profile" then script = profileScript end
        if a == "--shots" and args[i + 1] == "nextep" then script = nextepScript end
        if a == "--shots" and args[i + 1] == "notify" then script = notifyScript end
        if a == "--shots" and args[i + 1] == "genre" then script = genreScript end
        if a == "--shots" and args[i + 1] == "options" then script = optionsScript end
        if a == "--shots" and args[i + 1] == "watchlist" then script = watchlistScript end
        if a == "--shots" and args[i + 1] == "foryou" then script = forYouScript end
        if a == "--shots" and args[i + 1] == "cast" then script = castScript end
        if a == "--shots" and args[i + 1] == "audio" then script = audioScript; T.player = true; T.audioTest = true end
        if a == "--shots" and args[i + 1] == "tracks" then script = tracksScript; T.player = true; T.tracksTest = true end
        if a == "--shots" and args[i + 1] == "opus51" then script = opusScript; T.player = true; T.opusTest = true end
        if a == "--shots" and args[i + 1] == "stall" then script = stallScript; T.player = true; T.stallTest = true end
        if a == "--shots" and args[i + 1] == "fileerror" then script = fileErrorScript; T.player = true; T.fileErrorTest = true end
        if a == "--shots" and args[i + 1] == "upnext" then script = upnextScript; T.player = true; T.upnextTest = true end
        if a == "--shots" and args[i + 1] == "hover" then script = hoverScript end
        if a == "--shots" and args[i + 1] == "subs" then script = subsScript; T.player = true; T.subsTest = true end
        if a == "--shots" and args[i + 1] == "request" then script = requestScript end
        if a == "--shots" and args[i + 1] == "detail" then script = detailScript end
        if a == "--shots" and args[i + 1] == "search" then script = searchScript end
        if a == "--shots" and args[i + 1] == "controls" then script = controlsScript; T.player = true end
    end
    io.stdout:setvbuf("no")
    -- the real mouse (someone using the PC while this runs) would steal focus;
    -- scripted steps call love.mousemoved etc. directly, so drop the OS events
    for _, ev in ipairs({ "mousemoved", "mousepressed", "mousereleased", "wheelmoved" }) do
        love.handlers[ev] = function() end
    end
    love.filesystem.createDirectory("shots")
    dir = love.filesystem.getSaveDirectory() .. "/shots"
    print("[shots] saving to " .. dir)
end

function T.update(dt)
    if T.tickNotify then require("seerr.notify").update(dt) end
    local s = script[step]
    if not s then return end
    if s.wait == "home" then
        local top = app.top()
        if top and top.rows and #top.rows > 0 then
            print(("[shots] home loaded %.2f s after start"):format(love.timer.getTime()))
            step = step + 1
        end
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
            p.video.error = "ReadSample failed (0x80072f78)"   -- as if the stream's thread reported it
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
