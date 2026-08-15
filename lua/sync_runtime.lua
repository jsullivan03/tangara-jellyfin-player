local lvgl = require("lvgl")
local json = require("json")
local json_encode = require("json_encode")
local sync_apply = require("sync_apply")
local sync_artwork_cache =
    require("sync_artwork_cache")
local sync_config = require("sync_config")
local sync_library_refresh =
    require("sync_library_refresh")
local sync_library_artwork =
    require("sync_library_artwork")
local sync_library_view =
    require("sync_library_view")
local sync_inventory_report =
    require("sync_inventory_report")
local sync_operation_flush =
    require("sync_operation_flush")
local sync_offline_bootstrap =
    require("sync_offline_bootstrap")
local sync_operation_queue =
    require("sync_operation_queue")
local sync_managed_paths = require("sync_managed_paths")
local sync_manifest_state = require("sync_manifest_state")
local sync_reconcile = require("sync_reconcile")
local sync_client = require("sync_client")
local time = require("time")
local jellyfin_album_identity =
    require("jellyfin_album_identity")
local jellyfin_track_identity =
    require("jellyfin_track_identity")

local M = {}

local function download_state()
    local ok, module = pcall(
        require,
        "sync_download_state"
    )
    if ok then
        return module
    end
    return nil
end

local poll_period_ms = 500
local refresh_interval_ms = 60000
local retry_interval_ms = 15000
local durable_requests_interval_ms = 60000

local timer = nil
local next_refresh_at = 0
local next_apply_at = 0
local next_operation_at = 0
local next_library_at = 0
local last_result = nil
local last_operation_result = nil
local last_library_result = nil
local last_artwork_result = nil
local last_apply_result = nil
local last_inventory_result = nil
local last_offline_bootstrap_result = nil
local active_manifest = nil
local active_plan = nil
local active_plan_error = nil
local active_plan_authoritative = false
local managed_paths_recovered = false
local inventory_report_pending = true
local next_inventory_progress_at = 0
local manifest_refresh_request_generation = 0
local manifest_refresh_completed_generation = 0
local manifest_refresh_active_generation = nil
local state_generation = 0
local content_generation = 0
local optimistic_item_states = {}
local optimistic_items = {}
local download_operation_active = false
local download_operation_finalizing = false
local download_operation_needs_library = false
local download_operation_waiting_artwork = false
local download_operation_error = nil
local manifest_refresh_error = nil
local failed_item_id = nil
local initial_sync_active = false
local initial_sync_signature = nil
local initial_sync_failed = false
local next_durable_requests_at = 0
local durable_requests_initial = true
local durable_startup_attempt_ids = nil
local last_durable_requests_result = nil
local local_downloaded_at = {}
local incomplete_download_keys = {}
local recency_loaded = false
local bump_state
local RECENCY_VERSION = 1
local RECENCY_FILE_NAME =
    "/.tangara_device_download_recency.json"

local function stable_item_id(item)
    return jellyfin_album_identity.item_id(
        item
    )
end

local function item_attempt_id(item)
    if type(item) ~= "table" then
        return nil
    end

    local device = type(item.device) == "table" and
        item.device or {}
    return device.download_request_id or
        device.download_operation_id or
        item.download_request_id or
        item.download_operation_id
end

local function local_download_key(item_or_key)
    if type(item_or_key) ~= "table" then
        return jellyfin_album_identity.key(
            item_or_key
        )
    end

    -- Apply media items are manifest tracks. Their jellyfin_id is the
    -- track id, so album_identity.key() would stamp recency on the track
    -- instead of the Local album. Prefer the album id whenever it differs.
    local album_id =
        jellyfin_album_identity.canonical_id(
            item_or_key.album_id or
            item_or_key.parent_id or
            item_or_key.jellyfin_album_id
        )
    local item_id =
        jellyfin_album_identity.canonical_id(
            item_or_key.jellyfin_id or
            item_or_key.id
        )
    if album_id and
        (
            not item_id or
            album_id ~= item_id
        ) then
        return "id:" .. album_id
    end

    if item_or_key.kind == "track" or
        item_or_key.kind == "Audio" then
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

local function positive_timestamp(value)
    local timestamp = tonumber(value)
    if type(timestamp) == "number" and
        timestamp > 0 then
        return timestamp
    end
    return nil
end

local function request_completed_at(request)
    if type(request) ~= "table" then
        return 0
    end

    return positive_timestamp(
        request.updated_at
    ) or positive_timestamp(
        request.created_at
    ) or 0
end

local function recency_storage_path()
    local ok, device = pcall(require, "device")
    if not ok or
        type(device) ~= "table" or
        type(device.storage_root) ~=
            "function" then
        return nil
    end

    local root_ok, root =
        pcall(device.storage_root)
    if not root_ok or
        type(root) ~= "string" or
        root == "" then
        return nil
    end

    return root:gsub("/+$", "") ..
        RECENCY_FILE_NAME
end

local function load_local_download_recency()
    if recency_loaded then
        return
    end

    recency_loaded = true

    local path = recency_storage_path()
    if not path then
        return
    end

    local file = io.open(path, "rb")
    if not file then
        return
    end

    local contents = file:read("*a")
    file:close()

    local decoded_ok, decoded = pcall(
        json.decode,
        contents
    )
    if not decoded_ok or
        type(decoded) ~= "table" or
        decoded.version ~= RECENCY_VERSION or
        type(decoded.completed) ~= "table" then
        return
    end

    for key, timestamp in pairs(
        decoded.completed
    ) do
        local completed =
            positive_timestamp(timestamp)
        if type(key) == "string" and
            key ~= "" and
            completed and
            completed >
                (local_downloaded_at[key] or 0) then
            local_downloaded_at[key] =
                completed
        end
    end
end

local function save_local_download_recency()
    local path = recency_storage_path()
    if not path then
        return
    end

    local encoded_ok, contents = pcall(
        json_encode.encode,
        {
            version = RECENCY_VERSION,
            completed = local_downloaded_at,
        }
    )
    if not encoded_ok or
        type(contents) ~= "string" or
        contents == "" then
        return
    end

    local temporary = path .. ".tmp"
    local file = io.open(temporary, "wb")
    if not file then
        return
    end

    local wrote = file:write(contents)
    if wrote then
        file:flush()
    end
    file:close()
    if not wrote then
        os.remove(temporary)
        return
    end

    os.remove(path)
    os.rename(temporary, path)
end

local function wall_clock()
    if os and type(os.time) == "function" then
        local ok, value = pcall(os.time)
        if ok then
            return positive_timestamp(value)
        end
    end

    return nil
end

