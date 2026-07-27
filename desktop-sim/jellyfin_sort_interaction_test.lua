package.path =
    "lua/?.lua;" ..
    package.path

local sort =
    require("jellyfin_sort")

sort.reset_for_test()

local album_state =
    sort.current(
        "albums",
        "albums"
    )

assert(album_state.method == "recent")
assert(album_state.label == "NEW")

album_state =
    assert(
        sort.choose(
            "albums",
            "alpha",
            "albums"
        )
    )

assert(album_state.method == "alpha")
assert(album_state.label == "A-Z")

album_state =
    assert(
        sort.toggle(
            "albums",
            "alpha",
            "albums"
        )
    )

assert(album_state.method == "alpha")
assert(album_state.label == "Z-A")

album_state =
    assert(
        sort.choose(
            "albums",
            "recent",
            "albums"
        )
    )

assert(album_state.method == "recent")
assert(album_state.label == "NEW")
assert(
    sort.order_label(
        "albums",
        "alpha",
        "albums"
    ) == "Z-A"
)

album_state =
    assert(
        sort.toggle(
            "albums",
            "recent",
            "albums"
        )
    )

assert(album_state.method == "recent")
assert(album_state.label == "OLD")
assert(
    sort.order_label(
        "albums",
        "alpha",
        "albums"
    ) == "Z-A"
)
assert(
    sort.order_label(
        "albums",
        "recent",
        "albums"
    ) == "OLD"
)

album_state =
    assert(
        sort.choose(
            "albums",
            "alpha",
            "albums"
        )
    )

assert(album_state.label == "Z-A")

local artist_state =
    assert(
        sort.toggle(
            "artists",
            "alpha",
            "artists"
        )
    )

assert(artist_state.method == "alpha")
assert(artist_state.label == "Z-A")

print(
    "Jellyfin highlight, toggle, and artist sorting passed"
)

os.exit(0)
