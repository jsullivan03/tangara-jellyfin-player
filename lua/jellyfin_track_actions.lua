local M = {}

local function nonempty(value)
    return type(value) == "string" and
        value ~= ""
end

local function normalized_name(value)
    if not nonempty(value) then
        return nil
    end

    return value
end

local function normalized_key(value)
    local name = normalized_name(value)

    if not name then
        return nil
    end

    return "name:" .. name:lower()
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
        normalized_name(track.artist) or
        normalized_name(fallback.artist) or
        normalized_name(
            fallback.album_artist
        )

    local key = track.artist_key

    if not nonempty(key) then
        local artist_id =
            normalized_name(
                track.artist_id
            ) or
            normalized_name(
                fallback.artist_id
            ) or
            normalized_name(
                fallback.album_artist_id
            )

        if artist_id then
            key = "id:" .. artist_id
        else
            key = normalized_key(name)
        end
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
