local file = assert(
    io.open(
        "desktop-sim/jellyfin_library.lua",
        "rb"
    )
)
local source = file:read("*a")
file:close()

local playlist_start = assert(
    source:find(
        "local function cache_collection_artwork",
        1,
        true
    )
)
local playlist_end = assert(
    source:find(
        "cache_collection_artwork(\n    result.library.favorites",
        playlist_start + 1,
        true
    )
)
local playlist_source =
    source:sub(
        playlist_start,
        playlist_end - 1
    )

assert(
    playlist_source:find(
        "playlist_file_exists(destination)",
        1,
        true
    ) and
        playlist_source:find(
            "return true",
            1,
            true
        ),
    "Simulator playlist artwork does not reuse an existing cached file"
)

local track_start = assert(
    source:find(
        "local function cache_track_artwork",
        1,
        true
    )
)
local track_end = assert(
    source:find(
        "local function refreshed_active",
        track_start,
        true
    )
)
local track_source =
    source:sub(track_start, track_end - 1)

local guard_at = assert(
    track_source:find(
        "cached_artwork_by_track[track_id]",
        1,
        true
    )
)
local manifest_at = assert(
    track_source:find(
        "manifest_cache.load()",
        1,
        true
    )
)

assert(
    guard_at < manifest_at,
    "Simulator track artwork cache guard runs after the manifest is reloaded"
)

assert(
    track_source:find(
        "if manifest_changed then",
        1,
        true
    ) and
        track_source:find(
            "if cover_downloaded or",
            1,
            true
        ),
    "Simulator track artwork still saves or logs unchanged cached artwork"
)

assert(
    source:find(
        "-background-v3.png",
        1,
        true
    ) and
        source:find(
            "tangara_sim_cache_track_background",
            1,
            true
        ),
    "Simulator album backgrounds do not use the refreshed uniform-blur cache"
)

local server_file = assert(
    io.open(
        "server/tangara-sync/app.py",
        "rb"
    )
)
local server_source =
    server_file:read("*a")
server_file:close()

assert(
    server_source:find(
        "ImageFilter.GaussianBlur",
        1,
        true
    ) and
        server_source:find(
            "bleed = 24",
            1,
            true
        ) and
        server_source:find(
            "radius=16",
            1,
            true
        ) and
        not server_source:find(
            '"blur": "8"',
            1,
            true
        ),
    "Artwork server still delegates background blur to Jellyfin's vignetted renderer"
)

print(
    "Simulator artwork reuses cached files without repeated manifest saves or cache logs"
)
os.exit(0)
