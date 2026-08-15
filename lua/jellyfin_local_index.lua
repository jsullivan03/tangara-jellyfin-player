local device = require("device")
local jellyfin_artist_identity =
    require("jellyfin_artist_identity")
local jellyfin_album_identity =
    require("jellyfin_album_identity")
local jellyfin_track_identity =
    require("jellyfin_track_identity")
local sync_manifest_cache =
    require("sync_manifest_cache")
local index_generation =
    require("jellyfin_local_index_generation")

local M = {}

local cached_generation = -1
local cached_root = nil
local cached_library = nil
local cached_error = nil
local cache_hits = 0
local cache_builds = 0
local cache_file_checks = 0

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
    if value == nil then
        return fallback or ""
    end

    if type(value) == "number" then
        value = tostring(value)
    end

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

    local left_title =
        normalized_key(left.title)
    local right_title =
        normalized_key(right.title)

    if left_title ~= right_title then
        return left_title < right_title
    end

    return normalized_key(
        left.jellyfin_id or left.id
    ) <
        normalized_key(
            right.jellyfin_id or right.id
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
        jellyfin_track_identity.stable_id(
            item
        ) or
        normalized_text(
            item.jellyfin_id,
            item.id
        )

    if jellyfin_id == nil or
        jellyfin_id == "" then
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
        jellyfin_album_identity.album_id(
            {
                kind = "track",
                album_id = item.album_id,
                parent_id = item.parent_id,
                jellyfin_album_id =
                    item.jellyfin_album_id,
            }
        ) or ""

    local album_artist_id =
        jellyfin_artist_identity
            .album_artist_id(item) or ""
    local artist_id =
        jellyfin_artist_identity
            .canonical_id(
                item.artist_id or
                item.jellyfin_artist_id
            ) or
        album_artist_id or
        ""

    local album_key =
        jellyfin_album_identity
            .track_album_key(
                {
                    kind = "track",
                    album_id =
                        album_id ~= "" and
                        album_id or nil,
                    album = album,
                    artist = artist,
                    album_artist =
                        item.album_artist,
                }
            )

    local artist_key =
        jellyfin_artist_identity
            .canonical_key(
                {
                    artist_id = artist_id,
                    album_artist_id =
                        album_artist_id,
                    artist = artist,
                }
            )

    local track_key =
        jellyfin_track_identity.key(
            {
                jellyfin_id = jellyfin_id,
                id = jellyfin_id,
                album_key = album_key,
                album_id =
                    album_id ~= "" and
                    album_id or nil,
                album = album,
                artist = artist,
                title = item.title,
                disc = item.disc or
                    item.disc_number,
                track = item.track or
                    item.track_number or
                    item.IndexNumber,
            }
        )

    return {
        id = jellyfin_id,
        jellyfin_id = jellyfin_id,
        -- Canonical track key lives beside bare media ids so list selection
        -- (which prefers `key`) keeps using bare Jellyfin ids for resume.
        track_key = track_key,
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
        album_artist_id =
            album_artist_id,
        artist_key = artist_key,
        duration =
            tonumber(
                item.duration
            ) or 0,
        -- Local New/Old is based on when the item became available on this
        -- device. New downloads carry local_added_at in the durable manifest.
        -- Older manifests fall back to their existing date so migration stays
        -- stable instead of reshuffling on every boot.
        local_added_at =
            normalized_text(
                item.local_added_at or
                item.downloaded_at,
                normalized_text(
                    item.date_created,
                    ""
                )
            ),
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
                        jellyfin_id =
                            track.album_id ~=
                                "" and
                            track.album_id or
                            nil,
                        name =
                            track.album,
                        artist =
                            track.artist,
                        artist_key =
                            track.artist_key,
                        tracks = {},
                        track_count = 0,
                        local_added_at =
                            track.local_added_at,
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

                album.local_added_at =
                    newest_date(
                        album.local_added_at,
                        track.local_added_at
                    )

                album.date_created =
                    newest_date(
                        album.date_created,
                        track.date_created
                    )

                table.insert(
                    album.tracks,
                    track
                )
            end
        end
    end

    local function resolve_album_artist(album)
        local album_artist_id = nil
        local votes = {}
        local preferred_name =
            album.artist or
            "Unknown Artist"

        for _, track in ipairs(
            album.tracks or {}
        ) do
            local track_album_artist_id =
                jellyfin_artist_identity
                    .canonical_id(
                        track.album_artist_id
                    )

            if track_album_artist_id and
                not album_artist_id then
                album_artist_id =
                    track_album_artist_id
            end

            local track_artist_id =
                jellyfin_artist_identity
                    .canonical_id(
                        track.artist_id
                    )

            if track_artist_id then
                local vote =
                    votes[track_artist_id]

                if not vote then
                    vote = {
                        count = 0,
                        name =
                            track.artist or
                            preferred_name,
                    }
                    votes[track_artist_id] =
                        vote
                end

                vote.count = vote.count + 1

                if type(track.artist) ==
                        "string" and
                    track.artist ~= "" then
                    vote.name = track.artist
                end
            elseif type(track.artist) ==
                    "string" and
                track.artist ~= "" then
                preferred_name = track.artist
            end
        end

        local majority_id = nil
        local majority_count = 0
        local majority_name = preferred_name

        for artist_id, vote in pairs(
            votes
        ) do
            if vote.count >
                    majority_count then
                majority_id = artist_id
                majority_count = vote.count
                majority_name = vote.name
            end
        end

        local resolved_id =
            album_artist_id or
            majority_id
        local resolved_name =
            majority_name or
            preferred_name
        local artist_key,
            stable_id =
            jellyfin_artist_identity
                .canonical_key(
                    {
                        artist_id =
                            resolved_id,
                        artist =
                            resolved_name,
                    }
                )

        album.artist = resolved_name
        album.artist_id =
            stable_id or ""
        album.artist_key = artist_key

        return artist_key, stable_id, resolved_name
    end

    local function ensure_artist(
        artist_key,
        stable_id,
        name,
        seed
    )
        local artist =
            artists_by_key[artist_key]

        if artist then
            return artist
        end

        artist = {
            key = artist_key,
            id = stable_id or "",
            jellyfin_id =
                stable_id or nil,
            name = name,
            releases_by_key = {},
            releases = {},
            track_count = 0,
            release_count = 0,
            local_added_at =
                seed and
                seed.local_added_at or
                "",
            date_created =
                seed and
                seed.date_created or
                "",
        }

        artists_by_key[artist_key] =
            artist

        return artist
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

        local artist_key,
            stable_id,
            resolved_name =
            resolve_album_artist(album)

        local artist =
            ensure_artist(
                artist_key,
                stable_id,
                resolved_name,
                album
            )

        artist.track_count =
            artist.track_count +
            album.track_count
        artist.local_added_at =
            newest_date(
                artist.local_added_at,
                album.local_added_at
            )
        artist.date_created =
            newest_date(
                artist.date_created,
                album.date_created
            )
        artist.releases_by_key[
            album.key
        ] = album

        table.insert(
            albums,
            album
        )
    end

    table.sort(
        albums,
        release_sort
    )

    -- Coalesce incomplete name: fallbacks into a unique stable-ID artist with
    -- the same display name. Distinct stable IDs that share a name stay apart.
    local id_artist_by_name = {}

    for key, artist in pairs(
        artists_by_key
    ) do
        if key:sub(1, 3) == "id:" then
            local name_key =
                jellyfin_artist_identity
                    .normalize_name(
                        artist.name
                    )
            local existing =
                id_artist_by_name[name_key]

            if existing == nil then
                id_artist_by_name[name_key] =
                    artist
            else
                -- Multiple stable IDs share this display name; do not merge
                -- name-fallback rows into either of them by name alone.
                id_artist_by_name[name_key] =
                    false
            end
        end
    end

    for key, artist in pairs(
        artists_by_key
    ) do
        if key:sub(1, 5) == "name:" then
            local name_key =
                jellyfin_artist_identity
                    .normalize_name(
                        artist.name
                    )
            local target =
                id_artist_by_name[name_key]

            if type(target) == "table" then
                for album_key, album in pairs(
                    artist.releases_by_key or {}
                ) do
                    target.releases_by_key[
                        album_key
                    ] = album
                    album.artist_key =
                        target.key
                    album.artist_id =
                        target.id or ""
                    album.artist =
                        target.name
                end

                target.track_count =
                    target.track_count +
                    artist.track_count
                target.local_added_at =
                    newest_date(
                        target.local_added_at,
                        artist.local_added_at
                    )
                target.date_created =
                    newest_date(
                        target.date_created,
                        artist.date_created
                    )
                artists_by_key[key] = nil
            end
        end
    end

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

local function clear_cache()
    cached_generation = -1
    cached_root = nil
    cached_library = nil
    cached_error = nil
end

function M.invalidate(reason)
    clear_cache()

    return index_generation.invalidate(reason)
end

function M.cache_stats()
    local generation =
        index_generation.snapshot()

    return {
        hits = cache_hits,
        builds = cache_builds,
        file_checks = cache_file_checks,
        generation = generation.generation,
        last_invalidation =
            generation.last_reason,
        cached =
            cached_generation ==
                generation.generation,
        cached_root = cached_root,
    }
end

function M.load()
    local generation =
        index_generation.current()

    local root, root_error =
        device.storage_root()

    if type(root) ~= "string" or
        root == "" then
        return nil,
            root_error or
            "storage root is unavailable"
    end

    root = root:gsub("/+$", "")

    if cached_generation == generation and
        cached_root == root then
        cache_hits = cache_hits + 1

        return cached_library,
            cached_error
    end

    clear_cache()

    local manifest, manifest_error =
        sync_manifest_cache.load()

    local library
    local library_error

    if manifest then
        library, library_error =
            M.from_manifest(
                manifest,
                root,
                function(path)
                    cache_file_checks =
                        cache_file_checks + 1

                    return file_exists(path)
                end
            )
    else
        library_error =
            manifest_error or
            "download manifest is unavailable"
    end

    cache_builds = cache_builds + 1
    cached_generation = generation
    cached_root = root
    cached_library = library
    cached_error = library_error

    return cached_library,
        cached_error
end

return M
