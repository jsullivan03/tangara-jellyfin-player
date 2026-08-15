local backstack = require("backstack")
local device_identity =
    require("device_identity")
local jellyfin_list_ui =
    require("jellyfin_list_ui")
local jellyfin_virtual_list =
    require("jellyfin_virtual_list")
local jellyfin_album_identity =
    require("jellyfin_album_identity")
local jellyfin_artist_identity =
    require("jellyfin_artist_identity")
local jellyfin_track_identity =
    require("jellyfin_track_identity")
local jellyfin_local_index =
    require("jellyfin_local_index")
local jellyfin_text_entry =
    require("jellyfin_text_entry")
local lvgl = require("lvgl")
local screen = require("screen")
local sync_catalog = require("sync_catalog")
local sync_artwork_cache =
    require("sync_artwork_cache")
local sync_runtime = require("sync_runtime")
local sync_download_state =
    require("sync_download_state")
local jellyfin_track_action_sheet =
    require("jellyfin_track_action_sheet")
local sync_sort = require("sync_sort")
local time = require("time")
local palette =
    require("jellyfin_theme").current()

local M = {}
local active_screen = nil
local poll_timer = nil
local local_library = nil
local local_library_generation = -1
local local_track_ids = {}
local local_album_ids = {}
local CATALOG_PAGE_SIZE = 50
local CATALOG_PREFETCH_DISTANCE = 25
local CATALOG_REFRESH_INTERVAL_MS = 60000

-- Owner owns FIFO dispatch. Wire the existing catalog queue exactly once per
-- head promotion/request so Sync UI and runtime share one dispatcher.
-- Prefer the module local so desktop-sim mocks that replace package.loaded
-- before requiring this file still bind correctly.
sync_download_state.set_dispatcher(
    function(item, operation)
        if type(sync_runtime.dispatch_download) ==
                "function" then
            return sync_runtime.dispatch_download(
                item,
                operation
            )
        end
        -- Isolated simulator tests provide a synchronous catalog dispatcher
        -- without the runtime transport wrapper. Firmware always takes the
        -- async runtime path above. Keep the fallback callback-bound as well
        -- so an unexpectedly missing wrapper cannot turn request start into
        -- acceptance.
        if type(sync_catalog.queue) == "function" then
            return sync_catalog.queue(
                item,
                function(result)
                    local payload =
                        type(result) == "table" and
                        result.payload or nil
                    local request =
                        type(payload) == "table" and
                        payload.request or nil
                    sync_download_state.resolve_dispatch(
                        operation.id,
                        type(result) == "table" and
                            result.ok == true,
                        {
                            status =
                                type(result) == "table" and
                                result.status or nil,
                            replayed =
                                type(payload) == "table" and
                                (
                                    payload.replayed == true or
                                    payload.already_durable == true
                                ) or false,
                            error =
                                type(result) == "table" and
                                result.error or
                                "dispatch failed",
                            request_id =
                                type(request) == "table" and
                                request.id or
                                (
                                    type(payload) == "table" and
                                    payload.request_id or nil
                                ),
                        }
                    )
                end
            )
        end
        return false, "catalog queue unavailable"
    end
)
local DOWNLOAD_ICON_ANIM_PERIOD_MS = 50
local download_icon_anim_timer = nil
local download_icon_anim_screen = nil
local download_icon_anim_model = nil
local download_icon_anim_frame = 0

local LandingScreen
local CatalogScreen
local SearchScreen
local ResultsScreen
local ConfirmScreen
local DestinationScreen
local StatusScreen
local ArtistScreen
local ArtistActionScreen
local refresh_runtime_rows
local sync_download_icon_anim
local stop_download_icon_anim

local state_labels = {
    server_only = "On server",
    downloaded = "On device",
    queued = "Queued",
    downloading = "Downloading",
    finalizing = "Finalizing",
    importing = "Importing",
    external_queued = "Queued",
    external_downloading = "Downloading",
    jellyfin_importing = "Importing",
    partial = "Partial",
    failed = "Failed",
    available = "Available",
}

local function refresh_local_ids()
    local library =
        jellyfin_local_index.load()
    local generation =
        type(sync_runtime.content_generation) ==
            "function" and
        sync_runtime.content_generation() or 0

    if type(library) ~= "table" then
        return
    end

    if library == local_library and
        generation ==
            local_library_generation then
        return
    end

    local_library = library
    local_library_generation = generation
    local_track_ids = {}
    local_album_ids = {}

    for _, track in ipairs(
        library.tracks or {}
    ) do
        local id =
            jellyfin_album_identity
                .canonical_id(
                    track.jellyfin_id or
                    track.id
                )
        if id then
            local_track_ids[id] = true
        end

        local track_album =
            jellyfin_album_identity
                .canonical_id(
                    track.album_id or
                    track.parent_id
                )
        if track_album and
            not (
                track.pending_download
            ) then
            local_album_ids[track_album] =
                (
                    local_album_ids[
                        track_album
                    ] or 0
                ) + 1
        end
    end

    for _, album in ipairs(
        library.albums or {}
    ) do
        if type(album) == "table" and
            not album.pending_download then
            local album_id =
                jellyfin_album_identity
                    .album_id(album)
            local track_count =
                tonumber(
                    album.track_count
                ) or
                (
                    type(album.tracks) ==
                        "table" and
                    #album.tracks
                ) or 0
            if album_id and
                track_count > 0 then
                local_album_ids[album_id] =
                    math.max(
                        local_album_ids[
                            album_id
                        ] or 0,
                        track_count
                    )
            end
        end
    end
end

local function verified_jellyfin_id(item)
    if type(item) ~= "table" then
        return nil
    end

    if item.kind == "album" then
        return jellyfin_album_identity
            .album_id(item)
    end

    return jellyfin_album_identity
        .canonical_id(
            item.jellyfin_id or item.id
        )
end

local function local_album_track_count(
    album_id
)
    album_id =
        jellyfin_album_identity
            .canonical_id(album_id)
    if not album_id then
        return 0, nil
    end

    refresh_local_ids()

    local library =
        local_library or
        jellyfin_local_index.load()
    local album_record = nil

    if type(library) == "table" then
        for _, album in ipairs(
            library.albums or {}
        ) do
            if type(album) == "table" and
                not album.pending_download and
                jellyfin_album_identity
                    .album_id(album) ==
                    album_id then
                album_record = album
                break
            end
        end
    end

    local count =
        local_album_ids[album_id] or 0
    if album_record then
        local listed =
            tonumber(
                album_record.track_count
            ) or
            (
                type(album_record.tracks) ==
                    "table" and
                #album_record.tracks
            ) or 0
        if listed > count then
            count = listed
        end
    end

    return count, album_record
end

local function album_is_locally_complete(
    item,
    album_id,
    local_count,
    child_ids,
    matched_ids
)
    local_count = tonumber(local_count) or 0
    if local_count <= 0 then
        return false
    end

    if child_ids and matched_ids and
        #matched_ids >= #child_ids then
        return true
    end

    local catalog_total =
        tonumber(item.track_count) or
        tonumber(item.child_count)

    if catalog_total and
        catalog_total > 0 and
        local_count >= catalog_total then
        return true
    end

    -- No trustworthy expected/catalog size: a non-pending Local album record
    -- with tracks is treated as complete for this Sync row.
    if not catalog_total and
        not child_ids then
        return true
    end

    -- Stale expected-track cache: Local already has at least as many tracks as
    -- the expected set size (or more), so prefer Local completeness.
    if child_ids and
        local_count >= #child_ids and
        matched_ids and
        #matched_ids > 0 then
        return true
    end

    return false
end

local function authoritative_track_ids(
    item
)
    local device_state =
        type(item.device) == "table" and
        item.device or {}
    local source =
        item.jellyfin_track_ids or
        item.child_track_ids or
        device_state
            .jellyfin_track_ids or
        device_state.child_track_ids
    if type(source) ~= "table" then
        return nil
    end

    local seen = {}
    local ids = {}
    for _, value in ipairs(source) do
        local id =
            jellyfin_album_identity
                .canonical_id(value)
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

local function album_inventory(item)
    refresh_local_ids()
    local album_id =
        jellyfin_album_identity
            .album_id(item)
    local child_ids =
        authoritative_track_ids(item)
    local matched_ids = {}
    local local_count =
        local_album_track_count(album_id)

    if child_ids then
        for _, id in ipairs(child_ids) do
            if local_track_ids[id] then
                matched_ids[
                    #matched_ids + 1
                ] = id
            end
        end

        if album_is_locally_complete(
            item,
            album_id,
            local_count,
            child_ids,
            matched_ids
        ) then
            local total = math.max(
                #child_ids,
                local_count,
                tonumber(item.track_count) or
                    0
            )
            return total, total, child_ids, matched_ids
        end

        return
            #child_ids,
            #matched_ids,
            child_ids,
            matched_ids
    end

    local catalog_total =
        tonumber(item.track_count) or
        tonumber(item.child_count)

    if album_is_locally_complete(
        item,
        album_id,
        local_count,
        nil,
        nil
    ) then
        local total =
            catalog_total and
            catalog_total > 0 and
            math.max(
                catalog_total,
                local_count
            ) or local_count
        return total, total, nil, nil
    end

    -- Device counts are used when Local still has no tracks for this album.
    -- Once Local inventory exists, it owns completeness instead of stale
    -- companion downloaded_tracks values.
    if local_count == 0 then
        local device_state =
            type(item.device) == "table" and
            item.device or {}
        local total =
            tonumber(
                device_state.total_tracks
            )
        local device_local =
            tonumber(
                device_state
                    .downloaded_tracks
            )

        if total and total > 0 and
            device_local and
            device_local >= 0 and
            device_local <= total then
            return total, device_local, nil, nil
        end
    end

    if album_id and
        catalog_total and
        catalog_total > 0 then
        return
            catalog_total,
            local_count,
            nil,
            nil
    end

    if local_count > 0 then
        return
            local_count,
            local_count,
            nil,
            nil
    end

    return nil, nil, nil, nil
end

local function runtime_matches_item(
    item,
    active_item
)
    if type(item) ~= "table" or
        type(active_item) ~= "table" then
        return false
    end

    local active_id =
        jellyfin_album_identity
            .item_id(active_item)
    if not active_id then
        return false
    end

    if item.kind == "track" then
        return active_id ==
            jellyfin_album_identity
                .item_id(item)
    end

    if item.kind ~= "album" then
        return false
    end

    local album_id =
        jellyfin_album_identity
            .album_id(item)
    if not album_id then
        return false
    end

    if active_id == album_id then
        return true
    end

    if jellyfin_album_identity.same(
        active_item.album_id or
        active_item.parent_id,
        album_id
    ) then
        return true
    end

    for _, child_id in ipairs(
        authoritative_track_ids(item) or {}
    ) do
        if child_id == active_id then
            return true
        end
    end

    return false
end

