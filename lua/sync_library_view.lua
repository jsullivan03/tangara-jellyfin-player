local sync_library_cache =
    require("sync_library_cache")
local sync_operation_queue =
    require("sync_operation_queue")

local M = {}

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

local function placeholder_track(
    item_id,
    index
)
    local known = index[item_id]

    if known then
        return copy_value(known)
    end

    return {
        id = item_id,
        title = "Unknown Track",
        artist = "",
        album = "",
        duration = 0,
        date_created = "",
        favorite = false,
        image_tags = {},
    }
end

local function track_index(library)
    local index = {}

    for _, track in ipairs(
        library.favorites.items
    ) do
        index[track.id] =
            index[track.id] or track
    end

    for _, playlist in ipairs(
        library.playlists
    ) do
        for _, track in ipairs(
            playlist.items
        ) do
            index[track.id] =
                index[track.id] or track
        end
    end

    return index
end

local function normalize_collection(
    collection
)
    for position, track in ipairs(
        collection.items
    ) do
        track.position = position - 1
    end

    collection.track_count =
        #collection.items
end

local function normalize_library(library)
    normalize_collection(
        library.favorites
    )

    for _, playlist in ipairs(
        library.playlists
    ) do
        normalize_collection(playlist)
    end
end

local function resolve_id(
    snapshot,
    playlist_id
)
    return snapshot.playlist_aliases[
        playlist_id
    ] or playlist_id
end

local function find_playlist(
    library,
    snapshot,
    playlist_id
)
    local resolved =
        resolve_id(snapshot, playlist_id)

    for _, playlist in ipairs(
        library.playlists
    ) do
        if playlist.id == playlist_id or
            playlist.id == resolved then
            return playlist
        end
    end

    return nil
end

local function ensure_playlist(
    library,
    snapshot,
    playlist_id,
    name
)
    local playlist =
        find_playlist(
            library,
            snapshot,
            playlist_id
        )

    if playlist then
        return playlist
    end

    playlist = {
        id =
            resolve_id(
                snapshot,
                playlist_id
            ),
        local_id = playlist_id,
        name = name or "New Playlist",
        revision = "",
        track_count = 0,
        keep_downloaded = false,
        items = {},
        pending = true,
    }

    table.insert(
        library.playlists,
        playlist
    )

    return playlist
end

local function remove_playlist(
    library,
    snapshot,
    playlist_id
)
    local resolved =
        resolve_id(snapshot, playlist_id)

    for index = #library.playlists, 1, -1 do
        local playlist =
            library.playlists[index]

        if playlist.id == playlist_id or
            playlist.id == resolved or
            playlist.local_id == playlist_id then
            table.remove(
                library.playlists,
                index
            )
        end
    end
end

local function remove_entry(
    playlist,
    entry_id
)
    for index = #playlist.items, 1, -1 do
        if playlist.items[index]
            .playlist_entry_id == entry_id then
            table.remove(
                playlist.items,
                index
            )

            return true
        end
    end

    return false
end

local function move_entry(
    playlist,
    entry_id,
    new_index
)
    local current_index = nil

    for index, track in ipairs(
        playlist.items
    ) do
        if track.playlist_entry_id ==
            entry_id then
            current_index = index
            break
        end
    end

    if not current_index then
        return false
    end

    local track = table.remove(
        playlist.items,
        current_index
    )

    local destination =
        math.max(
            1,
            math.min(
                #playlist.items + 1,
                new_index + 1
            )
        )

    table.insert(
        playlist.items,
        destination,
        track
    )

    return true
end

local function set_favorite(
    library,
    item_id,
    favorite,
    index
)
    local existing = nil

    for position, track in ipairs(
        library.favorites.items
    ) do
        if track.id == item_id then
            existing = position
            break
        end
    end

    if favorite then
        if not existing then
            local track =
                placeholder_track(
                    item_id,
                    index
                )

            track.favorite = true

            table.insert(
                library.favorites.items,
                track
            )
        else
            library.favorites.items[
                existing
            ].favorite = true
        end
    elseif existing then
        table.remove(
            library.favorites.items,
            existing
        )
    end
end

function M.apply(
    canonical,
    snapshot
)
    local library =
        copy_value(
            canonical or
            sync_library_cache.empty()
        )

    snapshot = snapshot or {
        operations = {},
        playlist_aliases = {},
    }

    snapshot.operations =
        snapshot.operations or {}

    snapshot.playlist_aliases =
        snapshot.playlist_aliases or {}

    local index = track_index(library)

    for _, operation in ipairs(
        snapshot.operations
    ) do
        local data =
            operation.data or {}

        if operation.type ==
            "create_playlist" then
            local playlist =
                ensure_playlist(
                    library,
                    snapshot,
                    data.local_playlist_id,
                    data.name
                )

            playlist.name =
                data.name or playlist.name
            playlist.pending = true
            playlist.local_id =
                data.local_playlist_id

            for item_index, item_id in ipairs(
                data.item_ids or {}
            ) do
                local track =
                    placeholder_track(
                        item_id,
                        index
                    )

                track.playlist_entry_id =
                    "local-entry:" ..
                    operation.id ..
                    ":" ..
                    tostring(item_index)

                table.insert(
                    playlist.items,
                    track
                )
            end
        elseif operation.type ==
            "rename_playlist" then
            local playlist =
                ensure_playlist(
                    library,
                    snapshot,
                    data.playlist_id,
                    data.name
                )

            playlist.name =
                data.name or playlist.name
            playlist.pending = true
        elseif operation.type ==
            "delete_playlist" then
            remove_playlist(
                library,
                snapshot,
                data.playlist_id
            )
        elseif operation.type ==
            "add_playlist_item" then
            local playlist =
                ensure_playlist(
                    library,
                    snapshot,
                    data.playlist_id
                )

            local track =
                placeholder_track(
                    data.item_id,
                    index
                )

            track.playlist_entry_id =
                data.local_entry_id or
                (
                    "local-entry:" ..
                    operation.id
                )

            table.insert(
                playlist.items,
                track
            )

            playlist.pending = true
        elseif operation.type ==
            "remove_playlist_item" then
            local playlist =
                find_playlist(
                    library,
                    snapshot,
                    data.playlist_id
                )

            if playlist then
                remove_entry(
                    playlist,
                    data.entry_id
                )

                playlist.pending = true
            end
        elseif operation.type ==
            "move_playlist_item" then
            local playlist =
                find_playlist(
                    library,
                    snapshot,
                    data.playlist_id
                )

            if playlist then
                move_entry(
                    playlist,
                    data.entry_id,
                    data.new_index or 0
                )

                playlist.pending = true
            end
        elseif operation.type ==
            "set_favorite" then
            set_favorite(
                library,
                data.item_id,
                data.favorite == true,
                index
            )
        end
    end

    normalize_library(library)

    library.pending_changes =
        #snapshot.operations
    library.playlist_aliases =
        copy_value(
            snapshot.playlist_aliases
        )

    return library
end

function M.current()
    local canonical, recovered,
        cache_error, saved_at =
        sync_library_cache.load_or_empty()

    if not canonical then
        return nil, cache_error
    end

    local snapshot, queue_error =
        sync_operation_queue.snapshot()

    if not snapshot then
        return nil, queue_error
    end

    local library =
        M.apply(canonical, snapshot)

    return library, nil, {
        cache_recovered =
            recovered == true,
        cache_saved_at =
            saved_at or 0,
        pending_changes =
            library.pending_changes,
    }
end

return M
