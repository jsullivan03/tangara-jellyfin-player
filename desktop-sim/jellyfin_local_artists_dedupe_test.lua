package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local root =
    "/tmp/tangara-local-artists-dedupe"

os.execute("rm -rf " .. root)
os.execute("mkdir -p " .. root .. "/music")

local function create_file(path)
    local full = root .. path
    local directory =
        full:match("^(.*)/[^/]+$")

    os.execute("mkdir -p " .. directory)

    local file =
        assert(io.open(full, "wb"))
    file:write("test")
    file:close()
end

for index = 1, 20 do
    create_file(
        "/music/track-" ..
            tostring(index) ..
            ".flac"
    )
end

package.preload["device"] = function()
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
                return nil, "unused"
            end,
        }
    end

package.loaded["jellyfin_local_index"] = nil
package.loaded["jellyfin_artist_identity"] = nil
package.loaded["jellyfin_local_index_generation"] = nil

local index =
    require("jellyfin_local_index")
local artist_identity =
    require("jellyfin_artist_identity")

local function artist_names(library)
    local names = {}

    for _, artist in ipairs(
        library.artists or {}
    ) do
        names[#names + 1] =
            tostring(artist.name) ..
            "@" ..
            tostring(artist.key)
    end

    table.sort(names)
    return names
end

local function count_name(library, name)
    local count = 0

    for _, artist in ipairs(
        library.artists or {}
    ) do
        if artist.name == name then
            count = count + 1
        end
    end

    return count
end

local function find_artist(library, name)
    for _, artist in ipairs(
        library.artists or {}
    ) do
        if artist.name == name then
            return artist
        end
    end

    return nil
end

local function release_names(artist)
    local names = {}

    for _, album in ipairs(
        artist.releases or {}
    ) do
        names[#names + 1] = album.name
    end

    table.sort(names)
    return names
end

-- Many albums / tracks from one artist → one row.
local one_artist_manifest = {
    items = {},
}

for index = 1, 8 do
    one_artist_manifest.items[index] = {
        jellyfin_id =
            "same-artist-track-" ..
            tostring(index),
        title = "Track " .. tostring(index),
        artist = "Travis Scott",
        artist_id =
            "b3288d0a7a58af0d1296a8157602c83d",
        album =
            index <= 4 and
            "ASTROWORLD" or
            "Birds In The Trap Sing McKnight",
        album_id =
            index <= 4 and
            "album-astro" or
            "album-birds",
        local_path =
            "/music/track-" ..
            tostring(index) ..
            ".flac",
        sync_state = "ready",
        track_number = index,
    }
end

local library =
    assert(
        index.from_manifest(
            one_artist_manifest,
            root
        )
    )

assert(
    library.counts.artists == 1,
    "many albums/tracks from one artist must produce one artist row"
)
assert(
    count_name(library, "Travis Scott") == 1
)
assert(
    find_artist(library, "Travis Scott")
        .release_count == 2
)

-- Album inventory plus track inventory must not duplicate via per-track keys.
-- Outlier track artist_id on a shared album must not create a second artist.
one_artist_manifest.items[9] = {
    jellyfin_id = "pickup",
    title = "pick up the phone",
    artist = "Travis Scott",
    artist_id =
        "24a4dd5d666b3bebcff44e14f4d2aed7",
    album = "Birds In The Trap Sing McKnight",
    album_id = "album-birds",
    local_path = "/music/track-9.flac",
    sync_state = "ready",
    track_number = 9,
}

library =
    assert(
        index.from_manifest(
            one_artist_manifest,
            root
        )
    )

assert(
    count_name(library, "Travis Scott") == 1,
    "outlier track artist_id on a shared album must not duplicate the album artist"
)
assert(
    find_artist(library, "Travis Scott").key ==
        "id:b3288d0a7a58af0d1296a8157602c83d"
)

-- Missing artist_id name-fallback + stable-ID tracks for same display name.
local xxx_manifest = {
    items = {
        {
            jellyfin_id = "xxx-1",
            title = "Ayala (Outro)",
            artist = "Xxxtentacion",
            artist_id =
                "3688ed5e83f0cdd61888b4e9d10430e6",
            album = "17",
            album_id = "album-17",
            local_path = "/music/track-10.flac",
            sync_state = "ready",
        },
        {
            jellyfin_id = "xxx-2",
            title = "Carry On",
            artist = "Xxxtentacion",
            artist_id =
                "3688ed5e83f0cdd61888b4e9d10430e6",
            album = "17",
            album_id = "album-17",
            local_path = "/music/track-11.flac",
            sync_state = "ready",
        },
        {
            jellyfin_id = "xxx-3",
            title = "infinity (888)",
            artist = "Xxxtentacion",
            album = "?",
            album_id = "album-question",
            local_path = "/music/track-12.flac",
            sync_state = "ready",
        },
        {
            jellyfin_id = "xxx-4",
            title = "A GHETTO CHRISTMAS CAROL",
            artist = "Xxxtentacion",
            album = "A GHETTO CHRISTMAS CAROL",
            album_id = "album-ghetto",
            local_path = "/music/track-13.flac",
            sync_state = "ready",
        },
    },
}

library =
    assert(
        index.from_manifest(
            xxx_manifest,
            root
        )
    )

assert(
    count_name(library, "Xxxtentacion") == 1,
    "name-fallback albums must coalesce into the stable-ID artist"
)

local xxx =
    assert(
        find_artist(library, "Xxxtentacion")
    )

assert(
    xxx.key ==
        "id:3688ed5e83f0cdd61888b4e9d10430e6"
)
assert(
    xxx.release_count == 3,
    "discography must keep every unique Xxx album once"
)

local xxx_releases =
    release_names(xxx)

assert(
    xxx_releases[1] ==
        "17" and
    xxx_releases[2] ==
        "?" and
    xxx_releases[3] ==
        "A GHETTO CHRISTMAS CAROL"
)

-- Numeric and string forms of one ID deduplicate.
local numeric_manifest = {
    items = {
        {
            jellyfin_id = "num-1",
            title = "One",
            artist = "Numeric Artist",
            artist_id = 12345,
            album = "Album One",
            album_id = "album-num-1",
            local_path = "/music/track-14.flac",
            sync_state = "ready",
        },
        {
            jellyfin_id = "num-2",
            title = "Two",
            artist = "Numeric Artist",
            artist_id = "12345",
            album = "Album Two",
            album_id = "album-num-2",
            local_path = "/music/track-15.flac",
            sync_state = "ready",
        },
    },
}

library =
    assert(
        index.from_manifest(
            numeric_manifest,
            root
        )
    )

assert(
    library.counts.artists == 1,
    "numeric and string artist IDs must dedupe"
)
assert(
    find_artist(library, "Numeric Artist")
        .key == "id:12345"
)

-- Same display name, different stable IDs, separate albums → two artists.
local same_name_manifest = {
    items = {
        {
            jellyfin_id = "sn-1",
            title = "Left Track",
            artist = "Jordan",
            artist_id = "artist-left",
            album = "Left Album",
            album_id = "album-left",
            local_path = "/music/track-16.flac",
            sync_state = "ready",
        },
        {
            jellyfin_id = "sn-2",
            title = "Right Track",
            artist = "Jordan",
            artist_id = "artist-right",
            album = "Right Album",
            album_id = "album-right",
            local_path = "/music/track-17.flac",
            sync_state = "ready",
        },
    },
}

library =
    assert(
        index.from_manifest(
            same_name_manifest,
            root
        )
    )

assert(
    count_name(library, "Jordan") == 2,
    "same display name with different stable IDs must remain two artists"
)

local jordan_keys = {}

for _, artist in ipairs(library.artists) do
    if artist.name == "Jordan" then
        jordan_keys[artist.key] = true
        assert(artist.release_count == 1)
    end
end

assert(
    jordan_keys["id:artist-left"] and
    jordan_keys["id:artist-right"]
)

-- Placeholder-style incomplete metadata plus completed stable-ID entry.
local placeholder_manifest = {
    items = {
        {
            jellyfin_id = "ph-1",
            title = "Pending Song",
            artist = "Placeholder Artist",
            album = "Pending Album",
            album_id = "album-pending",
            local_path = "/music/track-18.flac",
            sync_state = "ready",
        },
        {
            jellyfin_id = "ph-2",
            title = "Ready Song",
            artist = "Placeholder Artist",
            artist_id = "artist-placeholder",
            album = "Ready Album",
            album_id = "album-ready",
            local_path = "/music/track-19.flac",
            sync_state = "ready",
        },
    },
}

library =
    assert(
        index.from_manifest(
            placeholder_manifest,
            root
        )
    )

assert(
    count_name(
        library,
        "Placeholder Artist"
    ) == 1,
    "placeholder/name-fallback plus completed ID must not duplicate"
)
assert(
    find_artist(
        library,
        "Placeholder Artist"
    ).release_count == 2
)

-- Repeated builds are idempotent.
local first_names =
    table.concat(artist_names(library), ",")
local second =
    assert(
        index.from_manifest(
            placeholder_manifest,
            root
        )
    )

assert(
    table.concat(
        artist_names(second),
        ","
    ) == first_names and
    second.counts.artists ==
        library.counts.artists,
    "repeated from_manifest builds must be idempotent"
)

-- Canonical key helpers.
local key, stable =
    artist_identity.canonical_key(
        {
            artist_id = 99,
            artist = "Number",
        }
    )

assert(key == "id:99" and stable == "99")

key, stable =
    artist_identity.canonical_key(
        {
            artist = "Only Name",
        }
    )

assert(
    key == "name:only name" and
    stable == nil
)

print(
    "Local Artists dedupe model tests passed"
)
os.exit(0)
