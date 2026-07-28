package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
require("mocks").install(lvgl)

local marquee = require("jellyfin_marquee")

local root = lvgl.Object()
root:set {
    x = 0,
    y = 0,
    w = 160,
    h = 128,
    pad_all = 0,
    border_width = 0,
    scrollbar_mode = lvgl.SCROLLBAR_MODE.OFF,
}

assert(
    type(root.update_layout) == "function",
    "Luavgl Object:update_layout binding is unavailable"
)

local title = marquee.create(
    root,
    {
        x = 6,
        y = 83,
        w = 148,
        h = 12,
        label_y = 0,
        text = "",
        align = "center",
        autostart = false,
    }
)

local artist = marquee.create(
    root,
    {
        x = 6,
        y = 95,
        w = 148,
        h = 12,
        label_y = 0,
        text = "",
        align = "center",
        autostart = false,
    }
)

local replacements = {
    {
        title = "I Thought About Killing You",
        artist = "Kanye West",
    },
    {
        title = "Unity",
        artist = "Frank Ocean",
    },
    {
        title = "A deliberately very long title that must overflow the fixed label view",
        artist = "A deliberately very long artist name that must overflow too",
    },
    {
        title = "Lilacs",
        artist = "Pastel Ghost",
    },
    {
        title = "ASTROTHUNDER",
        artist = "Travis Scott",
    },
}

local index = 0

local stable_generation = title.generation
title:set(replacements[1].title)
local replacement_generation = title.generation
title:set(replacements[1].title)
assert(
    title.generation == replacement_generation and
        replacement_generation > stable_generation,
    "setting identical marquee text should not restart measurement"
)
title:set("")

local stable_width_generation = artist.generation
artist:set_width(148)
assert(
    artist.generation == stable_width_generation,
    "setting an unchanged marquee width should not restart measurement"
)

local function assert_centered_or_left(controller, text, role)
    local view = controller.view:get_coords()
    local label = controller.label:get_coords()

    local view_width = view.x2 - view.x1 + 1
    local label_width = label.x2 - label.x1 + 1
    local relative_x = label.x1 - view.x1

    assert(
        label.y1 >= view.y1 and
            label.y2 <= view.y2,
        string.format(
            "%s replacement %q extends outside its clipping view: label=%d..%d view=%d..%d",
            role,
            text,
            label.y1,
            label.y2,
            view.y1,
            view.y2
        )
    )

    local expected_x = 0
    if label_width <= view_width then
        expected_x = math.max(
            0,
            math.floor(
                (view_width - label_width) / 2
            )
        )
    end

    assert(
        math.abs(relative_x - expected_x) <= 1,
        string.format(
            "%s replacement %q used stale layout: x=%d expected=%d label_width=%d view_width=%d",
            role,
            text,
            relative_x,
            expected_x,
            label_width,
            view_width
        )
    )
end

local function check_next()
    index = index + 1

    if index > #replacements then
        print(
            "Title and artist replacements stay centered and preserve descenders"
        )
        os.exit(0)
    end

    local values = replacements[index]
    title:set(values.title)
    artist:set(values.artist)

    lvgl.Timer {
        period = 80,
        repeat_count = 1,
        cb = function()
            local ok, failure = pcall(
                function()
                    assert_centered_or_left(
                        title,
                        values.title,
                        "title"
                    )
                    assert_centered_or_left(
                        artist,
                        values.artist,
                        "artist"
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

            check_next()
        end,
    }
end

check_next()
