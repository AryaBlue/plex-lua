-- Shared drawing helpers: fonts, colour, text fitting, an image cache that
-- loads artwork through the HTTP worker pool.

local theme = require("theme")
local http = require("lib.http")
local utf8 = require("utf8")

local gfx = {}

-- Fonts: Windows' Segoe UI (semibold for large sizes), Microsoft YaHei for
-- CJK and Malgun Gothic for Hangul so titles like 【推しの子】 render. Falls
-- back to LÖVE's built-in font when the system fonts aren't there.
-- One face per string instead of Font:setFallbacks: on LÖVE 12 fallback glyph
-- runs get drawn out of order ("【OSHI NO KO】" came out as "【】 OSHI NO KO").
local FONT_DIR = (os.getenv("WINDIR") or "C:/Windows") .. "/Fonts/"
local FACES = {
    latin = { regular = "segoeui.ttf", semibold = "seguisb.ttf" },
    cjk = { regular = "msyh.ttc", semibold = "msyhbd.ttc" },
    hangul = { regular = "malgun.ttf", semibold = "malgunbd.ttf" },
}
local fontData = {}

-- Which script family a string needs: "latin", "cjk" or "hangul".
local function scriptOf(s)
    -- quick reject: CJK/Hangul (U+1100.., U+2E80..U+FFEF) are 3-byte sequences starting E1 or E2..EF
    if not s or not s:find("[\225-\239]") then return "latin" end
    local family = "latin"
    local ok = pcall(function()
        for _, cp in utf8.codes(s) do
            if (cp >= 0xAC00 and cp <= 0xD7AF) or (cp >= 0x1100 and cp <= 0x11FF) or (cp >= 0x3130 and cp <= 0x318F) then
                family = "hangul"
                return
            elseif (cp >= 0x2E80 and cp <= 0x9FFF) or (cp >= 0xF900 and cp <= 0xFAFF) or (cp >= 0xFF00 and cp <= 0xFFEF) then
                family = "cjk"
            end
        end
    end)
    return ok and family or "latin"
end
gfx.scriptOf = scriptOf

local function loadFace(file)
    if fontData[file] == nil then
        local fh = io.open(FONT_DIR .. file, "rb")
        if fh then
            fontData[file] = love.filesystem.newFileData(fh:read("*a"), file)
            fh:close()
        else
            fontData[file] = false
        end
    end
    return fontData[file] or nil
end

local fontCache = {}
-- gfx.font(size [, text]): pass the text when it may contain CJK/Hangul.
function gfx.font(size, text)
    size = math.floor(size + 0.5)
    local family = scriptOf(text)
    local key = family .. size
    local f = fontCache[key]
    if f then return f end
    local faces = FACES[family]
    local data = loadFace(size >= 36 and faces.semibold or faces.regular) or loadFace(faces.regular)
                 or loadFace(FACES.latin.regular)
    f = data and love.graphics.newFont(data, size) or love.graphics.newFont(size)
    fontCache[key] = f
    return f
end

function gfx.color(c, a)
    love.graphics.setColor(c[1], c[2], c[3], a or c[4] or 1)
end

-- Base unit scales with window height so the layout works from 540p to 4K.
function gfx.unit()
    return love.graphics.getHeight() / 1080
end

function gfx.text(str, x, y, size, color, alpha)
    love.graphics.setFont(gfx.font(size, str))
    gfx.color(color or theme.text, alpha)
    love.graphics.print(str, math.floor(x), math.floor(y))
end

function gfx.textCentered(str, cx, y, size, color, alpha)
    local f = gfx.font(size, str)
    love.graphics.setFont(f)
    gfx.color(color or theme.text, alpha)
    love.graphics.print(str, math.floor(cx - f:getWidth(str) / 2), math.floor(y))
end

-- Width of a string in the font it will be drawn with.
function gfx.width(str, size)
    return gfx.font(size, str):getWidth(str)
end

-- Shorten to fit width with an ellipsis (cuts only between characters).
function gfx.fit(str, size, width)
    local f = gfx.font(size, str)
    if f:getWidth(str) <= width then return str end
    local ok, n = pcall(utf8.len, str)
    if not ok or not n then return str end
    local function prefix(chars)
        local stop = utf8.offset(str, chars + 1)
        return stop and str:sub(1, stop - 1) or str
    end
    local lo, hi = 0, n
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if f:getWidth(prefix(mid) .. "…") <= width then lo = mid else hi = mid - 1 end
    end
    return (prefix(lo):gsub("%s+$", "")) .. "…"
end