local function runtime_item_state(item)
    if type(sync_runtime.item_state) ==
            "function" then
        local ok, state = pcall(
            sync_runtime.item_state,
            item
        )

        if ok and state then
            return state
        end
    end

    local progress =
        sync_runtime.apply_progress()

    if type(progress) == "table" then
        local action = progress.action
        local active_item =
            type(action) == "table" and
            action.item or nil

        if runtime_matches_item(
            item,
            active_item
        ) then
            local bytes =
                tonumber(progress.bytes)
            local total =
                tonumber(
                    progress.bytes_total
                )
            local percentage = nil
            if bytes and total and total > 0 then
                percentage = math.max(
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
            return "downloading", percentage
        end
    end

    local failure =
        sync_runtime.last_apply_result()
    if type(failure) == "table" and
        failure.ok == false then
        local action =
            failure.failed_action or
            (
                type(failure.download) ==
                    "table" and
                failure.download.item or
                nil
            )
        local failed_item =
            type(action) == "table" and
            action.item or action
        if runtime_matches_item(
            item,
            failed_item
        ) then
            return "failed"
        end
    end

    return nil
end

local state_icon_kind

local function item_state(item)
    item = type(item) == "table" and
        item or {}
    refresh_local_ids()

    -- Tracks keep a thin local/runtime path; albums use the Phase 2 owner.
    if item.kind == "track" then
        local jellyfin_id =
            verified_jellyfin_id(item)
        local reported_state =
            type(item.device) == "table" and
                item.device.state or
            item.state or
            item.availability
        local runtime_state,
            runtime_percentage =
            runtime_item_state(item)

        if jellyfin_id and
            local_track_ids[jellyfin_id] then
            if type(
                sync_runtime.clear_optimistic
            ) == "function" then
                sync_runtime.clear_optimistic(
                    item
                )
            end
            return "downloaded"
        end

        if runtime_state then
            local normalized =
                sync_download_state
                    .normalize_state(
                        runtime_state
                    ) or runtime_state
            return normalized,
                runtime_percentage
        end

        if reported_state == "queued" or
            reported_state ==
                "downloading" or
            reported_state ==
                "finalizing" or
            reported_state == "failed" then
            return sync_download_state
                .normalize_state(
                    reported_state
                ) or reported_state
        end

        if not jellyfin_id then
            return "available"
        end
        return "server_only"
    end

    if item.kind == "album" or
        jellyfin_album_identity.album_id(
            item
        ) then
        local projection =
            sync_download_state.lookup(item)
        if projection.state == "downloaded" and
            type(
                sync_runtime.clear_optimistic
            ) == "function" then
            sync_runtime.clear_optimistic(item)
        end
        local final_icon =
            state_icon_kind(
                item,
                projection.state
            )
        return projection.state,
            projection.progress
    end

    local reported_state =
        type(item.device) == "table" and
            item.device.state or
        item.state or
        item.availability
    return sync_download_state.normalize_state(
        reported_state
    ) or reported_state or "server_only"
end

local function state_label(
    item,
    known_state,
    known_percentage
)
    local state, percentage =
        item_state(item)
    state = known_state or state
    if known_percentage ~= nil then
        percentage = known_percentage
    end
    local label =
        state_labels[state] or state
    if state == "downloading" and
        percentage ~= nil then
        label = label .. " " ..
            tostring(percentage) .. "%"
    end
    return label
end

state_icon_kind = function(
    item,
    state
)
    if state == "downloaded" then
        return "device"
    elseif state == "partial" then
        return "partial"
    elseif state == "queued" or
        state == "external_queued" then
        return "queued"
    elseif state == "downloading" or
        state == "external_downloading" or
        state == "finalizing" or
        state == "importing" or
        state == "jellyfin_importing" then
        return "downloading"
    elseif state == "failed" then
        return "failed"
    elseif state == "server_only" and
        verified_jellyfin_id(item) then
        return "server"
    end
    return nil
end

local STATUS_CELL_X = 139
local STATUS_CELL_Y = 2
local STATUS_CELL_W = 14
local STATUS_CELL_H = 18
local STATUS_CELL_CENTER_X =
    STATUS_CELL_X +
    math.floor(STATUS_CELL_W / 2)
local STATUS_CELL_CENTER_Y =
    STATUS_CELL_Y +
    math.floor(STATUS_CELL_H / 2)
local STATUS_ICON_SIZE = 10

local function status_icon_origin(
    width,
    height
)
    return
        STATUS_CELL_CENTER_X -
        math.floor(width / 2),
        STATUS_CELL_CENTER_Y -
        math.floor(height / 2)
end

local function add_state_icon(
    model,
    state,
    item
)
    local icon_kind =
        state_icon_kind(item, state)
    if not model or not icon_kind then
        return
    end

    local color =
        icon_kind == "device" and
        palette.accent or
        palette.accent_muted
    local parts = {}
    local spinner = nil

    local function part(
        x,
        y,
        width,
        height,
        options
    )
        options = options or {}
        local object =
            model.object:Object {
                x = x,
                y = y,
                w = width,
                h = height,
                pad_all = 0,
                border_width =
                    options.border_width or 0,
                border_color = color,
                radius = options.radius or 0,
                bg_color = color,
                bg_opa =
                    options.outline and
                    0 or 255,
                scrollbar_mode =
                    lvgl.SCROLLBAR_MODE.OFF,
            }
        object:clear_flag(
            lvgl.FLAG.CLICKABLE
        )
        object:clear_flag(
            lvgl.FLAG.SCROLLABLE
        )
        pcall(function()
            lvgl.group.remove_obj(object)
        end)
        table.insert(parts, object)
        return object
    end

    -- Invisible geometry cell so every state shares one trailing center.
    part(
        STATUS_CELL_X,
        STATUS_CELL_Y,
        STATUS_CELL_W,
        STATUS_CELL_H,
        {
            outline = true,
            border_width = 0,
        }
    )
    pcall(function()
        parts[1]:set {
            bg_opa = 0,
            border_width = 0,
        }
    end)

    if icon_kind == "device" then
        local x, y =
            status_icon_origin(10, 16)
        part(
            x,
            y,
            10,
            16,
            {
                border_width = 1,
                radius = 2,
                outline = true,
            }
        )
        part(x + 2, y + 2, 6, 4, {
            outline = true,
            border_width = 1,
        })
        part(x + 3, y + 8, 4, 4, {
            outline = true,
            border_width = 1,
            radius = 2,
        })
        part(x + 4, y + 9, 2, 2, {
            radius = 1,
        })
    elseif icon_kind == "queued" then
        local x, y =
            status_icon_origin(
                STATUS_ICON_SIZE,
                STATUS_ICON_SIZE
            )
        part(
            x,
            y,
            STATUS_ICON_SIZE,
            STATUS_ICON_SIZE,
            {
                outline = true,
                border_width = 1,
                radius = 5,
            }
        )
        part(x + 4, y + 2, 2, 4)
        part(x + 4, y + 4, 4, 2)
    elseif icon_kind == "downloading" then
        local x, y =
            status_icon_origin(
                STATUS_ICON_SIZE,
                STATUS_ICON_SIZE
            )
        local ok_spinner, created =
            pcall(function()
                local ring =
                    model.object:Object {
                        x = x,
                        y = y,
                        w = STATUS_ICON_SIZE,
                        h = STATUS_ICON_SIZE,
                        pad_all = 0,
                        border_width = 2,
                        border_color = color,
                        radius = 5,
                        bg_opa = 0,
                        pivot = {
                            x = math.floor(
                                STATUS_ICON_SIZE /
                                    2
                            ),
                            y = math.floor(
                                STATUS_ICON_SIZE /
                                    2
                            ),
                        },
                        angle = 0,
                        scrollbar_mode =
                            lvgl.SCROLLBAR_MODE.OFF,
                    }
                ring:clear_flag(
                    lvgl.FLAG.CLICKABLE
                )
                ring:clear_flag(
                    lvgl.FLAG.SCROLLABLE
                )
                pcall(function()
                    lvgl.group.remove_obj(ring)
                end)
                local tip =
                    ring:Object {
                        x = math.floor(
                            STATUS_ICON_SIZE / 2
                        ) - 1,
                        y = 0,
                        w = 2,
                        h = 3,
                        pad_all = 0,
                        border_width = 0,
                        radius = 1,
                        bg_color = color,
                        bg_opa = 255,
                        scrollbar_mode =
                            lvgl.SCROLLBAR_MODE.OFF,
                    }
                tip:clear_flag(
                    lvgl.FLAG.CLICKABLE
                )
                tip:clear_flag(
                    lvgl.FLAG.SCROLLABLE
                )
                return ring
            end)

        if ok_spinner and created then
            spinner = created
            table.insert(parts, spinner)
        else
            -- Fallback: still paint a centered ring without rotation props.
            spinner =
                part(
                    x,
                    y,
                    STATUS_ICON_SIZE,
                    STATUS_ICON_SIZE,
                    {
                        outline = true,
                        border_width = 2,
                        radius = 5,
                    }
                )
            part(
                x + math.floor(
                    STATUS_ICON_SIZE / 2
                ) - 1,
                y,
                2,
                3,
                {radius = 1}
            )
        end
    elseif icon_kind == "partial" then
        local x, y =
            status_icon_origin(
                STATUS_ICON_SIZE,
                STATUS_ICON_SIZE
            )
        part(
            x,
            y,
            STATUS_ICON_SIZE,
            STATUS_ICON_SIZE,
            {
                outline = true,
                border_width = 1,
                radius = 1,
            }
        )
        part(x + 1, y + 1, 4, 8)
    elseif icon_kind == "failed" then
        local x, y =
            status_icon_origin(2, 12)
        part(x, y, 2, 8)
        part(x, y + 10, 2, 2)
    else
        local x, y =
            status_icon_origin(
                STATUS_ICON_SIZE,
                STATUS_ICON_SIZE
            )
        part(
            x,
            y,
            STATUS_ICON_SIZE,
            STATUS_ICON_SIZE,
            {
                border_width = 1,
                radius = 1,
                outline = true,
            }
        )
        part(x + 1, y + 3, 8, 1)
        part(x + 1, y + 6, 8, 1)
        part(x + 2, y + 1, 1, 1)
        part(x + 2, y + 4, 1, 1)
        part(x + 2, y + 7, 1, 1)
    end

    model.state_icon = {
        kind = icon_kind,
        color = color,
        parts = parts,
        spinner = spinner,
        cell = {
            x = STATUS_CELL_X,
            y = STATUS_CELL_Y,
            w = STATUS_CELL_W,
            h = STATUS_CELL_H,
            center_x = STATUS_CELL_CENTER_X,
            center_y = STATUS_CELL_CENTER_Y,
        },
    }
end

local function busy_download_state(state)
    return state == "queued" or
        state == "downloading"
end

local function download_actionable(item)
    if type(item) == "table" and
        item.kind == "album" then
        local projection =
            sync_download_state.lookup(item)
        return projection.can_download == true
    end

    local state = item_state(item)
    return state == "server_only" or
        state == "partial" or
        state == "available"
end

local function failed_actionable(item)
    if type(item) == "table" and
        item.kind == "album" then
        local projection =
            sync_download_state.lookup(item)
        return projection.can_retry == true
    end

    return item_state(item) == "failed"
end

local function apply_download_icon_frame(model, frame)
    if not model or
        not model.state_icon or
        model.state_icon.kind ~=
            "downloading" then
        return
    end

    local spinner = model.state_icon.spinner
    if not spinner then
        return
    end

    frame = math.floor(tonumber(frame) or 0)
    pcall(function()
        spinner:set {
            angle = (frame % 24) * 150,
        }
    end)
end

stop_download_icon_anim = function()
    if download_icon_anim_timer then
        pcall(function()
            download_icon_anim_timer:pause()
        end)
    end

    download_icon_anim_screen = nil
    download_icon_anim_model = nil
    download_icon_anim_frame = 0
end

local function find_downloading_model(screen)
    if not screen then
        return nil
    end

    local function scan(collection)
        for _, model in ipairs(
            collection or {}
        ) do
            if model.state == "downloading" and
                model.state_icon and
                model.state_icon.kind ==
                    "downloading" then
                return model
            end
        end
        return nil
    end

    return scan(screen.media_rows) or
        scan(screen.result_models) or
        scan(screen.rows)
end

sync_download_icon_anim = function(screen)
    if not screen or
        screen.ui_active ~= true then
        if download_icon_anim_screen ==
                screen then
            stop_download_icon_anim()
        end
        return
    end

    local model =
        find_downloading_model(screen)

    if not model then
        if download_icon_anim_screen ==
                screen then
            stop_download_icon_anim()
        end
        return
    end

    download_icon_anim_screen = screen
    download_icon_anim_model = model
    apply_download_icon_frame(
        model,
        download_icon_anim_frame
    )

    if download_icon_anim_timer then
        pcall(function()
            download_icon_anim_timer:resume()
        end)
        return
    end

    download_icon_anim_timer =
        lvgl.Timer {
            period =
                DOWNLOAD_ICON_ANIM_PERIOD_MS,
            cb = function()
                local owner =
                    download_icon_anim_screen
                if not owner or
                    owner.ui_active ~=
                        true then
                    stop_download_icon_anim()
                    return
                end

                local target =
                    download_icon_anim_model
                if not target or
                    target.state ~=
                        "downloading" or
                    not target.state_icon or
                    target.state_icon.kind ~=
                        "downloading" then
                    target =
                        find_downloading_model(
                            owner
                        )
                    download_icon_anim_model =
                        target
                end

                if not target then
                    stop_download_icon_anim()
                    return
                end

                download_icon_anim_frame =
                    (
                        download_icon_anim_frame + 1
                    ) % 24
                apply_download_icon_frame(
                    target,
                    download_icon_anim_frame
                )
            end,
        }
end

local function apply_state_surface(
    model,
    state
)
    if not model or not model.object then
        return
    end

    -- Trailing icons carry download status. Never dim the whole row, and never
    -- erase selected-row chrome that install_controls / FOCUSED already painted.
    -- Artwork/runtime refresh can run before model.focused is set, or after a
    -- recycle leaves the flag stale — resolve against the owner selection too.
    local focused = model.focused == true
    local owner = model.owner

    if not focused and
        owner and
        model.selection_id and
        owner.selected_item_id and
        tostring(model.selection_id) ==
            tostring(owner.selected_item_id) then
        focused = true
        model.focused = true
    end

    if not focused and
        owner and
        owner.focus_group and
        model.object then
        local ok, current = pcall(
            function()
                return owner.focus_group:
                    get_focused()
            end
        )
        if ok and current == model.object then
            focused = true
            model.focused = true
        end
    end

    if focused then
        model.object:set {
            bg_color =
                palette.selected_surface,
            bg_opa = 255,
        }
    else
        model.object:set {
            bg_opa = 0,
        }
    end
    model.on_focus_style = nil
    model.on_defocus_style = nil
end

local function actionable(item)
    -- Rows stay long-holdable in every download state so composed menus can
    -- still expose Artist Discography. Download itself is gated separately.
    return type(item) == "table"
end

local function placeholder()
    return "//lua/img/cover_placeholder.png"
end

local function stable_item_id(item)
    if type(item) ~= "table" then
        return ""
    end

    return jellyfin_album_identity.item_id(
        item
    ) or
        jellyfin_album_identity.canonical_id(
            item.key
        ) or
        ""
end

local function catalog_items(
    payload,
    view,
    maximum
)
    local expected_kind =
        view == "albums" and
        "album" or "track"
    local items = {}

    for _, item in ipairs(
        type(payload) == "table" and
            payload.items or {}
    ) do
        if type(item) == "table" and
            item.kind == expected_kind then
            items[#items + 1] = item
            if maximum and
                #items >= maximum then
                break
            end
        end
    end

    return items
end

local function catalog_sort_options(
    view,
    cache_key,
    limit
)
    local mode =
        sync_sort.current(view)
    local request_sort = mode
    local direction = "ascending"

    if mode == "title_asc" then
        request_sort = "title"
    elseif mode == "title_desc" then
        request_sort = "title"
        direction = "descending"
    elseif mode == "date_added" then
        direction = "descending"
    elseif mode == "date_added_asc" then
        request_sort = "date_added"
    end

    return limit or 20, {
        sort = request_sort,
        direction = direction,
        cache_key = cache_key or view,
    }
end

local function artwork(item)
    return
        type(item.artwork_path) ==
            "string" and
        item.artwork_path ~= "" and
        item.artwork_path or
        placeholder()
end

local function result_detail(item)
    local detail =
        tostring(item.artist or "")

    if item.kind == "track" and
        type(item.album) == "string" and
        item.album ~= "" then
        if detail ~= "" then
            detail = detail .. " - "
        end
        detail = detail .. item.album
    end

    if item.explicit then
        detail =
            detail ..
            (
                detail ~= "" and
                    " - E" or
                "E"
            )
    end

    local state, percentage =
        item_state(item)

    -- Download lifecycle text stays in the trailing status/progress chrome.
    -- Never overwrite the artist/detail label with Queued/Downloading/Failed.
    return detail, state, percentage
end

local STATE_ICON_X = STATUS_CELL_X
local STATE_ICON_GAP = 4
local SYNC_FULL_TEXT_WIDTH = 127
local SYNC_ICON_TEXT_WIDTH =
    STATE_ICON_X - 24 - STATE_ICON_GAP

local function apply_sync_text_gutter(
    model,
    has_icon
)
    if not model then
        return
    end

    local width =
        has_icon and
        SYNC_ICON_TEXT_WIDTH or
        SYNC_FULL_TEXT_WIDTH

    if model.title and
        type(model.title.set_width) ==
            "function" then
        model.title:set_width(width)
    end

    if model.detail and
        type(model.detail.set_width) ==
            "function" then
        model.detail:set_width(width)
    end
end

local function clear_state_icon(model)
    if not model or
        not model.state_icon then
        return
    end

    for _, part in ipairs(
        model.state_icon.parts or {}
    ) do
        if part then
            pcall(function()
                if type(part.delete) ==
                        "function" then
                    part:delete()
                elseif type(part.add_flag) ==
                        "function" then
                    part:add_flag(
                        lvgl.FLAG.HIDDEN
                    )
                end
            end)
        end
    end

    model.state_icon = nil
    apply_sync_text_gutter(model, false)
end

local function clear_rows(self)
    local was_active =
        self.ui_active == true

    if download_icon_anim_screen == self then
        stop_download_icon_anim()
    end

    for _, model in ipairs(
        self.rows or {}
    ) do
        if type(
            model.retire_sync_artwork
        ) == "function" then
            model:retire_sync_artwork(
                true
            )
        end
    end

    jellyfin_list_ui.restore_controls(self)
    pcall(function()
        self.list:clean()
    end)
    self.rows = {}
    self.leading_rows = {}
    self.media_rows = nil
    self.virtual_list_controller = nil
    self.virtual_scroll_indicator = nil
    self.virtual_row_canvas = nil
    self.virtual_row_parent = nil
    self.scroll_indicator = nil
    self.result_models = nil
    self.first_row = nil
    self.initial_focus_object = nil
    self.ui_active = was_active
end

local function local_destination(item)
    local local_ui =
        require("jellyfin_local_library")

    local track_has_album =
        item.kind == "track" and
        (
            jellyfin_album_identity.album_id(item) ~= nil or
            (
                type(item.album) == "string" and
                item.album ~= ""
            ) or
            (
                type(item.album_name) == "string" and
                item.album_name ~= ""
            )
        )
    local album_key = nil
    if item.kind == "track" then
        if track_has_album then
            album_key = jellyfin_album_identity
                .track_album_key(item)
        end
    else
        album_key = jellyfin_album_identity
            .local_album_key(item)
    end

    if album_key then
        backstack.push(
            local_ui.Album:new {
                album_key = album_key,
                selected_item_id =
                    item.kind == "track" and
                    jellyfin_album_identity
                        .item_id(item) or
                    nil,
            }
        )
    else
        backstack.push(
            local_ui.Tracks:new {
                selected_item_id =
                    jellyfin_album_identity
                        .item_id(item),
            }
        )
    end
end

local function open_status(item)
    backstack.push(
        StatusScreen:new {
            item = item,
        }
    )
end

local function artist_key(item)
    if type(item) ~= "table" then
        return ""
    end

    return jellyfin_artist_identity.key(
        item
    ) or ""
end

local function current_list_scroll_y(owner)
    if not owner or
        not owner.list or
        not owner.focus_group then
        return nil
    end

    local ok, value = pcall(function()
        local focused =
            owner.focus_group:
                get_focused()
        if not focused then
            return nil
        end
        local list_coordinates =
            owner.list:get_coords()
        local focused_coordinates =
            focused:get_coords()
        return
            list_coordinates.y1 -
            focused_coordinates.y1
    end)

    if not ok then
        return nil
    end
    return tonumber(value)
end

local function local_view_label(item)
    if item and item.kind == "album" then
        return "View in Local",
            "view_album_local"
    end

    return "View in Local", "view_local"
end

local function start_download(owner, item)
    if not download_actionable(item) and
        not failed_actionable(item) then
        return false
    end

    local accepted, detail =
        sync_download_state.request(item)

    if not accepted then
        return false
    end

    -- Legacy/synchronous dispatchers used by isolated simulator tests are
    -- already accepted here. Production HTTP dispatch reports pending and is
    -- mirrored into runtime only by its response callback.
    if type(detail) == "table" and
        detail.dispatched == true and
        type(sync_runtime.note_queued) ==
            "function" then
        sync_runtime.note_queued(item)
    end

    if type(item.device) ~= "table" then
        item.device = {}
    end
    item.device.state =
        type(detail) == "table" and
            detail.state or
        sync_download_state.lookup(item).state or
        "queued"

    if owner then
        local target_id =
            sync_download_state.key(item) or
            stable_item_id(item)
        for _, model in ipairs(
            owner.media_rows or
            owner.result_models or
            {}
        ) do
            if type(model.catalog_item) ==
                    "table" and
                (
                    sync_download_state.key(
                        model.catalog_item
                    ) == target_id or
                    stable_item_id(
                        model.catalog_item
                    ) == target_id
                ) and
                type(
                    model.update_sync_catalog_item
                ) == "function" then
                if type(model.catalog_item.device) ~=
                        "table" then
                    model.catalog_item.device = {}
                end
                model.catalog_item.device.state =
                    item.device.state
                model:update_sync_catalog_item(
                    model.catalog_item
                )
            end
        end
        refresh_runtime_rows(owner)
    end

    -- Companion dispatch is owned by sync_download_state (FIFO head only).
    sync_download_state.pump_dispatch("ui")

    local projection =
        sync_download_state.lookup(item)
    if projection.state == "failed" then
        if type(sync_runtime.note_failed) ==
                "function" then
            sync_runtime.note_failed(item)
        end
        item.device.state = "failed"
        refresh_runtime_rows(owner)
        return false
    end

    return true
end

local function open_download_sheet(
    owner,
    item
)
    jellyfin_track_action_sheet
        .attach(owner):open_custom {
        {
            id = "download",
            label = "Download",
            activate = function()
                start_download(owner, item)
            end,
        },
        {
            id = "cancel",
            label = "Cancel",
        },
    }
end

local function push_artist_discography(
    owner,
    item,
    return_scroll_y,
    return_selection_id
)
    if owner.artist_discography_push_pending then
        return
    end

    owner.artist_discography_push_pending =
        true
    owner.artist_discography_restore_scroll_y =
        return_scroll_y or
        current_list_scroll_y(owner)
    owner.artist_discography_restore_selection_id =
        return_selection_id or
        owner.selected_item_id

    backstack.push(
        ArtistScreen:new {
            item = item,
            parent_screen = owner,
        }
    )
end

local function compose_context_actions(
    owner,
    item
)
    local state = item_state(item)
    local actions = {}
    local return_scroll_y =
        current_list_scroll_y(owner)
    local return_selection_id =
        owner and
        owner.selected_item_id or nil

    local function append_discography()
        if artist_key(item) == "" then
            return
        end

        actions[#actions + 1] = {
            id = "artist_discography",
            label = "Artist Discography",
            activate = function()
                push_artist_discography(
                    owner,
                    item,
                    return_scroll_y,
                    return_selection_id
                )
            end,
        }
    end

    local function append_view_local()
        local label, action_id =
            local_view_label(item)
        actions[#actions + 1] = {
            id = action_id,
            label = label,
            activate = function()
                local_destination(item)
            end,
        }
    end

    if busy_download_state(state) then
        -- A queued/downloading item can already have some files on disk, but
        -- exposing Local at that point produces a partial album that changes
        -- underneath the user. Keep Local navigation locked until the owner
        -- reaches authoritative downloaded state.
        append_discography()
    elseif state == "downloaded" then
        append_view_local()
        append_discography()
    elseif state == "failed" then
        actions[#actions + 1] = {
            id = "retry_download",
            label = "Retry Download",
            activate = function()
                start_download(owner, item)
            end,
        }
        append_discography()
    elseif state == "partial" then
        actions[#actions + 1] = {
            id = "download",
            label = "Download",
            activate = function()
                start_download(owner, item)
            end,
        }
        append_discography()
    elseif state == "server_only" or
        download_actionable(item) then
        actions[#actions + 1] = {
            id = "download",
            label = "Download",
            activate = function()
                start_download(owner, item)
            end,
        }
        append_discography()
    elseif state == "available" then
        append_discography()
    else
        return nil
    end

    actions[#actions + 1] = {
        id = "cancel",
        label = "Cancel",
    }

    return actions
end

local function open_context_sheet(
    owner,
    item
)
    local actions =
        compose_context_actions(
            owner,
            item
        )

    if not actions or #actions == 0 then
        return
    end

    jellyfin_track_action_sheet
        .attach(owner):open_custom(actions)
end

local function open_destination_sheet(
    owner,
    item
)
    jellyfin_track_action_sheet
        .attach(owner):open_custom {
        {
            id = "cancel",
            label = "Cancel",
        },
        {
            id = "jellyfin",
            label = "Add to Jellyfin only",
            activate = function()
                sync_catalog.external_job(
                    item,
                    "jellyfin"
                )
            end,
        },
        {
            id = "jellyfin_and_device",
            label =
                "Add to Jellyfin + Tangara",
            activate = function()
                sync_catalog.external_job(
                    item,
                    "jellyfin_and_device"
                )
            end,
        },
    }
end

local function activate(item, owner)
    local state = item_state(item)

    if busy_download_state(state) then
        return
    end

    if state == "downloaded" then
        if item.kind == "album" then
            local_destination(item)
        end
    elseif state == "server_only" or
        state == "partial" then
        open_download_sheet(owner, item)
    elseif state == "available" then
        open_destination_sheet(owner, item)
    elseif state == "failed" then
        open_context_sheet(owner, item)
    end
end

local function open_row_long_press(item, owner)
    local state = item_state(item)

    if state == "available" and
        artist_key(item) == "" then
        open_destination_sheet(owner, item)
        return
    end

    open_context_sheet(owner, item)
end

local function bind_result_row_actions(
    owner,
    item
)
    local state = item_state(item)
    local on_click = nil

    if download_actionable(item) or
        state == "available" or
        state == "failed" or
        (
            state == "downloaded" and
            item.kind == "album"
        ) then
        on_click = function()
            activate(item, owner)
        end
    end

    -- Always keep long-hold available so Artist Discography remains reachable
    -- while queued/downloading. Download is omitted from the composed menu.
    return true,
        on_click,
        function()
            open_row_long_press(
                item,
                owner
            )
        end
end

local function add_result_row(
    self,
    item,
    load_artwork
)
    local detail, state, percentage =
        result_detail(item)
    local available, on_click, on_long_press =
        bind_result_row_actions(self, item)

    local model =
        jellyfin_list_ui.add_track_row(
            self,
            {
                id =
                    item.jellyfin_id or
                    item.key,
                jellyfin_id =
                    item.jellyfin_id,
                key = item.key,
                title =
                    item.title or
                    "Unknown",
                artist = item.artist or "",
            },
            {
                artwork = placeholder(),
                detail = detail,
                detail_width =
                    state_icon_kind(item, state) and
                    SYNC_ICON_TEXT_WIDTH or
                    SYNC_FULL_TEXT_WIDTH,
                text_width =
                    state_icon_kind(item, state) and
                    SYNC_ICON_TEXT_WIDTH or
                    SYNC_FULL_TEXT_WIDTH,
                available = available,
                on_click = on_click,
                on_long_press = on_long_press,
            }
        )

    model.catalog_item = item
    model.state = state
    model.sync_artwork_stable_id =
        tostring(
            item.jellyfin_id or
            item.key or
            item.id or ""
        )
    model.sync_artwork_generation = 0
    model.sync_artwork_alive = true
    model.sync_artwork_subscription = nil
    model.sync_progress_visible = false
    model.sync_progress_percentage = nil

    -- Download progress bars are intentionally removed. State is conveyed only
    -- through the compact trailing icon system.
    function model:set_sync_progress()
        self.sync_progress_visible = false
        self.sync_progress_percentage = nil
    end

    model:set_sync_progress()
    add_state_icon(model, state, item)
    apply_sync_text_gutter(
        model,
        model.state_icon ~= nil
    )
    apply_state_surface(model, state)
    sync_download_icon_anim(self)

    function model:retire_sync_artwork(
        destroyed
    )
        if self.sync_artwork_subscription and
            type(sync_artwork_cache.cancel) ==
                "function" then
            sync_artwork_cache.cancel(
                self.sync_artwork_subscription
            )
        end
        self.sync_artwork_subscription = nil
        self.sync_artwork_generation =
            self.sync_artwork_generation + 1
        self.artwork_requested = false

        if destroyed then
            self.sync_artwork_alive =
                false
            self.sync_artwork_stable_id =
                nil
            if self.artwork and
                type(
                    self.artwork.detach
                ) == "function" then
                self.artwork:detach()
            end
        end
    end

    function model:update_sync_catalog_item(
        next_item
    )
        if type(next_item) ~= "table" then
            return
        end

        local previous_artwork_key =
            sync_artwork_cache.key(item)
        local previous_stable_id =
            self.sync_artwork_stable_id
        local next_artwork_key =
            sync_artwork_cache.key(
                next_item
            )
        local next_stable_id =
            tostring(
                next_item.jellyfin_id or
                next_item.key or
                next_item.id or ""
            )
        local artwork_changed =
            previous_artwork_key ~=
                next_artwork_key
        local binding_changed =
            previous_stable_id ~=
                next_stable_id

        if artwork_changed or
            binding_changed then
            self:retire_sync_artwork(
                false
            )
        end

        item = next_item
        self.catalog_item = item
        self.sync_artwork_stable_id =
            next_stable_id

        local next_detail, next_state,
            next_percentage =
            result_detail(item)
        local next_available,
            next_on_click,
            next_on_long_press =
            bind_result_row_actions(
                self.owner,
                item
            )
        self:update(
            {
                id =
                    item.jellyfin_id or
                    item.key,
                jellyfin_id =
                    item.jellyfin_id,
                key = item.key,
                title =
                    item.title or
                    "Unknown",
                artist =
                    item.artist or "",
            },
            {
                detail = next_detail,
                text_width =
                    state_icon_kind(
                        item,
                        next_state
                    ) and
                    SYNC_ICON_TEXT_WIDTH or
                    SYNC_FULL_TEXT_WIDTH,
                detail_width =
                    state_icon_kind(
                        item,
                        next_state
                    ) and
                    SYNC_ICON_TEXT_WIDTH or
                    SYNC_FULL_TEXT_WIDTH,
                available = next_available,
                on_click = next_on_click,
                on_long_press =
                    next_on_long_press,
            }
        )

        -- Runtime download-state refreshes can call this method directly,
        -- outside virtual_list.update_row(). Preserve the virtual long-hold
        -- trampoline in that path so a row remains long-holdable immediately
        -- after Download changes it to queued/downloading.
        if type(self.virtual_on_long_press) ==
                "function" then
            self.on_long_press =
                self.virtual_on_long_press
        end

        local previous_state = self.state
        local previous_icon_kind =
            self.state_icon and
            self.state_icon.kind or nil
        local next_icon_kind =
            state_icon_kind(
                item,
                next_state
            )
        if not next_icon_kind then
            clear_state_icon(self)
        elseif previous_icon_kind ~=
                next_icon_kind or
            previous_state ~= next_state or
            not self.state_icon then
            clear_state_icon(self)
            add_state_icon(
                self,
                next_state,
                item
            )
        end
        apply_sync_text_gutter(
            self,
            self.state_icon ~= nil
        )
        self.state = next_state
        self:set_sync_progress()
        apply_state_surface(
            self,
            next_state
        )

        if self.owner then
            sync_download_icon_anim(
                self.owner
            )
        end

        if (
            artwork_changed or
            binding_changed
        ) and self.artwork then
            if artwork_changed then
                self.artwork:set(
                    placeholder()
                )
            end
            self.artwork_should_load =
                true
            self:load_sync_artwork()
        end
    end

    function model:load_sync_artwork()
        if self.artwork_requested or
            not self.sync_artwork_alive then
            return
        end

        self.artwork_should_load = true
        self.artwork_requested = true
        self.sync_artwork_generation =
            self.sync_artwork_generation + 1
        local generation =
            self.sync_artwork_generation
        local stable_id =
            self.sync_artwork_stable_id
        local intended_artwork =
            self.artwork
        local screen_owner = self.owner
        local current_item =
            self.catalog_item
        local expected =
            sync_artwork_cache.key(
                current_item
            )
        local _, subscription =
            sync_artwork_cache.request(
            current_item,
            function(path, key)
                if key ~= expected or
                    active_screen ~=
                        screen_owner or
                    not screen_owner.ui_active or
                    not model
                        .sync_artwork_alive or
                    model
                        .sync_artwork_generation ~=
                        generation or
                    model
                        .sync_artwork_stable_id ~=
                        stable_id or
                    tostring(
                        model.catalog_item and
                        (
                            model.catalog_item
                                .jellyfin_id or
                            model.catalog_item.key or
                            model.catalog_item.id
                        ) or ""
                    ) ~= stable_id or
                    model.artwork ~=
                        intended_artwork or
                    type(
                        intended_artwork
                            .is_valid
                    ) ~= "function" or
                    not intended_artwork:
                        is_valid() then
                    if model
                            .sync_artwork_alive and
                        model
                            .sync_artwork_generation ==
                            generation then
                        model.artwork_requested =
                            false
                        model
                            .sync_artwork_subscription =
                            nil
                    end
                    return
                end

                model.sync_artwork_subscription =
                    nil
                intended_artwork:set(path)
            end
        )

        if subscription then
            if self.sync_artwork_alive and
                self.sync_artwork_generation ==
                    generation and
                self.sync_artwork_stable_id ==
                    stable_id then
                self.sync_artwork_subscription =
                    subscription
            elseif type(
                sync_artwork_cache.cancel
            ) == "function" then
                sync_artwork_cache.cancel(
                    subscription
                )
            end
        end
    end

    local previous_on_focus =
        model.on_focus
    model.on_focus = function()
        if type(previous_on_focus) ==
                "function" then
            previous_on_focus()
        end
        model:load_sync_artwork()
    end

    if load_artwork ~= false then
        model:load_sync_artwork()
    end
    return model
end

local function runtime_ui_signature()
    local state_generation =
        type(sync_runtime.state_generation) ==
            "function" and
        sync_runtime.state_generation() or 0
    local content_generation =
        type(sync_runtime.content_generation) ==
            "function" and
        sync_runtime.content_generation() or 0
    local download_generation =
        sync_download_state.generation()
    local progress =
        sync_runtime.apply_progress()
    if type(progress) == "table" then
        local action = progress.action
        local item =
            type(action) == "table" and
            action.item or {}
        return table.concat({
            "active",
            tostring(state_generation),
            tostring(content_generation),
            tostring(download_generation),
            tostring(
                item.jellyfin_id or
                item.id or ""
            ),
            tostring(progress.bytes or ""),
            tostring(
                progress.bytes_total or ""
            ),
            tostring(progress.completed or 0),
            tostring(progress.total or 0),
        }, ":")
    end

    local result =
        sync_runtime.last_apply_result()
    if type(result) == "table" then
        return table.concat({
            "complete",
            tostring(state_generation),
            tostring(content_generation),
            tostring(download_generation),
            tostring(result),
            tostring(result.ok),
            tostring(result.completed or 0),
            tostring(result.total or 0),
            tostring(result.error or ""),
        }, ":")
    end

    return table.concat({
        "idle",
        tostring(state_generation),
        tostring(content_generation),
        tostring(download_generation),
    }, ":")
end

refresh_runtime_rows = function(self)
    if not self or not self.ui_active then
        return
    end

    local progress =
        sync_runtime.apply_progress()
    if type(progress) == "table" then
        sync_download_state.sync_apply_progress(
            progress
        )
    end

    sync_download_state.reconcile({
        notify = false,
    })

    local seen = {}
    local function refresh_model(model)
        if type(model) ~= "table" or
            seen[model] then
            return
        end
        seen[model] = true

        if type(model.catalog_item) ==
                "table" and
            type(
                model.update_sync_catalog_item
            ) == "function" then
            model:update_sync_catalog_item(
                model.catalog_item
            )
        end
    end

    local function refresh_matching(keys)
        if type(keys) ~= "table" or
            #keys == 0 then
            return false
        end

        local wanted = {}
        for _, key in ipairs(keys) do
            wanted[key] = true
        end

        local matched = false
        local function maybe(model)
            if type(model) ~= "table" or
                type(model.catalog_item) ~=
                    "table" then
                return
            end
            local key =
                sync_download_state.key(
                    model.catalog_item
                )
            if key and wanted[key] then
                matched = true
                refresh_model(model)
            end
        end

        for _, model in ipairs(
            self.media_rows or {}
        ) do
            maybe(model)
        end
        for _, model in ipairs(
            self.result_models or {}
        ) do
            maybe(model)
        end
        return matched
    end

    if self._download_changed_keys and
        refresh_matching(
            self._download_changed_keys
        ) then
        self._download_changed_keys = nil
    else
        for _, model in ipairs(
            self.media_rows or {}
        ) do
            refresh_model(model)
        end
        for _, model in ipairs(
            self.result_models or {}
        ) do
            refresh_model(model)
        end
        for _, model in ipairs(
            self.rows or {}
        ) do
            refresh_model(model)
        end
        self._download_changed_keys = nil
    end

    self.sync_runtime_signature =
        runtime_ui_signature()
    sync_download_icon_anim(self)
end

local function install(self)
    active_screen = self
    self.artist_discography_push_pending =
        false

    if self._download_unsub then
        pcall(self._download_unsub)
        self._download_unsub = nil
    end

    self._download_unsub =
        sync_download_state.subscribe(
            function(payload)
                if not self.ui_active then
                    return
                end
                local keys =
                    payload and payload.keys or {}
                self._download_changed_keys =
                    keys
                refresh_runtime_rows(self)
            end
        )

    local locked_selection =
        self
            .artist_discography_restore_selection_id
    local restore_scroll_y =
        self
            .artist_discography_restore_scroll_y
    self.artist_discography_restore_selection_id =
        nil
    self.artist_discography_restore_scroll_y =
        nil

    if locked_selection then
        self.selected_item_id =
            locked_selection
    end

    jellyfin_list_ui.install_controls(self)

    -- Fixed-viewport catalogs own their motion layer. Native list scroll
    -- restore after Artist discography pushed the clipped canvas out of view
    -- and left Sync Albums black until the next wheel event.
    local fixed_viewport =
        self.virtual_list_controller and
        self.virtual_list_controller
            .fixed_viewport == true

    if restore_scroll_y and
        self.list and
        not fixed_viewport then
        local function restore_scroll()
            if not self.ui_active or
                not self.list then
                return
            end
            pcall(function()
                local focused = nil
                if locked_selection then
                    for _, model in ipairs(
                        self.rows or {}
                    ) do
                        if model.selection_id ==
                                locked_selection then
                            focused =
                                model.object
                            break
                        end
                    end
                end
                focused =
                    focused or
                    (
                        self.focus_group and
                        self.focus_group:
                            get_focused()
                    )
                if not focused then
                    return
                end
                local list_coordinates =
                    self.list:get_coords()
                local focused_coordinates =
                    focused:get_coords()
                local current_offset =
                    list_coordinates.y1 -
                    focused_coordinates.y1
                self.list:
                    scroll_by_bounded(
                        0,
                        current_offset -
                            restore_scroll_y,
                        false
                    )
            end)
        end
        restore_scroll()
        lvgl.Timer {
            period = 1,
            repeat_count = 1,
            cb = restore_scroll,
        }
    elseif fixed_viewport and
        self.virtual_list_controller and
        type(
            self.virtual_list_controller
                .repair_resumed_viewport
        ) == "function" then
        pcall(function()
            self.virtual_list_controller:
                repair_resumed_viewport()
        end)
    end

    if locked_selection then
        self.selected_item_id =
            locked_selection
        self.discography_selection_lock =
            locked_selection

        if self.virtual_list_controller and
            type(
                self.virtual_list_controller
                    .find_index
            ) == "function" and
            type(
                self.virtual_list_controller
                    .focus_index
            ) == "function" then
            local index =
                self.virtual_list_controller:
                    find_index(
                        locked_selection
                    )
            if index then
                self.suppress_focus_scroll =
                    true
                self.suppress_selection_tracking =
                    true
                pcall(function()
                    self.virtual_list_controller:
                        focus_index(index)
                end)
                self.suppress_selection_tracking =
                    false
                self.suppress_focus_scroll =
                    false
            end
        end

        self.selected_item_id =
            locked_selection

        local function refocus_locked_row()
            if not self.ui_active or
                self.discography_selection_lock ~=
                    locked_selection then
                return
            end

            self.selected_item_id =
                locked_selection
            self.suppress_selection_tracking =
                true
            self.suppress_focus_scroll = true

            local group =
                lvgl.group.get_default()

            for _, model in ipairs(
                self.rows or {}
            ) do
                local matched =
                    model.selection_id ==
                    locked_selection
                model.focused = matched
                if matched and model.object then
                    pcall(function()
                        group:add_obj(
                            model.object
                        )
                    end)
                    pcall(function()
                        backstack.focus(
                            model.object
                        )
                    end)
                    pcall(function()
                        lvgl.group.focus_obj(
                            model.object
                        )
                    end)
                end
            end

            self.suppress_focus_scroll = false
            self.suppress_selection_tracking =
                false
            self.selected_item_id =
                locked_selection

            if restore_scroll_y and
                self.list and
                not fixed_viewport then
                pcall(function()
                    local focused = nil
                    for _, model in ipairs(
                        self.rows or {}
                    ) do
                        if model.selection_id ==
                                locked_selection then
                            focused =
                                model.object
                            break
                        end
                    end
                    if not focused then
                        return
                    end
                    local list_coordinates =
                        self.list:get_coords()
                    local focused_coordinates =
                        focused:get_coords()
                    local current_offset =
                        list_coordinates.y1 -
                        focused_coordinates.y1
                    self.list:
                        scroll_by_bounded(
                            0,
                            current_offset -
                                restore_scroll_y,
                            false
                        )
                end)
            end
        end

        -- Screen load happens after on_show; refocus once the parent group is
        -- active so sort controls cannot keep the default group focus.
        -- Keep discography_selection_lock briefly so resume FOCUSED handlers
        -- cannot adopt a different pooled row and rewrite selected_item_id.
        refocus_locked_row()
        lvgl.Timer {
            period = 1,
            repeat_count = 1,
            cb = refocus_locked_row,
        }

        lvgl.Timer {
            period = 200,
            repeat_count = 1,
            cb = function()
                if self.discography_selection_lock ==
                        locked_selection then
                    refocus_locked_row()
                    self.discography_selection_lock =
                        nil
                end
            end,
        }
    end

    for _, model in ipairs(
        self.rows or {}
    ) do
        if model.artwork_should_load and
            not model.artwork_requested and
            type(
                model.load_sync_artwork
            ) == "function" then
            model:load_sync_artwork()
        end
    end

    self.sync_runtime_signature =
        runtime_ui_signature()
    self.sync_content_generation =
        type(sync_runtime.content_generation) ==
            "function" and
        sync_runtime.content_generation() or 0
end

local function hide(self)
    if self._download_unsub then
        pcall(self._download_unsub)
        self._download_unsub = nil
    end
    self._download_changed_keys = nil

    if active_screen == self then
        active_screen = nil
    end

    if download_icon_anim_screen == self then
        stop_download_icon_anim()
    end

    for _, model in ipairs(
        self.rows or {}
    ) do
        if type(
            model.retire_sync_artwork
        ) == "function" then
            model:retire_sync_artwork(
                false
            )
        end
    end

    jellyfin_list_ui.restore_controls(self)

    if not active_screen and poll_timer then
        pcall(function()
            poll_timer:pause()
        end)
    end
end

local function copied_items(items)
    local result = {}

    for index, item in ipairs(
        items or {}
    ) do
        result[index] = item
    end

    return result
end

local function create_catalog_virtual_list(
    self,
    items,
    payload
)
    local loaded_items =
        copied_items(items)
    self.items = loaded_items

    local controller =
        jellyfin_virtual_list.create(
            self,
            loaded_items,
            {
                item_label =
                    self.view == "tracks" and
                    "track" or "album",
                item_plural =
                    self.view == "tracks" and
                    "tracks" or "albums",
                item_id = stable_item_id,
                -- Catalog rows use the fixed seven-row viewport so recycling
                -- never exposes the transparent canvas as black bands while
                -- the encoder is moving quickly.
                fixed_viewport = true,
                pool_size = 7,
                anchor = 4,
                motion_duration = 90,
                total_count =
                    payload.total_count or
                    payload.total or
                    #loaded_items,
                -- Use the shared semantic accent scrollbar for the complete
                -- Albums and Tracks catalogs. Search retains its separately
                -- specified high-contrast indicator.
                scroll_indicator = {},
                create_row =
                    function(owner, item)
                        return add_result_row(
                            owner,
                            item,
                            true
                        )
                    end,
                update_row =
                    function(
                        model,
                        item,
                        handlers
                    )
                        model:
                            update_sync_catalog_item(
                                item
                            )
                        if model.available then
                            model.on_click =
                                handlers.on_click
                            model.on_long_press =
                                handlers.on_long_press
                        else
                            model.on_click = nil
                            model.on_long_press = nil
                        end
                    end,
                on_click = function(item)
                    activate(item, self)
                end,
                on_long_press = function(item)
                    open_row_long_press(
                        item,
                        self
                    )
                end,
                on_focus = function(index)
                    self:on_catalog_item_focus(
                        index
                    )
                end,
            }
        )

    self.result_models = controller.pool
    self.scroll_indicator =
        controller.scroll_indicator
    self.rendered_catalog_generation =
        payload.generation

    local selected_model =
        controller:selected_model()
    self.first_row =
        (
            selected_model and
            selected_model.object
        ) or
        controller.pool[1].object
    self.initial_focus_object =
        self.first_row
end

local function create_search_virtual_list(
    self,
    items,
    payload
)
    self.items = copied_items(items)

    local controller =
        jellyfin_virtual_list.create(
            self,
            self.items,
            {
                item_label = "result",
                item_plural = "results",
                item_id = stable_item_id,
                pool_size = 7,
                anchor = 4,
                motion_duration = 90,
                total_count =
                    payload.total_count or
                    payload.total or
                    #self.items,
                scroll_indicator = {
                    thumb_color = "#FFFFFF",
                },
                create_row =
                    function(owner, item)
                        return add_result_row(
                            owner,
                            item,
                            true
                        )
                    end,
                update_row =
                    function(
                        model,
                        item,
                        handlers
                    )
                        model:
                            update_sync_catalog_item(
                                item
                            )
                        if model.available then
                            model.on_click =
                                handlers.on_click
                            model.on_long_press =
                                handlers.on_long_press
                        else
                            model.on_click = nil
                            model.on_long_press = nil
                        end
                    end,
                on_click = function(item)
                    activate(item, self)
                end,
                on_long_press = function(item)
                    open_row_long_press(
                        item,
                        self
                    )
                end,
            }
        )

    self.result_models = controller.pool
    self.scroll_indicator =
        controller.scroll_indicator
    self.first_row =
        controller.pool[1].object
end

local function render_items(
    self,
    payload,
    sort_key
)
    local selected =
        self.selected_item_id
    clear_rows(self)

    local server_sorted =
        sort_key == "albums" or
        sort_key == "tracks"
    local items =
        server_sorted and
        (
            payload and payload.items or {}
        ) or
        sync_sort.apply(
            payload and payload.items or {},
            sync_sort.current(sort_key)
        )
    local virtualized_results =
        #items >= 7
    self.items = items

    if #items > 0 then
        if sort_key == "albums" or
            sort_key == "tracks" then
            local selected =
                sync_sort.selection(
                    sort_key
                )
            local draft = {
                method = selected.method,
                alpha_label =
                    selected.alpha_label,
                recent_label =
                    selected.recent_label,
            }

            local function draft_selection(
                method
            )
                if method == "alpha" or
                    method == "recent" then
                    draft.method = method
                end

                return {
                    method = draft.method,
                    label =
                        draft.method ==
                            "recent" and
                        draft.recent_label or
                        draft.alpha_label,
                    alpha_label =
                        draft.alpha_label,
                    recent_label =
                        draft.recent_label,
                }
            end

            local function draft_mode()
                if draft.method ==
                        "recent" then
                    return
                        draft.recent_label ==
                            "New" and
                        "date_added" or
                        "date_added_asc"
                end

                return
                    draft.alpha_label ==
                        "Z-A" and
                    "title_desc" or
                    "title_asc"
            end

            jellyfin_list_ui.add_sort_control(
                self,
                {
                    methods = {
                        "alpha",
                        "recent",
                    },
                    method_labels = {
                        alpha = "Title",
                        recent = "Date added",
                    },
                    current_method =
                        selected.method,
                    current_label =
                        selected.label,
                    alpha_label =
                        selected.alpha_label,
                    recent_label =
                        selected.recent_label,
                    on_highlight =
                        function(method)
                            return
                                draft_selection(
                                    method
                                )
                        end,
                    on_toggle =
                        function(method)
                            draft.method = method
                            if method ==
                                    "recent" then
                                draft.recent_label =
                                    draft
                                        .recent_label ==
                                        "New" and
                                    "Old" or "New"
                            else
                                draft.alpha_label =
                                    draft
                                        .alpha_label ==
                                        "A-Z" and
                                    "Z-A" or "A-Z"
                            end
                            return
                                draft_selection()
                        end,
                    on_restore =
                        function()
                            local restored =
                                sync_sort.selection(
                                    sort_key
                                )
                            draft.method =
                                restored.method
                            draft.alpha_label =
                                restored
                                    .alpha_label
                            draft.recent_label =
                                restored
                                    .recent_label
                            return
                                draft_selection()
                        end,
                    on_apply = function()
                        local mode =
                            draft_mode()
                        if sync_sort.current(
                            sort_key
                        ) == mode then
                            return
                        end
                        if not sync_sort.set(
                            sort_key,
                            mode
                        ) then
                            return
                        end

                        -- Reorder the already loaded page immediately so the
                        -- Sort sheet closes onto a responsive list. The
                        -- companion request below still replaces it with the
                        -- globally sorted catalog page when it arrives.
                        if self.virtual_list_controller and
                            type(self.items) == "table" and
                            #self.items > 0 then
                            local preview =
                                sync_sort.apply(
                                    self.items,
                                    mode
                                )
                            self.items = preview
                            self.virtual_list_controller
                                :set_items(
                                    preview,
                                    {
                                        total_count =
                                            self.scroll_indicator and
                                            self.scroll_indicator
                                                .item_count or
                                            #preview,
                                    }
                                )
                            self.result_models =
                                self.virtual_list_controller.pool
                        end

                        if type(
                            self
                                .request_sorted_catalog
                        ) == "function" then
                            self:
                                request_sorted_catalog()
                        end
                    end,
                }
            )
        else
            jellyfin_list_ui.add_sort_control(
                self,
                {
                    methods =
                        sync_sort.modes(
                            sort_key
                        ),
                    current_method =
                        sync_sort.current(
                            sort_key
                        ),
                    current_label =
                        sync_sort.label(
                            sync_sort.current(
                                sort_key
                            ),
                            sort_key
                        ),
                    on_highlight =
                        function(method)
                            sync_sort.set(
                                sort_key,
                                method
                            )
                            return {
                                method = method,
                                label =
                                    sync_sort.label(
                                        method,
                                        sort_key
                                    ),
                            }
                        end,
                    on_toggle =
                        function(method)
                            sync_sort.set(
                                sort_key,
                                method
                            )
                            return {
                                method = method,
                                label =
                                    sync_sort.label(
                                        method,
                                        sort_key
                                    ),
                            }
                        end,
                    on_apply = function()
                        self:render()
                    end,
                }
            )
        end

        if not server_sorted then
            if payload.external_available ==
                    false then
                self.external_notice =
                    jellyfin_list_ui.add_section_label(
                        self,
                        "External search unavailable"
                    )
            elseif payload
                    .external_search_pending then
                self.external_notice =
                    jellyfin_list_ui.add_section_label(
                        self,
                        "Searching external"
                    )
            end
        end

        if virtualized_results then
            if server_sorted then
                create_catalog_virtual_list(
                    self,
                    items,
                    payload
                )
            else
                create_search_virtual_list(
                    self,
                    items,
                    payload
                )
            end
        else
            local result_models = {}
            for index, item in ipairs(items) do
                table.insert(
                    result_models,
                    add_result_row(
                        self,
                        item,
                        index <= 7
                    )
                )
            end
            self.first_row = self.rows[2].object
            self.result_models =
                result_models
            self.selected_item_id = selected
            jellyfin_list_ui.attach_scroll_indicator(
                self,
                result_models,
                {
                    thumb_color = "#FFFFFF",
                    total_count =
                        payload.total_count or
                        payload.total or
                        #result_models,
                }
            )
        end
    else
        local row =
            jellyfin_list_ui.add_message(
                self,
                (
                    payload and
                    payload.external_available ==
                        false and
                    "External search unavailable"
                ) or
                sync_catalog.error() or
                    "No items"
            )
        self.first_row = row.object
    end

    if self.ui_active then
        install(self)
        jellyfin_list_ui.focus_first_row(
            self
        )
    end
end

local function append_catalog_items(
    self,
    payload
)
    local controller =
        self.virtual_list_controller
    local existing = self.items

    if not controller or
        type(existing) ~= "table" then
        return false
    end

    local items =
        catalog_items(
            payload,
            self.view
        )
    local existing_count = #existing
    local replacing_generation =
        payload.generation ~= nil and
        payload.generation ~=
            self.rendered_catalog_generation

    if not replacing_generation and
        #items < existing_count then
        return false
    end

    if not replacing_generation then
        for index = 1, existing_count do
            if stable_item_id(existing[index]) ~=
                stable_item_id(items[index]) then
                return false
            end
        end
    end

    local loaded_items =
        copied_items(items)
    self.items = loaded_items
    self.pagination_loading = false

    controller:set_items(
        loaded_items,
        {
            total_count =
                payload.total_count or
                payload.total or
                #loaded_items,
        }
    )
    self.result_models = controller.pool
    self.scroll_indicator =
        controller.scroll_indicator
    self.rendered_catalog_generation =
        payload.generation

    return true
end

local function update_search_results(
    self,
    payload
)
    local function normalized(value)
        return tostring(value or "")
            :lower()
            :gsub("%s+", " ")
            :match("^%s*(.-)%s*$")
    end

    local function artist_names(item)
        local values = {}
        local primary =
            normalized(item.artist)
        if primary ~= "" then
            values[primary] = true
        end
        for _, value in ipairs(
            item.artists or {}
        ) do
            local name = normalized(value)
            if name ~= "" then
                values[name] = true
            end
        end
        return values
    end

    local function same_identity(
        left,
        right
    )
        if left.kind ~= right.kind or
            normalized(left.title) == "" or
            normalized(left.title) ~=
                normalized(right.title) then
            return false
        end
        if normalized(left.artist) ~= "" and
            normalized(left.artist) ==
                normalized(right.artist) then
            return true
        end
        local right_names =
            artist_names(right)
        for name in pairs(
            artist_names(left)
        ) do
            if right_names[name] then
                local left_year =
                    tonumber(left.year)
                local right_year =
                    tonumber(right.year)
                return
                    not left_year or
                    not right_year or
                    left_year ==
                        right_year
            end
        end
        return false
    end

    local items =
        sync_sort.apply(
            payload and payload.items or {},
            sync_sort.current("search")
        )
    local controller =
        self.virtual_list_controller

    if controller and #items > 0 then
        self.items = items
        controller:set_items(
            items,
            {
                total_count =
                    payload.total_count or
                    payload.total or
                    #items,
            }
        )
        self.result_models = controller.pool
        self.scroll_indicator =
            controller.scroll_indicator

        if payload.external_available ==
                false then
            if self.external_notice and
                self.external_notice.label then
                self.external_notice.label:set {
                    text =
                        "External search unavailable",
                }
                self.external_notice.text =
                    "External search unavailable"
            end
        elseif self.external_notice and
            self.external_notice.object and
            type(
                self.external_notice
                    .object.add_flag
            ) == "function" then
            self.external_notice.object:
                add_flag(lvgl.FLAG.HIDDEN)
            self.external_notice = nil
        end

        return
    end

    if not controller and #items >= 7 then
        render_items(
            self,
            payload,
            "search"
        )
        return
    end

    local models =
        self.result_models or {}
    local by_stable = {}

    for _, model in ipairs(models) do
        local item = model.catalog_item
        local stable =
            tostring(
                item and (
                    item.jellyfin_id or
                    item.key or
                    item.id
                ) or ""
            )
        if stable ~= "" then
            by_stable[stable] = model
        end
    end

    for index, item in ipairs(items) do
        local stable =
            tostring(
                item.jellyfin_id or
                item.key or
                item.id or ""
            )
        local model = by_stable[stable]

        if not model then
            local matches = {}
            for _, candidate in ipairs(
                models
            ) do
                local existing =
                    candidate.catalog_item or {}
                if same_identity(
                    existing,
                    item
                ) then
                    matches[#matches + 1] =
                        candidate
                end
            end
            if #matches == 1 then
                model = matches[1]
            end
        end

        if model and
            type(
                model
                    .update_sync_catalog_item
            ) == "function" then
            model:update_sync_catalog_item(
                item
            )
            if stable ~= "" then
                by_stable[stable] = model
            end
        elseif not model then
            model = add_result_row(
                self,
                item,
                index <= 7
            )
            models[#models + 1] = model
            if stable ~= "" then
                by_stable[stable] = model
            end
            if self.scroll_indicator then
                local indicator =
                    self.scroll_indicator
                local row_index = #models
                local previous_on_focus =
                    model.on_focus
                model.on_focus =
                    function()
                        if type(
                            previous_on_focus
                        ) == "function" then
                            previous_on_focus()
                        end
                        indicator:update(
                            indicator.item_count,
                            row_index
                        )
                    end
            end
        end
    end

    self.items = items
    self.result_models = models
    if self.scroll_indicator then
        local indicator =
            self.scroll_indicator
        local total_count =
            math.max(
                #models,
                math.floor(
                    tonumber(
                        payload.total_count or
                        payload.total or
                        indicator.item_count
                    ) or #models
                )
            )
        local selected_index = 1
        local selected_id =
            tostring(
                self.selected_item_id or ""
            )

        if selected_id ~= "" then
            for index, model in ipairs(
                models
            ) do
                if stable_item_id(
                    model.catalog_item
                ) == selected_id then
                    selected_index = index
                    break
                end
            end
        end

        indicator.models = models
        indicator.item_count = total_count
        indicator:update(
            total_count,
            selected_index
        )
    end

    if payload.external_available ==
            false then
        if self.external_notice and
            self.external_notice.label then
            self.external_notice.label:set {
                text =
                    "External search unavailable",
            }
            self.external_notice.text =
                "External search unavailable"
        else
            self.external_notice =
                jellyfin_list_ui
                    .add_section_label(
                        self,
                        "External search unavailable"
                    )
        end
    elseif self.external_notice and
        self.external_notice.object and
        type(
            self.external_notice
                .object.add_flag
        ) == "function" then
        self.external_notice.object:
            add_flag(lvgl.FLAG.HIDDEN)
        self.external_notice = nil
    end
end

ConfirmScreen =
    screen:new {
        create_ui = function(self)
            jellyfin_list_ui.create_root(
                self,
                "Download"
            )
            jellyfin_list_ui.add_message(
                self,
                item_state(self.item) ==
                    "partial" and
                    "Download missing tracks?" or
                    "Download this item?"
            )
            local confirm
            confirm =
                jellyfin_list_ui.add_action_row(
                    self,
                    "Download",
                    {
                        selection_id =
                            "sync:confirm",
                        on_click = function()
                            local started =
                                start_download(
                                    nil,
                                    self.item
                                )
                            if started then
                                confirm:set_label(
                                    "Queued"
                                )
                                confirm.on_click = nil
                            else
                                confirm:set_label(
                                    "Failed"
                                )
                            end
                        end,
                    }
                )
            local cancel =
                jellyfin_list_ui.add_action_row(
                    self,
                    "Cancel",
                    {
                        selection_id =
                            "sync:cancel",
                        on_click =
                            backstack.pop,
                    }
                )
            self.cancel_row = cancel
            self.confirm_row = confirm
            self.first_row = confirm.object
        end,
        on_show = install,
        on_hide = hide,
    }

DestinationScreen =
    screen:new {
        create_ui = function(self)
            jellyfin_list_ui.create_root(
                self,
                "Destination"
            )
            local jellyfin =
                jellyfin_list_ui.add_action_row(
                    self,
                    "Add to Jellyfin only",
                    {
                        selection_id =
                            "sync:destination:jellyfin",
                        on_click = function()
                            sync_catalog.external_job(
                                self.item,
                                "jellyfin"
                            )
                        end,
                    }
                )
            jellyfin_list_ui.add_action_row(
                self,
                "Add to Jellyfin + this Tangara",
                {
                    selection_id =
                        "sync:destination:device",
                    on_click = function()
                        sync_catalog.external_job(
                            self.item,
                            "jellyfin_and_device"
                        )
                    end,
                }
            )
            self.first_row = jellyfin.object
        end,
        on_show = install,
        on_hide = hide,
    }

StatusScreen =
    screen:new {
        create_ui = function(self)
            jellyfin_list_ui.create_root(
                self,
                "Download status"
            )
            local item = self.item or {}
            local row =
                jellyfin_list_ui.add_message(
                    self,
                    state_label(item)
                )
            if item_state(item) == "failed" and
                (
                    not item.error or
                    item.error.retryable ~= false
                ) then
                local retry =
                    jellyfin_list_ui.add_action_row(
                        self,
                        "Retry",
                        {
                            selection_id =
                                "sync:retry",
                            on_click =
                                function()
                                    if item.jellyfin_id then
                                        start_download(
                                            nil,
                                            item
                                        )
                                    end
                                end,
                        }
                    )
                self.first_row = retry.object
            else
                self.first_row = row.object
            end
        end,
        on_show = install,
        on_hide = hide,
    }

ArtistActionScreen =
    screen:new {
        create_ui = function(self)
            jellyfin_list_ui.create_root(
                self,
                "Actions"
            )
            local row =
                jellyfin_list_ui.add_action_row(
                    self,
                    "Artist discography",
                    {
                        selection_id =
                            "sync:artist",
                        on_click = function()
                            backstack.push(
                                ArtistScreen:new {
                                    item = self.item,
                                    title =
                                        self.item.artist or
                                        "Artist",
                                }
                            )
                        end,
                    }
                )
            self.first_row = row.object
        end,
        on_show = install,
        on_hide = hide,
    }

ArtistScreen =
    screen:new {
        create_ui = function(self)
            local key =
                artist_key(self.item)
            local cached =
                sync_catalog.cached_key(
                    "artist:" ..
                    tostring(key)
                )
            local selection_required =
                cached and
                cached.resolution ==
                    "selection_required"
            local resolved_name =
                cached and
                type(cached.artist) ==
                    "table" and
                cached.artist.name or
                self.title or
                self.item.artist or
                "Artist"
            local page_title =
                selection_required and
                "Select artist" or
                resolved_name
            local root_valid = false
            if self.root and
                type(self.root.is_valid) ==
                    "function" then
                local ok, valid = pcall(
                    function()
                        return self.root:
                            is_valid()
                    end
                )
                root_valid =
                    ok and valid == true
            end

            if root_valid and self.list then
                self.header_marquee:set(
                    page_title
                )
            else
                -- Use the same backstack-owned Back path as every other
                -- list screen. The native backstack calls can_pop(), hides
                -- this child, restores the existing parent, then loads it.
                jellyfin_list_ui.create_root(
                    self,
                    page_title
                )
            end

            if selection_required then
                self.waiting_for_catalog =
                    false
                for _, candidate in ipairs(
                    cached.candidates or {}
                ) do
                    jellyfin_list_ui
                        .add_action_row(
                            self,
                            candidate.name or
                                "Artist",
                            {
                                selection_id =
                                    "sync:artist:" ..
                                    tostring(
                                        candidate.key
                                    ),
                                on_click =
                                    function()
                                        local item = {}
                                        for field, value
                                            in pairs(
                                                self.item
                                            ) do
                                            item[field] =
                                                value
                                        end
                                        item.artist_key =
                                            candidate.key
                                        item.artist =
                                            candidate.name
                                        backstack.push(
                                            ArtistScreen:new {
                                                item = item,
                                                title =
                                                    candidate
                                                        .name,
                                            }
                                        )
                                    end,
                            }
                        )
                end
            elseif cached and cached.groups then
                self.waiting_for_catalog =
                    false
                local count = 0
                for _, group in ipairs(
                    cached.groups
                ) do
                    jellyfin_list_ui
                        .add_section_label(
                            self,
                            ({
                                albums = "Albums",
                                singles =
                                    "Singles and EPs",
                                features =
                                    "Features",
                            })[group.id] or
                            group.id
                        )
                    for _, item in ipairs(
                        group.items or {}
                    ) do
                        add_result_row(
                            self,
                            item,
                            count < 7
                        )
                        count = count + 1
                    end
                end
                if count == 0 then
                    jellyfin_list_ui.add_message(
                        self,
                        "No releases"
                    )
                end
            else
                self.waiting_for_catalog =
                    true
                local row =
                    jellyfin_list_ui.add_message(
                        self,
                        "Loading"
                    )
                self.first_row = row.object
                sync_catalog.artist_releases(
                    self.item
                )
            end
            self.first_row =
                self.first_row or
                (
                    self.rows[1] and
                    self.rows[1].object
                )
        end,
        render = function(self)
            if self.discography_leaving or
                active_screen ~= self or
                not self.ui_active then
                return
            end
            local was_active =
                self.ui_active == true
            clear_rows(self)
            self:create_ui()
            if was_active then
                install(self)
            end
        end,
        can_pop = function(self)
            if self.discography_back_pending then
                return false
            end
            self.discography_back_pending = true
            return true
        end,
        on_show = function(self)
            self.discography_leaving =
                false
            self.discography_back_pending =
                false
            self.discography_generation =
                (
                    self
                        .discography_generation or
                    0
                ) + 1
            install(self)
        end,
        on_hide = function(self)
            self.discography_leaving =
                true
            self.waiting_for_catalog =
                false
            self.discography_generation =
                (
                    self
                        .discography_generation or
                    0
                ) + 1
            hide(self)
        end,
    }

CatalogScreen =
    screen:new {
        request_sorted_catalog =
            function(self, cursor)
                local limit, options =
                    catalog_sort_options(
                        self.view,
                        self.view,
                        CATALOG_PAGE_SIZE
                    )
                local generation =
                    self.catalog_generation or 0
                if not cursor then
                    generation = generation + 1
                end
                options.generation = generation

                local started, err =
                    sync_catalog.start(
                        self.view,
                        cursor,
                        limit,
                        options
                    )
                if started then
                    self.catalog_generation =
                        generation
                    self.next_catalog_refresh_at =
                        time.ticks() +
                        CATALOG_REFRESH_INTERVAL_MS
                    self.pagination_loading =
                        true
                    self.pagination_cursor =
                        cursor
                end
                return started, err
            end,
        on_catalog_item_focus =
            function(self, index)
                local payload =
                    sync_catalog.cached(
                        self.view
                    )
                local loaded =
                    #(self.items or {})
                if not payload or
                    self.pagination_loading or
                    sync_catalog.busy() or
                    type(payload.next_cursor) ~=
                        "string" or
                    payload.next_cursor == "" or
                    index < math.max(
                        1,
                        loaded -
                            CATALOG_PREFETCH_DISTANCE
                    ) then
                    return
                end

                self:request_sorted_catalog(
                    payload.next_cursor
                )
            end,
        create_ui = function(self)
            jellyfin_list_ui.create_root(
                self,
                self.title or "Sync"
            )
            self:render(true)
        end,
        render = function(self, initial)
            local payload =
                sync_catalog.cached(
                    self.view
                )
            if not payload then
                self.waiting_for_catalog = true
                if not initial then
                    clear_rows(self)
                end
                local message = "Loading"
                if not sync_catalog.busy() and
                    not self.load_attempted then
                    local started, err =
                        self:
                            request_sorted_catalog()
                    if started then
                        self.load_attempted = true
                    elseif err ~=
                            "sync request is already active" then
                        message = err or
                            "Unable to load"
                    end
                elseif not sync_catalog.busy() and
                    self.load_attempted then
                    message =
                        sync_catalog.error() or
                        "Unable to load"
                end
                local row =
                    jellyfin_list_ui.add_message(
                        self,
                        message
                    )
                self.first_row = row.object
                if self.ui_active then
                    install(self)
                end
                return
            end

            self.waiting_for_catalog = false
            if not sync_catalog.busy() then
                self.pagination_loading = false
            end

            if self.catalog_generation == nil and
                payload.generation ~= nil then
                self.catalog_generation =
                    payload.generation
            end

            local rendered_payload = {
                items =
                    catalog_items(
                        payload,
                        self.view
                    ),
                next_cursor =
                    payload.next_cursor,
                total = payload.total,
                total_count =
                    payload.total_count or
                    payload.total,
                generation =
                    payload.generation,
            }

            if self.result_models and
                payload.generation ==
                    self.catalog_generation and
                append_catalog_items(
                    self,
                    rendered_payload
                ) then
                return
            end

            render_items(
                self,
                rendered_payload,
                self.view
            )
        end,
        on_show = function(self)
            self.ui_active = true
            install(self)
        end,
        on_hide = hide,
    }

ResultsScreen =
    screen:new {
        create_ui = function(self)
            jellyfin_list_ui.create_root(
                self,
                "Search"
            )
            self:render(true)
        end,
        render = function(self, initial)
            local payload =
                sync_catalog.cached_key(
                    "search:" ..
                    tostring(self.query)
                )
            if not payload then
                self.waiting_for_catalog = true
                if not initial then
                    clear_rows(self)
                end
                local message =
                    sync_catalog.busy() and
                    "Searching" or
                    sync_catalog.error() or
                    "Searching"
                local row =
                    jellyfin_list_ui.add_message(
                        self,
                        message
                    )
                self.first_row = row.object
                if self.ui_active then
                    install(self)
                end
                return
            end
            self.waiting_for_catalog = false
            if not initial and
                self.result_models then
                update_search_results(
                    self,
                    payload
                )
                return
            end
            render_items(
                self,
                payload,
                "search"
            )
        end,
        on_show = install,
        on_hide = hide,
    }

SearchScreen =
    screen:new {
        create_ui = function(self)
            jellyfin_list_ui.create_root(
                self,
                "Search"
            )
            self.albums_enabled =
                self.albums_enabled ~= false
            self.tracks_enabled =
                self.tracks_enabled == true
            local query_row =
                jellyfin_list_ui.add_action_row(
                self,
                "Enter query",
                {
                    selection_id =
                        "sync:search:query",
                    on_click = function()
                        backstack.push(
                            jellyfin_text_entry.new {
                                title = "Search",
                                initial_carousel_active =
                                    true,
                                on_submit =
                                    function(query)
                                        local kinds = {}
                                        if self.albums_enabled then
                                            table.insert(
                                                kinds,
                                                "album"
                                            )
                                        end
                                        if self.tracks_enabled then
                                            table.insert(
                                                kinds,
                                                "track"
                                            )
                                        end
                                        if #kinds == 0 then
                                            return false,
                                                "Select a type"
                                        end
                                        local started,
                                            err =
                                            sync_catalog.search(
                                                query,
                                                kinds,
                                                sync_sort.current(
                                                    "search"
                                                )
                                            )
                                        if not started then
                                            return false, err
                                        end
                                        backstack.push(
                                            ResultsScreen:new {
                                                query = query,
                                            }
                                        )
                                        return "handled"
                                    end,
                            }
                        )
                    end,
                }
            )
            local toggles
            toggles =
                jellyfin_list_ui.add_toggle_actions(
                    self,
                    {
                        {
                            label = "Albums",
                            active =
                                self.albums_enabled,
                            selection_id =
                                "sync:search:albums",
                            on_click = function()
                                self.albums_enabled =
                                    not self.albums_enabled
                                toggles[1]:set_active(
                                    self.albums_enabled
                                )
                            end,
                        },
                        {
                            label = "Tracks",
                            active =
                                self.tracks_enabled,
                            selection_id =
                                "sync:search:tracks",
                            on_click = function()
                                self.tracks_enabled =
                                    not self.tracks_enabled
                                toggles[2]:set_active(
                                    self.tracks_enabled
                                )
                            end,
                        },
                    }
                )
            self.toggle_rows = toggles
            self.first_row = query_row.object
        end,
        on_show = install,
        on_hide = hide,
    }

local function advance_new_catalog_generation(
    self
)
    if type(
        sync_catalog.next_generation
    ) == "function" then
        self.new_catalog_generation =
            sync_catalog.next_generation(
                "new"
            )
    else
        self.new_catalog_generation =
            (
                self.new_catalog_generation or
                0
            ) + 1
    end
end

LandingScreen =
    screen:new {
        request_new_catalog =
            function(self)
                if sync_catalog.busy() then
                    self.new_refresh_pending =
                        true
                    return false,
                        "sync request is already active"
                end

                local started, err =
                    sync_catalog.start(
                        "albums",
                        nil,
                        20,
                        {
                            sort =
                                "date_added",
                            direction =
                                "descending",
                            cache_key = "new",
                            generation =
                                self
                                    .new_catalog_generation,
                        }
                    )

                self.new_load_attempted =
                    true

                if started then
                    self.new_refresh_pending =
                        false
                    self.next_catalog_refresh_at =
                        time.ticks() +
                        CATALOG_REFRESH_INTERVAL_MS
                    self.new_request_generation =
                        self.new_catalog_generation
                    self.new_failed_generation =
                        nil
                    self.new_error = nil
                elseif err ==
                        "sync request is already active" then
                    -- Another companion request owns the shared transport.
                    -- This generation is still pending, not failed.
                    self.new_refresh_pending =
                        true
                else
                    self.new_refresh_pending =
                        false
                    self.new_failed_generation =
                        self.new_catalog_generation
                    self.new_error = err
                end

                return started, err
            end,
        create_ui = function(self)
            self.fresh_top_level_entry =
                true
            self.preserve_leading_controls_on_open =
                true
            jellyfin_list_ui.create_root(
                self,
                "Sync"
            )
            self:render(true)
        end,
        render = function(self, initial)
            local selected =
                self.selected_item_id
            local preserve_scroll =
                not initial and
                not self.fresh_top_level_entry and
                self.ui_active == true
            local preserved_scroll_y =
                self.resume_plain_scroll_y
            local preserved_scroll_id =
                self.resume_plain_scroll_id

            if preserve_scroll then
                jellyfin_list_ui.capture_list_scroll(
                    self
                )
                -- Prefer the hide-time capture over a mid-rebuild snapshot.
                if preserved_scroll_y ~= nil then
                    self.resume_plain_scroll_y =
                        preserved_scroll_y
                    self.resume_plain_scroll_id =
                        preserved_scroll_id or
                        self.resume_plain_scroll_id
                end
            end

            if not initial then
                clear_rows(self)
            end
            local quick =
                jellyfin_list_ui.add_quick_actions(
                    self,
                    {
                        {
                            icon_kind = "search",
                            label = "Search",
                            selection_id =
                                "sync:search",
                            on_click = function()
                                backstack.push(
                                    SearchScreen:new()
                                )
                            end,
                        },
                        {
                            icon_kind = "album",
                            label = "Albums",
                            selection_id =
                                "sync:albums",
                            on_click = function()
                                backstack.push(
                                    CatalogScreen:new {
                                        title = "Albums",
                                        view = "albums",
                                    }
                                )
                            end,
                        },
                        {
                            icon_kind = "tracks",
                            label = "Tracks",
                            selection_id =
                                "sync:tracks",
                            on_click = function()
                                backstack.push(
                                    CatalogScreen:new {
                                        title = "Tracks",
                                        view = "tracks",
                                    }
                                )
                            end,
                        },
                    }
                )
            jellyfin_list_ui.add_section_label(
                self,
                "New"
            )
            local payload =
                sync_catalog.cached("new")
            local exact_payload =
                type(payload) == "table" and
                payload.view == "albums" and
                payload.sort ==
                    "date_added" and
                payload.direction ==
                    "descending"

            local new_album_rows = {}
            if exact_payload then
                self.waiting_for_catalog = false
                local albums =
                    catalog_items(
                        payload,
                        "albums",
                        20
                    )
                for _, item in ipairs(
                    albums
                ) do
                    table.insert(
                        new_album_rows,
                        add_result_row(
                            self,
                            item
                        )
                    )
                end
                if #albums == 0 then
                    jellyfin_list_ui.add_message(
                        self,
                        "No new albums"
                    )
                end
            else
                self.waiting_for_catalog =
                    payload == nil
                local current_failed =
                    self.new_failed_generation ~= nil and
                    self.new_failed_generation ==
                        self.new_catalog_generation
                local message =
                    payload and
                    "Companion update required" or
                    (
                        current_failed and
                        (
                            self.new_error or
                            "Unable to load"
                        ) or
                        "Loading"
                    )
                jellyfin_list_ui.add_message(
                    self,
                    message
                )
            end
            self.quick_rows = quick

            -- The three quick actions share one visual row. Track that row as
            -- a single logical item, followed by the New album rows, so the
            -- landing page gets the same compact scrollbar as other lists.
            local landing_scroll_models = {
                quick[1],
            }
            for _, model in ipairs(
                new_album_rows
            ) do
                table.insert(
                    landing_scroll_models,
                    model
                )
            end
            local landing_initial_index = 1
            if not self.fresh_top_level_entry and
                selected then
                for index, model in ipairs(
                    landing_scroll_models
                ) do
                    if model.selection_id ==
                            selected then
                        landing_initial_index = index
                        break
                    end
                end
            end
            jellyfin_list_ui.attach_scroll_indicator(
                self,
                landing_scroll_models,
                {
                    visible_items = 3,
                    initial_index =
                        landing_initial_index,
                    focus_aliases = {
                        {
                            model = quick[2],
                            index = 1,
                        },
                        {
                            model = quick[3],
                            index = 1,
                        },
                    },
                }
            )

            self.first_row = quick[1].object
            self.selected_item_id =
                self.fresh_top_level_entry and
                "sync:search" or
                selected
            if self.ui_active then
                install(self)
                if self.fresh_top_level_entry then
                    jellyfin_list_ui
                        .focus_first_row(self)
                    pcall(
                        function()
                            self.list:scroll_to {
                                x = 0,
                                y = 0,
                                anim = false,
                            }
                        end
                    )
                elseif preserve_scroll then
                    jellyfin_list_ui
                        .restore_list_scroll(self)
                end
            end
        end,
            on_show = function(self)
            advance_new_catalog_generation(
                self
            )
            self.new_refresh_pending = true
            install(self)
            if self.fresh_top_level_entry then
                jellyfin_list_ui
                    .focus_first_row(self)
                pcall(
                    function()
                        self.list:scroll_to {
                            x = 0,
                            y = 0,
                            anim = false,
                        }
                    end
                )
            else
                -- Escape from Albums/Tracks/Search must keep the saved Sync
                -- root viewport, not an animated reveal back to the top.
                self.suppress_focus_scroll = true
                jellyfin_list_ui.restore_list_scroll(
                    self
                )
                self.suppress_focus_scroll = false
            end
            self:request_new_catalog()
        end,
        on_hide = function(self)
            self.fresh_top_level_entry =
                false
            hide(self)
        end,
    }

local function poll_active()
    if not active_screen then
        -- Landing New-refresh can still be pending after a child screen cleared
        -- active_screen during pop ordering. Recover from the backstack tip.
        local current =
            type(backstack.current) ==
                "function" and
            backstack.current() or nil
        if type(current) == "table" and
            current.new_refresh_pending and
            type(current.request_new_catalog) ==
                "function" then
            active_screen = current
        else
            if poll_timer then
                poll_timer:pause()
            end
            return
        end
    end

    sync_artwork_cache.poll()
    local result = sync_catalog.poll()
    if not active_screen then
        return
    end

    local new_result =
        type(result) == "table" and
        result.key == "new" and
        active_screen
            .new_catalog_generation ~= nil

    if new_result and
        result.kind == "catalog" and
        result.generation ==
            active_screen
                .new_catalog_generation then
        active_screen.new_request_generation =
            nil
        active_screen.new_refresh_pending =
            false

        if result.ok then
            active_screen.new_failed_generation =
                nil
            active_screen.new_error = nil
        else
            active_screen.new_failed_generation =
                result.generation
            active_screen.new_error =
                result.error or
                "Unable to load"
        end
    end

    if active_screen.new_refresh_pending and
        not sync_catalog.busy() and
        type(
            active_screen.request_new_catalog
        ) == "function" then
        active_screen:request_new_catalog()
    end

    local next_catalog_refresh_at =
        tonumber(
            active_screen
                .next_catalog_refresh_at
        )
    if next_catalog_refresh_at and
        time.ticks() >=
            next_catalog_refresh_at and
        not sync_catalog.busy() and
        not active_screen
            .new_refresh_pending then
        if type(
            active_screen
                .request_new_catalog
        ) == "function" then
            advance_new_catalog_generation(
                active_screen
            )
            active_screen.new_refresh_pending =
                true
            active_screen:
                request_new_catalog()
        elseif type(
            active_screen
                .request_sorted_catalog
        ) == "function" and
            not active_screen
                .pagination_loading then
            active_screen:
                request_sorted_catalog()
        end
    end

    local queue_accepted =
        type(result) == "table" and
        result.ok == true and
        result.kind == "queue"
    if queue_accepted then
        if type(sync_runtime.dispatch_download) ~=
                "function" then
            sync_runtime.request_refresh()
        end
        refresh_runtime_rows(
            active_screen
        )
    end

    local content_generation =
        type(sync_runtime.content_generation) ==
            "function" and
        sync_runtime.content_generation() or 0

    if content_generation ~= (
        active_screen.sync_content_generation or 0
    ) then
        local_library = nil
        local_library_generation = -1
        active_screen.sync_content_generation =
            content_generation
        refresh_runtime_rows(active_screen)
    end

    local signature =
        runtime_ui_signature()
    if signature ~= active_screen
            .sync_runtime_signature then
        refresh_runtime_rows(
            active_screen
        )
    end

    -- Do not rebuild the whole Sync catalog while a download is painting
    -- mounted-row icons. Queue acceptance already refreshed those rows.
    local apply_busy =
        type(sync_runtime.apply_progress) ==
            "function" and
        type(sync_runtime.apply_progress()) ==
            "table"
    if (
        (
            result and
            not queue_accepted and
            not apply_busy
        ) or
        (
            active_screen
                .waiting_for_catalog and
            not sync_catalog.busy()
        )
    ) and
        type(active_screen.render) ==
            "function" then
        active_screen:render()
    end
end

local function ensure_timer()
    if poll_timer then
        poll_timer:resume()
        return
    end
    poll_timer = lvgl.Timer {
        period = 250,
        cb = poll_active,
    }
end

local base_install = install
install = function(self)
    ensure_timer()
    base_install(self)
end

local function debug_state_diagnostics(
    items,
    output
)
    output = output or print
    local diagnostics = {}

    for _, item in ipairs(items or {}) do
        local server_count,
            local_count,
            child_ids,
            matched_ids

        if item.kind == "album" then
            server_count,
                local_count,
                child_ids,
                matched_ids =
                album_inventory(item)
        else
            local id =
                verified_jellyfin_id(
                    item
                )
            local_count =
                id and
                local_track_ids[id] and
                1 or 0
            server_count =
                id and 1 or nil
            child_ids =
                id and {id} or nil
            matched_ids =
                local_count == 1 and
                {id} or {}
        end

        local state = item_state(item)
        local diagnostic = {
            title =
                tostring(item.title or ""),
            jellyfin_id =
                verified_jellyfin_id(
                    item
                ),
            canonical_album_id =
                jellyfin_album_identity
                    .album_id(item),
            local_album_key =
                jellyfin_album_identity
                    .local_album_key(item),
            in_jellyfin =
                verified_jellyfin_id(
                    item
                ) ~= nil,
            server_track_count =
                server_count,
            child_track_ids =
                child_ids or {},
            matched_local_track_ids =
                matched_ids or {},
            local_count =
                local_count or 0,
            state = state,
            icon =
                state_icon_kind(
                    item,
                    state
                ) or "none",
        }
        diagnostics[
            #diagnostics + 1
        ] = diagnostic

        output(
            string.format(
                "title=%s jellyfin_id=%s canonical_album_id=%s local_album_key=%s in_jellyfin=%s server_track_count=%s child_track_ids=%s matched_local_track_ids=%s local_count=%d final_state=%s final_icon=%s",
                diagnostic.title,
                tostring(
                    diagnostic.jellyfin_id or
                    ""
                ),
                tostring(
                    diagnostic
                        .canonical_album_id or
                    ""
                ),
                tostring(
                    diagnostic
                        .local_album_key or
                    ""
                ),
                tostring(
                    diagnostic.in_jellyfin
                ),
                tostring(
                    diagnostic
                        .server_track_count or
                    ""
                ),
                table.concat(
                    diagnostic
                        .child_track_ids,
                    ","
                ),
                table.concat(
                    diagnostic
                        .matched_local_track_ids,
                    ","
                ),
                diagnostic.local_count,
                diagnostic.state,
                diagnostic.icon
            )
        )
    end

    return diagnostics
end

M.Root = LandingScreen
M.Landing = LandingScreen
M.Catalog = CatalogScreen
M.Search = SearchScreen
M.Results = ResultsScreen
M.Confirm = ConfirmScreen
M.Destination = DestinationScreen
M.Status = StatusScreen
M.Artist = ArtistScreen
M.ArtistAction = ArtistActionScreen
M.state_label = state_label
M.state_icon_kind = function(item)
    local state = item_state(item)
    return state_icon_kind(item, state)
end
M.status_cell = {
    x = STATUS_CELL_X,
    y = STATUS_CELL_Y,
    w = STATUS_CELL_W,
    h = STATUS_CELL_H,
    center_x = STATUS_CELL_CENTER_X,
    center_y = STATUS_CELL_CENTER_Y,
}
M.debug_state_diagnostics =
    debug_state_diagnostics
M.item_state = item_state
M.canonical_album_id =
    jellyfin_album_identity.album_id
M.local_album_key =
    jellyfin_album_identity.local_album_key
M.actionable = actionable
M.activate = activate
M.download_icon_anim_active = function()
    return download_icon_anim_model ~= nil
end
M.sync_download_icon_anim =
    sync_download_icon_anim
M.download_state = sync_download_state

return M