local function mark_incomplete_download(item_or_key)
    local key = local_download_key(item_or_key)
    if key then
        incomplete_download_keys[key] = true
    end
    return key
end

local function record_completed_download(
    item_or_key,
    timestamp
)
    load_local_download_recency()
    local key = local_download_key(item_or_key)
    if not key then
        return false
    end

    incomplete_download_keys[key] = nil

    local stamp =
        positive_timestamp(timestamp) or
        wall_clock()
    if not stamp then
        return false
    end

    if stamp <= (local_downloaded_at[key] or 0) then
        return false
    end

    local_downloaded_at[key] = stamp
    save_local_download_recency()
    local index_ok, index = pcall(
        require,
        "jellyfin_local_index"
    )
    if index_ok and
        type(index) == "table" and
        type(index.invalidate) ==
            "function" then
        index.invalidate(
            "local download completed"
        )
    end
    bump_state(false)
    return true
end

local function track_recency_key(track)
    if type(track) ~= "table" then
        return nil
    end

    local track_id =
        jellyfin_track_identity.canonical_id(
            track.jellyfin_id or track.id
        )
    if not track_id then
        return nil
    end

    return "id:" .. track_id
end

local function fold_track_recency_into_albums(items)
    load_local_download_recency()
    local remap = {}

    local function remember(track, album_key)
        local track_key = track_recency_key(track)
        if track_key and album_key and
            track_key ~= album_key then
            remap[track_key] = album_key
        end
    end

    for _, item in ipairs(items or {}) do
        if type(item) == "table" then
            local album_key =
                local_download_key(item)
            if type(item.tracks) == "table" then
                for _, track in ipairs(item.tracks) do
                    remember(track, album_key)
                end
            else
                remember(item, album_key)
            end
        end
    end

    local folded = {}
    local changed = false
    for key, stamp in pairs(local_downloaded_at) do
        local album_key = remap[key] or key
        if album_key ~= key then
            changed = true
        end
        if stamp > (folded[album_key] or 0) then
            folded[album_key] = stamp
        end
    end

    if not changed then
        return false
    end

    local_downloaded_at = folded
    save_local_download_recency()
    return true
end

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

local function library_track(item_id)
    local library = sync_library_view.current()

    if type(library) ~= "table" then
        return nil
    end

    local function find(items)
        for _, item in ipairs(items or {}) do
            if stable_item_id(item) == item_id then
                return item
            end
        end

        return nil
    end

    local favorites =
        type(library.favorites) == "table" and
        library.favorites.items or {}
    local found = find(favorites)

    if found then
        return found
    end

    for _, playlist in ipairs(
        library.playlists or {}
    ) do
        found = find(playlist.items)

        if found then
            return found
        end
    end

    return nil
end

bump_state = function(content_changed)
    state_generation = state_generation + 1

    if content_changed then
        content_generation =
            content_generation + 1
    end
end

local function set_optimistic_item(item, state)
    local item_id = stable_item_id(item)

    if not item_id then
        return false
    end

    optimistic_item_states[item_id] =
        state or "queued"
    optimistic_items[item_id] =
        copy_value(item)

    return true
end

