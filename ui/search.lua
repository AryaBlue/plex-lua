-- Search: an on-screen keyboard on the left (for controllers and the mouse),
-- results on the right as one row per type (Films, Shows, Episodes...), then
-- a "Request" row of matches from Seerr that aren't on the server.
-- Typing on a real keyboard works at any time. Queries go to /hubs/search
-- shortly after the last keystroke.
--
-- Focus zones: "keys" (on-screen keyboard) and "results" (the rows, or the
-- recent searches list while the query is empty).

local utf8 = require("utf8")
local theme = require("theme")
local gfx = require("ui.gfx")
local W = require("ui.widgets")
local api = require("plex.api")
local input = require("lib.input")
local client = require("plex.client")
local mouse = require("ui.mouse")
local seerr = require("seerr.api")

local Search = {}
Search.__index = Search

local DEBOUNCE = 0.3
local MAX_LEN = 80
local MAX_RECENT = 8

-- 6 unit columns; the top row has three double-width keys.
local KEYBOARD = {
    { { "Space", " ", 2 }, { "Delete", "delete", 2 }, { "Clear", "clear", 2 } },
}
for _, letters in ipairs({ "abcdef", "ghijkl", "mnopqr", "stuvwx", "yz1234", "567890" }) do
    local row = {}
    for ch in letters:gmatch(".") do row[#row + 1] = { ch, ch, 1 } end
    KEYBOARD[#KEYBOARD + 1] = row
end
local KB_COLS = 6

-- Key covering unit column `col` of `row`, and the unit column it starts at.
local function keyAt(row, col)
    local start = 1
    for _, k in ipairs(KEYBOARD[row]) do
        if col < start + k[3] then return k, start end
        start = start + k[3]
    end
end

function Search.new(server)
    return setmetatable({
        server = server,
        query = "",
        zone = "keys", kr = 2, kc = 1,   -- on-screen keyboard focus (row, unit column)
        rows = {},                       -- result rows: { title, kind, items, col, scrollAnim, anim }
        row = 1,                         -- focused result row
        sel = 1,                         -- focused recent search
        recentAnim = {}, keyAnim = {},
        scrollY = 0, scrollTarget = 0,
        caret = 0,
        backdrop = W.newBackdrop(),
    }, Search)
end

function Search:enter()
    love.keyboard.setTextInput(true)
    love.keyboard.setKeyRepeat(true)    -- holding Backspace deletes repeatedly
end
function Search:resume() love.keyboard.setKeyRepeat(true) end
function Search:pause() love.keyboard.setKeyRepeat(false) end
function Search:leave() love.keyboard.setKeyRepeat(false) end

---------------------------------------------------------------------------
-- Query editing

function Search:setQuery(q)
    if #q > MAX_LEN then q = q:sub(1, utf8.offset(q, MAX_LEN + 1) - 1) end
    if q == self.query then return end
    self.query = q
    self.caret = 0
    self.debounce = DEBOUNCE
end

function Search:deleteChar()
    local q = self.query
    if q == "" then return end
    self:setQuery(q:sub(1, utf8.offset(q, -1) - 1))
end

function Search:deleteWord()
    self:setQuery((self.query:gsub("%s*[^%s]*%s*$", "")))
end

function Search:pressKey(value)
    if value == "delete" then self:deleteChar()
    elseif value == "clear" then self:setQuery("")
    elseif value == " " then
        if self.query ~= "" and not self.query:find(" $") then self:setQuery(self.query .. " ") end
    else
        self:setQuery(self.query .. value)
    end
end

function Search:textinput(t)
    if not self.ready then return end      -- the "/" that opened this scene
    t = t:gsub("[%c]", "")
    if t == "" or (t == " " and self.zone ~= "keys") then return end
    self.typing = true
    self:setQuery(self.query .. t)
end

-- Keys that type text are taken here, before they turn into navigation
-- actions (WASD, Space, Backspace...). Their text arrives through textinput.
function Search:keypressed(key)
    local ctrl = love.keyboard.isDown("lctrl", "rctrl")
    input.lastDevice = "keyboard"
    if ctrl and key == "v" then
        local clip = (love.system.getClipboardText() or ""):gsub("[%c]+", " ")
        self.typing = true
        self:setQuery(self.query .. clip)
        return true
    elseif ctrl and key == "backspace" then
        self.typing = true
        self:deleteWord()
        return true
    elseif ctrl then
        return false
    end
    if key == "backspace" then
        self.typing = true
        self:deleteChar()
        return true
    end
    -- Space plays the focused result; elsewhere it types
    if key == "space" then return self.zone == "keys" end
    return #key == 1
end

---------------------------------------------------------------------------
-- Searching

function Search:run()
    local q = self.query:gsub("^%s+", ""):gsub("%s+$", "")
    self.generation = (self.generation or 0) + 1
    self.plexRows, self.requestRow, self.requestError = nil, nil, nil
    if q == "" then
        self.rows, self.searchedFor, self.searching, self.error = {}, nil, false, nil
        return
    end
    local gen = self.generation
    self.searching = true
    self.firstResults = true
    api.search(self.server, q, function(hubs, err)
        if gen ~= self.generation then return end   -- a newer query replaced this one
        self.searching = false
        self.error = not hubs and tostring(err) or nil
        self.searchedFor = q
        self.plexRows = {}
        for _, h in ipairs(hubs or {}) do
            self.plexRows[#self.plexRows + 1] = { title = h.title, items = h.items,
                                                  kind = h.type == "genre" and "genre" or W.kindFor(h.items[1], h.hub) }
        end
        self:buildRows()
    end)
    if seerr.enabled() then
        seerr.search(q, function(items, err)
            if gen ~= self.generation then return end
            if not items then
                self.requestError = tostring(err)
                print("[seerr] search failed: " .. tostring(err))
                return
            end
            -- what's already on the server shows up in the Plex rows above
            local list = {}
            for _, it in ipairs(items) do
                if it.status ~= seerr.AVAILABLE then list[#list + 1] = it end
            end
            if #list > 0 then
                self.requestRow = { title = "Not in your library · Request", kind = "poster",
                                    items = list, request = true }
            end
            self:buildRows()
        end)
    end
end

-- Plex rows first, the request row last. The two searches answer in either
-- order, so keep the focused row when the other one arrives.
function Search:buildRows()
    local old = self.rows[self.row]
    local rows = {}
    for _, r in ipairs(self.plexRows or {}) do rows[#rows + 1] = r end
    if self.requestRow and self.plexRows then rows[#rows + 1] = self.requestRow end
    for _, r in ipairs(rows) do
        r.col, r.scrollAnim, r.anim = r.col or 1, r.scrollAnim or 0, r.anim or {}
    end
    self.rows = rows
    if self.firstResults and #rows > 0 then
        self.firstResults = false
        self.row = 1
        self.scrollTarget, self.mouseScroll = 0, false
        if self.enterResults then self.zone = "results" end
        self.enterResults = nil
    else
        for i, r in ipairs(rows) do if r == old then self.row = i end end
    end
end

function Search:showingRecent()
    return not self.query:find("%S")
end

function Search:count()
    local n = 0
    for _, r in ipairs(self.rows) do n = n + #r.items end
    return n
end

function Search:hasEntries()
    if self:showingRecent() then return #(client.settings.recentSearches or {}) > 0 end
    return #self.rows > 0
end

function Search:remember()
    local q = self.searchedFor
    if not q then return end
    local list = { q }
    for _, old in ipairs(client.settings.recentSearches or {}) do
        if old:lower() ~= q:lower() and #list < MAX_RECENT then list[#list + 1] = old end
    end
    client.set("recentSearches", list)
end

function Search:open(item)
    if not item then return end
    self:remember()
    if item.seerr then return app.push(require("ui.request").new(self.server, item)) end
    if item.type == "genre" then
        -- the library it belongs to, showing only that genre
        local section = { key = item.sectionKey, title = item.sectionTitle }
        return app.push(require("ui.library").new(self.server, section, { id = item.genre, title = item.title }))
    end
    app.push(require("ui.detail").new(self.server, item))
end

function Search:play(item)
    if not item then return end
    if item.seerr or item.type == "genre" or not api.isPlayable(item) then return self:open(item) end
    self:remember()
    api.metadata(self.server, item.ratingKey, function(full, err)
        if not full then return app.notify(tostring(err), "error") end
        app.push(require("player.scene").new(self.server, full))
    end)
end

-- Options for a library result (right click, its ⋯ button, or Tab / Y).
function Search:itemMenu(item, anchor)
    require("ui.itemmenu").open(self.server, item, { anchor = anchor })
end

-- Library results get the options menu; Seerr results and genres don't.
local function hasMenu(item) return item and not item.seerr and item.type ~= "genre" end

function Search:useRecent(i)
    local q = (client.settings.recentSearches or {})[i]
    if q then self:setQuery(q); self.debounce = 0 end
end

function Search:focusedItem()
    local r = self.rows[self.row]
    return r and r.items[r.col]
end

---------------------------------------------------------------------------
-- Layout

function Search:metrics()
    local w, h = love.graphics.getDimensions()
    local u = gfx.unit()
    local m = { u = u, w = w, h = h, pad = 70 * u, top = 200 * u }
    m.key, m.keyGap = 62 * u, 8 * u
    m.kbW = KB_COLS * m.key + (KB_COLS - 1) * m.keyGap
    m.rx = m.pad + m.kbW + 70 * u                  -- results area
    m.rw = w - m.rx - m.pad
    m.cardGap = 20 * u
    m.posterW = 170 * u
    m.posterH = m.posterW * W.POSTER_ASPECT
    m.wideW = 330 * u
    m.wideH = m.wideW * W.WIDE_ASPECT
    m.titleH = 46 * u
    m.lineH = 56 * u                                 -- recent searches
    return m
end

function Search:cardSize(row, m)
    if row.kind == "wide" then return m.wideW, m.wideH end
    if row.kind == "genre" then return W.GENRE_W * m.u, W.GENRE_H * m.u end
    return m.posterW, m.posterH
end

function Search:rowHeight(row, m)
    local _, ch = self:cardSize(row, m)
    return m.titleH + ch + (row.kind == "poster" and 64 * m.u or 0) + 36 * m.u
end

function Search:rowY(i, m)
    local y = m.top
    for r = 1, i - 1 do y = y + self:rowHeight(self.rows[r], m) end
    return y
end

function Search:maxScroll(m)
    local n = #self.rows
    if n == 0 then return 0 end
    return math.max(0, self:rowY(n + 1, m) - m.h + 60 * m.u)
end

---------------------------------------------------------------------------
-- Input

-- The arrows at a row's ends: move it by a screenful less one card.
function Search:pageRow(row, dir)
    local visible = row.visible or 1
    self.pointerFocus, self.mouseScroll = true, true
    row.scrollTarget = math.max(0, math.min((row.scrollTarget or 0) + dir * math.max(1, visible - 1), #row.items - visible))
end

function Search:wheel(dx, dy)
    if dy == 0 or self:showingRecent() then return end
    local m = self:metrics()
    self.mouseScroll = true
    self.scrollTarget = math.max(0, math.min(self:maxScroll(m), self.scrollTarget - dy * 170 * m.u))
end

function Search:actionKeys(a)
    local key, start = keyAt(self.kr, self.kc)
    if a == "back" then return app.pop()
    elseif a == "accept" then self:pressKey(key[2])
    elseif a == "playpause" then self:deleteChar()
    elseif a == "up" then self.kr = math.max(1, self.kr - 1)
    elseif a == "down" then self.kr = math.min(#KEYBOARD, self.kr + 1)
    elseif a == "left" then self.kc = math.max(1, start - 1)
    elseif a == "right" then
        if start + key[3] <= KB_COLS then self.kc = start + key[3]
        elseif self:hasEntries() then
            self.zone = "results"
            local r = self.rows[self.row]
            if r then r.col = math.max(1, math.min(#r.items, math.floor((r.scrollTarget or 0)) + 1)) end
        end
    end
end

function Search:actionRecent(a)
    local n = #(client.settings.recentSearches or {})
    if a == "back" or a == "left" then self.zone = "keys"
    elseif a == "up" then self.sel = math.max(1, self.sel - 1)
    elseif a == "down" then self.sel = math.min(n, self.sel + 1)
    elseif a == "accept" then self:useRecent(self.sel)
    end
end

function Search:actionResults(a)
    local r = self.rows[self.row]
    if not r then self.zone = "keys"; return end
    if a == "back" then self.zone = "keys"
    elseif a == "left" then
        if r.col == 1 then self.zone = "keys" else r.col = r.col - 1 end
    elseif a == "right" then r.col = math.min(#r.items, r.col + 1)
    elseif a == "up" then self.row = math.max(1, self.row - 1)
    elseif a == "down" then self.row = math.min(#self.rows, self.row + 1)
    elseif a == "accept" then self:open(r.items[r.col])
    elseif a == "playpause" then self:play(r.items[r.col])
    elseif a == "menu" then self:itemMenu(r.items[r.col], r.rects and r.rects[r.col])
    end
end

function Search:action(a)
    -- Enter after typing jumps to the results instead of pressing the focused key
    if a == "accept" and self.typing then
        self.typing = false
        if self.debounce then self.debounce = nil; self:run() end
        if self.searching then
            self.enterResults = true            -- moves there when the results arrive
        elseif self:hasEntries() then
            self.zone = "results"
        end
        return
    end
    self.typing, self.mouseScroll, self.pointerFocus = false, false, false
    if self.zone == "keys" then return self:actionKeys(a) end
    if self:showingRecent() then return self:actionRecent(a) end
    return self:actionResults(a)
end

---------------------------------------------------------------------------

function Search:update(dt)
    self.ready = true
    self.caret = self.caret + dt
    if self.debounce then
        self.debounce = self.debounce - dt
        if self.debounce <= 0 then self.debounce = nil; self:run() end
    end
    if self.zone == "results" and not self:hasEntries() then self.zone = "keys" end

    local m = self:metrics()
    local recent = self:showingRecent()
    local nRecent = #(client.settings.recentSearches or {})
    self.sel = math.max(1, math.min(self.sel, nRecent))
    self.row = math.max(1, math.min(self.row, #self.rows))

    if not self.mouseScroll then
        self.scrollTarget = (self.zone == "results" and not recent and self.row > 1)
            and math.min(self:maxScroll(m), self:rowY(self.row, m) - m.top) or 0
    end
    self.scrollY = gfx.approach(self.scrollY, self.scrollTarget, dt, 12)

    -- horizontal scroll keeps the focused card in view (not when the pointer picked it)
    for i, row in ipairs(self.rows) do
        local cw = self:cardSize(row, m) + m.cardGap
        local visible = math.max(1, math.floor((m.rw + m.cardGap) / cw))
        local target = row.scrollTarget or 0
        if not self.pointerFocus then
            if row.col - 1 < target then target = row.col - 1 end
            if row.col > target + visible then target = row.col - visible end
        end
        row.scrollTarget = math.max(0, target)
        row.visible = visible
        row.scrollAnim = gfx.approach(row.scrollAnim, row.scrollTarget * cw, dt, 14)
        for c = 1, #row.items do
            local on = self.zone == "results" and not recent and i == self.row and c == row.col
            row.anim[c] = gfx.approach(row.anim[c] or 0, on and 1 or 0, dt, 16)
        end
    end
    for i = 1, nRecent do
        local on = self.zone == "results" and recent and i == self.sel
        self.recentAnim[i] = gfx.approach(self.recentAnim[i] or 0, on and 1 or 0, dt, 16)
    end
    for r = 1, #KEYBOARD do
        local k = keyAt(r, self.kc)
        for c = 1, #KEYBOARD[r] do
            local on = self.zone == "keys" and not self.typing and r == self.kr and KEYBOARD[r][c] == k
            self.keyAnim[r * 10 + c] = gfx.approach(self.keyAnim[r * 10 + c] or 0, on and 1 or 0, dt, 20)
        end
    end

    local item = not recent and self:focusedItem()
    self.backdrop:set(self.server, item and (item.art or item.grandparentArt) or nil)
    self.backdrop:update(dt)
end

function Search:drawKeyboard(m)
    local u = m.u
    for r, row in ipairs(KEYBOARD) do
        local y = m.top + (r - 1) * (m.key + m.keyGap)
        local start = 1
        for c, k in ipairs(row) do
            local x = m.pad + (start - 1) * (m.key + m.keyGap)
            local kw = k[3] * m.key + (k[3] - 1) * m.keyGap
            local a = self.keyAnim[r * 10 + c] or 0
            gfx.color(theme.surface, 0.85)
            gfx.roundRect("fill", x, y, kw, m.key, 6 * u)
            if a > 0.01 then
                gfx.color({ 1, 1, 1 }, a)
                gfx.roundRect("fill", x, y, kw, m.key, 6 * u)
            end
            local size = k[3] > 1 and 22 * u or 30 * u
            local tc = a > 0.5 and { 0.05, 0.05, 0.06 } or theme.text
            gfx.textCentered(k[1], x + kw / 2, y + (m.key - gfx.font(size):getHeight()) / 2, size, tc)
            local kstart = start
            mouse.region(x, y, kw, m.key, {
                hover = function() self.zone, self.kr, self.kc, self.typing = "keys", r, kstart, false end,
                click = function() self:pressKey(k[2]) end,
            })
            start = start + k[3]
        end
    end
end

function Search:drawRows(m)
    local u = m.u
    for i, row in ipairs(self.rows) do
        local ry = self:rowY(i, m) - self.scrollY
        local rh = self:rowHeight(row, m)
        if ry + rh > 0 and ry < m.h then
            local focused = self.zone == "results" and self.row == i
            gfx.text(("%s  (%d)"):format(row.title, #row.items), m.rx, ry, 28 * u,
                focused and theme.text or theme.textDim)
            local cw, ch = self:cardSize(row, m)
            local cy = ry + m.titleH
            mouse.region(m.rx, ry, m.rw, rh, { wheel = function(dx)
                if dx == 0 then return false end
                self.pointerFocus = false
                self.zone, self.row = "results", i
                row.col = math.max(1, math.min(#row.items, row.col + (dx > 0 and 1 or -1)))
                return true
            end })
            local focusedCol = row.kind ~= "genre" and W.topCard(row.anim, 1, #row.items) or nil
            row.rects = {}
            for c, item in ipairs(row.items) do
                local cx = m.rx + (c - 1) * (cw + m.cardGap) - row.scrollAnim
                if cx > m.w then break end
                if cx + cw > m.rx - 40 * u then
                    if c ~= focusedCol then W.card(self.server, item, cx, cy, cw, ch, row.anim[c] or 0, row.kind) end
                    local rect = { x = cx, y = cy, w = cw, h = ch }
                    row.rects[c] = rect
                    mouse.region(cx, cy, cw, ch, {
                        hover = function()
                            self.mouseScroll, self.pointerFocus = true, true
                            self.zone, self.row, row.col = "results", i, c
                        end,
                        click = function() self:open(item) end,
                        context = hasMenu(item) and function() self:itemMenu(item, rect) end or nil,
                    })
                end
            end
            if focusedCol then
                local cx = m.rx + (focusedCol - 1) * (cw + m.cardGap) - row.scrollAnim
                local item = row.items[focusedCol]
                W.card(self.server, item, cx, cy, cw, ch, row.anim[focusedCol], row.kind)
                if hasMenu(item) then
                    W.moreButton(cx, cy, cw, ch, row.anim[focusedCol], row.kind,
                        function() self:itemMenu(item, row.rects[focusedCol]) end)
                end
            end
            W.rowArrows(m.rx - 30 * u, cy, m.w - m.rx + 30 * u, ch, row.scrollAnim / (cw + m.cardGap), #row.items,
                row.visible or 1, function(dir) self:pageRow(row, dir) end)
        end
    end
end

function Search:drawRecent(m)
    local u = m.u
    local list = client.settings.recentSearches or {}
    if #list == 0 then
        gfx.text("Search for films, shows and episodes across all your libraries.", m.rx, m.top, 24 * u, theme.textDim)
        return
    end
    gfx.text("Recent searches", m.rx, m.top - 4 * u, 26 * u, theme.textDim)
    local lw = math.min(560 * u, m.rw)
    for i, q in ipairs(list) do
        local y = m.top + 44 * u + (i - 1) * m.lineH
        local a = self.recentAnim[i] or 0
        if a > 0.01 then
            gfx.color(theme.surfaceHi, 0.9 * a)
            gfx.roundRect("fill", m.rx - 16 * u, y, lw, m.lineH - 8 * u, 8 * u)
        end
        gfx.text(gfx.fit(q, 26 * u, lw - 32 * u), m.rx, y + 9 * u, 26 * u, a > 0.5 and theme.text or theme.textDim)
        mouse.region(m.rx - 16 * u, y, lw, m.lineH - 8 * u, {
            hover = function() self.zone, self.sel = "results", i end,
            click = function() self:useRecent(i) end,
        })
    end
end

function Search:status()
    if self:showingRecent() then return "Type, or use the keyboard below" end
    if self.error then return "Search failed: " .. self.error end
    if self.searching or self.debounce or not self.searchedFor then return "Searching…" end
    local n = self:count()
    if n == 0 then return ("No matches for \"%s\""):format(self.searchedFor) end
    if not self.plexRows or #self.plexRows == 0 then
        return ("Nothing on %s for \"%s\" · you can request it below"):format(self.server.name, self.searchedFor)
    end
    return ("%d %s for \"%s\""):format(n, n == 1 and "result" or "results", self.searchedFor)
end

function Search:draw()
    local m = self:metrics()
    local u = m.u
    love.graphics.clear(theme.bg)
    self.backdrop:draw(0, 0, m.w, m.h, 0.16, 0.2)
    gfx.vgradient(0, 0, m.w, m.h, theme.bg, 0.6, 0.95)

    if self:showingRecent() then self:drawRecent(m) else self:drawRows(m) end

    -- header over the results: the query with a caret, and a status line
    love.graphics.setColor(theme.bg)
    love.graphics.rectangle("fill", 0, 0, m.w, m.top - 40 * u)
    gfx.vgradient(0, m.top - 40 * u, m.w, 40 * u, theme.bg, 1, 0)
    mouse.region(0, 0, m.w, m.top - 30 * u, { block = true })

    local hx = m.pad + 76 * u          -- header text starts right of the back button
    W.backButton(m.pad - 6 * u, 47 * u, 56 * u, false, function() app.pop() end)
    gfx.color(theme.accent)
    gfx.roundRect("fill", hx, 52 * u, 7 * u, 46 * u, 3 * u)
    local qx, qsize = hx + 24 * u, 50 * u
    local shown = self.query == "" and "" or gfx.fit(self.query, qsize, m.w - qx - m.pad - 60 * u)
    if shown == "" then
        gfx.text("Search", qx + 10 * u, 44 * u, qsize, theme.textDim)
    else
        gfx.text(shown, qx, 44 * u, qsize)
    end
    -- caret in the accent colour so it can't be mistaken for an "l" or "I"
    if self.caret % 1 < 0.55 then
        gfx.color(theme.accent)
        love.graphics.rectangle("fill", qx + gfx.width(shown, qsize) + 3 * u, 56 * u, 3 * u, 42 * u)
    end
    gfx.color(theme.text, 0.2)
    love.graphics.rectangle("fill", m.pad, 116 * u, m.w - 2 * m.pad, 2 * u)
    if self.searching or self.debounce then gfx.spinner(m.w - m.pad - 24 * u, 76 * u, 16 * u) end
    gfx.text(gfx.fit(self:status(), 22 * u, m.w - 2 * m.pad), hx + 24 * u, 132 * u,
        22 * u, self.error and theme.danger or theme.textDim)

    -- keyboard on a solid panel so results scrolled beneath it stay hidden
    love.graphics.setColor(theme.bg)
    love.graphics.rectangle("fill", 0, m.top - 30 * u, m.rx - 40 * u, m.h)
    gfx.hgradient(m.rx - 40 * u, m.top - 30 * u, 30 * u, m.h, theme.bg, 1, 0)
    mouse.region(0, m.top - 30 * u, m.rx - 40 * u, m.h, { block = true })
    self:drawKeyboard(m)
end

return Search
