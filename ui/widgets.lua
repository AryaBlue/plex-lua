-- Reusable pieces of the browse UI: artwork cards, buttons, backdrop, nav tabs.
-- `focus` arguments are animated 0..1 values so focus changes ease in and out.

local theme = require("theme")
local gfx = require("ui.gfx")
local api = require("plex.api")

local W = {}

W.POSTER_ASPECT = 1.5      -- height / width
W.WIDE_ASPECT = 9 / 16

-- Which card shape a hub/item should use.
function W.kindFor(item, hub)
    if hub then
        local id = (hub.hubIdentifier or "") .. (hub.context or "")
        if id:find("continue") or id:find("ondeck") or id:find("inprogress") then return "wide" end
        if hub.type == "episode" or hub.type == "clip" then return "wide" end
    end
    if item and (item.type == "episode" or item.type == "clip") then return "wide" end
    return "poster"
end

local function imagePath(item, kind)
    if kind == "wide" then
        if item.type == "episode" then return item.thumb or item.art or item.grandparentArt end
        return item.art or item.thumb
    end
    return api.posterPath(item)
end

-- Remote image for an item, requested at the size it's drawn (rounded up so
-- small focus scaling doesn't refetch).
function W.itemImage(server, path, w, h)
    if not path then return nil end
    if path:find("^https?://") then return gfx.remote(path) end   -- already a full URL (Seerr / TMDB)
    local bw = math.ceil(w / 64) * 64
    local bh = math.ceil(h / 64) * 64
    return gfx.remote(api.imageUrl(server, path, bw, bh))
end

local function playIcon(cx, cy, r)
    love.graphics.polygon("fill", cx - r * 0.45, cy - r * 0.6, cx - r * 0.45, cy + r * 0.6, cx + r * 0.6, cy)
end
W.playIcon = playIcon

function W.progressBar(x, y, w, h, frac, alpha)
    gfx.color({ 0.3, 0.3, 0.33 }, 0.9 * (alpha or 1))
    love.graphics.rectangle("fill", x, y, w, h)
    gfx.color(theme.accent, alpha)
    love.graphics.rectangle("fill", x, y, w * math.max(0, math.min(1, frac)), h)
end

-- Short label for a Seerr media status.
function W.requestStatus(status)
    return ({ [2] = "Requested", [3] = "Processing", [4] = "Partly available", [5] = "Available",
              [6] = "Blocked", [7] = "Deleted" })[status] or "Not requested"
end

-- Which card of a row is drawn last (on top): the one most in focus. While focus
-- moves, the old card is still fading out; it's drawn normally, not skipped.
function W.topCard(anim, first, last)
    local best, top = 0.02, nil
    for i = first, last do
        local a = anim[i] or 0
        if a > best then best, top = a, i end
    end
    return top
end

