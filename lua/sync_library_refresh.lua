local device_identity = require("device_identity")
local json = require("json")
local sync_client = require("sync_client")
local sync_library_cache =
    require("sync_library_cache")

local M = {}

local owner = "sync_library_refresh"
local page_limit = 500
local session = nil
local last_result = nil

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

local function decode_body(body)
    if type(body) ~= "string" or
        body == "" then
        return nil,
            "server returned an empty response"
    end

    local ok, payload =
        pcall(json.decode, body)

    if not ok or type(payload) ~= "table" then
        return nil,
            "server returned invalid JSON"
    end

    return payload
end

local function fail(
    message,
    status
)
    local result = {
        ok = false,
        error = message,
        status = status,
    }

    session = nil
    last_result = result

    return result
end

local function response_error(
    response,
    payload,
    fallback
)
    return payload and payload.error
        or response.error
        or fallback
        or (
            "HTTP status " ..
            tostring(response.status)
        )
end

local function validate_summary(summary)
    if type(summary.revision) ~= "string" or
        type(summary.user) ~= "table" or
        type(summary.user.id) ~= "string" or
        type(summary.user.name) ~= "string" or
        type(summary.favorites) ~= "table" or
        type(summary.favorites.revision)
            ~= "string" or
        type(summary.playlists) ~= "table" then
        return nil,
            "library summary is invalid"
    end

    for _, playlist in ipairs(
        summary.playlists
    ) do
        if type(playlist) ~= "table" or
            type(playlist.id) ~= "string" or
            playlist.id == "" or
            type(playlist.name) ~= "string" or
            type(playlist.revision)
                ~= "string" then
            return nil,
                "library playlist summary is invalid"
        end
    end

    return summary
end

local function cached_playlist(
    cached,
    playlist_id
)
    if type(cached) ~= "table" or
        type(cached.playlists) ~= "table" then
        return nil
    end

    for _, playlist in ipairs(
        cached.playlists
    ) do
        if playlist.id == playlist_id then
            return playlist
        end
    end

    return nil
end

local function collection_metadata(
    summary
)
    return {
        name = summary.name or "",
        revision = summary.revision,
        track_count =
            tonumber(summary.track_count)
            or 0,
        keep_downloaded =
            summary.keep_downloaded == true,
        artwork_item_id =
            type(summary.artwork_item_id) ==
                "string" and
            summary.artwork_item_id or "",
        artwork_tag =
            type(summary.artwork_tag) ==
                "string" and
            summary.artwork_tag or "",
        artwork = nil,
        items = {},
    }
end

local function prepare_library(
    summary,
    cached
)
    local library = {
        revision = summary.revision,
        generated_at =
            tonumber(summary.generated_at)
            or 0,
        user = copy_value(summary.user),
        favorites =
            collection_metadata(
                summary.favorites
            ),
        playlists = {},
    }

    local jobs = {}
    local reused = 0

    if type(cached) == "table" and
        type(cached.favorites) == "table" and
        cached.favorites.revision ==
            summary.favorites.revision then
        library.favorites.items =
            copy_value(
                cached.favorites.items or {}
            )

        if cached.favorites.artwork_tag ==
                library.favorites
                    .artwork_tag then
            library.favorites.artwork =
                copy_value(
                    cached.favorites
                        .artwork
                )
        end

        reused = reused + 1
    else
        table.insert(jobs, {
            kind = "favorites",
            revision =
                summary.favorites.revision,
            track_count =
                library.favorites.track_count,
            start = 0,
            items = {},
        })
    end

    for _, playlist_summary in ipairs(
        summary.playlists
    ) do
        local playlist =
            collection_metadata(
                playlist_summary
            )

        playlist.id =
            playlist_summary.id

        local previous =
            cached_playlist(
                cached,
                playlist.id
            )

        if previous and
            previous.revision ==
                playlist.revision then
            playlist.items =
                copy_value(
                    previous.items or {}
                )

            if previous.artwork_tag ==
                    playlist.artwork_tag then
                playlist.artwork =
                    copy_value(
                        previous.artwork
                    )
            end

            reused = reused + 1
        else
            table.insert(jobs, {
                kind = "playlist",
                playlist_id =
                    playlist.id,
                revision =
                    playlist.revision,
                track_count =
                    playlist.track_count,
                start = 0,
                items = {},
            })
        end

        table.insert(
            library.playlists,
            playlist
        )
    end

    return library, jobs, reused
end

local function playlist_by_id(
    library,
    playlist_id
)
    for _, playlist in ipairs(
        library.playlists
    ) do
        if playlist.id == playlist_id then
            return playlist
        end
    end

    return nil
end

local function request_path(path)
    local started, start_error =
        sync_client.get(path, owner)

    if not started then
        return false, start_error
    end

    return true
end

local function request_summary(kind)
    local path, path_error =
        device_identity.library_path()

    if not path then
        return false, path_error
    end

    session.request_kind = kind

    return request_path(path)
end

local function request_job(job)
    local path, path_error = nil, nil

    if job.kind == "favorites" then
        path, path_error =
            device_identity
                .favorite_items_path(
                    job.start,
                    page_limit
                )
    else
        path, path_error =
            device_identity
                .playlist_items_path(
                    job.playlist_id,
                    job.start,
                    page_limit
                )
    end

    if not path then
        return false, path_error
    end

    session.request_kind = "collection"

    return request_path(path)
