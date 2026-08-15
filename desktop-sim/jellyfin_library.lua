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

function tangara_sim_now_playing_event()
    require("jellyfin_playback_session")
        .open_now_playing()
end

print(
    "Simulator input: hold Right Arrow for 400 ms " ..
    "to open the current Local Now Playing session"
)

local lvgl = require("lvgl")

local native_img_data = lvgl.ImgData
local persistent_img_data = {}

lvgl.ImgData = function(path)
    if type(path) == "string" and
        path:match("^/desktop%-sim/") then
        local decoded =
            persistent_img_data[path]

        if not decoded then
            decoded = native_img_data(path)
            persistent_img_data[path] = decoded
        end

        return decoded
    end

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

local established_storage_root =
    "desktop-sim/sd/jellyfin-library-ui"
local configured_storage_root =
    os.getenv("TANGARA_SIM_STORAGE_ROOT")
local root =
    configured_storage_root or
    established_storage_root

os.execute("mkdir -p " .. root)

local companion_http_available = false

_G.tangara_sim_enable_encoder_handler = true

local simulator =
    require("mocks").install(lvgl)

local function simulator_shell_quote(value)
    return "'" ..
        tostring(value):gsub("'", "'\\''") ..
        "'"
end

local function simulator_command_ok(command)
    local ok, reason, code =
        os.execute(command)

    return ok == true or
        ok == 0 or
        (
            reason == "exit" and
            code == 0
        )
end

local function simulator_storage_path(path)
    if type(path) ~= "string" or
        path == "" then
        return nil
    end

    path = path:gsub("^/+", "")

    for segment in path:gmatch("[^/]+") do
        if segment == "." or
            segment == ".." then
            return nil
        end
    end

    return root .. "/" .. path
end

local simulator_filesystem =
    require("filesystem")

function simulator_filesystem.chkdir(path)
    local full_path =
        simulator_storage_path(path)

    return full_path ~= nil and
        simulator_command_ok(
            "test -d " ..
            simulator_shell_quote(full_path)
        )
end

function simulator_filesystem.mkdir(path)
    local full_path =
        simulator_storage_path(path)

    return full_path ~= nil and
        simulator_command_ok(
            "mkdir -p " ..
            simulator_shell_quote(full_path)
        )
end

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
                connected =
                    companion_http_available,
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

if result and result.ok then
    -- The refresh used the same configured URL and asynchronous HTTP
    -- transport as the sync runtime. This establishes the simulator
    -- equivalent of a connected interface without changing firmware Wi-Fi
    -- semantics.
    companion_http_available = true
else
    -- Local is an offline surface. A companion outage must not prevent the
    -- simulator from opening the persistent Local cache and downloaded
    -- media. Sync remains disconnected until a real HTTP refresh succeeds.
    local cached, _, cache_error =
        require("sync_library_cache")
            .load()

    assert(
        cached,
        cache_error or
            (result and result.error) or
            "library refresh timed out"
    )

    result = {
        ok = true,
        offline = true,
        library = cached,
        refresh_error =
            result and result.error,
    }
end

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

    if not companion_http_available then
        return false
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
local seed_simulated_media =
    os.getenv(
        "TANGARA_SIM_SEED_LOCAL_MEDIA"
    ) == "1"
local preserve_established_library =
    root == established_storage_root

local function legacy_placeholder_item(item)
    if seed_simulated_media or
        type(item) ~= "table" then
        return false
    end

    local path = item.local_path

    return type(path) == "string" and
        path:sub(1, 11) == "/sim-media/"
end

