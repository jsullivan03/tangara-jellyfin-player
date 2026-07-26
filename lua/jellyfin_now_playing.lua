local lvgl = require("lvgl")
local backstack = require("backstack")
local jellyfin_playback =
    require("jellyfin_playback")
local jellyfin_track_menu =
    require("jellyfin_track_menu")
local playback = require("playback")
local premium =
    require("premium_now_playing_screen")
local screen = require("screen")

local function format_time(value)
    value =
        math.max(
            0,
            math.floor(value or 0)
        )

    return string.format(
        "%d:%02d",
        math.floor(value / 60),
        value % 60
    )
end

local function artwork_value(
    active,
    name,
    fallback
)
    local item_artwork =
        active and
        active.item and
        active.item.artwork

    local track_artwork =
        active and
        active.track and
        active.track.artwork

    if type(item_artwork) == "table" and
        type(item_artwork[name]) ==
            "string" and
        item_artwork[name] ~= "" then
        return item_artwork[name]
    end

    if type(track_artwork) == "table" and
        type(track_artwork[name]) ==
            "string" and
        track_artwork[name] ~= "" then
        return track_artwork[name]
    end

    return fallback
end

local function corner_button(
    root,
    x,
    label_text,
    callback
)
    local button =
        root:Button {
            x = x,
            y = 2,
            w = 27,
            h = 19,
            pad_all = 0,
            radius = 5,
            border_width = 1,
            border_color = "#D8D9DE",
            bg_color = "#11131A",
            bg_opa = 215,
        }

    local label =
        button:Label {
            text = label_text,
            text_color = "#FFFFFF",
            text_font = font.fusion_10,
        }

    label:center()
    button:onClicked(callback)

    return button
end

return screen:new {
    create_ui = function(self)
        local active =
            jellyfin_playback.current()

        local track =
            active and active.track or {}

        local duration =
            tonumber(track.duration)
            or tonumber(
                active and
                active.item and
                active.item.duration
            )
            or 0

        self.view =
            premium.create {
                background =
                    artwork_value(
                        active,
                        "background",
                        "//lua/img/background_placeholder.png"
                    ),
                cover =
                    artwork_value(
                        active,
                        "cover",
                        "//lua/img/cover_placeholder.png"
                    ),
                title =
                    track.title or
                    "Nothing playing",
                artist =
                    track.artist or "",
                progress = 0,
                elapsed = "0:00",
                remaining =
                    format_time(duration),
            }

        self.root = self.view.root

        corner_button(
            self.root,
            2,
            "<",
            backstack.pop
        )

        local function open_menu()
            local current =
                jellyfin_playback.current()

            if not current or
                not current.track then
                return
            end

            backstack.push(
                jellyfin_track_menu:new {
                    track =
                        current.track,
                    collection_kind =
                        current.context
                            .collection_kind,
                    collection_id =
                        current.context
                            .collection_id,
                    entry_id =
                        current.context
                            .entry_id,
                }
            )
        end

        corner_button(
            self.root,
            131,
            "...",
            open_menu
        )

        self.root:onevent(
            lvgl.EVENT.LONG_PRESSED,
            open_menu
        )

        self.position_binding =
            playback.position:bind(
                function(position)
                    local current =
                        jellyfin_playback
                            .current()

                    local current_track =
                        current and
                        current.track or {}

                    local current_duration =
                        tonumber(
                            current_track.duration
                        )
                        or duration

                    local progress = 0

                    if current_duration > 0 then
                        progress =
                            math.max(
                                0,
                                math.min(
                                    1,
                                    (
                                        position or 0
                                    ) /
                                    current_duration
                                )
                            )
                    end

                    self.view:update {
                        progress = progress,
                        elapsed =
                            format_time(position),
                        remaining =
                            format_time(
                                math.max(
                                    0,
                                    current_duration -
                                    (position or 0)
                                )
                            ),
                    }
                end
            )
    end,
}

