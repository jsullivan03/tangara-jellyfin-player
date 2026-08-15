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
local lotion = "Lotion"
local short_artist = "Deftones"
local cover =
    "//lua/img/cover_placeholder.png"

for _, name in ipairs({
    "jellyfin_marquee",
    "premium_now_playing_screen",
}) do
    package.loaded[name] = nil
end

local premium =
    require("premium_now_playing_screen")

local function assert_title_centered_static(
    screen,
    label
)
    local state =
        screen:media_marquee_state()
    local layout =
        screen:media_text_layout_state()
    local title = layout.title
    local expected_x = math.max(
        0,
        math.floor(
            (
                title.view_width -
                title.text_width
            ) / 2
        )
    )

    assert(
        state.title.overflow == 0,
        label .. " overflow"
    )
    assert(
        not state.title.uses_native_circular,
        label .. " native"
    )
    assert(
        not state.title.has_anim,
        label .. " anim"
    )
    assert(
        math.abs(
            title.relative_x - expected_x
        ) <= 1,
        string.format(
            "%s first-frame geometry: rel_x=%s expected=%s tw=%s vw=%s short_x=%s current helper short_x=%s",
            label,
            tostring(title.relative_x),
            tostring(expected_x),
            tostring(title.text_width),
            tostring(title.view_width),
            tostring(state.title.short_x),
            tostring(state.title.short_x)
        )
    )
    assert(
        title.text_width <=
            title.view_width,
        label .. " expanded width"
    )
end

local function assert_title_marquees(
    screen,
    label
)
    local state =
        screen:media_marquee_state()
    assert(
        state.title.overflow > 0,
        label .. " overflow"
    )
    assert(
        state.title.active,
        label .. " active"
    )
    assert(
        state.title.uses_native_circular or
            state.title.has_anim,
        label .. " scrolling"
    )
    assert(
        state.title.short_x == 0,
        label .. " short_x must be 0 while scrolling"
    )
end

local screen = premium.create {
    title = long_title,
    artist = short_artist,
    cover = cover,
    background = cover,
    progress = 0.2,
    elapsed = "0:40",
    remaining = "-2:20",
    paused = false,
}

screen:refresh_media_layout()
screen:resume()
assert_title_marquees(screen, "initial long")

local artist_layout =
    screen:media_text_layout_state().artist
local artist_expected = math.max(
    0,
    math.floor(
        (
            artist_layout.view_width -
            artist_layout.text_width
        ) / 2
    )
)
assert(
    math.abs(
        artist_layout.relative_x -
            artist_expected
    ) <= 1,
    "artist must stay independently centered"
)

-- Long → short "Lotion" must be centered on the first rendered frame.
screen:update {
    title = lotion,
    artist = short_artist,
}
assert_title_centered_static(
    screen,
    "Lotion after long"
)

local artist_after =
    screen:media_text_layout_state().artist
assert(
    math.abs(
        artist_after.relative_x -
            artist_expected
    ) <= 1,
    "title reset must not move artist"
)

-- Short → long starts a fresh marquee at baseline (x helper short_x 0).
screen:update {
    title = long_title,
    artist = short_artist,
}
assert_title_marquees(
    screen,
    "long after Lotion"
)

local active_anims = 0
if screen:media_marquee_state()
    .title.has_anim then
    active_anims = active_anims + 1
end
if screen:media_marquee_state()
    .title.uses_native_circular then
    active_anims = active_anims + 1
end
assert(
    active_anims == 1,
    "exactly one title scroll mechanism"
)

for cycle = 1, 4 do
    screen:update {
        title = long_title,
        artist = short_artist,
    }
    assert_title_marquees(
        screen,
        "cycle " .. cycle .. " long"
    )
    screen:update {
        title = lotion,
        artist = short_artist,
    }
    assert_title_centered_static(
        screen,
        "cycle " .. cycle .. " Lotion"
    )
end

-- Suspend/resume must not leave Lotion left-aligned.
screen:update {
    title = long_title,
    artist = short_artist,
}
screen:suspend()
screen:resume()
assert_title_marquees(
    screen,
    "resume long"
)
screen:update {
    title = lotion,
    artist = short_artist,
}
assert_title_centered_static(
    screen,
    "Lotion after resume path"
)

screen:retire()
local retired =
    screen:media_marquee_state()
assert(
    retired.title.destroyed and
        retired.artist.destroyed and
        not retired.title.has_anim and
        not retired.artist.has_anim,
    "retire left stale animation"
)

print(
    "Now Playing Lotion title reset / first-frame geometry passed"
)
os.exit(0)
