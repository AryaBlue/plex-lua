-- Request page for a film or show that isn't on the Plex server (from Seerr).
-- Shows what Seerr knows about it and, if it can still be requested, a
-- Request button. Shows request every season that isn't on the server or
-- already requested.

local theme = require("theme")
local gfx = require("ui.gfx")
local W = require("ui.widgets")
local json = require("lib.json")
local seerr = require("seerr.api")
local mouse = require("ui.mouse")

local Request = {}
Request.__index = Request

function Request.new(server, item)
    return setmetatable({
        server = server,
        item = item,             -- search result (shaped like a Plex item)
        details = nil,
        buttons = {}, button = 1,
        backFocus = false,
        anim = {},
        backdrop = W.newBackdrop(),
        loading = true,
    }, Request)
end

function Request:enter()
    self.backdrop:set(self.server, self.item.art)
    self:load()
end

function Request:load()
    seerr.details(self.item, function(d, err)
        self.loading = false
        if not d then self.error = tostring(err); return end
        self.details = d
        local info = d.mediaInfo ~= json.null and d.mediaInfo or nil
        self.status = info and tonumber(info.status) or nil
        self.item.status = self.status              -- keeps the search card's badge current
        self:buildButtons()
    end)
end

local function plural(n, word) return n .. " " .. word .. (n == 1 and "" or "s") end

