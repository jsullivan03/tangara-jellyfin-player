package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")

lvgl.ImgData = function(path)
    return path
end

require("mocks").install(lvgl)

local root =
    "desktop-sim/sd/jellyfin-queue-shuffle-mid-session"

os.execute("rm -rf " .. root)
os.execute(
    "mkdir -p " .. root .. "/Music/Shuffle"
)

package.preload["device"] = function()
    return {
        id = function()
            return "shuffle-mid-session-device"
        end,
        storage_root = function()
            return root
        end,
    }
end

package.loaded["device"] = nil

local json_encode = require("json_encode")
local manifest_cache =
    require("sync_manifest_cache")
local queue = require("queue")
local playback = require("playback")
local jellyfin_playback =
    require("jellyfin_playback")
local jellyfin_track_identity =
    require("jellyfin_track_identity")

local function order_keys(view)
    local keys = {}

    for _, track in ipairs(view.tracks) do
        table.insert(
            keys,
            jellyfin_track_identity.key(track)
        )
    end

    return keys
end

local function assert_permutation(
    positions,
    count
)
    assert(
        #positions == count,
        "shuffled order lost or gained tracks"
    )

    local seen = {}

    for _, position in ipairs(positions) do
        assert(
            not seen[position],
            "shuffled order duplicated source " ..
                tostring(position)
        )
        seen[position] = true
    end

    for position = 1, count do
        assert(
            seen[position],
            "shuffled order missing source " ..
                tostring(position)
        )
    end
end

local tracks = {}
local manifest_items = {}

for index = 1, 8 do
    local relative =
        "/Music/Shuffle/track-" ..
        tostring(index) ..
        ".flac"
    local audio = assert(
        io.open(root .. relative, "wb")
    )

    audio:write("shuffle-audio-" .. index)
    audio:close()

    -- Mix numeric-looking string IDs and plain ids to cover identity parity.
    local track_id =
        index <= 4 and
        tostring(1000 + index) or
        ("track-key-" .. tostring(index))

    tracks[index] = {
        id = track_id,
        jellyfin_id = track_id,
        title = "Shuffle Track " .. index,
        artist = "Shuffle Artist",
        album = "Shuffle Album",
    }
    manifest_items[index] = {
        id = track_id,
        jellyfin_id = track_id,
        local_path = relative,
        duration = 120 + index,
    }
end

assert(
    manifest_cache.save(
        json_encode.encode({
            device = {
                id =
                    "shuffle-mid-session-device",
            },
            items = manifest_items,
        })
    )
)

-- Deterministic non-identity Fisher-Yates: always swap with a lower index so
-- the unplayed tail cannot accidentally remain sequential.
local random_calls = 0

math.random = function(low, high)
    random_calls = random_calls + 1

    if not low then
        return 0.25
    end

    if not high then
        return math.max(1, low - 1)
    end

    if high <= low then
        return low
    end

    return math.max(low, high - 1)
end

assert(
    jellyfin_playback.play_queue(
        tracks,
        {source = "shuffle-mid-session"},
        {
            selected_track = tracks[3],
            shuffle = false,
        }
    )
)

local before = assert(
    jellyfin_playback.queue_view()
)
local before_order =
    table.concat(
        before.source_positions,
        ","
    )
local before_generation =
    before.generation
local before_keys = order_keys(before)

assert(
    before.shuffle == false and
        before_order ==
            "1,2,3,4,5,6,7,8",
    "fixture must start unshuffled"
)
assert(
    before.source_position == 3,
    "fixture must start on source position 3"
)

-- Real Shuffle control path used by Now Playing.
assert(
    type(jellyfin_playback.set_shuffle) ==
        "function",
    "playback owner must expose set_shuffle"
)

jellyfin_playback.set_shuffle(true)

assert(
    queue.random:get() == true,
    "Shuffle control did not enable native queue.random"
)

local after = assert(
    jellyfin_playback.queue_view()
)
local after_order =
    table.concat(
        after.source_positions,
        ","
    )
local after_keys = order_keys(after)

assert(
    after.shuffle == true,
    "queue_view did not expose enabled shuffle"
)
assert(
    after.source_position == 3,
    "enabling Shuffle moved the current source position"
)
assert(
    jellyfin_track_identity.key(
        after.tracks[after.position]
    ) ==
        jellyfin_track_identity.key(
            tracks[3]
        ),
    "enabling Shuffle changed the current canonical track"
)
assert(
    after.generation >
        before_generation,
    "enabling Shuffle did not bump queue generation for mounted refresh"
)
assert(
    after_order ~= before_order,
    "enabling Shuffle left the displayed source order unchanged"
)
assert_permutation(
    after.source_positions,
    8
)

-- History before the current track stays fixed; only the unplayed tail moves.
assert(
    after.source_positions[1] == 1 and
        after.source_positions[2] == 2 and
        after.source_positions[3] == 3,
    "enabling Shuffle did not retain played history and current track"
)

local unplayed_before = {
    4,
    5,
    6,
    7,
    8,
}
local unplayed_after = {
    after.source_positions[4],
    after.source_positions[5],
    after.source_positions[6],
    after.source_positions[7],
    after.source_positions[8],
}

