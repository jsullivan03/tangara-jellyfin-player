package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")

lvgl.ImgData = function(path)
    return path
end

local simulator =
    require("mocks").install(lvgl)

package.loaded["backstack"] =
    simulator.backstack
local pushed_screen = nil
local original_push =
    simulator.backstack.push
simulator.backstack.push =
    function(value)
        pushed_screen = value
        original_push(value)
    end

local queued = nil
local streamrip_destination = nil

local function local_destination_screen(
    kind,
    options
)
    return {
        destination_kind = kind,
        destination_options = options,
        create_ui = function()
        end,
        on_show = function()
        end,
        on_hide = function()
        end,
    }
end

package.loaded["jellyfin_local_library"] = {
    Album = {
        new = function(_, options)
            return local_destination_screen(
                "album",
                options
            )
        end,
    },
    Tracks = {
        new = function(_, options)
            return local_destination_screen(
                "tracks",
                options
            )
        end,
    },
}
local catalog_requests = {}
local payloads = {
    new = {
        view = "albums",
        sort = "date_added",
        direction = "descending",
        items = {
            {
                jellyfin_id = "new-日本",
                kind = "album",
                title = "新作",
                artist = "音楽家",
                jellyfin_artist_id =
                    "jellyfin-artist-jp",
                track_count = 8,
                artwork_path =
                    "/devices/device/items/" ..
                    "new-日本/artwork/thumbnail",
                artwork_revision =
                    "new-日本-revision",
                date_created =
                    "2026-07-30T12:00:00Z",
                device = {
                    state = "server_only",
                    total_tracks = 8,
                    downloaded_tracks = 0,
                    actionable = true,
                },
            },
            {
                jellyfin_id = "album-日本",
                kind = "album",
                title = "作品",
                artist = "音楽家",
                jellyfin_artist_id =
                    "jellyfin-artist-jp",
                track_count = 8,
                artwork_path =
                    "/devices/device/items/" ..
                    "album-日本/artwork/thumbnail",
                artwork_revision =
                    "album-日本-revision",
                date_created =
                    "2026-07-20T12:00:00Z",
                device = {
                    state = "server_only",
                    total_tracks = 8,
                    downloaded_tracks = 0,
                    actionable = true,
                },
            },
            {
                jellyfin_id = "album-partial",
                kind = "album",
                title = "未完成",
                artist = "音楽家",
                track_count = 8,
                date_created =
                    "2026-07-10T12:00:00Z",
                device = {
                    state = "partial",
                    total_tracks = 8,
                    downloaded_tracks = 2,
                    actionable = true,
                },
            },
            {
                jellyfin_id = "album-done",
                kind = "album",
                title = "完了",
                artist = "音楽家",
                track_count = 3,
                date_created =
                    "2026-07-01T12:00:00Z",
                device = {
                    state = "downloaded",
                    total_tracks = 3,
                    downloaded_tracks = 3,
                    actionable = false,
                },
            },
        },
    },
    albums = {
        view = "albums",
        sort = "title",
        direction = "ascending",
        generation = 1,
        total = 125,
        total_count = 125,
        next_cursor = "cursor-50",
        items = {
            {
                jellyfin_id = "new-日本",
                kind = "album",
                title = "新作",
                artist = "音楽家",
                jellyfin_artist_id =
                    "jellyfin-artist-jp",
                track_count = 8,
                date_created =
                    "2026-07-30T12:00:00Z",
                device = {
                    state = "server_only",
                    total_tracks = 8,
                    downloaded_tracks = 0,
                    actionable = true,
                },
            },
            {
                jellyfin_id = "album-日本",
                kind = "album",
                title = "作品",
                artist = "音楽家",
                jellyfin_artist_id =
                    "jellyfin-artist-jp",
                track_count = 8,
                artwork_path =
                    "/devices/device/items/" ..
                    "album-日本/artwork/thumbnail",
                artwork_revision =
                    "album-日本-revision",
                date_created =
                    "2026-07-20T12:00:00Z",
                device = {
                    state = "server_only",
                    total_tracks = 8,
                    downloaded_tracks = 0,
                    actionable = true,
                },
            },
            {
                jellyfin_id = "album-partial",
                kind = "album",
                title = "未完成",
                artist = "音楽家",
                track_count = 8,
                date_created =
                    "2026-07-10T12:00:00Z",
                device = {
                    state = "partial",
                    total_tracks = 8,
                    downloaded_tracks = 2,
                    actionable = true,
                },
            },
            {
                jellyfin_id = "album-done",
                kind = "album",
                title = "完了",
                artist = "音楽家",
                track_count = 3,
                date_created =
                    "2026-07-01T12:00:00Z",
                device = {
                    state = "downloaded",
                    total_tracks = 3,
                    downloaded_tracks = 3,
                    actionable = false,
                },
            },
        },
    },
    tracks = {
        view = "tracks",
        sort = "title",
        direction = "ascending",
        generation = 1,
        total = 75,
        total_count = 75,
        next_cursor = "tracks-cursor-50",
        items = {
            {
                jellyfin_id = "track-1",
                kind = "track",
                title = "一曲",
                artist = "音楽家",
                device = {
                    state = "downloaded",
                    actionable = false,
                },
            },
        },
    },
}
for index = 5, 50 do
    payloads.albums.items[index] = {
        jellyfin_id =
            "album-page-1-" ..
            tostring(index),
        kind = "album",
        title =
            string.format(
                "Page One %02d",
                index
            ),
        artist = "Artist",
        device = {
            state = "server_only",
            actionable = true,
        },
    }