local function child_track_ids(item)
    if type(item) ~= "table" then
        return {}
    end

    local device_state =
        type(item.device) == "table" and
        item.device or {}
    local source =
        item.jellyfin_track_ids or
        item.child_track_ids or
        device_state.jellyfin_track_ids or
        device_state.child_track_ids or {}
    local result = {}
    local seen = {}

    for _, value in ipairs(source) do
        local item_id =
            jellyfin_track_identity.stable_id(
                value
            )

        if item_id and not seen[item_id] then
            seen[item_id] = true
            result[#result + 1] = item_id
        end
    end

    return result
end

local function clear_optimistic_item(item)
    local item_id =
        type(item) == "string" and
        item or stable_item_id(item)
    if not item_id then
        return false
    end

    local ids = {[item_id] = true}
    local album_id =
        type(item) == "table" and
        jellyfin_album_identity.album_id(item) or nil
    if album_id then
        ids[album_id] = true
    end

    if type(item) == "table" then
        for _, child_id in ipairs(
            child_track_ids(item)
        ) do
            ids[child_id] = true
        end
    end

    -- Apply failures may identify one media action rather than its album.
    -- Clear only optimistic entries belonging to that same canonical album.
    if album_id then
        for optimistic_id, optimistic_item in pairs(
            optimistic_items
        ) do
            if jellyfin_album_identity.album_id(
                    optimistic_item
                ) == album_id then
                ids[optimistic_id] = true
                for _, child_id in ipairs(
                    child_track_ids(
                        optimistic_item
                    )
                ) do
                    ids[child_id] = true
                end
            end
        end
    end

    local cleared = false
    for id in pairs(ids) do
        if optimistic_item_states[id] ~= nil or
            optimistic_items[id] ~= nil then
            cleared = true
        end
        optimistic_item_states[id] = nil
        optimistic_items[id] = nil
    end

    return cleared
end

local function mark_operation_active()
    download_operation_active = true
    -- A promoted FIFO successor can be accepted while the prior operation is
    -- still finishing its Local library/artwork pass. Do not cancel that
    -- existing finalization; its completion will retain the successor below.
    download_operation_error = nil
    manifest_refresh_error = nil
    failed_item_id = nil
    bump_state(false)
end

local function record_manifest_refresh_error(
    error_message
)
    manifest_refresh_error =
        error_message or
        "manifest refresh failed"
    initial_sync_failed = initial_sync_active
end

local function fail_operation(error_message, item)
    local preserve_finalization =
        item ~= nil and
        (
            download_operation_finalizing or
            download_operation_needs_library or
            download_operation_waiting_artwork
        )
    local remaining_owner_work = false
    local owner = download_state()
    if owner and type(owner.operations) == "function" then
        remaining_owner_work =
            #(owner.operations() or {}) > 0
    end

    download_operation_active =
        remaining_owner_work or
        preserve_finalization
    if not preserve_finalization then
        download_operation_finalizing = false
        download_operation_needs_library = false
        download_operation_waiting_artwork = false
    end
    download_operation_error =
        not remaining_owner_work and
        not preserve_finalization and
        (error_message or "download failed") or nil
    clear_optimistic_item(item)
    failed_item_id = stable_item_id(item)
    initial_sync_failed = initial_sync_active
    bump_state(false)
end

function M.dispatch_download(item, operation)
    local sync_catalog =
        package.loaded["sync_catalog"] or
        require("sync_catalog")
    if type(sync_catalog.queue) ~= "function" then
        return false, "catalog queue unavailable"
    end

    local operation_ref = operation and
        operation.id or operation
    return sync_catalog.queue(item, function(result)
        local owner = download_state()
        local accepted = type(result) == "table" and
            result.ok == true
        local payload = type(result) == "table" and
            result.payload or nil
        local request_payload =
            type(payload) == "table" and
            payload.request or nil
        local detail = {
            status = type(result) == "table" and
                result.status or nil,
            replayed = type(payload) == "table" and
                (
                    payload.replayed == true or
                    payload.already_durable == true
                ) or false,
            error = type(result) == "table" and
                result.error or "dispatch failed",
            request_id =
                type(request_payload) == "table" and
                request_payload.id or
                (
                    type(payload) == "table" and
                    payload.request_id or nil
                ),
        }

        local resolved = false
        if owner and
            type(owner.resolve_dispatch) == "function" then
            resolved = owner.resolve_dispatch(
                operation_ref,
                accepted,
                detail
            )
        end

        -- The HTTP callback belongs to one exact FIFO attempt. A retry may
        -- reuse the album key, so no album-keyed runtime mutation is safe
        -- after the owner rejects this operation ID as stale/superseded.
        if resolved ~= true then
            return
        end

        if accepted then
            if detail.request_id ~= nil then
                item.device = item.device or {}
                item.device.download_request_id =
                    detail.request_id
            end
            M.note_queued(item)
            M.request_refresh()
        else
            M.note_failed(item)
        end
    end)
end

local function complete_operation()
    local owner = download_state()
    local remaining_operations =
        owner and type(owner.operations) == "function" and
        owner.operations() or {}
    local remaining_keys = {}
    for _, operation in ipairs(remaining_operations) do
        local key = jellyfin_album_identity.key(
            operation.key or operation.item
        )
        if key then
            remaining_keys[key] = true
        end
    end

    download_operation_active =
        #remaining_operations > 0
    download_operation_finalizing = false
    download_operation_needs_library = false
    download_operation_waiting_artwork = false
    download_operation_error = nil
    failed_item_id = nil
    local retained_states = {}
    local retained_items = {}
    for item_id, optimistic_item in pairs(
        optimistic_items
    ) do
        local key = jellyfin_album_identity.key(
            optimistic_item
        )
        local download_key =
            local_download_key(optimistic_item)
        if download_key and
            not remaining_keys[download_key] then
            record_completed_download(
                optimistic_item
            )
        end
        if key and remaining_keys[key] then
            retained_states[item_id] =
                optimistic_item_states[item_id]
            retained_items[item_id] =
                optimistic_item
        end
    end
    for _, operation in ipairs(remaining_operations) do
        local item = operation.item
        local item_id = stable_item_id(item)
        if item_id and not retained_items[item_id] then
            retained_states[item_id] = "queued"
            retained_items[item_id] = copy_value(item)
        end
    end
    optimistic_item_states = retained_states
    optimistic_items = retained_items

    if initial_sync_active and
        not download_operation_active then
        sync_offline_bootstrap
            .mark_initial_sync_complete(
                initial_sync_signature or
                "complete"
            )
        initial_sync_active = false
        initial_sync_failed = false
    end

    bump_state(true)

    if owner and
        type(owner.reconcile) == "function" then
        owner.reconcile({
            force_local = true,
            notify = true,
        })
    end
end

local function reconcile_optimistic_items(
    manifest,
    plan
)
    if type(manifest) ~= "table" or
        type(plan) ~= "table" then
        return
    end

    local pending = {}

    for _, action in ipairs(
        plan.actions or {}
    ) do
        local item_id =
            stable_item_id(action.item)

        if item_id then
            pending[item_id] = true
        end
    end

    for _, item in ipairs(
        manifest.items or {}
    ) do
        local item_id = stable_item_id(item)

        if item_id and not pending[item_id] then
            optimistic_item_states[item_id] = nil
            optimistic_items[item_id] = nil
        end
    end

    for item_id, item in pairs(
        optimistic_items
    ) do
        if item.kind == "album" then
            local children = child_track_ids(item)
            local child_pending = false

            for _, child_id in ipairs(children) do
                if pending[child_id] then
                    child_pending = true
                    break
                end
            end

            if #children > 0 and
                not child_pending then
                optimistic_item_states[item_id] = nil
                optimistic_items[item_id] = nil
            end
        end
    end
end

local function update_plan(manifest, authoritative)
    if type(manifest) ~= "table" then
        active_manifest = nil
        active_plan = nil
        active_plan_error =
            "active manifest is unavailable"
        active_plan_authoritative = false
        managed_paths_recovered = false

        return nil, active_plan_error, false
    end

    local managed_paths, inventory_error, recovered =
        sync_managed_paths.load()

    if not managed_paths then
        active_manifest = manifest
        active_plan = nil
        active_plan_error = inventory_error
        active_plan_authoritative = false
        managed_paths_recovered = false

        return nil, inventory_error, false
    end

    local plan, plan_error =
        sync_reconcile.plan(
            manifest,
            managed_paths
        )

    if not plan then
        active_manifest = manifest
        active_plan = nil
        active_plan_error = plan_error
        active_plan_authoritative = false
        managed_paths_recovered = recovered

        return nil, plan_error, recovered
    end

    active_manifest = manifest
    active_plan = plan
    active_plan_error = nil
    active_plan_authoritative =
        authoritative == true
    managed_paths_recovered = recovered

    reconcile_optimistic_items(
        manifest,
        plan
    )
    bump_state(false)

    return plan, nil, recovered
end

local function attach_plan(result, authoritative)
    if result.ok and result.manifest then
        local plan, plan_error, recovered =
            update_plan(
                result.manifest,
                authoritative
            )

        result.plan = plan
        result.plan_error = plan_error
        result.managed_paths_recovered =
            recovered
    else
        result.plan = active_plan
        result.plan_error =
            active_plan_error
        result.managed_paths_recovered =
            managed_paths_recovered
    end

    result.plan_authoritative =
        active_plan_authoritative

    return result
end

local function update_last_result_plan()
    if type(last_result) ~= "table" then
        return
    end

    last_result.plan = active_plan
    last_result.plan_error =
        active_plan_error
    last_result.plan_authoritative =
        active_plan_authoritative
    last_result.managed_paths_recovered =
        managed_paths_recovered
end

local function schedule_next(result, now)
    if result.ok then
        next_refresh_at =
            now + refresh_interval_ms
    else
        next_refresh_at =
            now + retry_interval_ms
    end
end

local function start_apply(now, status)
    if sync_apply.busy() then
        return false
    end

    if not active_plan_authoritative then
        return false
    end

    if type(active_plan) ~= "table" or
        type(active_plan.actions) ~= "table" or
        #active_plan.actions == 0 then
        return false
    end

    if now < next_apply_at then
        return false
    end

    status = status or sync_config.status()

    if not status.connected then
        return false
    end

    -- Bind this apply session to the exact owner attempt that exists when the
    -- plan starts. Manifest media items are content-keyed and do not carry
    -- asynchronous request identity on their own.
    local owner = download_state()
    if owner and
        type(owner.operations) == "function" and
        type(owner.key) == "function" then
        local attempts_by_key = {}
        for _, operation in ipairs(owner.operations()) do
            attempts_by_key[operation.key] = {
                operation_id = operation.id,
                request_id = operation.request_id,
                conflicted =
                    operation.attempt_conflicted == true,
            }
        end
        for _, action in ipairs(active_plan.actions) do
            local item = type(action) == "table" and
                action.item or nil
            local key = item and owner.key(item) or nil
            local attempt = key and
                attempts_by_key[key] or nil
            if item then
                item.device = item.device or {}
                item.device.download_attempt_ambiguous = nil
                item.device.download_operation_id = nil
                item.device.download_request_id = nil
            end
            if attempt then
                if attempt.conflicted then
                    item.device.download_attempt_ambiguous =
                        true
                else
                    item.device.download_operation_id =
                        attempt.operation_id
                    item.device.download_request_id =
                        attempt.request_id
                end
            end
        end
    end

    local started, start_error =
        sync_apply.start(active_plan)

    if not started then
        last_apply_result = {
            ok = false,
            error = start_error,
            completed = 0,
            total = #active_plan.actions,
            remaining = #active_plan.actions,
        }

        next_apply_at =
            now + retry_interval_ms

        return false, start_error
    end

    last_apply_result = nil
    mark_operation_active()

    return true
end

local function finish_apply(result, now)
    last_apply_result = result

    if active_manifest then
        update_plan(
            active_manifest,
            active_plan_authoritative
        )
    end

    if result.ok then
        next_apply_at = now
    else
        next_apply_at =
            now + retry_interval_ms
    end

    update_last_result_plan()

    if type(last_result) == "table" then
        last_result.apply = result
    end

    inventory_report_pending = true

    if result.ok then
        load_local_download_recency()
        for _, item in ipairs(
            result.media_items or {}
        ) do
            local key = local_download_key(item)
            if key and
                (
                    incomplete_download_keys[key] or
                    local_downloaded_at[key] == nil
                ) then
                record_completed_download(item)
            end
        end
    end

    bump_state(true)

    local owner = download_state()
    local failed_item = nil
    local terminal_is_current = true
    if owner then
        if result.ok then
            if type(owner.complete_media_items) ==
                    "function" then
                owner.complete_media_items(
                    result.media_items or {}
                )
            end
            if type(owner.reconcile) ==
                    "function" then
                owner.reconcile({
                    force_local = true,
                    notify = true,
                })
            end
        else
            local failed_action =
                result.failed_action or
                (
                    type(result.download) ==
                        "table" and
                    result.download.item or nil
                )
            failed_item =
                type(failed_action) == "table" and
                failed_action.item or
                failed_action
            local attempt_ambiguous =
                type(failed_item) == "table" and
                type(failed_item.device) == "table" and
                failed_item.device
                    .download_attempt_ambiguous == true
            local attempt_id =
                item_attempt_id(failed_item)
            if attempt_ambiguous then
                terminal_is_current = false
            elseif attempt_id ~= nil and
                type(owner.fail_attempt) == "function" then
                terminal_is_current =
                    owner.fail_attempt(attempt_id, {
                        message =
                            result.error or
                            "download failed",
                        retriable = true,
                    }) == true
            end
        end
    end

    if result.ok then
        download_operation_active = true
        download_operation_finalizing = true
        download_operation_needs_library = true
        download_operation_waiting_artwork = false
        download_operation_error = nil
        next_library_at = 0
    else
        if terminal_is_current then
            if not failed_item then
                local failed_action =
                    result.failed_action or
                    (
                        type(result.download) == "table" and
                        result.download.item or nil
                    )
                failed_item =
                    type(failed_action) == "table" and
                    failed_action.item or
                    failed_action
            end
            fail_operation(
                result.error,
                failed_item
            )
        end
    end
end

local function start_operations(
    now,
    status
)
    if now < next_operation_at or
        not status.connected then
        return false
    end

    local queue_status, queue_error =
        sync_operation_queue.status()

    if queue_error then
        last_operation_result = {
            ok = false,
            error = queue_error,
            blocked = true,
        }

        next_operation_at =
            now + retry_interval_ms

        return false
    end

    if queue_status.pending == 0 then
        next_operation_at = now + 5000
        return false
    end

    if queue_status.blocked then
        last_operation_result = {
            ok = false,
            error = queue_status.error,
            blocked = true,
            pending =
                queue_status.pending,
        }

        next_operation_at =
            now + 60000

        return false
    end

    local started, start_error =
        sync_operation_flush.start()

    if not started then
        last_operation_result = {
            ok = false,
            error = start_error,
            blocked = false,
            pending =
                queue_status.pending,
        }

        next_operation_at =
            now + retry_interval_ms

        return false
    end

    return true
end

local function finish_operations(
    result,
    now
)
    last_operation_result = result

    if result.ok then
        if result.pending and
            result.pending > 0 then
            next_operation_at = now
        else
            next_operation_at = now + 5000
        end

        next_refresh_at = 0
        next_library_at = 0
    else
        next_operation_at =
            now + retry_interval_ms
    end
end

local function start_library(
    now,
    status
)
    if now < next_library_at or
        not status.connected then
        return false
    end

    local started, start_error =
        sync_library_refresh.start()

    if not started then
        last_library_result = {
            ok = false,
            error = start_error,
        }

        next_library_at =
            now + retry_interval_ms

        return false
    end

    return true
end

local function finish_library(
    result,
    now
)
    last_library_result = result

    if result.ok then
        local started, start_error =
            sync_library_artwork.start(
                result.library
            )

        result.artwork_started =
            started
        result.artwork_error =
            start_error

        if not started then
            last_artwork_result = {
                ok = false,
                error = start_error,
            }
        end

        next_library_at =
            now + refresh_interval_ms
        bump_state(true)

        if download_operation_needs_library then
            download_operation_needs_library = false

            if started then
                download_operation_waiting_artwork = true
            else
                complete_operation()
            end
        end
    else
        next_library_at =
            now + retry_interval_ms

        if download_operation_needs_library then
            fail_operation(result.error, nil)
        end
    end
end

local function current_apply_keys()
    local keys = {}
    if sync_apply.busy() == true and
        type(sync_apply.pending_items) == "function" then
        for _, entry in ipairs(
            sync_apply.pending_items() or {}
        ) do
            local key = jellyfin_album_identity.key(
                entry.item
            )
            if key then
                keys[key] = true
            end
        end
    end
    return keys
end

local function finish_durable_requests(result)
    last_durable_requests_result = result
    local now = time.ticks()
    if type(result) ~= "table" or
        result.ok ~= true or
        type(result.payload) ~= "table" then
        next_durable_requests_at =
            now + retry_interval_ms
        return
    end

    local latest_by_key = {}
    local observed_remote_keys = {}
    local download_recency_changed = false
    load_local_download_recency()
    for _, request in ipairs(
        result.payload.requests or {}
    ) do
        if type(request) == "table" and
            request.kind == "album" and
            type(request.root_jellyfin_id) ==
                "string" then
            local key = jellyfin_album_identity.key({
                jellyfin_id =
                    request.root_jellyfin_id,
                kind = "album",
            })
            local existing = key and
                latest_by_key[key] or nil
            local timestamp = tonumber(
                request.created_at or
                request.updated_at
            ) or 0
            if key and
                (
                    request.state == "queued" or
                    request.state == "downloading"
                ) then
                incomplete_download_keys[key] = true
            end

            local completed_timestamp =
                request_completed_at(request)

            if key and
                request.state == "downloaded" and
                completed_timestamp > 0 then
                local stamp = completed_timestamp
                if incomplete_download_keys[key] then
                    -- Companion often keeps created_at == updated_at at
                    -- queue time. A live incomplete -> downloaded
                    -- transition must sort as "downloaded now".
                    local now_stamp = wall_clock()
                    if now_stamp and
                        now_stamp > stamp then
                        stamp = now_stamp
                    end
                    incomplete_download_keys[key] =
                        nil
                end
                if stamp >
                    (local_downloaded_at[key] or 0) then
                    local_downloaded_at[key] = stamp
                    download_recency_changed = true
                end
            end
            local existing_timestamp =
                existing and tonumber(
                    existing.created_at or
                    existing.updated_at
                ) or -1
            if key and
                (
                    not existing or
                    timestamp > existing_timestamp or
                    (
                        timestamp == existing_timestamp and
                        tostring(request.id or "") >
                            tostring(existing.id or "")
                    )
                ) then
                latest_by_key[key] = request
            end
        end
    end
    local requests = {}
    for key, request in pairs(latest_by_key) do
        requests[#requests + 1] = request
        if request.state == "queued" or
            request.state == "downloading" then
            observed_remote_keys[key] = true
        end
    end
    table.sort(requests, function(left, right)
        local left_time = tonumber(
            left.created_at or left.updated_at
        ) or 0
        local right_time = tonumber(
            right.created_at or right.updated_at
        ) or 0
        if left_time ~= right_time then
            return left_time < right_time
        end
        return tostring(left.id or "") <
            tostring(right.id or "")
    end)
    local owner = download_state()
    if owner then
        if type(owner.reconcile) == "function" then
            owner.reconcile({force_local = true})
        end
        for _, request in ipairs(requests) do
            if type(request) == "table" and
                type(request.root_jellyfin_id) ==
                    "string" and
                request.kind == "album" then
                local item = {
                    jellyfin_id =
                        request.root_jellyfin_id,
                    id = request.root_jellyfin_id,
                    kind = "album",
                    title = request.title or
                        request.name or
                        "Downloading",
                    artist = request.artist or "",
                    track_count =
                        request.total_tracks,
                    jellyfin_track_ids =
                        request.track_ids,
                    device = {
                        state = request.state,
                    },
                }
                if request.state == "downloaded" and
                    request.id ~= nil and
                    type(owner.complete_attempt) ==
                        "function" then
                    owner.complete_attempt(request.id)
                elseif request.state == "failed" and
                    request.id ~= nil and
                    type(owner.fail_attempt) ==
                        "function" then
                    local failed_current_attempt =
                        owner.fail_attempt(request.id, {
                        message =
                            request.error or
                            "companion download failed",
                        retriable = true,
                    })
                    if failed_current_attempt == true then
                        fail_operation(
                            request.error or
                                "companion download failed",
                            item
                        )
                    end
                end
            end
        end
        if type(owner.reconcile_startup) == "function" then
            local local_active_keys =
                current_apply_keys()
            local startup_result =
                owner.reconcile_startup({
                    remote_operations = requests,
                    remote_keys = observed_remote_keys,
                    local_active_keys = local_active_keys,
                    remote_busy =
                        sync_apply.busy() == true,
                    cleanup_unconfirmed =
                        durable_requests_initial,
                    cleanup_attempt_ids =
                        durable_startup_attempt_ids,
                })

            -- A successful omission is negative evidence only for operations
            -- the owner actually removed. Keep optimism for retained local
            -- queue/in-flight work and independently active apply work.
            local retained_keys = {}
            local retained_operations =
                type(startup_result) == "table" and
                startup_result.operations or nil
            if type(retained_operations) ~= "table" and
                type(owner.operations) == "function" then
                retained_operations = owner.operations()
            end
            for _, operation in ipairs(
                retained_operations or {}
            ) do
                local key = jellyfin_album_identity.key(
                    operation.key or operation.item
                )
                if key then
                    retained_keys[key] = true
                end
            end

            local stale_optimistic_items = {}
            local stale_keys = {}
            for _, item in pairs(optimistic_items) do
                local key = jellyfin_album_identity.key(item)
                if key and
                    not stale_keys[key] and
                    not observed_remote_keys[key] and
                    not local_active_keys[key] and
                    not retained_keys[key] then
                    stale_keys[key] = true
                    stale_optimistic_items[
                        #stale_optimistic_items + 1
                    ] = item
                end
            end
            local optimism_cleared = false
            for _, item in ipairs(
                stale_optimistic_items
            ) do
                optimism_cleared =
                    clear_optimistic_item(item) or
                    optimism_cleared
            end
            if optimism_cleared then
                bump_state(false)
            end
        end
    end

    for _, request in ipairs(requests) do
        if type(request) == "table" and
            (
                request.state == "queued" or
                request.state == "downloading"
            ) then
            download_operation_active = true
            download_operation_error = nil
            break
        end
    end

    if download_recency_changed then
        -- Local "New" follows when media was downloaded to this device, not
        -- Jellyfin's original DateCreated. Durable request history is the
        -- authoritative cross-restart source for that device-side recency.
        save_local_download_recency()
        bump_state(false)
    end

    durable_requests_initial = false
    durable_startup_attempt_ids = nil
    next_durable_requests_at =
        now + durable_requests_interval_ms
end

local function poll_shared_catalog(now)
    local sync_catalog =
        package.loaded["sync_catalog"] or
        require("sync_catalog")
    local kind = type(sync_catalog.pending_kind) ==
            "function" and
        sync_catalog.pending_kind() or nil

    if kind == "queue" or
        kind == "download_requests" then
        sync_catalog.poll()
        return true
    end

    -- UI catalog/search traffic owns the same transport. Let its mounted
    -- poller consume the response rather than stealing a screen result here.
    if kind ~= nil then
        return true
    end

    if now < next_durable_requests_at or
        sync_client.busy() then
        return false
    end

    if type(sync_catalog.download_requests) ~= "function" then
        next_durable_requests_at =
            now + retry_interval_ms
        return false
    end

    local started, start_error =
        sync_catalog.download_requests(
            finish_durable_requests
        )
    if started then
        return true
    end

    last_durable_requests_result = {
        ok = false,
        error = start_error,
    }
    next_durable_requests_at =
        now + retry_interval_ms
    return false
end

local function poll()
    local now = time.ticks()

    if poll_shared_catalog(now) then
        return
    end

    if sync_artwork_cache.busy() then
        sync_artwork_cache.poll()
        return
    end

    if sync_inventory_report.busy() then
        local inventory_result =
            sync_inventory_report.poll()

        if inventory_result then
            last_inventory_result =
                inventory_result
        end

        return
    end

    if sync_library_artwork.busy() then
        local artwork_result =
            sync_library_artwork.poll()

        if artwork_result then
            last_artwork_result =
                artwork_result

            if type(last_library_result) ==
                    "table" then
                last_library_result.artwork =
                    artwork_result
            end

            if download_operation_waiting_artwork then
                if artwork_result.ok == false then
                    last_artwork_result = artwork_result
                end

                complete_operation()
            end
        end

        return
    end

    if sync_offline_bootstrap.busy() then
        local bootstrap_result =
            sync_offline_bootstrap.poll()

        if bootstrap_result then
            last_offline_bootstrap_result =
                bootstrap_result

            if bootstrap_result.ok then
                mark_operation_active()

                if bootstrap_result.initial then
                    initial_sync_active = true
                    initial_sync_failed = false
                    initial_sync_signature =
                        bootstrap_result.signature
                end

                for _, item_id in ipairs(
                    bootstrap_result.ids or {}
                ) do
                    local item =
                        library_track(item_id) or {
                            id = item_id,
                            jellyfin_id = item_id,
                            kind = "track",
                            title = "Downloading",
                        }
                    set_optimistic_item(
                        item,
                        "queued"
                    )
                end

                bump_state(false)
                manifest_refresh_request_generation =
                    manifest_refresh_request_generation + 1
                next_refresh_at = 0
                next_apply_at = 0
            else
                fail_operation(
                    bootstrap_result.error,
                    nil
                )
            end
        end

        return
    end

    if sync_apply.busy() then
        if now >=
            next_inventory_progress_at then
            local started =
                sync_inventory_report.start(
                    sync_apply.progress(),
                    nil
                )

            if started then
                next_inventory_progress_at =
                    now + 2000
            end
        end

        local owner = download_state()
        if owner and
            type(owner.sync_apply_progress) ==
                "function" then
            owner.sync_apply_progress(
                sync_apply.progress()
            )
        end

        local apply_result =
            sync_apply.poll()

        if apply_result then
            finish_apply(apply_result, now)
        end

        return
    end

    if sync_operation_flush.busy() then
        local operation_result =
            sync_operation_flush.poll()

        if operation_result then
            finish_operations(
                operation_result,
                now
            )
        end

        return
    end

    if sync_library_refresh.busy() then
        local library_result =
            sync_library_refresh.poll()

        if library_result then
            finish_library(
                library_result,
                now
            )
        end

        return
    end

    local result = sync_manifest_state.poll()

    if result then
        if result.ok then
            manifest_refresh_error = nil
        end
        if manifest_refresh_active_generation then
            manifest_refresh_completed_generation =
                math.max(
                    manifest_refresh_completed_generation,
                    manifest_refresh_active_generation
                )
            manifest_refresh_active_generation = nil
        end
        local authoritative =
            result.ok and
            type(result.manifest) == "table"

        result = attach_plan(
            result,
            authoritative
        )

        last_result = result
        schedule_next(result, now)

        local status = sync_config.status()
        local started, start_error =
            start_apply(now, status)

        result.apply_started = started
        result.apply_error = start_error
        inventory_report_pending = true

        if not result.ok then
            record_manifest_refresh_error(
                result.error or
                    "manifest refresh failed"
            )
        end

        if download_operation_active and
            not started and
            type(active_plan) == "table" and
            type(active_plan.actions) == "table" and
            #active_plan.actions == 0 then
            download_operation_finalizing = true
            download_operation_needs_library = true
            next_library_at = 0
        end

        return
    end

    if sync_manifest_state.busy() then
        return
    end

    local status = sync_config.status()

    if manifest_refresh_completed_generation <
            manifest_refresh_request_generation then
        if not status.connected then
            return
        end

        local started, start_error =
            sync_manifest_state.start_refresh()

        if started then
            manifest_refresh_active_generation =
                manifest_refresh_request_generation
        else
            local failure = attach_plan({
                ok = false,
                error = start_error,
            }, false)
            last_result = failure
            manifest_refresh_completed_generation =
                manifest_refresh_request_generation
            schedule_next(failure, now)
            record_manifest_refresh_error(
                start_error or
                    "manifest refresh failed"
            )
        end

        return
    end

    if inventory_report_pending and
        status.connected then
        local failure =
            type(last_apply_result) ==
                "table" and
            not last_apply_result.ok and
            last_apply_result or nil
        local started =
            sync_inventory_report.start(
                sync_apply.current(),
                failure
            )

        if started then
            inventory_report_pending =
                false
            return
        end
    end

    if start_operations(now, status) then
        return
    end

    if start_library(now, status) then
        return
    end

    local library, library_error,
        library_status =
        sync_library_view.current()
    local library_ready =
        type(library) == "table" and
        type(library_status) == "table" and
        tonumber(
            library_status.cache_saved_at
        ) and
        tonumber(
            library_status.cache_saved_at
        ) > 0
    local bootstrap_started = false
    local bootstrap_error = library_error

    if library_ready then
        bootstrap_started,
            bootstrap_error =
            sync_offline_bootstrap.start(
                library
            )
    end

    if bootstrap_started then
        mark_operation_active()

        local required, signature =
            sync_offline_bootstrap
                .initial_sync_required(library)

        if required then
            initial_sync_active = true
            initial_sync_failed = false
            initial_sync_signature = signature
        end

        return
    end

    if initial_sync_active and library_ready then
        local required =
            sync_offline_bootstrap
                .initial_sync_required(library)

        if not required and
            not download_operation_active then
            initial_sync_active = false
            initial_sync_failed = false
            bump_state(false)
        end
    end

    if bootstrap_error then
        last_offline_bootstrap_result = {
            ok = false,
            error = bootstrap_error,
        }
    end

    local apply_started =
        start_apply(now, status)

    if apply_started then
        return
    end

    local owner = download_state()
    if owner and
        type(owner.pump_dispatch) ==
            "function" then
        owner.pump_dispatch("runtime-poll")
    end

    if now < next_refresh_at then
        return
    end

    if not status.connected then
        next_refresh_at = now + 1000
        return
    end

    local started, start_error =
        sync_manifest_state.start_refresh()

    if not started then
        local failure = attach_plan({
            ok = false,
            error = start_error,
        }, false)
        last_result = failure

        next_refresh_at =
            now + retry_interval_ms
        record_manifest_refresh_error(
            start_error or
                "manifest refresh failed"
        )
    end
end

function M.start()
    if timer then
        return false,
            "sync runtime is already started"
    end

    local initial_complete =
        sync_offline_bootstrap
            .initial_sync_complete()
    initial_sync_active =
        initial_complete ~= true
    initial_sync_failed = false

    local owner = download_state()
    if owner and
        type(owner.set_dispatcher) ==
            "function" then
        owner.set_dispatcher(M.dispatch_download)
    end

    durable_startup_attempt_ids = {}
    if owner and type(owner.operations) == "function" then
        for _, operation in ipairs(
            owner.operations()
        ) do
            if operation.id ~= nil then
                durable_startup_attempt_ids[
                    operation.id
                ] = true
            end
        end
    end

    local cached =
        sync_manifest_state.load_cached()

    cached = attach_plan(cached, false)
    last_result = cached

    -- Startup cleanup waits for the companion's durable request list. A
    -- manifest failure must not make a real accepted operation look stale.
    next_durable_requests_at = 0
    durable_requests_initial = true
    load_local_download_recency()

    timer = lvgl.Timer {
        period = poll_period_ms,
        cb = function()
            poll()
        end,
    }

    return true, cached
end

function M.last_result()
    return last_result
end

function M.request_refresh()
    manifest_refresh_request_generation =
        manifest_refresh_request_generation + 1
    next_refresh_at = 0
    next_apply_at = 0
    return true
end

function M.current_plan()
    return active_plan,
        active_plan_error,
        managed_paths_recovered,
        active_plan_authoritative
end

function M.apply_progress()
    return sync_apply.progress()
end

function M.last_apply_result()
    return last_apply_result
end

function M.operation_queue_status()
    return sync_operation_queue.status()
end

function M.last_operation_result()
    return last_operation_result
end

function M.library()
    return sync_library_view.current()
end

function M.library_refresh_progress()
    return sync_library_refresh.progress()
end

function M.last_library_result()
    return last_library_result
end

function M.last_artwork_result()
    return last_artwork_result
end

function M.last_offline_bootstrap_result()
    return last_offline_bootstrap_result
end

function M.note_queued(item)
    if type(item) ~= "table" then
        return false
    end

    mark_incomplete_download(item)

    -- Optimistic runtime lockout stays "queued" so item_state() preserves the
    -- pending marker before apply tracks the item. Sync row chrome reads the
    -- authoritative owner (downloading for the FIFO head).
    local noted = set_optimistic_item(
        item,
        "queued"
    )

    for _, child_id in ipairs(
        child_track_ids(item)
    ) do
        local child = library_track(child_id) or {
            id = child_id,
            jellyfin_id = child_id,
            kind = "track",
            title = item.title or
                item.name or
                "Downloading",
            artist = item.artist or "",
            album = item.title or
                item.name or "",
            album_id =
                jellyfin_album_identity
                    .album_id(item) or
                item.jellyfin_id or
                item.id,
        }
        noted = set_optimistic_item(
            child,
            "queued"
        ) or noted
    end

    if noted then
        mark_operation_active()
    end

    local owner = download_state()
    if owner and
        type(owner.request) == "function" then
        local projection = owner.lookup(item)
        if projection and
            projection.state ~= "queued" and
            projection.state ~= "downloading" and
            projection.state ~= "downloaded" then
            owner.request(item)
        end
    end

    return noted
end

function M.note_failed(item)
    if type(item) ~= "table" then
        return false
    end

    clear_optimistic_item(item)
    local noted = set_optimistic_item(
        item,
        "failed"
    )

    for _, child_id in ipairs(
        child_track_ids(item)
    ) do
        local child = library_track(child_id) or {
            id = child_id,
            jellyfin_id = child_id,
            kind = "track",
            title = item.title or
                item.name or
                "Download failed",
            artist = item.artist or "",
            album = item.title or
                item.name or "",
            album_id =
                jellyfin_album_identity
                    .album_id(item) or
                item.jellyfin_id or
                item.id,
        }
        noted = set_optimistic_item(
            child,
            "failed"
        ) or noted
    end

    failed_item_id = stable_item_id(item)
    bump_state(false)

    local owner = download_state()
    if owner then
        local projection = owner.lookup(item)
        if projection and
            projection.state ~= "failed" then
            local attempt_id =
                item_attempt_id(item)
            if attempt_id ~= nil and
                type(owner.fail_attempt) ==
                    "function" then
                owner.fail_attempt(attempt_id, {
                    message = "download failed",
                    retriable = true,
                })
            elseif type(owner.fail) == "function" then
                owner.fail(item, {
                    message = "download failed",
                    retriable = true,
                })
            end
        end
    end

    return noted
end

function M.clear_optimistic(item)
    local cleared = clear_optimistic_item(item)

    if cleared then
        bump_state(false)
    end

    return cleared
end

function M.item_state(item)
    local item_id =
        type(item) == "string" and
        item or stable_item_id(item)
    local apply_states =
        sync_apply.item_states()

    if item_id and apply_states[item_id] then
        -- Authoritative apply state replaces optimistic lockout.
        if optimistic_item_states[item_id] and
            optimistic_item_states[item_id] ~=
                apply_states[item_id] then
            optimistic_item_states[item_id] =
                apply_states[item_id]
        end
        return apply_states[item_id]
    end

    if type(item) == "table" and
        item.kind == "album" then
        local priority = {
            finalizing = 1,
            queued = 2,
            downloading = 3,
            failed = 4,
        }
        local selected = nil

        for _, child_id in ipairs(
            child_track_ids(item)
        ) do
            local state =
                apply_states[child_id]
            if not state then
                local optimistic =
                    optimistic_item_states[
                        child_id
                    ]
                if optimistic ==
                        "downloading" or
                    optimistic ==
                        "finalizing" or
                    optimistic ==
                        "importing" or
                    optimistic ==
                        "jellyfin_importing" or
                    optimistic ==
                        "external_downloading" then
                    optimistic_item_states[
                        child_id
                    ] = nil
                    optimistic_items[
                        child_id
                    ] = nil
                else
                    state = optimistic
                end
            end

            if state and
                (
                    not selected or
                    priority[state] >
                        priority[selected]
                ) then
                selected = state
            end
        end

        -- Catalog albums often lack child id arrays. Match apply/pending rows
        -- by album_id so downloading/queued still resolve on the album row.
        if not selected then
            local pending_by_id = {}

            for _, entry in ipairs(
                sync_apply.pending_items()
            ) do
                local pending_id =
                    stable_item_id(
                        entry.item
                    )
                if pending_id then
                    pending_by_id[pending_id] =
                        entry.item
                end
            end

            for pending_id, state in pairs(
                apply_states
            ) do
                local pending_item =
                    optimistic_items[pending_id] or
                    pending_by_id[pending_id]
                local album_ref =
                    type(pending_item) ==
                        "table" and
                    (
                        pending_item.album_id or
                        pending_item.parent_id
                    ) or nil

                if jellyfin_album_identity.same(
                        album_ref,
                        item_id
                    ) and
                    state and
                    (
                        not selected or
                        priority[state] >
                            priority[selected]
                    ) then
                    selected = state
                end
            end
        end

        if selected then
            if optimistic_item_states[item_id] and
                optimistic_item_states[item_id] ~=
                    selected then
                optimistic_item_states[item_id] =
                    selected
            end
            return selected
        end
    end

    if item_id and
        optimistic_item_states[item_id] then
        local optimistic =
            optimistic_item_states[item_id]
        -- In-flight optimistic states are only meaningful while apply still
        -- tracks the item. After apply drops them, they must not block Local
        -- completion from promoting the row to downloaded.
        if optimistic == "downloading" or
            optimistic == "finalizing" or
            optimistic == "importing" or
            optimistic ==
                "jellyfin_importing" or
            optimistic ==
                "external_downloading" then
            optimistic_item_states[item_id] =
                nil
            optimistic_items[item_id] = nil
        else
            return optimistic
        end
    end

    if failed_item_id and
        item_id == failed_item_id then
        return "failed"
    end

    return nil
end

function M.pending_items()
    local result = {}
    local by_id = {}

    local function add(item, state)
        local item_id = stable_item_id(item)

        if not item_id then
            return
        end

        local existing = by_id[item_id]

        if existing then
            existing.state =
                M.item_state(item) or
                state or existing.state
            return
        end

        local entry = {
            item = copy_value(item),
            state =
                M.item_state(item) or
                state or "queued",
        }
        by_id[item_id] = entry
        result[#result + 1] = entry
    end

    for item_id, item in pairs(
        optimistic_items
    ) do
        add(
            item,
            optimistic_item_states[item_id]
        )
    end

    for _, entry in ipairs(
        sync_apply.pending_items()
    ) do
        add(entry.item, entry.state)
    end

    return result
end

function M.activity()
    local progress = sync_apply.progress()

    if type(progress) == "table" then
        local action = progress.action
        local kind =
            type(action) == "table" and
            action.kind or nil
        local bytes = tonumber(progress.bytes) or 0
        local total =
            tonumber(progress.bytes_total) or 0

        -- The status-bar activity affordance is intentionally user-visible
        -- sync only.  Routine manifest/catalog refresh, artwork-cache work,
        -- inventory reporting, and offline bootstrap polling continue in the
        -- background without keeping the top-left indicator alive.
        if kind == "media" then
            if total > 0 then
                return {
                    busy = true,
                    mode = "determinate",
                    bytes = bytes,
                    bytes_total = total,
                    phase = "downloading",
                }
            end

            return {
                busy = true,
                mode = "indeterminate",
                phase = "downloading",
            }
        end

        if kind == "artwork" and
            (
                download_operation_active or
                download_operation_finalizing or
                download_operation_waiting_artwork
            ) then
            return {
                busy = true,
                mode = "indeterminate",
                phase = "finalizing",
            }
        end
    end

    if download_operation_finalizing or
        download_operation_waiting_artwork then
        return {
            busy = true,
            mode = "indeterminate",
            phase = "finalizing",
        }
    end

    -- A durable operation can remain in the runtime lifecycle while only a
    -- queued FIFO successor is left.  Keep that lifecycle state for pumping
    -- the queue, but do not present a queued-only successor as an active
    -- download in the top-left status indicator.
    local visible_download_active = download_operation_active
    if visible_download_active then
        local owner = download_state()
        if owner and type(owner.operations) == "function" then
            local ok, operations = pcall(owner.operations)
            if ok and type(operations) == "table" then
                local head = operations[1]
                visible_download_active =
                    type(head) == "table" and
                    (
                        head.status == "downloading" or
                        head.dispatched == true
                    )
            end
        end
    end

    if visible_download_active then
        return {
            busy = true,
            mode = "indeterminate",
            phase = "downloading",
        }
    end

    -- Startup/device-state flushes are background reconciliation, not a
    -- user-visible transfer. They must not make the status indicator pulse on
    -- every simulator launch. Actual media/download activity above remains
    -- visible.
    if download_operation_error then
        return {
            busy = false,
            mode = "error",
            error = download_operation_error,
        }
    end

    return {
        busy = false,
        mode = "idle",
    }
end

function M.local_downloaded_at(item_or_key)
    load_local_download_recency()
    local key = local_download_key(item_or_key)

    if not key then
        return nil
    end

    return local_downloaded_at[key]
end

function M.note_local_download_completed(
    item_or_key,
    timestamp
)
    return record_completed_download(
        item_or_key,
        timestamp
    )
end

function M.reconcile_local_download_recency(items)
    return fold_track_recency_into_albums(items)
end

function M.local_gate_state()
    return {
        blocked =
            initial_sync_active and
            not initial_sync_failed,
        failed = initial_sync_failed,
        error =
            initial_sync_failed and
            (
                download_operation_error or
                manifest_refresh_error
            ) or nil,
    }
end

function M.state_generation()
    local owner = download_state()
    local download_generation =
        owner and owner.generation and
        owner.generation() or 0

    return state_generation +
        (sync_apply.generation() or 0) +
        download_generation
end

function M.content_generation()
    return content_generation +
        (sync_apply.generation() or 0)
end

return M
