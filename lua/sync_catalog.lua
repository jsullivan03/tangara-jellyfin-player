local device_identity =
    require("device_identity")
local jellyfin_artist_identity =
    require("jellyfin_artist_identity")
local json = require("json")
local json_encode = require("json_encode")
local sync_client = require("sync_client")
local time = require("time")

local M = {}

local owner = "sync_catalog"
local request_kind = nil
local request_view = nil
local request_cursor = nil
local request_item = nil
local request_key = nil
local request_generation = nil
local request_callback = nil
local cache = {}
local last_error = nil
local search_generation = 0
local current_search = nil
local pending_search = nil
local expected_catalog_generations = {}

local function decoded_body(response)
    local ok, payload =
        pcall(
            json.decode,
            response.body or ""
        )

    if ok and type(payload) == "table" then
        return payload
    end

    return nil
end

local function decode(response)
    if not response.ok then
        local payload = decoded_body(response)
        local status = tonumber(response.status)

        if status == 404 then
            return nil,
                "Sync catalog is unavailable on this companion server"
        end

        return nil,
            (
                payload and payload.error
            ) or
            response.error or
            (
                "HTTP status " ..
                tostring(response.status)
            )
    end

    local payload = decoded_body(response)

    if not payload then
        return nil,
            "server returned invalid JSON"
    end

    return payload
end

function M.start(
    view,
    cursor,
    limit,
    options
)
    if request_kind or
        sync_client.busy() then
        return false,
            "sync request is already active"
    end

    options = options or {}

    local path, path_error =
        device_identity.catalog_path(
            view,
            cursor,
            limit or 20,
            options
        )

    if not path then
        return false, path_error
    end

    local started, start_error =
        sync_client.get(path, owner)

    if not started then
        return false, start_error
    end

    request_kind = "catalog"
    request_view = view
    request_cursor = cursor
    request_item = nil
    request_key =
        options.cache_key or view
    request_generation =
        options.generation
    request_callback = nil
    last_error = nil

    return true
end

function M.next_generation(key)
    key = tostring(key or "")
    local generation =
        (
            expected_catalog_generations[
                key
            ] or 0
        ) + 1
    expected_catalog_generations[key] =
        generation
    return generation
end

local function start_request(
    kind,
    path,
    body,
    key,
    item,
    path_error,
    callback
)
    if request_kind or
        sync_client.busy() then
        return false,
            "sync request is already active"
    end

    if not path then
        return false, path_error
    end

    local started, start_error

    if body == nil then
        started, start_error =
            sync_client.get(path, owner)
    else
        started, start_error =
            sync_client.post(
                path,
                json_encode.encode(body),
                owner
            )
    end

    if not started then
        return false, start_error
    end

    request_kind = kind
    request_view = nil
    request_cursor = nil
    request_item = item
    request_key = key
    request_generation = nil
    request_callback =
        type(callback) == "function" and
        callback or nil
    last_error = nil
    return true
end

local function search_body(context)
    return {
        query = context.query,
        kinds = context.kinds,
        sort = context.sort,
    }
end

local function start_search_phase(
    context,
    phase
)
    local path, path_error
    if phase == "jellyfin" then
        path, path_error =
            device_identity
                .jellyfin_search_path()
    else
        path, path_error =
            device_identity
                .external_search_path()
    end

    return start_request(
        "search_" .. phase,
        path,
        search_body(context),
        context.key,
        context,
        path_error
    )
end

local function stable_item_id(item)
    return tostring(
        item.jellyfin_id or
        item.key or
        item.id or ""
    )
end

local function normalized_identity(value)
    return tostring(value or "")
        :lower()
        :gsub("%s+", " ")
        :match("^%s*(.-)%s*$")
end

local function value_set(values)
    local result = {}
    for _, value in ipairs(values or {}) do
        local normalized =
            normalized_identity(value)
        if normalized ~= "" then
            result[normalized] = true
        end
    end
    return result
end