assert(
    table.concat(unplayed_after, ",") ~=
        table.concat(unplayed_before, ","),
    "unplayed remainder was not reordered"
)
assert_permutation(
    {
        after.source_positions[1],
        after.source_positions[2],
        after.source_positions[3],
        unplayed_after[1],
        unplayed_after[2],
        unplayed_after[3],
        unplayed_after[4],
        unplayed_after[5],
    },
    8
)

-- Automatic next must follow the displayed shuffled order.
local expected_next =
    after.source_positions[
        after.position + 1
    ]

jellyfin_playback.next()

local advanced = assert(
    jellyfin_playback.queue_view()
)

assert(
    advanced.source_position ==
        expected_next,
    "automatic next did not follow the displayed shuffled order"
)
assert(
    advanced.shuffle == true and
        table.concat(
            advanced.source_positions,
            ","
        ) == after_order,
    "advancing reshuffled or rebuilt source positions"
)

-- Queue click-to-jump uses source queue_index after shuffle.
local jump_display = 6
local jump_source =
    advanced.source_positions[jump_display]

queue.position:set(jump_source)
playback.playing:set(true)
jellyfin_playback.sync_position(
    jump_source
)

local jumped = assert(
    jellyfin_playback.queue_view()
)

assert(
    jumped.source_position ==
        jump_source and
        jumped.position == jump_display,
    "queue click-to-jump lost the shuffled source mapping"
)

local playing_before_disable =
    jumped.source_position
local generation_before_disable =
    jumped.generation

jellyfin_playback.set_shuffle(false)

local disabled = assert(
    jellyfin_playback.queue_view()
)

assert(
    queue.random:get() == false and
        disabled.shuffle == false,
    "disabling Shuffle did not clear shuffle state"
)
assert(
    disabled.source_position ==
        playing_before_disable,
    "disabling Shuffle moved the current track"
)
assert(
    table.concat(
        disabled.source_positions,
        ","
    ) == "1,2,3,4,5,6,7,8",
    "disabling Shuffle did not restore sequential display order"
)
assert(
    disabled.generation >
        generation_before_disable,
    "disabling Shuffle did not bump queue generation"
)

-- Canonical key parity: numeric-looking and string IDs resolve identically.
assert(
    jellyfin_track_identity.key(
        tracks[1]
    ) ==
        jellyfin_track_identity.key(
            "1001"
        ) and
        jellyfin_track_identity.key(
            tracks[1]
        ) ==
            jellyfin_track_identity.key(
                {id = "id:1001"}
            ),
    "canonical track keys must treat bare and prefixed IDs as identical"
)
assert(
    #before_keys == 8 and
        #after_keys == 8,
    "shuffle changed the number of displayed canonical keys"
)

-- Repeated toggles must not accumulate duplicate rows or stale mappings.
for _ = 1, 3 do
    jellyfin_playback.set_shuffle(true)
    local shuffled = assert(
        jellyfin_playback.queue_view()
    )
    assert_permutation(
        shuffled.source_positions,
        8
    )
    assert(
        shuffled.source_position ==
            playing_before_disable,
        "repeated Shuffle enable moved the current track"
    )

    jellyfin_playback.set_shuffle(false)
    local sequential = assert(
        jellyfin_playback.queue_view()
    )
    assert(
        table.concat(
            sequential.source_positions,
            ","
        ) == "1,2,3,4,5,6,7,8",
        "repeated Shuffle disable drifted from sequential order"
    )
    assert_permutation(
        sequential.source_positions,
        8
    )
end

-- Mounted Queue rows must rebind when generation changes.
package.loaded["jellyfin_navigation"] = {
    set_back = function()
    end,
    clear_back = function()
    end,
}

assert(
    jellyfin_playback.play_queue(
        tracks,
        {source = "shuffle-mounted"},
        {
            selected_track = tracks[2],
            shuffle = false,
        }
    )
)

local QueueScreen =
    require("jellyfin_queue")
local page = QueueScreen:new()

page:create_ui()

local mounted_before =
    page.queue_page_state()
local titles_before = {}

for index, entry in ipairs(
    page.queue_entries
) do
    titles_before[index] = entry.title
end

assert(
    table.concat(titles_before, ",") ==
        "Shuffle Track 1,Shuffle Track 2,Shuffle Track 3,Shuffle Track 4,Shuffle Track 5,Shuffle Track 6,Shuffle Track 7,Shuffle Track 8",
    "mounted Queue fixture was not sequential"
)

jellyfin_playback.set_shuffle(true)

local mounted_after =
    page.queue_page_state()
local titles_after = {}

for index, entry in ipairs(
    page.queue_entries
) do
    titles_after[index] = entry.title
end

local view = assert(
    jellyfin_playback.queue_view()
)

assert(
    mounted_after.count == 8,
    "mounted Queue gained or lost rows after Shuffle"
)
assert(
    table.concat(titles_after, ",") ~=
        table.concat(titles_before, ","),
    "mounted Queue rows did not refresh to the shuffled order"
)
assert(
    page.queue_generation ==
        view.generation,
    "mounted Queue generation did not track the shuffled view"
)
assert(
    page.queue_entries[view.position]
        .queue_index ==
        view.source_position,
    "mounted current row lost its source queue_index after Shuffle"
)

print(
    "Mid-session Shuffle permutes unplayed tracks, refreshes Queue, and keeps jump/next aligned"
)
print(
    "deterministic_before=" ..
        before_order
)
print(
    "deterministic_after=" ..
        after_order
)
os.exit(0)
