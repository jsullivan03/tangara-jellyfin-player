package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
local backstack =
    require("firmware_backstack")

lvgl.ImgData = function(path)
    return path
end

require("mocks").install(lvgl)
package.loaded["backstack"] = backstack
package.preload["backstack"] =
    function()
        return backstack
    end

local requests = {}
local artist_payload = {
    resolution = "resolved",
    artist = {
        key =
            "aaaaaaaaaaaaaaaa" ..
            "aaaaaaaaaaaaaaaa",
        name = "Travis Scott",
    },
    groups = {
        {
            id = "albums",
            items = {
                {
                    jellyfin_id =
                        "jellyfin-astroworld",
                    kind = "album",
                    title = "ASTROWORLD",
                    artist = "Travis Scott",
                    artists = {
                        "Travis Scott",
                    },
                    jellyfin_artist_id =
                        "jellyfin-travis",
                    track_count = 17,
                    artwork_path =
                        "/devices/device-1/items/" ..
                        "jellyfin-astroworld/" ..
                        "artwork/thumbnail",
                    artwork_revision =
                        "jellyfin-astro-art",
                    artwork_source =
                        "jellyfin",
                    device = {
                        state = "partial",
                        total_tracks = 17,
                        downloaded_tracks = 5,
                    },
                },
                {
                    key =
                        "bbbbbbbbbbbbbbbb" ..
                        "bbbbbbbbbbbbbbbb",
                    kind = "album",
                    title = "JACKBOYS",
                    artist = "JACKBOYS",
                    artists = {
                        "JACKBOYS",
                        "Travis Scott",
                    },
                    artist_key =
                        "aaaaaaaaaaaaaaaa" ..
                        "aaaaaaaaaaaaaaaa",
                    artwork_path =
                        "/devices/device-1/" ..
                        "external/items/" ..
                        "bbbbbbbbbbbbbbbb" ..
                        "bbbbbbbbbbbbbbbb/" ..
                        "artwork",
                    artwork_revision =
                        "external-jackboys-art",
                    artwork_source =
                        "external",
                    availability =
                        "available",
                },
                {
                    key =
                        "cccccccccccccccc" ..
                        "cccccccccccccccc",
                    kind = "album",
                    title = "No Cover",
                    artist = "Travis Scott",
                    artist_key =
                        "aaaaaaaaaaaaaaaa" ..
                        "aaaaaaaaaaaaaaaa",
                    artwork_path = "",
                    artwork_revision = "",
                    availability =
                        "available",
                },
            },
        },
        {
            id = "singles",
            items = {
                {
                    key =
                        "dddddddddddddddd" ..
                        "dddddddddddddddd",
                    kind = "album",
                    title = "HIGHEST",
                    artist = "Travis Scott",
                    artist_key =
                        "aaaaaaaaaaaaaaaa" ..
                        "aaaaaaaaaaaaaaaa",
                    artwork_path = "",
                    availability =
                        "available",
                },
            },
        },
        {
            id = "features",
            items = {
                {
                    key =
                        "eeeeeeeeeeeeeeee" ..
                        "eeeeeeeeeeeeeeee",
                    kind = "album",
                    title = "Love Galore",
                    artist = "SZA",
                    artists = {
                        "SZA",
                        "Travis Scott",
                    },
                    artist_key =
                        "aaaaaaaaaaaaaaaa" ..
                        "aaaaaaaaaaaaaaaa",
                    artwork_path = "",
                    availability =
                        "available",
                },
            },
        },
    },
}

package.loaded["jellyfin_local_index"] = {
    load = function()
        return {
            tracks = {},
            albums = {
                {
                    id =
                        "jellyfin-astroworld",
                    track_count = 5,
                },
            },
        }
    end,
}

local function artwork_key(item)
    return table.concat(
        {
            tostring(
                item.jellyfin_id or
                item.key or ""
            ),
            tostring(
                item.artwork_revision or
                ""
            ),
            tostring(
                item.artwork_path or ""
            ),
        },
        ":"
    )
end

package.loaded["sync_artwork_cache"] = {
    key = artwork_key,
    request = function(item, callback)
        if type(item.artwork_path) ~=
                "string" or
            item.artwork_path == "" then
            return nil
        end
        requests[#requests + 1] = {
            item = item,
            key = artwork_key(item),
            callback = callback,
        }
        return nil
    end,
    poll = function()
        return nil
    end,
}

