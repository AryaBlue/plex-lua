-- A library section as a poster grid, loaded page by page as you scroll.
-- Sort with the menu button (Tab / Y).

local theme = require("theme")
local gfx = require("ui.gfx")
local W = require("ui.widgets")
local api = require("plex.api")
local mouse = require("ui.mouse")

local Library = {}
Library.__index = Library

local PAGE = 120
local SORTS = {
    { key = "titleSort", label = "A-Z" },
    { key = "addedAt:desc", label = "Recently Added" },
    { key = "originallyAvailableAt:desc", label = "Release Date" },
    { key = "audienceRating:desc", label = "Rating" },
}

function Library.new(server, section)
    return setmetatable({
        server = server, section = section,
        items = {}, total = nil, loadingFrom = nil,
        sel = 1, sortIndex = 1,
        scrollY = 0, anim = {},
        backdrop = W.newBackdrop(),
        searchable = true,
    }, Library)
end

function Library:enter() self:reload() end

function Library:reload()
    self.items, self.total, self.sel, self.anim = {}, nil, 1, {}
    self.generation = (self.generation or 0) + 1
    self:loadMore()
end

function Library:loadMore()
    local start = #self.items
    if self.loadingFrom == start or (self.total and start >= self.total) then return end
    self.loadingFrom = start
    local gen = self.generation
    api.sectionItems(self.server, self.section.key, SORTS[self.sortIndex].key, start, PAGE, function(items, total)
        if gen ~= self.generation then return end
        self.loadingFrom = nil
        if not items then self.error = total; return end
        for _, it in ipairs(items) do self.items[#self.items + 1] = it end
        self.total = total > 0 and total or #self.items
    end)
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
             rowH = ch + 90 * u, top = 190 * u }
end

function Library:wheel(dx, dy)
    if dy == 0 then return end
    local g = self:grid()
    local rows = math.ceil(#self.items / g.cols)
    local maxScroll = math.max(0, rows * g.rowH - (g.h - g.top) + 60 * g.u)
    self.mouseScroll = true
    self.scrollTarget = math.max(0, math.min(maxScroll, (self.scrollTarget or self.scrollY) - dy * g.rowH * 0.6))
end

function Library:nextSort()
    self.sortIndex = self.sortIndex % #SORTS + 1
    self.scrollTarget, self.mouseScroll = 0, false
    self:reload()
end

function Library:action(a)
    self.mouseScroll = false
    local g = self:grid()
    local n = #self.items
    if a == "back" then return app.pop() end
    if a == "left" then self.sel = math.max(1, self.sel - 1)
    elseif a == "right" then self.sel = math.min(n, self.sel + 1)
    elseif a == "up" then self.sel = math.max(1, self.sel - g.cols)
    elseif a == "down" then
        if self.sel + g.cols <= n then self.sel = self.sel + g.cols
        elseif math.ceil(self.sel / g.cols) < math.ceil(n / g.cols) then self.sel = n end
    elseif a == "accept" and self.items[self.sel] then
        app.push(require("ui.detail").new(self.server, self.items[self.sel]))
    elseif a == "menu" then
        self:nextSort()
    end
end

function Library:update(dt)
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
        self.anim[i] = gfx.approach(self.anim[i] or 0, i == self.sel and 1 or 0, dt, 16)
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
                hover = function() self.sel = i; self.mouseScroll = true end,
                click = function() app.push(require("ui.detail").new(self.server, it)) end,
            })
        end
    end
    if focusedIdx then
        local r, c = math.floor((focusedIdx - 1) / g.cols), (focusedIdx - 1) % g.cols
        W.card(self.server, self.items[focusedIdx], g.pad + c * (g.cw + g.gap), g.top + r * g.rowH - self.scrollY,
            g.cw, g.ch, self.anim[focusedIdx], "poster")
    end

    -- header over the grid
    gfx.vgradient(0, 0, g.w, g.top + 10 * u, theme.bg, 1, 0.0)
    love.graphics.setColor(theme.bg)
    love.graphics.rectangle("fill", 0, 0, g.w, g.top - 50 * u)
    local hx = g.pad + 76 * u          -- header text starts right of the back button
    gfx.color(theme.accent)
    gfx.roundRect("fill", hx, 52 * u, 7 * u, 46 * u, 3 * u)
    gfx.text(self.section.title or "Library", hx + 20 * u, 44 * u, 50 * u)
    local count = self.total and ("%d titles"):format(self.total) or "Loading…"
    local sortText = "Sorted by " .. SORTS[self.sortIndex].label
    local countText = count .. "   ·   "
    gfx.text(countText, hx + 20 * u, 108 * u, 22 * u, theme.textDim)
    local sx = hx + 20 * u + gfx.width(countText, 22 * u)
    gfx.text(sortText, sx, 108 * u, 22 * u, theme.text)
    mouse.region(0, 0, g.w, g.top - 40 * u, { block = true })   -- header hides cards scrolled beneath it
    mouse.region(sx - 8 * u, 102 * u, gfx.width(sortText, 22 * u) + 16 * u, 36 * u, { click = function() self:nextSort() end })
    W.backButton(g.pad - 6 * u, 47 * u, 56 * u, false, function() app.pop() end)

    if self.error then
        gfx.textCentered("Couldn't load: " .. tostring(self.error), g.w / 2, g.h / 2, 26 * u, theme.danger)
    elseif #self.items == 0 then
        gfx.spinner(g.w / 2, g.h / 2, 30 * u)
    end
end

return Library
