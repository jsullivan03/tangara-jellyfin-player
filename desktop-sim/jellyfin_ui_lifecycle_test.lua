package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")

lvgl.ImgData =
    function(path)
        return path
    end

local simulator =
    require("mocks").install(lvgl)

package.loaded["backstack"] =
    simulator.backstack

local root =
    "/tmp/tangara-ui-lifecycle"

os.execute("rm -rf " .. root)
os.execute("mkdir -p " .. root)

package.loaded["device"] = nil
package.preload["device"] =
    function()
        return {
            id =
                function()
                    return "lifecycle-test"
                end,
            storage_root =
                function()
                    return root
                end,
        }
    end

package.loaded["sync_config"] = {
    status =
        function()
            return {
                configured = true,
                started = true,
                connected = true,
                server_url =
                    "http://localhost",
            }
        end,
}

package.loaded["sync_runtime"] = {
    last_library_result =
        function()
            return {
                ok = true,
            }
        end,
    last_result =
        function()
            return {
                ok = true,
            }
        end,
}

local tracks = {
    {
        id = "track-a",
        jellyfin_id = "track-a",
        title = "Alpha Track",
        artist = "Artist A",
        album = "Album A",
        date_created =
            "2026-01-01T00:00:00Z",
    },
    {
        id = "track-b",
        jellyfin_id = "track-b",
        title = "Beta Track",
        artist = "Artist B",
        album = "Album B",
        date_created =
            "2026-03-01T00:00:00Z",
    },
    {
        id = "track-c",
        jellyfin_id = "track-c",
        title = "Gamma Track",
        artist = "Artist C",
        album = "Album C",
        date_created =
            "2026-02-01T00:00:00Z",
    },
}

local synced_library = {
    favorites = {
        name = "Favorites",
        track_count = #tracks,
        items = tracks,
    },
    playlists = {
        {
            id = "playlist-a",
            name = "Playlist A",
            track_count = #tracks,
            items = tracks,
            artwork = {
                cover =
                    "//lua/img/favorites_playlist.png",
            },
        },
    },
}

package.loaded["sync_library_view"] = {
    current =
        function()
            return synced_library
        end,
}

local albums = {
    {
        key = "album-a",
        id = "album-a",
        name = "Album A",
        artist = "Artist A",
        track_count = 1,
        tracks = {tracks[1]},
        date_created =
            "2026-01-01T00:00:00Z",
        artwork = {
            thumbnail =
                "//lua/img/favorites_playlist.png",
        },
    },
    {
        key = "album-b",
        id = "album-b",
        name = "Album B",
        artist = "Artist B",
        track_count = 1,
        tracks = {tracks[2]},
        date_created =
            "2026-03-01T00:00:00Z",
        artwork = {
            thumbnail =
                "//lua/img/favorites_playlist.png",
        },
    },
    {
        key = "album-c",
        id = "album-c",
        name = "Album C",
        artist = "Artist C",
        track_count = 1,
        tracks = {tracks[3]},
        date_created =
            "2026-02-01T00:00:00Z",
        artwork = {
            thumbnail =
                "//lua/img/favorites_playlist.png",
        },
    },
}

local artists = {
    {
        key = "artist-a",
        name = "Artist A",
        release_count = 1,
        track_count = 1,
        releases = {albums[1]},
        date_created =
            albums[1].date_created,
    },
    {
        key = "artist-b",
        name = "Artist B",
        release_count = 1,
        track_count = 1,
        releases = {albums[2]},
        date_created =
            albums[2].date_created,
    },
    {
        key = "artist-c",
        name = "Artist C",
        release_count = 1,
        track_count = 1,
        releases = {albums[3]},
        date_created =
            albums[3].date_created,
    },
}

local local_library = {
    artists = artists,
    albums = albums,
    tracks = tracks,
    counts = {
        artists = #artists,
        albums = #albums,
        tracks = #tracks,
    },
}

package.loaded["jellyfin_local_index"] = {
    load =
        function()
            return local_library
        end,
}

package.loaded["jellyfin_playback"] = {
    play =
        function()
            return true
        end,
    current =
        function()
            return nil
        end,
}

package.loaded["jellyfin_now_playing"] = {
    new =
        function()
            return {}
        end,
}

package.loaded["jellyfin_track_menu"] = {
    new =
        function()
            return {}
        end,
}

