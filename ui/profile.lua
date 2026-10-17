-- Account menu that drops down from the avatar at the top right of Home,
-- laid out like Plex's own (NavBarAccountMenu): big avatar, name and
-- username, then the menu entries.

local theme = require("theme")
local gfx = require("ui.gfx")
local W = require("ui.widgets")
local client = require("plex.client")
local auth = require("plex.auth")
local mouse = require("ui.mouse")

local Profile = {}
Profile.__index = Profile

-- server: the one Home is showing (named in the menu).
function Profile.new(server)
    local self = setmetatable({ server = server, sel = 1, open = 0, overlay = true }, Profile)
    self.entries = {
        { label = "Settings", run = function()
            app.pop()
            app.push(require("ui.settings").new(server))
        end },
        { label = "Switch Server", run = function() app.reset(require("ui.servers").new(false)) end },
        { label = "Sign Out", run = function()
            auth.signOut()
            app.reset(require("ui.signin").new())
        end },
    }
    return self
end

function Profile:enter()
    -- signed in before the avatar was saved: fetch it once
    if not client.settings.userThumb then
        auth.verify(function(user) if user then client.rememberUser(user) end end)
    end
end

function Profile:action(a)
    if a == "up" then self.sel = math.max(1, self.sel - 1)
    elseif a == "down" then self.sel = math.min(#self.entries, self.sel + 1)
    elseif a == "accept" then self.entries[self.sel].run()
    elseif a == "back" or a == "menu" or a == "left" then app.pop() end
end

function Profile:update(dt)
    self.open = gfx.approach(self.open, 1, dt, 18)
end

function Profile:draw()
    local w, h = love.graphics.getDimensions()
    local u = gfx.unit()
    local a = self.open
    local mw = 340 * u
    local x, y = w - 70 * u - mw, 92 * u - (1 - a) * 12 * u
    local rowH = 58 * u
    local headH = 200 * u
    local mh = headH + #self.entries * rowH + 54 * u

    -- clicking anywhere else closes the menu
    mouse.region(0, 0, w, h, { click = function() app.pop() end })
    gfx.color({ 0, 0, 0 }, 0.35 * a)
    gfx.roundRect("fill", x - 2 * u, y + 4 * u, mw + 4 * u, mh + 4 * u, 14 * u)
    gfx.color(theme.surface, 0.98 * a)
    gfx.roundRect("fill", x, y, mw, mh, 12 * u)
    mouse.region(x, y, mw, mh, { click = function() end })

    -- who's signed in
    local name = client.settings.userName or "Signed in"
    local handle = client.settings.userHandle
    W.avatar(x + mw / 2, y + 64 * u, 40 * u, a)
    gfx.textCentered(gfx.fit(name, 26 * u, mw - 40 * u), x + mw / 2, y + 116 * u, 26 * u, theme.text, a)
    if handle and handle ~= name then
        gfx.textCentered(gfx.fit(handle, 19 * u, mw - 40 * u), x + mw / 2, y + 150 * u, 19 * u, theme.textDim, a)
    end
    gfx.color(theme.text, 0.1 * a)
    love.graphics.rectangle("fill", x + 20 * u, y + headH - 8 * u, mw - 40 * u, 1)

    local ry = y + headH
    for i, e in ipairs(self.entries) do
        if self.sel == i then
            gfx.color(theme.text, 0.1 * a)
            love.graphics.rectangle("fill", x, ry, mw, rowH)
            gfx.color(theme.accent, a)
            love.graphics.rectangle("fill", x, ry + 12 * u, 4 * u, rowH - 24 * u)
        end
        gfx.text(e.label, x + 30 * u, ry + (rowH - gfx.font(23 * u):getHeight()) / 2, 23 * u,
            self.sel == i and theme.text or theme.textDim, a)
        mouse.region(x, ry, mw, rowH, {
            hover = function() self.sel = i end,
            click = function() e.run() end,
        })
        ry = ry + rowH
    end
    if self.server and self.server.name then
        gfx.text(gfx.fit("Server: " .. self.server.name, 17 * u, mw - 60 * u), x + 30 * u, ry + 14 * u, 17 * u, theme.textDim, a)
    end
end

return Profile
