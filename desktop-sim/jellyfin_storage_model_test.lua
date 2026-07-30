package.path =
    "lua/?.lua;" ..
    "desktop-sim/?.lua;" ..
    package.path

local root =
    "/tmp/tangara-storage-model"

os.execute("rm -rf " .. root)
os.execute(
    "mkdir -p " .. root ..
    "/Music " .. root ..
    "/.tangara-artwork"
)

local function write(path, bytes)
    local file = assert(io.open(path, "wb"))
    assert(file:write(string.rep("x", bytes)))
    file:close()
end

write(root .. "/Music/一曲.flac", 100)
write(root .. "/Music/二曲.flac", 150)
write(root .. "/Music/incomplete.part", 25)
write(
    root ..
        "/.tangara-artwork/作品.png",
    40
)

package.loaded["device"] = {
    storage_root = function()
        return root
    end,
    storage_info = function()
        return {
            total_bytes = 1000,
            used_bytes = 600,
            free_bytes = 400,
        }
    end,
}

local tracks = {
    {
        id = "track-一",
        title = "一曲",
        artist = "音楽家",
        album = "作品",
        local_path = "/Music/一曲.flac",
    },
    {
        id = "track-二",
        title = "二曲",
        artist = "音楽家",
        album = "作品",
        local_path = "/Music/二曲.flac",
    },
}
local album = {
    key = "album-作品",
    name = "作品",
    artist = "音楽家",
    track_count = 2,
    tracks = tracks,
}
local invalidations = 0

package.loaded["jellyfin_local_index"] = {
    load = function()
        return {
            albums = {album},
            tracks = tracks,
            counts = {
                albums = 1,
                tracks = 2,
            },
        }
    end,
    invalidate = function()
        invalidations = invalidations + 1
    end,
}

local manifest = {
    items = {
        {
            jellyfin_id = "track-一",
            local_path = "/Music/一曲.flac",
            sync_state = "ready",
            artwork = {
                cover =
                    "/.tangara-artwork/作品.png",
            },
        },
        {
            jellyfin_id = "track-二",
            local_path = "/Music/二曲.flac",
            sync_state = "ready",
            artwork = {
                cover =
                    "/.tangara-artwork/作品.png",
            },
        },
        {
            jellyfin_id = "track-incomplete",
            local_path =
                "/Music/incomplete.part",
            sync_state = "partial",
        },
    },
}

package.loaded["sync_manifest_cache"] = {
    load = function()
        return manifest
    end,
}

local managed = {
    "/Music/一曲.flac",
    "/Music/二曲.flac",
    "/Music/incomplete.part",
    "/.tangara-artwork/作品.png",
}

package.loaded["sync_managed_paths"] = {
    load = function()
        local copied = {}

        for index, path in ipairs(managed) do
            copied[index] = path
        end

        return copied
    end,
    save = function(paths)
        managed = paths
        return true
    end,
}

package.loaded["sync_reconcile"] = {
    normalize_local_path = function(path)
        if type(path) ~= "string" or
            path:sub(1, 1) ~= "/" or
            path:find("..", 1, true) then
            return nil, "unsafe path"
        end

        return path
    end,
}

package.preload["sync_operation_queue"] =
    function()
        error(
            "Storage cleanup must not load the server operation queue"
        )
    end

package.loaded["jellyfin_storage"] = nil
local storage =
    require("jellyfin_storage")

local snapshot = assert(storage.snapshot())

assert(snapshot.total_bytes == 1000)
assert(snapshot.used_bytes == 600)
assert(snapshot.available_bytes == 400)
assert(snapshot.music_bytes == 250)
assert(snapshot.artwork_bytes == 40)
assert(snapshot.system_bytes == 310)
assert(snapshot.album_count == 1)
assert(snapshot.track_count == 2)
assert(snapshot.individual_track_count == 0)
assert(snapshot.artwork_count == 1)
assert(snapshot.incomplete_count == 1)
assert(tracks[1].title == "一曲")
assert(album.name == "作品")

local removed_album, album_error =
    storage.remove_album(album)

assert(removed_album, album_error)
assert(
    io.open(
        root .. "/Music/一曲.flac",
        "rb"
    ) == nil
)
assert(
    io.open(
        root .. "/Music/二曲.flac",
        "rb"
    ) == nil
)

local cleared_art, art_error =
    storage.clear_artwork_cache()

assert(cleared_art, art_error)
assert(
    io.open(
        root ..
            "/.tangara-artwork/作品.png",
        "rb"
    ) == nil
)

local cleared_temp, temp_error =
    storage.clear_temporary_files()

assert(cleared_temp, temp_error)
assert(
    io.open(
        root .. "/Music/incomplete.part",
        "rb"
    ) == nil
)
assert(#managed == 0)
assert(invalidations == 3)

os.execute("rm -rf " .. root)

print(
    "Offline Storage model metrics and local-only cleanup passed"
)
os.exit(0)
