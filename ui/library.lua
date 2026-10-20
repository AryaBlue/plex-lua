-- A library section as a poster grid, loaded page by page as you scroll.
--
-- Toolbar under the title, after Plex's DirectoryListToolbar: dropdown pills
-- for Genre and Sort (a ✕ next to Genre clears it), the title count on the
-- right. A pill opens a dropdown menu like Plex's DirectoryListFilterMenu: a
-- small uppercase heading, a filter box you type into (genres), the options
-- with the current one in the accent colour and ticked. Up from the top row
-- of posters reaches the toolbar. The menu button (Tab / Y) opens a poster's
-- options (ui/itemmenu.lua), or Sort from the toolbar.
-- Genres come from /library/sections/{id}/genre. Sort "For You" ranks the
-- titles by your watch history (plex/recommend.lua), all at once rather than
-- page by page, with the reason under the focused poster.

local theme = require("theme")
local gfx = require("ui.gfx")
local W = require("ui.widgets")
local api = require("plex.api")
local mouse = require("ui.mouse")
local input = require("lib.input")
local utf8 = require("utf8")

local Library = {}
Library.__index = Library

local PAGE = 120
local SORTS = {
    { key = "forYou", label = "For You", ranked = true },
    { key = "titleSort", label = "Title" },
    { key = "addedAt:desc", label = "Date Added" },
    { key = "originallyAvailableAt:desc", label = "Release Date" },
    { key = "audienceRating:desc", label = "Rating" },
}

-- genre (optional): { id, title } to start filtered (e.g. a genre from Search).
function Library.new(server, section, genre)
    return setmetatable({
        server = server, section = section, genre = genre,
        items = {}, total = nil, loadingFrom = nil,
        sel = 1, sortIndex = 2,
        header = nil,            -- focused toolbar control: "genre", "clear" or "sort"
        menu = nil,              -- open dropdown (see openMenu)
        pills = {},              -- toolbar control rectangles from the last draw
        pillAnim = {},
        scrollY = 0, anim = {},
        backdrop = W.newBackdrop(),
        searchable = true,
    }, Library)
end

function Library:enter()
    self:reload()
    api.genres(self.server, self.section.key, function(list) self.genres = list end)
end

function Library:reload()
    self.items, self.total, self.sel, self.anim, self.error = {}, nil, 1, {}, nil
    self.generation = (self.generation or 0) + 1
    self:loadMore()
end

