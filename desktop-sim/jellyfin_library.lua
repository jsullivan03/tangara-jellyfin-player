if _G.jellyfin_library_ui_started then
    return
end

_G.jellyfin_library_ui_started = true

package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

function tangara_sim_back()
    local navigation =
        require("jellyfin_navigation")

    navigation.back()
end

local lvgl = require("lvgl")

lvgl.ImgData = function(path)
    return path
end

local network =
    dofile("desktop-sim/network.lua")

local server_url =
    os.getenv("TANGARA_SIM_SERVER_URL")

local device_id =
    os.getenv("TANGARA_SIM_DEVICE_ID")
    or "tangara-sim-001"

if type(server_url) ~= "string" or
    server_url == "" then
    error(
        "TANGARA_SIM_SERVER_URL is required"
    )
end

local root =
    "desktop-sim/sd/jellyfin-library-ui"

os.execute("mkdir -p " .. root)

_G.tangara_sim_enable_encoder_handler = true

local simulator =
    require("mocks").install(lvgl)

package.loaded["backstack"] =
    simulator.backstack

package.loaded["http"] = nil
package.preload["http"] = function()
    return network.http
end

package.loaded["device"] = nil
package.preload["device"] = function()
    return {
        id = function()
            return device_id
        end,
        storage_root = function()
            return root
        end,
    }
end

package.loaded["sync_config"] = nil
package.preload["sync_config"] = function()
    return {
        load = function()
            return {
                ssid = "desktop-sim",
                password = "",
                server_url = server_url,
            }
        end,
        valid = function(config)
            if type(config.server_url)
                ~= "string" or
                config.server_url == "" then
                return false,
                    "sync server URL is required"
            end

            return true
        end,
        save = function()
            return true
        end,
        reload_wifi = function()
            return true
        end,
        status = function()
            return {
                configured = true,
                started = true,
                connected = false,
                ssid = "desktop-sim",
                server_url = server_url,
            }
        end,
    }
end

local function ticks()
    local process =
        assert(io.popen("date +%s%3N"))

    local value =
        tonumber((process:read("*l")))

    process:close()

    return assert(value)
end

local refresh =
    require("sync_library_refresh")

local started, start_error =
    refresh.start()

assert(started, start_error)

local deadline = ticks() + 120000
local result = nil

while ticks() < deadline do
    result = refresh.poll()

    if result then
        break
    end

    os.execute("sleep 0.05")
end

assert(result, "library refresh timed out")
assert(result.ok, result.error)

local function playlist_shell_quote(value)
    return "'" ..
        tostring(value):gsub(
            "'",
            "'\\''"
        ) ..
        "'"
end

local function playlist_encode_segment(value)
    return (
        tostring(value):gsub(
            "([^A-Za-z0-9._~-])",
            function(character)
                return string.format(
                    "%%%02X",
                    string.byte(character)
                )
            end
        )
    )
end

local function playlist_command_ok(command)
    local ok, reason, code =
        os.execute(command)

    return ok == true or
        ok == 0 or
        (
            reason == "exit" and
            code == 0
        )
end

local function playlist_file_exists(path)
    local file = io.open(path, "rb")

    if not file then
        return false
    end

    file:close()
    return true
end

local playlist_artwork_root =
    root .. "/sim-playlist-artwork"

os.execute(
    "mkdir -p " ..
    playlist_shell_quote(
        playlist_artwork_root
    )
)

