local M = {}

local function file_exists(path)
    local file = io.open(path, "rb")

    if not file then
        return false
    end

    file:close()
    return true
end

local function shell_quote(value)
    return "'" ..
        tostring(value):gsub("'", "'\\''") ..
        "'"
end

local function file_revision(path)
    if type(path) ~= "string" or
        path == "" then
        return "missing"
    end

    local process = io.popen(
        "stat -c '%s:%Y' " ..
        shell_quote(path) ..
        " 2>/dev/null"
    )

    if not process then
        return path
    end

    local value = process:read("*l")
    process:close()

    return type(value) == "string" and
        value ~= "" and value or path
end

function M.new(root)
    root = tostring(root or ""):gsub("/+$", "")

    local memory = {}
    local trace = {
        network_requests = 0,
        generated = 0,
        memory_hits = 0,
        disk_hits = 0,
        misses = 0,
        last = nil,
    }

    local function storage_path(value)
        if type(value) ~= "string" or
            value == "" then
            return nil
        end

        value = value:gsub("^/+", "")

        for segment in value:gmatch("[^/]+") do
            if segment == "." or
                segment == ".." then
                return nil
            end
        end

        return root .. "/" .. value
    end

    local function existing(artwork, key)
        local value =
            type(artwork) == "table" and
            artwork[key] or nil

        if type(value) ~= "string" or
            value == "" or
            value:sub(1, 2) == "//" then
            return nil
        end

        local full_path = storage_path(value)

        if not full_path or
            not file_exists(full_path) then
            return nil
        end

        return value, full_path
    end

    local function resolve(item, track)
        local item_artwork =
            type(item) == "table" and
            item.artwork or nil
        local track_artwork =
            type(track) == "table" and
            track.artwork or nil
        local resolved = {}
        local full_paths = {}

        for _, variant in ipairs({
            {"thumbnail", "28x28"},
            {"cover", "72x72"},
            {"background", "160x128"},
        }) do
            local key = variant[1]
            local value, full_path =
                existing(item_artwork, key)

            if not value then
                value, full_path =
                    existing(track_artwork, key)
            end

            if value then
                resolved[key] = value
                full_paths[key] = full_path
            end
        end

        -- Older manifests may contain only one square derivative. Reusing it
        -- is still offline and LVGL fits it into the requested square. A
        -- complete current manifest uses distinct 28x28 and 72x72 files.
        resolved.thumbnail =
            resolved.thumbnail or resolved.cover
        resolved.cover =
            resolved.cover or resolved.thumbnail
        full_paths.thumbnail =
            full_paths.thumbnail or full_paths.cover
        full_paths.cover =
            full_paths.cover or full_paths.thumbnail

        local identity =
            resolved.cover or
            resolved.thumbnail or
            resolved.background

        if not identity then
            trace.misses = trace.misses + 1
            trace.last = {
                track_id = track and
                    (track.jellyfin_id or track.id),
                album_id = track and track.album_id,
                source = nil,
                generated = false,
                network = false,
            }
            return nil
        end

        local revision =
            (item_artwork and
                (item_artwork.revision or
                    item_artwork.image_tag)) or
            (track_artwork and
                (track_artwork.revision or
                    track_artwork.image_tag)) or
            table.concat({
                file_revision(
                    full_paths.thumbnail
                ),
                file_revision(full_paths.cover),
                file_revision(
                    full_paths.background
                ),
            }, ":")
        local key =
            tostring(revision) .. "|" ..
            tostring(resolved.thumbnail or "") ..
            "|28x28|" ..
            tostring(resolved.cover or "") ..
            "|72x72|" ..
            tostring(resolved.background or "") ..
            "|160x128"
        local cached = memory[key]

        if cached then
            trace.memory_hits = trace.memory_hits + 1
            trace.last = cached.trace
            return cached
        end

        local result = {
            thumbnail = resolved.thumbnail,
            cover = resolved.cover,
            background = resolved.background,
            full_paths = full_paths,
            cache_key = key,
        }

        result.trace = {
            track_id = track and
                (track.jellyfin_id or track.id),
            album_id = track and track.album_id,
            source = resolved.cover,
            thumbnail = resolved.thumbnail,
            background = resolved.background,
            dimensions = {
                thumbnail = "28x28",
                cover = "72x72",
                background = "160x128",
            },
            full_paths = full_paths,
            cache_key = key,
            derived_exists = true,
            decoded_or_resized = false,
            generated = false,
            network = false,
        }

        memory[key] = result
        trace.disk_hits = trace.disk_hits + 1
        trace.last = result.trace
        return result
    end

    return {
        resolve = resolve,
        trace = trace,
    }
end

return M
