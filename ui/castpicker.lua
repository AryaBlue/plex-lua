-- "Play on…": the devices Reel can cast to, found when the menu opens
-- (cast/init.lua). Choosing one starts the title there and opens the player as its
-- remote (player/scene.lua, casting). Styled like the poster options menu (ui/itemmenu.lua).

local theme = require("theme")
local gfx = require("ui.gfx")
local api = require("plex.api")
local mouse = require("ui.mouse")
local cast = require("cast")

local Picker = {}
Picker.__index = Picker

-- opts: offset = seconds to start from; onCast() once a device is chosen, for a player
-- that becomes the remote itself (otherwise a remote player is opened).
function Picker.new(server, item, opts)
    local self = setmetatable({ server = server, item = item, opts = opts or {}, sel = 1, open = 0,
                                overlay = true }, Picker)
    cast.scan()
    return self
end

local function kindLabel(d)
    if d.kind == "chromecast" then return d.model or "Chromecast" end
    return (d.manufacturer and d.manufacturer .. " " or "") .. (d.model or "TV") .. " · opens Plex"
end

-- Rows: the devices, then "Search again" when the scan is over.
function Picker:rows()
    local rows = {}
    for _, d in ipairs(cast.devices) do
        rows[#rows + 1] = { label = d.name, note = kindLabel(d), run = function() self:choose(d) end, device = d }
    end
    if not cast.scanning then
        rows[#rows + 1] = { label = "Search again", run = function() cast.scan() end }
    end
    return rows
end

function Picker:choose(d)
    if self.busy then return end
    self.busy = d
    local server, opts = self.server, self.opts
    api.metadata(server, self.item.ratingKey, function(full, err)
        if not full then self.busy = nil; return app.notify(tostring(err), "error") end
        if app.top() == self then app.pop() end
        -- failures show on the remote (player/scene.lua says why and closes)
        cast.start(d, server, full, opts.offset or 0)
        if opts.onCast then opts.onCast()
        else app.push(require("player.scene").new(server, full, { cast = true })) end
    end)
end

function Picker:action(a)
    local rows = self:rows()
    if a == "up" then self.sel = math.max(1, self.sel - 1)
    elseif a == "down" then self.sel = math.min(#rows, self.sel + 1)
    elseif a == "accept" then local r = rows[self.sel]; if r then r.run() end
    elseif a == "back" or a == "menu" or a == "left" or a == "right" then app.pop() end
end

function Picker:update(dt)
    self.open = gfx.approach(self.open, 1, dt, 18)
    self.sel = math.max(1, math.min(self.sel, #self:rows()))
end

function Picker:draw()
    local w, h = love.graphics.getDimensions()
    local u = gfx.unit()
    local a = self.open
    local rows = self:rows()
    local mw, rowH, headH = 440 * u, 68 * u, 92 * u
    local statusH = (cast.scanning or #cast.devices == 0) and 56 * u or 0
    local mh = headH + statusH + #rows * rowH + 14 * u
    local x, y = (w - mw) / 2, (h - mh) / 2 - (1 - a) * 12 * u

    mouse.region(0, 0, w, h, { click = function() app.pop() end, context = function() app.pop() end,
                               wheel = function() return true end })
    gfx.color({ 0, 0, 0 }, 0.5 * a)
    love.graphics.rectangle("fill", 0, 0, w, h)
    gfx.color(theme.surface, 0.98 * a)
    gfx.roundRect("fill", x, y, mw, mh, 12 * u)
    mouse.region(x, y, mw, mh, { click = function() end, context = function() end })

    gfx.text("Play on…", x + 24 * u, y + 16 * u, 26 * u, theme.text, a)
    gfx.text(gfx.fit(api.displayTitle(self.item), 18 * u, mw - 48 * u), x + 24 * u, y + 52 * u, 18 * u, theme.textDim, a)
    gfx.color(theme.text, 0.1 * a)
    love.graphics.rectangle("fill", x + 20 * u, y + headH - 4 * u, mw - 40 * u, 1)

    local ry = y + headH
    if statusH > 0 then
        local msg
        if cast.scanning then
            msg = "Looking for TVs…"
            gfx.spinner(x + 38 * u, ry + statusH / 2, 10 * u)
        else
            msg = "No TVs found on this network"
        end
        gfx.text(msg, x + (cast.scanning and 62 or 24) * u, ry + (statusH - gfx.font(20 * u):getHeight()) / 2, 20 * u,
            theme.textDim, a)
        ry = ry + statusH
    end
    for i, r in ipairs(rows) do
        local on = self.sel == i
        if on then
            gfx.color(theme.text, 0.1 * a)
            love.graphics.rectangle("fill", x, ry, mw, rowH)
            gfx.color(theme.accent, a)
            love.graphics.rectangle("fill", x, ry + 14 * u, 4 * u, rowH - 28 * u)
        end
        local busy = self.busy and r.device == self.busy
        if r.note then
            gfx.text(gfx.fit(r.label, 22 * u, mw - 60 * u), x + 30 * u, ry + 10 * u, 22 * u, on and theme.text or theme.textDim, a)
            gfx.text(gfx.fit(busy and "Starting…" or r.note, 17 * u, mw - 60 * u), x + 30 * u, ry + 38 * u, 17 * u,
                busy and theme.accent or theme.textDim, a * 0.8)
        else
            gfx.text(r.label, x + 30 * u, ry + (rowH - gfx.font(22 * u):getHeight()) / 2, 22 * u,
                on and theme.text or theme.textDim, a)
        end
        mouse.region(x, ry, mw, rowH, {
            hover = function() self.sel = i end,
            click = function() r.run() end,
        })
        ry = ry + rowH
    end
end

return Picker
