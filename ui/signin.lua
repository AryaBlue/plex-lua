-- Sign-in: verify a saved token, otherwise show a link code for plex.tv/link.

local theme = require("theme")
local gfx = require("ui.gfx")
local auth = require("plex.auth")
local client = require("plex.client")
local input = require("lib.input")
local mouse = require("ui.mouse")

local SignIn = {}
SignIn.__index = SignIn

function SignIn.new()
    return setmetatable({ state = "checking", t = 0 }, SignIn)
end

function SignIn:enter()
    -- signed in before and the last server is cached: open Home with it right
    -- away; the sign-in check and the connection happen in the background
    local cached = client.settings.token and require("plex.servers").cached()
    if cached then return self:quickStart(cached) end
    if client.settings.token then
        auth.verify(function(user, err, unauthorized)
            if user then return self:signedIn(user) end
            if unauthorized then
                auth.signOut()
                self:startLogin()
            else
                self.state = "error"
                self.error = "Can't reach plex.tv: " .. tostring(err)
            end
        end)
    else
        self:startLogin()
    end
end

function SignIn:startLogin()
    if self.login then self.login:cancel() end
    self.state = "requesting"
    self.code, self.linkUrl, self.error = nil, nil, nil
    self.login = auth.startLogin({
        onCode = function(code, url)
            self.state = "code"
            self.code, self.linkUrl = code, url
        end,
        onToken = function()
            self.state = "checking"
            auth.verify(function(user, err)
                if user then self:signedIn(user)
                else self.state = "error"; self.error = tostring(err) end
            end)
        end,
        onError = function(err)
            self.state = "error"
            self.error = err
        end,
    })
end

function SignIn:quickStart(server)
    app.reset(require("ui.home").new(server))
    server:quickConnect()
    auth.verify(function(user, err, unauthorized)
        if user then return client.rememberUser(user) end
        if unauthorized then
            -- token revoked: back to the sign-in code
            auth.signOut()
            app.reset(SignIn.new())
        else
            print("[signin] couldn't check the sign-in with plex.tv: " .. tostring(err))
        end
    end)
end

function SignIn:signedIn(user)
    client.rememberUser(user)
    app.reset(require("ui.servers").new())
end

function SignIn:leave()
    if self.login then self.login:cancel() end
end

function SignIn:update(dt)
    self.t = self.t + dt
    if self.login then self.login:update(dt) end
end

function SignIn:action(a)
    if a == "accept" then
        if self.state == "code" and self.linkUrl then
            love.system.openURL(self.linkUrl)
        elseif self.state == "error" then
            self:startLogin()
        end
    elseif a == "back" and input.lastDevice ~= "mouse" then
        love.event.quit()   -- (a stray right-click shouldn't close the app)
    end
end

local function logo(cx, y, u)
    local f = gfx.font(96 * u)
    local w = f:getWidth(theme.appName)
    gfx.color(theme.accent)
    gfx.roundRect("fill", cx - w / 2 - 28 * u, y + 22 * u, 12 * u, 76 * u, 4 * u)
    gfx.textCentered(theme.appName, cx + 8 * u, y, 96 * u, theme.text)
    gfx.textCentered(theme.tagline, cx, y + 120 * u, 28 * u, theme.textDim)
end

function SignIn:draw()
    local w, h = love.graphics.getDimensions()
    local u = gfx.unit()
    local cx = w / 2

    -- soft accent glow
    for i = 6, 1, -1 do
        gfx.color(theme.accent, 0.025)
        love.graphics.circle("fill", cx, h * 0.15, i * 140 * u)
    end

    logo(cx, h * 0.14, u)

    local panelW, panelH = 760 * u, 420 * u
    local px, py = cx - panelW / 2, h * 0.42
    -- clicking the panel does what Enter does (open the browser / retry)
    mouse.region(px, py, panelW, panelH, { click = function() self:action("accept") end })
    gfx.color(theme.surface, 0.92)
    gfx.roundRect("fill", px, py, panelW, panelH, 20 * u)

    if self.state == "code" then
        gfx.textCentered("Sign in with your Plex account", cx, py + 36 * u, 32 * u, theme.text)
        gfx.textCentered("Go to  plex.tv/link  and enter this code", cx, py + 86 * u, 26 * u, theme.textDim)
        local code = self.code or ""
        local spaced = code:gsub(".", "%0 "):sub(1, -2)
        gfx.textCentered(spaced, cx, py + 140 * u, 96 * u, theme.accent)
        local how = input.lastDevice == "mouse" and "Click here" or ("Press " .. input.hint("accept"))
        gfx.textCentered(("%s to open the sign-in page in your browser"):format(how),
            cx, py + 300 * u, 24 * u, theme.textDim)
        local dots = ("."):rep(math.floor(self.t * 2) % 4)
        gfx.textCentered("Waiting for you to sign in" .. dots, cx, py + 346 * u, 22 * u, theme.textDim)
    elseif self.state == "error" then
        gfx.textCentered("Something went wrong", cx, py + 60 * u, 34 * u, theme.danger)
        gfx.wrapped(self.error or "", px + 40 * u, py + 130 * u, panelW - 80 * u, 24 * u, theme.textDim, 5)
        gfx.textCentered(("Press %s to try again"):format(input.hint("accept")), cx, py + 340 * u, 24 * u, theme.text)
    else
        local label = self.state == "checking" and "Checking your account" or "Getting a sign-in code"
        gfx.textCentered(label .. ("."):rep(math.floor(self.t * 2) % 4), cx, py + panelH / 2 - 16 * u, 30 * u, theme.textDim)
    end
end

return SignIn
