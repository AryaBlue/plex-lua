-- Server list: fetch the account's servers, test every connection, pick one.
-- Reconnects to the last used server automatically once it comes online.

local theme = require("theme")
local gfx = require("ui.gfx")
local servers = require("plex.servers")
local client = require("plex.client")
local auth = require("plex.auth")
local input = require("lib.input")
local mouse = require("ui.mouse")
local W = require("ui.widgets")

local Servers = {}
Servers.__index = Servers

-- autoOpen = false when the user came here on purpose (switch server).
function Servers.new(autoOpen)
    return setmetatable({ list = nil, sel = 1, t = 0, autoOpen = autoOpen ~= false }, Servers)
end

function Servers:enter()
    self:refresh()
end

function Servers:refresh()
    self.list, self.error, self.loading = nil, nil, true
    servers.fetch(function(list, err)
        self.loading = false
        if not list then self.error = err; return end
        self.list = list
        for i, s in ipairs(list) do
            if s.id == client.settings.serverId then self.sel = i end
            s:connect(function(server) self:onServerChange(server) end)
        end
        self.sel = math.min(self.sel, math.max(1, #list))
    end)
end

function Servers:onServerChange(server)
    if self.autoOpen and server.state == "online" and server.id == client.settings.serverId
       and app.top() == self and not self.opened then
        -- wait briefly for a better connection to finish testing (e.g. LAN after relay)
        self.autoOpenAt = self.autoOpenAt or (love.timer.getTime() + 0.6)
    end
end

function Servers:open(server)
    if server.state ~= "online" then
        app.notify(server.name .. " is " .. server.state, "error")
        return
    end
    self.opened = true
    client.set("serverId", server.id)
    print(("[servers] using %s via %s (%s)"):format(server.name, server:baseUrl(), server:connectionLabel()))
    app.reset(require("ui.home").new(server))
end

function Servers:update(dt)
    self.t = self.t + dt
    if self.autoOpenAt and love.timer.getTime() >= self.autoOpenAt and not self.opened then
        for _, s in ipairs(self.list or {}) do
            if s.id == client.settings.serverId and s.state == "online" then return self:open(s) end
        end
    end
end

function Servers:action(a)
    local n = self.list and #self.list or 0
    if a == "up" then self.sel = math.max(1, self.sel - 1)
    elseif a == "down" then self.sel = math.min(n, self.sel + 1)
    elseif a == "accept" and n > 0 then
        self.autoOpenAt = nil
        self:open(self.list[self.sel])
    elseif a == "menu" then
        self:refresh()
    end
end

function Servers:signOut()
    auth.signOut()
    app.reset(require("ui.signin").new())
end

-- theme fields, looked up at draw time so a theme change applies
local STATE_COLORS = {
    online = "success", testing = "warning", pending = "warning",
    offline = "textDim", unauthorized = "danger",
}

function Servers:draw()
    local w, h = love.graphics.getDimensions()
    local u = gfx.unit()
    local x = 140 * u
    gfx.color(theme.accent)
    gfx.roundRect("fill", x, 92 * u, 8 * u, 52 * u, 3 * u)
    gfx.text(theme.appName, x + 24 * u, 84 * u, 56 * u)
    gfx.text("Choose a server" .. (client.settings.userName and ("  ·  " .. client.settings.userName) or ""),
        x, 170 * u, 30 * u, theme.textDim)

    local y = 250 * u
    if self.loading then
        gfx.text("Finding your servers" .. ("."):rep(math.floor(self.t * 2) % 4), x, y, 30 * u, theme.textDim)
    elseif self.error then
        gfx.text("Couldn't load servers: " .. tostring(self.error), x, y, 28 * u, theme.danger)
    elseif self.list and #self.list == 0 then
        gfx.text("No servers on this account. Add one at plex.tv/media-server-downloads", x, y, 28 * u, theme.textDim)
    end

    local rowW, rowH = math.min(1100 * u, w - 2 * x), 96 * u
    for i, s in ipairs(self.list or {}) do
        local ry = y + (i - 1) * (rowH + 16 * u)
        if ry > h - 120 * u then break end
        local selected = i == self.sel
        mouse.region(x, ry, rowW, rowH, {
            hover = function() self.sel = i end,
            click = function() self.autoOpenAt = nil; self:open(s) end,
        })
        gfx.color(selected and theme.surfaceHi or theme.surface)
        gfx.roundRect("fill", x, ry, rowW, rowH, 14 * u)
        if selected then
            gfx.color(theme.accent)
            love.graphics.setLineWidth(3 * u)
            gfx.roundRect("line", x, ry, rowW, rowH, 14 * u)
        end
        local col = theme[STATE_COLORS[s.state] or "textDim"]
        gfx.color(col)
        love.graphics.circle("fill", x + 40 * u, ry + rowH / 2, 10 * u)
        gfx.text(gfx.fit(s.name, 34 * u, rowW * 0.55), x + 72 * u, ry + 14 * u, 34 * u)
        local sub = s.owned and "Your server" or ("Shared by " .. (s.sourceTitle or "a friend"))
        if s.productVersion then sub = sub .. "  ·  v" .. tostring(s.productVersion):match("^[%d.]+") end
        gfx.text(sub, x + 72 * u, ry + 56 * u, 22 * u, theme.textDim)

        local status = s.state == "online" and s:connectionLabel() or s.state
        if s.state == "online" and s.active and s.active.latency then
            status = status .. ("  ·  %d ms"):format(s.active.latency * 1000)
        end
        local f = gfx.font(24 * u)
        gfx.text(status, x + rowW - f:getWidth(status) - 32 * u, ry + rowH / 2 - 14 * u, 24 * u, col)
    end

    -- text links along the bottom
    local lx = x
    for _, link in ipairs({ { "Refresh", function() self:refresh() end },
                            { "Sign out", function() self:signOut() end } }) do
        local lw = gfx.width(link[1], 22 * u)
        local lit = W.pointerIn(lx - 8 * u, h - 76 * u, lw + 16 * u, 40 * u)
        gfx.text(link[1], lx, h - 70 * u, 22 * u, lit and theme.text or theme.textDim)
        mouse.region(lx - 8 * u, h - 76 * u, lw + 16 * u, 40 * u, { click = link[2] })
        lx = lx + lw + 40 * u
    end
end

return Servers
