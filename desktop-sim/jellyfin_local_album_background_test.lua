dofile("desktop-sim/jellyfin_library.lua")

local backstack = require("backstack")
local index = require("jellyfin_local_index")
local local_library = require("jellyfin_local_library")
local metrics = require("sim_metrics")

local library = assert(index.load())
local checked = 0

local function usable(value)
    return type(value) == "string" and
        value ~= "" and
        not value:find("placeholder", 1, true)
end

local function persistent_source(album)
    local sources = {album.artwork}

    if album.tracks and album.tracks[1] then
        table.insert(
            sources,
            album.tracks[1].artwork
        )
    end

    for _, artwork in ipairs(sources) do
        if type(artwork) == "table" then
            for _, key in ipairs({
                "background",
                "cover",
                "thumbnail",
                "album_thumbnail",
            }) do
                if usable(artwork[key]) then
                    return artwork[key]
                end
            end
        end
    end

    return nil
end

for _, album in ipairs(library.albums or {}) do
    local expected = persistent_source(album)

    if expected then
        local screen = local_library.Album:new {
            title = album.name,
            album_key = album.key,
        }

        backstack.push(screen)
        screen.root:update_layout()

        local state = screen:background_state()
        local geometry = metrics.image_geometry(
            screen.background_art
        )

        print(string.format(
            "ALBUM GEOMETRY | %s | object=%d,%d %dx%d | " ..
                "pivot=%d,%d zoom=%d transformed=%d,%d-%d,%d",
            album.name,
            geometry.x,
            geometry.y,
            geometry.width,
            geometry.height,
            geometry.pivot_x,
            geometry.pivot_y,
            geometry.zoom,
            geometry.transformed_x1,
            geometry.transformed_y1,
            geometry.transformed_x2,
            geometry.transformed_y2
        ))

        assert(state.enabled,
            album.name .. " has persistent art but no background")
        assert(state.source:find(
            expected:gsub("^/", ""),
            1,
            true
        ), album.name .. " used another album/session artwork")
        assert(state.geometry.target_width == 160)
        assert(state.geometry.target_height == 128)
        assert(geometry.transformed_x1 <= 0)
        assert(geometry.transformed_y1 <= 0)
        assert(geometry.transformed_x2 >= 159,
            "transformed x2=" ..
                tostring(geometry.transformed_x2))
        assert(geometry.transformed_y2 >= 127,
            "transformed y2=" ..
                tostring(geometry.transformed_y2))

        print(string.format(
            "ALBUM BACKGROUND | %s | id=%s | owner=%s | source=%s | " ..
                "decoded=%dx%d zoom=%d descriptor=%s",
            album.name,
            tostring(album.id or album.jellyfin_id or album.key),
            tostring(album.id or album.jellyfin_id or album.key),
            state.source,
            geometry.decoded_width,
            geometry.decoded_height,
            state.geometry.zoom,
            tostring(geometry.source)
        ))

        backstack.pop()
        checked = checked + 1

        if checked >= 4 then
            break
        end
    end
end

assert(checked >= 3,
    "expected at least three real Local albums with persistent artwork")
print("Local album backgrounds passed for " .. checked .. " viewed albums")
os.exit(0)
