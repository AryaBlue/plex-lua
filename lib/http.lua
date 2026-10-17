-- Non-blocking HTTP for the main thread. Requests run on a pool of worker
-- threads; call http.update() every frame to receive callbacks.
--
--   http.request({ url=..., headers={...}, timeout=10 }, function(res, err) end)
--   res = { status, headers (raw string), body | image (ImageData) }

local json = require("lib.json")

local http = {}

local WORKERS = 6
local reqChannel = love.thread.newChannel()
local resChannel = love.thread.newChannel()
local threads = {}
local pending = {}
local nextId = 0

function http.init()
    if #threads > 0 then return end
    for i = 1, WORKERS do
        local t = love.thread.newThread("lib/http_worker.lua")
        t:start(reqChannel, resChannel)
        threads[i] = t
    end
end

-- Returns a handle with :cancel() (the callback is dropped; the request itself still finishes).
function http.request(opts, callback)
    http.init()
    nextId = nextId + 1
    local id = nextId
    pending[id] = { callback = callback, url = opts.url }
    reqChannel:push({
        id = id, url = opts.url, method = opts.method or "GET",
        headers = opts.headers, body = opts.body, timeout = opts.timeout or 20,
        insecure = opts.insecure, decode = opts.decode,
    })
    return { cancel = function() pending[id] = nil end }
end

-- Convenience: JSON request. callback(data, err, res)
function http.json(opts, callback)
    opts.headers = opts.headers or {}
    opts.headers["Accept"] = "application/json"
    return http.request(opts, function(res, err)
        if not res then return callback(nil, err) end
        if res.status < 200 or res.status >= 300 then
            return callback(nil, ("HTTP %d"):format(res.status), res)
        end
        if res.body == nil or res.body == "" then return callback({}, nil, res) end
        local ok, data = pcall(json.decode, res.body)
        if not ok then return callback(nil, "bad JSON: " .. tostring(data), res) end
        callback(data, nil, res)
    end)
end

function http.update()
    for _, t in ipairs(threads) do
        local err = t:getError()
        if err then error("HTTP worker crashed: " .. err) end
    end
    while true do
        local msg = resChannel:pop()
        if not msg then break end
        local p = pending[msg.id]
        pending[msg.id] = nil
        if p and p.callback then
            if msg.error then p.callback(nil, msg.error) else p.callback(msg) end
        end
    end
end

function http.pendingCount()
    local n = 0
    for _ in pairs(pending) do n = n + 1 end
    return n
end

function http.shutdown()
    for _ = 1, #threads do reqChannel:push("quit") end
end

-- Build "a=1&b=2" (values URL-encoded, keys sorted for stable URLs/cache keys).
function http.encode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c) return ("%%%02X"):format(c:byte()) end))
end

function http.query(params)
    local keys = {}
    for k in pairs(params) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = http.encode(k) .. "=" .. http.encode(params[k]) end
    return table.concat(parts, "&")
end

function http.withQuery(url, params)
    if not params or next(params) == nil then return url end
    return url .. (url:find("?", 1, true) and "&" or "?") .. http.query(params)
end

return http
