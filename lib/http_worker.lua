-- HTTP worker thread. Pops requests from the shared request channel, performs
-- them with WinHTTP and pushes the result back. Images can be decoded here so
-- the main thread only uploads them to the GPU.
require("love.filesystem")
require("love.image")
require("love.data")

local reqChannel, resChannel = ...
local winhttp = require("lib.winhttp")

while true do
    local job = reqChannel:demand()
    if job == "quit" then break end

    local res, err = winhttp.request({
        url = job.url, method = job.method, body = job.body,
        timeout = job.timeout, insecure = job.insecure,
        headers = job.headers,
    })

    local out = { id = job.id }
    if not res then
        out.error = err
    else
        out.status, out.headers = res.status, res.headers
        if job.decode == "image" and res.status == 200 and #res.body > 0 then
            local ok, img = pcall(function()
                local fd = love.filesystem.newFileData(res.body, "image")
                return love.image.newImageData(fd)
            end)
            if ok then out.image = img else out.error = "image decode: " .. tostring(img) end
        else
            out.body = res.body
        end
    end
    resChannel:push(out)
end
