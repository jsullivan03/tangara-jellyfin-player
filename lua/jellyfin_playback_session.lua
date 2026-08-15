local backstack = require("backstack")
local jellyfin_local_artwork =
    require("jellyfin_local_artwork")
local jellyfin_playback =
    require("jellyfin_playback")
local jellyfin_track_identity =
    require("jellyfin_track_identity")
local jellyfin_album_identity =
    require("jellyfin_album_identity")
local playback = require("playback")
local volume = require("volume")

local M = {}
local session_id = 0
local last_track_id = nil
local last_queue_generation = nil
local now_playing_visible = false

local function copy(value)
    if type(value) ~= "table" then
        return value
    end

    local result = {}

    for key, child in pairs(value) do
        result[copy(key)] = copy(child)
    end

    return result
end

local function simulator_state()
    local value = rawget(
        _G,
        "tangara_sim_local_playback_state"
    )

    return type(value) == "table" and
        value or nil
end

function M.current()
    local active = jellyfin_playback.current()

    if not active or
        type(active.track) ~= "table" or
        type(active.item) ~= "table" then
        return nil
    end

    local track_id =
        jellyfin_track_identity.stable_id(
            active.track
        )

    if last_queue_generation ~=
            active.generation then
        session_id = session_id + 1
        last_queue_generation =
            active.generation
    end

    last_track_id = track_id

    local foreground, foreground_identity =
        jellyfin_local_artwork.active(
            active,
            "cover"
        )
    local background, background_identity =
        jellyfin_local_artwork.active(
            active,
            "background"
        )
    local simulator = simulator_state()
    local queue = copy(active.queue or {})

    queue.items = queue.items or {}

    return {
        id = session_id,
        track_id = track_id,
        album_id =
            jellyfin_album_identity.album_id(
                active.track
            ) or
            jellyfin_album_identity.album_id(
                active.item
            ),
        queue = queue,
        queue_index =
            tonumber(queue.position) or 0,
        local_path = active.item.local_path,
        resolved_local_path =
            simulator and
            simulator.resolved_path or
            active.item.local_path,
        decoder = {
            open = simulator and
                simulator.decoder_open == true or
                playback.track:get() ~= nil,
            output = simulator and
                simulator.output or
                "firmware",
            path = simulator and
                simulator.decoder_path or
                active.item.local_path,
            open_count = simulator and
                tonumber(simulator.open_count) or
                nil,
            close_count = simulator and
                tonumber(simulator.close_count) or
                nil,
            sample_rate = simulator and
                tonumber(simulator.sample_rate) or
                nil,
            channels = simulator and
                tonumber(simulator.channels) or
                nil,
            transition = simulator and
                copy(simulator.transition) or
                nil,
        },
        position =
            simulator and
            tonumber(simulator.position) or
            tonumber(playback.position:get()) or
            0,
        paused = playback.playing:get() ~= true,
        volume = tonumber(volume.current_pct:get()) or 0,
        metadata = {
            title = active.track.title or "",
            artist = active.track.artist or "",
            album = active.track.album or "",
            duration =
                tonumber(active.track.duration) or
                tonumber(active.item.duration) or 0,
        },
        artwork = {
            foreground = foreground,
            background = background,
            foreground_identity =
                foreground_identity,
            background_identity =
                background_identity,
        },
        pcm = simulator and
            simulator.pcm_analysis or nil,
        active = active,
    }
end

function M.exists()
    return M.current() ~= nil
end

function M.open_now_playing()
    if not M.exists() or
        now_playing_visible then
        return false
    end

    backstack.push(
        require("jellyfin_now_playing"):new()
    )
    return true
end

function M.set_now_playing_visible(value)
    now_playing_visible = value == true
end

function M.is_now_playing_visible()
    return now_playing_visible
end

function M.reset_for_test()
    session_id = 0
    last_track_id = nil
    last_queue_generation = nil
    now_playing_visible = false
end

-- Resume-selection contract: snapshots store the exact focused selection.
-- Track focus uses canonical jellyfin_track_identity keys; leading controls
-- keep their explicit control:* identity. The viewport remains independent.
function M.track_selection_key(track_or_id)
    return jellyfin_track_identity.key(
        track_or_id
    )
end