end

local function finish_success()
    local saved, save_error =
        sync_library_cache.save(
            session.library
        )

    if not saved then
        return fail(save_error)
    end

    local result = {
        ok = true,
        status = 200,
        library =
            copy_value(session.library),
        fetched_collections =
            session.fetched_collections,
        reused_collections =
            session.reused_collections,
    }

    session = nil
    last_result = result

    return result
end

local function request_next()
    local job =
        session.jobs[
            session.job_index
        ]

    if job then
        local started, start_error =
            request_job(job)

        if not started then
            return fail(start_error)
        end

        return nil
    end

    local started, start_error =
        request_summary("verify")

    if not started then
        return fail(start_error)
    end

    return nil
end

local function accept_summary(
    payload,
    verification
)
    local summary, validation_error =
        validate_summary(payload)

    if not summary then
        return fail(validation_error)
    end

    if verification then
        if summary.revision ~=
            session.summary.revision then
            return fail(
                "Jellyfin library changed during refresh"
            )
        end

        return finish_success()
    end

    local cached =
        sync_library_cache.load_or_empty()

    local library, jobs, reused =
        prepare_library(
            summary,
            cached
        )

    session.summary =
        copy_value(summary)
    session.library = library
    session.jobs = jobs
    session.job_index = 1
    session.reused_collections = reused
    session.fetched_collections = 0

    return request_next()
end

local function accept_collection(payload)
    local job =
        session.jobs[
            session.job_index
        ]

    if not job then
        return fail(
            "library refresh lost its active collection"
        )
    end

    local payload_revision =
        payload.revision

    if job.kind == "playlist" then
        if type(payload.playlist) ~= "table" or
            payload.playlist.id ~=
                job.playlist_id then
            return fail(
                "Jellyfin returned the wrong playlist"
            )
        end

        payload_revision =
            payload.playlist.revision
    end

    if type(payload_revision) ~= "string" or
        payload_revision ~= job.revision or
        type(payload.items) ~= "table" then
        return fail(
            "Jellyfin collection changed during refresh"
        )
    end

    for _, item in ipairs(payload.items) do
        if type(item) ~= "table" or
            type(item.id) ~= "string" or
            item.id == "" then
            return fail(
                "Jellyfin returned an invalid track"
            )
        end

        table.insert(
            job.items,
            copy_value(item)
        )
    end

    local expected =
        tonumber(payload.total)
        or job.track_count

    if #job.items < expected then
        local next_start =
            tonumber(payload.next_start)

        if not next_start or
            next_start <= job.start then
            return fail(
                "Jellyfin returned invalid pagination"
            )
        end

        job.start = next_start

        local started, start_error =
            request_job(job)

        if not started then
            return fail(start_error)
        end

        return nil
    end

    if #job.items ~= expected or
        #job.items ~= job.track_count then
        return fail(
            "Jellyfin collection count changed during refresh"
        )
    end

    if job.kind == "favorites" then
        session.library.favorites.items =
            job.items
    else
        local playlist =
            playlist_by_id(
                session.library,
                job.playlist_id
            )

        if not playlist then
            return fail(
                "library refresh lost a playlist"
            )
        end

        playlist.items = job.items
    end

    session.fetched_collections =
        session.fetched_collections + 1
    session.job_index =
        session.job_index + 1

    return request_next()
end

function M.start()
    if session or
        sync_client.busy(owner) then
        return false,
            "library refresh is already active"
    end

    if sync_client.busy() then
        return false,
            "HTTP request already in progress"
    end

    session = {
        request_kind = nil,
        summary = nil,
        library = nil,
        jobs = {},
        job_index = 1,
        fetched_collections = 0,
        reused_collections = 0,
    }

    local started, start_error =
        request_summary("summary")

    if not started then
        session = nil
        return false, start_error
    end

    last_result = nil

    return true
end

function M.busy()
    return session ~= nil or
        sync_client.busy(owner)
end

function M.poll()
    if not session then
        return nil
    end

    local response =
        sync_client.poll(owner)

    if response == nil then
        return nil
    end

    local payload, decode_error =
        decode_body(response.body)

    if not response.ok then
        return fail(
            response_error(
                response,
                payload,
                decode_error
            ),
            response.status
        )
    end

    if not payload then
        return fail(
            decode_error,
            response.status
        )
    end

    if session.request_kind ==
        "summary" then
        return accept_summary(
            payload,
            false
        )
    end

    if session.request_kind ==
        "verify" then
        return accept_summary(
            payload,
            true
        )
    end

    if session.request_kind ==
        "collection" then
        return accept_collection(payload)
    end

    return fail(
        "library refresh response had no request type",
        response.status
    )
end

function M.progress()
    if not session then
        return nil
    end

    return {
        busy = true,
        collection_index =
            session.job_index,
        collection_total =
            #session.jobs,
        fetched_collections =
            session.fetched_collections,
        reused_collections =
            session.reused_collections,
        request_kind =
            session.request_kind,
    }
end

function M.last_result()
    return last_result
end

return M