local function cache_collection_artwork(
    collection,
    name
)
    local item_id =
        collection.artwork_item_id

    if type(item_id) ~= "string" or
        item_id == "" then
        return false
    end

    local stem =
        tostring(name):gsub(
            "[^A-Za-z0-9._-]",
            "_"
        )

    local destination =
        playlist_artwork_root ..
        "/" ..
        stem ..
        ".png"

    if playlist_file_exists(destination) then
        collection.artwork = {
            cover =
                "/" .. destination,
        }

        return true
    end

    local temporary =
        destination .. ".part"

    local url =
        server_url ..
        "/devices/" ..
        playlist_encode_segment(
            device_id
        ) ..
        "/items/" ..
        playlist_encode_segment(
            item_id
        ) ..
        "/artwork/thumbnail"

    os.remove(temporary)

    local command =
        "curl -fsSL " ..
        "--connect-timeout 10 " ..
        "--max-time 60 " ..
        "-o " ..
        playlist_shell_quote(
            temporary
        ) ..
        " " ..
        playlist_shell_quote(url) ..
        " && mv " ..
        playlist_shell_quote(
            temporary
        ) ..
        " " ..
        playlist_shell_quote(
            destination
        )

    if not playlist_command_ok(
        command
    ) then
        os.remove(temporary)
        return false
    end

    collection.artwork = {
        cover =
            "/" .. destination,
    }

    print(
        "Playlist artwork cached for: " ..
        tostring(
            collection.name or name
        )
    )

    return true
end

cache_collection_artwork(
    result.library.favorites,
    "favorites"
)

for _, playlist in ipairs(
    result.library.playlists or {}
) do
    cache_collection_artwork(
        playlist,
        playlist.id
    )
end

local sync_library_cache =
    require("sync_library_cache")

assert(
    sync_library_cache.save(
        result.library
    )
)

local json_encode =
    require("json_encode")
local manifest_cache =
    require("sync_manifest_cache")
local manifest = {
    device = {
        id = device_id,
    },
    items = {},
}
local seen = {}
local counter = 0

local function add_track(track)
    if seen[track.id] then
        return
    end

    seen[track.id] = true
    counter = counter + 1

    local local_path =
        "/sim-media/" ..
        tostring(counter) ..
        ".flac"

    os.execute(
        "mkdir -p " ..
        root ..
        "/sim-media"
    )

    local file =
        assert(
            io.open(
                root .. local_path,
                "wb"
            )
        )

    file:write("simulator")
    file:close()

    local artwork_key

    if type(track.album_id) == "string" and
        track.album_id ~= "" then
        artwork_key = track.album_id
    else
        artwork_key =
            tostring(track.artist or "") ..
            "-" ..
            tostring(track.album or "")
    end

    artwork_key = artwork_key:gsub(
        "[^A-Za-z0-9._-]",
        "_"
    )

    if artwork_key == "" then
        artwork_key = tostring(track.id):gsub(
            "[^A-Za-z0-9._-]",
            "_"
        )
    end

    local thumbnail =
        "/.tangara-artwork/albums/" ..
        artwork_key ..
        ".png"

    table.insert(
        manifest.items,
        {
            id = track.id,
            jellyfin_id = track.id,
            title = track.title,
            artist = track.artist,
            album = track.album,
            duration =
                track.duration or 240,
            date_created =
                track.date_created or "",
            album_id =
                track.album_id or "",
            artist_id =
                track.artist_id or "",
            track_number =
                track.track_number or
                track.index_number or 0,
            disc_number =
                track.disc_number or
                track.parent_index_number or 0,
            local_path = local_path,
            sync_state = "ready",
            pinned = true,
            artwork = {
                thumbnail = thumbnail,
                thumbnail_item_id = track.id,
                cover =
                    "//lua/img/cover_placeholder.png",
                background =
                    "//lua/img/background_placeholder.png",
            },
        }
    )
end

for _, track in ipairs(
    result.library.favorites.items or {}
) do
    add_track(track)
end

for _, playlist in ipairs(
    result.library.playlists or {}
) do
    for _, track in ipairs(
        playlist.items or {}
    ) do
        add_track(track)
    end
end

assert(
    manifest_cache.save(
        json_encode.encode(manifest)
    )
)

