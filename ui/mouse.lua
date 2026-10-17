-- Mouse support. Scenes register clickable regions while drawing:
--   mouse.region(x, y, w, h, { hover = fn, click = fn })
-- Events are tested against the regions from the last drawn frame, topmost first.
-- Only the top scene's regions count, so overlays don't leak clicks below.

local input = require("lib.input")

local mouse = {
    regions = {},
    active = true,      -- false while drawing scenes under the top one
    lastMove = 0,       -- time of the last real mouse movement
}

local handCursor
local cursorIsHand = false

function mouse.beginFrame()
    mouse.regions = {}
end

function mouse.region(x, y, w, h, opts)
    if not mouse.active then return end
    local r = { x = x, y = y, w = w, h = h, hover = opts.hover, click = opts.click, wheel = opts.wheel,
                block = opts.block }
    mouse.regions[#mouse.regions + 1] = r
end

-- Topmost region under (x, y) that handles `want`. A region with block=true
-- (e.g. a header bar) hides everything registered before it.
local function find(x, y, want)
    for i = #mouse.regions, 1, -1 do
        local r = mouse.regions[i]
        if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
            if r[want] then return r end
            if r.block then return nil end
        end
    end
end

local function updateCursor(x, y)
    local over = find(x, y, "click") ~= nil
    if over ~= cursorIsHand and love.mouse.isCursorSupported() then
        handCursor = handCursor or love.mouse.getSystemCursor("hand")
        love.mouse.setCursor(over and handCursor or nil)
        cursorIsHand = over
    end
end

-- True for a while after the mouse was used; scenes use it to stop
-- keyboard-style auto scrolling from fighting the pointer.
function mouse.recentlyUsed(seconds)
    return input.lastDevice == "mouse" and love.timer.getTime() - mouse.lastMove < (seconds or 1e9)
end

function mouse.moved(x, y, dx, dy, istouch)
    if istouch then return end
    mouse.lastMove = love.timer.getTime()
    input.lastDevice = "mouse"
    love.mouse.setVisible(true)
    local r = find(x, y, "hover")
    if r then r.hover(x, y) end
    updateCursor(x, y)
end

-- Returns true if a region handled the click.
function mouse.pressed(x, y, button)
    input.lastDevice = "mouse"
    mouse.lastMove = love.timer.getTime()
    if button == 1 then
        local r = find(x, y, "click")
        if r then r.click(x, y); return true end
    end
    return false
end

-- Wheel over a region with its own wheel handler (e.g. a row) goes there first.
function mouse.wheel(dx, dy)
    input.lastDevice = "mouse"
    local x, y = love.mouse.getPosition()
    local r = find(x, y, "wheel")
    if r then return r.wheel(dx, dy) end
end

function mouse.refreshCursor()
    updateCursor(love.mouse.getPosition())
end

return mouse
