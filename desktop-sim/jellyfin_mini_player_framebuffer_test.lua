package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
local backstack = require("firmware_backstack")
local metrics = require("sim_metrics")
local native_img_data = lvgl.ImgData
local decoded = {}

lvgl.ImgData = function(path)
    if type(path) == "string" and
        path:match("^/desktop%-sim/") then
        if not decoded[path] then
            decoded[path] = native_img_data(path)
        end

        return decoded[path]
    end

    return path
end

require("mocks").install(lvgl)

package.loaded["backstack"] = backstack
package.preload["backstack"] = function()
    return backstack
end

package.loaded["jellyfin_playback_session"] = {
    current = function()
        return {
            id = 17,
            track_id =
                "ce1c15cfac374bfa95508510ec994096",
            queue_index = 5,
            position = 45,
            paused = false,
            metadata = {
                title = "Star Wars Samba",
                artist = "Masayoshi Takanaka",
                duration = 225,
            },
            artwork = {
                foreground =
                    "/desktop-sim/sd/jellyfin-library-ui/" ..
                    ".tangara-artwork/albums/" ..
                    "3d698c5103e705965c5965d8ba385a1d-sq66.png",
            },
        }
    end,
    open_now_playing = function()
        return true
    end,
}

local mini_player = require("jellyfin_mini_player")
local screen = require("screen")

local Owner = screen:new {
    create_ui = function(self)
        self.root = lvgl.Object(nil, {
            x = 0,
            y = 0,
            w = 160,
            h = 128,
            pad_all = 0,
            border_width = 0,
            bg_color = 0,
            bg_opa = 255,
        })
        self.list = lvgl.List(self.root, {
            x = 2,
            y = 28,
            w = 156,
            h = 100,
        })
        self.ui_active = true
        mini_player.attach(self)
    end,
    on_show = function(self)
        self.ui_active = true
        self.mini_player:on_show()
    end,
    on_hide = function(self)
        self.ui_active = false
        self.mini_player:on_hide()
    end,
}

local function settle(passes)
    for _ = 1, passes or 4 do
        metrics.wait_ms(15)
        backstack.flush(1)
    end
end

local owner = Owner:new()
backstack.push(owner)
settle(6)

local state = owner.mini_player:state()
local geometry =
    metrics.image_geometry(
        owner.mini_player.cover
    )
local chevron_coordinates =
    owner.mini_player.state_icon:
        get_coords()

assert(state.visible)
assert(state.list_height == 72)
assert(state.root_coordinates.x1 == 2)
assert(state.root_coordinates.x2 == 157)
assert(state.root_coordinates.y1 == 101)
assert(state.root_coordinates.y2 == 125)
assert(state.cover_frame_coordinates.x1 >=
    state.root_coordinates.x1)
assert(state.cover_frame_coordinates.y1 >=
    state.root_coordinates.y1)
assert(state.cover_frame_coordinates.y2 <=
    state.root_coordinates.y2)
assert(state.title_coordinates.y2 <
    state.artist_coordinates.y2)
assert(state.artist_coordinates.y2 <
    state.root_coordinates.y2)
assert(state.affordance_coordinates.x2 <=
    state.root_coordinates.x2)
assert(state.affordance_coordinates.y2 <=
    state.root_coordinates.y2)
assert(state.affordance_coordinates.x2 -
    state.affordance_coordinates.x1 + 1 == 15)
assert(state.title_coordinates.x2 <
    state.affordance_coordinates.x1)
assert(state.title_coordinates.x2 -
    state.title_coordinates.x1 + 1 == 112)
assert(state.artist_coordinates.x2 -
    state.artist_coordinates.x1 + 1 == 112)
assert(geometry.decoded_width == 67)
assert(geometry.decoded_height == 66)
assert(geometry.clip_x1 >=
    state.cover_frame_coordinates.x1)
assert(geometry.clip_y1 >=
    state.cover_frame_coordinates.y1)
assert(geometry.clip_x2 <=
    state.cover_frame_coordinates.x2)
assert(geometry.clip_y2 <=
    state.cover_frame_coordinates.y2)
assert(chevron_coordinates.x2 -
    chevron_coordinates.x1 + 1 == 11)
assert(chevron_coordinates.y2 -
    chevron_coordinates.y1 + 1 == 11)
assert(chevron_coordinates.x1 >=
    state.affordance_coordinates.x1)
assert(chevron_coordinates.x2 <=
    state.affordance_coordinates.x2)

local dummy_focus = owner.root:Button {
    x = 0,
    y = 0,
    w = 1,
    h = 1,
    border_width = 0,
    bg_opa = 0,
}
lvgl.group.get_default():add_obj(
    dummy_focus
)
lvgl.group.focus_obj(dummy_focus)
settle(2)
local unfocused = metrics.framebuffer()

lvgl.group.focus_obj(owner.mini_player.object)
settle(2)
local focused = metrics.framebuffer()
assert(#metrics.missing_glyphs() == 0,
    "mini-player introduced a missing control glyph")

local function region_signature(frame, area)
    local value = 0

    for y = area.y1, area.y2 do
        for x = area.x1, area.x2 do
            local offset =
                y * frame.stride + x * 2 + 1
            local low, high =
                frame.pixels:byte(
                    offset,
                    offset + 1
                )
            value = (value +
                (low or 0) +
                (high or 0) * 257) %
                4294967291
        end
    end

    return value
end

assert(region_signature(
    unfocused,
    state.root_coordinates
) ~= region_signature(
    focused,
    state.root_coordinates
), "whole-bar focus outline did not change the framebuffer")

local affordance_colors = {}
for y = state.affordance_coordinates.y1,
    state.affordance_coordinates.y2 do
    for x = state.affordance_coordinates.x1,
        state.affordance_coordinates.x2 do
        local offset =
            y * focused.stride + x * 2 + 1
        affordance_colors[
            focused.pixels:sub(offset, offset + 1)
        ] = true
    end
end
local affordance_color_count = 0
for _ in pairs(affordance_colors) do
    affordance_color_count =
        affordance_color_count + 1
end
assert(affordance_color_count >= 2,
    "right affordance is blank; chevron was not painted")

local frame = focused
local colors = {}

for y = state.root_coordinates.y1,
    state.root_coordinates.y2 do
    for x = state.root_coordinates.x1,
        state.root_coordinates.x2 do
        local offset =
            y * frame.stride + x * 2 + 1
        colors[
            frame.pixels:sub(
                offset,
                offset + 1
            )
        ] = true
    end
end

local color_count = 0

for _ in pairs(colors) do
    color_count = color_count + 1
end

assert(color_count > 4,
    "mini-player framebuffer was not painted")

print(string.format(
    "Mini-player framebuffer passed: bar=(%d,%d)-(%d,%d) " ..
        "cover=%dx%d colors=%d list_height=%d",
    state.root_coordinates.x1,
    state.root_coordinates.y1,
    state.root_coordinates.x2,
    state.root_coordinates.y2,
    geometry.decoded_width,
    geometry.decoded_height,
    color_count,
    state.list_height
))
os.exit(0)
