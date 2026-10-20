-- An actor's page, opened from a title's Cast row: their portrait and name,
-- then one row per film / TV library of what they're in on this server
-- (/library/sections/{id}/all?actor=, newest first).

local theme = require("theme")
local gfx = require("ui.gfx")
local W = require("ui.widgets")
local api = require("plex.api")
local mouse = require("ui.mouse")

local Person = {}
Person.__index = Person

-- person: a metadata Role { id, tag, thumb, role }
function Person.new(server, person)
    return setmetatable({
        server = server, person = person,
        rows = nil,              -- { { title, items, col, scroll, visible } }
        row = 1, anim = {}, scrollY = 0, scrollTarget = 0,
        backdrop = W.newBackdrop(),
    }, Person)
end

function Person:enter()
    self:load()
end

function Person:load()
    api.byActor(self.server, self.person.id, function(rows, err)
        if not rows then self.error = err; return end
        for _, r in ipairs(rows) do r.col, r.scroll, r.visible = 1, 0, 6 end
        self.rows = rows
        self.row = math.min(self.row, math.max(1, #rows))
        local first = rows[1] and rows[1].items[1]
        if first then self.backdrop:set(self.server, first.art) end
    end)
end

function Person:resume()
    if self.rows then self:load() end    -- watched state may have changed
end

function Person:open(item)
    app.push(require("ui.detail").new(self.server, item))
end

function Person:itemMenu(item, anchor)
    require("ui.itemmenu").open(self.server, item, { anchor = anchor, onChange = function() self:load() end })
end

function Person:action(a)
    self.mouseScroll, self.pointerFocus = false, false
    if a == "back" then return app.pop() end
    if self.backFocus then
        if a == "accept" then return app.pop() end
        if a == "down" then self.backFocus = false end
        return
    end
    local rows = self.rows or {}
    local r = rows[self.row]
    if a == "up" then
        if self.row == 1 then self.backFocus = true else self.row = self.row - 1 end
    elseif a == "down" then self.row = math.min(#rows, self.row + 1)
    elseif r and a == "left" then r.col = math.max(1, r.col - 1)
    elseif r and a == "right" then r.col = math.min(#r.items, r.col + 1)
    elseif r and a == "accept" then self:open(r.items[r.col])
    elseif r and a == "menu" then self:itemMenu(r.items[r.col], self.cardRects and self.cardRects[self.row .. ":" .. r.col])
    end
end

function Person:wheel(dx, dy)
    if dy == 0 then return end
    local u = gfx.unit()
    local bottom = (self.contentBottom or 0) - love.graphics.getHeight() + 60 * u
    self.mouseScroll = true
    self.scrollTarget = math.max(0, math.min(math.max(0, bottom), self.scrollTarget - dy * 150 * u))
end

local function clampScroll(first, n, visible) return math.max(0, math.min(first, n - visible)) end

function Person:update(dt)
    self.backdrop:update(dt)
    local function ease(key, want) self.anim[key] = gfx.approach(self.anim[key] or 0, want, dt, 16) end
    for i, r in ipairs(self.rows or {}) do
        for c = 1, #r.items do ease(i .. ":" .. c, (i == self.row and r.col == c and not self.backFocus) and 1 or 0) end
        if not self.pointerFocus then
            -- keep the focused card in view, a neighbour showing where possible
            local margin = r.visible > 2 and 1 or 0
            if r.col - 1 - margin < r.scroll then r.scroll = r.col - 1 - margin end
            if r.col + margin > r.scroll + r.visible then r.scroll = r.col + margin - r.visible end
        end
        r.scroll = clampScroll(r.scroll, #r.items, r.visible)
        ease("scroll" .. i, r.scroll)
    end
    if not self.mouseScroll and self.rowY and self.rowY[self.row] then
        self.scrollTarget = math.max(0, self.rowY[self.row] - love.graphics.getHeight() * 0.4)
    end
    self.scrollY = gfx.approach(self.scrollY, self.scrollTarget, dt, 12)
end

function Person:draw()
    local w, h = love.graphics.getDimensions()
    local u = gfx.unit()
    local pad = 90 * u
    love.graphics.clear(theme.bg)
    self.cardRects = {}
    self.backdrop:draw(w * 0.25, -self.scrollY, w * 0.75, h * 0.6, 0.6, 0.2)
    gfx.hgradient(w * 0.25, -self.scrollY, w * 0.4, h * 0.6, theme.bg, 1, 0)
    gfx.vgradient(0, h * 0.25 - self.scrollY, w, h * 0.35 + 2, theme.bg, 0, 1)
    love.graphics.setColor(theme.bg)
    love.graphics.rectangle("fill", 0, h * 0.6 - self.scrollY, w, h * 2)

    -- portrait and name
    local y = 110 * u - self.scrollY
    local size = 170 * u
    W.personCard(self.server, { tag = "", thumb = self.person.thumb }, pad, y, size, 0)
    local tx = pad + size + 40 * u
    gfx.text(self.person.tag or "", tx, y + size / 2 - 52 * u, 56 * u, theme.text)
    local count = 0
    for _, r in ipairs(self.rows or {}) do count = count + #r.items end
    local sub = self.rows and (count == 1 and "1 title on this server" or count .. " titles on this server") or ""
    gfx.text(sub, tx, y + size / 2 + 22 * u, 22 * u, theme.textDim)
    y = y + size + 70 * u

    if not self.rows then
        if self.error then
            gfx.text("Couldn't load: " .. tostring(self.error), pad, y, 24 * u, theme.danger)
        else
            gfx.spinner(pad + 30 * u, y + 40 * u, 24 * u)
        end
    elseif #self.rows == 0 then
        gfx.text("Nothing else with " .. (self.person.tag or "them") .. " on this server.", pad, y, 24 * u, theme.textDim)
    end

    self.rowY = {}
    local cw = 180 * u
    local ch = cw * W.POSTER_ASPECT
    for i, r in ipairs(self.rows or {}) do
        self.rowY[i] = y + self.scrollY
        gfx.text(r.title or "", pad, y, 30 * u, i == self.row and theme.text or theme.textDim)
        y = y + 50 * u
        r.visible = math.max(1, math.floor((w - pad - 40 * u + 20 * u) / (cw + 20 * u)))
        local off = (self.anim["scroll" .. i] or 0) * (cw + 20 * u)
        mouse.region(0, y, w, ch, { wheel = function(dx)
            if dx == 0 then return false end
            self.pointerFocus = false
            self.row = i
            r.col = math.max(1, math.min(#r.items, r.col + (dx > 0 and 1 or -1)))
            return true
        end })
        for c, it in ipairs(r.items) do
            local cx = pad + (c - 1) * (cw + 20 * u) - off
            if cx > w then break end
            if cx + cw > 0 then
                local focus = self.anim[i .. ":" .. c] or 0
                W.card(self.server, it, cx, y, cw, ch, focus, "poster")
                local rect = { x = cx, y = y, w = cw, h = ch }
                self.cardRects[i .. ":" .. c] = rect
                mouse.region(cx, y, cw, ch, {
                    hover = function()
                        self.mouseScroll, self.pointerFocus, self.backFocus = true, true, false
                        self.row, r.col = i, c
                    end,
                    click = function() self:open(it) end,
                    context = function() self:itemMenu(it, rect) end,
                })
                W.moreButton(cx, y, cw, ch, focus, "poster", function() self:itemMenu(it, rect) end)
            end
        end
        W.rowArrows(0, y, w, ch, self.anim["scroll" .. i] or 0, #r.items, r.visible, function(dir)
            self.pointerFocus, self.mouseScroll = true, true
            r.scroll = clampScroll(r.scroll + dir * math.max(1, r.visible - 1), #r.items, r.visible)
        end)
        y = y + ch + 90 * u
    end
    self.contentBottom = y + self.scrollY

    W.backButton(24 * u, 26 * u, 56 * u, self.backFocus, function() app.pop() end)
end

return Person
