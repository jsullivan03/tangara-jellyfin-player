package.path =
    "lua/?.lua;" ..
    package.path

local root =
    "/tmp/tangara-local-index-cache-test"

os.execute("rm -rf " .. root)
os.execute("mkdir -p " .. root .. "/music")

local function create_file(name)
    local file =
        assert(
            io.open(
                root .. "/music/" .. name,
                "wb"
            )
        )

    file:write("test")
    file:close()
end

create_file("one.flac")
create_file("two.flac")

local manifest = {
    items = {
        {
            jellyfin_id = "one",
            title = "One",
            artist = "Artist",
            album = "Album",
            album_id = "album",
            local_path =
                "/music/one.flac",
            sync_state = "ready",
        },
        {
            jellyfin_id = "two",
            title = "Two",
            artist = "Artist",
            album = "Album",
            album_id = "album",
            local_path =
                "/music/two.flac",
            sync_state = "ready",
        },
    },
}

local manifest_loads = 0

package.preload["device"] =
    function()
        return {
            storage_root = function()
                return root
            end,
        }
    end

package.preload["sync_manifest_cache"] =
    function()
        return {
            load = function()
                manifest_loads =
                    manifest_loads + 1

                return manifest
            end,
        }
    end

local index =
    require("jellyfin_local_index")

local first, first_error =
    index.load()

assert(first, first_error)
assert(first.counts.tracks == 2)
assert(manifest_loads == 1)

local after_first =
    index.cache_stats()

assert(after_first.builds == 1)
assert(after_first.hits == 0)
assert(after_first.file_checks == 2)
assert(after_first.cached == true)

local second, second_error =
    index.load()

assert(second, second_error)
assert(second == first)
assert(manifest_loads == 1)

local after_second =
    index.cache_stats()

assert(after_second.builds == 1)
assert(after_second.hits == 1)
assert(after_second.file_checks == 2)

create_file("three.flac")

table.insert(
    manifest.items,
    {
        jellyfin_id = "three",
        title = "Three",
        artist = "Artist",
        album = "Album",
        album_id = "album",
        local_path =
            "/music/three.flac",
        sync_state = "ready",
    }
)

local still_cached =
    assert(index.load())

assert(still_cached == first)
assert(still_cached.counts.tracks == 2)
assert(manifest_loads == 1)

index.invalidate(
    "cache test manifest changed"
)

local rebuilt, rebuilt_error =
    index.load()

assert(rebuilt, rebuilt_error)
assert(rebuilt ~= first)
assert(rebuilt.counts.tracks == 3)
assert(manifest_loads == 2)

local after_rebuild =
    index.cache_stats()

assert(after_rebuild.builds == 2)
assert(after_rebuild.hits == 2)
assert(after_rebuild.file_checks == 5)
assert(
    after_rebuild.last_invalidation ==
        "cache test manifest changed"
)

print(
    "Local library index cache passed"
)

os.execute("rm -rf " .. root)
os.exit(0)
