-- Authoritative album download state machine (Phase 2).
--
-- Public states only:
--   server_only | partial | queued | downloading | downloaded | failed
--
-- Precedence (highest wins while valid):
--   downloading > queued > failed > downloaded > partial > server_only
--
-- Sync UI, Local placeholders, and context-menu predicates must consume this
-- owner rather than independently deriving competing states.

local jellyfin_album_identity =
    require("jellyfin_album_identity")

local M = {}

M.STATES = {
    server_only = true,
    partial = true,
    queued = true,
    downloading = true,
    downloaded = true,
    failed = true,
}

local PRECEDENCE = {
    downloading = 60,
    queued = 50,
    failed = 40,
    downloaded = 30,
    partial = 20,
    server_only = 10,
}

local generation = 0
local operations = {}
local by_key = {}
local subscribers = {}
local next_subscriber_id = 1
local dispatcher = nil
local dispatch_inflight = nil
local remote_attempt_shadows = {}
local local_cache = {
    generation = -1,
    track_ids = {},
    album_counts = {},
    library = nil,
}

local function log_transition(event, fields)
    if type(print) ~= "function" then
        return
    end

    local parts = {"[sync-state] " .. event}
    if type(fields) == "table" then
        for key, value in pairs(fields) do
            parts[#parts + 1] =
                tostring(key) .. "=" ..
                tostring(value)
        end
    end

    print(table.concat(parts, " "))
end

local function copy_shallow(value)
    if type(value) ~= "table" then
        return value
    end

    local copied = {}
    for key, child in pairs(value) do
        copied[key] = child
    end
    return copied
end

local function copy_item(item)
    if type(item) ~= "table" then
        return item
    end

    local copied = copy_shallow(item)
    if type(item.device) == "table" then
        copied.device = copy_shallow(item.device)
    end
    if type(item.artwork) == "table" then
        copied.artwork = copy_shallow(item.artwork)
    end
    return copied
end

local function normalize_public_state(state)
    if state == "finalizing" or
        state == "importing" or
        state == "jellyfin_importing" or
        state == "external_downloading" then
        return "downloading"
    end

    if state == "external_queued" then
        return "queued"
    end

    if state == "available" or
        state == "on_device" then
        return nil
    end

    if M.STATES[state] then
        return state
    end

    return nil
end

local function album_key(item_or_key)
    if item_or_key == nil then
        return nil
    end

    if type(item_or_key) == "string" then
        if item_or_key:sub(1, 3) == "id:" or
            item_or_key:sub(1, 6) == "album:" then
            return item_or_key
        end

        local bare =
            jellyfin_album_identity.canonical_id(
                item_or_key
            )
        if bare then
            return "id:" .. bare
        end
        return nil
    end

    if type(item_or_key) ~= "table" then
        return nil
    end

    if item_or_key.kind == "track" then
        return jellyfin_album_identity
            .track_album_key(item_or_key) or
            jellyfin_album_identity.key(
                item_or_key
            )
    end

    return jellyfin_album_identity.key(
        item_or_key
    )
end

local function album_id_from_key(key)
    if type(key) ~= "string" then
        return nil
    end

    if key:sub(1, 3) == "id:" then
        return key:sub(4)
    end

    return jellyfin_album_identity.canonical_id(
        key
    )
end

local function bump(changed_keys)
    generation = generation + 1

    local payload = {
        generation = generation,
        keys = changed_keys or {},
    }

    local dead = {}
    for id, entry in pairs(subscribers) do
        if entry.dead then
            dead[#dead + 1] = id
        else
            local ok = pcall(entry.callback, payload)
            if not ok then
                entry.dead = true
                dead[#dead + 1] = id
            end
        end
    end

    for _, id in ipairs(dead) do
        subscribers[id] = nil
    end

    return generation
end

local function ensure_record(key, item)
    local record = by_key[key]
    if not record then
        record = {
            key = key,
            state = "server_only",
            progress = nil,
            item = nil,
            failure = nil,
            op_id = nil,
            queue_index = nil,
            local_complete = false,
            local_partial = false,
            local_usable = false,
            updated_generation = generation,
        }
        by_key[key] = record
    end

    if type(item) == "table" then
        record.item = copy_item(item)
    end

    return record
end

local function operation_index_for_key(key)
    for index, operation in ipairs(operations) do
        if operation.key == key then
            return index, operation
        end
    end
    return nil, nil
end

local function operation_index_for_attempt(attempt_ref)
    local attempt_id =
        type(attempt_ref) == "table" and
        (
            attempt_ref.request_id or
            attempt_ref.id
        ) or attempt_ref
    if attempt_id == nil then
        return nil, nil
    end

    for index, operation in ipairs(operations) do
        if operation.id == attempt_id or
            operation.remote_request_id ==
                attempt_id then
            return index, operation
        end
    end

    return nil, nil
end

local function exact_attempt_id(attempt_ref)
    return type(attempt_ref) == "table" and
        (
            attempt_ref.request_id or
            attempt_ref.id
        ) or attempt_ref
end

local function refresh_local_cache(force)
    local local_index =
        package.loaded["jellyfin_local_index"] or
        require("jellyfin_local_index")
    local sync_runtime =
        package.loaded["sync_runtime"]

    local content_generation = 0
    if type(sync_runtime) == "table" and
        type(sync_runtime.content_generation) ==
            "function" then
        content_generation =
            tonumber(
                sync_runtime.content_generation()
            ) or 0
    end

    local library = local_index.load()

    if not force and
        local_cache.library and
        local_cache.library == library and
        local_cache.generation ==
            content_generation then
        return local_cache
    end

    local track_ids = {}
    local album_counts = {}

    if type(library) == "table" then
        for _, track in ipairs(
            library.tracks or {}
        ) do
            if type(track) == "table" and
                not track.pending_download then
                local track_id =
                    jellyfin_album_identity
                        .canonical_id(
                            track.jellyfin_id or
                            track.id
                        )
                if track_id then
                    track_ids[track_id] = true
                end

                -- Prefer explicit album fields. Bare Local track rows often omit
                -- kind="track", so album_id(track) would wrongly use jellyfin_id.
                local track_album =
                    jellyfin_album_identity
                        .canonical_id(
                            track.album_id or
                            track.parent_id or
                            track.jellyfin_album_id
                        )
                if not track_album and
                    track.kind == "track" then
                    track_album =
                        jellyfin_album_identity
                            .album_id(track)
                end
                if track_album then
                    album_counts[track_album] =
                        (
                            album_counts[
                                track_album
                            ] or 0
                        ) + 1
                end
            end
        end

        for _, album in ipairs(
            library.albums or {}
        ) do
            if type(album) == "table" and
                not album.pending_download then
                local album_id =
                    jellyfin_album_identity
                        .album_id(album) or
                    jellyfin_album_identity
                        .canonical_id(
                            album.id or
                            album.jellyfin_id
                        )
                local listed =
                    tonumber(album.track_count) or
                    (
                        type(album.tracks) ==
                            "table" and
                        #album.tracks
                    ) or 0
                if album_id and listed > 0 then
                    album_counts[album_id] =
                        math.max(
                            album_counts[
                                album_id
                            ] or 0,
                            listed
                        )
                end
            end
        end
    end

    local_cache.generation = content_generation
    local_cache.track_ids = track_ids
    local_cache.album_counts = album_counts
    local_cache.library = library
    return local_cache
end

local function child_track_ids(item)
    if type(item) ~= "table" then
        return nil
    end

    local device_state =
        type(item.device) == "table" and
        item.device or {}
    local source =
        item.jellyfin_track_ids or
        item.child_track_ids or
        device_state.jellyfin_track_ids or
        device_state.child_track_ids
    if type(source) ~= "table" then
        return nil
    end

    local seen = {}
    local ids = {}
    for _, value in ipairs(source) do
        local id =
            jellyfin_album_identity.canonical_id(
                value
            )
        if id and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end

    if #ids == 0 then
        return nil
    end
    return ids
end

local function local_inventory_for(item, key)
    local cache = refresh_local_cache(false)
    local album_id =
        album_id_from_key(key) or
        jellyfin_album_identity.album_id(item)
    local local_count =
        (album_id and
            cache.album_counts[album_id]) or 0
    local children = child_track_ids(item)
    local matched = 0

    if children then
        for _, id in ipairs(children) do
            if cache.track_ids[id] then
                matched = matched + 1
            end
        end
    end

    local catalog_total =
        type(item) == "table" and
        (
            tonumber(item.track_count) or
            tonumber(item.child_count)
        ) or nil

    local complete = false
    if local_count > 0 then
        if children and matched >= #children then
            complete = true
        elseif catalog_total and
            catalog_total > 0 and
            local_count >= catalog_total then
            complete = true
        elseif not catalog_total and
            not children then
            complete = true
        elseif children and
            local_count >= #children and
            matched > 0 then
            complete = true
        end
    end

    local partial =
        not complete and local_count > 0
    if not complete and children and
        matched > 0 and
        matched < #children then
        partial = true
    end

    return {
        local_count = local_count,
        matched = matched,
        expected =
            children and #children or
            catalog_total,
        complete = complete,
        partial = partial,
        usable = local_count > 0,
    }
end

local function runtime_state_for(item, key)
    local sync_runtime =
        package.loaded["sync_runtime"]
    if type(sync_runtime) ~= "table" or
        type(sync_runtime.item_state) ~=
            "function" then
        return nil, nil
    end

    local ok, state, percentage = pcall(
        sync_runtime.item_state,
        item or key
    )
    if not ok then
        return nil, nil
    end

    local public = normalize_public_state(state)
    if public then
        return public, percentage
    end

    if type(sync_runtime.apply_progress) ==
            "function" then
        local progress =
            sync_runtime.apply_progress()
        if type(progress) == "table" then
            local action = progress.action
            local active =
                type(action) == "table" and
                action.item or nil
            local active_key = album_key(active)
            if active_key and
                active_key == key then
                local bytes =
                    tonumber(progress.bytes)
                local total = tonumber(
                    progress.bytes_total
                )
                local pct = nil
                if bytes and total and
                    total > 0 then
                    pct = math.max(
                        0,
                        math.min(
                            100,
                            math.floor(
                                bytes * 100 /
                                total
                            )
                        )
                    )
                end
                return "downloading", pct
            end
        end
    end

    return nil, nil
end

local function reported_state_for(item)
    if type(item) ~= "table" then
        return nil
    end

    local reported =
        type(item.device) == "table" and
            item.device.state or
        item.state or
        item.availability
    return normalize_public_state(reported)
end

local function choose_state(candidates)
    local best = nil
    local best_rank = -1

    for _, candidate in ipairs(candidates) do
        local state =
            normalize_public_state(candidate)
        local rank = state and
            PRECEDENCE[state] or -1
        if rank > best_rank then
            best = state
            best_rank = rank
        end
    end

    return best or "server_only"
end

local function rebuild_operation_indexes()
    for index, operation in ipairs(operations) do
        operation.queue_index = index
        local record = ensure_record(
            operation.key,
            operation.item
        )
        record.op_id = operation.id
        record.queue_index = index
        if index == 1 then
            if operation.status == "failed" then
                record.state = "failed"
            elseif operation.dispatched then
                operation.status = "downloading"
                record.state = "downloading"
            else
                -- Head waits for exactly-once companion dispatch.
                operation.status = "queued"
                record.state = "queued"
            end
        elseif operation.status ~= "failed" then
            operation.status = "queued"
            operation.dispatched =
                operation.remote_confirmed == true
            record.state = "queued"
            record.progress = nil
        end
    end
end

local function mark_record_state(key, state, fields)
    local record = ensure_record(key)
    local previous = record.state
    record.state = state
    if type(fields) == "table" then
        for field, value in pairs(fields) do
            record[field] = value
        end
    end
    record.updated_generation = generation + 1
    if type(record.item) == "table" then
        if type(record.item.device) ~= "table" then
            record.item.device = {}
        end
        record.item.device.state = state
    end
    log_transition("transition", {
        key = key,
        old = previous,
        new = state,
        op_id = record.op_id,
        queue_index = record.queue_index,
    })
end

local function try_dispatch_head(reason, extra_keys)
    local head = operations[1]
    if not head then
        return false, "empty"
    end

    if head.dispatched then
        return false, "already"
    end

    if head.dispatch_pending or dispatch_inflight then
        return false, "inflight"
    end

    if next(remote_attempt_shadows) ~= nil then
        return false, "remote-occupied"
    end

    local function notify_keys()
        local keys = {head.key}
        if type(extra_keys) == "table" then
            for _, key in ipairs(extra_keys) do
                if key and key ~= head.key then
                    keys[#keys + 1] = key
                end
            end
        end
        return keys
    end

    local first_dispatch_attempt =
        head.dispatch_waiting_busy ~= true
    if first_dispatch_attempt then
        log_transition("active", {
            key = head.key,
            op_id = head.id,
            queue_index = 1,
            reason = reason or "dispatch",
        })
    end

    -- A missing transport can never constitute companion acceptance. Keep
    -- the head queued until runtime wiring is available and pump_dispatch()
    -- can make the real attempt.
    if type(dispatcher) ~= "function" then
        head.dispatch_waiting_busy = true
        return false, "dispatcher unavailable"
    end

    dispatch_inflight = head.id
    head.dispatch_pending = true
    if first_dispatch_attempt then
        log_transition("dispatch", {
            key = head.key,
            op_id = head.id,
            queue_index = 1,
            reason = reason or "dispatch",
        })
    end
    local ok, err = dispatcher(head.item, head)

    if ok and err == "pending" then
        -- The transport started, but the companion has not accepted the
        -- operation yet. Keep the public projection queued and retain the
        -- private lock until resolve_dispatch() receives the HTTP result.
        head.status = "queued"
        head.dispatch_waiting_busy = nil
        mark_record_state(head.key, "queued", {
            op_id = head.id,
            queue_index = 1,
            progress = nil,
        })
        log_transition("dispatch-pending", {
            key = head.key,
            op_id = head.id,
            reason = reason or "dispatch",
        })
        return false, "pending"
    end

    head.dispatch_pending = nil
    if dispatch_inflight == head.id then
        dispatch_inflight = nil
    end

    if ok then
        head.dispatch_waiting_busy = nil
        head.dispatched = true
        head.status = "downloading"
        mark_record_state(head.key, "downloading", {
            op_id = head.id,
            queue_index = 1,
            failure = nil,
            progress = head.progress or 0,
        })
        bump(notify_keys())
        log_transition("accepted", {
            key = head.key,
            op_id = head.id,
            reason = reason or "dispatch",
        })
        return true
    end

    local message = tostring(err or "dispatch failed")
    if message:find("already active", 1, true) or
        message == "busy" then
        -- Keep FIFO head queued and retry from pump/startup reconcile.
        head.dispatch_waiting_busy = true
        head.dispatched = false
        head.status = "queued"
        local record = ensure_record(
            head.key,
            head.item
        )
        record.state = "queued"
        record.op_id = head.id
        record.queue_index = 1
        record.progress = nil
        return false, "busy"
    end

    -- Hard rejection: drop the head so it cannot block the FIFO forever.
    local failed_key = head.key
    local failed_op_id = head.id
    table.remove(operations, 1)
    local record = ensure_record(failed_key, head.item)
    record.state = "failed"
    record.progress = nil
    record.failure = {
        message = message,
        retriable = true,
    }
    record.op_id = failed_op_id
    record.queue_index = nil
    record.updated_generation = generation + 1
    if type(record.item) == "table" then
        if type(record.item.device) ~= "table" then
            record.item.device = {}
        end
        record.item.device.state = "failed"
    end
    rebuild_operation_indexes()
    local changed = {failed_key}
    if type(extra_keys) == "table" then
        for _, key in ipairs(extra_keys) do
            if key and key ~= failed_key then
                changed[#changed + 1] = key
            end
        end
    end
    if operations[1] then
        changed[#changed + 1] = operations[1].key
    end
    bump(changed)
    log_transition("fail", {
        key = failed_key,
        op_id = failed_op_id,
        error = message,
        reason = reason or "dispatch",
    })
    if operations[1] then
        try_dispatch_head("promote-after-dispatch-fail")
    end
    return false, message
end

function M.resolve_dispatch(operation_ref, accepted, detail)
    local op_id = type(operation_ref) == "table" and
        operation_ref.id or operation_ref
    if op_id == nil then
        return false, "operation id required"
    end

    local op_index = nil
    local operation = nil

    for index, candidate in ipairs(operations) do
        if candidate.id == op_id then
            op_index = index
            operation = candidate
            break
        end
    end

    if not operation then
        if dispatch_inflight == op_id then
            dispatch_inflight = nil
        end
        return false, "operation is no longer pending"
    end

    operation.dispatch_pending = nil
    if dispatch_inflight == operation.id then
        dispatch_inflight = nil
    end

    if accepted then
        local remote_request_id =
            type(detail) == "table" and
            detail.request_id or nil
        if remote_request_id ~= nil then
            operation.remote_request_id =
                remote_request_id
            if type(operation.item) == "table" then
                operation.item.device =
                    operation.item.device or {}
                operation.item.device
                    .download_request_id =
                    remote_request_id
            end
        end
        operation.dispatched = true
        operation.remote_confirmed = true
        operation.accepted_observation_grace = true
        operation.status =
            op_index == 1 and "downloading" or "queued"
        rebuild_operation_indexes()
        mark_record_state(operation.key, operation.status, {
            op_id = operation.id,
            queue_index = op_index,
            failure = nil,
            progress =
                op_index == 1 and
                (operation.progress or 0) or nil,
        })
        bump({operation.key})
        log_transition("accepted", {
            key = operation.key,
            op_id = operation.id,
            replayed =
                type(detail) == "table" and
                detail.replayed == true or false,
            status =
                type(detail) == "table" and
                detail.status or nil,
        })
        return true
    end

    local message = type(detail) == "table" and
        detail.error or detail
    return M.fail_attempt(operation.id, {
        message = tostring(message or "dispatch failed"),
        retriable = true,
    })
end

local function projection_from_record(record)
    local state = record.state or "server_only"
    local locked =
        state == "queued" or
        state == "downloading" or
        state == "downloaded"
    local can_download =
        state == "server_only" or
        state == "partial"
    local can_retry = state == "failed"
    -- Local navigation is intentionally gated until authoritative album
    -- completion. A queued/downloading/partial/failed album can have usable
    -- files on disk, but exposing them creates a changing partial album UI.
    local show_view_local =
        state == "downloaded"

    local icon = "server"
    if state == "downloaded" then
        icon = "device"
    elseif state == "partial" then
        icon = "partial"
    elseif state == "queued" then
        icon = "queued"
    elseif state == "downloading" then
        icon = "downloading"
    elseif state == "failed" then
        icon = "failed"
    end

    local label = state
    if state == "downloading" and
        record.progress ~= nil then
        label = "downloading " ..
            tostring(record.progress) .. "%"
    end

    return {
        key = record.key,
        state = state,
        progress = record.progress,
        percentage = record.progress,
        failure = record.failure,
        op_id = record.op_id,
        queue_index = record.queue_index,
        local_complete =
            record.local_complete == true,
        local_partial =
            record.local_partial == true,
        local_usable =
            record.local_usable == true,
        has_local_content =
            record.local_usable == true,
        can_download = can_download,
        can_retry = can_retry,
        request_locked = locked,
        show_view_local = show_view_local,
        download_actionable =
            can_download or can_retry,
        icon_kind = icon,
        label = label,
        item = record.item,
        generation = record.updated_generation or
            generation,
    }
end

local function reconcile_one(item, key, sources)
    key = key or album_key(item)
    if not key then
        return nil
    end

    sources = sources or {}
    local record = ensure_record(key, item)
    local inventory =
        local_inventory_for(
            item or record.item,
            key
        )
    record.local_complete = inventory.complete
    record.local_partial = inventory.partial
    record.local_usable = inventory.usable

    local op_index, operation =
        operation_index_for_key(key)
    local runtime_state, runtime_percentage =
        runtime_state_for(
            item or record.item,
            key
        )
    local reported =
        reported_state_for(item or record.item)

    -- Local completeness ends a valid operation without leaving Sync partial.
    if inventory.complete then
        local promoted_key = nil
        local was_head = op_index == 1
        if operation then
            table.remove(operations, op_index)
            rebuild_operation_indexes()
            if operations[1] then
                promoted_key = operations[1].key
            end
            if type(sources.on_auto_complete) ==
                    "function" then
                sources.on_auto_complete(
                    key,
                    promoted_key
                )
            elseif sources.changed_keys then
                sources.changed_keys[#sources.changed_keys + 1] =
                    key
                if promoted_key then
                    sources.changed_keys[
                        #sources.changed_keys + 1
                    ] = promoted_key
                end
            end
        end
        record.state = "downloaded"
        record.progress = nil
        record.failure = nil
        record.op_id = nil
        record.queue_index = nil
        record.updated_generation = generation
        if was_head and promoted_key and
            type(sources) == "table" then
            sources.pending_dispatch = true
        end
        return projection_from_record(record)
    end

    -- Operation store is authoritative for in-flight request state.
    if operation then
        if op_index == 1 and
            operation.status ~= "failed" then
            if operation.dispatched then
                record.state = "downloading"
                if runtime_percentage ~= nil then
                    record.progress =
                        runtime_percentage
                elseif sources.progress ~= nil then
                    record.progress =
                        sources.progress
                end
            else
                record.state = "queued"
                record.progress = nil
            end
        elseif operation.status == "failed" then
            record.state = "failed"
            record.progress = nil
        else
            record.state = "queued"
            record.progress = nil
        end
        record.op_id = operation.id
        record.queue_index = op_index
        record.updated_generation = generation
        return projection_from_record(record)
    end

    -- No local operation: runtime/apply and local inventory decide.
    -- Active/queued/failed runtime never collapses to partial.
    if runtime_state == "downloading" then
        record.state = "downloading"
        record.progress = runtime_percentage
        record.updated_generation = generation
        return projection_from_record(record)
    end

    if runtime_state == "queued" then
        record.state = "queued"
        record.progress = nil
        record.updated_generation = generation
        return projection_from_record(record)
    end

    if runtime_state == "failed" or
        reported == "failed" or
        record.failure ~= nil then
        -- Explicit fail()/rejection remains visible until retry replaces it.
        if record.state ~= "downloaded" then
            record.state = "failed"
            record.progress = nil
            record.updated_generation =
                generation
            return projection_from_record(record)
        end
    end

    -- Sticky downloaded from complete() wins over stale caller device.state
    -- unless Local inventory proves a real shortfall.
    if record.state == "downloaded" and
        not inventory.partial then
        record.progress = nil
        record.failure = nil
        record.updated_generation = generation
        return projection_from_record(record)
    end

    if runtime_state == "downloaded" or
        reported == "downloaded" then
        -- Only accept reported downloaded when Local does not prove a shortfall.
        if not inventory.partial then
            record.state = "downloaded"
            record.progress = nil
            record.failure = nil
            record.updated_generation = generation
            return projection_from_record(record)
        end
    end

    if inventory.partial then
        -- Real Local shortfall invalidates a prior downloaded stamp.
        record.state = "partial"
        record.progress = nil
        record.updated_generation = generation
        return projection_from_record(record)
    end

    record.state = "server_only"
    record.progress = nil
    record.updated_generation = generation
    return projection_from_record(record)
end

function M.key(item_or_key)
    return album_key(item_or_key)
end

function M.generation()
    return generation
end

function M.precedence()
    return copy_shallow(PRECEDENCE)
end

function M.lookup(item_or_key)
    local key = album_key(item_or_key)
    if not key then
        return {
            key = nil,
            state = "server_only",
            can_download = false,
            request_locked = false,
            show_view_local = false,
            icon_kind = "server",
        }
    end

    local item =
        type(item_or_key) == "table" and
        item_or_key or
        (by_key[key] and by_key[key].item)

    local opts = {}
    local projection =
        reconcile_one(item, key, opts)
    if opts.pending_dispatch then
        try_dispatch_head(
            "lookup-auto-complete",
            {key}
        )
        projection = reconcile_one(item, key)
    end

    return projection
end

function M.projection(item_or_key)
    return M.lookup(item_or_key)
end

function M.reconcile(opts)
    opts = opts or {}
    refresh_local_cache(opts.force_local == true)

    local changed = {}
    local seen = {}
    opts.changed_keys = changed

    local function touch(item)
        local key = album_key(item)
        if not key or seen[key] then
            return
        end
        seen[key] = true
        local before =
            by_key[key] and by_key[key].state
        local before_progress =
            by_key[key] and by_key[key].progress
        local projection =
            reconcile_one(item, key, opts)
        if projection and
            (
                projection.state ~= before or
                projection.progress ~=
                    before_progress
            ) then
            changed[#changed + 1] = key
        end
    end

    if opts.item then
        touch(opts.item)
    end

    for _, operation in ipairs(operations) do
        touch(operation.item or operation.key)
    end

    for key, record in pairs(by_key) do
        touch(record.item or key)
    end

    if opts.items then
        for _, item in ipairs(opts.items) do
            touch(item)
        end
    end

    if opts.pending_dispatch then
        local ok =
            try_dispatch_head(
                "auto-complete",
                changed
            )
        if not ok and
            (
                #changed > 0 or
                opts.notify == true
            ) then
            bump(changed)
        end
    elseif #changed > 0 or opts.notify == true then
        bump(changed)
    end

    return {
        generation = generation,
        changed_keys = changed,
    }
end

function M.set_dispatcher(fn)
    if fn == nil then
        dispatcher = nil
        return true
    end
    if type(fn) ~= "function" then
        return false, "dispatcher required"
    end
    dispatcher = fn
    return true
end

function M.pump_dispatch(reason)
    return try_dispatch_head(reason or "pump")
end

function M.reconcile_startup(opts)
    opts = opts or {}
    local remote_keys = {}
    local local_active_keys = {}
    local remote_order = {}
    local remote_descriptors = {}
    local remote_attempt_ids = {}
    local conflicting_local_attempt_ids = {}
    if type(opts.remote_keys) == "table" then
        for _, key in ipairs(opts.remote_keys) do
            local canonical = album_key(key)
            if canonical then
                remote_keys[canonical] = true
            end
        end
        for key, value in pairs(opts.remote_keys) do
            if value == true then
                local canonical = album_key(key)
                if canonical then
                    remote_keys[canonical] = true
                end
            end
        end
    end

    -- Current local apply work can protect an accepted operation while the
    -- companion is being observed, but it is deliberately not remote proof.
    if type(opts.local_active_keys) == "table" then
        for _, key in ipairs(opts.local_active_keys) do
            local canonical = album_key(key)
            if canonical then
                local_active_keys[canonical] = true
            end
        end
        for key, value in pairs(opts.local_active_keys) do
            if value == true then
                local canonical = album_key(key)
                if canonical then
                    local_active_keys[canonical] = true
                end
            end
        end
    end

    if type(opts.remote_operations) == "table" then
        local candidates = {}
        for _, entry in ipairs(opts.remote_operations) do
            if type(entry) == "table" then
                local state = normalize_public_state(
                    entry.state or
                    (
                        type(entry.device) == "table" and
                        entry.device.state or nil
                    )
                )
                if state == "queued" or
                    state == "downloading" then
                    local item = type(entry.item) == "table" and
                        copy_item(entry.item) or copy_item(entry)
                    item.kind = item.kind or entry.kind or "album"
                    item.jellyfin_id =
                        item.jellyfin_id or
                        entry.root_jellyfin_id or
                        entry.album_id
                    item.id = item.id or item.jellyfin_id
                    item.title =
                        item.title or item.name or
                        entry.title or entry.name or
                        "Downloading"
                    item.artist =
                        item.artist or entry.artist or ""
                    item.track_count =
                        item.track_count or
                        entry.total_tracks
                    item.jellyfin_track_ids =
                        item.jellyfin_track_ids or
                        entry.track_ids
                    item.device = item.device or {}
                    item.device.state = state
                    item.device.download_request_id =
                        entry.id or entry.request_id

                    local key = album_key(item)
                    if key then
                        candidates[#candidates + 1] = {
                            key = key,
                            state = state,
                            item = item,
                            request_id =
                                entry.id or entry.request_id,
                            created_at =
                                tonumber(entry.created_at) or 0,
                        }
                    end
                end
            end
        end

        table.sort(candidates, function(left, right)
            if left.state ~= right.state then
                return left.state == "downloading"
            end
            if left.created_at ~= right.created_at then
                return left.created_at < right.created_at
            end
            return tostring(left.request_id or left.key) <
                tostring(right.request_id or right.key)
        end)

        for _, descriptor in ipairs(candidates) do
            if not remote_descriptors[descriptor.key] then
                remote_descriptors[descriptor.key] = descriptor
                remote_order[#remote_order + 1] = descriptor.key
                remote_keys[descriptor.key] = true
                if descriptor.request_id ~= nil then
                    remote_attempt_ids[
                        descriptor.request_id
                    ] = true
                end
            end
        end
    end

    local remote_busy = opts.remote_busy == true
    local changed = {}
    local changed_set = {}
    local confirmed = {}
    local confirmed_by_key = {}
    local locally_active = {}
    local queued = {}
    local before = {}

    local function add_changed(key)
        if key and not changed_set[key] then
            changed_set[key] = true
            changed[#changed + 1] = key
        end
    end

    -- Recreate accepted companion work that survived a process restart. The
    -- durable request ID becomes the local operation ID and is never posted
    -- again.
    if type(opts.remote_operations) == "table" then
        for _, operation in ipairs(operations) do
            operation.remote_attempt_conflict = nil
        end
    end
    for _, key in ipairs(remote_order) do
        local descriptor = remote_descriptors[key]
        local request_id = descriptor and
            descriptor.request_id or nil
        local _, operation =
            operation_index_for_attempt(request_id)
        if operation and operation.key ~= key then
            operation = nil
        end
        local _, same_album_operation =
            operation_index_for_key(key)

        if not operation and
            same_album_operation and
            request_id ~= nil then
            -- Album identity cannot prove attempt identity. Keep the durable
            -- work as an independent capacity owner without rebinding the
            -- newer local retry that happens to share its album key.
            remote_attempt_shadows[request_id] = {
                request_id = request_id,
                key = key,
                state = descriptor.state,
                item = copy_item(descriptor.item),
            }
            conflicting_local_attempt_ids[
                same_album_operation.id
            ] = true
            same_album_operation.remote_attempt_conflict =
                true
        elseif not operation and descriptor then
            operation = {
                id = tostring(
                    descriptor.request_id or
                    ("remote:" .. key)
                ),
                key = key,
                item = copy_item(descriptor.item),
                status = descriptor.state,
                dispatched = true,
                remote_confirmed = true,
                remote_request_id =
                    descriptor.request_id,
            }
            operations[#operations + 1] = operation
            ensure_record(key, operation.item)
            add_changed(key)
        elseif operation and descriptor then
            -- Keep richer catalog metadata already attached to the local op,
            -- filling only fields supplied by the durable request.
            operation.item = operation.item or
                copy_item(descriptor.item)
            operation.remote_state = descriptor.state
            operation.remote_request_id =
                descriptor.request_id
            if request_id ~= nil then
                remote_attempt_shadows[request_id] = nil
            end
        end
    end

    if type(opts.remote_operations) == "table" then
        for request_id in pairs(remote_attempt_shadows) do
            if not remote_attempt_ids[request_id] then
                remote_attempt_shadows[request_id] = nil
            end
        end
    end

    for index, operation in ipairs(operations) do
        local key = operation.key
        before[operation] = {
            index = index,
            dispatched = operation.dispatched,
            status = operation.status,
            state = by_key[key] and
                by_key[key].state or nil,
        }
        local descriptor = remote_descriptors[key]
        local remote =
            remote_attempt_ids[operation.id] == true or
            (
                operation.remote_request_id ~= nil and
                remote_attempt_ids[
                    operation.remote_request_id
                ] == true
            ) or
            (
                descriptor == nil and
                remote_keys[key] == true
            )
        if remote then
            -- Canonical remote identity is authoritative even if a separate
            -- global busy bit is stale or inconsistent.
            operation.remote_confirmed = true
            operation.accepted_observation_grace = nil
            operation.dispatched = true
            operation.dispatch_pending = nil
            if dispatch_inflight == operation.id then
                dispatch_inflight = nil
            end
            confirmed[#confirmed + 1] = operation
            confirmed_by_key[key] = operation
        elseif operation.dispatch_pending then
            -- A POST awaiting its HTTP result is a bounded local lifecycle,
            -- not evidence that the durable request exists remotely.
            operation.remote_confirmed = nil
            operation.dispatched = false
            operation.status = "queued"
            queued[#queued + 1] = operation
        elseif operation.accepted_observation_grace then
            -- The queue POST was accepted after the durable snapshot used by
            -- this observation may already have been taken. One successful
            -- omission revokes the grace but cannot erase the accepted
            -- attempt; a later omission can clean it normally.
            operation.accepted_observation_grace = nil
            operation.remote_confirmed = nil
            locally_active[#locally_active + 1] =
                operation
        elseif conflicting_local_attempt_ids[
                operation.id
            ] == true then
            -- A separately represented remote attempt for this album is not
            -- negative evidence against the newer local attempt either.
            operation.remote_confirmed = nil
            if operation.dispatched then
                locally_active[#locally_active + 1] =
                    operation
            else
                operation.status = "queued"
                queued[#queued + 1] = operation
            end
        elseif local_active_keys[key] == true then
            -- sync_apply is independently active for this key. Preserve the
            -- accepted owner operation without classifying it as observed.
            operation.remote_confirmed = nil
            locally_active[#locally_active + 1] = operation
        elseif operation.dispatched or
            (
                opts.cleanup_unconfirmed == true and
                (
                    type(opts.cleanup_attempt_ids) ~=
                        "table" or
                    opts.cleanup_attempt_ids[
                        operation.id
                    ] == true
                )
            ) then
            -- Abandoned optimistic head/tail from a prior session.
            log_transition("fail", {
                key = key,
                op_id = operation.id,
                reason = "stale-startup",
            })
            local record = ensure_record(
                key,
                operation.item
            )
            record.state = "failed"
            record.failure = {
                message =
                    "stale download cleared",
                retriable = true,
            }
            record.progress = nil
            record.op_id = nil
            record.queue_index = nil
            record.updated_generation =
                generation + 1
            operation.dispatch_pending = nil
            if dispatch_inflight == operation.id then
                dispatch_inflight = nil
            end
            add_changed(key)
        else
            operation.remote_confirmed = nil
            operation.dispatched = false
            operation.status = "queued"
            queued[#queued + 1] = operation
        end
    end

    -- A remotely confirmed tail moves ahead of unconfirmed local work so a
    -- stale/queued local head cannot block or redispatch it.
    operations = {}
    local inserted = {}
    for _, key in ipairs(remote_order) do
        local operation = confirmed_by_key[key]
        if operation and not inserted[operation] then
            inserted[operation] = true
            operations[#operations + 1] = operation
        end
    end
    for _, operation in ipairs(confirmed) do
        if not inserted[operation] then
            inserted[operation] = true
            operations[#operations + 1] = operation
        end
    end
    for _, operation in ipairs(locally_active) do
        if not inserted[operation] then
            inserted[operation] = true
            operations[#operations + 1] = operation
        end
    end
    for _, operation in ipairs(queued) do
        operations[#operations + 1] = operation
    end
    rebuild_operation_indexes()

    for index, operation in ipairs(operations) do
        local old = before[operation]
        local record = by_key[operation.key]
        if not old or
            old.index ~= index or
            old.dispatched ~= operation.dispatched or
            old.status ~= operation.status or
            (record and old.state ~= record.state) then
            if record then
                record.updated_generation =
                    generation + 1
            end
            add_changed(operation.key)
        end
    end

    -- remote_busy is only a capacity gate for unidentified remote work. It
    -- never supplies operation identity. Any remote key also occupies the
    -- dispatcher even if remote_busy is inconsistently false.
    local remote_occupied =
        #confirmed > 0 or
        #locally_active > 0 or
        next(remote_attempt_shadows) ~= nil or
        remote_busy
    local dispatch_notified = false
    if not remote_occupied and operations[1] then
        local _, reason =
            try_dispatch_head(
                "startup",
                changed
            )
        dispatch_notified =
            reason ~= "empty" and
            reason ~= "already" and
            reason ~= "inflight"
    end

    if #changed > 0 and not dispatch_notified then
        bump(changed)
    end

    return {
        generation = generation,
        changed_keys = changed,
        operations = M.operations(),
    }
end

function M.request(item)
    if type(item) ~= "table" then
        return false, "item required"
    end

    local key = album_key(item)
    if not key then
        return false, "album identity required"
    end

    local current = M.lookup(item)
    if current.state == "downloaded" then
        return false, "already downloaded"
    end

    if current.state == "queued" or
        current.state == "downloading" then
        return false, "request locked"
    end

    local existing_index =
        operation_index_for_key(key)
    if existing_index then
        return false, "duplicate operation"
    end

    local op_id = string.format(
        "dl:%s:%d",
        key,
        generation + 1
    )

    -- A catalog item may retain the durable ID of an older attempt. A new
    -- request owns a new local attempt identity until its POST is accepted
    -- and supplies the companion request ID.
    if type(item.device) ~= "table" then
        item.device = {}
    end
    item.device.download_request_id = nil
    item.device.download_operation_id = op_id
    item.device.state = "queued"

    log_transition("request", {
        key = key,
        op_id = op_id,
        queue_index = #operations + 1,
    })

    operations[#operations + 1] = {
        id = op_id,
        key = key,
        item = copy_item(item),
        status = "queued",
        dispatched = false,
        queue_index = #operations + 1,
    }

    local record = ensure_record(key, item)
    record.state = "queued"
    record.op_id = op_id
    record.queue_index = #operations
    record.failure = nil
    record.progress = nil
    record.updated_generation = generation + 1

    rebuild_operation_indexes()
    log_transition("enqueue", {
        key = key,
        op_id = op_id,
        queue_index = #operations,
    })
    bump({key})

    local dispatched = false
    local dispatch_reason = nil
    if #operations == 1 then
        local dispatch_ok
        dispatch_ok, dispatch_reason =
            try_dispatch_head("request")
        dispatched = dispatch_ok == true and
            dispatch_reason ~= "pending"
    end

    local status =
        dispatched and "downloading" or
        (
            (
                operations[1] and
                operations[1].key == key and
                operations[1].dispatched
            ) and "downloading" or "queued"
        )
    if type(item.device) == "table" then
        item.device.state = status
    end

    return true, {
        key = key,
        state = status,
        op_id = op_id,
        queue_index =
            operation_index_for_key(key) or
            #operations,
        dispatched = dispatched,
    }
end

function M.set_progress(item_or_key, percentage)
    local key = album_key(item_or_key)
    if not key then
        return false
    end

    local record = ensure_record(
        key,
        type(item_or_key) == "table" and
            item_or_key or nil
    )
    local op_index = operation_index_for_key(key)
    if op_index == 1 or
        record.state == "downloading" then
        record.state = "downloading"
        record.progress =
            tonumber(percentage)
        record.updated_generation =
            generation + 1
        bump({key})
        return true
    end

    return false
end

function M.complete(item_or_key)
    local key = album_key(item_or_key)
    if not key then
        return false
    end

    local record = ensure_record(
        key,
        type(item_or_key) == "table" and
            item_or_key or nil
    )
    local op_index, operation =
        operation_index_for_key(key)
    if op_index then
        table.remove(operations, op_index)
    end

    record.state = "downloaded"
    record.progress = nil
    record.failure = nil
    record.op_id = nil
    record.queue_index = nil
    record.local_complete = true
    record.local_partial = false
    record.local_usable = true
    record.updated_generation = generation + 1

    if type(record.item) == "table" then
        if type(record.item.device) ~= "table" then
            record.item.device = {}
        end
        record.item.device.state = "downloaded"
    end

    rebuild_operation_indexes()
    local changed = {key}
    local promoted =
        op_index == 1 and operations[1] or nil
    if promoted then
        changed[#changed + 1] = promoted.key
        log_transition("promote", {
            key = promoted.key,
            op_id = promoted.id,
            queue_index = 1,
        })
    end
    -- Local inventory/application reconciliation can report every already
    -- present album during startup.  That still needs to notify subscribers,
    -- but it is not a download lifecycle transition.  An owned operation is
    -- the discriminator for the meaningful completion log.
    if operation then
        log_transition("complete", {
            key = key,
            notify = table.concat(changed, ","),
        })
    end

    if promoted then
        local before_generation = generation
        try_dispatch_head("promote", {key})
        if generation == before_generation then
            bump(changed)
        end
    else
        bump(changed)
    end
    return true
end

function M.complete_attempt(attempt_ref)
    local attempt_id = exact_attempt_id(attempt_ref)
    local _, operation =
        operation_index_for_attempt(attempt_id)
    if not operation then
        if attempt_id ~= nil and
            remote_attempt_shadows[attempt_id] then
            remote_attempt_shadows[attempt_id] = nil
            try_dispatch_head(
                "remote-shadow-complete"
            )
            return true
        end
        return false,
            "operation attempt is no longer pending"
    end

    return M.complete(operation.key)
end

function M.fail(item_or_key, failure)
    local key = album_key(item_or_key)
    if not key then
        return false
    end

    local record = ensure_record(
        key,
        type(item_or_key) == "table" and
            item_or_key or nil
    )
    local op_index, operation =
        operation_index_for_key(key)

    record.state = "failed"
    record.progress = nil
    record.failure = type(failure) == "table" and
        failure or {
            message =
                tostring(
                    failure or "download failed"
                ),
            retriable = true,
        }
    record.updated_generation = generation + 1

    if op_index then
        table.remove(operations, op_index)
    end

    -- Retain a terminal failed marker without occupying the FIFO head.
    record.op_id =
        operation and operation.id or record.op_id
    record.queue_index = nil

    if type(record.item) == "table" then
        if type(record.item.device) ~= "table" then
            record.item.device = {}
        end
        record.item.device.state = "failed"
    end

    rebuild_operation_indexes()
    local changed = {key}
    local promoted =
        op_index == 1 and operations[1] or nil
    if promoted then
        changed[#changed + 1] = promoted.key
        log_transition("promote", {
            key = promoted.key,
            op_id = promoted.id,
            reason = "fail",
        })
    end
    log_transition("fail", {
        key = key,
        notify = table.concat(changed, ","),
    })

    if promoted then
        local before_generation = generation
        try_dispatch_head("promote-fail", {key})
        if generation == before_generation then
            bump(changed)
        end
    else
        bump(changed)
    end
    return true
end

function M.fail_attempt(attempt_ref, failure)
    local attempt_id = exact_attempt_id(attempt_ref)
    local _, operation =
        operation_index_for_attempt(attempt_id)
    if not operation then
        if attempt_id ~= nil and
            remote_attempt_shadows[attempt_id] then
            remote_attempt_shadows[attempt_id] = nil
            try_dispatch_head(
                "remote-shadow-fail"
            )
            return true
        end
        return false,
            "operation attempt is no longer pending"
    end

    return M.fail(operation.key, failure)
end

function M.promote()
    rebuild_operation_indexes()
    if operations[1] then
        try_dispatch_head("promote-manual")
        bump({operations[1].key})
        return M.lookup(operations[1].key)
    end
    return nil
end

function M.operations()
    local snapshot = {}
    for index, operation in ipairs(operations) do
        local status = "queued"
        if index == 1 and operation.dispatched then
            status = "downloading"
        elseif operation.status == "failed" then
            status = "failed"
        end
        snapshot[index] = {
            id = operation.id,
            key = operation.key,
            status = status,
            dispatched =
                operation.dispatched == true,
            request_id =
                operation.remote_request_id,
            attempt_conflicted =
                operation.remote_attempt_conflict == true,
            queue_index = index,
            item = operation.item,
        }
    end
    return snapshot
end

function M.active_operation()
    local ops = M.operations()
    return ops[1]
end

function M.pending_placeholders()
    local result = {}
    local seen = {}
    local cache = refresh_local_cache(false)

    local function push(entry_item, state, key, progress, op)
        if not key or seen[key] then
            return
        end

        if state ~= "queued" and
            state ~= "downloading" then
            return
        end

        seen[key] = true
        local item =
            type(entry_item) == "table" and
            copy_shallow(entry_item) or {}
        local album_id =
            album_id_from_key(key) or
            jellyfin_album_identity.album_id(item)
        local title =
            item.kind == "album" and
            (item.title or item.name) or
            item.album or
            item.album_name or
            item.title or
            item.name or
            "Downloading"
        local artist =
            item.artist or
            item.album_artist or
            ""
        local artist_id =
            item.jellyfin_artist_id or
            item.artist_id
        local server_total =
            tonumber(item.track_count) or
            tonumber(item.child_count) or
            (
                type(item.device) == "table" and
                tonumber(item.device.total_tracks)
            ) or nil
        local local_count =
            (album_id and
                cache.album_counts[album_id]) or 0

        -- Preserve Sync artwork identifiers for Local display without
        -- introducing per-row HTTP or filesystem scans.
        local artwork = item.artwork
        if type(artwork) ~= "table" then
            artwork = {}
        else
            artwork = copy_shallow(artwork)
        end
        if type(item.artwork_path) == "string" and
            item.artwork_path ~= "" and
            not artwork.thumbnail then
            artwork.thumbnail = item.artwork_path
            artwork.cover = artwork.cover or
                item.artwork_path
        end

        local placeholder = {
            id = album_id or key,
            jellyfin_id = album_id,
            key = key,
            kind = "album",
            name = title,
            title = title,
            artist = artist,
            jellyfin_artist_id = artist_id,
            artist_id = artist_id,
            track_count = server_total or 0,
            server_track_count = server_total,
            local_track_count = local_count,
            tracks = {},
            artwork = artwork,
            artwork_path = item.artwork_path,
            artwork_source = item.artwork_source,
            artwork_revision =
                item.artwork_revision,
            PrimaryImageTag =
                item.PrimaryImageTag or
                item.primary_image_tag,
            image_tag =
                item.image_tag or
                item.ImageTag,
            pending_download = true,
            download_state = state,
            download_progress = progress,
            download_op_id =
                op and op.id or nil,
            download_queue_index =
                op and op.queue_index or nil,
            jellyfin_track_ids =
                item.jellyfin_track_ids or
                item.child_track_ids,
        }

        result[#result + 1] = {
            item = placeholder,
            state = state,
            key = key,
            progress = progress,
            album = placeholder,
        }
    end

    for index, operation in ipairs(operations) do
        local projection = M.lookup(
            operation.item or operation.key
        )
        push(
            operation.item,
            projection and projection.state or
                (
                    index == 1 and
                    "downloading" or
                    "queued"
                ),
            operation.key,
            projection and projection.progress,
            {
                id = operation.id,
                queue_index = index,
            }
        )
    end

    for key, record in pairs(by_key) do
        if not seen[key] then
            push(
                record.item,
                record.state,
                key,
                record.progress,
                {
                    id = record.op_id,
                    queue_index =
                        record.queue_index,
                }
            )
        end
    end

    return result
end

function M.sync_apply_progress(progress)
    if type(progress) ~= "table" then
        return false
    end

    local action = progress.action
    local item =
        type(action) == "table" and
        action.item or nil
    local key = album_key(item)
    if not key then
        return false
    end

    local bytes = tonumber(progress.bytes)
    local total =
        tonumber(progress.bytes_total)
    local percentage = nil
    if bytes and total and total > 0 then
        percentage = math.max(
            0,
            math.min(
                100,
                math.floor(bytes * 100 / total)
            )
        )
    elseif progress.completed and
        progress.total and
        progress.total > 0 then
        percentage = math.max(
            0,
            math.min(
                100,
                math.floor(
                    progress.completed * 100 /
                    progress.total
                )
            )
        )
    end

    if percentage == nil then
        return false
    end

    return M.set_progress(key, percentage)
end

function M.complete_media_items(items)
    if type(items) ~= "table" then
        return {}
    end

    local changed = {}
    local seen = {}

    for _, item in ipairs(items) do
        local key = album_key(item)
        if key and not seen[key] then
            seen[key] = true
            if M.complete(key) then
                changed[#changed + 1] = key
            end
        end
    end

    return changed
end

M._log = log_transition

function M.subscribe(callback)
    if type(callback) ~= "function" then
        return function()
        end
    end

    local id = next_subscriber_id
    next_subscriber_id = next_subscriber_id + 1
    subscribers[id] = {
        callback = callback,
        dead = false,
    }

    return function()
        local entry = subscribers[id]
        if entry then
            entry.dead = true
        end
        subscribers[id] = nil
    end
end

function M.notify_changed(keys)
    if type(keys) == "string" then
        keys = {keys}
    end
    return bump(keys or {})
end

function M.can_download(item_or_key)
    local projection = M.lookup(item_or_key)
    return projection.can_download == true
end

function M.request_locked(item_or_key)
    local projection = M.lookup(item_or_key)
    return projection.request_locked == true
end

function M.show_view_local(item_or_key)
    local projection = M.lookup(item_or_key)
    return projection.show_view_local == true
end

function M.icon_kind(item_or_key)
    local projection = M.lookup(item_or_key)
    return projection.icon_kind
end

function M.reset_for_tests()
    generation = 0
    operations = {}
    by_key = {}
    subscribers = {}
    next_subscriber_id = 1
    -- Keep dispatcher wiring; tests that need isolation call set_dispatcher.
    dispatch_inflight = nil
    remote_attempt_shadows = {}
    local_cache = {
        generation = -1,
        track_ids = {},
        album_counts = {},
        library = nil,
    }
end

-- Exposed for adapters that still speak companion interim names.
function M.normalize_state(state)
    return normalize_public_state(state) or
        choose_state({state})
end

return M
