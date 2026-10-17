-- Detail page for a movie, show, season or episode.
--
-- Sections (focus moves vertically between them):
--   buttons   Play/Resume, Start over, Mark watched, Go to show
--   seasons   season tabs (shows)
--   episodes  episode cards of the selected season
--   related   "More like this"

local theme = require("theme")
local gfx = require("ui.gfx")
local W = require("ui.widgets")
local api = require("plex.api")
local mouse = require("ui.mouse")

local Detail = {}
Detail.__index = Detail

function Detail.new(server, item)
    local self = setmetatable({
        server = server,
        stub = item,             -- what we were opened with (may be partial)
        item = nil,              -- full metadata of the movie/show/episode shown
        seasons = nil, season = 1,
        episodes = nil, episodeCol = 1,
        related = nil, relatedCol = 1,
        sections = {}, focus = 1, button = 1,
        anim = {}, scrollY = 0,
        epScroll = 0, relScroll = 0,     -- first visible card of each row (target of anim.epScroll/relScroll)
        epVisible = 3, relVisible = 6,   -- cards that fit across, measured while drawing
        backdrop = W.newBackdrop(),
        loading = true,
    }, Detail)
    return self
end

function Detail:enter()
    local stub = self.stub
    if stub.type == "season" then
        -- a season opens its show with that season selected
        self.wantSeason = stub.ratingKey
        self:load(stub.parentRatingKey)
    else
        self:load(stub.ratingKey)
    end
end

function Detail:resume()
    -- back from the player: progress changed
    if self.item then self:load(self.item.ratingKey, true) end
end