-- An artwork card. Returns nothing; draws title under the card when focused.
function W.card(server, item, x, y, w, h, focus, kind)
    local u = gfx.unit()
    focus = focus or 0
    local s = 1 + 0.07 * focus
    local cx, cy = x + w / 2, y + h / 2
    local dw, dh = w * s, h * s
    local dx, dy = cx - dw / 2, cy - dh / 2

    -- shadow
    love.graphics.setColor(0, 0, 0, 0.35 + 0.25 * focus)
    gfx.roundRect("fill", dx + 4 * u, dy + 8 * u, dw, dh, 8 * u)

    local img, age = W.itemImage(server, imagePath(item, kind), w, h)
    gfx.color(theme.surface)
    gfx.roundRect("fill", dx, dy, dw, dh, 6 * u)
    if img then
        gfx.drawCover(img, dx, dy, dw, dh, math.min(1, age * 4), 0.5, kind == "wide" and 0.3 or 0.5)
    else
        -- placeholder: title on a tinted tile
        gfx.wrapped(api.displayTitle(item), dx + 14 * u, dy + dh / 2 - 30 * u, dw - 28 * u, 22 * u, theme.textDim, 3)
    end

    if kind == "wide" then
        -- caption inside the image
        gfx.vgradient(dx, dy + dh * 0.45, dw, dh * 0.55, { 0, 0, 0 }, 0, 0.85)
        local title = api.displayTitle(item)
        gfx.text(gfx.fit(title, 24 * u * s, dw - 24 * u), dx + 12 * u, dy + dh - 62 * u * s, 24 * u * s)
        local sub = item.type == "episode" and api.subtitle(item):gsub("  .*$", "") .. "  " .. (item.title or "") or api.subtitle(item)
        gfx.text(gfx.fit(sub, 18 * u * s, dw - 24 * u), dx + 12 * u, dy + dh - 32 * u * s, 18 * u * s, theme.textDim)
    end

    local prog = api.progress(item)
    if prog and prog > 0.01 then
        W.progressBar(dx, dy + dh - 5 * u, dw, 5 * u, prog)
    end

    -- request state of a Seerr result
    if item.seerr and item.status and item.status > 1 and item.status ~= 7 then
        local label = W.requestStatus(item.status)
        local f = gfx.font(16 * u)
        local bw = f:getWidth(label) + 18 * u
        gfx.color(item.status == 4 and theme.accent or theme.surfaceHi, 0.95)
        gfx.roundRect("fill", dx + 8 * u, dy + 8 * u, bw, 26 * u, 13 * u)
        gfx.text(label, dx + 17 * u, dy + 11 * u, 16 * u, theme.text)
    end

    -- unwatched episode count (shows / seasons)
    local leaves, viewed = tonumber(item.leafCount), tonumber(item.viewedLeafCount)
    if leaves and viewed and leaves > viewed and (item.type == "show" or item.type == "season") then
        local label = tostring(leaves - viewed)
        local f = gfx.font(18 * u)
        local bw = math.max(30 * u, f:getWidth(label) + 16 * u)
        gfx.color(theme.accent)
        gfx.roundRect("fill", dx + dw - bw - 8 * u, dy + 8 * u, bw, 28 * u, 14 * u)
        gfx.textCentered(label, dx + dw - bw / 2 - 8 * u, dy + 11 * u, 18 * u, theme.text)
    elseif (tonumber(item.viewCount) or 0) > 0 and not prog and item.type ~= "show" then
        gfx.color(theme.success, 0.9)
        love.graphics.circle("fill", dx + dw - 22 * u, dy + 22 * u, 13 * u)
        love.graphics.setColor(0, 0, 0, 0.8)
        love.graphics.setLineWidth(3 * u)
        love.graphics.line(dx + dw - 28 * u, dy + 22 * u, dx + dw - 23 * u, dy + 27 * u, dx + dw - 15 * u, dy + 17 * u)
    end

    if focus > 0.01 then
        gfx.color(theme.text, focus)
        love.graphics.setLineWidth(3 * u)
        gfx.roundRect("line", dx - 2 * u, dy - 2 * u, dw + 4 * u, dh + 4 * u, 8 * u)
        if kind ~= "wide" then
            gfx.text(gfx.fit(api.displayTitle(item), 22 * u, dw + 40 * u), dx, dy + dh + 12 * u, 22 * u, theme.text, focus)
            gfx.text(gfx.fit(api.subtitle(item), 18 * u, dw + 40 * u), dx, dy + dh + 40 * u, 18 * u, theme.textDim, focus)
        end
    end
end

-- Pill button. kind = "primary" (filled white), "secondary" (translucent).
function W.button(label, x, y, h, focus, opts)
    opts = opts or {}
    local u = gfx.unit()
    local size = h * 0.42
    local f = gfx.font(size)
    local iconW = opts.icon and h * 0.55 or 0
    local w = opts.width or (f:getWidth(label) + h * 0.9 + iconW)
    local primary = opts.primary
    local s = 1 + 0.05 * focus
    local dw, dh = w * s, h * s
    local dx, dy = x + (w - dw) / 2, y + (h - dh) / 2

    if primary then
        local c = { 1, 1, 1 }
        gfx.color(c, 0.85 + 0.15 * focus)
    else
        gfx.color(theme.surfaceHi, 0.75 + 0.25 * focus)
    end
    gfx.roundRect("fill", dx, dy, dw, dh, 8 * u)
    if focus > 0.01 then
        gfx.color(theme.accent, focus)
        love.graphics.setLineWidth(3 * u)
        gfx.roundRect("line", dx - 3 * u, dy - 3 * u, dw + 6 * u, dh + 6 * u, 10 * u)
    end
    local tc = primary and { 0.05, 0.05, 0.06 } or theme.text
    local tx = dx + (dw - f:getWidth(label) - iconW) / 2 + iconW
    if opts.icon == "play" then
        gfx.color(tc)
        playIcon(tx - iconW * 0.55, dy + dh / 2, h * 0.32)
    elseif opts.icon == "info" then
        gfx.color(tc)
        love.graphics.setLineWidth(2.5 * u)
        love.graphics.circle("line", tx - iconW * 0.55, dy + dh / 2, h * 0.2)
        gfx.textCentered("i", tx - iconW * 0.55, dy + dh / 2 - size * 0.42, size * 0.75, tc)
    elseif opts.icon == "check" then
        gfx.color(tc)
        love.graphics.setLineWidth(3 * u)
        local ix = tx - iconW * 0.55
        love.graphics.line(ix - h * 0.15, dy + dh / 2, ix - h * 0.03, dy + dh / 2 + h * 0.12, ix + h * 0.17, dy + dh / 2 - h * 0.12)
    elseif opts.icon == "restart" then
        gfx.color(tc)
        love.graphics.setLineWidth(2.5 * u)
        local ix, iy = tx - iconW * 0.55, dy + dh / 2
        love.graphics.arc("line", "open", ix, iy, h * 0.18, -2.2, 3.3)
        love.graphics.polygon("fill", ix - h * 0.27, iy - h * 0.14, ix - h * 0.05, iy - h * 0.2, ix - h * 0.2, iy + h * 0.02)
    end
    gfx.text(label, tx, math.floor(dy + dh / 2 - (f:getBaseline() - size * 0.35) + 0.5), size, tc)
    if opts.progress then
        W.progressBar(dx + 12 * u, dy + dh - 7 * u, dw - 24 * u, 3 * u, opts.progress)
    end
    return w
