-- Home: top nav (Home + libraries), a rotating hero banner, and horizontal
-- rows built from the server's /hubs (plus Continue Watching).
--
-- Focus rows: 0 = nav bar, 1 = hero buttons, 2.. = hub rows.

local theme = require("theme")
local gfx = require("ui.gfx")
local W = require("ui.widgets")
local api = require("plex.api")
local input = require("lib.input")
local client = require("plex.client")
local mouse = require("ui.mouse")

local Home = {}
Home.__index = Home

local HERO_ROTATE = 12
local HERO_MAX = 6
local OPENABLE = { movie = true, show = true, season = true, episode = true, clip = true }

function Home.new(server)
    return setmetatable({
        server = server,
        rows = {},            -- { title, kind, items, col, scroll, anim }
        heroItems = {},
        heroIndex = 1, heroTimer = 0, heroFade = 1,
        focusRow = 1, heroButton = 1,
        navIndex = 1,
        scrollY = 0, scrollTarget = 0,
        anim = { nav = 0, hero = 1, heroBtn = {} },
        backdrop = W.newBackdrop(),
        loading = true,
        tabs = { { label = "Home", active = true }, { label = "Search", search = true },
                 { label = "Account", profile = true } },
        searchable = true,    -- "/" or Ctrl+F opens search (main.lua)
    }, Home)
end

function Home:enter()
    self:load()
end

function Home:resume()
    -- back from player/detail: refresh progress and Continue Watching
    self:load(true)
end

local function isContinueHub(hub)
    local id = (hub.hubIdentifier or "") .. (hub.context or "")
    return id:find("continue") or id:find("ondeck") or id:find("inprogress")
end

function Home:load(quiet)
    if not quiet then self.loading = true end
    local pending = 3
    local hubs, cont, sections
    local function done()
        pending = pending - 1
        if pending > 0 then return end
        self.loading = false
        self:build(hubs or {}, cont or {}, sections or {})
    end
    api.hubs(self.server, function(h, err)
        if not h then self.error = err end
        hubs = h
        done()
    end)
    api.continueWatching(self.server, function(items) cont = items; done() end)
    api.sections(self.server, function(s) sections = s; done() end)
end

