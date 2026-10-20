-- Finds cast targets on the network, on its own thread (one pass per start):
--   Chromecasts / Google TV: mDNS query for _googlecast._tcp.local (fn = name, md = model).
--   DIAL devices (Fire TV sticks, smart TVs): SSDP M-SEARCH for the DIAL service, then the
--   device description (friendlyName, and the Application-URL header where its apps live).
-- DIAL is asked by unicast to opts.dialHosts; opts.dialScan also multicasts it to the whole LAN.
--
-- Out: { ev = "device", device = {...} } per device, then { ev = "done" }.
require("love.timer")
require("love.filesystem")

local outCh, opts = ...
local socket = require("socket")
local winhttp = require("lib.winhttp")

local function emit(t) outCh:push(t) end

---------------------------------------------------------------------------
-- DNS message parsing (enough for mDNS answers: PTR, SRV, TXT, A)

local function u16(s, i) return s:byte(i) * 256 + s:byte(i + 1) end

local function readName(s, i, depth)
    local labels = {}
    depth = depth or 0
    while true do
        local len = s:byte(i)
        if not len then return nil, i end
        if len == 0 then return table.concat(labels, "."), i + 1 end
        if len >= 192 then
            if depth > 8 then return nil, i + 2 end
            local rest = readName(s, u16(s, i) % 16384 + 1, depth + 1)
            if rest then labels[#labels + 1] = rest end
            return table.concat(labels, "."), i + 2
        end
        labels[#labels + 1] = s:sub(i + 1, i + len)
        i = i + 1 + len
    end
end

-- Returns { name, model, id, port, host } for the first _googlecast instance in the packet, or nil.
local function parseCast(pkt)
    if #pkt < 12 then return nil end
    local qd, an, ns, ar = u16(pkt, 5), u16(pkt, 7), u16(pkt, 9), u16(pkt, 11)
    local i = 13
    for _ = 1, qd do
        local _, j = readName(pkt, i)
        i = j + 4
    end
    local out, isCast = {}, false
    for _ = 1, an + ns + ar do
        local name, j = readName(pkt, i)
        if not name or j + 10 > #pkt + 1 then break end
        local rtype, rdlen = u16(pkt, j), u16(pkt, j + 8)
        local rd = j + 10
        if name:find("_googlecast._tcp.local", 1, true) then isCast = true end
        if rtype == 16 then          -- TXT: length-prefixed key=value strings
            local k = rd
            while k < rd + rdlen do
                local l = pkt:byte(k)
                local kv = pkt:sub(k + 1, k + l)
                local key, val = kv:match("^([^=]+)=(.*)$")
                if key == "fn" then out.name = val elseif key == "md" then out.model = val
                elseif key == "id" then out.id = val end
                k = k + 1 + l
            end
        elseif rtype == 33 then      -- SRV: priority, weight, port, target
            out.port = u16(pkt, rd + 4)
        elseif rtype == 1 and rdlen == 4 then
            out.host = ("%d.%d.%d.%d"):format(pkt:byte(rd, rd + 3))
        end
        i = rd + rdlen
    end
    if not isCast then return nil end
    return out
end

local function mdnsQuery(service)
    local q = { "\0\0\0\0\0\1\0\0\0\0\0\0" }
    for part in service:gmatch("[^.]+") do q[#q + 1] = string.char(#part) .. part end
    q[#q + 1] = "\0\0\12\0\1"          -- PTR, class IN
    return table.concat(q)
end

local seenCast = {}
local function onCastPacket(pkt, ip)
    local d = parseCast(pkt)
    local host = d and (d.host or ip)
    if d and not seenCast[d.id or host] then
        seenCast[d.id or host] = true
        emit({ ev = "device", device = {
            kind = "chromecast", id = "cc:" .. (d.id or host), name = d.name or host,
            model = d.model, host = host, port = d.port or 8009,
        } })
    end
end

---------------------------------------------------------------------------
-- DIAL

local function msearch()
    return "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\n"
        .. "ST: urn:dial-multiscreen-org:service:dial:1\r\n\r\n"
end

local function xmlTag(body, tag)
    local v = body:match("<" .. tag .. ">%s*(.-)%s*</" .. tag .. ">")
    return v and v:gsub("&amp;", "&"):gsub("&apos;", "'"):gsub("&#39;", "'"):gsub("&quot;", '"')
end

local function isBlocked(name, host)
    for _, b in ipairs(opts.block or {}) do
        if b == name or b == host then return true end
    end
    return false
end

local function describe(location, ip, seen)
    if seen[location] then return end
    seen[location] = true
    local host = location:match("^%a+://([^/:]+)") or ip
    if isBlocked(nil, host) then return end
    local res = winhttp.request({ url = location, timeout = 3 })
    if not res or res.status ~= 200 then return end
    local name = xmlTag(res.body, "friendlyName") or host
    if isBlocked(name, host) then
        print("[cast] skipping blocked device " .. name)
        return
    end
    local appUrl = res.headers and res.headers:match("[Aa]pplication%-URL:%s*([^\r\n]+)")
    if not appUrl then return end
    emit({ ev = "device", device = {
        kind = "dial", id = "dial:" .. (xmlTag(res.body, "UDN") or host), name = name,
        model = xmlTag(res.body, "modelName"), manufacturer = xmlTag(res.body, "manufacturer"),
        host = host, appUrl = appUrl:gsub("/+$", ""),
    } })
end

-- Where DIAL devices usually serve their description: Fire TV, then Android / Google TV.
local DESCRIPTIONS = { "http://%s:60000/dd.xml", "http://%s:8008/ssdp/device-desc.xml" }

local function udpSocket()
    local udp = (socket.udp4 or socket.udp)()      -- IPv4: "*" alone can bind an IPv6 socket
    udp:settimeout(0)
    udp:setsockname("0.0.0.0", 0)
    return udp
end

-- Both scans run together for opts.wait seconds; each query is sent twice (UDP drops packets).
local function scan(wait)
    local mdns, ssdp = udpSocket(), udpSocket()
    local mdnsTarget = opts.mdnsTarget or { "224.0.0.251", 5353 }
    local query = mdnsQuery("_googlecast._tcp.local")
    local function ask()
        if opts.chromecast ~= false then mdns:sendto(query, mdnsTarget[1], mdnsTarget[2]) end
        for _, h in ipairs(opts.dialHosts or {}) do
            if not isBlocked(nil, h) then ssdp:sendto(msearch(), h, opts.ssdpPort or 1900) end
        end
        if opts.dialScan then ssdp:sendto(msearch(), "239.255.255.250", 1900) end
    end
    ask()
    local seen, resent = {}, false
    -- Fire TV sticks don't answer an M-SEARCH sent straight to them (only the multicast
    -- one), so for the listed hosts also read the usual description addresses directly.
    for _, h in ipairs(opts.dialHosts or {}) do
        if not isBlocked(nil, h) then
            for _, loc in ipairs(opts.dialDescriptions or DESCRIPTIONS) do
                local ok, err = pcall(describe, loc:format(h), h, seen)
                if not ok then print("[cast] DIAL: " .. tostring(err)) end
            end
        end
    end
    local start = love.timer.getTime()
    while love.timer.getTime() - start < wait do
        if not resent and love.timer.getTime() - start > 0.8 then resent = true; ask() end
        local got = false
        local pkt, ip = mdns:receivefrom()
        if pkt then got = true; pcall(onCastPacket, pkt, ip) end
        pkt, ip = ssdp:receivefrom()
        if pkt then
            got = true
            local loc = pkt:match("[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:%s*(%S+)")
            if loc then
                local ok, err = pcall(describe, loc, ip, seen)
                if not ok then print("[cast] DIAL: " .. tostring(err)) end
            end
        end
        if not got then love.timer.sleep(0.02) end
    end
    mdns:close()
    ssdp:close()
end

local ok, err = pcall(scan, opts.wait or 2.5)
if not ok then print("[cast] discovery: " .. tostring(err)) end
emit({ ev = "done" })
