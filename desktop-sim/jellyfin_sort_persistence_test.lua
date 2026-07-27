package.path =
    "lua/?.lua;" ..
    package.path

local root =
    "/tmp/tangara-sort-persistence"

os.execute("rm -rf " .. root)
os.execute("mkdir -p " .. root)

package.loaded["device"] = nil
package.preload["device"] =
    function()
        return {
            storage_root =
                function()
                    return root
                end,
        }
    end

package.loaded["jellyfin_sort"] = nil

local sort =
    require("jellyfin_sort")

sort.reset_for_test()

assert(
    sort.label(
        "artists",
        "artists"
    ) == "A-Z"
)
assert(
    sort.label(
        "albums",
        "albums"
    ) == "NEW"
)
assert(
    sort.label(
        "tracks",
        "tracks"
    ) == "NEW"
)
assert(
    sort.label(
        "favorites",
        "tracks"
    ) == "NEW"
)

sort.select(
    "albums",
    "alpha",
    "albums"
)
sort.select(
    "albums",
    "alpha",
    "albums"
)
sort.select(
    "tracks",
    "recent",
    "tracks"
)
sort.select(
    "favorites",
    "alpha",
    "tracks"
)
sort.select(
    "playlist:test",
    "recent",
    "tracks"
)
sort.select(
    "artist:test",
    "alpha",
    "albums"
)

assert(
    sort.label(
        "albums",
        "albums"
    ) == "Z-A"
)
assert(
    sort.label(
        "tracks",
        "tracks"
    ) == "OLD"
)
assert(
    sort.label(
        "favorites",
        "tracks"
    ) == "A-Z"
)
assert(
    sort.label(
        "playlist:test",
        "tracks"
    ) == "OLD"
)
assert(
    sort.label(
        "artist:test",
        "albums"
    ) == "A-Z"
)

package.loaded["jellyfin_sort"] = nil

sort = require("jellyfin_sort")

assert(
    sort.label(
        "albums",
        "albums"
    ) == "Z-A"
)
assert(
    sort.label(
        "tracks",
        "tracks"
    ) == "OLD"
)
assert(
    sort.label(
        "favorites",
        "tracks"
    ) == "A-Z"
)
assert(
    sort.label(
        "playlist:test",
        "tracks"
    ) == "OLD"
)
assert(
    sort.label(
        "artist:test",
        "albums"
    ) == "A-Z"
)

os.execute("rm -rf " .. root)

print(
    "Jellyfin per-screen sort persistence passed"
)

os.exit(0)
