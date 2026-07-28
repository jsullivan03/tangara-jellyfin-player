package.path =
    "lua/?.lua;" ..
    package.path

local actions =
    require("jellyfin_track_actions")

local calls = {}

local function handler(name)
    return function()
        table.insert(calls, name)
    end
end

assert(
    actions.favorite_state(
        {
            favorites = {
                items = {
                    {id = "track-2"},
                },
            },
        },
        "track-2"
    ) == true,
    "favorite_state did not find a favorite track"
)

assert(
    actions.favorite_state(nil, "track-2") ==
        false,
    "favorite_state should tolerate a missing library"
)

local main = actions.main {
    track = {
        id = "track-2",
        artist_key = "id:artist-2",
    },
    context = {
        collection_kind = "playlist",
    },
    favorite = true,
    handlers = {
        open_artist = handler("artist"),
        toggle_favorite = handler("favorite"),
        show_playlists = handler("playlist"),
        remove_from_playlist = handler("remove"),
    },
}

assert(
    #main == 4,
    "playlist track should expose four current actions"
)

local expected = {
    {"artist", "Go to artist"},
    {"favorite", "Remove favorite"},
    {"add_to_playlist", "Add to playlist"},
    {
        "remove_from_playlist",
        "Remove from playlist",
    },
}

for index, value in ipairs(expected) do
    assert(
        main[index].id == value[1] and
            main[index].label == value[2],
        "track action order or label is incorrect at index " ..
            tostring(index)
    )

    main[index].activate()
end

assert(
    table.concat(calls, ",") ==
        "artist,favorite,playlist,remove",
    "track action callbacks were not preserved"
)

local without_artist = actions.main {
    track = {
        id = "track-3",
    },
    context = {},
    favorite = false,
    handlers = {
        open_artist = handler("unused"),
        toggle_favorite = handler("favorite-2"),
        show_playlists = handler("playlist-2"),
        remove_from_playlist = handler("unused-remove"),
    },
}

assert(
    #without_artist == 2 and
        without_artist[1].id == "favorite" and
        without_artist[1].label ==
            "Add favorite" and
        without_artist[2].id ==
            "add_to_playlist",
    "track actions did not hide unavailable contextual options"
)


local fallback_artist
local playlist_from_manifest = actions.main {
    track = {
        id = "track-4",
        artist = "Manifest Artist",
    },
    item = {
        artist_id = "artist-4",
    },
    context = {
        collection_kind = "playlist",
    },
    favorite = false,
    handlers = {
        open_artist = function(target)
            fallback_artist = target
        end,
        toggle_favorite = handler("favorite-4"),
        show_playlists = handler("playlist-4"),
        remove_from_playlist = handler("remove-4"),
    },
}

assert(
    #playlist_from_manifest == 4 and
        playlist_from_manifest[1].id ==
            "artist",
    "playlist action did not resolve its artist from downloaded manifest metadata"
)

playlist_from_manifest[1].activate()

assert(
    fallback_artist and
        fallback_artist.key ==
            "id:artist-4" and
        fallback_artist.name ==
            "Manifest Artist",
    "resolved playlist artist target was incorrect"
)

print(
    "Track actions build reusable contextual menus with stable ordering"
)
os.exit(0)