function Home:build(hubs, cont, sections)
    -- Keep the user's place when refreshing.
    local prevRow = self.rows[self.focusRow - 1]
    local prevTitle, prevCol = prevRow and prevRow.title, prevRow and prevRow.col

    local rows = {}
    local haveContinue = false
    for _, hub in ipairs(hubs) do
        if isContinueHub(hub) then haveContinue = true end
    end
    if not haveContinue and #cont > 0 then
        rows[#rows + 1] = { title = "Continue Watching", kind = "wide", items = cont }
    end
    -- On Deck mostly repeats Continue Watching; keep only what's not already there.
    local inContinue = {}
    for _, hub in ipairs(hubs) do
        if (hub.hubIdentifier or "") == "home.continue" then
            for _, it in ipairs(hub.Metadata or {}) do inContinue[it.ratingKey] = true end
        end
    end
    for _, hub in ipairs(hubs) do
        local items = {}
        local isOnDeck = (hub.hubIdentifier or ""):find("ondeck") ~= nil
        for _, it in ipairs(hub.Metadata or {}) do
            if OPENABLE[it.type] and not (isOnDeck and inContinue[it.ratingKey]) then items[#items + 1] = it end
        end
        if #items > 0 then
            rows[#rows + 1] = { title = hub.title or "", kind = W.kindFor(items[1], hub), items = items, hub = hub }
        end
    end
    for _, r in ipairs(rows) do
        r.col, r.scroll, r.anim = 1, 0, {}
        if r.title == prevTitle then r.col = math.min(prevCol or 1, #r.items) end
    end
    self.rows = rows

    -- Hero: recent items with backdrop art, not the in-progress row.
    local hero, seen = {}, {}
    for _, r in ipairs(rows) do
        if r.kind == "poster" then
            for _, it in ipairs(r.items) do
                local key = it.ratingKey
                if it.art and not seen[key] and #hero < HERO_MAX and (it.type == "movie" or it.type == "show") then
                    seen[key] = true
                    hero[#hero + 1] = it
                end
            end
        end
    end
    if #self.heroItems == 0 then self.heroItems = hero; self.heroIndex = 1 end

    self.tabs = { { label = "Home", active = true }, { label = "Search", search = true } }
    for _, s in ipairs(sections) do
        if s.type == "movie" or s.type == "show" then
            self.tabs[#self.tabs + 1] = { label = s.title, section = s }
        end
    end
    self.tabs[#self.tabs + 1] = { label = "Account", profile = true }   -- avatar, top right

    if self.focusRow > #rows + 1 then self.focusRow = math.max(1, #rows + 1) end
end

---------------------------------------------------------------------------
-- Layout (all values scale with gfx.unit()).

function Home:metrics()
    local w, h = love.graphics.getDimensions()
    local u = gfx.unit()
    local m = {
        u = u, w = w, h = h,
        pad = 70 * u,
        heroH = h * 0.72,
        rowGap = 56 * u,
        titleH = 50 * u,
        posterW = 200 * u,
        wideW = 400 * u,
        cardGap = 22 * u,
    }
    m.posterH = m.posterW * W.POSTER_ASPECT
    m.wideH = m.wideW * W.WIDE_ASPECT
    return m
end

function Home:rowHeight(row, m)
    local ch = row.kind == "wide" and m.wideH or m.posterH
    local extra = row.kind == "wide" and 0 or 64 * m.u   -- room for the focused title
    return m.titleH + ch + extra + m.rowGap
end

-- y (content space) where each row starts.
function Home:rowY(i, m)
    local y = m.heroH - 150 * m.u
    for r = 1, i - 1 do y = y + self:rowHeight(self.rows[r], m) end
    return y
end

---------------------------------------------------------------------------

function Home:currentHero()
    return self.heroItems[self.heroIndex]
end

function Home:focusedItem()
    if self.focusRow >= 2 then
        local row = self.rows[self.focusRow - 1]
        return row and row.items[row.col]
    end
    return self:currentHero()
end

function Home:update(dt)
    local m = self:metrics()

    -- hero rotation (paused while the hero buttons have focus)
    if #self.heroItems > 1 and self.focusRow ~= 1 then
        self.heroTimer = self.heroTimer + dt
        if self.heroTimer > HERO_ROTATE then
            self.heroTimer = 0
            self.heroIndex = self.heroIndex % #self.heroItems + 1
            self.heroFade = 0
        end
    end
    self.heroFade = math.min(1, self.heroFade + dt * 2)

    -- vertical scroll: nav/hero at top; rows bring the focused row under the nav bar.
    -- With the mouse the wheel owns scrolling and hover never moves the page.
    if not self.mouseScroll then
        if self.focusRow <= 1 then
            self.scrollTarget = 0
        else
            self.scrollTarget = math.max(0, self:rowY(self.focusRow - 1, m) - 150 * m.u)
        end
    end
    self.scrollY = gfx.approach(self.scrollY, self.scrollTarget, dt, 12)

    -- horizontal scroll per row: keep the focused card in view, Netflix-style left anchor
    for i, row in ipairs(self.rows) do
        local cw = (row.kind == "wide" and m.wideW or m.posterW) + m.cardGap
        local visible = math.max(1, math.floor((m.w - 2 * m.pad) / cw))
        local target = row.scroll
        -- keep the focused card in view, unless the pointer picked it (then the row stays put)
        if not self.pointerFocus then
            if row.col - 1 < target then target = row.col - 1 end
            if row.col > target + visible - 1 then target = row.col - visible + 1 end
        end
        row.scrollTarget = math.max(0, target)
        row.scroll = row.scrollTarget
        row.visible = visible
        row.scrollAnim = gfx.approach(row.scrollAnim or 0, row.scrollTarget * cw, dt, 14)
        for c = 1, #row.items do
            local want = (self.focusRow - 1 == i and row.col == c) and 1 or 0
            row.anim[c] = gfx.approach(row.anim[c] or 0, want, dt, 16)
        end
    end
    self.anim.nav = gfx.approach(self.anim.nav, self.focusRow == 0 and 1 or 0, dt, 16)
    for b = 1, 2 do
        self.anim.heroBtn[b] = gfx.approach(self.anim.heroBtn[b] or 0,
            (self.focusRow == 1 and self.heroButton == b) and 1 or 0, dt, 16)
    end

    -- background follows focus
    local item = self:focusedItem()
    if item then self.backdrop:set(self.server, item.art or item.grandparentArt) end
    self.backdrop:update(dt)
end

function Home:open(item)
    if not item then return end
    app.push(require("ui.detail").new(self.server, item))
end

function Home:play(item)
    if not item then return end
    if api.isPlayable(item) then
        api.metadata(self.server, item.ratingKey, function(full, err)
            if not full then return app.notify(tostring(err), "error") end
            app.push(require("player.scene").new(self.server, full))
        end)
    else
        self:open(item)
    end
end

-- The arrows at a row's ends: move it by a screenful less one card.
function Home:pageRow(row, dir)
    local visible = row.visible or 1
    self.pointerFocus, self.mouseScroll = true, true
    row.scroll = math.max(0, math.min(row.scroll + dir * math.max(1, visible - 1), #row.items - visible))
end

function Home:maxScroll(m)
    local n = #self.rows
    if n == 0 then return 0 end
    return math.max(0, self:rowY(n, m) + self:rowHeight(self.rows[n], m) - m.h + 40 * m.u)
end

function Home:wheel(dx, dy)
    if dy == 0 then return end
    local m = self:metrics()
    self.mouseScroll = true
    self.scrollTarget = math.max(0, math.min(self:maxScroll(m), self.scrollTarget - dy * 170 * m.u))
end

function Home:action(a)
    self.mouseScroll = false   -- keyboard/controller takes over scrolling again
    self.pointerFocus = false
    local nRows = #self.rows
    if self.focusRow == 0 then
        if a == "left" then self.navIndex = math.max(1, self.navIndex - 1)
        elseif a == "right" then self.navIndex = math.min(#self.tabs, self.navIndex + 1)
        elseif a == "down" then self.focusRow = 1
        elseif a == "accept" then self:openTab(self.tabs[self.navIndex])
        elseif a == "back" then self.focusRow = 1 end
        return
    end

    if a == "up" then
        self.focusRow = self.focusRow - 1
        if self.focusRow == 0 then self.navIndex = 1 end
    elseif a == "down" then
        self.focusRow = math.min(nRows + 1, self.focusRow + 1)
    elseif self.focusRow == 1 then
        local hero = self:currentHero()
        if a == "left" then
            if self.heroButton > 1 then self.heroButton = self.heroButton - 1
            elseif #self.heroItems > 1 then
                self.heroIndex = (self.heroIndex - 2) % #self.heroItems + 1; self.heroFade = 0
            end
        elseif a == "right" then
            if self.heroButton < 2 then self.heroButton = self.heroButton + 1
            elseif #self.heroItems > 1 then
                self.heroIndex = self.heroIndex % #self.heroItems + 1; self.heroFade = 0
            end
        elseif a == "accept" then
            if self.heroButton == 1 then self:playHero(hero) else self:open(hero) end
        elseif a == "playpause" then
            self:playHero(hero)
        elseif a == "back" then
            self.focusRow = 0
        end
    else
        local row = self.rows[self.focusRow - 1]
        if not row then return end
        if a == "left" then row.col = math.max(1, row.col - 1)
        elseif a == "right" then row.col = math.min(#row.items, row.col + 1)
        elseif a == "accept" then self:open(row.items[row.col])
        elseif a == "playpause" then self:play(row.items[row.col])
        elseif a == "back" then self.focusRow = 1
        end
    end
end

-- Play from the hero: movies play directly, shows open their page.
function Home:playHero(item)
    if not item then return end
    if item.type == "movie" then self:play(item) else self:open(item) end
end

function Home:openTab(tab)
    if not tab or tab.active then return end
    if tab.search then
        app.push(require("ui.search").new(self.server))
    elseif tab.profile then
        app.push(require("ui.profile").new(self.server))
    elseif tab.section then
        app.push(require("ui.library").new(self.server, tab.section))
    end
end

---------------------------------------------------------------------------

function Home:drawHero(m, y0)
    local hero = self:currentHero()
    local u = m.u
    if not hero then return end
    local img = W.itemImage(self.server, hero.art, m.w, m.heroH)
    if img then
        gfx.drawCover(img, 0, y0, m.w, m.heroH, self.heroFade, 0.5, 0.25)
    end
    -- readability gradients: left side and bottom fade into the page
    gfx.hgradient(0, y0, m.w * 0.65, m.heroH, theme.bg, 0.95, 0)
    gfx.vgradient(0, y0 + m.heroH * 0.45, m.w, m.heroH * 0.55 + 2, theme.bg, 0, 1)

    local x = m.pad
    local ty = y0 + m.heroH * 0.30
    local maxW = m.w * 0.42
    local a = self.heroFade
    local kind = hero.type == "show" and "SERIES" or "FILM"
    gfx.color(theme.accent, a)
    gfx.text(kind, x, ty - 36 * u, 20 * u, theme.accent, a)
    local titleH = gfx.wrapped(hero.title or "", x, ty, maxW, 64 * u, theme.text, 2, a)
    local meta = {}
    if hero.year then meta[#meta + 1] = tostring(hero.year) end
    if hero.contentRating then meta[#meta + 1] = hero.contentRating end
    if hero.type == "movie" and hero.duration then
        meta[#meta + 1] = api.runtime(hero.duration)
    elseif hero.childCount then
        meta[#meta + 1] = hero.childCount .. (tonumber(hero.childCount) == 1 and " Season" or " Seasons")
    end
    if hero.audienceRating then meta[#meta + 1] = ("%.1f/10"):format(hero.audienceRating) end
    gfx.text(table.concat(meta, "   ·   "), x, ty + titleH + 12 * u, 24 * u, theme.textDim, a)
    gfx.wrapped(hero.summary or "", x, ty + titleH + 56 * u, maxW, 23 * u, theme.text, 3, 0.85 * a)

    local by = ty + titleH + 56 * u + 3 * gfx.font(23 * u):getHeight() + 30 * u
    local bh = 62 * u
    local playLabel = hero.type == "movie" and ((api.progress(hero) or 0) > 0.01 and "Resume" or "Play") or "Episodes"
    local bw = W.button(playLabel, x, by, bh, self.anim.heroBtn[1] or 0,
        { primary = true, icon = hero.type == "movie" and "play" or nil, progress = api.progress(hero) })
    local bw2 = W.button("More Info", x + bw + 18 * u, by, bh, self.anim.heroBtn[2] or 0, { icon = "info" })
    mouse.region(x, by, bw, bh, {
        hover = function() self.mouseScroll = true; self.focusRow, self.heroButton = 1, 1 end,
        click = function() self:playHero(hero) end })
    mouse.region(x + bw + 18 * u, by, bw2, bh, {
        hover = function() self.mouseScroll = true; self.focusRow, self.heroButton = 1, 2 end,
        click = function() self:open(hero) end })

    -- rotation dots (clickable)
    if #self.heroItems > 1 then
        local dx = m.w - m.pad - #self.heroItems * 22 * u
        for i = 1, #self.heroItems do
            local cx = dx + (i - 1) * 22 * u
            gfx.color(i == self.heroIndex and theme.text or theme.textDim, i == self.heroIndex and 1 or 0.5)
            love.graphics.circle("fill", cx, by + bh / 2, (i == self.heroIndex and 6 or 4) * u)
            mouse.region(cx - 11 * u, by + bh / 2 - 14 * u, 22 * u, 28 * u, {
                click = function()
                    if self.heroIndex ~= i then self.heroIndex, self.heroFade, self.heroTimer = i, 0, 0 end
                end })
        end
    end
end

function Home:draw()
    local m = self:metrics()
    local u = m.u
    love.graphics.clear(theme.bg)

    -- dim full-screen backdrop of whatever has focus (behind the rows)
    if self.focusRow >= 2 then
        self.backdrop:draw(0, 0, m.w, m.h, 0.22, 0.2)
        gfx.vgradient(0, 0, m.w, m.h, theme.bg, 0.5, 0.95)
    end

    local y0 = -self.scrollY
    if y0 + m.heroH > 0 then self:drawHero(m, y0) end

    for i, row in ipairs(self.rows) do
        local ry = self:rowY(i, m) - self.scrollY
        local rh = self:rowHeight(row, m)
        if ry + rh > 0 and ry < m.h then
            local focused = self.focusRow - 1 == i
            gfx.text(row.title, m.pad, ry, 30 * u, focused and theme.text or theme.textDim)
            local cw = row.kind == "wide" and m.wideW or m.posterW
            local ch = row.kind == "wide" and m.wideH or m.posterH
            local cy = ry + m.titleH
            local first = math.max(1, math.floor((row.scrollAnim or 0) / (cw + m.cardGap)))
            -- whole row: horizontal wheel / Shift+wheel steps through it
            mouse.region(0, ry, m.w, rh, { wheel = function(dx)
                if dx == 0 then return false end
                self.pointerFocus = false
                self.focusRow = i + 1
                row.col = math.max(1, math.min(#row.items, row.col + (dx > 0 and 1 or -1)))
                return true
            end })
            -- draw unfocused cards first so the focused one overlaps its neighbours
            local focusedCol = W.topCard(row.anim, first, #row.items)
            for c = first, #row.items do
                local cx = m.pad + (c - 1) * (cw + m.cardGap) - (row.scrollAnim or 0)
                if cx > m.w then break end
                if c ~= focusedCol then W.card(self.server, row.items[c], cx, cy, cw, ch, row.anim[c] or 0, row.kind) end
                local item = row.items[c]
                mouse.region(cx, cy, cw, ch, {
                    hover = function() self.mouseScroll = true; self.focusRow, row.col, self.pointerFocus = i + 1, c, true end,
                    click = function() self:open(item) end,
                })
            end
            if focusedCol then
                local cx = m.pad + (focusedCol - 1) * (cw + m.cardGap) - (row.scrollAnim or 0)
                W.card(self.server, row.items[focusedCol], cx, cy, cw, ch, row.anim[focusedCol], row.kind)
            end
            -- edge fade hints that a row continues
            if (row.scrollAnim or 0) > 1 then gfx.hgradient(0, cy - 10 * u, m.pad, ch + 20 * u, theme.bg, 0.9, 0) end
            W.rowArrows(0, cy, m.w, ch, (row.scrollAnim or 0) / (cw + m.cardGap), #row.items, row.visible or 1,
                function(dir) self:pageRow(row, dir) end)
        end
    end

    if self.loading and #self.rows == 0 then
        gfx.spinner(m.w / 2, m.h * 0.55, 30 * u)
    elseif self.error and #self.rows == 0 then
        gfx.textCentered("Couldn't load " .. self.server.name .. ": " .. tostring(self.error), m.w / 2, m.h / 2, 26 * u, theme.danger)
    end

    -- solid header once the page scrolls, so rows don't show through the nav
    local solid = math.min(1, self.scrollY / (120 * u))
    if solid > 0 then
        love.graphics.setColor(theme.bg[1], theme.bg[2], theme.bg[3], solid)
        love.graphics.rectangle("fill", 0, 0, m.w, 100 * u)
        gfx.vgradient(0, 100 * u, m.w, 40 * u, theme.bg, solid, 0)
    end
    W.navBar(self.tabs, self.focusRow == 0 and self.navIndex or 1, self.focusRow == 0, self.anim.nav,
        self.server.name)
    mouse.region(0, 0, m.w, 100 * u, { block = true })   -- header hides rows scrolled beneath it
    for t, tab in ipairs(self.tabs) do
        if tab._x then
            mouse.region(tab._x - 16 * u, 26 * u, tab._w + 32 * u, 54 * u, {
                hover = function() self.mouseScroll = true; self.focusRow, self.navIndex = 0, t end,
                click = function() self:openTab(tab) end,
            })
        end
    end
end

return Home
