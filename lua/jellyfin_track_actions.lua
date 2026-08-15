local jellyfin_artist_identity =
    require("jellyfin_artist_identity")

local M = {}

local function nonempty(value)
    return type(value) == "string" and
        value ~= ""
end

local function add_action(
    actions,
    id,
    label,
    callback
)
    if type(callback) ~= "function" then
        return
    end

    table.insert(
        actions,
        {
            id = id,
            label = label,
            activate = callback,
        }
    )
end

function M.favorite_state(
    library,
    item_id
)
    if not library or
        not library.favorites then
        return false
    end

    for _, track in ipairs(
        library.favorites.items or {}
    ) do
        if track.id == item_id then
            return true
        end
    end

    return false
end

function M.artist_target(
    track,
    fallback
)
    track = track or {}
    fallback = fallback or {}

    local name =
        (
            nonempty(track.artist) and
            track.artist
        ) or
        (
            nonempty(fallback.artist) and
            fallback.artist
        ) or
        (
            nonempty(fallback.album_artist) and
            fallback.album_artist
        ) or
        nil

    local key, stable =
        jellyfin_artist_identity
            .canonical_key(
                {
                    artist_key =
                        track.artist_key,
                    artist_id =
                        track.artist_id or
                        fallback.artist_id,
                    jellyfin_artist_id =
                        track.jellyfin_artist_id or
                        fallback.jellyfin_artist_id,
                    album_artist_id =
                        track.album_artist_id or
                        fallback.album_artist_id,
                    artist = name,
                    album_artist =
                        fallback.album_artist,
                    name = name,
                }
            )

    -- Without a stable artist id or display name, there is no artist target.
    if not stable and not name then
        return nil
    end

    if not nonempty(key) then
        return nil
    end

    return {
        key = key,
        name = name or "Artist",
    }
end

function M.main(options)
    options = options or {}

    local track = options.track or {}
    local context = options.context or {}
    local handlers = options.handlers or {}
    local actions = {}
    local artist =
        options.artist or
        M.artist_target(
            track,
            options.item
        )

    add_action(
        actions,
        "queue",
        "Queue",
        handlers.open_queue
    )

    add_action(
        actions,
        "shuffle",
        options.shuffle and
            "Disable shuffle" or
            "Enable shuffle",
        handlers.toggle_shuffle
    )

    if artist and
        type(handlers.open_artist) ==
            "function" then
        add_action(
            actions,
            "artist",
            "Go to artist",
            function()
                handlers.open_artist(
                    artist
                )
            end
        )
    end

    add_action(
        actions,
        "favorite",
        options.favorite and
            "Remove favorite" or
            "Add favorite",
        handlers.toggle_favorite
    )

    add_action(
        actions,
        "add_to_playlist",
        "Add to playlist",
        handlers.show_playlists
    )

    if context.collection_kind ==
            "playlist" then
        add_action(
            actions,
            "remove_from_playlist",
            "Remove from playlist",
            handlers.remove_from_playlist
        )
    end

    return actions
end

return M
