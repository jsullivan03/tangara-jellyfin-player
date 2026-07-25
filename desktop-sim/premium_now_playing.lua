package.path = "desktop-sim/?.lua;lua/?.lua;" .. package.path

local lvgl = require("lvgl")

lvgl.ImgData = function(path)
    return path
end

require("mocks").install(lvgl)

local playback = require("playback")
local json = require("json")

local file, open_error = io.open(
    "desktop-sim/sync_manifest.json",
    "rb"
)

if not file then
    error(open_error)
end

local manifest_text = file:read("*a")
file:close()

local manifest = json.decode(manifest_text)

local screen = require("premium_now_playing_screen").create {
    background = manifest.items[1].artwork.background,
    cover = manifest.items[1].artwork.cover,
}

local function format_time(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function update_progress()
    local track = playback.track:get()
    local position = playback.position:get() or 0

    if not track then
        return
    end

    local duration = track.duration or 0
    local progress = 0

    if duration > 0 then
        progress = position / duration
    end

    screen:update {
        progress = progress,
        elapsed = format_time(position),
        remaining = format_time(duration),
    }
end

playback.track:bind(function(track)
    if not track then
        return
    end

    screen:update {
        background = track.artwork.background,
        cover = track.artwork.cover,
        title = track.title,
        artist = track.artist,
        progress = 0,
        elapsed = "0:00",
        remaining = format_time(track.duration),
    }
end)

playback.position:bind(update_progress)

local current_index = 1

local function load_item(index)
    local item = manifest.items[index]

    if not item then
        return
    end

    current_index = index

    playback.position:set(0)
    playback.track:set {
        id = item.id,
        jellyfin_id = item.jellyfin_id,
        title = item.title,
        artist = item.artist,
        album = item.album,
        duration = item.duration,
        filepath = item.local_path,
        artwork = item.artwork,
        sync_state = item.sync_state,
        pinned = item.pinned,
    }
    playback.playing:set(true)
end

screen.playback_timer = lvgl.Timer {
    period = 1000,
    cb = function()
        if not playback.playing:get() then
            return
        end

        local track = playback.track:get()

        if not track then
            return
        end

        local position = (playback.position:get() or 0) + 1

        if position >= track.duration then
            local next_index = current_index + 1

            if next_index > #manifest.items then
                next_index = 1
            end

            load_item(next_index)
            return
        end

        playback.position:set(position)
    end,
}

local hitbox = screen.root:Object {
    x = 0,
    y = 0,
    w = 160,
    h = 128,
    border_width = 0,
    bg_opa = 0,
}

hitbox:onClicked(function()
    local next_index = current_index + 1

    if next_index > #manifest.items then
        next_index = 1
    end

    load_item(next_index)
end)

load_item(1)