function Library:loadMore()
    local start = #self.items
    if self.loadingFrom == start or (self.total and start >= self.total) then return end
    self.loadingFrom = start
    local gen = self.generation
    if SORTS[self.sortIndex].ranked then
        if start > 0 then return end
        self.basedOn = nil
        return require("plex.recommend").forSection(self.server, self.section, function(items, info)
            if gen ~= self.generation then return end
            self.loadingFrom = nil
            if not items then self.error = info; return end
            self.items, self.total, self.basedOn = items, #items, info.watched
        end, self.genre and self.genre.id)
    end
    api.sectionItems(self.server, self.section.key, SORTS[self.sortIndex].key, start, PAGE, function(items, total)
        if gen ~= self.generation then return end
        self.loadingFrom = nil
        if not items then self.error = total; return end
        for _, it in ipairs(items) do self.items[#self.items + 1] = it end
        self.total = total > 0 and total or #self.items
    end, self.genre and self.genre.id)
end

function Library:grid()
    local w, h = love.graphics.getDimensions()
    local u = gfx.unit()
    local pad = 70 * u
    local gap = 26 * u
    local cols = math.max(3, math.floor((w - 2 * pad + gap) / (190 * u + gap)))
    local cw = (w - 2 * pad - (cols - 1) * gap) / cols
    local ch = cw * W.POSTER_ASPECT
    return { u = u, w = w, h = h, pad = pad, gap = gap, cols = cols, cw = cw, ch = ch,
             rowH = ch + 90 * u, top = 200 * u }
end

function Library:wheel(dx, dy)
    if dy == 0 or self.menu then return end
    local g = self:grid()
    local rows = math.ceil(#self.items / g.cols)
    local maxScroll = math.max(0, rows * g.rowH - (g.h - g.top) + 60 * g.u)
    self.mouseScroll = true
    self.scrollTarget = math.max(0, math.min(maxScroll, (self.scrollTarget or self.scrollY) - dy * g.rowH * 0.6))
end

function Library:setSort(i)
    if i == self.sortIndex then return end
    self.sortIndex = i
    self.scrollTarget, self.mouseScroll = 0, false
    self:reload()
end

function Library:setGenre(g)
    if (g and g.id) == (self.genre and self.genre.id) then return end
    self.genre = g
    self.scrollTarget, self.mouseScroll = 0, false
    if not g and self.header == "clear" then self.header = "genre" end
    self:reload()
end

---------------------------------------------------------------------------
-- Dropdown menu: { kind, title, options = { {label, value} }, current, sel,
-- scroll, filter, open (0..1 animation), anchor = pill rect }

function Library:openMenu(kind)
    local m = { kind = kind, sel = 1, scroll = 0, filter = "", open = 0, anim = {},
                anchor = self.pills[kind] }
    if kind == "genre" then
        if not self.genres then return app.notify("Genres are still loading…") end
        m.title = "Genre"
        m.all = { { label = "All " .. (self.section.title or ""), value = false } }
        for _, g in ipairs(self.genres) do m.all[#m.all + 1] = { label = g.title, value = g } end
        m.current = self.genre and self.genre.id or false
    else
        m.title = "Sort by"
        m.all = {}
        for i, s in ipairs(SORTS) do m.all[#m.all + 1] = { label = s.label, value = i } end
        m.current = self.sortIndex
    end
    self.menu = m
    self:filterMenu()
    for i, o in ipairs(m.options) do
        if self:isCurrent(o) then m.sel = i end
    end
end

function Library:isCurrent(o)
    local m = self.menu
    if m.kind == "genre" then return (o.value and o.value.id or false) == m.current end
    return o.value == m.current
end

-- Options matching what's been typed (genres only).
function Library:filterMenu()
    local m = self.menu
    local q = m.filter:lower()
    m.options = {}
    for _, o in ipairs(m.all) do
        if q == "" or (o.value and o.label:lower():find(q, 1, true)) then m.options[#m.options + 1] = o end
    end
    m.sel = math.max(1, math.min(m.sel, #m.options))
end

function Library:chooseMenu(i)
    local m = self.menu
    local o = m and m.options[i]
    self.menu = nil
    if not o then return end
    if m.kind == "genre" then self:setGenre(o.value or nil) else self:setSort(o.value) end
end

function Library:menuAction(a)
    local m = self.menu
    m.mouse = false
    if a == "back" or a == "menu" or a == "left" or a == "right" then self.menu = nil
    elseif a == "accept" then self:chooseMenu(m.sel)
    elseif a == "up" then m.sel = math.max(1, m.sel - 1)
    elseif a == "down" then m.sel = math.min(#m.options, m.sel + 1)
    end
end

-- Typing filters the genre list (the key itself arrives through textinput).
function Library:keypressed(key)
    local m = self.menu
    if not m or m.kind ~= "genre" then return false end
    if key == "backspace" then
        local off = utf8.offset(m.filter, -1)
        if off then m.filter = m.filter:sub(1, off - 1); self:filterMenu() end
        return true
    end
    return #key == 1 or key == "space"
end

function Library:textinput(t)
    local m = self.menu
    if not m or m.kind ~= "genre" then return end
    m.filter = m.filter .. t
    m.sel = 1
    self:filterMenu()
end

local ROW_H, MENU_W = 50, 340

function Library:menuLayout()
    local m = self.menu
    local u = gfx.unit()
    local h = love.graphics.getHeight()
    local a = m.anchor or { x = 70 * u, y = 100 * u, w = 0, h = 40 * u }
    local x, y = a.x, a.y + a.h + 10 * u
    local headH = m.kind == "genre" and 112 * u or 58 * u
    local listH = math.min(#m.options * ROW_H * u, h - y - headH - 40 * u)
    listH = math.max(listH, ROW_H * u)
    return { u = u, x = x, y = y, w = MENU_W * u, headH = headH, listH = listH, rowH = ROW_H * u,
             h = headH + listH + 12 * u }
end

function Library:updateMenu(dt)
    local m = self.menu
    m.open = gfx.approach(m.open, 1, dt, 20)
    local L = self:menuLayout()
    local maxScroll = math.max(0, #m.options * L.rowH - L.listH)
    if not m.mouse then
        local top = (m.sel - 1) * L.rowH
        local target = m.scroll
        if top < target then target = top
        elseif top + L.rowH > target + L.listH then target = top + L.rowH - L.listH end
        m.scroll = gfx.approach(m.scroll, target, dt, 18)
    end
    m.scroll = math.max(0, math.min(maxScroll, m.scroll))
    m.maxScroll = maxScroll
end

local function chevron(x, y, s, color, alpha)
    gfx.color(color, alpha)
    love.graphics.setLineWidth(math.max(1.5, s * 0.22))
    love.graphics.line(x - s * 0.45, y - s * 0.2, x, y + s * 0.25, x + s * 0.45, y - s * 0.2)
end

local function tick(x, y, s, color, alpha)
    gfx.color(color, alpha)
    love.graphics.setLineWidth(math.max(2, s * 0.2))
    love.graphics.line(x - s * 0.5, y, x - s * 0.15, y + s * 0.35, x + s * 0.5, y - s * 0.35)
end

function Library:drawMenu()
    local m, L = self.menu, self:menuLayout()
    local u, a = L.u, m.open
    local x, y = L.x, L.y - (1 - a) * 10 * u
    local w = love.graphics.getWidth()
    local h = love.graphics.getHeight()
    mouse.region(0, 0, w, h, { click = function() self.menu = nil end, wheel = function() return true end })

    gfx.color({ 0, 0, 0 }, 0.4 * a)
    gfx.roundRect("fill", x - 2 * u, y + 6 * u, L.w + 4 * u, L.h + 4 * u, 14 * u)
    gfx.color(theme.surface, 0.98 * a)
    gfx.roundRect("fill", x, y, L.w, L.h, 12 * u)
    mouse.region(x, y, L.w, L.h, { click = function() end, wheel = function(_, dy)
        m.mouse = true
        m.scroll = math.max(0, math.min(m.maxScroll or 0, m.scroll - dy * L.rowH * 1.5))
        return true
    end })

    -- heading, as Plex's: small, uppercase, faint
    gfx.text(m.title:upper(), x + 22 * u, y + 20 * u, 17 * u, theme.textDim, a)
    if m.kind == "genre" then
        -- filter box
        local fx, fy, fw, fh = x + 14 * u, y + 52 * u, L.w - 28 * u, 46 * u
        gfx.color(theme.text, 0.07 * a)
        gfx.roundRect("fill", fx, fy, fw, fh, fh / 2)
        local ty = fy + (fh - gfx.font(20 * u):getHeight()) / 2
        if m.filter == "" then
            gfx.text("Type to filter", fx + 22 * u, ty, 20 * u, theme.textDim, 0.7 * a)
        else
            local shown = gfx.fit(m.filter, 20 * u, fw - 50 * u)
            gfx.text(shown, fx + 22 * u, ty, 20 * u, theme.text, a)
            if love.timer.getTime() % 1 < 0.55 then
                gfx.color(theme.accent, a)
                love.graphics.rectangle("fill", fx + 24 * u + gfx.width(shown, 20 * u), fy + 11 * u, 2 * u, fh - 22 * u)
            end
        end
    end
    gfx.color(theme.text, 0.08 * a)
    love.graphics.rectangle("fill", x + 14 * u, y + L.headH - 6 * u, L.w - 28 * u, 1)

    local listTop = y + L.headH
    if #m.options == 0 then
        gfx.textCentered("No genres match", x + L.w / 2, listTop + 12 * u, 20 * u, theme.textDim, a)
        return
    end
    love.graphics.setScissor(x, listTop, L.w, L.listH)
    local first = math.max(1, math.floor(m.scroll / L.rowH) + 1)
    for i = first, math.min(#m.options, first + math.ceil(L.listH / L.rowH)) do
        local o = m.options[i]
        local ry = listTop + (i - 1) * L.rowH - m.scroll
        local focused = i == m.sel
        local current = self:isCurrent(o)
        if focused then
            gfx.color(theme.text, 0.09 * a)
            love.graphics.rectangle("fill", x, ry, L.w, L.rowH)
            gfx.color(theme.accent, a)
            love.graphics.rectangle("fill", x, ry + 10 * u, 4 * u, L.rowH - 20 * u)
        end
        local col = current and theme.accent or (focused and theme.text or theme.textDim)
        local f = gfx.font(21 * u, o.label)
        gfx.text(gfx.fit(o.label, 21 * u, L.w - 90 * u), x + 24 * u,
            math.floor(ry + L.rowH / 2 - (f:getBaseline() - 21 * u * 0.35) + 0.5), 21 * u, col, a)
        if current then tick(x + L.w - 32 * u, ry + L.rowH / 2, 16 * u, theme.accent, a) end
        if ry >= listTop - 1 and ry + L.rowH <= listTop + L.listH + 1 then
            mouse.region(x, ry, L.w, L.rowH, {
                hover = function() m.sel, m.mouse = i, true end,
                click = function() self:chooseMenu(i) end,
            })
        end
    end
    love.graphics.setScissor()
    -- fade at the bottom edge when more is below
    if m.scroll < (m.maxScroll or 0) - 1 then
        gfx.vgradient(x, listTop + L.listH - 30 * u, L.w, 30 * u, theme.surface, 0, a)
    end
end

---------------------------------------------------------------------------
-- Toolbar

-- Controls in order, for left/right.
function Library:controls()
    local c = { "genre" }
    if self.genre then c[#c + 1] = "clear" end
    c[#c + 1] = "sort"
    return c
end

function Library:headerAction(a)
    local list = self:controls()
    local idx = 1
    for i, k in ipairs(list) do if k == self.header then idx = i end end
    if a == "left" then self.header = list[math.max(1, idx - 1)]
    elseif a == "right" then self.header = list[math.min(#list, idx + 1)]
    elseif a == "down" then self.header = nil
    elseif a == "accept" then
        if self.header == "clear" then self:setGenre(nil) else self:openMenu(self.header) end
    end
end

-- A dropdown pill: label (+ value) and a chevron. Returns its width.
local function pill(label, value, x, y, h, focus, hover, active, u)
    local size = 21 * u
    local f = gfx.font(size)
    local lw = f:getWidth(label)
    local vw = value and f:getWidth(value) or 0
    local w = 22 * u + lw + (value and 8 * u + vw or 0) + 46 * u
    gfx.color(active and theme.accentDark or theme.surfaceHi, active and 0.55 or (0.55 + 0.35 * math.max(hover, focus)))
    gfx.roundRect("fill", x, y, w, h, h / 2)
    if active then
        gfx.color(theme.accent, 0.9)
        love.graphics.setLineWidth(1.5 * u)
        gfx.roundRect("line", x, y, w, h, h / 2)
    end
    if focus > 0.01 then
        gfx.color(theme.text, focus)
        love.graphics.setLineWidth(2.5 * u)
        gfx.roundRect("line", x - 3 * u, y - 3 * u, w + 6 * u, h + 6 * u, h / 2 + 3 * u)
    end
    local ty = math.floor(y + h / 2 - (f:getBaseline() - size * 0.35) + 0.5)
    gfx.text(label, x + 22 * u, ty, size, value and theme.textDim or theme.text)
    if value then gfx.text(value, x + 30 * u + lw, ty, size, active and theme.text or theme.text) end
    chevron(x + w - 24 * u, y + h / 2, 12 * u, theme.textDim)
    return w
end

function Library:drawToolbar(g)
    local u = g.u
    local y, h = 104 * u, 42 * u
    local x = g.pad + 96 * u
    local pointer = input.lastDevice == "mouse" and not self.menu
    local open = self.menu and self.menu.kind
    local function state(key, w)
        local hov = pointer and W.pointerIn(x, y, w, h)
        local want = (self.header == key and not self.menu) and 1 or 0
        self.pillAnim[key] = gfx.approach(self.pillAnim[key] or 0, want, love.timer.getDelta(), 18)
        return self.pillAnim[key], (hov or open == key) and 1 or 0
    end

    -- Genre
    local glabel = self.genre and self.genre.title or "All"
    local gw = pill("Genre", glabel, -9999, y, h, 0, 0, false, u)    -- measure
    local f, hv = state("genre", gw)
    gw = pill("Genre", glabel, x, y, h, f, hv, self.genre ~= nil, u)
    self.pills.genre = { x = x, y = y, w = gw, h = h }
    mouse.region(x, y, gw, h, { click = function() self:openMenu("genre") end,
                                hover = function() if not self.menu then self.header = nil end end })
    x = x + gw + 10 * u

    -- clear the genre (Plex's DirectoryToolbarClearFiltersButton)
    if self.genre then
        local cf, chv = state("clear", h)
        local cx, cy, r = x + h / 2, y + h / 2, h / 2
        gfx.color(theme.surfaceHi, 0.55 + 0.35 * math.max(cf, chv))
        love.graphics.circle("fill", cx, cy, r)
        if cf > 0.01 then
            gfx.color(theme.text, cf)
            love.graphics.setLineWidth(2.5 * u)
            love.graphics.circle("line", cx, cy, r + 3 * u)
        end
        gfx.color(theme.text, 0.85)
        love.graphics.setLineWidth(2.5 * u)
        local s = 7 * u
        love.graphics.line(cx - s, cy - s, cx + s, cy + s)
        love.graphics.line(cx - s, cy + s, cx + s, cy - s)
        mouse.region(x, y, h, h, { click = function() self:setGenre(nil) end })
        x = x + h + 10 * u
    end
    x = x + 14 * u

    -- Sort
    local slabel = SORTS[self.sortIndex].label
    local sw = pill("Sort", slabel, -9999, y, h, 0, 0, false, u)
    local sf, shv = state("sort", sw)
    sw = pill("Sort", slabel, x, y, h, sf, shv, false, u)
    self.pills.sort = { x = x, y = y, w = sw, h = h }
    mouse.region(x, y, sw, h, { click = function() self:openMenu("sort") end })

    -- count on the right, as Plex's toolbar info text
    local count = self.total and ("%d %s"):format(self.total, self.total == 1 and "title" or "titles") or "Loading…"
    if self.basedOn and SORTS[self.sortIndex].ranked then
        count = self.basedOn == 0 and "Watch something to get picks · by rating for now"
            or ("Picked from %d %s you've watched · %s"):format(self.basedOn, self.basedOn == 1 and "title" or "titles", count)
    end
    local ff = gfx.font(21 * u)
    gfx.text(count, g.w - g.pad - ff:getWidth(count), math.floor(y + h / 2 - (ff:getBaseline() - 21 * u * 0.35) + 0.5),
        21 * u, theme.textDim)
end

---------------------------------------------------------------------------

function Library:action(a)
    self.mouseScroll = false
    if self.menu then return self:menuAction(a) end
    local g = self:grid()
    local n = #self.items
    if a == "back" then return app.pop() end
    if self.header then
        if a == "menu" then return self:openMenu("sort") end
        return self:headerAction(a)
    end
    if a == "menu" then return self:itemMenu(self.sel) end
    if a == "left" then self.sel = math.max(1, self.sel - 1)
    elseif a == "right" then self.sel = math.min(n, self.sel + 1)
    elseif a == "up" then
        if self.sel <= g.cols then self.header = "genre" else self.sel = self.sel - g.cols end
    elseif a == "down" then
        if self.sel + g.cols <= n then self.sel = self.sel + g.cols
        elseif math.ceil(self.sel / g.cols) < math.ceil(n / g.cols) then self.sel = n end
    elseif a == "accept" and self.items[self.sel] then
        app.push(require("ui.detail").new(self.server, self.items[self.sel]))
    end
end

-- Options for card i (right click, its ⋯ button, or Tab / Y). Marking it
-- updates the card in place.
function Library:itemMenu(i)
    local it = self.items[i]
    if not it then return end
    local g = self:grid()
    local r, c = math.floor((i - 1) / g.cols), (i - 1) % g.cols
    require("ui.itemmenu").open(self.server, it, {
        anchor = { x = g.pad + c * (g.cw + g.gap), y = g.top + r * g.rowH - self.scrollY, w = g.cw, h = g.ch },
    })
end

function Library:update(dt)
    self.searchable = not self.menu       -- typing goes to the genre filter while it's open
    if self.menu then self:updateMenu(dt) end
    if self.header == "clear" and not self.genre then self.header = "genre" end
    local g = self:grid()
    local target
    if self.mouseScroll then
        target = self.scrollTarget
        -- prefetch when the wheel nears the loaded end
        if target + g.h > (math.ceil(#self.items / g.cols) - 3) * g.rowH then self:loadMore() end
    else
        -- prefetch the next page well before reaching the end
        if self.sel > #self.items - g.cols * 3 then self:loadMore() end
        local row = math.floor((self.sel - 1) / g.cols)
        target = math.max(0, row * g.rowH - (g.h - g.top - g.rowH) * 0.35)
        self.scrollTarget = target
    end
    self.scrollY = gfx.approach(self.scrollY, target, dt, 12)
    local first = math.max(1, math.floor(self.scrollY / g.rowH) * g.cols - g.cols + 1)
    for i = first, math.min(#self.items, first + g.cols * 8) do
        self.anim[i] = gfx.approach(self.anim[i] or 0, (i == self.sel and not self.header) and 1 or 0, dt, 16)
    end
    local it = self.items[self.sel]
    if it then self.backdrop:set(self.server, it.art) end
    self.backdrop:update(dt)
end

function Library:draw()
    local g = self:grid()
    local u = g.u
    love.graphics.clear(theme.bg)
    self.backdrop:draw(0, 0, g.w, g.h, 0.18, 0.2)
    gfx.vgradient(0, 0, g.w, g.h, theme.bg, 0.6, 0.95)

    local firstRow = math.max(0, math.floor(self.scrollY / g.rowH) - 1)
    local lastRow = firstRow + math.ceil(g.h / g.rowH) + 2
    local focusedIdx = W.topCard(self.anim, firstRow * g.cols + 1, math.min(#self.items, (lastRow + 1) * g.cols))
    for r = firstRow, lastRow do
        for c = 0, g.cols - 1 do
            local i = r * g.cols + c + 1
            local it = self.items[i]
            if not it then break end
            local x = g.pad + c * (g.cw + g.gap)
            local y = g.top + r * g.rowH - self.scrollY
            if i ~= focusedIdx then W.card(self.server, it, x, y, g.cw, g.ch, self.anim[i] or 0, "poster") end
            mouse.region(x, y, g.cw, g.ch, {
                hover = function() self.sel, self.header = i, nil; self.mouseScroll = true end,
                click = function() app.push(require("ui.detail").new(self.server, it)) end,
                context = function() self:itemMenu(i) end,
            })
        end
    end
    if focusedIdx then
        local r, c = math.floor((focusedIdx - 1) / g.cols), (focusedIdx - 1) % g.cols
        local x, y = g.pad + c * (g.cw + g.gap), g.top + r * g.rowH - self.scrollY
        W.card(self.server, self.items[focusedIdx], x, y, g.cw, g.ch, self.anim[focusedIdx], "poster")
        W.moreButton(x, y, g.cw, g.ch, self.anim[focusedIdx], "poster", function() self:itemMenu(focusedIdx) end)
    end

    -- header over the grid
    gfx.vgradient(0, 0, g.w, g.top + 10 * u, theme.bg, 1, 0.0)
    love.graphics.setColor(theme.bg)
    love.graphics.rectangle("fill", 0, 0, g.w, g.top - 40 * u)
    local hx = g.pad + 76 * u          -- header text starts right of the back button
    gfx.color(theme.accent)
    gfx.roundRect("fill", hx, 40 * u, 7 * u, 46 * u, 3 * u)
    gfx.text(self.section.title or "Library", hx + 20 * u, 32 * u, 50 * u)
    mouse.region(0, 0, g.w, g.top - 30 * u, { block = true })   -- header hides cards scrolled beneath it
    W.backButton(g.pad - 6 * u, 35 * u, 56 * u, false, function() app.pop() end)
    self:drawToolbar(g)

    if self.error then
        gfx.textCentered("Couldn't load: " .. tostring(self.error), g.w / 2, g.h / 2, 26 * u, theme.danger)
    elseif self.total == 0 then
        gfx.textCentered("Nothing in " .. (self.genre and self.genre.title or "this library") .. " yet",
            g.w / 2, g.h / 2, 26 * u, theme.textDim)
    elseif #self.items == 0 then
        gfx.spinner(g.w / 2, g.h / 2, 30 * u)
    end
    if self.menu then self:drawMenu() end
end

return Library
