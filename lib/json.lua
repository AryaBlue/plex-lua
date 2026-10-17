-- Minimal JSON decoder/encoder. Decodes objects to tables, arrays to sequences,
-- null to json.null (a sentinel) so array holes stay visible.

local json = {}
json.null = setmetatable({}, { __tostring = function() return "null" end })

local byte, sub, find, char, concat = string.byte, string.sub, string.find, string.char, table.concat
local tonumber, floor = tonumber, math.floor

local escapes = { [34] = '"', [92] = "\\", [47] = "/", [98] = "\b", [102] = "\f", [110] = "\n", [114] = "\r", [116] = "\t" }

local function utf8_char(cp)
    if cp < 0x80 then return char(cp)
    elseif cp < 0x800 then return char(0xC0 + floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return char(0xE0 + floor(cp / 0x1000), 0x80 + floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return char(0xF0 + floor(cp / 0x40000), 0x80 + floor(cp / 0x1000) % 0x40,
                0x80 + floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local decode_value

local function decode_error(s, i, msg)
    error(("json: %s at position %d near '%s'"):format(msg, i, sub(s, i, i + 15)), 0)
end

local function skip_ws(s, i)
    return (find(s, "[^ \t\r\n]", i)) or #s + 1
end

local function decode_string(s, i)
    -- i points at the opening quote
    local parts, n = {}, 0
    local j = i + 1
    while true do
        local k = find(s, '["\\]', j)
        if not k then decode_error(s, i, "unterminated string") end
        if k > j then n = n + 1; parts[n] = sub(s, j, k - 1) end
        if byte(s, k) == 34 then return concat(parts), k + 1 end
        local e = byte(s, k + 1)
        if e == 117 then -- \uXXXX
            local cp = tonumber(sub(s, k + 2, k + 5), 16)
            if not cp then decode_error(s, k, "bad unicode escape") end
            j = k + 6
            if cp >= 0xD800 and cp <= 0xDBFF and sub(s, j, j + 1) == "\\u" then
                local lo = tonumber(sub(s, j + 2, j + 5), 16)
                if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                    cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                    j = j + 6
                end
            end
            n = n + 1; parts[n] = utf8_char(cp)
        else
            local c = escapes[e]
            if not c then decode_error(s, k, "bad escape") end
            n = n + 1; parts[n] = c
            j = k + 2
        end
    end
end

local function decode_number(s, i)
    local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
    local v = num and tonumber(num)
    if not v then decode_error(s, i, "bad number") end
    return v, i + #num
end

local function decode_array(s, i)
    local arr, n = {}, 0
    i = skip_ws(s, i + 1)
    if byte(s, i) == 93 then return arr, i + 1 end
    while true do
        local v
        v, i = decode_value(s, i)
        n = n + 1; arr[n] = v
        i = skip_ws(s, i)
        local c = byte(s, i)
        if c == 93 then return arr, i + 1 end
        if c ~= 44 then decode_error(s, i, "expected ',' or ']'") end
        i = skip_ws(s, i + 1)
    end
end

local function decode_object(s, i)
    local obj = {}
    i = skip_ws(s, i + 1)
    if byte(s, i) == 125 then return obj, i + 1 end
    while true do
        if byte(s, i) ~= 34 then decode_error(s, i, "expected key") end
        local k
        k, i = decode_string(s, i)
        i = skip_ws(s, i)
        if byte(s, i) ~= 58 then decode_error(s, i, "expected ':'") end
        local v
        v, i = decode_value(s, skip_ws(s, i + 1))
        obj[k] = v
        i = skip_ws(s, i)
        local c = byte(s, i)
        if c == 125 then return obj, i + 1 end
        if c ~= 44 then decode_error(s, i, "expected ',' or '}'") end
        i = skip_ws(s, i + 1)
    end
end

decode_value = function(s, i)
    local c = byte(s, i)
    if c == 34 then return decode_string(s, i)
    elseif c == 123 then return decode_object(s, i)
    elseif c == 91 then return decode_array(s, i)
    elseif c == 116 and sub(s, i, i + 3) == "true" then return true, i + 4
    elseif c == 102 and sub(s, i, i + 4) == "false" then return false, i + 5
    elseif c == 110 and sub(s, i, i + 3) == "null" then return json.null, i + 4
    end
    return decode_number(s, i)
end

function json.decode(s)
    if type(s) ~= "string" then error("json: expected string, got " .. type(s), 2) end
    local v, i = decode_value(s, skip_ws(s, 1))
    i = skip_ws(s, i)
    if i <= #s then decode_error(s, i, "trailing garbage") end
    return v
end

local function encode_string(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        local b = byte(c)
        if c == '"' then return '\\"' elseif c == "\\" then return "\\\\"
        elseif c == "\n" then return "\\n" elseif c == "\r" then return "\\r" elseif c == "\t" then return "\\t" end
        return ("\\u%04x"):format(b)
    end) .. '"'
end

local function encode(v, out)
    local t = type(v)
    if v == nil or v == json.null then out[#out + 1] = "null"
    elseif t == "boolean" then out[#out + 1] = tostring(v)
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then error("json: cannot encode " .. tostring(v)) end
        out[#out + 1] = (v == floor(v) and v >= -1e15 and v <= 1e15) and ("%d"):format(v) or ("%.17g"):format(v)
    elseif t == "string" then out[#out + 1] = encode_string(v)
    elseif t == "table" then
        if #v > 0 or next(v) == nil then
            out[#out + 1] = "["
            for i = 1, #v do
                if i > 1 then out[#out + 1] = "," end
                encode(v[i], out)
            end
            out[#out + 1] = "]"
        else
            out[#out + 1] = "{"
            local first = true
            for k, val in pairs(v) do
                if not first then out[#out + 1] = "," end
                first = false
                out[#out + 1] = encode_string(tostring(k))
                out[#out + 1] = ":"
                encode(val, out)
            end
            out[#out + 1] = "}"
        end
    else
        error("json: cannot encode " .. t)
    end
end

function json.encode(v)
    local out = {}
    encode(v, out)
    return concat(out)
end

return json
