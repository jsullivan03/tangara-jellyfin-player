local device = require("device")
local playback = require("playback")
local queue = require("queue")
local sync_manifest_cache =
    require("sync_manifest_cache")
local jellyfin_track_identity =
    require("jellyfin_track_identity")

local M = {}
local active = nil
local queue_generation = 0
local current_playback_order = nil

local QUEUE_PLAYLIST_PATH =
    "/.tangara-jellyfin-current.playlist"

local function copy_value(value)
    if type(value) ~= "table" then
        return value
    end

    local copied = {}

    for key, child in pairs(value) do
        copied[copy_value(key)] =
            copy_value(child)
    end

    return copied
end

local function manifest_items_by_id(
    manifest
)
    local by_id = {}

    for _, item in ipairs(
        manifest.items or {}
    ) do
        local stable =
            jellyfin_track_identity.stable_id(
                item
            )

        if stable then
            by_id[stable] = item
        end

        if type(item.jellyfin_id) ==
                "string" then
            by_id[
                jellyfin_track_identity
                    .stable_id(
                        item.jellyfin_id
                    ) or
                item.jellyfin_id
            ] = item
        end

        if type(item.id) == "string" then
            by_id[
                jellyfin_track_identity
                    .stable_id(item.id) or
                item.id
            ] = item
        end
    end

    return by_id
end

local function file_exists(path)
    local file = io.open(path, "rb")

    if not file then
        return false
    end

    file:close()
    return true
end

local function storage_root()
    local root, root_error =
        device.storage_root()

    if type(root) ~= "string" or
        root == "" then
        return nil,
            root_error or
            "storage root is unavailable"
    end

    return root:gsub("/+$", "")
end

local function local_item_from_manifest(
    track,
    items_by_id,
    root,
    verify_file
)
    if type(track) ~= "table" then
        return nil,
            "Jellyfin track ID is missing"
    end

    local track_id =
        jellyfin_track_identity.stable_id(
            track
        )

    if not track_id then
        return nil,
            "Jellyfin track ID is missing"
    end

    local item =
        items_by_id[track_id] or
        (
            type(track.id) == "string" and
            items_by_id[track.id]
        ) or
        (
            type(track.jellyfin_id) ==
                "string" and
            items_by_id[track.jellyfin_id]
        )

    if not item then
        return nil,
            "Track is not downloaded yet"
    end

    if type(item.local_path) ~= "string" or
        item.local_path == "" or
        item.local_path:sub(1, 1) ~= "/" then
        return nil,
            "Downloaded track path is invalid"
    end

    if verify_file ~= false and
        not file_exists(
            root .. item.local_path
        ) then
        return nil,
            "Track is not downloaded yet"
    end

    return item
end

local function entry_context(
    context,
    track
)
    local copied = {}

    for key, value in pairs(
        context or {}
    ) do
        if key ~= "queue_tracks" then
            copied[key] =
                copy_value(value)
        end
    end

    if type(track) == "table" and
        type(track.playlist_entry_id) ==
            "string" and
        track.playlist_entry_id ~= "" then
        copied.entry_id =
            track.playlist_entry_id
    end

    return copied
end

local function selected_track_matches(
    candidate,
    selected,
    context
)
    if type(selected) ~= "table" then
        return false
    end

    local selected_entry =
        context and
        context.entry_id

    if type(selected_entry) == "string" and
        selected_entry ~= "" and
        type(candidate.playlist_entry_id) ==
            "string" then
        return candidate.playlist_entry_id ==
            selected_entry
    end

    return jellyfin_track_identity.same(
        candidate,
        selected
    )
end

local function write_queue_playlist(
    root,
    items
)
    local full_path =
        root .. QUEUE_PLAYLIST_PATH

    local file, file_error =
        io.open(full_path, "wb")

    if not file then
        return nil,
            file_error or
            "Unable to create playback queue"
    end

    for _, item in ipairs(items) do
        local path = item.local_path

        if path:find("[\r\n]") then
            file:close()
            return nil,
                "Downloaded track path is invalid"
        end

        file:write(path, "\n")
    end

    file:close()

    -- Tangara caches playlist offsets beside the playlist. Replacing the
    -- queue file must invalidate that cache or the old item count and offsets
    -- can be reused.
    os.remove(full_path .. ".cache")

    return QUEUE_PLAYLIST_PATH
end

