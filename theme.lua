-- Branding and colours in one place. The colour fields are swapped in place by
-- theme.apply(presetId) (Settings > Theme); everything reads them at draw time.
local theme = {
    appName = "Reel",                -- placeholder product name
    tagline = "Your media, your way",
    version = "0.1.0",
}

-- The default colours; a preset changes only the fields it lists.
local BASE = {
    accent = { 0.89, 0.25, 0.32 },   -- #E34052
    accentDark = { 0.62, 0.14, 0.20 },
    bg = { 0.055, 0.055, 0.07 },
    surface = { 0.11, 0.11, 0.14 },
    surfaceHi = { 0.18, 0.18, 0.22 },
    text = { 0.96, 0.96, 0.97 },
    textDim = { 0.62, 0.63, 0.68 },
    success = { 0.35, 0.80, 0.45 },
    warning = { 0.95, 0.70, 0.25 },
    danger = { 0.92, 0.33, 0.33 },
}

local function rgb(hex)
    return { tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255 }
end

theme.presets = {
    { id = "reel", name = "Reel" },
    { id = "plex", name = "Plex Gold", accent = rgb("E5A00D"), accentDark = rgb("8A6008"),
      bg = rgb("1F2326"), surface = rgb("2B3035"), surfaceHi = rgb("3A4046"), textDim = rgb("A3A9AF") },
    { id = "cinema", name = "Cinema", accent = rgb("E50914"), accentDark = rgb("8C060C"),
      bg = rgb("141414"), surface = rgb("1F1F1F"), surfaceHi = rgb("2F2F2F"), textDim = rgb("A3A3A3") },
    { id = "ocean", name = "Ocean", accent = rgb("3B9EFF"), accentDark = rgb("1D5FA3"),
      bg = rgb("0B1220"), surface = rgb("142034"), surfaceHi = rgb("1F2F4A"), textDim = rgb("8FA3BF") },
    { id = "emerald", name = "Emerald", accent = rgb("2ECC8F"), accentDark = rgb("17805A"),
      bg = rgb("0A1411"), surface = rgb("13221D"), surfaceHi = rgb("1E332C"), textDim = rgb("8DAA9F") },
    { id = "violet", name = "Violet", accent = rgb("A66BFF"), accentDark = rgb("6438AD"),
      bg = rgb("110D1A"), surface = rgb("1C1629"), surfaceHi = rgb("2A213D"), textDim = rgb("A197B5") },
    { id = "sunset", name = "Sunset", accent = rgb("FF7A45"), accentDark = rgb("A8471F"),
      bg = rgb("1A100D"), surface = rgb("281915"), surfaceHi = rgb("3A2620"), textDim = rgb("B59D94") },
    { id = "oled", name = "OLED Black", accent = rgb("8AB4F8"), accentDark = rgb("4A6FA8"),
      bg = rgb("000000"), surface = rgb("0E0E0E"), surfaceHi = rgb("1E1E1E"), textDim = rgb("8A8A8A") },
}

function theme.preset(id)
    for _, p in ipairs(theme.presets) do
        if p.id == id then return p end
    end
    return theme.presets[1]
end

local function hex(c)
    return ("#%02X%02X%02X"):format(math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
end

-- All the colours of a preset (for previews).
function theme.colorsOf(id)
    local p, c = theme.preset(id), {}
    for k, v in pairs(BASE) do c[k] = p[k] or v end
    return c
end

-- Switch the colours to a preset (unknown id = the default).
function theme.apply(id)
    local p = theme.preset(id)
    for k, v in pairs(theme.colorsOf(id)) do theme[k] = v end
    theme.id = p.id
    theme.accentHex = hex(theme.accent)
    if love and love.graphics then love.graphics.setBackgroundColor(theme.bg) end
end

theme.apply("reel")

return theme
