package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")

lvgl.ImgData = function(path)
    return path
end

require("mocks").install(lvgl)

package.loaded["jellyfin_navigation"] = {
    set_back = function()
    end,
    clear_back = function()
    end,
}

local queue = require("queue")
local source_tracks = {}
local source_items = {}

for index = 1, 20 do
    source_tracks[index] = {
        id = "track-" .. tostring(index),
        title = "Track " .. tostring(index),
        artist = "Artist " .. tostring(index),
        artwork = {
            cover =
                "//lua/img/cover_placeholder.png",
        },
    }
    source_items[index] = {
        jellyfin_id =
            source_tracks[index].id,
        artwork = {
            thumbnail =
                "item-cover-" ..
                tostring(index),
        },
    }
end

source_tracks[9].title =
    "ザ・ワード II (The Word II)"
source_tracks[9].artist =
    "Sekito Shigeo (関戸剛)"

local shuffled_order = {
    9, 4, 15, 2, 20, 7, 1, 12, 5, 18,
    3, 14, 6, 16, 8, 10, 11, 13, 17, 19,
}
local current_source = 9
local shuffle_cursor = 1

local function current_order()
    local order = {}

    if queue.random:get() then
        for _, source_position in ipairs(
            shuffled_order
        ) do
            table.insert(
                order,
                source_position
            )
        end
    else
        for index = 1,
            #source_tracks do
            table.insert(order, index)
        end
    end

    return order
end

local function queue_view()
    local tracks = {}
    local items = {}
    local positions =
        current_order()

    for _, source_position in ipairs(
        positions
    ) do
        table.insert(
            tracks,
            source_tracks[source_position]
        )
        table.insert(
            items,
            source_items[source_position]
        )
    end

    local display_position = 1

    for index, source_position in ipairs(
        positions
    ) do
        if source_position == current_source then
            display_position = index
            break
        end
    end

    return {
        tracks = tracks,
        items = items,
        source_positions = positions,
        position = display_position,
        source_position = current_source,
        size = #tracks,
        total_size = #source_tracks,
        generation = 7,
        shuffle = queue.random:get(),
    }
end

package.loaded["jellyfin_local_index"] = {
    load = function()
        local tracks = {}

        for index = 1, #source_tracks do
            tracks[index] = {
                id = "track-" .. tostring(index),
                artwork = {
                    thumbnail =
                        "/desktop-sim/sd/.tangara-artwork/track-" ..
                        tostring(index) .. ".png",
                },
            }
        end

        return {tracks = tracks}
    end,
}

package.loaded["jellyfin_playback"] = {
    queue_view = queue_view,
    sync_position = function(position)
        current_source =
            math.max(
                1,
                math.min(
                    #source_tracks,
                    tonumber(position) or 1
                )
            )

        if queue.random:get() then
            for index, source_position in ipairs(
                shuffled_order
            ) do
                if source_position ==
                        current_source then
                    shuffle_cursor = index
                    break
                end
            end
        end
    end,
}

queue.position:set(current_source)
queue.random:set(true)

for _, name in ipairs({
    "jellyfin_marquee",
    "jellyfin_list_ui",
    "jellyfin_virtual_list",
    "jellyfin_queue",
}) do
    package.loaded[name] = nil
end

local QueueScreen =
    require("jellyfin_queue")
local page = QueueScreen:new()

page:create_ui()
page:on_show()

local state = page.queue_page_state()

assert(
    state.count == 20 and
        state.pool == 7,
    "Queue page did not virtualize the shuffled queue through seven reusable rows"
)
assert(
    state.current == 1 and
        state.selected == 1 and
        state.selected_id ==
            "queue:7:9" and
        state.selected_queue_index == 9,
    "Queue page did not focus the first item in the actual playback order"
)
assert(
    state.selected_detail ==
        "Sekito Shigeo (関戸剛)" and
        state.current_visualizer == true,
    "Queue page did not replace the active cover with the visualizer or preserve artist metadata"
)
assert(
    state.selected_artwork ==
        "/desktop-sim/sd/.tangara-artwork/track-9.png",
    "Queue page did not prefer the normalized local-index artwork path"
)
assert(
    page.header_marquee.text ==
        "Queue (Shuffle)",
    "Queue page did not expose the active shuffle state"
)

-- Browse a future item, then advance playback. The viewed queue should retain
-- the completed entry because Previous can revisit it, move the visualizer to
-- the next shuffled item, and preserve the user's selected future occurrence.
page.virtual_queue_list:focus_index(4)
queue.position:set(4)

state = page.queue_page_state()
assert(
    state.current == 2 and
        state.count == 20 and
        state.selected == 4 and
        state.selected_id ==
            "queue:7:2" and
        state.selected_queue_index == 2,
    "Queue advancement removed history or changed the user's future-track selection"
)

local current_model =
    assert(
        page.virtual_queue_list
            :model_for_index(2)
    )
assert(
    current_model.title.text ==
        "Track 4" and
        current_model.detail.text ==
            "Artist 4" and
        current_model.queue_visualizer_active == true,
    "Queue advancement did not move the visualizer to the next shuffled item"
)

-- Click a shuffled-future row. Playback must jump by source queue_index, not
-- display_index, and must resume even if playback was paused.
local playback = require("playback")
playback.playing:set(false)
page.virtual_queue_list:focus_index(3)

local clicked =
    assert(page.virtual_queue_list:selected_model())
assert(
    page.queue_entries[3].queue_index == 15,
    "Queue click fixture expected display row 3 to map to source index 15"
)
clicked.on_click()

state = page.queue_page_state()
assert(
    current_source == 15 and
        state.current == 3 and
        state.selected_queue_index == 15 and
        playback.playing:get() == true and
        state.current_visualizer == true,
    "Queue row click did not jump playback by source queue_index and resume"
)

queue.random:set(false)
assert(
    page.header_marquee.text == "Queue",
    "Queue page did not refresh after shuffle was disabled"
)

page:on_hide()

print(
    "Queue page shows playback order, local artwork, stable virtual selection, and click-to-play jumps"
)
os.exit(0)
