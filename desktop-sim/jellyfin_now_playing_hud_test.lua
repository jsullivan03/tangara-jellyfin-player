package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")

lvgl.ImgData = function(path)
    return path
end

require("mocks").install(lvgl)

local premium =
    require("premium_now_playing_screen")
local volume_hud = require("volume_hud")
local controls = require("controls")

local screen = premium.create {
    title = "Test Track",
    artist = "Test Artist",
    progress = 0.5,
    elapsed = "1:00",
    remaining = "1:00",
    paused = false,
}

screen:refresh_media_layout()

local initial_text =
    screen:media_text_layout_state()

local function assert_centered(
    state,
    role
)
    local expected_x = 0

    if state.text_width <=
            state.view_width then
        expected_x =
            math.max(
                0,
                math.floor(
                    (
                        state.view_width -
                        state.text_width
                    ) / 2
                )
            )
    end

    assert(
        state.measured and
            math.abs(
                state.relative_x -
                expected_x
            ) <= 1,
        string.format(
            "initial %s was not centered synchronously: x=%d expected=%d",
            role,
            state.relative_x,
            expected_x
        )
    )
end

assert_centered(
    initial_text.title,
    "title"
)
assert_centered(
    initial_text.artist,
    "artist"
)
assert(
    initial_text.title.view_height >= 18 and
        initial_text.artist.view_height >= 18 and
        initial_text.title.bottom_room >= 0 and
        initial_text.artist.bottom_room >= 0,
    "Now Playing marquee viewports clipped title or artist descenders"
)

local playing = screen:layout_state()

assert(
    playing.paused == false and
        playing.elapsed_y == 111 and
        playing.remaining_y == 111 and
        playing.progress_y == 124 and
        playing.pause_icon_visible == false,
    "playing layout is incorrect"
)

screen:update {paused = true}

local paused = screen:layout_state()

assert(
    paused.paused == true and
        paused.elapsed_y == 116 and
        paused.remaining_y == 116 and
        paused.progress_y == 128 and
        paused.pause_icon_visible == false and
        paused.pause_icon_pending == true and
        paused.pause_icon_delay_ms == 105,
    "paused layout or delayed icon state is incorrect"
)

local zero = volume_hud.geometry(0)
local half = volume_hud.geometry(50)
local full = volume_hud.geometry(100)

assert(
    zero.fill_height == 0 and
        zero.fill_opacity == 0,
    "zero-volume HUD is incorrect"
)
assert(
    half.fill_height == 26 and
        half.fill_y == 29,
    "half-volume HUD is incorrect"
)
assert(
    full.fill_height == 52 and
        full.fill_y == 3,
    "full-volume HUD is incorrect"
)
assert(
    zero.x == 3 and
        zero.width == 7 and
        zero.height == 58,
    "volume HUD is not a slim left-side capsule"
)

controls.lock_switch:set(false)
assert(
    volume_hud.show(50) == true,
    "unlocked volume HUD did not show"
)

controls.lock_switch:set(true)
assert(
    volume_hud.show(50) == false,
    "locked volume HUD should remain hidden"
)

screen:update {
    background = "background-next",
    cover = "cover-next",
    title = "Next Track",
    artist = "Next Artist",
}

local media = screen:media_state()

assert(
    media.background == "background-next" and
        media.cover == "cover-next" and
        media.title == "Next Track" and
        media.artist == "Next Artist" and
        media.cover_x == 44 and
        media.cover_y == 19 and
        media.cover_zoom == 256 and
        media.title_x == 6 and
        media.title_y == 90 and
        media.artist_x == 6 and
        media.artist_y == 100 and
        media.background_x == 0 and
        media.background_y == 0 and
        media.background_dimmer_opa ==
            118,
    "track replacement did not preserve the fixed Now Playing layout"
)

screen:update {
    title = "ザ・ワード II (The Word II)",
    artist = "Sekito Shigeo (関戸剛)",
}

media = screen:media_state()
assert(
    media.title ==
        "ザ・ワード II (The Word II)" and
        media.artist ==
            "Sekito Shigeo (関戸剛)",
    "Now Playing changed non-Latin metadata instead of preserving the original text"
)

lvgl.Timer {
    period = 130,
    repeat_count = 1,
    cb = function()
        local ok, failure = pcall(
            function()
                local delayed =
                    screen:layout_state()

                assert(
                    delayed.paused == true and
                        delayed.pause_icon_visible == true and
                        delayed.pause_icon_pending == false,
                    "pause icon did not appear after its short delay"
                )

                screen:update {
                    paused = false,
                }

                local resumed =
                    screen:layout_state()

                assert(
                    resumed.paused == false and
                        resumed.elapsed_y == 111 and
                        resumed.remaining_y == 111 and
                        resumed.progress_y == 124 and
                        resumed.pause_icon_visible == false and
                        resumed.pause_icon_pending == false,
                    "resumed layout is incorrect"
                )
            end
        )

        if not ok then
            io.stderr:write(
                tostring(failure),
                "\n"
            )
            os.exit(1)
        end

        print(
            "Now Playing initial text centering, delayed pause icon, and side volume HUD passed"
        )
        os.exit(0)
    end,
}
