dofile("desktop-sim/jellyfin_library.lua")

local backstack = require("backstack")
local device = require("device")
local index = require("jellyfin_local_index")
local jellyfin_playback = require("jellyfin_playback")
local local_library = require("jellyfin_local_library")
local lvgl = require("lvgl")
local playback = require("playback")
local session = require("jellyfin_playback_session")
local sim_audio = require("sim_audio")

local library = assert(index.load())
local root = assert(device.storage_root())
local selected
local following

for _, track in ipairs(library.tracks) do
    local file = io.open(root .. track.local_path, "rb")
    local size = file and file:seek("end") or 0

    if file then
        file:close()
    end

    if track.id ==
            "ce1c15cfac374bfa95508510ec994096" then
        selected = track
    elseif size > 1000000 and not following then
        following = track
    end
end

assert(selected and following)

local parent = local_library.Tracks:new()
backstack.push(parent)
assert(jellyfin_playback.play(
    selected,
    {
        collection_kind = "local_tracks",
        queue_tracks = {selected, following},
    }
))
assert(session.open_now_playing())

local player = backstack.current()
local initial = assert(session.current())
assert(sim_audio.seek(
    initial.metadata.duration - 0.01
))
playback.playing:set(true)

local attempts = 0

lvgl.Timer {
    period = 100,
    cb = function()
        local ok, failure = xpcall(function()
            attempts = attempts + 1
            local current = assert(session.current())

            if current.track_id ~= following.id and
                attempts < 20 then
                return
            end

            assert(current.track_id == following.id,
                "EOF did not update playback session")
            assert(current.queue_index == 2)
            assert(#current.queue.items == 2)
            assert(player.view:media_state().title ==
                following.title)

            backstack.pop()
            parent.mini_player:refresh()
            local mini = parent.mini_player:state()
            assert(mini.track_id == following.id)
            assert(mini.queue_index == 2)
            assert(mini.artwork.source ==
                current.artwork.foreground)

            print(string.format(
                "EOF session propagation passed: track=%s index=%d title=%s",
                current.track_id,
                current.queue_index,
                current.metadata.title
            ))
            os.exit(0)
        end, debug.traceback)

        if not ok then
            io.stderr:write(failure, "\n")
            os.exit(1)
        end
    end,
}
