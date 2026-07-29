local jellyfin_list_ui =
    require("jellyfin_list_ui")
local jellyfin_playback =
    require("jellyfin_playback")
local jellyfin_local_index =
    require("jellyfin_local_index")
local jellyfin_virtual_list =
    require("jellyfin_virtual_list")
local queue = require("queue")
local screen = require("screen")

local COVER_PLACEHOLDER =
    "//lua/img/cover_placeholder.png"

local function usable_artwork(value)
    return type(value) == "string" and
        value ~= "" and
        value ~= COVER_PLACEHOLDER and
        value ~=
            "//lua/img/playlist_placeholder.png"
end

local function local_artwork_index()
    local library = jellyfin_local_index.load()
    local index = {}

    if type(library) ~= "table" then
        return index
    end

    for _, track in ipairs(
        library.tracks or {}
    ) do
        local artwork = track.artwork

        if type(track.id) == "string" then
            index[track.id] = artwork
        end

        if type(track.jellyfin_id) == "string" then
            index[track.jellyfin_id] = artwork
        end
    end

    return index
end

local function artwork_path(entry, local_artwork)
    -- The retained manifest item is the authoritative source for downloaded
    -- artwork. Playlist/Favorites track summaries may contain no artwork or a
    -- placeholder even when the local manifest has the album thumbnail.
    local track_id =
        entry and entry.track and
        (entry.track.id or
            entry.track.jellyfin_id)

    local candidates = {
        track_id and local_artwork and
            local_artwork[track_id],
        entry and entry.track and
            entry.track.artwork,
        entry and entry.track and
            entry.track.source_item and
            entry.track.source_item.artwork,
        entry and entry.item and
            entry.item.artwork,
    }
    local fallback = nil

    for _, artwork in ipairs(candidates) do
        if type(artwork) == "table" then
            for _, key in ipairs({
                "thumbnail",
                "cover",
                "album_thumbnail",
                "playlist_thumbnail",
            }) do
                local value = artwork[key]

                if usable_artwork(value) then
                    return value
                end

                if not fallback and
                    type(value) == "string" and
                    value ~= "" then
                    fallback = value
                end
            end
        end
    end

    return fallback or COVER_PLACEHOLDER
end

local function queue_title(shuffle)
    if shuffle then
        return "Queue (Shuffle)"
    end

    return "Queue"
end

local function entry_detail(entry)
    local artist =
        entry and entry.artist or ""

    if entry and entry.current then
        if artist ~= "" then
            return "Now playing - " .. artist
        end

        return "Now playing"
    end

    if artist ~= "" then
        return artist
    end

    return
        entry and entry.album or ""
end

local function build_entries(view)
    local entries = {}
    local generation =
        tonumber(view and view.generation) or 0
    local current =
        tonumber(view and view.position) or 1

    for index, track in ipairs(
        view and view.tracks or {}
    ) do
        table.insert(
            entries,
            {
                id = string.format(
                    "queue:%d:%d",
                    generation,
                    tonumber(
                        view.source_positions and
                        view.source_positions[index]
                    ) or index
                ),
                queue_index =
                    tonumber(
                        view.source_positions and
                        view.source_positions[index]
                    ) or index,
                display_index = index,
                current = index == current,
                title =
                    track.title or
                    "Unknown Track",
                artist =
                    track.artist or "",
                album =
                    track.album or "",
                artwork = track.artwork,
                track = track,
                item =
                    view.items and
                    view.items[index] or nil,
            }
        )
    end

    return entries
end

