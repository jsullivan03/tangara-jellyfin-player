package.path =
    "lua/?.lua;" ..
    package.path

package.preload["device"] =
    function()
        return {
            storage_root = function()
                return
                    "/tmp/tangara-local-index-test"
            end,
        }
    end

package.preload["sync_manifest_cache"] =
    function()
        return {
            load = function()
                return nil,
                    "not used by this test"
            end,
        }
    end

local index =
    require("jellyfin_local_index")

local root =
    "/tmp/tangara-local-index-test"

os.execute("rm -rf " .. root)
os.execute("mkdir -p " .. root)

local function create_file(path)
    local full_path = root .. path
    local directory =
        full_path:match(
            "^(.*)/[^/]+$"
        )

    os.execute(
        "mkdir -p " .. directory
    )

    local file =
        assert(
            io.open(
                full_path,
                "wb"
            )
        )

    file:write("test")
    file:close()
end

create_file("/music/track-1.flac")
create_file("/music/track-2.flac")
create_file("/music/track-3.flac")

local manifest = {
    items = {
        {
            jellyfin_id = "track-1",
            title = "Second",
            artist = "Artist A",
            album = "Album A",
            album_id = "album-a",
            local_path =
                "/music/track-1.flac",
            sync_state = "ready",
            track_number = 2,
            date_created =
                "2026-01-01T00:00:00Z",
        },
        {
            jellyfin_id = "track-1",
            title = "Duplicate",
            artist = "Artist A",
            album = "Album A",
            album_id = "album-a",
            local_path =
                "/music/track-1.flac",
            sync_state = "ready",
        },
        {
            jellyfin_id = "track-2",
            title = "First",
            artist = "Artist A",
            album = "Album A",
            album_id = "album-a",
            local_path =
                "/music/track-2.flac",
            sync_state = "ready",
            track_number = 1,
            date_created =
                "2026-03-01T00:00:00Z",
        },
        {
            jellyfin_id = "track-3",
            title = "Single",
            artist = "Artist B",
            album = "Single",
            album_id = "single-b",
            local_path =
                "/music/track-3.flac",
            sync_state = "ready",
            date_created =
                "2026-02-01T00:00:00Z",
        },
    },
}

local library, library_error =
    index.from_manifest(
        manifest,
        root
    )

assert(library, library_error)
assert(library.counts.tracks == 3)
assert(library.counts.albums == 2)
assert(library.counts.artists == 2)
assert(
    library.albums[1].tracks[1]
        .title == "First"
)
assert(
    library.albums[1].date_created ==
        "2026-03-01T00:00:00Z"
)
assert(
    library.artists[1].date_created ==
        "2026-03-01T00:00:00Z"
)

print(
    "Local library index passed"
)

os.exit(0)
