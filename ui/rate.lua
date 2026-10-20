-- Star rating for a film, show, season or episode (Plex's userRating, kept on
-- the server). Five stars in half steps: left / right (or the pointer) choose,
-- accept or a click saves, 0 stars removes the rating; keys 0-5 set whole
-- stars at once. Opened from the title page's Rate button (ui/detail.lua) and
-- the card options menu (ui/itemmenu.lua); styled like that menu.

local theme = require("theme")
local gfx = require("ui.gfx")
local W = require("ui.widgets")
local api = require("plex.api")
local mouse = require("ui.mouse")

local Rate = {}
Rate.__index = Rate

-- opts: anchor = { x, y, w, h } to open beside (below = true: under it; else
-- centred), onChange(rating)
-- after saving (nil when the rating was removed).
function Rate.new(server, item, opts)
    local current = math.floor((tonumber(item.userRating) or 0) + 0.5)
    return setmetatable({ server = server, item = item, opts = opts or {}, overlay = true, open = 0,
                          current = current, value = current, row = 1 }, Rate)
end

function Rate:rows()
    return self.current > 0 and 2 or 1     -- the stars, then "Remove Rating" when rated
end

function Rate:save(value)
    app.pop()
    if value == self.current then return end   -- unchanged (or still unrated)
    local item, onChange = self.item, self.opts.onChange
    local rating = value > 0 and value or nil
    api.rate(self.server, item, rating, function(ok, err)
        if not ok then return app.notify("Couldn't save the rating: " .. tostring(err), "error") end
        item.userRating = rating
        app.notify(rating and ("Rated " .. api.starsText(rating) .. ": " .. api.displayTitle(item))
            or ("Rating removed: " .. api.displayTitle(item)))
        if onChange then onChange(rating) end
    end)
end

function Rate:action(a)
    if a == "back" or a == "menu" then return app.pop() end
    if a == "up" then self.row = 1
    elseif a == "down" then self.row = self:rows()
    elseif self.row == 1 and a == "left" then self.value = math.max(0, self.value - 1)
    elseif self.row == 1 and a == "right" then self.value = math.min(10, self.value + 1)
    elseif a == "accept" then self:save(self.row == 1 and self.value or 0)
    end
end

function Rate:keypressed(key)
    local n = tonumber(key:match("^kp(%d)$") or key:match("^(%d)$"))
    if n and n <= 5 then
        self:save(n * 2)
        return true
    end
end

function Rate:update(dt)
    self.open = gfx.approach(self.open, 1, dt, 18)
end

function Rate:draw()
    local w, h = love.graphics.getDimensions()
    local u = gfx.unit()
    local a = self.open
    local mw, headH, starsH, rowH = 420 * u, 84 * u, 150 * u, 56 * u
    local mh = headH + starsH + (self.current > 0 and rowH or 0) + 14 * u
    local x, y
    local an = self.opts.anchor
    if an and self.opts.below then
        x = math.max(20 * u, math.min(w - mw - 20 * u, an.x))
        y = an.y + an.h + 14 * u
    elseif an then
        x = an.x + an.w + 18 * u
        if x + mw > w - 20 * u then x = an.x - mw - 18 * u end
        if x < 20 * u then x = math.max(20 * u, math.min(w - mw - 20 * u, an.x + (an.w - mw) / 2)) end
        y = an.y
    else
        x, y = (w - mw) / 2, (h - mh) / 2
    end
    y = math.max(20 * u, math.min(h - mh - 20 * u, y)) - (1 - a) * 12 * u

    mouse.region(0, 0, w, h, { click = function() app.pop() end, context = function() app.pop() end,
                               wheel = function() return true end })
    gfx.color({ 0, 0, 0 }, 0.35 * a)
    gfx.roundRect("fill", x - 2 * u, y + 4 * u, mw + 4 * u, mh + 4 * u, 14 * u)
    gfx.color(theme.surface, 0.98 * a)
    gfx.roundRect("fill", x, y, mw, mh, 12 * u)
    mouse.region(x, y, mw, mh, { click = function() end, context = function() end })

    local item = self.item
    gfx.text(gfx.fit(api.displayTitle(item), 24 * u, mw - 48 * u), x + 24 * u, y + 16 * u, 24 * u, theme.text, a)
    local sub = api.subtitle(item)
    if sub and sub ~= "" then
        gfx.text(gfx.fit(sub, 18 * u, mw - 48 * u), x + 24 * u, y + 48 * u, 18 * u, theme.textDim, a)
    end
    gfx.color(theme.text, 0.1 * a)
    love.graphics.rectangle("fill", x + 20 * u, y + headH - 4 * u, mw - 40 * u, 1)

    -- the stars: each half is a target for the pointer
    local r, gap = 26 * u, 14 * u
    local rowW = 5 * 2 * r + 4 * gap
    local sx, sy = x + (mw - rowW) / 2, y + headH + 22 * u
    local focused = self.row == 1
    for i = 1, 5 do
        local cx = sx + r + (i - 1) * (2 * r + gap)
        local fill = math.max(0, math.min(1, (self.value - (i - 1) * 2) / 2))
        gfx.color(fill > 0 and theme.warning or theme.textDim, (focused and 1 or 0.7) * a)
        W.star(cx, sy + r, r, fill)
        for half = 1, 2 do
            local v = (i - 1) * 2 + half
            mouse.region(cx - r - gap / 2 + (half - 1) * (r + gap / 2), sy - 6 * u, r + gap / 2, 2 * r + 12 * u, {
                hover = function() self.row = 1; self.value = v end,
                click = function() self:save(v) end,
            })
        end
    end
    local label = self.value > 0 and api.starsText(self.value) or "No rating"
    gfx.textCentered(label, x + mw / 2, sy + 2 * r + 16 * u, 22 * u, focused and theme.text or theme.textDim, a)
    gfx.textCentered(self.value == self.current and (self.current > 0 and "Your rating" or "Choose with ← → or the pointer")
        or "Enter or click to save",
        x + mw / 2, sy + 2 * r + 48 * u, 17 * u, theme.textDim, a)

    if self.current > 0 then
        local ry = y + headH + starsH
        if self.row == 2 then
            gfx.color(theme.text, 0.1 * a)
            love.graphics.rectangle("fill", x, ry, mw, rowH)
            gfx.color(theme.accent, a)
            love.graphics.rectangle("fill", x, ry + 12 * u, 4 * u, rowH - 24 * u)
        end
        gfx.text("Remove Rating", x + 30 * u, ry + (rowH - gfx.font(22 * u):getHeight()) / 2, 22 * u,
            self.row == 2 and theme.text or theme.textDim, a)
        mouse.region(x, ry, mw, rowH, {
            hover = function() self.row = 2 end,
            click = function() self:save(0) end,
        })
    end
end

return Rate
