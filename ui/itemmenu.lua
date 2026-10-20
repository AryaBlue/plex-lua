-- Options for one poster (Plex's "⋯" menu on a card): play, mark watched or
-- unwatched, add to / remove from the watchlist, remove from Continue
-- Watching, go to the show. Watchlist titles that aren't on the server get
-- Request (Seerr) and Remove from Watchlist. Opens beside the
-- card it belongs to, styled like the account menu (ui/profile.lua).
-- Opened with right click, the card's ⋯ button, or Tab / Y on a focused card.

local theme = require("theme")
local gfx = require("ui.gfx")
local api = require("plex.api")
local mouse = require("ui.mouse")
local watchlist = require("plex.watchlist")

local ItemMenu = {}
ItemMenu.__index = ItemMenu

-- opts: anchor = { x, y, w, h } (the card), continueWatching = the card is in
-- that row, onChange(what) after a change ("watched" | "continue" | "watchlist").
function ItemMenu.open(server, item, opts)
    if not item or item.type == "genre" or item.seerr or not item.ratingKey then return end
    local menu = ItemMenu.new(server, item, opts)
    if #menu.entries > 0 then app.push(menu) end
end

function ItemMenu.new(server, item, opts)
    opts = opts or {}
    local self = setmetatable({ server = server, item = item, opts = opts, sel = 1, open = 0, overlay = true }, ItemMenu)
    local e = {}
    local function add(label, run) e[#e + 1] = { label = label, run = run } end
    self.entries = e
    if item.notOnServer then
        if require("seerr.api").enabled() and item.tmdbId then
            add("Request", function()
                app.pop()
                app.push(require("ui.request").new(server, ItemMenu.requestItem(item)))
            end)
        end
        add("Remove from Watchlist", function() self:setWatchlist(false) end)
        return self
    end
    local watched, started = api.watchState(item)

    if api.isPlayable(item) then
        local offset = (tonumber(item.viewOffset) or 0) / 1000
        if offset > 5 then
            add("Resume from " .. api.clock(offset), function() self:play() end)
            add("Play from Start", function() self:play(0) end)
        else
            add("Play", function() self:play() end)
        end
    end
    if not watched then add("Mark as Watched", function() self:setWatched(true) end) end
    if started then add("Mark as Unwatched", function() self:setWatched(false) end) end
    if watchlist.guidOf(item) then
        local show = item.type == "episode" or item.type == "season"
        if watchlist.has(item) then
            add(show and "Remove Show from Watchlist" or "Remove from Watchlist", function() self:setWatchlist(false) end)
        else
            add(show and "Add Show to Watchlist" or "Add to Watchlist", function() self:setWatchlist(true) end)
        end
    end
    if opts.continueWatching then add("Remove from Continue Watching", function() self:removeContinue() end) end
    local show = item.type == "episode" and item.grandparentRatingKey or item.type == "season" and item.parentRatingKey
    if show then
        add("Go to Show", function()
            app.pop()
            app.push(require("ui.detail").new(server, { type = "show", ratingKey = show }))
        end)
    end
    return self
end

-- A watchlist entry shaped as the Seerr item ui/request.lua expects.
function ItemMenu.requestItem(item)
    return { seerr = true, type = item.type, mediaType = item.mediaType, tmdbId = item.tmdbId,
             ratingKey = "seerr:" .. item.mediaType .. ":" .. tostring(item.tmdbId),
             title = item.title, year = item.year, summary = item.summary, thumb = item.thumb, art = item.art }
end

function ItemMenu:setWatchlist(on)
    app.pop()
    local item, onChange = self.item, self.opts.onChange
    watchlist.set(item, on, function(ok, err)
        if not ok then return app.notify("Couldn't update the watchlist: " .. tostring(err), "error") end
        local title = item.type == "episode" and item.grandparentTitle or item.type == "season" and item.parentTitle
            or api.displayTitle(item)
        app.notify((on and "Added to your watchlist: " or "Removed from your watchlist: ") .. title)
        if onChange then onChange("watchlist") end
    end)
end

function ItemMenu:play(startAt)
    app.pop()
    local server = self.server
    api.metadata(server, self.item.ratingKey, function(full, err)
        if not full then return app.notify(tostring(err), "error") end
        app.push(require("player.scene").new(server, full, { startAt = startAt }))
    end)
end

function ItemMenu:setWatched(watched)
    app.pop()
    local item, onChange = self.item, self.opts.onChange
    api.setWatched(self.server, item, watched, function(ok, err)
        if not ok then return app.notify("Couldn't update: " .. tostring(err), "error") end
        api.applyWatched(item, watched)
        require("plex.recommend").invalidate()
        app.notify((watched and "Marked as watched: " or "Marked as unwatched: ") .. api.displayTitle(item))
        if onChange then onChange("watched") end
    end)
end

function ItemMenu:removeContinue()
    app.pop()
    local item, onChange = self.item, self.opts.onChange
    api.removeFromContinueWatching(self.server, item, function(ok, err)
        if not ok then return app.notify("Couldn't remove it: " .. tostring(err), "error") end
        app.notify("Removed from Continue Watching")
        if onChange then onChange("continue") end
    end)
end

function ItemMenu:action(a)
    if a == "up" then self.sel = math.max(1, self.sel - 1)
    elseif a == "down" then self.sel = math.min(#self.entries, self.sel + 1)
    elseif a == "accept" then self.entries[self.sel].run()
    elseif a == "back" or a == "menu" or a == "left" or a == "right" then app.pop() end
end

function ItemMenu:update(dt)
    self.open = gfx.approach(self.open, 1, dt, 18)
end

function ItemMenu:draw()
    local w, h = love.graphics.getDimensions()
    local u = gfx.unit()
    local a = self.open
    local mw, rowH, headH = 360 * u, 56 * u, 84 * u
    local mh = headH + #self.entries * rowH + 14 * u
    -- beside the card (right if it fits, else left), else centred
    local x, y
    local an = self.opts.anchor
    if an then
        x = an.x + an.w + 18 * u
        if x + mw > w - 20 * u then x = an.x - mw - 18 * u end
        if x < 20 * u then x = math.max(20 * u, math.min(w - mw - 20 * u, an.x + (an.w - mw) / 2)) end
        y = an.y
    else
        x, y = (w - mw) / 2, (h - mh) / 2
    end
    y = math.max(20 * u, math.min(h - mh - 20 * u, y)) - (1 - a) * 12 * u

    -- clicking anywhere else closes the menu
    mouse.region(0, 0, w, h, { click = function() app.pop() end, context = function() app.pop() end,
                               wheel = function() return true end })
    gfx.color({ 0, 0, 0 }, 0.35 * a)
    gfx.roundRect("fill", x - 2 * u, y + 4 * u, mw + 4 * u, mh + 4 * u, 14 * u)
    gfx.color(theme.surface, 0.98 * a)
    gfx.roundRect("fill", x, y, mw, mh, 12 * u)
    mouse.region(x, y, mw, mh, { click = function() end, context = function() end })

    -- which item this is for
    local item = self.item
    gfx.text(gfx.fit(api.displayTitle(item), 24 * u, mw - 48 * u), x + 24 * u, y + 16 * u, 24 * u, theme.text, a)
    local sub = api.subtitle(item)
    if sub and sub ~= "" then
        gfx.text(gfx.fit(sub, 18 * u, mw - 48 * u), x + 24 * u, y + 48 * u, 18 * u, theme.textDim, a)
    end
    gfx.color(theme.text, 0.1 * a)
    love.graphics.rectangle("fill", x + 20 * u, y + headH - 4 * u, mw - 40 * u, 1)

    local ry = y + headH + 4 * u
    for i, e in ipairs(self.entries) do
        if self.sel == i then
            gfx.color(theme.text, 0.1 * a)
            love.graphics.rectangle("fill", x, ry, mw, rowH)
            gfx.color(theme.accent, a)
            love.graphics.rectangle("fill", x, ry + 12 * u, 4 * u, rowH - 24 * u)
        end
        gfx.text(e.label, x + 30 * u, ry + (rowH - gfx.font(22 * u):getHeight()) / 2, 22 * u,
            self.sel == i and theme.text or theme.textDim, a)
        mouse.region(x, ry, mw, rowH, {
            hover = function() self.sel = i end,
            click = function() e.run() end,
        })
        ry = ry + rowH
    end
end

return ItemMenu