end

for index = 2, 50 do
    payloads.tracks.items[index] = {
        jellyfin_id =
            "track-page-1-" ..
            tostring(index),
        kind = "track",
        title =
            string.format(
                "Track %02d",
                index
            ),
        artist = "Artist",
        device = {
            state = "server_only",
            actionable = true,
        },
    }
end

local search_payload = {
    total_count = 25,
    items = {
        payloads.albums.items[1],
        {
            key = "opaque-search-only",
            kind = "album",
            title = "外部検索",
            artist = "外部音楽家",
            availability = "available",
        },
    },
    external_search_pending = true,
}

package.loaded["jellyfin_local_index"] = {
    load = function()
        return {
            tracks = {
                {
                    jellyfin_id =
                        "some-local-1",
                },
                {
                    jellyfin_id =
                        "all-local-1",
                },
                {
                    jellyfin_id =
                        "all-local-2",
                },
                {
                    id = "track-1",
                    jellyfin_id = "track-1",
                    title = "一曲",
                    artist = "音楽家",
                    album = "作品",
                },
                {
                    jellyfin_id =
                        "individual-local",
                },
            },
            albums = {
                {
                    id = "album-done",
                    track_count = 3,
                },
                {
                    id = "album-partial",
                    track_count = 2,
                },
            },
        }
    end,
}

package.loaded["sync_catalog"] = {
    cached = function(view)
        return payloads[view]
    end,
    cached_key = function(key)
        if key == "downloads" then
            return {
                device_requests = {
                    {id = "r1", state = "downloading"},
                },
                external_jobs = {},
            }
        end
        if key == "search:作品" then
            return search_payload
        end
        if key ==
            "artist:jellyfin-artist-jp" then
            return {
                resolution =
                    "jellyfin_only",
                artist = {
                    name = "音楽家",
                },
                groups = {
                    {
                        id = "albums",
                        items = {
                            payloads
                                .albums
                                .items[1],
                            {
                                key =
                                    "opaque-external-only",
                                kind = "album",
                                title = "外部作品",
                                artist = "音楽家",
                                availability =
                                    "available",
                            },
                        },
                    },
                },
            }
        end
        return nil
    end,
    local_artist_releases = function(item)
        return {
            groups = {
                {
                    id = "albums",
                    items = {
                        payloads.albums.items[1],
                    },
                },
            },
        }
    end,
    error = function()
        return nil
    end,
    busy = function()
        return false
    end,
    start = function(
        view,
        cursor,
        limit,
        options
    )
        catalog_requests[
            #catalog_requests + 1
        ] = {
            view = view,
            cursor = cursor,
            limit = limit,
            options = options,
        }
        return true
    end,
    downloads = function()
        return true
    end,
    search = function()
        return true
    end,
    artist_releases = function()
        return true
    end,
    external_job = function(_, destination)
        streamrip_destination = destination
        return true
    end,
    poll = function()
        return nil
    end,
    queue = function(item)
        queued = item
        return true
    end,
}

