local device = require("device")
local jellyfin_local_index =
    require("jellyfin_local_index")
local sync_managed_paths =
    require("sync_managed_paths")
local sync_manifest_cache =
    require("sync_manifest_cache")
local sync_reconcile =
    require("sync_reconcile")

local M = {}

local function storage_root()
    local root, root_error =
        device.storage_root()

    if type(root) ~= "string" or
        root == "" then
        return nil,
            root_error or
            "storage root is unavailable"
    end

    return root:gsub("/+$", "")
end

local function ready(item)
    local state = item and item.sync_state

    return state == nil or
        state == "" or
        state == "ready" or
        state == "downloaded" or
        state == "complete"
end

local function file_size(path)
    local file = io.open(path, "rb")

    if not file then
        return 0, false
    end

    local size = file:seek("end")
    file:close()

    return tonumber(size) or 0, true
end

local function add_path(set, value)
    if type(value) == "string" and
        value:sub(1, 1) == "/" and
        value:sub(1, 2) ~= "//" then
        set[value] = true
    end
end

local function manifest_paths(manifest)
    local music = {}
    local artwork = {}
    local incomplete = {}

    for _, item in ipairs(
        manifest and manifest.items or {}
    ) do
        if ready(item) then
            add_path(music, item.local_path)
        else
            add_path(incomplete, item.local_path)
        end

        for _, value in pairs(
            type(item.artwork) == "table" and
                item.artwork or {}
        ) do
            add_path(artwork, value)
        end
    end

    return music, artwork, incomplete
end

local function paths_size(root, paths)
    local total = 0
    local count = 0

    for path in pairs(paths) do
        local size, exists =
            file_size(root .. path)

        if exists then
            total = total + size
            count = count + 1
        end
    end

    return total, count
end

local function storage_metrics()
    if type(device.storage_info) ~=
            "function" then
        return nil,
            "storage metrics are unavailable"
    end

    local info, info_error =
        device.storage_info()

    if type(info) ~= "table" then
        return nil,
            info_error or
            "storage metrics are unavailable"
    end

    local total =
        math.max(
            0,
            tonumber(info.total_bytes) or 0
        )
    local free =
        math.max(
            0,
            tonumber(
                info.free_bytes or
                info.available_bytes
            ) or 0
        )
    local used =
        math.max(
            0,
            tonumber(info.used_bytes) or
                total - free
        )

    return {
        total_bytes = total,
        free_bytes = math.min(total, free),
        used_bytes = math.min(total, used),
    }
end

function M.snapshot()
    local root, root_error =
        storage_root()

    if not root then
        return nil, root_error
    end

    local library, library_error =
        jellyfin_local_index.load()
    local manifest, manifest_error =
        sync_manifest_cache.load()

    library = library or {
        albums = {},
        tracks = {},
        counts = {
            albums = 0,
            tracks = 0,
        },
    }
    manifest = manifest or {items = {}}

    local music_paths,
        artwork_paths,
        incomplete_paths =
        manifest_paths(manifest)

    local music_bytes =
        paths_size(root, music_paths)
    local artwork_bytes,
        artwork_count =
        paths_size(root, artwork_paths)
    local incomplete_bytes,
        incomplete_count =
        paths_size(root, incomplete_paths)

    local metrics, metrics_error =
        storage_metrics()

    local total_bytes =
        metrics and
            metrics.total_bytes or 0
    local free_bytes =
        metrics and
            metrics.free_bytes or 0
    local used_bytes =
        metrics and
            metrics.used_bytes or
            music_bytes +
                artwork_bytes +
                incomplete_bytes
    local system_bytes =
        math.max(
            0,
            used_bytes -
                music_bytes -
                artwork_bytes
        )

    local individual_tracks = 0

    for _, album in ipairs(
        library.albums or {}
    ) do
        if tonumber(album.track_count) == 1 then
            individual_tracks =
                individual_tracks + 1
        end
    end

    return {
        root = root,
        library = library,
        manifest = manifest,
        albums = library.albums or {},
        tracks = library.tracks or {},
        album_count =
            #(library.albums or {}),
        track_count =
            #(library.tracks or {}),
        individual_track_count =
            individual_tracks,
        artwork_count = artwork_count,
        incomplete_count =
            incomplete_count,
        used_bytes = used_bytes,
        available_bytes = free_bytes,
        total_bytes = total_bytes,
        music_bytes = music_bytes,
        artwork_bytes = artwork_bytes,
        incomplete_bytes =
            incomplete_bytes,
        system_bytes = system_bytes,
        metrics_error = metrics_error,
        library_error = library_error,
        manifest_error = manifest_error,
    }
