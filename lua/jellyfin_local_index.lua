local device = require("device")
local sync_manifest_cache =
    require("sync_manifest_cache")

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

local function normalized_text(
    value,
    fallback
)
    if type(value) == "string" and
        value ~= "" then
        return value
    end

    return fallback or ""
end

local function normalized_key(value)
    return normalized_text(
        value,
        ""
    ):lower()
end

local function newest_date(left, right)
    left = type(left) == "string" and left or ""
    right = type(right) == "string" and right or ""

    if left == "" then
        return right
    end

    if right == "" then
        return left
    end

    if right > left then
        return right
    end

    return left
end

local function file_exists(path)
    local file = io.open(path, "rb")

    if not file then
        return false
    end

    file:close()
    return true
end

local function item_ready(item)
    local state = item.sync_state

    return state == nil or
        state == "" or
        state == "ready" or
        state == "downloaded" or
        state == "complete"
end

local function track_sort(left, right)
    local left_disc =
        tonumber(
            left.disc_number
        ) or 0

    local right_disc =
        tonumber(
            right.disc_number
        ) or 0

    if left_disc ~= right_disc then
        return left_disc <
            right_disc
    end

    local left_track =
        tonumber(
            left.track_number
        ) or 0

    local right_track =
        tonumber(
            right.track_number
        ) or 0

    if left_track ~= right_track and
        (
            left_track > 0 or
            right_track > 0
        ) then
        if left_track == 0 then
            return false
        end

        if right_track == 0 then
            return true
        end

        return left_track <
            right_track
    end

    return normalized_key(
        left.title
    ) <
        normalized_key(
            right.title
        )
end

local function release_sort(left, right)
    local left_name =
        normalized_key(
            left.name
        )

    local right_name =
        normalized_key(
            right.name
        )

    if left_name ~= right_name then
        return left_name <
            right_name
    end

    return normalized_key(
        left.artist
    ) <
        normalized_key(
            right.artist
        )
end

local function artist_sort(left, right)
    return normalized_key(
        left.name
    ) <
        normalized_key(
            right.name
        )
end

local function track_from_item(item)
    local jellyfin_id =
        normalized_text(
            item.jellyfin_id,
            item.id
        )

    if jellyfin_id == "" then
        return nil
    end

    local artist =
        normalized_text(
            item.artist,
            item.album_artist
        )

    if artist == "" then
        artist = "Unknown Artist"
    end

    local album =
        normalized_text(
            item.album,
            "Unknown Album"
        )

    local album_id =
        normalized_text(
            item.album_id,
            item.parent_id
        )

    local artist_id =
        normalized_text(
            item.artist_id,
            item.album_artist_id
        )

    local album_key

    if album_id ~= "" then
        album_key =
            "id:" .. album_id
    else
        album_key =
            "name:" ..
            normalized_key(artist) ..
            "\0" ..
            normalized_key(album)
    end

    local artist_key

    if artist_id ~= "" then
        artist_key =
            "id:" .. artist_id
    else
        artist_key =
            "name:" ..
            normalized_key(artist)
    end

    return {
        id = jellyfin_id,
        jellyfin_id = jellyfin_id,
        title =
            normalized_text(
                item.title,
                "Unknown Track"
            ),
        artist = artist,
        album = album,
        album_id = album_id,
        album_key = album_key,
        artist_id = artist_id,
        artist_key = artist_key,
        duration =
            tonumber(
                item.duration
            ) or 0,
        date_created =
            normalized_text(
                item.date_created,
                ""
            ),
        disc_number =
            tonumber(
                item.disc_number or
                item.parent_index_number
            ) or 0,
        track_number =
            tonumber(
                item.track_number or
                item.index_number
            ) or 0,
        local_path = item.local_path,
        sync_state = item.sync_state,
        artwork =
            copy_value(
                item.artwork
            ),
        source_item =
            copy_value(item),
    }
end