local function item_artist_names(item)
    local values = {
        item.artist,
    }
    for _, value in ipairs(
        item.artists or {}
    ) do
        values[#values + 1] = value
    end
    return value_set(values)
end

local function item_artist_ids(item)
    return value_set(
        item.artist_ids or {}
    )
end

local function overlaps(left, right)
    for value in pairs(left) do
        if right[value] then
            return true
        end
    end
    return false
end

local function years_compatible(
    left,
    right
)
    local left_year = tonumber(left.year)
    local right_year = tonumber(right.year)
    return
        not left_year or
        not right_year or
        left_year == right_year
end

local function exact_identity_match(
    left,
    right
)
    if left.kind ~= right.kind or
        normalized_identity(
            left.title
        ) ~= normalized_identity(
            right.title
        ) or
        normalized_identity(
            left.title
        ) == "" then
        return false
    end

    local left_primary =
        normalized_identity(left.artist)
    local right_primary =
        normalized_identity(right.artist)
    if left_primary ~= "" and
        left_primary == right_primary then
        return true
    end

    if overlaps(
        item_artist_ids(left),
        item_artist_ids(right)
    ) then
        return true
    end

    return overlaps(
        item_artist_names(left),
        item_artist_names(right)
    ) and years_compatible(left, right)
end

local function state_rank(item)
    local state =
        type(item.device) == "table" and
            item.device.state or
        item.state or
        item.availability or
        "available"
    local ranks = {
        downloaded = 1,
        on_device = 1,
        partial = 2,
        server_only = 3,
        queued = 4,
        downloading = 4,
        importing = 4,
        external_queued = 4,
        external_downloading = 4,
        jellyfin_importing = 4,
        failed = 4,
        available = 5,
    }
    return ranks[state] or 4
end

local function merge_canonical(
    existing,
    incoming
)
    local jellyfin =
        existing.jellyfin_id and
            (
                incoming.jellyfin_id and
                type(existing.device) ~=
                    "table" and
                type(incoming.device) ==
                    "table" and
                incoming or
                existing
            ) or
        (
            incoming.jellyfin_id and
                incoming or nil
        )
    local external =
        jellyfin == incoming and
            existing or incoming
    local external_key =
        external.key or
        external.external_key or
        external.external_item_key

    if jellyfin == incoming then
        local external_artwork_path =
            existing.artwork_path
        local external_artwork_revision =
            existing.artwork_revision
        for key, value in pairs(incoming) do
            existing[key] = value
        end
        if (
            type(existing.artwork_path) ~=
                "string" or
            existing.artwork_path == ""
        ) and
            type(external_artwork_path) ==
                "string" and
            external_artwork_path ~= "" then
            existing.artwork_path =
                external_artwork_path
            existing.artwork_revision =
                external_artwork_revision
            existing.artwork_source =
                "external"
        end
    elseif (
        type(existing.artwork_path) ~=
            "string" or
        existing.artwork_path == ""
    ) and
        type(incoming.artwork_path) ==
            "string" and
        incoming.artwork_path ~= "" then
        existing.artwork_path =
            incoming.artwork_path
        existing.artwork_revision =
            incoming.artwork_revision
        existing.artwork_source =
            "external"
    end

    if external_key then
        existing.external_key =
            external_key
        existing.external_item_key =
            external_key
    end
    if not existing.artist_key and
        incoming.artist_key then
        existing.artist_key =
            incoming.artist_key
    end
    if not existing.jellyfin_artist_id and
        incoming.jellyfin_artist_id then
        existing.jellyfin_artist_id =
            incoming
                .jellyfin_artist_id
    end

    if state_rank(incoming) <
            state_rank(existing) and
        not incoming.jellyfin_id then
        existing.state = incoming.state
        existing.availability =
            incoming.availability
    end

    return existing
end

local function merge_external(
    jellyfin_payload,
    external_payload
)
    local merged = {}
    local by_jellyfin = {}
    local by_key = {}
    local candidates = {}

    for _, item in ipairs(
        jellyfin_payload.items or {}
    ) do
        merged[#merged + 1] = item
        if item.jellyfin_id then
            by_jellyfin[
                tostring(
                    item.jellyfin_id
                )
            ] = item
        end
        if item.key then
            by_key[tostring(item.key)] =
                item
        end
        candidates[#candidates + 1] =
            item
    end

    local duplicates = 0
    for _, item in ipairs(
        external_payload.items or {}
    ) do
        local existing =
            item.jellyfin_id and
            by_jellyfin[
                tostring(
                    item.jellyfin_id
                )
            ] or
            (
                item.key and
                by_key[
                    tostring(item.key)
                ] or nil
            )

        if not existing then
            local matches = {}
            for _, candidate in ipairs(
                candidates
            ) do
                if exact_identity_match(
                    candidate,
                    item
                ) then
                    matches[#matches + 1] =
                        candidate
                end
            end
            if #matches == 1 then
                existing = matches[1]
            elseif #matches > 1 then
                item.possible_duplicate =
                    true
            end
        end

        if existing then
            duplicates = duplicates + 1
            merge_canonical(
                existing,
                item
            )
        else
            merged[#merged + 1] = item
            candidates[#candidates + 1] =
                item
            local stable =
                stable_item_id(item)
            if stable ~= "" then
                if item.jellyfin_id then
                    by_jellyfin[stable] =
                        item
                else
                    by_key[stable] = item
                end
            end
        end
    end

    jellyfin_payload.items = merged
    jellyfin_payload.external_available =
        external_payload
            .external_available ~= false
    jellyfin_payload.external_message =
        external_payload.external_message
    jellyfin_payload
        .external_search_pending = false
    jellyfin_payload.external_metrics =
        external_payload.metrics
    jellyfin_payload.external_duplicates =
        duplicates

    return jellyfin_payload
end

M._merge_search_payloads_for_test =
    merge_external

function M.search(query, kinds, sort)
    search_generation =
        search_generation + 1
    local context = {
        query = tostring(query),
        kinds = kinds or {
            "album",
            "track",
        },
        sort = sort or "relevance",
        generation = search_generation,
        key =
            "search:" ..
            tostring(query),
    }

    cache[context.key] = nil
    current_search = context

    if request_kind == "search_jellyfin" or
        request_kind == "search_external" then
        pending_search = context
        return true
    end

    if request_kind or
        sync_client.busy() then
        return false,
            "sync request is already active"
    end

    pending_search = nil
    return start_search_phase(
        context,
        "jellyfin"
    )
end

function M.downloads()
    local path, path_error =
        device_identity.downloads_path()

    return start_request(
        "downloads",
        path,
        nil,
        "downloads",
        nil,
        path_error
    )
end

function M.artist_releases(item)
    local key =
        item and
        jellyfin_artist_identity.key(item)
    local stable_artist_id =
        item and
        jellyfin_artist_identity.stable_id(
            item.jellyfin_artist_id or
            (
                type(item.artist_ids) ==
                    "table" and
                item.artist_ids[1]
            ) or
            item.artist_id
        )
    local path, path_error =
        device_identity
            .artist_releases_path(
                key,
                item and item.artist,
                {
                    jellyfin_artist_id =
                        stable_artist_id or
                        (
                            item and
                            (
                                item
                                    .jellyfin_artist_id or
                                (
                                    type(
                                        item
                                            .artist_ids
                                    ) == "table" and
                                    item.artist_ids[1]
                                    or nil
                                )
                            )
                        ),
                    external_item_key =
                        item and
                        (
                            item
                                .external_item_key or
                            (
                                not item.jellyfin_id and
                                item.key or nil
                            )
                        ),
                    jellyfin_id =
                        item and
                        item.jellyfin_id,
                    release_title =
                        item and item.title,
                }
            )

    return start_request(
        "artist",
        path,
        nil,
        "artist:" .. tostring(key),
        item,
        path_error
    )
end

local function normalized(value)
    return tostring(value or ""):lower()
end

local function contains(values, expected)
    for _, value in ipairs(values or {}) do
        if tostring(value) ==
                tostring(expected) then
            return true
        end
    end

    return false
end

function M.local_artist_releases(item)
    local albums = cache.albums
    if type(item) ~= "table" or
        type(albums) ~= "table" or
        type(albums.items) ~= "table" then
        return nil
    end

    local target_id =
        item.jellyfin_artist_id or
        (
            type(item.artist_ids) ==
                "table" and
            item.artist_ids[1] or nil
        )
    local target_name =
        normalized(item.artist)
    local groups = {
        albums = {},
        singles = {},
        features = {},
    }
    local seen = {}

    for _, release in ipairs(
        albums.items
    ) do
        local id_match =
            target_id and
            (
                release.artist_id ==
                    target_id or
                contains(
                    release.artist_ids,
                    target_id
                )
            )
        if id_match then
            local stable_id =
                tostring(
                    release.jellyfin_id or
                    release.key or
                    release.id or ""
                )

            if not seen[stable_id] then
                seen[stable_id] = true
                local group = "albums"
                local release_type =
                    normalized(
                        release.release_type or
                        release.album_type
                    )

                if normalized(
                    release.artist
                ) ~= target_name and
                    id_match then
                    group = "features"
                elseif release_type:
                        find(
                            "single",
                            1,
                            true
                        ) or
                    release_type:
                        find(
                            "ep",
                            1,
                            true
                        ) then
                    group = "singles"
                end

                table.insert(
                    groups[group],
                    release
                )
            end
        end
    end

    local result = {
        groups = {},
        local_only = true,
    }

    for _, group in ipairs {
        "albums",
        "singles",
        "features",
    } do
        if #groups[group] > 0 then
            table.insert(
                result.groups,
                {
                    id = group,
                    items = groups[group],
                }
            )
        end
    end

    if #result.groups == 0 then
        return nil
    end

    return result
end

function M.external_job(
    item,
    destination
)
    local path, path_error =
        device_identity
            .external_jobs_path()
    local device_id =
        device_identity.id()

    return start_request(
        "external_job",
        path,
        {
            item_key = item.key,
            destination = destination,
            device_id =
                destination ==
                    "jellyfin_and_device" and
                device_id or nil,
            idempotency_key =
                tostring(device_id) ..
                ":" ..
                tostring(item.key) ..
                ":" ..
                tostring(destination),
        },
        nil,
        item,
        path_error
    )
end

function M.queue(item, callback)
    if request_kind or
        sync_client.busy() then
        return false,
            "sync request is already active"
    end

    if type(item) ~= "table" or
        type(item.jellyfin_id) ~= "string" or
        (
            item.kind ~= "album" and
            item.kind ~= "track"
        ) then
        return false,
            "invalid Jellyfin catalog item"
    end

    local path, path_error =
        device_identity
            .download_requests_path()

    if not path then
        return false, path_error
    end

    local device_id =
        device_identity.id()
    local body =
        json_encode.encode {
            jellyfin_item_id =
                item.jellyfin_id,
            kind = item.kind,
            idempotency_key =
                tostring(device_id) ..
                ":" ..
                item.kind ..
                ":" ..
                item.jellyfin_id ..
                ":" ..
                tostring(time.ticks()),
        }

    local started, start_error =
        sync_client.post(
            path,
            body,
            owner
        )

    if not started then
        return false, start_error
    end

    request_kind = "queue"
    request_view = nil
    request_cursor = nil
    request_item = item
    request_key = nil
    request_generation = nil
    request_callback =
        type(callback) == "function" and
        callback or nil
    last_error = nil

    return true, "pending"
end

function M.download_requests(callback)
    local path, path_error =
        device_identity.download_requests_path()
    return start_request(
        "download_requests",
        path,
        nil,
        "download_requests",
        nil,
        path_error,
        callback
    )
end

local function start_pending_search()
    if not pending_search then
        return false
    end

    local context = pending_search
    pending_search = nil
    local started, start_error =
        start_search_phase(
            context,
            "jellyfin"
        )

    if not started then
        last_error = start_error
    end

    return started
end

function M.poll()
    if not request_kind then
        return nil
    end

    local response =
        sync_client.poll(owner)

    if not response then
        return nil
    end

    local kind = request_kind
    local view = request_view
    local cursor = request_cursor
    local item = request_item
    local key = request_key
    local generation = request_generation
    local callback = request_callback
    request_kind = nil
    request_view = nil
    request_cursor = nil
    request_item = nil
    request_key = nil
    request_generation = nil
    request_callback = nil

    local search_response =
        kind == "search_jellyfin" or
        kind == "search_external"
    local stale_search =
        search_response and
        (
            type(item) ~= "table" or
            item.generation ~=
                search_generation
        )

    if stale_search then
        start_pending_search()
        return {
            ok = true,
            kind = "search_stale",
            stale = true,
            status = response.status,
        }
    end

    local catalog_key =
        kind == "catalog" and
        (key or view) or nil
    local catalog_existing =
        catalog_key and
        cache[catalog_key] or nil
    local catalog_paged =
        kind == "catalog" and
        type(cursor) == "string" and
        cursor ~= ""
    local stale_catalog_page =
        catalog_paged and
        type(catalog_existing) == "table" and
        generation ~= nil and
        catalog_existing.generation ~= nil and
        generation ~= catalog_existing.generation
    local expected_catalog_generation =
        catalog_key and
        expected_catalog_generations[
            tostring(catalog_key)
        ] or nil
    local stale_catalog_generation =
        kind == "catalog" and
        generation ~= nil and
        expected_catalog_generation ~= nil and
        generation ~= expected_catalog_generation

    -- Reject an obsolete catalog completion before decoding either success or
    -- failure. Otherwise an old generation's timeout/error becomes the global
    -- catalog error and can replace the Loading state owned by a newer New
    -- refresh that has not completed yet.
    if stale_catalog_page or
        stale_catalog_generation then
        return {
            ok = true,
            kind = "catalog_stale",
            key = catalog_key,
            view = view,
            stale = true,
            generation = generation,
            expected_generation =
                expected_catalog_generation,
            status = response.status,
        }
    end

    local payload = nil
    local payload_error = nil
    if kind == "queue" and
        response.ok ~= true and
        tonumber(response.status) == 409 then
        local conflict = decoded_body(response)
        if type(conflict) == "table" and
            conflict.code ==
                "already_downloaded_or_queued" then
            conflict.replayed = true
            conflict.already_durable = true
            payload = conflict
        end
    end
    if not payload then
        payload, payload_error = decode(response)
    end

    if not payload then
        if kind == "search_external" then
            local existing =
                cache[key] or {
                    items = {},
                    query = item.query,
                    kinds = item.kinds,
                    sort = item.sort,
                }
            existing
                .external_search_pending =
                false
            existing.external_available =
                false
            existing.external_message =
                "External search unavailable"
            cache[key] = existing
            current_search = nil
            last_error = nil
            return {
                ok = true,
                kind = kind,
                payload = existing,
                status = response.status,
                external_error =
                    payload_error,
            }
        end

        last_error = payload_error
        local failed = {
            ok = false,
            kind = kind,
            key = key,
            view = view,
            generation = generation,
            error = payload_error,
            status = response.status,
        }
        if callback then
            pcall(callback, failed)
        end
        return failed
    end

    if kind == "search_jellyfin" then
        payload.external_search_pending =
            true
        payload.external_available = nil
        payload.external_message = nil
        cache[key] = payload

        local started =
            start_search_phase(
                item,
                "external"
            )
        if not started then
            payload
                .external_search_pending =
                false
            payload.external_available =
                false
            payload.external_message =
                "External search unavailable"
            current_search = nil
        end
    elseif kind == "search_external" then
        local existing =
            cache[key] or {
                items = {},
                query = item.query,
                kinds = item.kinds,
                sort = item.sort,
            }
        payload = merge_external(
            existing,
            payload
        )
        cache[key] = payload
        current_search = nil
    elseif kind == "catalog" then
        payload.generation = generation

        if catalog_paged and
            type(catalog_existing) == "table" and
            type(catalog_existing.items) == "table" and
            type(payload.items) == "table" then
            local seen = {}
            for _, existing_item in ipairs(
                catalog_existing.items
            ) do
                local stable = tostring(
                    existing_item.jellyfin_id or
                    existing_item.key or
                    existing_item.id or ""
                )
                if stable ~= "" then
                    seen[stable] = true
                end
            end

            for _, next_item in ipairs(
                payload.items
            ) do
                local stable = tostring(
                    next_item.jellyfin_id or
                    next_item.key or
                    next_item.id or ""
                )
                if stable == "" or not seen[stable] then
                    catalog_existing.items[
                        #catalog_existing.items + 1
                    ] = next_item
                    if stable ~= "" then
                        seen[stable] = true
                    end
                end
            end

            catalog_existing.next_cursor =
                payload.next_cursor
            catalog_existing.total =
                payload.total or
                payload.total_count
            catalog_existing.total_count =
                payload.total_count or
                payload.total
            catalog_existing.generation =
                generation
            catalog_existing.sort =
                payload.sort or
                catalog_existing.sort
            catalog_existing.direction =
                payload.direction or
                catalog_existing.direction
            payload = catalog_existing
        else
            payload.total_count =
                payload.total_count or
                payload.total
            cache[catalog_key] = payload
        end
    elseif kind == "queue" and
        type(item) == "table" then
        item.device =
            item.device or {}
        item.device.state = "queued"
        item.device.actionable = false
    elseif key then
        cache[key] = payload
    end

    last_error = nil

    local completed = {
        ok = true,
        kind = kind,
        key = key,
        view = view,
        generation = generation,
        payload = payload,
        status = response.status,
    }
    if callback then
        pcall(callback, completed)
    end
    return completed
end

function M.cached_key(key)
    return cache[key]
end

function M.cached(view)
    return cache[view]
end

function M.error()
    return last_error
end

function M.busy()
    return request_kind ~= nil
end

function M.pending_kind()
    return request_kind
end

function M.reset()
    cache = {}
    last_error = nil
    search_generation = 0
    current_search = nil
    pending_search = nil
    request_generation = nil
    request_callback = nil
    expected_catalog_generations = {}
end

return M