package.loaded["sync_catalog"] = {
    cached_key = function(key)
        if key ==
            "artist:" ..
            "aaaaaaaaaaaaaaaa" ..
            "aaaaaaaaaaaaaaaa" then
            return artist_payload
        end
        return nil
    end,
    cached = function()
        return nil
    end,
    busy = function()
        return false
    end,
    error = function()
        return nil
    end,
    artist_releases = function()
        return true
    end,
    queue = function()
        return true
    end,
    external_job = function()
        return true
    end,
    poll = function()
        return nil
    end,
}

package.loaded["jellyfin_sync_ui"] = nil
local sync_ui =
    require("jellyfin_sync_ui")

local artist =
    sync_ui.Artist:new {
        item = {
            jellyfin_id =
                "jellyfin-astroworld",
            external_item_key =
                "ffffffffffffffff" ..
                "ffffffffffffffff",
            artist_key =
                "aaaaaaaaaaaaaaaa" ..
                "aaaaaaaaaaaaaaaa",
            jellyfin_artist_id =
                "jellyfin-travis",
            kind = "album",
            title = "ASTROWORLD",
            artist = "Travis Scott",
        },
    }

backstack.reset(artist)
backstack.flush(8)

assert(
    artist.header_marquee.text ==
        "Travis Scott",
    "resolved discography did not use the exact artist title"
)

local rows = {}
for _, row in ipairs(artist.rows) do
    if row.catalog_item then
        rows[row.catalog_item.title] = row
    end
end

assert(rows["ASTROWORLD"])
assert(rows["JACKBOYS"])
assert(rows["HIGHEST"])
assert(rows["Love Galore"])
assert(not rows["LONG.LIVE.A$AP"])
assert(not rows["God Save the Animals"])
assert(
    rows["ASTROWORLD"].state ==
        "partial"
)
assert(
    rows["ASTROWORLD"].state_icon and
        rows["ASTROWORLD"]
            .state_icon.kind ==
            "server",
    "Partial discography release lost its server icon"
)
assert(
    rows["ASTROWORLD"].detail.text:
        find("Partial", 1, true),
    "Partial discography release lost its state text"
)
assert(
    #requests == 2,
    "discography did not lazily request the two available covers"
)
assert(
    requests[1].item.artwork_source ==
        "jellyfin" and
        requests[1].item.title ==
            "ASTROWORLD",
    "matched release did not prefer Jellyfin artwork"
)
assert(
    requests[2].item.artwork_source ==
        "external" and
        requests[2].item.title ==
            "JACKBOYS",
    "external-only release did not use the companion artwork proxy"
)
assert(
    rows["No Cover"].artwork
        .current_source ==
        "//lua/img/cover_placeholder.png",
    "missing discography artwork did not retain the placeholder"
)

requests[1].callback(
    "/desktop-sim/astroworld.png",
    requests[1].key
)
requests[2].callback(
    "/desktop-sim/jackboys.png",
    requests[2].key
)
assert(
    rows["ASTROWORLD"].artwork
        .current_source ==
        "/desktop-sim/astroworld.png",
    "Jellyfin discography art did not appear immediately"
)
assert(
    rows["JACKBOYS"].artwork
        .current_source ==
        "/desktop-sim/jackboys.png",
    "external discography art did not appear immediately"
)

local stale_row = rows["ASTROWORLD"]
local stale_source =
    stale_row.artwork.current_source
local stale_request = requests[1]
artist:render()
assert(not stale_row.artwork:is_valid())
stale_request.callback(
    "/desktop-sim/stale.png",
    stale_request.key
)
assert(
    stale_row.artwork.current_source ==
        stale_source,
    "destroyed discography row accepted stale artwork"
)

artist_payload = {
    resolution = "selection_required",
    artist = {
        name = "Travis Scott",
    },
    candidates = {
        {
            key =
                "1111111111111111" ..
                "1111111111111111",
            name = "Travis Scott",
        },
        {
            key =
                "2222222222222222" ..
                "2222222222222222",
            name = "Travis Scott",
        },
    },
    groups = {},
}
local picker =
    sync_ui.Artist:new {
        item = artist.item,
    }
backstack.reset(picker)
backstack.flush(4)
assert(
    picker.header_marquee.text ==
        "Select artist",
    "ambiguous artist identity did not show the picker page"
)
assert(#picker.rows == 2)
assert(
    picker.rows[1].marquees[1].text ==
        "Travis Scott" and
        picker.rows[2].marquees[1].text ==
        "Travis Scott"
)

print(
    "Sync artist discography identity, Partial state, and artwork passed"
)
os.exit(0)
