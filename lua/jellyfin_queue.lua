local jellyfin_list_ui =
    require("jellyfin_list_ui")
local jellyfin_playback =
    require("jellyfin_playback")
local jellyfin_local_index =
    require("jellyfin_local_index")
local jellyfin_track_identity =
    require("jellyfin_track_identity")
local jellyfin_virtual_list =
    require("jellyfin_virtual_list")
local lvgl = require("lvgl")
local playback = require("playback")
local queue = require("queue")
local screen = require("screen")
local palette =
    require("jellyfin_theme").current()

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
        local stable =
            jellyfin_track_identity.stable_id(
                track
            )

        if stable then
            index[stable] = artwork
        end

        if type(track.id) == "string" then
            index[track.id] = artwork
        end

        if type(track.jellyfin_id) == "string" then
            index[track.jellyfin_id] = artwork
        end

        if type(track.key) == "string" then
            index[track.key] = artwork
        end

        if type(track.track_key) == "string" then
            index[track.track_key] = artwork
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

    if artist ~= "" then
        return artist
    end

    return
        entry and entry.album or ""
end

-- The queue marker is intentionally a low-resolution three-bar meter, but
-- it still needs enough temporal resolution to read as "playing."  The
-- previous 650 ms target period changed the pattern only about 1.5 times per
-- second, and interpolating five or fewer integer pixels made it appear nearly
-- frozen.  Ten smoothly stepped frames at roughly 11 fps remain inexpensive
-- (three tiny LVGL objects) while looking active on both simulator and device.
local VISUALIZER_PATTERNS = {
    {5, 12, 8},
    {7, 14, 6},
    {10, 15, 5},
    {13, 13, 7},
    {15, 10, 10},
    {13, 7, 13},
    {10, 5, 15},
    {7, 6, 13},
    {5, 9, 10},
    {6, 12, 7},
}

local VISUALIZER_PERIOD_MS = 90

local function add_queue_visualizer(model)
    local artwork =
        model and model.artwork
    local frame =
        artwork and artwork.frame

    if not frame then
        return
    end

    local bars = {}
    local bar_heights = {}

    for index = 1, 3 do
        local bar = frame:Object {
            x = 3 + (index - 1) * 5,
            y = 14,
            w = 3,
            h = 3,
            pad_all = 0,
            border_width = 0,
            shadow_width = 0,
            radius = 1,
            bg_color = palette.accent,
            bg_opa = 255,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        }

        bar:clear_flag(
            lvgl.FLAG.CLICKABLE
        )
        bar:clear_flag(
            lvgl.FLAG.SCROLLABLE
        )
        bar:add_flag(
            lvgl.FLAG.HIDDEN
        )
        bars[index] = bar
        bar_heights[index] = 3
    end

    model.queue_visualizer_bars = bars
    model.queue_visualizer_heights =
        bar_heights
    model.queue_visualizer_active = false

    function model:set_queue_current(current)
        local active = current == true
        self.queue_visualizer_active = active

        if artwork.image then
            if active then
                artwork.image:add_flag(
                    lvgl.FLAG.HIDDEN
                )
            elseif not artwork.placeholder_visible then
                artwork.image:clear_flag(
                    lvgl.FLAG.HIDDEN
                )
            end
        end

        if artwork.placeholder_image then
            if active or
                not artwork.placeholder_visible then
                artwork.placeholder_image:add_flag(
                    lvgl.FLAG.HIDDEN
                )
            else
                artwork.placeholder_image:clear_flag(
                    lvgl.FLAG.HIDDEN
                )
            end
        end

        frame:set {
            shadow_width = 0,
            bg_color = palette.overlay,
            bg_opa = active and 255 or 0,
        }

        for _, bar in ipairs(bars) do
            if active then
                bar:clear_flag(
                    lvgl.FLAG.HIDDEN
                )
            else
                bar:add_flag(
                    lvgl.FLAG.HIDDEN
                )
            end
        end

        if active then
            self:update_queue_visualizer(
                1,
                true
            )
        end
    end

    function model:update_queue_visualizer(
        phase,
        immediate
    )
        if not self.queue_visualizer_active then
            return
        end

        local pattern =
            VISUALIZER_PATTERNS[
                ((phase - 1) %
                    #VISUALIZER_PATTERNS) + 1
            ]

        for index, height in ipairs(pattern) do
            local bar = bars[index]

            bar_heights[index] = height
            bar:set {
                y = 17 - height,
                h = height,
            }
        end
    end
end

local function retire_binding(owner, name)
    local binding = owner[name]

    if binding then
        pcall(
            function()
                if type(binding.unbind) ==
                        "function" then
                    binding:unbind()
                end
            end
        )
    end

    owner[name] = nil
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
                        on_click =
                            function(entry)
                                local queue_index =
                                    entry and
                                    tonumber(
                                        entry.queue_index
                                    )

                                if not queue_index then
                                    return
                                end

                                -- Jump within the already-open playlist using
                                -- the native source position. Never rebuild
                                -- the playlist or use shuffled display_index.
                                queue.position:set(
                                    queue_index
                                )
                                playback.playing:set(
                                    true
                                )
                            end,
                        create_row =
                            function(owner, entry)
                                local model =
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

                                add_queue_visualizer(
                                    model
                                )
                                model:set_queue_current(
                                    entry.current
                                )

                                return model
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
                                model:set_queue_current(
                                    entry.current
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

            self.queue_visualizer_phase = 1
            self.queue_visualizer_timer =
                lvgl.Timer {
                    period =
                        VISUALIZER_PERIOD_MS,
                    cb = function()
                        if not self.ui_active then
                            return
                        end

                        self.queue_visualizer_phase =
                            self.queue_visualizer_phase + 1

                        for _, model in ipairs(
                            self.virtual_queue_list.pool or {}
                        ) do
                            if type(
                                model.update_queue_visualizer
                            ) == "function" then
                                model:update_queue_visualizer(
                                    self.queue_visualizer_phase
                                )
                            end
                        end
                    end,
                }
            self.queue_visualizer_timer:pause()

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
                    current_visualizer =
                        self.virtual_queue_list
                            :model_for_index(
                                tonumber(
                                    jellyfin_playback
                                        .queue_view()
                                        .position
                                ) or 1
                            ) and
                        self.virtual_queue_list
                            :model_for_index(
                                tonumber(
                                    jellyfin_playback
                                        .queue_view()
                                        .position
                                ) or 1
                            )
                            .queue_visualizer_active == true,
                }
            end
        end,

        on_show = function(self)
            jellyfin_list_ui
                .install_controls(self)

            if self.queue_visualizer_timer then
                self.queue_visualizer_timer:resume()
            end
        end,
        on_hide = function(self)
            if self.queue_visualizer_timer then
                self.queue_visualizer_timer:pause()
            end

            jellyfin_list_ui
                .restore_controls(self)
        end,
        on_destroy = function(self)
            if self.queue_visualizer_timer then
                self.queue_visualizer_timer:delete()
                self.queue_visualizer_timer = nil
            end

            retire_binding(
                self,
                "queue_position_binding"
            )
            retire_binding(
                self,
                "queue_shuffle_binding"
            )
        end,
    }

return QueueScreen
