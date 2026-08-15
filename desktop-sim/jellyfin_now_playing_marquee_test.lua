package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")

lvgl.ImgData = function(path)
    return path
end

require("mocks").install(lvgl)

local long_title =
    "Be Quiet and Drive (Far Away)"
local short_title = "Lotion"
local long_artist =
    "A deliberately very long artist name that must overflow"
local short_artist = "Pastel Ghost"

for _, name in ipairs({
    "jellyfin_marquee",
    "premium_now_playing_screen",
}) do
    package.loaded[name] = nil
end

local marquee = require("jellyfin_marquee")
local premium =
    require("premium_now_playing_screen")

local function assert_scrolling(state, label)
    assert(state.measured, label .. " measured")
    assert(state.overflow > 0, label .. " overflow")
    assert(state.active, label .. " active")
    assert(
        state.uses_native_circular or
            state.has_anim,
        label .. " scrolling"
    )
end

local function assert_static(state, label)
    assert(state.measured, label .. " measured")
    assert(state.overflow == 0, label .. " static")
    assert(
        not state.uses_native_circular,
        label .. " no circular"
    )
    assert(
        not state.has_anim,
        label .. " no anim"
    )
    assert(state.short_x > 0, label .. " centered")
end

local root = lvgl.Object(nil, {
    x = 0,
    y = 0,
    w = 160,
    h = 128,
    pad_all = 0,
    border_width = 0,
})

local solo = marquee.create(root, {
    x = 6,
    y = 90,
    w = 148,
    h = 12,
    label_y = 0,
    text = long_title,
    align = "center",
    autostart = true,
})
solo:refresh(true)
solo:start()
assert_scrolling({
    measured = solo.measured,
    overflow = solo.overflow,
    active = solo.active,
    uses_native_circular =
        solo.uses_native_circular,
    has_anim = solo.anim ~= nil,
    short_x = solo.short_x,
}, "initial long title")

-- Hidden rebind after circular (Now Playing update path).
solo:stop()
solo.view:add_flag(lvgl.FLAG.HIDDEN)
solo:set(long_title .. "!")
solo:refresh(true)
assert(
    solo.overflow > 0,
    "hidden rebind must keep overflow"
)
solo.view:clear_flag(lvgl.FLAG.HIDDEN)
solo:start()
assert_scrolling({
    measured = solo.measured,
    overflow = solo.overflow,
    active = solo.active,
    uses_native_circular =
        solo.uses_native_circular,
    has_anim = solo.anim ~= nil,
    short_x = solo.short_x,
}, "reopened long title")

solo:set(short_title)
solo:refresh(true)
solo:start()
assert_static({
    measured = solo.measured,
    overflow = solo.overflow,
    active = solo.active,
    uses_native_circular =
        solo.uses_native_circular,
    has_anim = solo.anim ~= nil,
    short_x = solo.short_x,
}, "short title")

solo:destroy()
assert(
    solo.destroyed and
        solo.anim == nil and
        not solo.active,
    "destroy left a live animation"
)

local screen = premium.create {
    title = long_title,
    artist = short_artist,
    progress = 0.2,
    elapsed = "0:40",
    remaining = "-2:20",
    paused = false,
}
screen:refresh_media_layout()
screen:resume()

local state = screen:media_marquee_state()
assert_scrolling(state.title, "NP long title")
assert_static(state.artist, "NP short artist")

screen:update {
    title = short_title,
    artist = short_artist,
}
state = screen:media_marquee_state()
assert_static(state.title, "NP short title")
assert_static(state.artist, "NP short artist after")

screen:update {
    title = long_title,
    artist = long_artist,
}
state = screen:media_marquee_state()
assert_scrolling(
    state.title,
    "NP title after track change"
)
assert_scrolling(
    state.artist,
    "NP long artist after track change"
)

screen:suspend()
state = screen:media_marquee_state()
assert(
    not state.title.active and
        not state.artist.active,
    "suspend must stop NP marquees"
)

screen:resume()
screen:refresh_media_layout()
state = screen:media_marquee_state()
assert_scrolling(
    state.title,
    "NP title after reopen"
)
assert_scrolling(
    state.artist,
    "NP artist after reopen"
)

-- Automatic queue advancement style update.
screen:update {
    title = short_title,
    artist = short_artist,
}
screen:update {
    title = long_title,
    artist = short_artist,
}
state = screen:media_marquee_state()
assert_scrolling(
    state.title,
    "NP title after queue advance"
)
assert_static(
    state.artist,
    "NP short artist after queue advance"
)

-- Sync focused-row ownership must not cancel NP marquees.
local sync_row = marquee.create(root, {
    x = 0,
    y = 0,
    w = 120,
    h = 12,
    text =
        "A very long Sync album title that should marquee when focused",
    autostart = true,
})
sync_row:refresh(true)
sync_row:start()
assert_scrolling({
    measured = sync_row.measured,
    overflow = sync_row.overflow,
    active = sync_row.active,
    uses_native_circular =
        sync_row.uses_native_circular,
    has_anim = sync_row.anim ~= nil,
    short_x = sync_row.short_x,
}, "sync focused row")
sync_row:stop()

screen:resume()
screen:refresh_media_layout()
state = screen:media_marquee_state()
assert_scrolling(
    state.title,
    "NP still scrolls after Sync row stop"
)

screen:retire()
state = screen:media_marquee_state()
assert(
    state.title.destroyed and
        state.artist.destroyed and
        not state.title.has_anim and
        not state.artist.has_anim,
    "retire left stale NP animation"
)

print(
    "Now Playing marquee overflow / ownership passed"
)
os.exit(0)
