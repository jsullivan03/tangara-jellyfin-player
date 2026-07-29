package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")

lvgl.ImgData = function(path)
    return path
end

local simulator =
    require("mocks").install(lvgl)

package.loaded["backstack"] =
    simulator.backstack

package.loaded["sync_config"] = {
    status = function()
        return {
            connected = false,
        }
    end,
}

package.loaded["sync_runtime"] = {
    last_library_result = function()
        return nil
    end,
    last_result = function()
        return nil
    end,
}

local theme = require("jellyfin_theme")

assert(theme.set_mode("dark"))
assert(theme.set_accent("blue"))

local dark = {}

for key, value in pairs(
    theme.current()
) do
    dark[key] = value
end

assert(dark.background == "#07080C")
assert(dark.foreground == "#FFFFFF")
assert(dark.accent == "#4D8DFF")
assert(dark.placeholder_cover == "#173A5E")

assert(theme.set_mode("light"))

local light = theme.current()

assert(light.background ~= dark.background)
assert(light.foreground ~= dark.foreground)
assert(light.foreground == "#17191F")

package.loaded["jellyfin_list_ui"] = nil
local light_list_ui =
    require("jellyfin_list_ui")

assert(
    light_list_ui.colors.background ==
        light.background
)
assert(
    light_list_ui.colors.primary ==
        light.foreground
)
assert(
    light_list_ui.colors.selected ==
        light.selected_surface
)

local expected_accents = {
    blue = true,
    violet = true,
    green = true,
    amber = true,
    rose = true,
}

for _, name in ipairs(theme.accents()) do
    assert(expected_accents[name])
    expected_accents[name] = nil
    assert(theme.set_accent(name))
    assert(theme.current().accent_name == name)
end

assert(next(expected_accents) == nil)
assert(not theme.set_mode("sepia"))
assert(not theme.set_accent("orange"))

theme.configure {
    mode = "dark",
    accent = "blue",
}

package.loaded["jellyfin_list_ui"] = nil
package.loaded["jellyfin_home"] = nil

local home_module =
    require("jellyfin_home")
local home =
    home_module.Home:new()

simulator.backstack.reset(home)

local expected_rows = {
    "home:local",
    "home:sync",
    "home:storage",
    "home:settings",
}

assert(#home.rows == #expected_rows)

for index, selection_id in ipairs(
    expected_rows
) do
    assert(
        home.rows[index].selection_id ==
            selection_id
    )
end

local sync_screen =
    home_module.Sync:new()
simulator.backstack.push(sync_screen)
assert(
    sync_screen.header_marquee.text ==
        "Sync"
)
simulator.backstack.pop()

local storage_screen =
    home_module.Storage:new()
simulator.backstack.push(storage_screen)
assert(
    storage_screen.header_marquee.text ==
        "Storage"
)
simulator.backstack.pop()

local settings =
    home_module.Settings:new()
simulator.backstack.push(settings)

assert(settings.header_marquee.text == "Settings")
assert(settings.mode_row.label.text == "Mode")
assert(settings.mode_row.swatch ~= nil)
assert(settings.accent_row.label.text == "Accent")
assert(settings.accent_row.swatch ~= nil)

settings.mode_row.on_click()
settings.accent_row.on_click()

assert(theme.mode() == "light")
assert(theme.accent() == "violet")

local refreshed_settings =
    home_module.Settings:new()
refreshed_settings:create_ui()

assert(
    refreshed_settings.mode_row.label.text ==
        "Mode"
)
assert(refreshed_settings.mode_row.swatch ~= nil)
assert(
    refreshed_settings.accent_row.label.text ==
        "Accent"
)
assert(refreshed_settings.accent_row.swatch ~= nil)

print(
    "Top-level navigation and semantic theme presets passed"
)
os.exit(0)
