package.path =
    "lua/?.lua;" ..
    "desktop-sim/?.lua;" ..
    package.path

local root =
    "desktop-sim/sd/library-cache-test"

os.execute("mkdir -p " .. root)

package.preload["device"] = function()
    return {
        id = function()
            return "library-cache-test"
        end,
        storage_root = function()
            return root
        end,
    }
end

local cache =
    require("sync_library_cache")
local queue =
    require("sync_operation_queue")
local view =
    require("sync_library_view")

local function clean()
    for _, module in ipairs({
        cache,
        queue,
    }) do
        local paths = assert(module.paths())

        os.remove(paths.path)
        os.remove(paths.temporary)
        os.remove(paths.backup)
    end
end

local function copy_file(source, destination)
    local input = assert(
        io.open(source, "rb")
    )
    local contents = input:read("*a")
    input:close()

    local output = assert(
        io.open(destination, "wb")
    )
    output:write(contents)
    output:close()
end

clean()

assert(cache.save({
    revision = "library-1",
    generated_at = 1,
    user = {
        id = "user-1",
        name = "Test User",
    },
    favorites = {
        name = "Favorites",
        revision = "favorites-1",
        track_count = 1,
        keep_downloaded = true,
        items = {
            {
                id = "track-1",
                title = "Track One",
                artist = "Artist",
                album = "Album",
                playlist_entry_id = nil,
                favorite = true,
            },
        },
    },
    playlists = {
        {
            id = "playlist-1",
            name = "Original",
            revision = "playlist-1",
            track_count = 2,
            keep_downloaded = true,
            items = {
                {
                    id = "track-1",
                    title = "Track One",
                    artist = "Artist",
                    album = "Album",
                    playlist_entry_id =
                        "entry-1",
                    favorite = true,
                    position = 0,
                },
                {
                    id = "track-2",
                    title = "Track Two",
                    artist = "Artist",
                    album = "Album",
                    playlist_entry_id =
                        "entry-2",
                    favorite = false,
                    position = 1,
                },
            },
        },
    },
}))

assert(
    queue.enqueue_rename_playlist(
        "playlist-1",
        "Renamed"
    )
)

assert(
    queue.enqueue_remove_playlist_item(
        "playlist-1",
        "entry-1"
    )
)

assert(
    queue.enqueue_add_playlist_item(
        "playlist-1",
        "track-3"
    )
)

local current = assert(view.current())

assert(current.pending_changes == 3)
assert(#current.playlists == 1)
assert(current.playlists[1].name == "Renamed")
assert(current.playlists[1].track_count == 2)
assert(current.playlists[1].items[1].id ==
    "track-2")
assert(current.playlists[1].items[2].id ==
    "track-3")

assert(
    queue.enqueue_set_favorite(
        "track-3",
        true
    )
)

local local_id = assert(
    queue.enqueue_create_playlist(
        "Offline",
        {"track-2"}
    )
)

assert(
    queue.enqueue_rename_playlist(
        local_id,
        "Offline Renamed"
    )
)

current = assert(view.current())

assert(current.pending_changes == 6)
assert(#current.playlists == 2)
assert(current.favorites.track_count == 2)

local offline = nil

for _, playlist in ipairs(
    current.playlists
) do
    if playlist.local_id == local_id then
        offline = playlist
        break
    end
end

assert(offline)
assert(offline.name == "Offline Renamed")
assert(offline.track_count == 1)
assert(offline.items[1].id == "track-2")

local paths = assert(cache.paths())

copy_file(
    paths.path,
    paths.backup
)

local corrupted = assert(
    io.open(paths.path, "wb")
)

corrupted:write("{broken")
corrupted:close()

package.loaded["sync_library_cache"] = nil
cache = require("sync_library_cache")

local recovered, was_recovered =
    cache.load()

assert(recovered)
assert(was_recovered == true)
assert(recovered.revision == "library-1")

clean()

print(
    "offline Jellyfin library cache passed"
)

os.exit(0)