end

function M.format_bytes(value)
    value =
        math.max(
            0,
            tonumber(value) or 0
        )

    local units = {
        "B",
        "KB",
        "MB",
        "GB",
        "TB",
    }
    local unit = 1

    while value >= 1024 and
        unit < #units do
        value = value / 1024
        unit = unit + 1
    end

    if unit == 1 then
        return string.format(
            "%d %s",
            math.floor(value),
            units[unit]
        )
    end

    return string.format(
        value >= 10 and "%.0f %s" or
            "%.1f %s",
        value,
        units[unit]
    )
end

local function remove_local_paths(paths)
    local root, root_error =
        storage_root()

    if not root then
        return false, root_error
    end

    local normalized = {}

    for _, path in ipairs(paths or {}) do
        local value, path_error =
            sync_reconcile
                .normalize_local_path(path)

        if not value then
            return false, path_error
        end

        normalized[value] = true
    end

    local removed = 0

    for path in pairs(normalized) do
        local full_path = root .. path
        local _, exists =
            file_size(full_path)

        if exists then
            local ok, remove_error =
                os.remove(full_path)

            if not ok then
                return false,
                    remove_error or
                    "unable to remove local file"
            end

            removed = removed + 1
        end
    end

    local managed, managed_error =
        sync_managed_paths.load()

    if not managed then
        return false, managed_error
    end

    local kept = {}

    for _, path in ipairs(managed) do
        if not normalized[path] then
            table.insert(kept, path)
        end
    end

    local saved, save_error =
        sync_managed_paths.save(kept)

    if not saved then
        return false, save_error
    end

    jellyfin_local_index.invalidate(
        "storage cleanup changed local files"
    )

    return true, nil, removed
end

function M.remove_track(track)
    if type(track) ~= "table" then
        return false, "track is required"
    end

    return remove_local_paths {
        track.local_path,
    }
end

function M.remove_tracks(tracks)
    local paths = {}

    for _, track in ipairs(tracks or {}) do
        table.insert(paths, track.local_path)
    end

    return remove_local_paths(paths)
end

function M.remove_album(album)
    if type(album) ~= "table" then
        return false, "album is required"
    end

    local paths = {}

    for _, track in ipairs(
        album.tracks or {}
    ) do
        table.insert(paths, track.local_path)
    end

    return remove_local_paths(paths)
end

function M.remove_albums(albums)
    local paths = {}

    for _, album in ipairs(albums or {}) do
        for _, track in ipairs(
            album.tracks or {}
        ) do
            table.insert(
                paths,
                track.local_path
            )
        end
    end

    return remove_local_paths(paths)
end

function M.clear_artwork_cache()
    local manifest, manifest_error =
        sync_manifest_cache.load()

    if not manifest then
        return false, manifest_error
    end

    local _, artwork =
        manifest_paths(manifest)
    local paths = {}

    for path in pairs(artwork) do
        table.insert(paths, path)
    end

    return remove_local_paths(paths)
end

function M.clear_temporary_files()
    local manifest =
        sync_manifest_cache.load()
    local _, _, incomplete =
        manifest_paths(
            manifest or {items = {}}
        )
    local paths = {}

    for path in pairs(incomplete) do
        table.insert(paths, path)
    end

    local managed =
        sync_managed_paths.load() or {}

    for _, path in ipairs(managed) do
        if path:match("%.tmp$") or
            path:match("%.part$") or
            path:match("%.partial$") or
            path:match("%.download$") then
            table.insert(paths, path)
        end
    end

    return remove_local_paths(paths)
end

return M