local function queue_entries(
    selected_track,
    context,
    items_by_id,
    root
)
    local candidates =
        context and
        context.queue_tracks

    if type(candidates) ~= "table" or
        #candidates == 0 then
        candidates = {selected_track}
    end

    local tracks = {}
    local items = {}
    local selected_index = nil

    for _, candidate in ipairs(candidates) do
        local item =
            local_item_from_manifest(
                candidate,
                items_by_id,
                root,
                true
            )

        -- Collection views may contain a temporarily unavailable item. Keep
        -- the playable local ordering and omit unavailable entries instead of
        -- preventing the selected downloaded track from playing. Only table
        -- references are retained here; duplicating thousands of metadata
        -- records would waste PSRAM.
        if item then
            table.insert(tracks, candidate)
            table.insert(items, item)

            if not selected_index and
                selected_track_matches(
                    candidate,
                    selected_track,
                    context
                ) then
                selected_index = #tracks
            end
        end
    end

    return tracks, items, selected_index
end

local function active_snapshot()
    if not active then
        return nil
    end

    return {
        generation = active.generation,
        track = copy_value(active.track),
        item = copy_value(active.item),
        context = copy_value(active.context),
        queue = {
            position = active.position,
            size = #active.tracks,
            items = copy_value(
                active.tracks
            ),
            playlist_path =
                active.playlist_path,
            shuffle =
                queue.random and
                type(queue.random.get) ==
                    "function" and
                queue.random:get() == true or
                false,
        },
    }
end

local function sync_active_position(native_position)
    if not active or
        type(active.tracks) ~= "table" then
        return
    end

    native_position =
        tonumber(native_position)

    if native_position == nil then
        native_position =
            tonumber(queue.position:get())
    end

    if native_position == nil then
        native_position =
            active.position or 1
    end

    -- Tangara exposes queue.position to Lua as a one-based value. Keep the
    -- retained Jellyfin queue position in that same coordinate system.
    local position =
        math.floor(native_position)

    if position < 1 or
        position > #active.tracks then
        return
    end

    local selected_track =
        active.tracks[position]

    active.position = position
    active.track = selected_track
    active.item = active.items[position]
    active.context =
        entry_context(
            active.base_context,
            selected_track
        )
end

function M.local_item(track)
    local manifest, manifest_error =
        sync_manifest_cache.load()

    if not manifest then
        return nil,
            manifest_error or
            "download manifest is unavailable"
    end

    local root, root_error =
        storage_root()

    if not root then
        return nil, root_error
    end

    return local_item_from_manifest(
        track,
        manifest_items_by_id(
            manifest
        ),
        root,
        true
    )
end

function M.play_queue(
    tracks,
    context,
    options
)
    context = context or {}
    options = options or {}

    if type(tracks) ~= "table" or
        #tracks == 0 then
        return false, "No tracks to play"
    end

    local manifest, manifest_error =
        sync_manifest_cache.load()

    if not manifest then
        return false,
            manifest_error or
            "download manifest is unavailable"
    end

    local root, root_error =
        storage_root()

    if not root then
        return false, root_error
    end

    local items_by_id =
        manifest_items_by_id(
            manifest
        )
    local selected_track =
        options.selected_track
    local selected_item = nil

    if selected_track then
        local item_error

        selected_item, item_error =
            local_item_from_manifest(
                selected_track,
                items_by_id,
                root,
                true
            )

        if not selected_item then
            return false, item_error
        end
    end

    local queue_context = {}

    for key, value in pairs(context) do
        queue_context[key] = value
    end

    queue_context.queue_tracks = tracks

    local queued_tracks,
        queued_items,
        selected_index =
        queue_entries(
            selected_track,
            queue_context,
            items_by_id,
            root
        )

    if selected_track and
        not selected_index then
        table.insert(
            queued_tracks,
            selected_track
        )
        table.insert(
            queued_items,
            selected_item
        )
        selected_index =
            #queued_tracks
    end

    if #queued_tracks == 0 then
        return false,
            "No downloaded tracks are available"
    end

    if selected_track then
        -- queue_entries preserves the exact selected occurrence, including a
        -- duplicate playlist entry identified by context.entry_id.
        selected_index =
            selected_index or 1
    else
        selected_index =
            math.max(
                1,
                math.min(
                    #queued_tracks,
                    math.floor(
                        tonumber(
                            options.start_index
                        ) or 1
                    )
                )
            )
    end

    local playlist_path,
        playlist_error =
        write_queue_playlist(
            root,
            queued_items
        )

    if not playlist_path then
        return false, playlist_error
    end

    queue_generation =
        queue_generation + 1

    active = {
        tracks = queued_tracks,
        items = queued_items,
        base_context =
            entry_context(
                context,
                {}
            ),
        position = selected_index,
        playlist_path = playlist_path,
        generation = queue_generation,
    }

    local shuffle =
        options.shuffle == true

    if queue.random and
        type(queue.random.set) ==
            "function" then
        queue.random:set(shuffle)
    end

    queue.open_playlist(
        playlist_path
    )

    if shuffle then
        -- Tangara chooses the initial shuffled position while opening the
        -- playlist. Preserve that native position so Shuffle All starts with
        -- a random item instead of forcing the first track afterward.
        sync_active_position(
            queue.position:get()
        )
    else
        queue.position:set(
            selected_index
        )
        sync_active_position(
            selected_index
        )
    end

    playback.playing:set(true)

    -- Capture the complete display order while the native queue still exposes
    -- the full shuffled sequence. Later playback_order() calls only expose the
    -- unplayed tail, but the Queue screen must retain earlier tracks because
    -- Previous can still return to them.
    active.display_shuffle = shuffle
    active.display_order = {}

    if shuffle and
        type(current_playback_order) ==
            "function" then
        active.display_order =
            current_playback_order()
    else
        for index = 1, #queued_tracks do
            table.insert(
                active.display_order,
                index
            )
        end
    end

    return true, active_snapshot()
