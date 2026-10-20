-- Audio & Subtitles for a whole show (the detail page's button): the show's
-- own settings on the server, as in Plex Web's Edit > Advanced: preferred
-- audio language, preferred subtitle language, and when subtitles are shown.
-- The server uses them to pick the tracks for every episode; a track chosen
-- in the player still wins for that episode.
--
-- A panel over the detail page: three rows; choosing one lists its options
-- (languages get a filter box you type into, like the library's Genre menu).
-- Each choice is saved straight away (PUT /library/metadata/{id}/prefs).

local theme = require("theme")
local gfx = require("ui.gfx")
local api = require("plex.api")
local mouse = require("ui.mouse")
local utf8 = require("utf8")

local ShowPrefs = {}
ShowPrefs.__index = ShowPrefs

-- Shorter names than the server's labels, in this order.
local ROWS = {
    { id = "audioLanguage", title = "Audio language" },
    { id = "subtitleLanguage", title = "Subtitle language" },
    { id = "subtitleMode", title = "Subtitles shown" },
}
local ROW_H, LIST_ROWS = 64, 8

-- The server names languages in their own script (日本語, Deutsch); the English
-- name goes in front so "japanese" or "german" finds them too.
local ENGLISH = {
    en = "English", es = "Spanish", fr = "French", ca = "Catalan", cs = "Czech", da = "Danish", de = "German",
    et = "Estonian", hr = "Croatian", id = "Indonesian", is = "Icelandic", it = "Italian", lv = "Latvian",
    lt = "Lithuanian", hu = "Hungarian", nl = "Dutch", nb = "Norwegian", pl = "Polish", pt = "Portuguese",
    ro = "Romanian", sk = "Slovak", fi = "Finnish", sv = "Swedish", vi = "Vietnamese", tr = "Turkish",
    el = "Greek", bg = "Bulgarian", ru = "Russian", uk = "Ukrainian", he = "Hebrew", ar = "Arabic",
    fa = "Persian", hi = "Hindi", th = "Thai", ko = "Korean", zh = "Chinese", ja = "Japanese",
}

local function withEnglish(setting)
    if not setting.id:find("Language$") then return end
    for _, o in ipairs(setting.options) do
        local name = ENGLISH[o.value:match("^(%a+)") or ""]
        if name and not o.label:find(name, 1, true) then o.label = name .. " · " .. o.label end
    end
end

function ShowPrefs.new(server, show)
    return setmetatable({ server = server, show = show, sel = 1, open = 0, overlay = true,
                          loading = true, rows = {}, searchable = false }, ShowPrefs)
end

function ShowPrefs:enter()
    api.itemPrefs(self.server, self.show.ratingKey, function(settings, err)
        self.loading = false
        if not settings then self.error = tostring(err); return end
        local byId = {}
        for _, st in ipairs(settings) do byId[st.id] = st end
        for _, r in ipairs(ROWS) do
            local st = byId[r.id]
            if st then
                withEnglish(st)
                self.rows[#self.rows + 1] = { title = r.title, setting = st }
            end
        end
        if #self.rows == 0 then self.error = "The server has no track settings for this show." end
    end)
end

local function optionLabel(st, value)
    for _, o in ipairs(st.options) do
        if o.value == value then return o.label end
    end
    return value == "" and "Account default" or value
end

function ShowPrefs:openList(i)
    local row = self.rows[i]
    if not row then return end
    local st = row.setting
    local sel = 1
    for k, o in ipairs(st.options) do if o.value == st.value then sel = k end end
    self.list = { row = row, sel = sel, scroll = math.max(0, sel - 3), filter = "",
                  searchable = #st.options > 10, options = st.options }
end

-- The options matching the filter.
function ShowPrefs:visibleOptions()
    local l = self.list
    if l.filter == "" then return l.options end
    local out, f = {}, l.filter:lower()
    for _, o in ipairs(l.options) do
        if o.label:lower():find(f, 1, true) or o.value:lower():find(f, 1, true) then out[#out + 1] = o end
    end
    return out
end

function ShowPrefs:choose(o)
    local row = self.list.row
    self.list = nil
    if not o or o.value == row.setting.value then return end
    local old = row.setting.value
    row.setting.value = o.value
    api.setItemPrefs(self.server, self.show.ratingKey, { [row.setting.id] = o.value }, function(ok, err)
        if ok then return app.notify(row.title .. ": " .. o.label) end
        row.setting.value = old
        app.notify("Couldn't save: " .. tostring(err), "error")
    end)
end

function ShowPrefs:action(a)
    local l = self.list
    if l then
        local opts = self:visibleOptions()
        if a == "up" then l.sel = math.max(1, l.sel - 1)
        elseif a == "down" then l.sel = math.min(#opts, l.sel + 1)
        elseif a == "accept" then self:choose(opts[l.sel])
        elseif a == "back" or a == "left" or a == "menu" then self.list = nil end
        return
    end
    if a == "up" then self.sel = math.max(1, self.sel - 1)
    elseif a == "down" then self.sel = math.min(#self.rows, self.sel + 1)
    elseif a == "accept" or a == "right" then self:openList(self.sel)
    elseif a == "back" or a == "menu" or a == "left" then app.pop() end
end

-- Typing filters a language list.
function ShowPrefs:keypressed(key)
    local l = self.list
    if not (l and l.searchable) then return false end
    if key == "backspace" then
        if l.filter == "" then return false end           -- empty: Backspace goes back as usual
        l.filter = l.filter:sub(1, utf8.offset(l.filter, -1) - 1)
        l.sel, l.scroll = 1, 0
        return true
    end
    return #key == 1 or key == "space"                    -- printable keys type, not move (WASD)
end

function ShowPrefs:textinput(t)
    local l = self.list
    if not (l and l.searchable) or t:find("%c") then return end
    l.filter = l.filter .. t
    l.sel, l.scroll = 1, 0
end

function ShowPrefs:update(dt)
    self.open = gfx.approach(self.open, 1, dt, 18)
end

function ShowPrefs:draw()
    local w, h = love.graphics.getDimensions()
    local u = gfx.unit()
    local a = self.open
    gfx.color({ 0, 0, 0 }, 0.6 * a)
    love.graphics.rectangle("fill", 0, 0, w, h)
    mouse.region(0, 0, w, h, { click = function() if self.list then self.list = nil else app.pop() end end,
                               wheel = function() return true end })

    local pw = 680 * u
    local headH = 150 * u
    local bodyH = self.list and (LIST_ROWS * 50 * u + (self.list.searchable and 70 * u or 0) + 60 * u)
        or math.max(1, #self.rows) * ROW_H * u + 30 * u
    local ph = headH + bodyH
    local x, y = (w - pw) / 2, (h - ph) / 2 + (1 - a) * 16 * u
    gfx.color({ 0, 0, 0 }, 0.35 * a)
    gfx.roundRect("fill", x - 2 * u, y + 5 * u, pw + 4 * u, ph + 4 * u, 16 * u)
    gfx.color(theme.surface, a)
    gfx.roundRect("fill", x, y, pw, ph, 14 * u)
    mouse.region(x, y, pw, ph, { click = function() end, wheel = function() return true end })

    gfx.color(theme.accent, a)
    gfx.roundRect("fill", x + 32 * u, y + 34 * u, 6 * u, 36 * u, 3 * u)
    gfx.text("Audio & Subtitles", x + 52 * u, y + 28 * u, 32 * u, theme.text, a)
    gfx.text(gfx.fit("For every episode of " .. (self.show.title or "this show") .. ".", 20 * u, pw - 64 * u),
        x + 32 * u, y + 84 * u, 20 * u, theme.textDim, a)
    gfx.text("A track you pick in the player still wins for that episode.", x + 32 * u, y + 112 * u, 18 * u,
        theme.textDim, a * 0.8)
    gfx.color(theme.text, 0.1 * a)
    love.graphics.rectangle("fill", x + 24 * u, y + headH - 2 * u, pw - 48 * u, 1)

    local by = y + headH
    if self.loading then return gfx.spinner(x + pw / 2, by + bodyH / 2, 20 * u) end
    if self.error then
        return gfx.text(gfx.fit(self.error, 20 * u, pw - 64 * u), x + 32 * u, by + 24 * u, 20 * u, theme.danger, a)
    end
    if self.list then return self:drawList(x, by, pw, bodyH, u, a) end

    local ry = by + 14 * u
    local rh = ROW_H * u
    for i, r in ipairs(self.rows) do
        local focused = self.sel == i
        if focused then
            gfx.color(theme.text, 0.08 * a)
            love.graphics.rectangle("fill", x, ry, pw, rh)
            gfx.color(theme.accent, a)
            love.graphics.rectangle("fill", x, ry + 14 * u, 4 * u, rh - 28 * u)
        end
        local f = gfx.font(23 * u)
        local ty = ry + (rh - f:getHeight()) / 2
        gfx.text(r.title, x + 32 * u, ty, 23 * u, focused and theme.text or theme.textDim, a)
        local value = optionLabel(r.setting, r.setting.value)
        local vw = gfx.width(value, 21 * u)
        local vx = x + pw - 64 * u - vw
        gfx.text(value, vx, ty + 2 * u, 21 * u, r.setting.value ~= r.setting.default and theme.accent or theme.text, a)
        -- chevron
        gfx.color(theme.textDim, a)
        love.graphics.setLineWidth(2.5 * u)
        local cx, cy = x + pw - 40 * u, ry + rh / 2
        love.graphics.line(cx - 5 * u, cy - 8 * u, cx + 3 * u, cy, cx - 5 * u, cy + 8 * u)
        mouse.region(x, ry, pw, rh, {
            hover = function() self.sel = i end,
            click = function() self.sel = i; self:openList(i) end,
        })
        ry = ry + rh
    end
end

function ShowPrefs:drawList(x, y, pw, bodyH, u, a)
    local l = self.list
    local opts = self:visibleOptions()
    l.sel = math.max(1, math.min(l.sel, #opts))
    local cy = y + 18 * u
    gfx.text(l.row.title:upper(), x + 32 * u, cy, 17 * u, theme.textDim, a)
    cy = cy + 36 * u
    if l.searchable then
        local bh = 46 * u
        gfx.color(theme.bg, a)
        gfx.roundRect("fill", x + 24 * u, cy, pw - 48 * u, bh, 8 * u)
        local text = l.filter == "" and "Type to filter" or l.filter
        gfx.text(text, x + 40 * u, cy + (bh - gfx.font(20 * u):getHeight()) / 2, 20 * u,
            l.filter == "" and theme.textDim or theme.text, a)
        if l.filter ~= "" and love.timer.getTime() % 1 < 0.5 then
            gfx.color(theme.accent, a)
            love.graphics.rectangle("fill", x + 42 * u + gfx.width(l.filter, 20 * u), cy + 11 * u, 2 * u, bh - 22 * u)
        end
        cy = cy + bh + 16 * u
    end

    local rowH = 50 * u
    local n = math.min(LIST_ROWS - (l.searchable and 1 or 0), #opts)
    -- keep the focused option in view
    if l.sel - 1 < l.scroll then l.scroll = l.sel - 1 end
    if l.sel > l.scroll + n then l.scroll = l.sel - n end
    l.scroll = math.max(0, math.min(l.scroll, #opts - n))
    mouse.region(x, cy, pw, n * rowH, { wheel = function(_, dy)
        l.scroll = math.max(0, math.min(#opts - n, l.scroll - (dy > 0 and 1 or -1)))
        return true
    end })
    if #opts == 0 then
        gfx.text("No matches", x + 60 * u, cy + 12 * u, 20 * u, theme.textDim, a)
        return
    end
    local current = l.row.setting.value
    for k = l.scroll + 1, l.scroll + n do
        local o = opts[k]
        local ry = cy + (k - l.scroll - 1) * rowH
        local focused = k == l.sel
        if focused then
            gfx.color(theme.text, 0.08 * a)
            love.graphics.rectangle("fill", x, ry, pw, rowH)
            gfx.color(theme.accent, a)
            love.graphics.rectangle("fill", x, ry + 12 * u, 4 * u, rowH - 24 * u)
        end
        local isCurrent = o.value == current
        if isCurrent then
            gfx.color(theme.accent, a)
            love.graphics.setLineWidth(3 * u)
            love.graphics.line(x + 30 * u, ry + rowH * 0.5, x + 37 * u, ry + rowH * 0.64, x + 50 * u, ry + rowH * 0.34)
        end
        gfx.text(gfx.fit(o.label, 21 * u, pw - 100 * u), x + 66 * u, ry + (rowH - gfx.font(21 * u):getHeight()) / 2,
            21 * u, isCurrent and theme.accent or (focused and theme.text or theme.textDim), a)
        mouse.region(x, ry, pw, rowH, {
            hover = function() l.sel = k end,
            click = function() self:choose(o) end,
        })
    end
    -- more below / above
    if l.scroll + n < #opts then gfx.vgradient(x, cy + (n - 1) * rowH, pw, rowH, theme.surface, 0, 0.9 * a) end
end

return ShowPrefs
