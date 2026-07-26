local device = require("device")
local playback = require("playback")
local queue = require("queue")
local sync_manifest_cache =
    require("sync_manifest_cache")

local M = {}
local active = nil

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

local function find_manifest_item(
    manifest,
    jellyfin_id
)
    for _, item in ipairs(
        manifest.items or {}
    ) do
        if item.jellyfin_id ==
            jellyfin_id or
            item.id == jellyfin_id then
            return item
        end
    end

    return nil
end

local function file_exists(path)
    local file = io.open(path, "rb")

    if not file then
        return false
    end

    file:close()
    return true
end

function M.local_item(track)
    if type(track) ~= "table" or
        type(track.id) ~= "string" or
        track.id == "" then
        return nil,
            "Jellyfin track ID is missing"
    end

    local manifest, manifest_error =
        sync_manifest_cache.load()

    if not manifest then
        return nil,
            manifest_error or
            "download manifest is unavailable"
    end

    local item =
        find_manifest_item(
            manifest,
            track.id
        )

    if not item then
        return nil,
            "Track is not downloaded yet"
    end

    if type(item.local_path) ~= "string" or
        item.local_path == "" or
        item.local_path:sub(1, 1) ~= "/" then
        return nil,
            "Downloaded track path is invalid"
    end

    local root, root_error =
        device.storage_root()

    if type(root) ~= "string" or
        root == "" then
        return nil,
            root_error or
            "storage root is unavailable"
    end

    root = root:gsub("/+$", "")

    if not file_exists(
        root .. item.local_path
    ) then
        return nil,
            "Track is not downloaded yet"
    end

    return item
end

function M.play(track, context)
    local item, item_error =
        M.local_item(track)

    if not item then
        return false, item_error
    end

    active = {
        track = copy_value(track),
        item = copy_value(item),
        context =
            copy_value(context or {}),
    }

    queue.clear()

    if queue.random and
        type(queue.random.set) ==
            "function" then
        queue.random:set(false)
    end

    queue.play_from(
        item.local_path,
        0
    )

    playback.playing:set(true)

    return true, copy_value(active)
end

function M.current()
    return copy_value(active)
end

return M

