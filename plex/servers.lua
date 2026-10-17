-- Server discovery and connection choice.
--
-- 1. GET https://clients.plex.tv/api/v2/resources?includeHttps=1&includeRelay=1&includeIPv6=1
--    lists every device on the account; servers are the ones whose `provides`
--    contains "server". Each carries its own accessToken and Connection list.
-- 2. Every connection is tested in parallel with GET <uri>/identity (10 s timeout);
--    a success is only accepted if machineIdentifier matches the resource.
-- 3. Among the connections that answered, pick the best:
--    direct > relay, then loopback > LAN (private address) > public, then https > http.

local http = require("lib.http")
local client = require("plex.client")

local servers = {}

local RESOURCES_URL = "https://clients.plex.tv/api/v2/resources"
local TEST_TIMEOUT = 10

local function is_loopback(addr)
    return addr == "localhost" or addr == "::1" or addr:match("^127%.") ~= nil
end

local function is_private(addr)
    if is_loopback(addr) then return true end
    local a, b = addr:match("^(%d+)%.(%d+)%.%d+%.%d+$")
    a, b = tonumber(a), tonumber(b)
    if a then
        return a == 10 or (a == 172 and b >= 16 and b <= 31) or (a == 192 and b == 168)
            or (a == 169 and b == 254) or (a == 100 and b >= 64 and b <= 127)
    end
    local lower = addr:lower()
    return lower:match("^f[cd]") ~= nil or lower:match("^fe80") ~= nil
end

-- *.plex.direct hostnames encode the IP: 192-168-1-5.<hash>.plex.direct
local function plex_direct_ip(host)
    local first = host:match("^([^.]+)%.[%w]+%.plex%.direct$")
    if not first then return nil end
    if first:find("^%d+%-%d+%-%d+%-%d+$") then return (first:gsub("%-", ".")) end
    return (first:gsub("%-", ":"))
end

local function make_connection(c)
    local host = c.uri:match("^%a+://%[?([^%]/:]+)") or c.address
    local addr = c.address or plex_direct_ip(host) or host
    local conn = {
        uri = c.uri:gsub("/+$", ""),
        protocol = c.protocol or c.uri:match("^(%a+)://"),
        address = addr,
        port = c.port,
        relay = c.relay == true,
        localHint = c["local"] == true,
        ipv6 = c.IPv6 == true,
        state = "untested",
    }
    conn.loopback = is_loopback(addr)
    conn.private = is_private(addr)
    conn.https = conn.protocol == "https"
    return conn
end

-- Returns the better of two connections (FINDINGS.md ranking).
function servers.better(a, b)
    if a.relay ~= b.relay then return a.relay and b or a end
    if a.loopback ~= b.loopback then return a.loopback and a or b end
    if a.private ~= b.private then return a.private and a or b end
    if a.https ~= b.https then return a.https and a or b end
    return a
end

local Server = {}
Server.__index = Server

local function new_server(res)
    local self = setmetatable({
        id = res.clientIdentifier,
        name = res.name or "Plex Media Server",
        owned = res.owned == true,
        sourceTitle = type(res.sourceTitle) == "string" and res.sourceTitle or nil,
        accessToken = type(res.accessToken) == "string" and res.accessToken or nil,
        presence = res.presence == true,
        productVersion = res.productVersion,
        platform = res.platform,
        httpsRequired = res.httpsRequired == true,
        connections = {},
        state = "pending",      -- pending | testing | online | offline | unauthorized
    }, Server)

    local seen = {}
    local function add(c)
        if not seen[c.uri] then
            seen[c.uri] = true
            self.connections[#self.connections + 1] = c
        end
    end
    for _, c in ipairs(res.connections or {}) do
        if type(c) == "table" and type(c.uri) == "string" then
            if not (c.relay and not client.settings.allowRelay) then
                local conn = make_connection(c)
                add(conn)
                -- LAN servers without a valid certificate path: also try plain http to the raw IP.
                if client.settings.allowInsecureLocal and conn.private and not self.httpsRequired
                   and c.address and c.port and not conn.relay then
                    local ip = c.address:find(":") and ("[" .. c.address .. "]") or c.address
                    add(make_connection({ uri = ("http://%s:%d"):format(ip, c.port), protocol = "http",
                                          address = c.address, port = c.port, ["local"] = c["local"] }))
                end
            end
        end
    end
    return self
end

function Server:best()
    local best
    for _, c in ipairs(self.connections) do
        if c.state == "ok" then best = best and servers.better(best, c) or c end
    end
    return best
end

-- Test all connections in parallel. onChange(server) fires whenever state/active connection changes.
function Server:connect(onChange)
    if #self.connections == 0 then
        self.state = "offline"
        if onChange then onChange(self) end
        return
    end
    self.state = "testing"
    self.active = nil
    local remaining = #self.connections
    local sawUnauthorized = false

    for _, c in ipairs(self.connections) do
        c.state = "testing"
        local started = love.timer.getTime()
        http.json({ url = c.uri .. "/identity", headers = client.headers(self.accessToken), timeout = TEST_TIMEOUT },
            function(data, err, res)
                remaining = remaining - 1
                local mc = data and (data.MediaContainer or data)
                if mc and mc.machineIdentifier == self.id then
                    c.state = "ok"
                    c.latency = love.timer.getTime() - started
                elseif res and res.status == 401 then
                    c.state = "unauthorized"
                    sawUnauthorized = true
                else
                    c.state = "failed"
                    c.error = err or "identity mismatch"
                end

                local best = self:best()
                if best then
                    self.active = best
                    self.state = "online"
                elseif remaining == 0 then
                    self.state = sawUnauthorized and "unauthorized" or "offline"
                end
                if onChange then onChange(self) end
            end)
    end
end

function Server:baseUrl()
    return self.active and self.active.uri
end

function Server:connectionLabel()
    local c = self.active
    if not c then return self.state end
    if c.relay then return "relay" end
    if c.loopback then return "this PC" end
    return (c.private and "local" or "remote") .. (c.https and " · secure" or "")
end

-- Fetch the server list. callback(list | nil, err)
function servers.fetch(callback)
    local url = http.withQuery(RESOURCES_URL, { includeHttps = 1, includeRelay = 1, includeIPv6 = 1 })
    http.json({ url = url, headers = client.headers(), timeout = 20 }, function(list, err)
        if not list then return callback(nil, err) end
        local out = {}
        for _, res in ipairs(list) do
            local provides = type(res.provides) == "string" and res.provides or ""
            if provides:find("server", 1, true) then out[#out + 1] = new_server(res) end
        end
        table.sort(out, function(a, b)
            if a.owned ~= b.owned then return a.owned end
            if a.presence ~= b.presence then return a.presence end
            return a.name:lower() < b.name:lower()
        end)
        callback(out)
    end)
end

servers._internal = { is_private = is_private, is_loopback = is_loopback, plex_direct_ip = plex_direct_ip }

return servers
