package.path =
    "lua/?.lua;" ..
    package.path

local sort =
    require("jellyfin_sort")

sort.reset_for_test()

local artists = {
    {
        name = "Beta",
        date_created =
            "2026-01-01T00:00:00Z",
    },
    {
        name = "Alpha",
        date_created =
            "2026-02-01T00:00:00Z",
    },
}

local albums = {
    {
        name = "Older",
        artist = "Artist",
        date_created =
            "2026-01-01T00:00:00Z",
    },
    {
        name = "Newer",
        artist = "Artist",
        date_created =
            "2026-02-01T00:00:00Z",
    },
}

local artist_result =
    sort.sort(
        "artists",
        artists,
        "artists"
    )

assert(
    artist_result[1].name ==
        "Alpha"
)
assert(
    sort.label(
        "artists",
        "artists"
    ) == "A-Z"
)

sort.select(
    "artists",
    "alpha",
    "artists"
)

artist_result =
    sort.sort(
        "artists",
        artists,
        "artists"
    )

assert(
    artist_result[1].name ==
        "Beta"
)
assert(
    sort.label(
        "artists",
        "artists"
    ) == "Z-A"
)

local album_result =
    sort.sort(
        "albums",
        albums,
        "albums"
    )

assert(
    album_result[1].name ==
        "Newer"
)
assert(
    sort.label(
        "albums",
        "albums"
    ) == "NEW"
)

sort.select(
    "albums",
    "recent",
    "albums"
)

album_result =
    sort.sort(
        "albums",
        albums,
        "albums"
    )

assert(
    album_result[1].name ==
        "Older"
)
assert(
    sort.label(
        "albums",
        "albums"
    ) == "OLD"
)

sort.select(
    "albums",
    "alpha",
    "albums"
)

album_result =
    sort.sort(
        "albums",
        albums,
        "albums"
    )

assert(
    album_result[1].name ==
        "Newer"
)
assert(
    sort.label(
        "albums",
        "albums"
    ) == "A-Z"
)

sort.ensure(
    "artists",
    "artists",
    {"alpha"}
)

assert(
    sort.current(
        "artists",
        "artists"
    ).method == "alpha"
)

print(
    "Jellyfin sort defaults and modes passed"
)

os.exit(0)
