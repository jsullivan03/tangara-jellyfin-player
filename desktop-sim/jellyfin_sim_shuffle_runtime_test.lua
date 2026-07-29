package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
require("mocks").install(lvgl)

local queue = require("queue")

local playlist_path =
    "desktop-sim/sd/shuffle-runtime.playlist"
local file = assert(
    io.open(playlist_path, "wb")
)
file:write(
    "/Music/A/01.mp3\n",
    "/Music/A/02.mp3\n",
    "/Music/A/03.mp3\n",
    "/Music/A/04.mp3\n"
)
file:close()

local original_random = math.random

-- Force a predictable Fisher-Yates result so this test verifies shuffled
-- navigation rather than relying on probability.
math.random = function(low)
    return low or 0
end

local ok, failure = xpcall(
    function()
        queue.random:set(true)
        queue.open_playlist(
            "/shuffle-runtime.playlist"
        )

        assert(
            queue.position:get() == 2,
            "Shuffle All did not randomize the initial simulator queue position"
        )
        assert(
            table.concat(
                queue.playback_order(),
                ","
            ) == "2,3,4,1",
            "simulator did not expose the actual shuffled playback order"
        )

        local shuffled_positions = {
            queue.position:get(),
        }

        for _ = 1, 3 do
            queue.next()
            table.insert(
                shuffled_positions,
                queue.position:get()
            )
        end

        assert(
            table.concat(
                shuffled_positions,
                ","
            ) == "2,3,4,1",
            "simulator Next ignored the shuffled queue order"
        )

        queue.random:set(false)
        queue.next()
        assert(
            queue.position:get() == 2,
            "disabling shuffle did not restore sequential queue navigation"
        )

        queue.position:set(3)
        queue.random:set(true)
        assert(
            queue.position:get() == 3,
            "enabling shuffle changed the currently selected track"
        )

        assert(
            table.concat(
                queue.playback_order(),
                ","
            ) == "3,2,4,1",
            "shuffle toggle did not expose the current track followed by its randomized upcoming order"
        )

        queue.next()
        assert(
            queue.position:get() == 2,
            "enabling shuffle from Now Playing did not randomize the upcoming order"
        )
        assert(
            table.concat(
                queue.playback_order(),
                ","
            ) == "2,4,1",
            "simulator playback order did not advance with the shuffled queue"
        )
    end,
    debug.traceback
)

math.random = original_random
os.remove(playlist_path)

if not ok then
    error(failure)
end

print(
    "Simulator queue honors Shuffle All and the Now Playing shuffle toggle"
)
os.exit(0)
