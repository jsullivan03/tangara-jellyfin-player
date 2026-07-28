local file = assert(
    io.open(
        "lua/jellyfin_now_playing.lua",
        "rb"
    )
)
local source = file:read("*a")
file:close()

local start_at = assert(
    source:find(
        "local function add_sheet_button",
        1,
        true
    )
)
local end_at = assert(
    source:find(
        "local function remove_from_group",
        start_at,
        true
    )
)
local button_source =
    source:sub(start_at, end_at - 1)

assert(
    not source:find(
        "local sheet_button_focused_style",
        1,
        true
    ) and
        not button_source:find(
            "button:add_style(",
            1,
            true
        ),
    "Now Playing still derives menu color from potentially stale LVGL focus-state styles"
)

assert(
    button_source:find(
        "lvgl.EVENT.FOCUSED",
        1,
        true
    ) and
        button_source:find(
            "on_focus(button)",
            1,
            true
        ) and
        not button_source:find(
            "lvgl.EVENT.DEFOCUSED",
            1,
            true
        ),
    "Now Playing does not route focus through one exclusive menu-highlight callback"
)

assert(
    source:find(
        "local function refresh_sheet_highlight",
        1,
        true
    ) and
        source:find(
            "button:clear_state(",
            1,
            true
        ) and
        source:find(
            '"#72AFFF" or',
            1,
            true
        ) and
        source:find(
            '"#FFFFFF"',
            1,
            true
        ),
    "Now Playing does not normalize every menu row whenever focus changes"
)

print(
    "Now Playing sheet highlight is normalized exclusively on each focus event"
)
os.exit(0)
