local device = require("device")
local playback = require("playback")
local queue = require("queue")
local sync_manifest_cache =
    require("sync_manifest_cache")

local M = {}
local active = nil
local queue_generation = 0

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
        if type(item.jellyfin_id) ==
                "string" then
            by_id[item.jellyfin_id] = item
        end

        if type(item.id) == "string" then
            by_id[item.id] = item
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
    if type(track) ~= "table" or
        type(track.id) ~= "string" or
        track.id == "" then
        return nil,
            "Jellyfin track ID is missing"
    end

    local item =
        items_by_id[track.id]

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

    return candidate.id == selected.id
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
                false
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
        track = copy_value(active.track),
        item = copy_value(active.item),
        context = copy_value(active.context),
        queue = {
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

function M.sync_position(position)
    sync_active_position(position)
    return active_snapshot()
end

function M.next()
    queue.next()
    sync_active_position(
        queue.position:get()
    )
    return active_snapshot()
end

function M.previous()
    queue.previous()
    sync_active_position(
        queue.position:get()
    )
    return active_snapshot()
end

function M.current()
    sync_active_position()
    return active_snapshot()
end


local function current_playback_order()
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

function M.queue_view()
    sync_active_position()

    if not active then
        return nil
    end

    local source_positions =
        current_playback_order()
    local tracks = {}
    local items = {}

    for _, source_position in ipairs(
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
    end

    return {
        tracks = tracks,
        items = items,
        source_positions = source_positions,
        position = #tracks > 0 and 1 or 0,
        source_position = active.position,
        size = #tracks,
        total_size = #active.tracks,
        playlist_path =
            active.playlist_path,
        generation =
            active.generation or 0,
        shuffle =
            queue.random and
            type(queue.random.get) ==
                "function" and
            queue.random:get() == true or
            false,
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