function M.capture_track_list_resume(screen)
    if type(screen) ~= "table" then
        return nil
    end

    local controller =
        screen.virtual_track_list or
        screen.virtual_list_controller

    if type(controller) ~= "table" or
        type(controller.items) ~= "table" then
        return nil
    end

    local selected_index =
        math.max(
            1,
            math.floor(
                tonumber(
                    controller.selected_index
                ) or 1
            )
        )
    local selected_id = screen.selected_item_id
    local focus_id =
        selected_id ~= nil and
        tostring(selected_id) or
        nil
    local track_key = nil

    if type(controller.find_index) ==
            "function" and
        selected_id and
        not tostring(selected_id):match(
            "^control:"
        ) then
        local by_id =
            controller:find_index(selected_id)

        if by_id then
            selected_index = by_id
            local item =
                controller.items[by_id]
            track_key =
                M.track_selection_key(item) or
                M.track_selection_key(
                    selected_id
                )
        end
    end

    if not track_key and
        not (
            focus_id and
            focus_id:match("^control:")
        ) then
        local item =
            controller.items[selected_index]

        track_key =
            M.track_selection_key(item)
    end

    focus_id = focus_id or track_key

    if not focus_id then
        screen.track_list_resume = nil
        return nil
    end

    local snapshot = {
        focus_id = focus_id,
        track_key = track_key,
        -- Legacy field kept for album helpers that still read track_id.
        track_id = track_key,
        selected_index = selected_index,
        window_start =
            controller.window_start,
        fixed_base_y =
            controller.fixed_base_y or 0,
        viewport_height =
            controller.fixed_viewport_height,
    }

    screen.track_list_resume = snapshot
    screen.album_track_resume = snapshot
    screen.selected_item_id = focus_id
    controller.selected_index =
        selected_index

    return snapshot
end

function M.restore_track_list_resume(screen)
    if type(screen) ~= "table" then
        return nil
    end

    local snapshot =
        screen.track_list_resume or
        screen.album_track_resume

    if type(snapshot) ~= "table" then
        return nil
    end

    local focus_id =
        snapshot.focus_id and
        tostring(snapshot.focus_id) or
        nil
    local control_focus =
        focus_id and
        focus_id:match("^control:") ~= nil
    local track_key = nil

    if not control_focus then
        track_key =
            M.track_selection_key(
                snapshot.track_key or
                snapshot.track_id or
                focus_id
            )
    end

    local controller =
        screen.virtual_track_list or
        screen.virtual_list_controller

    if type(controller) ~= "table" then
        return nil
    end

    local selected_index =
        math.min(
            math.max(1, #controller.items),
            math.max(
                1,
                math.floor(
                    tonumber(
                        snapshot.selected_index
                    ) or
                    controller.selected_index or
                    1
                )
            )
        )

    local found_by_id = nil

    if track_key and
        type(controller.find_index) ==
            "function" then
        found_by_id =
            controller:find_index(track_key)

        if found_by_id then
            selected_index = found_by_id
        end
    end

    if not control_focus and
        not found_by_id then
        local fallback =
            controller.items[selected_index]
        track_key =
            M.track_selection_key(fallback)
        focus_id = track_key
    end

    if not focus_id then
        return nil
    end

    screen.selected_item_id = focus_id
    screen.discography_selection_lock =
        control_focus and nil or track_key
    controller.selected_index =
        selected_index

    local height_unchanged =
        snapshot.viewport_height ~= nil and
        snapshot.viewport_height ==
            controller.fixed_viewport_height

    if height_unchanged then
        if snapshot.window_start then
            controller.window_start =
                snapshot.window_start
        end

        if snapshot.fixed_base_y ~= nil then
            controller.fixed_base_y =
                snapshot.fixed_base_y
        end
    end

    return {
        focus_id = focus_id,
        track_key = track_key,
        selected_index = selected_index,
        exact =
            control_focus or
            found_by_id ~= nil,
    }
end

function M.clear_track_list_resume_lock(screen)
    if type(screen) ~= "table" then
        return
    end

    local snapshot =
        screen.track_list_resume or
        screen.album_track_resume

    if not snapshot then
        return
    end

    local lock_key =
        snapshot.track_key or
        snapshot.track_id

    if screen.discography_selection_lock ~=
            lock_key and
        not jellyfin_track_identity
            .matches_selection(
                screen.discography_selection_lock,
                lock_key
            ) then
        return
    end

    screen.discography_selection_lock = nil
end

return M
