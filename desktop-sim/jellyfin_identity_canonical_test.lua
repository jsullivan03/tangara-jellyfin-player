package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local artist =
    require("jellyfin_artist_identity")
local album =
    require("jellyfin_album_identity")
local track =
    require("jellyfin_track_identity")

-- Artists: numeric/string forms match.
assert(
    artist.stable_id(99) == "99" and
    artist.stable_id("99") == "99" and
    artist.key({artist_id = 99}) ==
        "id:99" and
    artist.key({artist_id = "99"}) ==
        "id:99" and
    artist.same(99, "99")
)

assert(
    artist.key({
        artist_id = "a1",
        artist = "Same",
    }) == "id:a1"
)
assert(
    artist.key({
        artist_id = "a2",
        artist = "Same",
    }) == "id:a2"
)
assert(
    not artist.same(
        {artist_id = "a1", artist = "Same"},
        {artist_id = "a2", artist = "Same"}
    ),
    "same name with different IDs stay distinct"
)

assert(
    artist.key({artist = "Only Name"}) ==
        "name:only name"
)
assert(
    artist.key({
        artist_key = "name:Travis Scott",
    }) == "name:travis scott",
    "legacy Sync name keys normalize"
)
assert(
    artist.key({
        artist_key = "bare-artist",
    }) == "id:bare-artist",
    "legacy bare artist ids become id:"
)

-- Albums: Sync / Local / placeholder / track share one key.
local album_id = "album-stable-1"
local sync_album = {
    kind = "album",
    jellyfin_id = album_id,
    title = "Around the Fur",
    artist = "Deftones",
}
local local_album = {
    key = "id:" .. album_id,
    id = album_id,
    name = "Around the Fur",
    artist = "Deftones",
}
local placeholder = {
    kind = "album",
    jellyfin_id = album_id,
    title = "Around the Fur",
    artist = "Deftones",
    pending_download = true,
}
local runtime_op = {
    jellyfin_id = album_id,
    album_id = album_id,
    kind = "album",
}
local sheet_item = {
    jellyfin_id = album_id,
    title = "Around the Fur",
}

local expected = "id:" .. album_id
assert(album.key(sync_album) == expected)
assert(album.key(local_album) == expected)
assert(album.key(placeholder) == expected)
assert(album.key(runtime_op) == expected)
assert(album.key(sheet_item) == expected)
assert(album.same(sync_album, local_album))
assert(
    album.stable_id(42) == "42" and
    album.stable_id("42") == "42" and
    album.key(42) == "id:42" and
    album.key("42") == "id:42"
)
assert(
    album.key({
        jellyfin_id = "one",
        title = "Shared Title",
        artist = "A",
    }) ~=
    album.key({
        jellyfin_id = "two",
        title = "Shared Title",
        artist = "A",
    })
)

local track_row = {
    kind = "track",
    jellyfin_id = "t1",
    album_id = album_id,
    album = "Around the Fur",
    artist = "Deftones",
    title = "My Own Summer",
}
assert(
    album.track_album_key(track_row) ==
        expected
)

assert(
    album.key({
        title = "No Id Album",
        artist = "Solo",
    }) == "album:solo|no id album"
)

-- Tracks
assert(
    track.stable_id(7) == "7" and
    track.stable_id("7") == "7" and
    track.key(7) == "id:7" and
    track.key("7") == "id:7" and
    track.same(7, "7")
)

local sync_track = {
    kind = "track",
    jellyfin_id = "track-1",
    album_id = album_id,
    title = "Song",
}
local local_track = {
    id = "track-1",
    jellyfin_id = "track-1",
    track_key = "id:track-1",
    album_id = album_id,
}
local queue_track = {
    id = "track-1",
    title = "Song",
}
local playback_track = {
    jellyfin_id = "track-1",
}

assert(track.key(sync_track) == "id:track-1")
assert(track.key(local_track) == "id:track-1")
assert(track.key(queue_track) == "id:track-1")
assert(track.key(playback_track) == "id:track-1")
assert(
    track.same(sync_track, local_track) and
    track.same(queue_track, playback_track)
)

assert(
    track.key({
        title = "Same Title",
        album_id = "album-a",
        album = "A",
        artist = "X",
    }) ~=
    track.key({
        title = "Same Title",
        album_id = "album-b",
        album = "B",
        artist = "X",
    }) or
    track.key({
        title = "Same Title",
        album_id = "album-a",
    }) == "id:" -- unreachable if ids exist
)

-- Same title, no track ids, different albums → distinct fallback keys.
local fallback_a = track.key({
    title = "Same Title",
    album = "Album A",
    artist = "X",
    disc = 1,
    track = 1,
})
local fallback_b = track.key({
    title = "Same Title",
    album = "Album B",
    artist = "X",
    disc = 1,
    track = 1,
})
assert(
    fallback_a ~= fallback_b and
    fallback_a:sub(1, 6) == "track:" and
    fallback_b:sub(1, 6) == "track:"
)

print("jellyfin_identity_canonical_test ok")
os.exit(0)
