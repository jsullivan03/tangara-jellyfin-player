package.path = "desktop-sim/?.lua;lua/?.lua;" .. package.path

local lvgl = require("lvgl")

lvgl.ImgData = function(path)
    return path
end

require("mocks").install(lvgl)

local playback = require("playback")
local database = require("database")

local screen = require("premium_now_playing_screen").create {
    background = "/desktop-sim/generated/now-playing-background.png",
    cover = "/desktop-sim/generated/now-playing-cover.png",
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

    local tags = track.tags or {}

    screen:update {
        title = tags.title or track.title or "",
        artist = tags.artist or track.artist or "",
        progress = 0,
        elapsed = "0:00",
        remaining = format_time(track.duration),
    }
end)

playback.position:bind(function()
    update_progress()
end)

local current_track = 1

local function load_track(id)
    current_track = id
    playback.position:set(0)
    playback.track:set(database.track_by_id(id))
    playback.playing:set(true)
end

lvgl.Timer {
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
            local next_track = current_track + 1

            if not database.track_by_id(next_track) then
                next_track = 1
            end

            load_track(next_track)
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
    local next_track = current_track + 1

    if not database.track_by_id(next_track) then
        next_track = 1
    end

    load_track(next_track)
end)

load_track(1)