local function add_track(track)
    if seen[track.id] then
        return
    end

    -- /sim-media entries are old desktop fixtures, not real downloaded
    -- Jellyfin media. Keep Favorites and playlist metadata visible, but do not
    -- advertise these placeholder files through the Local manifest unless a
    -- focused simulator test explicitly opts into seeding them.
    if not seed_simulated_media then
        return
    end

    seen[track.id] = true
    counter = counter + 1

    local local_path =
        "/sim-media/" ..
        tostring(counter) ..
        ".flac"

    if seed_simulated_media then
        os.execute(
            "mkdir -p " ..
            simulator_shell_quote(
                root .. "/sim-media"
            )
        )

        if not playlist_file_exists(
            root .. local_path
        ) then
            local file =
                assert(
                    io.open(
                        root .. local_path,
                        "wb"
                    )
                )

            file:write("simulator")
            file:close()
        end
    elseif not playlist_file_exists(
        root .. local_path
    ) then
        return
    end

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
                -- Album rows and playlist fallback share one stable, offline
                -- cover identity. The companion artwork proxy resolves the
                -- parent album image even when a track has no Primary tag.
                thumbnail_item_id =
                    type(track.album_id) ==
                            "string" and
                        track.album_id ~= "" and
                        track.album_id or
                        track.id,
                cover =
                    "//lua/img/cover_placeholder.png",
                background =
                    "//lua/img/background_placeholder.png",
            },
        }
    )
end

if seed_simulated_media or
    preserve_established_library then
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

end

