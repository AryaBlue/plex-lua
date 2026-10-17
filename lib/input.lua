-- Maps keyboard and gamepad to UI actions, with key-repeat for held directions
-- and the analog stick. Scenes receive input.pressed(action) via scene:action(name).
--
-- Actions: up down left right accept back menu playpause seekback seekfwd

local input = {}

local KEYS = {
    up = "up", w = "up", down = "down", s = "down", left = "left", a = "left", right = "right", d = "right",
    ["return"] = "accept", kpenter = "accept", space = "playpause",
    escape = "back", backspace = "back",
    tab = "menu", m = "menu",
    j = "seekback", l = "seekfwd", [","] = "seekback", ["."] = "seekfwd",
}

local BUTTONS = {
    dpup = "up", dpdown = "down", dpleft = "left", dpright = "right",
    a = "accept", b = "back", start = "menu", back = "back", x = "playpause", y = "menu",
    leftshoulder = "seekback", rightshoulder = "seekfwd",
}

local REPEATABLE = { up = true, down = true, left = true, right = true, seekback = true, seekfwd = true }
local REPEAT_DELAY, REPEAT_RATE = 0.4, 0.08
local STICK_ON, STICK_OFF = 0.55, 0.35

input.lastDevice = "keyboard"   -- "keyboard" | "gamepad"; UI shows matching hints
local handler
local held = {}                 -- action -> { t = time held, next = next repeat time, source }
local stickDir = {}             -- joystick -> current stick action

function input.setHandler(f) handler = f end

local function fire(action, isRepeat)
    if handler then handler(action, isRepeat) end
end

local function press(action, source)
    held[action] = { t = 0, nextAt = REPEAT_DELAY, source = source }
    fire(action, false)
end

local function release(action, source)
    local h = held[action]
    if h and h.source == source then held[action] = nil end
end

function input.keypressed(key, scancode, isrepeat)
    if isrepeat then return end
    input.lastDevice = "keyboard"
    local action = KEYS[key]
    if action then press(action, "key:" .. key) end
end

function input.keyreleased(key)
    local action = KEYS[key]
    if action then release(action, "key:" .. key) end
end

function input.gamepadpressed(js, button)
    input.lastDevice = "gamepad"
    local action = BUTTONS[button]
    if action then press(action, "pad:" .. button) end
end

function input.gamepadreleased(js, button)
    local action = BUTTONS[button]
    if action then release(action, "pad:" .. button) end
end

local function stick_action(js)
    local x, y = js:getGamepadAxis("leftx"), js:getGamepadAxis("lefty")
    local cur = stickDir[js]
    local threshold = cur and STICK_OFF or STICK_ON
    if math.abs(x) < threshold and math.abs(y) < threshold then return nil end
    if math.abs(x) > math.abs(y) then return x > 0 and "right" or "left" end
    return y > 0 and "down" or "up"
end

function input.update(dt)
    for _, js in ipairs(love.joystick.getJoysticks()) do
        if js:isGamepad() then
            local dir = stick_action(js)
            local cur = stickDir[js]
            if dir ~= cur then
                if cur then release(cur, "stick") end
                stickDir[js] = dir
                if dir then input.lastDevice = "gamepad"; press(dir, "stick") end
            end
        end
    end
    for action, h in pairs(held) do
        if REPEATABLE[action] then
            h.t = h.t + dt
            while h.t >= h.nextAt do
                h.nextAt = h.nextAt + REPEAT_RATE
                fire(action, true)
            end
        end
    end
end

-- Button label for on-screen hints.
function input.hint(action)
    if input.lastDevice == "gamepad" then
        return ({ accept = "A", back = "B", menu = "Y", playpause = "X", seekback = "LB", seekfwd = "RB" })[action] or action
    end
    return ({ accept = "Enter", back = "Esc", menu = "Tab", playpause = "Space", seekback = "J", seekfwd = "L" })[action] or action
end

return input