function M.from_manifest(
    manifest,
    root,
    exists
)
    if type(manifest) ~= "table" or
        type(manifest.items) ~=
            "table" then
        return nil,
            "download manifest is unavailable"
    end

    if type(root) ~= "string" or
        root == "" then
        return nil,
            "storage root is unavailable"
    end

    root = root:gsub("/+$", "")
    exists = exists or file_exists

    local tracks = {}
    local seen_tracks = {}
    local albums_by_key = {}
    local artists_by_key = {}

    for _, item in ipairs(
        manifest.items
    ) do
        if type(item) == "table" and
            item_ready(item) and
            type(item.local_path) ==
                "string" and
            item.local_path:sub(1, 1) ==
                "/" and
            exists(
                root .. item.local_path
            ) then
            local track =
                track_from_item(item)

            if track and
                type(track.artwork) ==
                    "table" then
                local thumbnail =
                    track.artwork
                        .thumbnail

                if type(thumbnail) ==
                        "string" and
                    thumbnail:sub(1, 1) ==
                        "/" and
                    thumbnail:sub(1, 2) ~=
                        "//" then
                    local full_thumbnail =
                        root .. thumbnail

                    if not exists(
                        full_thumbnail
                    ) then
                        track.artwork
                            .thumbnail = nil
                    elseif root:match(
                        "^desktop%-sim/"
                    ) then
                        track.artwork
                            .thumbnail =
                            "/" ..
                            full_thumbnail
                    end
                end
            end

            if track and
                not seen_tracks[
                    track.id
                ] then
                seen_tracks[
                    track.id
                ] = true

                table.insert(
                    tracks,
                    track
                )

                local album =
                    albums_by_key[
                        track.album_key
                    ]

                if not album then
                    album = {
                        key =
                            track.album_key,
                        id =
                            track.album_id,
                        name =
                            track.album,
                        artist =
                            track.artist,
                        artist_key =
                            track.artist_key,
                        tracks = {},
                        track_count = 0,
                        date_created =
                            track.date_created,
                        artwork =
                            copy_value(
                                track.artwork
                            ),
                    }

                    albums_by_key[
                        track.album_key
                    ] = album
                elseif (
                    not album.artwork or
                    not album.artwork.cover
                ) and
                    track.artwork then
                    album.artwork =
                        copy_value(
                            track.artwork
                        )
                end

                album.date_created =
                    newest_date(
                        album.date_created,
                        track.date_created
                    )

                table.insert(
                    album.tracks,
                    track
                )

                local artist =
                    artists_by_key[
                        track.artist_key
                    ]

                if not artist then
                    artist = {
                        key =
                            track.artist_key,
                        id =
                            track.artist_id,
                        name =
                            track.artist,
                        releases_by_key =
                            {},
                        releases = {},
                        track_count = 0,
                        release_count = 0,
                        date_created =
                            track.date_created,
                    }

                    artists_by_key[
                        track.artist_key
                    ] = artist
                end

                artist.track_count =
                    artist.track_count + 1

                artist.date_created =
                    newest_date(
                        artist.date_created,
                        track.date_created
                    )

                artist.releases_by_key[
                    track.album_key
                ] = album
            end
        end
    end

    local albums = {}

    for _, album in pairs(
        albums_by_key
    ) do
        table.sort(
            album.tracks,
            track_sort
        )

        album.track_count =
            #album.tracks

        table.insert(
            albums,
            album
        )
    end

    table.sort(
        albums,
        release_sort
    )

    local artists = {}

    for _, artist in pairs(
        artists_by_key
    ) do
        for _, album in pairs(
            artist.releases_by_key
        ) do
            table.insert(
                artist.releases,
                album
            )
        end

        table.sort(
            artist.releases,
            release_sort
        )

        artist.release_count =
            #artist.releases
        artist.releases_by_key = nil

        table.insert(
            artists,
            artist
        )
    end

    table.sort(
        artists,
        artist_sort
    )

    table.sort(
        tracks,
        function(left, right)
            local left_title =
                normalized_key(
                    left.title
                )

            local right_title =
                normalized_key(
                    right.title
                )

            if left_title ~=
                right_title then
                return left_title <
                    right_title
            end

            return normalized_key(
                left.artist
            ) <
                normalized_key(
                    right.artist
                )
        end
    )

    return {
        artists = artists,
        albums = albums,
        tracks = tracks,
        counts = {
            artists = #artists,
            albums = #albums,
            tracks = #tracks,
        },
    }
end

function M.load()
    local manifest, manifest_error =
        sync_manifest_cache.load()

    if not manifest then
        return nil,
            manifest_error or
            "download manifest is unavailable"
    end

    local root, root_error =
        device.storage_root()

    if type(root) ~= "string" or
        root == "" then
        return nil,
            root_error or
            "storage root is unavailable"
    end

    return M.from_manifest(
        manifest,
        root,
        file_exists
    )
end

return M
