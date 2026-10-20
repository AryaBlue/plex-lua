-- plex.tv sign-in with the PIN ("link code") flow:
--   POST https://plex.tv/api/v2/pins            -> { id, code }
--   user enters the code at https://plex.tv/link (or opens the app.plex.tv auth URL)
--   GET  https://plex.tv/api/v2/pins/{id}        -> authToken once claimed
--   GET  https://plex.tv/api/v2/user             -> 200 = token valid, 401 = invalid

local http = require("lib.http")
local client = require("plex.client")

local auth = {}

local PLEX_TV = "https://plex.tv"
local POLL_INTERVAL = 2

-- Verify the stored token. callback(user | nil, err, unauthorized)
function auth.verify(callback)
    if not client.settings.token then return callback(nil, "not signed in", true) end
    http.json({ url = PLEX_TV .. "/api/v2/user", headers = client.headers(), timeout = 15 },
        function(user, err, res)
            if user then return callback(user) end
            callback(nil, err, res and res.status == 401)
        end)
end

-- A running PIN login. Call :update(dt) every frame; listen with onCode/onToken/onError.
local Login = {}
Login.__index = Login

function auth.startLogin(handlers)
    local self = setmetatable({ handlers = handlers or {}, pollTimer = 0, state = "requesting" }, Login)
    http.json({ url = PLEX_TV .. "/api/v2/pins", method = "POST", headers = client.headers(), timeout = 15 },
        function(pin, err)
            if self.state == "cancelled" then return end
            if not pin or not pin.id then
                self.state = "error"
                return self:_emit("onError", err or "no PIN returned")
            end
            self.pin = pin
            self.state = "waiting"
            self.expires = love.timer.getTime() + (tonumber(pin.expiresIn) or 900)
            self:_emit("onCode", pin.code, auth.linkUrl(pin))
        end)
    return self
end

-- The browser URL that claims this PIN directly (no typing needed).
function auth.linkUrl(pin)
    return "https://app.plex.tv/auth#?" .. http.query({
        clientID = client.settings.clientIdentifier,
        code = pin.code,
        ["context[device][product]"] = client.headers()["X-Plex-Product"],
    })
end

function Login:_emit(name, ...)
    local f = self.handlers[name]
    if f then f(...) end
end

function Login:update(dt)
    if self.state ~= "waiting" or self.polling then return end
    if love.timer.getTime() > self.expires then
        self.state = "expired"
        return self:_emit("onError", "The code expired. Press A / Enter for a new one.")
    end
    self.pollTimer = self.pollTimer + dt
    if self.pollTimer < POLL_INTERVAL then return end
    self.pollTimer = 0
    self.polling = true
    http.json({ url = PLEX_TV .. "/api/v2/pins/" .. self.pin.id, headers = client.headers(), timeout = 15 },
        function(pin)
            self.polling = false
            if self.state ~= "waiting" then return end
            local token = pin and pin.authToken
            if type(token) == "string" and token ~= "" then
                self.state = "done"
                client.set("token", token)
                self:_emit("onToken", token)
            end
        end)
end

function Login:cancel() self.state = "cancelled" end

function auth.signOut()
    client.settings.token = nil
    client.settings.userName = nil
    client.settings.userHandle = nil
    client.settings.userThumb = nil
    client.settings.serverId = nil
    client.settings.lastServer = nil     -- holds that server's access token
    client.save()
end

return auth