end

---------------------------------------------------------------------------
-- Backdrop: full-screen art that crossfades when the target item changes.

local Backdrop = {}
Backdrop.__index = Backdrop

function W.newBackdrop()
    return setmetatable({ layers = {} }, Backdrop)
end

function Backdrop:set(server, path)
    local cur = self.layers[#self.layers]
    if cur and cur.path == path then return end
    self.layers[#self.layers + 1] = { server = server, path = path, alpha = 0 }
    if #self.layers > 3 then table.remove(self.layers, 1) end
end

function Backdrop:update(dt)
    local top = self.layers[#self.layers]
    if not top then return end
    local w, h = love.graphics.getDimensions()
    local img = top.path and W.itemImage(top.server, top.path, w, h)
    if img or not top.path then top.alpha = math.min(1, top.alpha + dt * 2.5) end
    -- once the newest layer is opaque the older ones are invisible
    if top.alpha >= 1 then
        while #self.layers > 1 do table.remove(self.layers, 1) end
    end
end

-- Draw cover art in the region; ay picks the crop anchor.
function Backdrop:draw(x, y, w, h, alpha, ay)
    for _, l in ipairs(self.layers) do
        local img = l.path and W.itemImage(l.server, l.path, love.graphics.getWidth(), love.graphics.getHeight())
        if img then gfx.drawCover(img, x, y, w, h, l.alpha * (alpha or 1), 0.5, ay or 0.2) end
    end
end

---------------------------------------------------------------------------
local function pointerIn(x, y, w, h)
    if require("lib.input").lastDevice ~= "mouse" then return false end
    local mx, my = love.mouse.getPosition()
    return mx >= x and mx < x + w and my >= y and my < y + h
end
W.pointerIn = pointerIn

-- The signed-in user's picture in a circle, or their initial until it loads.
function W.avatar(cx, cy, r, alpha)
    local client = require("plex.client")
    local img = gfx.remote(client.settings.userThumb)
    if img then return gfx.circleImage(img, cx, cy, r, alpha) end
    gfx.color(theme.accentDark, alpha)
    love.graphics.circle("fill", cx, cy, r)
    local letter = (client.settings.userName or "?"):match("^[%z\1-\127\194-\244][\128-\191]*") or "?"
    local size = r * 1.1
    gfx.textCentered(letter:upper(), cx, cy - gfx.font(size, letter):getHeight() / 2, size, theme.text, alpha)
end

---------------------------------------------------------------------------
-- Top navigation bar. tabs = { {label=...}, ... }; sel = selected index or nil.
-- A tab with `profile = true` is the avatar at the right end; rightText sits
-- just left of it.

function W.navBar(tabs, sel, focused, focusAnim, rightText)
    local w = love.graphics.getWidth()
    local u = gfx.unit()
    gfx.vgradient(0, 0, w, 150 * u, { 0, 0, 0 }, 0.75, 0)
    local x = 70 * u
    gfx.color(theme.accent)
    gfx.roundRect("fill", x, 34 * u, 7 * u, 40 * u, 3 * u)
    gfx.text(theme.appName, x + 18 * u, 26 * u, 44 * u)
    x = x + 18 * u + gfx.width(theme.appName, 44 * u) + 60 * u
    local right = w - 70 * u
    for i, tab in ipairs(tabs) do
        local isSel = i == sel
        if tab.profile then
            local r = 24 * u
            local cx, cy = right - r, 53 * u
            if (isSel and focused) or pointerIn(cx - r, cy - r, 2 * r, 2 * r) then
                gfx.color(theme.accent)
                love.graphics.setLineWidth(3 * u)
                love.graphics.circle("line", cx, cy, r + 4 * u)
            end
            W.avatar(cx, cy, r)
            tab._x, tab._w = cx - r, 2 * r
            right = cx - r - 24 * u
        else
            local tw = gfx.width(tab.label, 26 * u)
            local col = isSel and theme.text or theme.textDim
            if isSel and focused then
                gfx.color(theme.surfaceHi, 0.8 * focusAnim)
                gfx.roundRect("fill", x - 16 * u, 30 * u, tw + 32 * u, 46 * u, 23 * u)
            end
            -- centre the capitals on the pill (font boxes carry extra room below the baseline)
            local f = gfx.font(26 * u, tab.label)
            local ty = 53 * u - (f:getBaseline() - 26 * u * 0.35)
            gfx.text(tab.label, x, math.floor(ty + 0.5), 26 * u, col)
            if isSel and not focused and tab.active then
                gfx.color(theme.accent)
                love.graphics.rectangle("fill", x, 74 * u, tw, 3 * u)
            end
            tab._x, tab._w = x, tw
            x = x + tw + 44 * u
        end
    end
    if rightText then
        gfx.text(rightText, right - gfx.width(rightText, 22 * u), 42 * u, 22 * u, theme.textDim)
    end
end

-- Round back-arrow button (top left of pages). focused: keyboard/controller focus.
function W.backButton(x, y, s, focused, onClick)
    local u = gfx.unit()
    local lit = focused or pointerIn(x, y, s, s)
    gfx.color({ 0, 0, 0 }, lit and 0 or 0.35)
    love.graphics.circle("fill", x + s / 2, y + s / 2, s / 2)
    if lit then
        gfx.color(theme.text, 0.2)
        love.graphics.circle("fill", x + s / 2, y + s / 2, s / 2)
    end
    if focused then
        gfx.color(theme.accent)
        love.graphics.setLineWidth(2.5 * u)
        love.graphics.circle("line", x + s / 2, y + s / 2, s / 2 + 2 * u)
    end
    local cx, cy, a = x + s / 2, y + s / 2, s * 0.6
    gfx.color(theme.text)
    love.graphics.setLineWidth(3 * u)
    love.graphics.setLineJoin("bevel")
    love.graphics.line(cx + a * 0.38, cy, cx - a * 0.36, cy)
    love.graphics.line(cx - a * 0.08, cy - a * 0.3, cx - a * 0.38, cy, cx - a * 0.08, cy + a * 0.3)
    require("ui.mouse").region(x, y, s, s, { click = onClick })
end

-- Arrow strip at one end of a card row (dir -1 = left, 1 = right), shown while the
-- pointer is over the row. Clicking pages the row.
function W.rowArrow(x, y, w, h, dir, onClick)
    local u = gfx.unit()
    local lit = pointerIn(x, y, w, h)
    gfx.color({ 0, 0, 0 }, lit and 0.7 or 0.5)
    love.graphics.rectangle("fill", x, y, w, h)
    local cx, cy, s = x + w / 2, y + h / 2, (lit and 22 or 17) * u
    gfx.color(theme.text)
    love.graphics.setLineWidth(4 * u)
    love.graphics.setLineJoin("bevel")
    love.graphics.line(cx - dir * s * 0.45, cy - s, cx + dir * s * 0.45, cy, cx - dir * s * 0.45, cy + s)
    require("ui.mouse").region(x, y, w, h, { click = onClick })
end

-- Both arrows for a card row spanning x..x+w, shown while the pointer is over
-- it and there's more that way. first = index of the first visible card (0-based,
-- may be fractional while scrolling), n cards, `visible` fit across.
-- onPage(dir) scrolls the row by a page.
function W.rowArrows(x, y, w, h, first, n, visible, onPage)
    if not pointerIn(x, y, w, h) then return end
    local aw = 60 * gfx.unit()
    if first > 0.01 then W.rowArrow(x, y, aw, h, -1, function() onPage(-1) end) end
    if first + visible < n - 0.01 then W.rowArrow(x + w - aw, y, aw, h, 1, function() onPage(1) end) end
end

return W