print(
    "Jellyfin UI ready: playlists=" ..
    tostring(#result.library.playlists) ..
    " favorites=" ..
    tostring(#result.library.favorites.items) ..
    " playable_tracks=" ..
    tostring(#manifest.items)
)

local ok, message =
    pcall(dofile, "lua/main.lua")

if not ok then
    error(
        "Failed to load Tangara UI:\n" ..
        tostring(message)
    )
end

local core_jellyfin_playback =
    dofile("lua/jellyfin_playback.lua")

local original_play =
    core_jellyfin_playback.play
local original_current =
    core_jellyfin_playback.current
local original_sync_position =
    core_jellyfin_playback.sync_position
local original_next =
    core_jellyfin_playback.next
local original_previous =
    core_jellyfin_playback.previous

local function shell_quote(value)
    return "'" ..
        tostring(value):gsub(
            "'",
            "'\\''"
        ) ..
        "'"
end

local function encode_path_segment(value)
    return (
        tostring(value):gsub(
            "([^A-Za-z0-9._~-])",
            function(character)
                return string.format(
                    "%%%02X",
                    string.byte(character)
                )
            end
        )
    )
end

local function file_exists(path)
    local file = io.open(path, "rb")

    if not file then
        return false
    end

    file:close()
    return true
end

local function command_succeeded(command)
    local ok, reason, code =
        os.execute(command)

    return ok == true or
        ok == 0 or
        (
            reason == "exit" and
            code == 0
        )
end

local function download_artwork(
    track,
    variant,
    destination
)
    if file_exists(destination) then
        return true, false
    end

    local temporary =
        destination .. ".part"

    local url =
        server_url ..
        "/devices/" ..
        encode_path_segment(device_id) ..
        "/items/" ..
        encode_path_segment(
            track.id or
            track.jellyfin_id
        ) ..
        "/artwork/" ..
        variant

    os.remove(temporary)

    local command =
        "curl -fsSL " ..
        "--connect-timeout 10 " ..
        "--max-time 60 " ..
        "-o " ..
        shell_quote(temporary) ..
        " " ..
        shell_quote(url) ..
        " && mv " ..
        shell_quote(temporary) ..
        " " ..
        shell_quote(destination)

    if command_succeeded(command) then
        return true, true
    end

    os.remove(temporary)
    return false, false
end

local cached_artwork_by_track = {}

local function cache_track_background(track)
    if type(track) ~= "table" then
        return false
    end

    local track_id =
        track.id or
        track.jellyfin_id

    if type(track_id) ~= "string" or
        track_id == "" then
        return false
    end

    local current_manifest =
        manifest_cache.load()

    if not current_manifest then
        return false
    end

    local item = nil

    for _, candidate in ipairs(
        current_manifest.items or {}
    ) do
        if candidate.id == track_id or
            candidate.jellyfin_id ==
                track_id then
            item = candidate
            break
        end
    end

    if not item then
        return false
    end

    local artwork_directory =
        root .. "/sim-artwork"

    os.execute(
        "mkdir -p " ..
        shell_quote(artwork_directory)
    )

    local stem =
        track_id:gsub(
            "[^A-Za-z0-9._-]",
            "_"
        )

    local background_path =
        artwork_directory ..
        "/" ..
        stem ..
        "-background-v3.png"

    local background_ready,
        background_downloaded =
        download_artwork(
            track,
            "background",
            background_path
        )

    if not background_ready then
        return false
    end

    local value =
        "/" .. background_path

    item.artwork =
        item.artwork or {}

    local manifest_changed =
        item.artwork.background ~=
            value

    item.artwork.background = value
    track.artwork =
        track.artwork or {}
    track.artwork.background = value

    if manifest_changed then
        local saved, save_error =
            manifest_cache.save(
                json_encode.encode(
                    current_manifest
                )
            )

        if not saved then
            print(
                "Album background cache save failed: " ..
                tostring(save_error)
            )
            return false
        end
    end

    if background_downloaded then
        print(
            "Album background cached for: " ..
            tostring(track.album or track.title)
        )
    end

    return true
end

_G.tangara_sim_cache_track_background =
    cache_track_background

local function apply_cached_artwork(
    track,
    cached
)
    track.artwork = track.artwork or {}

    if cached.cover then
        track.artwork.cover = cached.cover
    end

    if cached.background then
        track.artwork.background =
            cached.background
    end
end

local function cache_track_artwork(track)
    if type(track) ~= "table" then
        return false
    end

    local track_id =
        track.id or
        track.jellyfin_id

    if type(track_id) ~= "string" or
        track_id == "" then
        return false
    end

    local cached =
        cached_artwork_by_track[track_id]

    if cached then
        apply_cached_artwork(
            track,
            cached
        )
        return true
    end
    local current_manifest =
        manifest_cache.load()

    if not current_manifest then
        return false
    end

    local item = nil

    for _, candidate in ipairs(
        current_manifest.items or {}
    ) do
        if candidate.id == track_id or
            candidate.jellyfin_id ==
                track_id then
            item = candidate
            break
        end
    end

    if not item then
        return false
    end

    local artwork_directory =
        root .. "/sim-artwork"

    os.execute(
        "mkdir -p " ..
        shell_quote(artwork_directory)
    )

    local stem =
        track_id:gsub(
            "[^A-Za-z0-9._-]",
            "_"
        )

    local cover_path =
        artwork_directory ..
        "/" ..
        stem ..
        "-cover.png"

    local background_path =
        artwork_directory ..
        "/" ..
        stem ..
        "-background-v3.png"

    local cover_ready,
        cover_downloaded =
        download_artwork(
            track,
            "cover",
            cover_path
        )

    local background_ready,
        background_downloaded =
        download_artwork(
            track,
            "background",
            background_path
        )

    item.artwork =
        item.artwork or {}

    local manifest_changed = false
    local resolved = {}

    if cover_ready then
        local value = "/" .. cover_path

        if item.artwork.cover ~= value then
            item.artwork.cover = value
            manifest_changed = true
        end

        resolved.cover = value
    end

    if background_ready then
        local value =
            "/" .. background_path

        if item.artwork.background ~= value then
            item.artwork.background = value
            manifest_changed = true
        end

        resolved.background = value
    end

    if not cover_ready and
        not background_ready then
        print(
            "No Jellyfin artwork for: " ..
            tostring(track.title)
        )

        return false
    end

    apply_cached_artwork(
        track,
        resolved
    )

    if manifest_changed then
        local saved, save_error =
            manifest_cache.save(
                json_encode.encode(
                    current_manifest
                )
            )

        if not saved then
            print(
                "Artwork cache save failed: " ..
                tostring(save_error)
            )

            return false
        end
    end

    cached_artwork_by_track[track_id] =
        resolved

    if cover_downloaded or
        background_downloaded then
        print(
            "Artwork cached for: " ..
            tostring(track.title)
        )
    end

    return true
end

local function refreshed_active(
    active,
    download
)
    if not active or
        type(active.track) ~= "table" then
        return active
    end

    if download then
        cache_track_artwork(
            active.track
        )
    end

    local current_manifest =
        manifest_cache.load()

    if current_manifest then
        for _, item in ipairs(
            current_manifest.items or {}
        ) do
            if item.id == active.track.id or
                item.jellyfin_id ==
                    active.track.id then
                active.item = item
                active.track.artwork =
                    item.artwork or
                    active.track.artwork
                break
            end
        end
    end

    return active
end

function core_jellyfin_playback.play(
    track,
    context
)
    cache_track_artwork(track)

    return original_play(
        track,
        context
    )
end

function core_jellyfin_playback.current()
    return refreshed_active(
        original_current(),
        false
    )
end

function core_jellyfin_playback.sync_position(
    position
)
    return refreshed_active(
        original_sync_position(
            position
        ),
        true
    )
end

function core_jellyfin_playback.next()
    return refreshed_active(
        original_next(),
        true
    )
end

function core_jellyfin_playback.previous()
    return refreshed_active(
        original_previous(),
        true
    )
end

package.loaded["jellyfin_playback"] =
    core_jellyfin_playback

local library_screen =
    dofile("lua/jellyfin_library.lua")

package.loaded["jellyfin_library"] =
    library_screen

local local_library =
    dofile(
        "lua/jellyfin_local_library.lua"
    )

package.loaded[
    "jellyfin_local_library"
] = local_library

simulator.backstack.pop()

simulator.backstack.push(
    require("jellyfin_home").Home:new()
)