local QueueScreen =
    screen:new {
        create_ui = function(self)
            local view =
                jellyfin_playback.queue_view()

            jellyfin_list_ui.create_root(
                self,
                queue_title(
                    view and view.shuffle
                )
            )

            self.preserve_leading_controls_on_open =
                true

            if not view or
                type(view.tracks) ~= "table" or
                #view.tracks == 0 then
                local message =
                    jellyfin_list_ui.add_message(
                        self,
                        "Queue is empty"
                    )

                self.first_row = message.object
                return
            end

            local entries =
                build_entries(view)

            self.local_queue_artwork =
                local_artwork_index()
            local current_id =
                entries[view.position] and
                entries[view.position].id or
                entries[1].id

            self.selected_item_id = current_id
            self.queue_generation =
                view.generation
            self.queue_entries = entries

            self.virtual_queue_list =
                jellyfin_virtual_list.create(
                    self,
                    entries,
                    {
                        item_label =
                            "queue item",
                        item_plural =
                            "queue items",
                        item_id =
                            function(entry)
                                return entry.id
                            end,
                        create_row =
                            function(owner, entry)
                                return
                                    jellyfin_list_ui
                                        .add_track_row(
                                            owner,
                                            entry,
                                            {
                                                artwork =
                                                    artwork_path(
                                                        entry,
                                                        self.local_queue_artwork
                                                    ),
                                                detail =
                                                    entry_detail(
                                                        entry
                                                    ),
                                            }
                                        )
                            end,
                        update_row =
                            function(
                                model,
                                entry,
                                handlers
                            )
                                model:update(
                                    entry,
                                    {
                                        artwork =
                                            artwork_path(
                                                entry,
                                                self.local_queue_artwork
                                            ),
                                        detail =
                                            entry_detail(
                                                entry
                                            ),
                                        on_click =
                                            handlers.on_click,
                                        on_long_press =
                                            handlers
                                                .on_long_press,
                                    }
                                )
                            end,
                    }
                )

            local initial =
                self.virtual_queue_list
                    :selected_model()

            self.first_row =
                initial and initial.object or
                self.media_rows[1].object
            self.initial_focus_object =
                self.first_row

            local function refresh_queue()
                local next_view =
                    jellyfin_playback.queue_view()

                if not next_view or
                    type(next_view.tracks) ~= "table" or
                    #next_view.tracks == 0 then
                    return
                end

                local generation_changed =
                    next_view.generation ~=
                    self.queue_generation
                local next_entries =
                    build_entries(next_view)

                self.queue_generation =
                    next_view.generation
                self.queue_entries =
                    next_entries

                if generation_changed then
                    self.selected_item_id =
                        next_entries[
                            next_view.position
                        ] and
                        next_entries[
                            next_view.position
                        ].id or
                        next_entries[1].id
                end

                self.virtual_queue_list
                    :set_items(
                        next_entries
                    )

                self.header_marquee:set(
                    queue_title(
                        next_view.shuffle
                    )
                )
                self.header_marquee:start()
            end

            self.queue_position_binding =
                queue.position:bind(
                    function(position)
                        jellyfin_playback
                            .sync_position(
                                position
                            )
                        refresh_queue()
                    end
                )

            self.queue_shuffle_binding =
                queue.random:bind(
                    function()
                        refresh_queue()
                    end
                )

            function self.queue_page_state()
                local selected =
                    self.virtual_queue_list
                        :selected_model()

                local selected_index =
                    self.virtual_queue_list
                        .selected_index
                local selected_entry =
                    self.queue_entries[
                        selected_index
                    ]

                return {
                    count =
                        #self.queue_entries,
                    current =
                        tonumber(
                            jellyfin_playback
                                .queue_view()
                                .position
                        ) or 1,
                    selected = selected_index,
                    pool =
                        self.virtual_queue_list
                            :pool_count(),
                    selected_id =
                        self.selected_item_id,
                    selected_detail =
                        selected and
                        selected.detail and
                        selected.detail.text or
                        nil,
                    selected_artwork =
                        selected_entry and
                        artwork_path(
                            selected_entry,
                            self.local_queue_artwork
                        ) or nil,
                    selected_queue_index =
                        selected_entry and
                        selected_entry.queue_index or
                        nil,
                }
            end
        end,

        on_show =
            jellyfin_list_ui.install_controls,
        on_hide =
            jellyfin_list_ui.restore_controls,
    }

return QueueScreen