function Detail:load(ratingKey, quiet)
    if not quiet then self.loading = true end
    api.metadata(self.server, ratingKey, function(item, err)
        self.loading = false
        if not item then self.error = err; return end
        self.item = item
        self.backdrop:set(self.server, item.art or item.grandparentArt)
        if item.type == "show" then
            api.children(self.server, item.ratingKey, function(seasons)
                self.seasons = {}
                for _, s in ipairs(seasons or {}) do
                    if s.type == "season" then self.seasons[#self.seasons + 1] = s end
                end
                -- default: requested season, else first with something unwatched
                local pick
                for i, s in ipairs(self.seasons) do
                    if self.wantSeason and s.ratingKey == self.wantSeason then pick = i end
                end
                -- otherwise the first regular season with something unwatched (Specials last)
                if not pick then
                    for i, s in ipairs(self.seasons) do
                        if not pick and (tonumber(s.index) or 0) > 0
                           and (tonumber(s.viewedLeafCount) or 0) < (tonumber(s.leafCount) or 0) then pick = i end
                    end
                end
                if not pick then
                    for i, s in ipairs(self.seasons) do
                        if not pick and (tonumber(s.index) or 0) > 0 then pick = i end
                    end
                end
                self.wantSeason = nil
                self:selectSeason(pick or self.season or 1, true)
            end)
        end
        if item.type ~= "episode" then
            api.related(self.server, item.ratingKey, function(list)
                self.related = list
                self:buildSections()
            end)
        end
        self:buildSections()
    end)
end

-- setUpNext: this is the season the show opens on, so its first unfinished
-- episode becomes what the Play button plays.
function Detail:selectSeason(i, setUpNext)
    if not self.seasons or not self.seasons[i] then return end
    self.season = i
    self.episodes = nil
    local key = self.seasons[i].ratingKey
    api.children(self.server, key, function(eps)
        if not self.seasons[self.season] or self.seasons[self.season].ratingKey ~= key then return end
        self.episodes = eps or {}
        -- focus the first episode not yet finished
        self.episodeCol = 1
        for c, e in ipairs(self.episodes) do
            if (tonumber(e.viewCount) or 0) == 0 or api.progress(e) then self.episodeCol = c; break end
        end
        if setUpNext then self.upNext = self.episodes[self.episodeCol] end
        self:buildSections()
    end)
    self:buildSections()
end

-- The episode a show's main button plays: the next unwatched one, fixed when the
-- page loads (and after returning from the player), not whichever card has focus.
function Detail:nextEpisode()
    return self.upNext
end

function Detail:buildSections()
    local item = self.item
    if not item then return end
    local s = { "buttons" }
    if item.type == "show" then
        s[#s + 1] = "seasons"
        s[#s + 1] = "episodes"
    end
    if self.related and #self.related > 0 then s[#s + 1] = "related" end
    self.sections = s
    if self.focus > #s then self.focus = #s end

    local buttons = {}
    local target = item.type == "show" and self:nextEpisode() or item
    if target then
        local prog = api.progress(target)
        local label
        if item.type == "show" then
            label = (prog and "Resume " or "Play ") .. ("S%d E%d"):format(tonumber(target.parentIndex) or 0, tonumber(target.index) or 0)
        else
            label = prog and ("Resume  " .. api.runtime((target.duration or 0) - (target.viewOffset or 0)) .. " left") or "Play"
        end
        buttons[#buttons + 1] = { label = label, icon = "play", primary = true, progress = prog,
            run = function() self:play(target) end }
        if prog then
            buttons[#buttons + 1] = { label = "Start Over", icon = "restart",
                run = function() self:play(target, 0) end }
        end
    end
    if item.type ~= "show" then
        local watched = (tonumber(item.viewCount) or 0) > 0
        buttons[#buttons + 1] = { label = watched and "Mark Unwatched" or "Mark Watched", icon = "check",
            run = function() self:toggleWatched(item, not watched) end }
    end
    if item.type == "episode" and item.grandparentRatingKey then
        buttons[#buttons + 1] = { label = "Go to Show", run = function()
            app.push(Detail.new(self.server, { type = "show", ratingKey = item.grandparentRatingKey }))
        end }
    end
    self.buttons = buttons
    self.button = math.min(self.button, #buttons)
end

function Detail:play(target, startAt)
    if not target then return end
    -- episodes listed under a show are partial; fetch full metadata (Media/Part) first
    api.metadata(self.server, target.ratingKey, function(full, err)
        if not full then return app.notify(tostring(err), "error") end
        app.push(require("player.scene").new(self.server, full, { startAt = startAt }))
    end)
end

function Detail:toggleWatched(item, watched)
    api.setWatched(self.server, item, watched, function(ok, err)
        if not ok then return app.notify("Couldn't update: " .. tostring(err), "error") end
        app.notify(watched and "Marked as watched" or "Marked as unwatched")
        self:load(self.item.ratingKey, true)
    end)
end

function Detail:action(a)
    self.mouseScroll = false
    self.pointerFocus = false
    local sec = self.sections[self.focus]
    if a == "back" then return app.pop() end
    if self.backFocus then
        if a == "accept" then return app.pop() end
        if a == "down" then self.backFocus = false end
        return
    end
    if a == "up" then
        if self.focus == 1 then self.backFocus = true end
        self.focus = math.max(1, self.focus - 1)
        return
    end
    if a == "down" then self.focus = math.min(#self.sections, self.focus + 1); return end

    if sec == "buttons" and self.buttons then
        if a == "left" then self.button = math.max(1, self.button - 1)
        elseif a == "right" then self.button = math.min(#self.buttons, self.button + 1)
        elseif a == "accept" then local b = self.buttons[self.button]; if b then b.run() end
        elseif a == "playpause" then local b = self.buttons[1]; if b then b.run() end
        end
    elseif sec == "seasons" and self.seasons then
        if a == "left" and self.season > 1 then self:selectSeason(self.season - 1)
        elseif a == "right" and self.season < #self.seasons then self:selectSeason(self.season + 1)
        elseif a == "accept" then self.focus = self.focus + 1
        end
    elseif sec == "episodes" and self.episodes then
        if a == "left" then self.episodeCol = math.max(1, self.episodeCol - 1); self:buildSections()
        elseif a == "right" then self.episodeCol = math.min(#self.episodes, self.episodeCol + 1); self:buildSections()
        elseif a == "accept" or a == "playpause" then self:play(self.episodes[self.episodeCol])
        end
    elseif sec == "related" and self.related then
        if a == "left" then self.relatedCol = math.max(1, self.relatedCol - 1)
        elseif a == "right" then self.relatedCol = math.min(#self.related, self.relatedCol + 1)
        elseif a == "accept" then app.push(Detail.new(self.server, self.related[self.relatedCol]))
        end
    end
end

-- Keep card `col` inside the visible window, with a neighbour showing where possible.
local function followCol(first, col, visible)
    local margin = visible > 2 and 1 or 0
    if col - 1 - margin < first then first = col - 1 - margin end
    if col + margin > first + visible then first = col + margin - visible end
    return first
end

local function clampScroll(first, n, visible)
    return math.max(0, math.min(first, n - visible))
end

-- The row arrows: page by a screenful less one card.
function Detail:page(which, dir)
    self.pointerFocus, self.mouseScroll = true, true
    if which == "episodes" then
        self.epScroll = clampScroll(self.epScroll + dir * math.max(1, self.epVisible - 1), #self.episodes, self.epVisible)
    else
        self.relScroll = clampScroll(self.relScroll + dir * math.max(1, self.relVisible - 1), #self.related, self.relVisible)
    end
end

-- Arrows at both ends of a row while the pointer is over it and there's more that way.
local function rowArrows(self, which, y, h, first, n, visible)
    W.rowArrows(0, y, love.graphics.getWidth(), h, first, n, visible, function(dir) self:page(which, dir) end)
end

function Detail:update(dt)
    self.backdrop:update(dt)
    local function ease(key, want) self.anim[key] = gfx.approach(self.anim[key] or 0, want, dt, 16) end
    local sec = self.sections[self.focus]
    for i = 1, #(self.buttons or {}) do ease("b" .. i, (sec == "buttons" and self.button == i and not self.backFocus) and 1 or 0) end
    for i = 1, #(self.episodes or {}) do ease("e" .. i, (sec == "episodes" and self.episodeCol == i) and 1 or 0) end
    for i = 1, #(self.related or {}) do ease("r" .. i, (sec == "related" and self.relatedCol == i) and 1 or 0) end
    ease("seasons", sec == "seasons" and 1 or 0)
    -- rows follow keyboard focus; when the pointer chose the card (or paged with
    -- the arrows) the row stays where it is
    if not self.pointerFocus then
        self.epScroll = followCol(self.epScroll, self.episodeCol, self.epVisible)
        self.relScroll = followCol(self.relScroll, self.relatedCol, self.relVisible)
    end
    self.epScroll = clampScroll(self.epScroll, #(self.episodes or {}), self.epVisible)
    self.relScroll = clampScroll(self.relScroll, #(self.related or {}), self.relVisible)
    ease("epScroll", self.epScroll)
    ease("relScroll", self.relScroll)
    -- scroll the page so lower sections come into view
    local h = love.graphics.getHeight()
    if not self.mouseScroll then
        local target = 0
        if sec == "episodes" and self.episodesBottom then target = math.max(0, self.episodesBottom - h + 40) end
        if sec == "related" and self.relatedY then target = math.max(0, self.relatedY - h * 0.45) end
        self.scrollTarget = target
    end
    self.scrollY = gfx.approach(self.scrollY, self.scrollTarget or 0, dt, 12)
end

function Detail:wheel(dx, dy)
    if dy == 0 then return end
    local u = gfx.unit()
    local bottom = (self.contentBottom or love.graphics.getHeight()) - love.graphics.getHeight() + 60 * u
    self.mouseScroll = true
    self.scrollTarget = math.max(0, math.min(math.max(0, bottom), (self.scrollTarget or 0) - dy * 150 * u))
end

-- Horizontal wheel over a card row steps through it.
local function rowWheel(self, which)
    return function(dx)
        if dx == 0 then return false end
        self.pointerFocus = false
        local step = dx > 0 and 1 or -1
        if which == "episodes" and self.episodes then
            self.episodeCol = math.max(1, math.min(#self.episodes, self.episodeCol + step))
            self:buildSections()
        elseif which == "related" and self.related then
            self.relatedCol = math.max(1, math.min(#self.related, self.relatedCol + step))
        end
        return true
    end
end

local function focusSection(self, name)
    for i, s in ipairs(self.sections) do
        if s == name then self.focus = i end
    end
end

local function metaLine(item)
    local parts = {}
    if item.type == "episode" then
        parts[#parts + 1] = ("Season %d  ·  Episode %d"):format(tonumber(item.parentIndex) or 0, tonumber(item.index) or 0)
    end
    if item.year then parts[#parts + 1] = tostring(item.year) end
    if item.contentRating then parts[#parts + 1] = item.contentRating end
    if item.duration and item.type ~= "show" then parts[#parts + 1] = api.runtime(item.duration) end
    if item.type == "show" and item.childCount then
        parts[#parts + 1] = item.childCount .. (tonumber(item.childCount) == 1 and " Season" or " Seasons")
    end
    if item.audienceRating then parts[#parts + 1] = ("%.1f/10"):format(item.audienceRating) end
    local media = item.Media and item.Media[1]
    if media and media.videoResolution then
        local res = tostring(media.videoResolution)
        parts[#parts + 1] = (res == "4k" and "4K" or (res:match("^%d+$") and res .. "p" or res:upper()))
    end
    return table.concat(parts, "   ·   ")
end

local function tagList(list, n)
    local out = {}
    for i = 1, math.min(n, #(list or {})) do out[#out + 1] = list[i].tag end
    return table.concat(out, ", ")
end

function Detail:draw()
    local w, h = love.graphics.getDimensions()
    local u = gfx.unit()
    local pad = 90 * u
    love.graphics.clear(theme.bg)

    -- backdrop on the right, fading into the page on the left and bottom
    self.backdrop:draw(w * 0.25, -self.scrollY, w * 0.75, h * 0.8, 1, 0.2)
    gfx.hgradient(w * 0.25, -self.scrollY, w * 0.4, h * 0.8, theme.bg, 1, 0)
    gfx.vgradient(0, h * 0.45 - self.scrollY, w, h * 0.35 + 2, theme.bg, 0, 1)
    love.graphics.setColor(theme.bg)
    love.graphics.rectangle("fill", 0, h * 0.8 - self.scrollY, w, h * 2)

    local item = self.item
    if not item then
        if self.error then
            gfx.textCentered("Couldn't load: " .. tostring(self.error), w / 2, h / 2, 26 * u, theme.danger)
        else
            gfx.spinner(w / 2, h / 2, 30 * u)
        end
        W.backButton(24 * u, 26 * u, 56 * u, false, function() app.pop() end)
        return
    end

    local y = 110 * u - self.scrollY
    local maxW = w * 0.45
    if item.type == "episode" then
        gfx.text(item.grandparentTitle or "", pad, y, 30 * u, theme.textDim)
        y = y + 44 * u
    end
    local titleH = gfx.wrapped(item.title or "", pad, y, maxW, 64 * u, theme.text, 2)
    y = y + titleH + 14 * u
    if item.tagline and item.tagline ~= "" then
        gfx.text(gfx.fit(item.tagline, 24 * u, maxW), pad, y, 24 * u, theme.accent)
        y = y + 38 * u
    end
    gfx.text(metaLine(item), pad, y, 23 * u, theme.textDim)
    y = y + 44 * u
    y = y + gfx.wrapped(item.summary or "", pad, y, maxW, 23 * u, theme.text, 5) + 18 * u
    local genres = tagList(item.Genre, 3)
    local cast = tagList(item.Role, 4)
    local director = tagList(item.Director, 2)
    if genres ~= "" then gfx.text("Genres:  " .. genres, pad, y, 20 * u, theme.textDim); y = y + 30 * u end
    if director ~= "" then gfx.text("Director:  " .. director, pad, y, 20 * u, theme.textDim); y = y + 30 * u end
    if cast ~= "" then gfx.text(gfx.fit("Starring:  " .. cast, 20 * u, maxW), pad, y, 20 * u, theme.textDim); y = y + 30 * u end

    -- buttons
    y = y + 24 * u
    local bx = pad
    for i, b in ipairs(self.buttons or {}) do
        local bw = W.button(b.label, bx, y, 62 * u, self.anim["b" .. i] or 0,
            { primary = b.primary, icon = b.icon, progress = b.progress })
        mouse.region(bx, y, bw, 62 * u, {
            hover = function() self.mouseScroll = true; focusSection(self, "buttons"); self.button = i end,
            click = function() b.run() end,
        })
        bx = bx + bw + 18 * u
    end
    y = y + 62 * u + 48 * u

    -- seasons + episodes
    if item.type == "show" then
        local sx = pad
        for i, s in ipairs(self.seasons or {}) do
            local label = s.title or ("Season " .. tostring(s.index))
            local lw = gfx.width(label, 26 * u)
            local sel = i == self.season
            if sel then
                gfx.color(theme.surfaceHi, 0.6 + 0.4 * (self.anim.seasons or 0))
                gfx.roundRect("fill", sx - 16 * u, y - 8 * u, lw + 32 * u, 46 * u, 23 * u)
                if (self.anim.seasons or 0) > 0.05 then
                    gfx.color(theme.accent, self.anim.seasons)
                    love.graphics.setLineWidth(2.5 * u)
                    gfx.roundRect("line", sx - 16 * u, y - 8 * u, lw + 32 * u, 46 * u, 23 * u)
                end
            end
            gfx.text(label, sx, y, 26 * u, sel and theme.text or theme.textDim)
            mouse.region(sx - 16 * u, y - 8 * u, lw + 32 * u, 46 * u, {
                hover = function() self.mouseScroll = true; focusSection(self, "seasons") end,
                click = function() if self.season ~= i then self:selectSeason(i) end end,
            })
            sx = sx + lw + 48 * u
            if sx > w - pad then break end
        end
        y = y + 70 * u

        local cw, ch = 380 * u, 380 * u * W.WIDE_ASPECT
        if not self.episodes then
            gfx.spinner(pad + 40 * u, y + ch / 2, 22 * u)
        else
            local off = (self.anim.epScroll or 0) * (cw + 22 * u)
            self.epVisible = math.max(1, math.floor((w - pad - 40 * u + 22 * u) / (cw + 22 * u)))
            mouse.region(0, y, w, ch, { wheel = rowWheel(self, "episodes") })
            for c, e in ipairs(self.episodes) do
                local cx = pad + (c - 1) * (cw + 22 * u) - off
                if cx > w then break end
                if cx + cw > 0 then
                    W.card(self.server, e, cx, y, cw, ch, self.anim["e" .. c] or 0, "wide")
                    mouse.region(cx, y, cw, ch, {
                        hover = function() self.mouseScroll = true;
                            focusSection(self, "episodes")
                            self.pointerFocus = true
                            if self.episodeCol ~= c then self.episodeCol = c; self:buildSections() end
                        end,
                        click = function() self:play(e) end,
                    })
                end
            end
            self.episodeRow = { y = y, h = ch }   -- for tools/shots.lua
            rowArrows(self, "episodes", y, ch, self.anim.epScroll or 0, #self.episodes, self.epVisible)
            local e = self.episodes[self.episodeCol]
            if e and self.sections[self.focus] == "episodes" then
                local ty = y + ch + 22 * u
                gfx.text(("%d. %s  ·  %s"):format(tonumber(e.index) or 0, e.title or "", api.runtime(e.duration)),
                    pad, ty, 24 * u, theme.text)
                gfx.wrapped(e.summary or "", pad, ty + 36 * u, w * 0.6, 20 * u, theme.textDim, 2)
            end
        end
        y = y + ch + 150 * u
        self.episodesBottom = y + self.scrollY
    end

    -- related
    if self.related and #self.related > 0 then
        self.relatedY = y + self.scrollY
        gfx.text("More Like This", pad, y, 30 * u, self.sections[self.focus] == "related" and theme.text or theme.textDim)
        y = y + 50 * u
        local cw = 180 * u
        local chR = cw * W.POSTER_ASPECT
        local off = (self.anim.relScroll or 0) * (cw + 20 * u)
        self.relVisible = math.max(1, math.floor((w - pad - 40 * u + 20 * u) / (cw + 20 * u)))
        mouse.region(0, y, w, chR, { wheel = rowWheel(self, "related") })
        for c, r in ipairs(self.related) do
            local cx = pad + (c - 1) * (cw + 20 * u) - off
            if cx > w then break end
            if cx + cw > 0 then
                W.card(self.server, r, cx, y, cw, chR, self.anim["r" .. c] or 0, "poster")
                mouse.region(cx, y, cw, chR, {
                    hover = function() self.mouseScroll = true; focusSection(self, "related"); self.pointerFocus = true; self.relatedCol = c end,
                    click = function() app.push(Detail.new(self.server, r)) end,
                })
            end
        end
        rowArrows(self, "related", y, chR, self.anim.relScroll or 0, #self.related, self.relVisible)
        y = y + chR + 90 * u
    end
    self.contentBottom = y + self.scrollY

    -- back button, fixed at the top left
    W.backButton(24 * u, 26 * u, 56 * u, self.backFocus, function() app.pop() end)
end

return Detail
