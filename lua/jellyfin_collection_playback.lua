local backstack = require("backstack")
local jellyfin_list_ui =
    require("jellyfin_list_ui")
local jellyfin_now_playing =
    require("jellyfin_now_playing")
local jellyfin_playback =
    require("jellyfin_playback")

local M = {}

local function resolve(value)
    if type(value) == "function" then
        return value()
    end

    return value
end

function M.flatten_albums(albums)
    local tracks = {}

    for _, album in ipairs(
        albums or {}
    ) do
        for _, track in ipairs(
            album.tracks or {}
        ) do
            table.insert(tracks, track)
        end
    end

    return tracks
end

function M.start(
    tracks,
    context,
    shuffle
)
    tracks = resolve(tracks) or {}
    context = resolve(context) or {}

    local played, play_error =
        jellyfin_playback.play_queue(
            tracks,
            context,
            {
                start_index = 1,
                shuffle = shuffle == true,
            }
        )

    if played then
        backstack.push(
            jellyfin_now_playing:new()
        )
    end

    return played, play_error
end

function M.attach(
    owner,
    options
)
    options = options or {}

    return jellyfin_list_ui
        .add_play_control(
            owner,
            {
                label =
                    options.label or
                    "Play",
                shuffle_label =
                    options.shuffle_label or
                    "Shuffle",
                selection_id =
                    options.selection_id,
                on_play =
                    function()
                        return M.start(
                            options.tracks,
                            options.context,
                            false
                        )
                    end,
                on_shuffle =
                    function()
                        return M.start(
                            options.tracks,
                            options.context,
                            true
                        )
                    end,
            }
        )
end

return M
