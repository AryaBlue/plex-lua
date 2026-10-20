-- Settings (from the profile menu): auto play, the countdown before the next
-- episode starts, streaming quality at home and away, colour theme, and
-- account actions. Choices apply and save
-- straight away; left/right on a row changes it.

local theme = require("theme")
local gfx = require("ui.gfx")
local W = require("ui.widgets")
local client = require("plex.client")
local playback = require("plex.playback")
local auth = require("plex.auth")
local mouse = require("ui.mouse")

local Settings = {}
Settings.__index = Settings

local DELAYS = { 3, 5, 10, 15, 30 }

function Settings.new(server)
    local self = setmetatable({ server = server, row = 1, backFocus = false, anim = {}, scrollY = 0 }, Settings)
    local function setting(key) return function() return client.settings[key] end end
    local function save(key) return function(v) client.set(key, v) end end

    local delays = {}
    for _, d in ipairs(DELAYS) do delays[#delays + 1] = { label = d .. " seconds", value = d } end
    local qualities = {}
    for _, q in ipairs(playback.QUALITIES) do qualities[#qualities + 1] = { label = q.label, value = q.kbps } end
    local themes = {}
    for _, p in ipairs(theme.presets) do themes[#themes + 1] = { label = p.name, value = p.id, preset = p } end

    self.rows = {
        { section = "Playback", title = "Auto Play",
          desc = "When an episode ends, play the next one.",
          options = { { label = "On", value = true }, { label = "Off", value = false } },
          get = function() return client.settings.autoPlay ~= false end, set = save("autoPlay") },
        { title = "Countdown",
          desc = "How long \"Playing Next\" waits before starting the next episode.",
          options = delays, get = setting("autoPlayDelay"), set = save("autoPlayDelay"),
          disabled = function() return client.settings.autoPlay == false end },
        { section = "Quality", title = "At Home",
          desc = "Server on this network. Original plays files as they are; a limit converts anything bigger.",
          options = qualities, get = setting("qualityHome"), set = save("qualityHome"), key = "qualityHome" },
        { title = "Away",
          desc = "Streaming over the internet or through Plex's relay.",
          options = qualities, get = setting("qualityAway"), set = save("qualityAway"), key = "qualityAway" },
        { section = "Appearance", title = "Theme", kind = "swatch",
          desc = "Colours for the whole app.",
          options = themes, get = setting("theme"),
          set = function(v) client.set("theme", v); theme.apply(v) end },
        { section = "Account", title = client.settings.userName or "Plex account", kind = "buttons",
          desc = server and ("Watching from " .. server.name) or nil,
          options = {
              { label = "Switch Server", run = function() app.reset(require("ui.servers").new(false)) end },
              { label = "Sign Out", run = function()
                  auth.signOut()
                  app.reset(require("ui.signin").new())
              end },
          } },
    }
    -- say which quality row this connection uses
    if server and server.active then
        local key = playback.settingKey(server)
        for _, r in ipairs(self.rows) do
            if r.key == key then r.desc = r.desc .. "  (in use now)" end
        end
    end
    for _, r in ipairs(self.rows) do r.col = self:currentIndex(r) end
    return self
end

-- Index of the option that's in effect (1 for button rows).
function Settings:currentIndex(r)
    if not r.get then return r.col or 1 end
    local v = r.get()
    for i, o in ipairs(r.options) do
        if o.value == v then return i end
    end
    return 1
end

function Settings:choose(r, i)
    r.col = i
    local o = r.options[i]
    if r.kind == "buttons" then return o.run() end
    if r.disabled and r.disabled() then return end
    r.set(o.value)
end

function Settings:action(a)
    if a == "back" then return app.pop() end
    if self.backFocus then
        if a == "accept" then return app.pop() end
        if a == "down" then self.backFocus = false end
        return
    end
    local r = self.rows[self.row]
    if a == "up" then
        if self.row == 1 then self.backFocus = true else self.row = self.row - 1 end
    elseif a == "down" then
        self.row = math.min(#self.rows, self.row + 1)
    elseif a == "left" or a == "right" then
        local i = math.max(1, math.min(#r.options, r.col + (a == "left" and -1 or 1)))
        if r.kind == "buttons" then r.col = i else self:choose(r, i) end
    elseif a == "accept" then
        self:choose(r, r.col)
    end
end

function Settings:update(dt)
    -- keys/controller: scroll so the focused row is on screen
    local r = self.rows[self.row]
    if r._top and require("lib.input").lastDevice ~= "mouse" then
        local h, u = love.graphics.getHeight(), gfx.unit()
        local target = self.scrollY
        if self.backFocus or self.row == 1 then target = 0
        elseif r._bottom - target > h - 40 * u then target = r._bottom - h + 40 * u
        elseif r._top - target < 120 * u then target = r._top - 120 * u end
        self.scrollY = gfx.approach(self.scrollY, math.max(0, math.min(self.maxScroll or 0, target)), dt, 12)
    end
    for i, r in ipairs(self.rows) do
        if r.kind ~= "buttons" then r.col = self:currentIndex(r) end
        for c = 1, #r.options do
            local key = i * 100 + c
            local want = (not self.backFocus and self.row == i and r.col == c) and 1 or 0
            self.anim[key] = gfx.approach(self.anim[key] or 0, want, dt, 16)
        end
    end
end

function Settings:wheel(dx, dy)
    self.scrollY = math.max(0, math.min(self.maxScroll or 0, self.scrollY - dy * 120 * gfx.unit()))
end

-- Small preview card of a theme: its background, a surface panel and the accent.
local function drawSwatch(p, x, y, sw, sh, focus, current, u)
    local c = theme.colorsOf(p.id)
    local accent = c.accent
    gfx.color(c.bg)
    gfx.roundRect("fill", x, y, sw, sh, 10 * u)
    gfx.color(c.surfaceHi)
    gfx.roundRect("fill", x + 14 * u, y + 16 * u, sw * 0.42, sh * 0.42, 6 * u)
    gfx.roundRect("fill", x + 22 * u + sw * 0.42, y + 16 * u, sw * 0.42, sh * 0.42, 6 * u)
    gfx.color(accent)
    gfx.roundRect("fill", x + 14 * u, y + sh * 0.42 + 26 * u, sw * 0.3, 8 * u, 4 * u)
    gfx.text(gfx.fit(p.name, 19 * u, sw - 24 * u), x + 14 * u, y + sh - 34 * u, 19 * u, theme.text)
    if current or focus > 0.01 then
        gfx.color(current and theme.text or theme.accent, current and 1 or focus)
        love.graphics.setLineWidth(3 * u)
        gfx.roundRect("line", x - 4 * u, y - 4 * u, sw + 8 * u, sh + 8 * u, 13 * u)
    end
end

function Settings:draw()
    local w, h = love.graphics.getDimensions()
    local u = gfx.unit()
    love.graphics.clear(theme.bg)
    local pad = 140 * u
    local y = 130 * u - self.scrollY
    gfx.text("Settings", pad, y, 52 * u, theme.text)
    y = y + 100 * u

    for i, r in ipairs(self.rows) do
        if r.section then
            y = y + 20 * u
            gfx.text(r.section:upper(), pad, y, 19 * u, theme.accent)
            y = y + 40 * u
        end
        local top = y
        local focused = not self.backFocus and self.row == i
        local dim = r.disabled and r.disabled()
        gfx.text(r.title, pad, y, 30 * u, (focused and not dim) and theme.text or theme.textDim)
        y = y + 44 * u
        if r.desc then
            gfx.text(r.desc, pad, y, 20 * u, theme.textDim, dim and 0.6 or 1)
            y = y + 40 * u
        end
        local current = r.get and r.get()
        local x = pad
        if r.kind == "swatch" then
            local sw, sh = 190 * u, 120 * u
            for c, o in ipairs(r.options) do
                if x + sw > w - pad then x, y = pad, y + sh + 24 * u end
                drawSwatch(o.preset, x, y, sw, sh, focused and self.anim[i * 100 + c] or 0, o.value == current, u)
                mouse.region(x, y, sw, sh, {
                    hover = function() self.row, self.backFocus = i, false end,
                    click = function() self:choose(r, c) end,
                })
                x = x + sw + 24 * u
            end
            y = y + sh + 30 * u
        else
            local bh = 54 * u
            for c, o in ipairs(r.options) do
                local on = r.kind ~= "buttons" and o.value == current
                if x > pad and x + W.buttonWidth(o.label, bh, on and "check" or nil) > w - pad then
                    x, y = pad, y + bh + 16 * u     -- wrap long rows (the quality list)
                end
                local bw = W.button(o.label, x, y, bh, focused and self.anim[i * 100 + c] or 0,
                    { primary = on and not dim, icon = on and "check" or nil })
                mouse.region(x, y, bw, bh, {
                    hover = function()
                        self.row, self.backFocus = i, false
                        if r.kind == "buttons" then r.col = c end
                    end,
                    click = function() self:choose(r, c) end,
                })
                x = x + bw + 16 * u
            end
            y = y + bh + 30 * u
        end
        r._top, r._bottom = top + self.scrollY, y + self.scrollY   -- page coordinates, for scrolling
    end
    self.maxScroll = math.max(0, y + self.scrollY - h + 60 * u)

    W.backButton(24 * u, 26 * u, 56 * u, self.backFocus, function() app.pop() end)
end

return Settings
