-- Persistent client identity and settings, plus the X-Plex-* headers every
-- request carries (developer.plex.tv: "X-Plex-Client-Identifier is typically
-- required, as is X-Plex-Token for authentication").

local json = require("lib.json")
local theme = require("theme")

local client = {}

local SETTINGS_FILE = "settings.json"

client.settings = {
    clientIdentifier = nil,
    token = nil,             -- plex.tv account token
    userName = nil,
    serverId = nil,          -- last chosen server machineIdentifier
    allowRelay = true,
    allowInsecureLocal = true, -- also try plain http:// for LAN addresses
    autoPlay = true,         -- play the next episode after a countdown
    autoPlayDelay = 10,      -- countdown seconds (Plex's own is 10)
    theme = "reel",          -- theme.presets id
    qualityHome = 0,         -- kbps limit on this network (0 = Original); playback.QUALITIES
    qualityAway = 0,         -- the same over the internet / relay
    castDialHosts = {},      -- addresses asked directly for DIAL devices (Fire TV sticks); cast/init.lua
    castDialScan = false,    -- also look for DIAL devices across the whole network
    castBlock = {},          -- device names or addresses never offered or contacted
    castAdb = true,          -- control Plex on Fire TV over ADB (cast/adb_worker.lua)
}

local function random_id()
    local hex = "0123456789abcdef"
    local t = {}
    for i = 1, 32 do
        local r = love.math.random(1, 16)
        t[i] = hex:sub(r, r)
        if i == 8 or i == 12 or i == 16 or i == 20 then t[i] = t[i] .. "-" end
    end
    return table.concat(t)
end

function client.load()
    local data = love.filesystem.read(SETTINGS_FILE)
    if data then
        local ok, saved = pcall(json.decode, data)
        if ok and type(saved) == "table" then
            for k, v in pairs(saved) do
                if v ~= json.null then client.settings[k] = v end
            end
        end
    end
    if not client.settings.clientIdentifier then
        love.math.setRandomSeed(os.time(), love.timer.getTime() * 1e6)
        client.settings.clientIdentifier = random_id()
        client.save()
    end
end

function client.save()
    love.filesystem.write(SETTINGS_FILE, json.encode(client.settings))
end

function client.set(key, value)
    client.settings[key] = value
    client.save()
end

-- Name and avatar for the profile menu, from plex.tv /api/v2/user.
function client.rememberUser(user)
    client.settings.userName = user.title or user.username
    client.settings.userHandle = user.username
    client.settings.userThumb = user.thumb
    client.save()
end

local osName = love.system.getOS()

-- Headers identifying this app. token: pass a server access token to override the account token.
function client.headers(token)
    local h = {
        ["X-Plex-Client-Identifier"] = client.settings.clientIdentifier,
        ["X-Plex-Product"] = theme.appName,
        ["X-Plex-Version"] = theme.version,
        ["X-Plex-Platform"] = osName,
        ["X-Plex-Device"] = osName,
        ["X-Plex-Device-Name"] = theme.appName .. " (" .. osName .. ")",
        ["X-Plex-Model"] = "LOVE",
        ["Accept"] = "application/json",
    }
    local tok = token or client.settings.token
    if tok then h["X-Plex-Token"] = tok end
    return h
end

return client
