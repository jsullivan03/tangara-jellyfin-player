local M = {}

local ACCENTS = {
    blue = {
        accent = "#4D8DFF",
        accent_muted = "#294A78",
        placeholder_cover = "#173A5E",
    },
    violet = {
        accent = "#946BDE",
        accent_muted = "#513B78",
        placeholder_cover = "#352452",
    },
    green = {
        accent = "#42A66B",
        accent_muted = "#285E3E",
        placeholder_cover = "#183F2A",
    },
    amber = {
        accent = "#D79028",
        accent_muted = "#76501F",
        placeholder_cover = "#4B3215",
    },
    rose = {
        accent = "#D8627E",
        accent_muted = "#79394A",
        placeholder_cover = "#502431",
    },
}

local MODES = {
    dark = {
        background = "#07080C",
        foreground = "#FFFFFF",
        muted_text = "#AEB0B8",
        surface = "#11131A",
        selected_surface = "#34363F",
        divider = "#555862",
        focus_text = "#FFFFFF",
        overlay = "#000000",
        status_background = "#05060A",
        status_muted = "#8A8C93",
        status_good = "#74C991",
        status_bad = "#E06666",
    },
    light = {
        background = "#F7F8FA",
        foreground = "#17191F",
        muted_text = "#5F626C",
        surface = "#FFFFFF",
        selected_surface = "#DDE7F5",
        divider = "#A9ADB7",
        focus_text = "#FFFFFF",
        overlay = "#FFFFFF",
        status_background = "#ECEEF2",
        status_muted = "#5F626C",
        status_good = "#237A47",
        status_bad = "#B33A3A",
    },
}

local mode = "dark"
local accent = "blue"
local active_palette = {}

local function valid(table_value, key)
    return type(key) == "string" and
        table_value[key] ~= nil
end

local function environment(name)
    local ok, value = pcall(os.getenv, name)

    if ok and type(value) == "string" then
        return value:lower()
    end

    return nil
end

local requested_mode =
    environment("TANGARA_THEME_MODE")
local requested_accent =
    environment("TANGARA_THEME_ACCENT")

if valid(MODES, requested_mode) then
    mode = requested_mode
end

if valid(ACCENTS, requested_accent) then
    accent = requested_accent
end

local function rebuild()
    for key in pairs(active_palette) do
        active_palette[key] = nil
    end

    for key, value in pairs(MODES[mode]) do
        active_palette[key] = value
    end

    for key, value in pairs(ACCENTS[accent]) do
        active_palette[key] = value
    end

    active_palette.mode = mode
    active_palette.accent_name = accent
    active_palette.focus =
        active_palette.accent
    active_palette.badge =
        active_palette.accent_muted
    active_palette.badge_text =
        active_palette.focus_text
    active_palette.art_background =
        active_palette.surface
    active_palette.modal =
        active_palette.surface
    active_palette.modal_border =
        active_palette.divider
end

function M.current()
    return active_palette
end

function M.color(name)
    return active_palette[name]
end

function M.mode()
    return mode
end

function M.accent()
    return accent
end

function M.modes()
    return {"dark", "light"}
end

function M.accents()
    return {
        "blue",
        "violet",
        "green",
        "amber",
        "rose",
    }
end

function M.set_mode(value)
    if not valid(MODES, value) then
        return false, "unknown theme mode"
    end

    mode = value
    rebuild()
    return true
end

function M.set_accent(value)
    if not valid(ACCENTS, value) then
        return false, "unknown accent preset"
    end

    accent = value
    rebuild()
    return true
end

function M.configure(options)
    options = options or {}

    if options.mode then
        local ok, err = M.set_mode(options.mode)

        if not ok then
            return false, err
        end
    end

    if options.accent then
        local ok, err =
            M.set_accent(options.accent)

        if not ok then
            return false, err
        end
    end

    return true
end

rebuild()

return M
