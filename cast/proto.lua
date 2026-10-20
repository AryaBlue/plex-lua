-- Google Cast v2 wire format: each message is a 4-byte big-endian length then a
-- protobuf CastMessage (cast_channel.proto):
--   1 protocol_version (enum, 0 = CASTV2_1_0)   2 source_id   3 destination_id
--   4 namespace   5 payload_type (0 = STRING, 1 = BINARY)   6 payload_utf8   7 payload_binary
-- Only string payloads are used here (every namespace Reel talks is JSON).

local proto = {}

local char, byte, floor = string.char, string.byte, math.floor

local function varint(n)
    local out = {}
    repeat
        local b = n % 128
        n = floor(n / 128)
        out[#out + 1] = char(n > 0 and b + 128 or b)
    until n == 0
    return table.concat(out)
end

local function field(num, s)
    return varint(num * 8 + 2) .. varint(#s) .. s
end

-- One framed message, ready to send.
function proto.encode(source, dest, namespace, payload)
    local body = "\8\0" .. field(2, source) .. field(3, dest) .. field(4, namespace)
        .. "\40\0" .. field(6, payload)
    local n = #body
    return char(floor(n / 16777216) % 256, floor(n / 65536) % 256, floor(n / 256) % 256, n % 256) .. body
end

local function readVarint(s, i)
    local n, mul = 0, 1
    while true do
        local b = byte(s, i)
        if not b then return nil end
        i = i + 1
        n = n + (b % 128) * mul
        if b < 128 then return n, i end
        mul = mul * 128
    end
end

-- Decode one CastMessage body (without the length prefix).
-- Returns { source, dest, namespace, payload } or nil, err.
function proto.decode(body)
    local msg, i = {}, 1
    while i <= #body do
        local key
        key, i = readVarint(body, i)
        if not key then return nil, "truncated key" end
        local num, wire = floor(key / 8), key % 8
        if wire == 0 then
            local v
            v, i = readVarint(body, i)
            if not v then return nil, "truncated varint" end
            if num == 5 then msg.payloadType = v end
        elseif wire == 2 then
            local len
            len, i = readVarint(body, i)
            if not len or i + len - 1 > #body then return nil, "truncated field" end
            local v = body:sub(i, i + len - 1)
            i = i + len
            if num == 2 then msg.source = v
            elseif num == 3 then msg.dest = v
            elseif num == 4 then msg.namespace = v
            elseif num == 6 then msg.payload = v
            elseif num == 7 then msg.binary = v end
        else
            return nil, "unsupported wire type " .. wire
        end
    end
    return msg
end

-- Splits a byte stream into messages. feed(bytes) returns a list of decoded messages.
function proto.reader()
    local buf = ""
    return function(bytes)
        buf = buf .. bytes
        local out = {}
        while #buf >= 4 do
            local a, b, c, d = byte(buf, 1, 4)
            local n = ((a * 256 + b) * 256 + c) * 256 + d
            if n > 65536 then error("cast: message too large (" .. n .. " bytes)") end
            if #buf < 4 + n then break end
            local msg, err = proto.decode(buf:sub(5, 4 + n))
            buf = buf:sub(5 + n)
            if msg then out[#out + 1] = msg else print("[cast] bad message: " .. err) end
        end
        return out
    end
end

return proto