function Request:buildButtons()
    local d, item = self.details, self.item
    local b = {}
    self.note = nil
    local st = self.status
    if item.mediaType == "tv" then
        local missing = seerr.missingSeasons(d)
        local total = 0
        for _, s in ipairs(d.seasons or {}) do if (tonumber(s.seasonNumber) or 0) > 0 then total = total + 1 end end
        if #missing > 0 and st ~= seerr.BLOCKLISTED then
            local label = #missing == total and (total == 1 and "Request" or "Request All Seasons")
                or ("Request %s"):format(plural(#missing, "Missing Season"))
            b[#b + 1] = { label = label, primary = true, run = function() self:send(missing) end }
            if #missing < total then
                local list = {}
                for _, n in ipairs(missing) do list[#list + 1] = tostring(n) end
                self.note = "Not on the server or requested yet: season " .. table.concat(list, ", ")
            end
        elseif st ~= seerr.BLOCKLISTED then
            self.note = "Every season so far is on the server or already requested."
        end
    elseif st == nil or st == seerr.UNKNOWN or st == seerr.DELETED then
        b[#b + 1] = { label = "Request", primary = true, run = function() self:send() end }
    end
    b[#b + 1] = { label = "Back", run = function() app.pop() end }
    self.buttons = b
    self.button = 1
end

function Request:send(seasons)
    if self.sending then return end
    self.sending = true
    local item = self.item
    seerr.request(item, seasons, function(req, err)
        self.sending = false
        if not req then return app.notify("Request failed: " .. tostring(err), "error") end
        local approved = tonumber(req.status) == 2 or seerr.autoApproved(item.mediaType)
        app.notify(("Requested %s%s"):format(item.title, approved and "" or " · waiting for approval"))
        self:load()
    end)
end

function Request:statusLine()
    local st = self.status
    if st == seerr.PENDING then return "Requested · waiting for approval"
    elseif st == seerr.PROCESSING then return "Requested · approved, on its way"
    elseif st == seerr.PARTIAL then return "Partly available on Plex"
    elseif st == seerr.AVAILABLE then return "Available on Plex"
    elseif st == seerr.BLOCKLISTED then return "Can't be requested (blocklisted)"
    end
    return "Not on the server"
end

function Request:action(a)
    if a == "back" then return app.pop() end
    if self.backFocus then
        if a == "accept" then return app.pop() end
        if a == "down" then self.backFocus = false end
        return
    end
    if a == "up" then self.backFocus = true
    elseif a == "left" then self.button = math.max(1, self.button - 1)
    elseif a == "right" then self.button = math.min(#self.buttons, self.button + 1)
    elseif a == "accept" then
        local b = self.buttons[self.button]
        if b then b.run() end
    end
end

function Request:update(dt)
    self.backdrop:update(dt)
    for i = 1, #self.buttons do
        local want = (not self.backFocus and self.button == i) and 1 or 0
        self.anim[i] = gfx.approach(self.anim[i] or 0, want, dt, 16)
    end
end

local function names(list, n)
    local out = {}
    for i = 1, math.min(n, #(list or {})) do out[#out + 1] = list[i].name end
    return table.concat(out, ", ")
end

function Request:draw()
    local w, h = love.graphics.getDimensions()
    local u = gfx.unit()
    local pad = 90 * u
    love.graphics.clear(theme.bg)
    -- the text runs further right than on the Plex detail page, so fade wider
    self.backdrop:draw(w * 0.25, 0, w * 0.75, h * 0.8, 0.85, 0.2)
    gfx.hgradient(w * 0.25, 0, w * 0.6, h * 0.8, theme.bg, 1, 0.15)
    gfx.vgradient(0, h * 0.45, w, h * 0.35 + 2, theme.bg, 0, 1)
    love.graphics.setColor(theme.bg)
    love.graphics.rectangle("fill", 0, h * 0.8, w, h * 0.2)

    local item, d = self.item, self.details or {}
    -- poster on the left, text beside it
    local pw = 260 * u
    local ph = pw * W.POSTER_ASPECT
    local py = 120 * u
    W.card(self.server, item, pad, py, pw, ph, 0, "poster")
    local x = pad + pw + 50 * u
    local maxW = math.min(w * 0.45, w - x - pad)
    local y = py

    gfx.text(item.mediaType == "tv" and "SERIES" or "FILM", x, y, 20 * u, theme.accent)
    y = y + 34 * u
    y = y + gfx.wrapped(item.title, x, y, maxW, 58 * u, theme.text, 2) + 10 * u
    if d.tagline and d.tagline ~= "" and d.tagline ~= json.null then
        gfx.text(gfx.fit(d.tagline, 22 * u, maxW), x, y, 22 * u, theme.textDim)
        y = y + 36 * u
    end
    local meta = {}
    if item.year then meta[#meta + 1] = tostring(item.year) end
    if tonumber(d.runtime) and d.runtime > 0 then meta[#meta + 1] = require("plex.api").runtime(d.runtime * 60000) end
    if tonumber(d.numberOfSeasons) then meta[#meta + 1] = plural(d.numberOfSeasons, "Season") end
    if tonumber(d.voteAverage) and d.voteAverage > 0 then meta[#meta + 1] = ("%.1f/10"):format(d.voteAverage) end
    local genres = names(d.genres, 3)
    if genres ~= "" then meta[#meta + 1] = genres end
    gfx.text(table.concat(meta, "   ·   "), x, y, 22 * u, theme.textDim)
    y = y + 42 * u

    -- request state
    local st = self:statusLine()
    local good = self.status == seerr.AVAILABLE or self.status == seerr.PROCESSING
    gfx.color(good and theme.success or (self.status == seerr.PENDING and theme.accent or theme.textDim))
    love.graphics.circle("fill", x + 7 * u, y + 13 * u, 6 * u)
    gfx.text(st, x + 24 * u, y, 24 * u, theme.text)
    y = y + 40 * u
    if self.note then
        gfx.text(gfx.fit(self.note, 20 * u, maxW), x, y, 20 * u, theme.textDim)
        y = y + 32 * u
    end
    y = y + 6 * u
    y = y + gfx.wrapped(d.overview ~= json.null and d.overview or item.summary or "", x, y, maxW, 22 * u, theme.text, 6) + 30 * u

    if self.loading then
        gfx.spinner(x + 30 * u, y + 30 * u, 22 * u)
    elseif self.error then
        gfx.wrapped("Couldn't reach Seerr: " .. self.error, x, y, maxW, 22 * u, theme.danger, 3)
    else
        local bx = x
        for i, b in ipairs(self.buttons) do
            local label = (b.primary and self.sending) and "Requesting…" or b.label
            local bw = W.button(label, bx, y, 62 * u, self.anim[i] or 0, { primary = b.primary })
            mouse.region(bx, y, bw, 62 * u, {
                hover = function() self.button, self.backFocus = i, false end,
                click = function() b.run() end,
            })
            bx = bx + bw + 18 * u
        end
        if seerr.user() and seerr.user().displayName then
            gfx.text("Requests are made as " .. tostring(seerr.user().displayName) .. " on " ..
                seerr.baseUrl():gsub("^https?://", ""), x, y + 84 * u, 18 * u, theme.textDim)
        end
    end

    W.backButton(24 * u, 26 * u, 56 * u, self.backFocus, function() app.pop() end)
end

return Request