local function merge_simulator_manifest(
    incoming
)
    if not preserve_established_library then
        return incoming
    end

    incoming = incoming or {
        device = {id = device_id},
        items = {},
    }

    local merged = {
        device = incoming.device,
        items = {},
    }
    local positions = {}

    for _, item in ipairs(manifest.items) do
        if not legacy_placeholder_item(item) then
            local id = tostring(
                item.jellyfin_id or
                item.id or ""
            )
            if id ~= "" and
                not positions[id] then
                merged.items[#merged.items + 1] =
                    item
                positions[id] = #merged.items
            end
        end
    end

    for _, item in ipairs(
        incoming.items or {}
    ) do
        if not legacy_placeholder_item(item) then
            local id = tostring(
                item.jellyfin_id or
                item.id or ""
            )
            local position = positions[id]

            if id ~= "" and position then
                -- A real synchronized file is authoritative over any prior
                -- entry for the same Jellyfin item.
                merged.items[position] = item
            else
                merged.items[#merged.items + 1] =
                    item
                if id ~= "" then
                    positions[id] = #merged.items
                end
            end
        end
    end

    return merged
end

local original_manifest_cache_save =
    manifest_cache.save

if preserve_established_library then
    local sync_manifest =
        require("sync_manifest")

    manifest_cache.save = function(text)
        local incoming, decode_error =
            sync_manifest.decode(text)

        if not incoming then
            return false, decode_error
        end

        return original_manifest_cache_save(
            json_encode.encode(
                merge_simulator_manifest(
                    incoming
                )
            )
        )
    end

    local persisted =
        manifest_cache.load()

    assert(
        original_manifest_cache_save(
            json_encode.encode(
                merge_simulator_manifest(
                    persisted
                )
            )
        )
    )

    local manifest_fetch =
        require("sync_manifest_fetch")
    local original_manifest_fetch_poll =
        manifest_fetch.poll

    manifest_fetch.poll = function()
        local fetched =
            original_manifest_fetch_poll()

        if fetched and fetched.ok and
            fetched.manifest then
            fetched.manifest =
                merge_simulator_manifest(
                    fetched.manifest
                )
        end

        return fetched
    end
elseif seed_simulated_media then
    assert(
        manifest_cache.save(
            json_encode.encode(manifest)
        )
    )
end

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

if companion_http_available then
    require("sync_runtime")
        .request_refresh()
end

local core_jellyfin_playback =
    dofile("lua/jellyfin_playback.lua")
local simulator_playback =
    require("playback")
local simulator_volume =
    require("volume")
local simulator_audio =
    require("sim_audio")

local function simulator_global_volume_transport(
    action,
    amount
)
    if action ~= "volume_up" and
        action ~= "volume_down" then
        return false
    end

    local direction =
        action == "volume_up" and 1 or -1

    local count =
        math.max(
            1,
            math.abs(
                tonumber(amount) or 1
            )
        )

    local current =
        tonumber(
            simulator_volume.current_pct:get()
        ) or 0

    simulator_volume.current_pct:set(
        math.max(
            0,
            math.min(
                100,
                current +
                    direction * count * 5
            )
        )
    )

    return true
end

_G.tangara_sim_transport_event =
    simulator_global_volume_transport

local original_play_queue =
    core_jellyfin_playback.play_queue
local original_current =
    core_jellyfin_playback.current
local original_sync_position =
    core_jellyfin_playback.sync_position
local original_next =
    core_jellyfin_playback.next
local original_previous =
    core_jellyfin_playback.previous

local simulator_playback_state = {
    started = false,
    file_open = false,
    resolved_path = nil,
    queued_path = nil,
    size = nil,
    codec = nil,
    output = "closed",
    decoder_open = false,
    sample_rate = 0,
    channels = 0,
    total_frames = 0,
    consumed_frames = 0,
    duration = 0,
    position = 0,
    peak = 0,
    rms = 0,
    audio_error = nil,
    open_count = 0,
    close_count = 0,
    decoder_path = nil,
    queue_index = nil,
    transition = nil,
}

_G.tangara_sim_local_playback_state =
    simulator_playback_state

local function bind_simulator_playback(
    active
)
    if not active or
        type(active.track) ~= "table" or
        type(active.item) ~= "table" then
        return active
    end

    local queued_path =
        active.item.local_path
    local resolved_path =
        simulator_storage_path(
            queued_path
        )
    local decoder_before =
        simulator_playback_state
            .decoder_path
    local decoder_was_open =
        simulator_playback_state
            .decoder_open == true
    local previous_queue_index =
        simulator_playback_state
            .queue_index
    local next_queue_index =
        active.queue and
        tonumber(active.queue.position) or
        nil
    local file_size = nil

    if resolved_path then
        local file =
            io.open(
                resolved_path,
                "rb"
            )

        if file then
            file_size = file:seek("end")
            file:close()
        end
    end

    simulator_playback_state.started =
        file_size ~= nil
    simulator_playback_state.file_open =
        file_size ~= nil
    simulator_playback_state.resolved_path =
        resolved_path
    simulator_playback_state.queued_path =
        queued_path
    simulator_playback_state.size =
        file_size
    simulator_playback_state.codec =
        type(queued_path) == "string" and
        queued_path:match("%.([^./]+)$") or
        nil

    if not file_size then
        if decoder_was_open then
            simulator_playback_state
                .close_count =
                simulator_playback_state
                    .close_count + 1
        end

        simulator_audio.close()
        simulator_playback_state.decoder_open =
            false
        simulator_playback_state.decoder_path =
            nil
        simulator_playback_state.output =
            "closed"
        simulator_playback_state.queue_index =
            next_queue_index
        simulator_playback_state.transition = {
            old_queue_index =
                previous_queue_index,
            new_queue_index =
                next_queue_index,
            track_id = active.track.id,
            title = active.track.title,
            queued_path = queued_path,
            path_passed = resolved_path,
            decoder_before = decoder_before,
            decoder_after = nil,
            old_decoder_closed =
                decoder_was_open,
            new_decoder_opened = false,
        }
        if os.getenv(
                "TANGARA_SIM_PLAYBACK_TRACE"
            ) == "1" then
            local transition =
                simulator_playback_state
                    .transition

            print(string.format(
                "Playback transition: %s -> %s | %s | %s | " ..
                    "queue=%s | passed=%s | decoder=%s -> %s | " ..
                    "closed=%s opened=%s | error=local file not found",
                tostring(
                    transition.old_queue_index
                ),
                tostring(
                    transition.new_queue_index
                ),
                tostring(transition.track_id),
                tostring(transition.title),
                tostring(transition.queued_path),
                tostring(transition.path_passed),
                tostring(transition.decoder_before),
                tostring(transition.decoder_after),
                tostring(
                    transition.old_decoder_closed
                ),
                tostring(
                    transition.new_decoder_opened
                )
            ))
        end

        simulator_playback.playing:set(
            false
        )
        return active
    end

    local same_source =
        decoder_was_open and
        decoder_before == resolved_path
    local audio_status
    local old_decoder_closed = false
    local new_decoder_opened = false

    if same_source then
        audio_status = simulator_audio.poll()
    else
        old_decoder_closed =
            decoder_was_open

        if old_decoder_closed then
            simulator_playback_state
                .close_count =
                simulator_playback_state
                    .close_count + 1
        end

        simulator_playback_state.end_handled =
            false
        simulator_playback_state.open_count =
            simulator_playback_state.open_count + 1
        audio_status =
            simulator_audio.open(
                resolved_path
            )
        new_decoder_opened =
            audio_status.ok == true
    end

    simulator_playback_state.decoder_open =
        audio_status.ok == true
    simulator_playback_state.output =
        audio_status.mode or "silent"
    simulator_playback_state.sample_rate =
        tonumber(audio_status.sample_rate) or 0
    simulator_playback_state.channels =
        tonumber(audio_status.channels) or 0
    simulator_playback_state.total_frames =
        tonumber(audio_status.total_frames) or 0
    simulator_playback_state.duration =
        tonumber(audio_status.duration) or 0
    simulator_playback_state.audio_error =
        audio_status.error
    simulator_playback_state.decoder_path =
        audio_status.ok == true and
        resolved_path or nil
    simulator_playback_state.queue_index =
        next_queue_index
    simulator_playback_state.transition = {
        old_queue_index =
            previous_queue_index,
        new_queue_index = next_queue_index,
        track_id = active.track.id,
        title = active.track.title,
        queued_path = queued_path,
        path_passed = resolved_path,
        decoder_before = decoder_before,
        decoder_after =
            simulator_playback_state
                .decoder_path,
        old_decoder_closed =
            old_decoder_closed,
        new_decoder_opened =
            new_decoder_opened,
    }

    if os.getenv(
            "TANGARA_SIM_PLAYBACK_TRACE"
        ) == "1" then
        local transition =
            simulator_playback_state
                .transition

        print(string.format(
            "Playback transition: %s -> %s | %s | %s | " ..
                "queue=%s | passed=%s | decoder=%s -> %s | " ..
                "closed=%s opened=%s | error=%s",
            tostring(
                transition.old_queue_index
            ),
            tostring(
                transition.new_queue_index
            ),
            tostring(transition.track_id),
            tostring(transition.title),
            tostring(transition.queued_path),
            tostring(transition.path_passed),
            tostring(transition.decoder_before),
            tostring(transition.decoder_after),
            tostring(
                transition.old_decoder_closed
            ),
            tostring(
                transition.new_decoder_opened
            ),
            tostring(
                simulator_playback_state
                    .audio_error
            )
        ))
    end

    if not audio_status.ok then
        simulator_playback.playing:set(
            false
        )
    elseif simulator_playback.playing:get() ==
            true then
        simulator_audio.play()
    else
        simulator_audio.pause()
    end

    simulator_audio.set_volume(
        tonumber(
            simulator_volume.current_pct:get()
        ) or 100
    )

    simulator_playback.track:set {
        id = active.track.id,
        jellyfin_id =
            active.track.jellyfin_id or
            active.track.id,
        title = active.track.title,
        artist = active.track.artist,
        album = active.track.album,
        duration =
            tonumber(active.track.duration) or
            tonumber(active.item.duration) or
            math.floor(
                tonumber(audio_status.duration) or
                0
            ) or
            0,
        filepath = queued_path,
        resolved_filepath =
            resolved_path,
        artwork = active.track.artwork,
        encoding =
            simulator_playback_state.codec and
            simulator_playback_state.codec:
                upper() or
            nil,
    }

    return active
end

local position_from_audio = false
local original_position_set =
    simulator_playback.position.set

function simulator_playback.position:set(
    value
)
    local result =
        original_position_set(
            self,
            value
        )

    if not position_from_audio and
        simulator_playback_state
            .decoder_open then
        local current =
            tonumber(
                simulator_audio.poll().position
            ) or 0
        local requested =
            tonumber(value) or 0

        if math.abs(requested - current) >
                0.25 then
            simulator_audio.seek(requested)
        end
    end

    return result
end

simulator_playback.playing:bind(
    function(playing)
        if not simulator_playback_state
                .decoder_open then
            return
        end

        if playing == true then
            simulator_audio.play()
        else
            simulator_audio.pause()
        end
    end
)

simulator_volume.current_pct:bind(
    function(value)
        simulator_audio.set_volume(
            tonumber(value) or 100
        )
    end
)

-- One authoritative clock: both audible output and the headless fallback
-- advance by PCM frames consumed from dr_flac. This timer only mirrors that
-- decoder position into Tangara's playback property; it never invents time.
simulator_playback_state.timer =
    lvgl.Timer {
        period = 50,
        cb = function()
            if not simulator_playback_state
                    .decoder_open then
                return
            end

            local status =
                simulator_audio.poll()
            local analysis =
                simulator_audio.analysis()

            simulator_playback_state.position =
                tonumber(status.position) or 0
            simulator_playback_state
                .consumed_frames =
                tonumber(
                    status.consumed_frames
                ) or 0
            simulator_playback_state.peak =
                tonumber(analysis.peak) or 0
            simulator_playback_state.rms =
                tonumber(analysis.rms) or 0
            simulator_playback_state
                .pcm_analysis = analysis

            position_from_audio = true
            simulator_playback.position:set(
                math.floor(
                    simulator_playback_state
                        .position
                )
            )
            position_from_audio = false

            if status.ended and
                not simulator_playback_state
                    .end_handled then
                simulator_playback_state
                    .end_handled = true

                local current =
                    original_current()
                local queue_position =
                    current and current.queue and
                    tonumber(
                        current.queue.position
                    ) or 0
                local queue_size =
                    current and current.queue and
                    tonumber(
                        current.queue.size
                    ) or 0

                if queue_position < queue_size then
                    core_jellyfin_playback.next()
                else
                    simulator_playback.playing:set(
                        false
                    )
                end
            end
        end,
    }

-- Local browsing is deliberately offline. Media sync has already placed the
-- display variants on the simulated SD card; the resolver shares them by
-- album artwork identity instead of starting the retired per-track network
-- cache path.
local local_artwork_cache =
    require("local_artwork_cache")
        .new(root)
local local_artwork_trace =
    local_artwork_cache.trace
local resolve_local_artwork =
    local_artwork_cache.resolve

_G.tangara_sim_local_artwork_trace =
    local_artwork_trace

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

    local resolved =
        resolve_local_artwork(
            item,
            track
        )

    if not resolved or
        not resolved.background then
        return false
    end

    track.artwork =
        track.artwork or {}
    track.artwork.background =
        resolved.background

    return true
end

_G.tangara_sim_cache_track_background =
    cache_track_background

local function apply_cached_artwork(
    track,
    cached
)
    track.artwork = track.artwork or {}

    if cached.thumbnail then
        track.artwork.thumbnail =
            cached.thumbnail
    end

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

    local resolved =
        resolve_local_artwork(
            item,
            track
        )

    if not resolved then
        return false
    end

    apply_cached_artwork(
        track,
        resolved
    )

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

function core_jellyfin_playback.play_queue(
    tracks,
    context,
    options
)
    local played, active =
        original_play_queue(
            tracks,
            context,
            options
        )

    if played then
        active =
            refreshed_active(
                active,
                true
            )
        bind_simulator_playback(active)
    end

    return played, active
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
    return bind_simulator_playback(
        refreshed_active(
        original_sync_position(
            position
        ),
        true
        )
    )
end

function core_jellyfin_playback.next()
    return bind_simulator_playback(
        refreshed_active(
            original_next(),
            true
        )
    )
end

function core_jellyfin_playback.previous()
    return bind_simulator_playback(
        refreshed_active(
            original_previous(),
            true
        )
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