package.loaded["jellyfin_sync_ui"] = nil
local sync_ui =
    require("jellyfin_sync_ui")

local root = sync_ui.Root:new()
simulator.backstack.reset(root)

assert(#root.rows == 7)
assert(#root.quick_rows == 3)
assert(root.quick_rows[1].label_text == "Search")
assert(root.quick_rows[2].label_text == "Albums")
assert(root.quick_rows[3].label_text == "Tracks")
assert(root.quick_rows[1].label_text_align == 2)
assert(#root.quick_rows[1].icon_parts > 0)
assert(#root.quick_rows[2].icon_parts > 0)
assert(#root.quick_rows[3].icon_parts > 0)
assert(root.rows[1] == root.quick_rows[1])
assert(root.rows[2] == root.quick_rows[2])
assert(root.rows[3] == root.quick_rows[3])
assert(root.rows[4].title.text == "新作")
assert(#root.rows - 3 <= 20)
assert(#catalog_requests == 1)
assert(catalog_requests[1].view == "albums")
assert(catalog_requests[1].cursor == nil)
assert(catalog_requests[1].limit == 20)
assert(catalog_requests[1].options.cache_key == "new")
assert(catalog_requests[1].options.sort == "date_added")
assert(catalog_requests[1].options.direction == "descending")
catalog_requests = {}
local previous_date = nil
for index = 4, #root.rows do
    local item = root.rows[index].catalog_item
    assert(item.kind == "album")
    if previous_date then
        assert(
            previous_date >=
                tostring(
                    item.date_created or ""
                )
        )
    end
    previous_date =
        tostring(item.date_created or "")
end

local albums =
    sync_ui.Catalog:new {
        title = "Albums",
        view = "albums",
    }
albums:create_ui()

assert(#albums.rows == 8)
assert(
    albums.virtual_list_controller.fixed_viewport == true,
    "Sync Albums must use the fixed viewport so row recycling cannot expose black canvas gaps"
)
assert(
    albums.sort_row.marquees[1].text ==
        "Sort"
)
assert(
    albums.sort_menu_models ~= nil,
    "Albums did not instantiate the original list-ui Sort controller"
)
albums.open_sort_menu()
assert(#albums.sort_menu_models == 2)
assert(
    albums.sort_menu_models[1]
        .method == "alpha"
)
assert(
    albums.sort_menu_models[2]
        .method == "recent"
)
albums.close_sort_menu(true)
assert(albums.rows[2].title.text == "新作")
assert(
    albums.rows[2].detail.text ==
        "音楽家"
)
assert(albums.rows[2].on_click ~= nil)
assert(albums.rows[3].on_click ~= nil)
assert(
    albums.scroll_indicator.item_count == 125,
    "Albums scrollbar ignored the complete catalog count"
)
assert(
    albums.scroll_indicator.thumb_height ==
        albums.scroll_indicator:
            thumb_height_for(125),
    "Albums scrollbar thumb was sized from loaded rows"
)
assert(
    albums.scroll_indicator.thumb_color ==
        require("jellyfin_theme").color(
            "accent"
        ),
    "Albums scrollbar did not use the semantic accent color"
)

albums.virtual_list_controller:
    focus_index(26)
assert(#catalog_requests == 1)
assert(catalog_requests[1].view == "albums")
assert(catalog_requests[1].cursor == "cursor-50")
assert(catalog_requests[1].limit == 50)
assert(
    catalog_requests[1].options.generation == 1
)

payloads.albums.items[51] = {
    jellyfin_id = "album-page-2-a",
    kind = "album",
    title = "Page Two A",
    artist = "Artist",
    device = {
        state = "server_only",
        actionable = true,
    },
}
payloads.albums.items[52] = {
    jellyfin_id = "album-page-2-b",
    kind = "album",
    title = "Page Two B",
    artist = "Artist",
    device = {
        state = "server_only",
        actionable = true,
    },
}
payloads.albums.next_cursor = "cursor-100"
albums:render()
assert(#albums.items == 52)
assert(#albums.result_models == 7)
assert(#albums.rows == 8)
assert(
    albums.scroll_indicator.item_count == 125,
    "Albums scrollbar count shrank after appending a page"
)
assert(
    albums.items[51].jellyfin_id ==
        "album-page-2-a"
)
assert(
    albums.virtual_list_controller:
        pool_count() == 7,
    "Albums pagination materialized more than the virtual row pool"
)
albums.virtual_list_controller:
    focus_index(1)

local tracks =
    sync_ui.Catalog:new {
        title = "Tracks",
        view = "tracks",
    }
tracks:create_ui()
assert(#tracks.items == 50)
assert(#tracks.result_models == 7)
-- Clicking a downloaded Sync track must not open the Local sheet; View is
-- offered on long-hold only.
pushed_screen = nil
if tracks.track_action_sheet then
    tracks.track_action_sheet:close(true)
end
tracks.result_models[1].on_click()
assert(
    not (
        tracks.track_action_sheet and
        tracks.track_action_sheet.is_open
    ),
    "Downloaded Sync track opened an action sheet on click"
)
assert(
    pushed_screen == nil,
    "Downloaded Sync track navigated on click"
)

pushed_screen = nil
tracks.result_models[1].on_long_press()
local downloaded_sheet =
    assert(tracks.track_action_sheet)
assert(downloaded_sheet.is_open)
assert(
    downloaded_sheet:state()
        .main_actions[1] ==
        "view_local",
    "Downloaded Sync track did not expose View in Local first"
)
assert(
    downloaded_sheet:activate(
        "view_local"
    )
)
assert(
    pushed_screen ~= nil and
        pushed_screen.destination_kind ==
            "tracks",
    "Downloaded Sync track did not open its Local destination"
)
assert(
    tracks.scroll_indicator.item_count == 75,
    "Tracks scrollbar ignored the complete catalog count"
)
assert(
    tracks.scroll_indicator.thumb_color ==
        require("jellyfin_theme").color(
            "accent"
        ),
    "Tracks scrollbar did not use the semantic accent color"
)
tracks.virtual_list_controller:
    focus_index(26)
assert(#catalog_requests == 2)
assert(catalog_requests[2].view == "tracks")
assert(
    catalog_requests[2].cursor ==
        "tracks-cursor-50"
)
assert(catalog_requests[2].limit == 50)

local server_row = nil
local downloaded_row = nil
local partial_row = nil
for _, row in ipairs(albums.rows) do
    if row.catalog_item and
        row.catalog_item.jellyfin_id ==
            "album-日本" then
        server_row = row
    elseif row.state == "downloaded" then
        downloaded_row = row
    elseif row.state == "partial" then
        partial_row = row
    end
end
assert(server_row ~= nil)
assert(downloaded_row ~= nil)
assert(partial_row ~= nil)
assert(server_row.state_icon.kind == "server")
assert(
    downloaded_row.state_icon.kind ==
        "device"
)
assert(
    partial_row.state_icon and
        partial_row.state_icon.kind ==
            "partial",
    "Partial did not use the compact partial-state icon"
)
assert(
    not partial_row.detail.text:
        find("Partial", 1, true),
    "Partial state text leaked into the artist line"
)
assert(
    server_row.catalog_item.artwork_path:
        match("/artwork/thumbnail$")
)
local placeholder_image =
    server_row.artwork.image
server_row.artwork:set(
    "/desktop-sim/.tangara-artwork/sync/test.png"
)
assert(
    server_row.artwork.image ==
        placeholder_image,
    "completed Sync artwork replaced its LVGL image instead of updating it in place"
)
assert(
    server_row.artwork.current_source ==
        "/desktop-sim/.tangara-artwork/sync/test.png",
    "completed Sync artwork did not repaint the row on its first load"
)

local results =
    sync_ui.Results:new {
        query = "作品",
    }
results:create_ui()
assert(#results.rows == 3)
assert(
    results.external_notice.text ==
        "Searching external"
)
assert(
    results.scroll_indicator.item_count == 25 and
        results.scroll_indicator.thumb_height ==
            results.scroll_indicator:
                thumb_height_for(25),
    "Search scrollbar ignored a known complete result count"
)
local jellyfin_search_row = nil
local external_search_row = nil
for _, row in ipairs(results.rows) do
    if row.catalog_item and
        row.catalog_item.jellyfin_id ==
            "new-日本" then
        jellyfin_search_row = row
    elseif row.catalog_item and
        row.catalog_item.key ==
            "opaque-search-only" then
        external_search_row = row
    end
end
assert(
    jellyfin_search_row and
        jellyfin_search_row.on_click ~= nil,
    "Jellyfin Search result was not immediately actionable"
)
assert(external_search_row ~= nil)
assert(
    external_search_row.detail.text ==
        "外部音楽家" and
        external_search_row.state_icon ==
            nil,
    "unified Search still displayed Available or a server/device icon"
)
search_payload = {
    items = {
        payloads.albums.items[1],
    },
    external_available = false,
    external_message =
        "External search unavailable",
}
results:render()
assert(#results.rows >= 2)
assert(
    results.external_notice.text ==
        "External search unavailable"
)
local retained_jellyfin = false
for _, row in ipairs(results.rows) do
    if row.catalog_item and
        row.catalog_item.jellyfin_id ==
            "new-日本" and
        row.on_click ~= nil then
        retained_jellyfin = true
        break
    end
end
assert(
    retained_jellyfin,
    "external failure replaced the Jellyfin Search result"
)
assert(
    results.scroll_indicator.thumb_color ==
        "#FFFFFF"
)

server_row.on_long_press()
local confirm = albums.track_action_sheet
local confirm_state = confirm:state()
assert(
    confirm.is_open and
        confirm_state.main_actions[1] ==
            "download" and
        confirm_state.main_actions[2] ==
            "artist_discography" and
        confirm_state.main_actions[3] ==
            "cancel",
    "undownloaded Sync album long-hold must offer Download, Artist Discography, Cancel"
)
confirm:close(true)

server_row.on_click()
confirm = albums.track_action_sheet
confirm_state = confirm:state()
assert(
    confirm.is_open and
        confirm_state.main_actions[1] ==
            "download" and
        confirm_state.main_actions[2] ==
            "cancel"
)
assert(confirm:activate("download"))
assert(queued.jellyfin_id == "album-日本")
confirm:close(true)

local artist =
    sync_ui.Artist:new {
        item = server_row.catalog_item,
        title = "音楽家",
    }
artist:create_ui()
assert(
    artist.rows[1] and
        artist.rows[1].catalog_item
            .jellyfin_id ==
            "new-日本",
    "artist discography did not render cached Jellyfin releases immediately"
)
local external_release = nil
for _, row in ipairs(artist.rows) do
    if row.catalog_item and
        row.catalog_item.key ==
            "opaque-external-only" then
        external_release = row
        break
    end
end
assert(external_release ~= nil)
assert(
    external_release.detail.text ==
        "音楽家",
    "external-only result still displayed Available"
)
assert(
    external_release.state_icon == nil,
    "external-only result displayed a server or device icon"
)

partial_row.on_click()
confirm_state = confirm:state()
assert(
    confirm.is_open and
        confirm_state.main_actions[1] ==
            "download"
)
confirm:close(true)

local partial =
    sync_ui.Confirm:new {
        item = payloads.albums.items[3],
    }
partial:create_ui()
assert(
    partial.rows[1].marquees[1].text ==
        "Download missing tracks?"
)

assert(
    sync_ui.state_label(
        payloads.tracks.items[1]
    ) == "On device"
)

local available = {
    key = "opaque-external-1",
    kind = "album",
    title = "外部",
    artist = "音楽家",
    availability = "available",
}
sync_ui.activate(available, albums)
local destination =
    albums.track_action_sheet
assert(destination:activate("jellyfin"))
assert(streamrip_destination == "jellyfin")
sync_ui.activate(available, albums)
assert(
    destination:activate(
        "jellyfin_and_device"
    )
)
assert(
    streamrip_destination ==
        "jellyfin_and_device"
)
assert(
    sync_ui.state_label {
        device = {
            state = "queued",
        },
    } == "Queued"
)
assert(
    sync_ui.state_label {
        device = {
            state = "downloading",
        },
    } == "Downloading"
)
assert(
    sync_ui.state_label {
        jellyfin_id = "album-not-local",
        kind = "album",
        track_count = 12,
        device = {
            state = "downloaded",
        },
    } == "On server",
    "stale companion inventory incorrectly marked an incomplete local album as complete"
)
assert(
    sync_ui.actionable {
        device = {
            state = "queued",
            actionable = false,
        },
    } == true,
    "queued rows must remain long-holdable for Artist Discography"
)
assert(
    sync_ui.actionable(
        payloads.albums.items[3]
    ) == true
)

local state_cases = {
    {
        title = "Zero local",
        jellyfin_id = "album-zero",
        kind = "album",
        jellyfin_track_ids = {
            "zero-1",
            "zero-2",
        },
    },
    {
        title = "Some local",
        jellyfin_id = "album-some",
        kind = "album",
        jellyfin_track_ids = {
            "some-local-1",
            "some-missing-2",
        },
    },
    {
        title = "All local",
        jellyfin_id = "album-all",
        kind = "album",
        jellyfin_track_ids = {
            "all-local-1",
            "all-local-2",
        },
    },
    {
        title = "External only",
        key = "opaque-external-only",
        kind = "album",
        state = "server_only",
    },
    {
        title = "Local track",
        jellyfin_id =
            "individual-local",
        kind = "track",
        device = {
            state = "partial",
        },
    },
    {
        title = "Absent track",
        jellyfin_id =
            "individual-absent",
        kind = "track",
        device = {
            state = "partial",
        },
    },
}
local debug_lines = {}
local diagnostics =
    sync_ui.debug_state_diagnostics(
        state_cases,
        function(line)
            debug_lines[
                #debug_lines + 1
            ] = line
        end
    )
assert(#debug_lines == #state_cases)
assert(
    diagnostics[1].state ==
        "server_only" and
        diagnostics[1].icon ==
            "server" and
        diagnostics[1].local_count == 0,
    "zero-local Jellyfin album did not remain On server"
)
assert(
    diagnostics[2].state ==
        "partial" and
        diagnostics[2].icon ==
            "partial" and
        diagnostics[2].local_count == 1,
    "verified partial album did not show the partial-state icon"
)
assert(
    diagnostics[3].state ==
        "downloaded" and
        diagnostics[3].icon ==
            "device" and
        diagnostics[3].local_count == 2,
    "complete album did not show On device"
)
assert(
    diagnostics[4].state ==
        "available" and
        diagnostics[4].icon == "none",
    "external-only row received a server icon"
)
assert(
    diagnostics[5].state ==
        "downloaded" and
        diagnostics[5].icon ==
            "device",
    "local individual track was not On device"
)
assert(
    diagnostics[6].state ==
        "server_only" and
        diagnostics[6].icon ==
            "server",
    "absent individual track became Partial"
)

print(
    "Sync catalog navigation, states, confirmation, and non-Latin metadata passed"
)
os.exit(0)