package.loaded["jellyfin_sort"] = nil
package.loaded["jellyfin_marquee"] = nil
package.loaded["jellyfin_list_ui"] = nil
package.loaded["jellyfin_library"] = nil
package.loaded["jellyfin_local_library"] = nil

local playlist_module =
    dofile(
        "lua/jellyfin_library.lua"
    )

package.loaded["jellyfin_library"] =
    playlist_module

local local_module =
    dofile(
        "lua/jellyfin_local_library.lua"
    )

package.loaded["jellyfin_local_library"] =
    local_module

local function row_objects(screen)
    local result = {}

    for index, row in ipairs(
        screen.media_rows or {}
    ) do
        result[index] =
            row.object
    end

    return result
end

local function assert_same_rows(
    screen,
    expected
)
    assert(
        #(screen.media_rows or {}) ==
            #expected
    )

    for index, object in ipairs(
        expected
    ) do
        assert(
            screen.media_rows[index]
                .object == object
        )
    end
end

local function exercise_sort_screen(
    screen,
    methods
)
    local identities =
        row_objects(screen)

    if screen.sort_row and
        screen.media_rows and
        screen.media_rows[1] then
        assert(
            screen.first_row ==
                screen.media_rows[1].object
        )
        assert(
            screen.first_row ~=
                screen.sort_row.object
        )
    end

    for iteration = 1, 12 do
        if type(screen.open_sort_menu) ==
                "function" then
            screen.open_sort_menu()

            for _, method in ipairs(
                methods
            ) do
                screen.sort_select(
                    method
                )
            end

            screen.close_sort_menu(false)
        else
            assert(
                screen.sort_row and
                type(screen.sort_row.on_click) ==
                    "function"
            )

            screen.sort_row.on_click()
        end

        assert_same_rows(
            screen,
            identities
        )
    end
end

simulator.backstack.reset(
    local_module.Root:new()
)

local playlist_root =
    playlist_module:new()

simulator.backstack.push(
    playlist_root
)

local first_artwork = nil

for _, row in ipairs(
    playlist_root.rows
) do
    if row.artwork then
        first_artwork = row.artwork
        break
    end
end

assert(
    first_artwork and
    (
        first_artwork.image or
        first_artwork.star
    )
)

simulator.backstack.pop()

for iteration = 1, 12 do
    local favorites =
        playlist_module.Collection:new {
            title = "Favorites",
            collection_kind =
                "favorites",
        }

    simulator.backstack.push(
        favorites
    )

    exercise_sort_screen(
        favorites,
        {
            "alpha",
            "recent",
        }
    )

    assert(
        favorites.media_rows[1]
            .artwork ~= nil
    )

    simulator.backstack.pop()

    local playlist =
        playlist_module.Collection:new {
            title = "Playlist A",
            collection_kind =
                "playlist",
            collection_id =
                "playlist-a",
        }

    simulator.backstack.push(
        playlist
    )

    exercise_sort_screen(
        playlist,
        {
            "recent",
            "alpha",
        }
    )

    assert(
        playlist.media_rows[1]
            .artwork ~= nil
    )

    simulator.backstack.pop()

    local album_screen =
        local_module.Albums:new()

    simulator.backstack.push(
        album_screen
    )

    exercise_sort_screen(
        album_screen,
        {
            "alpha",
            "recent",
        }
    )

    simulator.backstack.pop()

    local track_screen =
        local_module.Tracks:new()

    simulator.backstack.push(
        track_screen
    )

    exercise_sort_screen(
        track_screen,
        {
            "recent",
            "alpha",
        }
    )

    simulator.backstack.pop()

    local artist_screen =
        local_module.Artists:new()

    simulator.backstack.push(
        artist_screen
    )

    exercise_sort_screen(
        artist_screen,
        {
            "alpha",
        }
    )

    simulator.backstack.pop()

    local artist_detail =
        local_module.Artist:new {
            title = "Artist A",
            artist_key = "artist-a",
        }

    simulator.backstack.push(
        artist_detail
    )

    assert(
        artist_detail.sort_row == nil
    )
    assert(
        artist_detail.open_sort_menu ==
            nil
    )
    assert(
        artist_detail.media_rows and
        artist_detail.media_rows[1]
    )
    assert(
        artist_detail.first_row ==
            artist_detail.media_rows[1]
                .object
    )

    simulator.backstack.pop()
end

os.execute("rm -rf " .. root)

print(
    "Jellyfin UI repeated-open and sort lifecycle passed"
)

os.exit(0)
