package.path =
    "desktop-sim/?.lua;lua/?.lua;" ..
    package.path

local json = require("json")
local root =
    "desktop-sim/sd/jellyfin-library-ui"
local manifest_file = assert(io.open(
    root .. "/.tangara_sync_manifest.json",
    "rb"
))
local manifest = json.decode(
    manifest_file:read("*a")
)
manifest_file:close()

local track_id =
    "ce1c15cfac374bfa95508510ec994096"
local item

for _, candidate in ipairs(manifest.items) do
    if (candidate.jellyfin_id or
            candidate.id) == track_id then
        item = candidate
        break
    end
end

assert(item, "Star Wars Samba is absent from the real manifest")

local cache =
    require("local_artwork_cache")
        .new(root)
local track = {
    id = track_id,
    album_id = item.album_id,
    artwork = {
        -- A stale per-track miss must not override valid parent-album files.
        thumbnail =
            "/sim-artwork/missing-track-cover.png",
    },
}
local first = assert(cache.resolve(item, track))

assert(first.thumbnail:match("%-sq28%.png$"))
assert(first.cover:match("%-sq66%.png$"))
assert(first.background:match("%-bg160x128%-v3%.png$"))
assert(first.cache_key:find("|28x28|", 1, true))
assert(first.cache_key:find("|66x66|", 1, true))
assert(first.cache_key:find("|160x128", 1, true))

for _, path in pairs(first.full_paths) do
    local file = assert(io.open(path, "rb"))
    assert(file:seek("end") > 0)
    file:close()
end

-- Favorites, playlists, albums, Tracks, and Now Playing all resolve the same
-- album identity. A different sibling track ID must not cause another disk
-- derivative or network operation.
for index = 1, 5 do
    local sibling = assert(cache.resolve(
        item,
        {
            id = "sibling-" .. index,
            album_id = item.album_id,
            artwork = {},
        }
    ))
    assert(sibling.cache_key == first.cache_key)
    assert(sibling.thumbnail == first.thumbnail)
    assert(sibling.cover == first.cover)
end

assert(cache.trace.disk_hits == 1)
assert(cache.trace.memory_hits == 5)
assert(cache.trace.network_requests == 0)
assert(cache.trace.generated == 0)
assert(cache.trace.last.network == false)
assert(cache.trace.last.generated == false)

local source_file = assert(io.open(
    "desktop-sim/jellyfin_library.lua",
    "rb"
))
local source = source_file:read("*a")
source_file:close()

local cache_start = assert(source:find(
    "local function cache_track_artwork",
    1,
    true
))
local cache_end = assert(source:find(
    "local function refreshed_active",
    cache_start,
    true
))
local cache_source = source:sub(cache_start, cache_end - 1)

assert(not cache_source:find("curl", 1, true))
assert(not cache_source:find("/artwork/", 1, true))
assert(not cache_source:find("Artwork cached", 1, true))

print(
    "Local artwork reused real 28x28, 66x66, and 160x128 " ..
    "album files across six surfaces with zero network/generation"
)
os.exit(0)