function gfx.wrapped(str, x, y, width, size, color, maxLines, alpha)
    local f = gfx.font(size, str)
    local _, lines = f:getWrap(str or "", width)
    love.graphics.setFont(f)
    gfx.color(color or theme.text, alpha)
    local n = maxLines and math.min(maxLines, #lines) or #lines
    for i = 1, n do
        local line = lines[i]
        if maxLines and i == n and #lines > n then line = gfx.fit(line .. " …", size, width) end
        love.graphics.print(line, math.floor(x), math.floor(y + (i - 1) * f:getHeight()))
    end
    return n * f:getHeight()
end

function gfx.roundRect(mode, x, y, w, h, r)
    love.graphics.rectangle(mode, x, y, w, h, r, r)
end

-- Draw an image scaled to cover the box (cropping the overflow).
-- ax, ay (0..1) choose which part survives the crop; default centre.
local coverQuad
function gfx.drawCover(img, x, y, w, h, alpha, ax, ay)
    local iw, ih = img:getDimensions()
    local s = math.max(w / iw, h / ih)
    local qw, qh = w / s, h / s
    coverQuad = coverQuad or love.graphics.newQuad(0, 0, 1, 1, 1, 1)
    coverQuad:setViewport((iw - qw) * (ax or 0.5), (ih - qh) * (ay or 0.5), qw, qh, iw, ih)
    love.graphics.setColor(1, 1, 1, alpha or 1)
    love.graphics.draw(img, coverQuad, x, y, 0, s, s)
end

-- Exponential approach that is frame-rate independent.
-- Image cropped to a circle (avatars): a triangle fan whose texture coords
-- cover-fit the image, so no stencil is needed.
local circleMesh
local CIRCLE_SEGMENTS = 48
function gfx.circleImage(img, cx, cy, r, alpha)
    if not circleMesh then
        circleMesh = love.graphics.newMesh(CIRCLE_SEGMENTS + 2, "fan", "dynamic")
    end
    local iw, ih = img:getDimensions()
    local su, sv = math.min(1, ih / iw), math.min(1, iw / ih)   -- share of the texture across the circle
    circleMesh:setVertex(1, 0, 0, 0.5, 0.5)
    for i = 0, CIRCLE_SEGMENTS do
        local a = i / CIRCLE_SEGMENTS * math.pi * 2
        local c, s = math.cos(a), math.sin(a)
        circleMesh:setVertex(i + 2, c, s, 0.5 + c * su / 2, 0.5 + s * sv / 2)
    end
    circleMesh:setTexture(img)
    love.graphics.setColor(1, 1, 1, alpha or 1)
    love.graphics.draw(circleMesh, cx, cy, 0, r, r)
end

function gfx.approach(cur, target, dt, speed)
    return cur + (target - cur) * (1 - math.exp(-(speed or 14) * dt))
end

-- Vertical gradient strip from colour c at alpha a0 (top) to a1 (bottom).
local gradMesh
function gfx.vgradient(x, y, w, h, c, a0, a1)
    gradMesh = gradMesh or love.graphics.newMesh({ { 0, 0, 0, 0 }, { 1, 0, 0, 0 }, { 1, 1, 0, 0 }, { 0, 1, 0, 0 } }, "fan", "dynamic")
    gradMesh:setVertices({
        { 0, 0, 0, 0, c[1], c[2], c[3], a0 }, { 1, 0, 0, 0, c[1], c[2], c[3], a0 },
        { 1, 1, 0, 0, c[1], c[2], c[3], a1 }, { 0, 1, 0, 0, c[1], c[2], c[3], a1 },
    })
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(gradMesh, x, y, 0, w, h)
end

-- Horizontal gradient: alpha a0 at the left edge to a1 at the right.
function gfx.hgradient(x, y, w, h, c, a0, a1)
    gradMesh = gradMesh or love.graphics.newMesh({ { 0, 0, 0, 0 }, { 1, 0, 0, 0 }, { 1, 1, 0, 0 }, { 0, 1, 0, 0 } }, "fan", "dynamic")
    gradMesh:setVertices({
        { 0, 0, 0, 0, c[1], c[2], c[3], a0 }, { 1, 0, 0, 0, c[1], c[2], c[3], a1 },
        { 1, 1, 0, 0, c[1], c[2], c[3], a1 }, { 0, 1, 0, 0, c[1], c[2], c[3], a0 },
    })
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(gradMesh, x, y, 0, w, h)
end

function gfx.spinner(cx, cy, r, color)
    local t = love.timer.getTime()
    gfx.color(color or theme.accent)
    love.graphics.setLineWidth(math.max(2, r / 6))
    love.graphics.arc("line", "open", cx, cy, r, t * 6, t * 6 + 4.2)
end

---------------------------------------------------------------------------
-- Remote image cache (LRU by last use).

local images = {}        -- url -> { image, state, lastUsed }
local MAX_IMAGES = 220
local inflight = 0
local MAX_INFLIGHT = 8
local queue = {}

local function evict()
    local count, oldestUrl, oldest = 0, nil, math.huge
    for url, e in pairs(images) do
        count = count + 1
        if e.state ~= "loading" and e.lastUsed < oldest then oldest, oldestUrl = e.lastUsed, url end
    end
    if count > MAX_IMAGES and oldestUrl then
        local e = images[oldestUrl]
        if e.image then e.image:release() end
        images[oldestUrl] = nil
    end
end

local function start(url)
    local e = images[url]
    inflight = inflight + 1
    http.request({ url = url, decode = "image", timeout = 30, headers = { Accept = "image/jpeg,image/*" } },
        function(res)
            inflight = inflight - 1
            if res and res.image then
                e.image = love.graphics.newImage(res.image, { mipmaps = true })
                e.image:setFilter("linear", "linear")
                e.image:setMipmapFilter("linear")
                res.image:release()
                e.state = "ready"
                e.loadedAt = love.timer.getTime()
            else
                e.state = "failed"
            end
        end)
end

-- Returns the Image if loaded (and how long ago, for fade-in), else nil (and starts loading).
function gfx.remote(url)
    if not url then return nil end
    local e = images[url]
    local now = love.timer.getTime()
    if not e then
        e = { state = "loading", lastUsed = now }
        images[url] = e
        queue[#queue + 1] = url
        evict()
    end
    e.lastUsed = now
    if e.image then return e.image, now - e.loadedAt end
    return nil
end

function gfx.update()
    -- Newest requests first: what's on screen now matters more than what scrolled past.
    while inflight < MAX_INFLIGHT and #queue > 0 do
        local url = table.remove(queue)
        local e = images[url]
        if e and e.state == "loading" and love.timer.getTime() - e.lastUsed < 1 then
            start(url)
        elseif e and e.state == "loading" then
            images[url] = nil   -- scrolled away before we got to it
        end
    end
end

return gfx