end

function M.play(track, context)
    context = context or {}

    local tracks =
        context.queue_tracks

    if type(tracks) ~= "table" or
        #tracks == 0 then
        tracks = {track}
    end

    return M.play_queue(
        tracks,
        context,
        {
            selected_track = track,
            shuffle = false,
        }
    )
end

local function native_shuffle_enabled()
    return
        queue.random and
        type(queue.random.get) ==
            "function" and
        queue.random:get() == true or
        false
end

local function sequential_source_order(count)
    local order = {}

    for position = 1, count do
        table.insert(order, position)
    end

    return order
end

local function bump_queue_generation()
    if not active then
        return
    end

    queue_generation = queue_generation + 1
    active.generation = queue_generation
end

local function display_index_of(order, source_position)
    for index, position in ipairs(order or {}) do
        if position == source_position then
            return index
        end
    end

    return nil
end

local function shuffle_unplayed_positions(positions)
    local remaining = {}

    for _, position in ipairs(positions) do
        table.insert(remaining, position)
    end

    if #remaining <= 1 then
        return remaining
    end

    local original = {}

    for index, position in ipairs(remaining) do
        original[index] = position
    end

    for index = #remaining, 2, -1 do
        local swap_index =
            math.random(1, index)

        remaining[index],
            remaining[swap_index] =
            remaining[swap_index],
            remaining[index]
    end

    -- Guaranteeing a visible mid-session shuffle avoids the false-"random"
    -- case where Fisher-Yates reproduces the unplayed sequential tail.
    local unchanged = true

    for index = 1, #remaining do
        if remaining[index] ~=
            original[index] then
            unchanged = false
            break
        end
    end

    if unchanged then
        remaining[1],
            remaining[#remaining] =
            remaining[#remaining],
            remaining[1]
    end

    return remaining
end

-- Mid-session Shuffle must keep history + current fixed and permute only the
-- still-unplayed source positions. Native queue.random alone permutes the
-- entire queue; merging that with a sequential display_order often rebuilds
-- the original order after dedupe.
local function apply_mid_session_shuffle()
    local count = #active.tracks
    local current =
        math.max(
            1,
            math.min(
                count,
                math.floor(
                    tonumber(active.position) or 1
                )
            )
        )
    local previous =
        type(active.display_order) ==
            "table" and
        active.display_order or
        sequential_source_order(count)
    local history = {}
    local seen = {}

    for _, position in ipairs(previous) do
        if position == current then
            break
        end

        if position >= 1 and
            position <= count and
            not seen[position] then
            table.insert(history, position)
            seen[position] = true
        end
    end

    seen[current] = true

    local unplayed = {}

    for _, position in ipairs(previous) do
        if position >= 1 and
            position <= count and
            not seen[position] then
            table.insert(unplayed, position)
            seen[position] = true
        end
    end

    for position = 1, count do
        if not seen[position] then
            table.insert(unplayed, position)
        end
    end

    unplayed =
        shuffle_unplayed_positions(unplayed)

    local order = {}

    for _, position in ipairs(history) do
        table.insert(order, position)
    end

    table.insert(order, current)

    for _, position in ipairs(unplayed) do
        table.insert(order, position)
    end

    active.display_order = order
    active.display_shuffle = true
    bump_queue_generation()
    return order
end

local function apply_unshuffle_display()
    local order =
        sequential_source_order(
            #active.tracks
        )

    active.display_order = order
    active.display_shuffle = false
    bump_queue_generation()
    return order
end

local function ensure_shuffle_display_state()
    if not active then
        return false
    end

    local shuffle = native_shuffle_enabled()

    if shuffle and
        not active.display_shuffle then
        apply_mid_session_shuffle()
        return true
    end

    if not shuffle and
        active.display_shuffle then
        apply_unshuffle_display()
        return true
    end

    return false
end

function M.sync_position(position)
    sync_active_position(position)
    ensure_shuffle_display_state()
    return active_snapshot()
end

function M.set_shuffle(enabled)
    enabled = enabled == true

    if queue.random and
        type(queue.random.set) ==
            "function" then
        queue.random:set(enabled)
    end

    if not active then
        return nil
    end

    ensure_shuffle_display_state()
    return active_snapshot()
end

function M.next()
    if not active then
        return nil
    end

    ensure_shuffle_display_state()

    if active.display_shuffle and
        type(active.display_order) ==
            "table" then
        local index =
            display_index_of(
                active.display_order,
                active.position
            )
        local next_source =
            index and
            active.display_order[index + 1]

        if next_source then
            queue.position:set(next_source)
            sync_active_position(next_source)
        end

        return active_snapshot()
    end

    queue.next()
    sync_active_position(
        queue.position:get()
    )
    return active_snapshot()
end

function M.previous()
    if not active then
        return nil
    end

    ensure_shuffle_display_state()

    if active.display_shuffle and
        type(active.display_order) ==
            "table" then
        local index =
            display_index_of(
                active.display_order,
                active.position
            )
        local previous_source =
            index and
            active.display_order[index - 1]

        if previous_source then
            queue.position:set(
                previous_source
            )
            sync_active_position(
                previous_source
            )
        end

        return active_snapshot()
    end

    queue.previous()
    sync_active_position(
        queue.position:get()
    )
    return active_snapshot()
end

function M.current()
    sync_active_position()
    ensure_shuffle_display_state()
    return active_snapshot()
end


current_playback_order = function()
    local count = #active.tracks
    local order = nil

    if type(queue.playback_order) ==
            "function" then
        local ok, result =
            pcall(queue.playback_order)

        if ok and
            type(result) == "table" then
            order = {}

            for _, value in ipairs(result) do
                local position =
                    math.floor(
                        tonumber(value) or 0
                    )

                if position >= 1 and
                    position <= count then
                    table.insert(
                        order,
                        position
                    )
                end
            end

            if #order == 0 then
                order = nil
            end
        end
    end

    if order then
        return order
    end

    order = {}

    for position =
        math.max(1, active.position or 1),
        count do
        table.insert(order, position)
    end

    return order
end

local function display_playback_order()
    local count = #active.tracks
    local shuffle = native_shuffle_enabled()

    if not shuffle then
        if active.display_shuffle then
            return apply_unshuffle_display(),
                false
        end

        local order =
            sequential_source_order(count)

        active.display_order = order
        active.display_shuffle = false
        return order, false
    end

    if not active.display_shuffle then
        return apply_mid_session_shuffle(), true
    end

    -- Stable shuffled display order. Do not re-merge with native remaining;
    -- that path reconstructed the sequential queue after mid-session enable.
    local order = active.display_order

    if type(order) ~= "table" or
        #order ~= count then
        return apply_mid_session_shuffle(), true
    end

    return order, true
end

function M.queue_view()
    sync_active_position()

    if not active then
        return nil
    end

    local source_positions, shuffle =
        display_playback_order()
    local tracks = {}
    local items = {}
    local display_position = 0

    for index, source_position in ipairs(
        source_positions
    ) do
        table.insert(
            tracks,
            active.tracks[source_position]
        )
        table.insert(
            items,
            active.items[source_position]
        )

        if source_position ==
            active.position then
            display_position = index
        end
    end

    return {
        tracks = tracks,
        items = items,
        source_positions = source_positions,
        position = display_position,
        source_position = active.position,
        size = #tracks,
        total_size = #active.tracks,
        playlist_path =
            active.playlist_path,
        generation =
            active.generation or 0,
        shuffle = shuffle,
    }
end

function M.queue_state()
    if not active then
        return nil
    end

    return {
        position = active.position,
        size = #active.tracks,
        playlist_path =
            active.playlist_path,
        shuffle =
            queue.random and
            type(queue.random.get) ==
                "function" and
            queue.random:get() == true or
            false,
    }
end

return M
