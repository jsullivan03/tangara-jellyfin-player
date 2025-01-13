-- SPDX-FileCopyrightText: 2024 jacqueline <me@jacqueline.id.au>
--
-- SPDX-License-Identifier: GPL-3.0-only

local backstack = require("backstack")
local font = require("font")
local lvgl = require("lvgl")
local playback = require("playback")
local screen = require("screen")
local widgets = require("widgets")

return screen:new {
  create_ui = function(self)
    self.root = lvgl.Object(nil, {
      flex = {
        flex_direction = "column",
        flex_wrap = "wrap",
        justify_content = "center",
        align_items = "center",
        align_content = "center",
      },
      w = lvgl.HOR_RES(),
      h = lvgl.VER_RES(),
    })
    self.root:center()

    self.status_bar = widgets.StatusBar(self, {
      back_cb = backstack.pop,
      transparent_bg = true,
    })

    local info = lvgl.List(self.root, {
      w = lvgl.PCT(100),
      h = lvgl.PCT(100),
      flex_grow = 1,
    })

    -- Use buttons so we can scroll through the list, and labels so we can
    -- change the text as the track changes.
    local label = function(text)
      local b = info:add_btn(nil, "")
      local ret = b:Label {
        w = lvgl.PCT(100),
        h = lvgl.SIZE_CONTENT,
        text = text,
        text_font = font.fusion_10,
        text_align = 1, -- left
      }
      return ret
    end

    local album_artist = label("Loading...")
    local genre = label("")
    local disc = label("")
    local tracknum = label("")
    local encoding = label("")
    local bitrate_kbps = label("")
    local sample_rate = label("")
    local num_channels = label("")
    local bits_per_sample = label("")
    local path = label("")

    self.bindings = self.bindings + {
      playback.track:bind(function(track)
        if not track then
          return
        end

        -- Genres are stored in a table of (genre, bool) pairs
        local function genres(tbl)
          local all = {}
          for item,_ in pairs(tbl) do
            table.insert(all, item)
          end
          return table.concat(all, ", ")
        end

        album_artist:set { text = "Album artist: " .. (track.album_artist or "") }
        genre:set { text = "Genre: " .. (track.genre and genres(track.genre) or "") }
        disc:set { text = "Disc: " .. (track.disc or "") }
        tracknum:set { text = "Track: " .. (track.track or "") }
        encoding:set { text = "Encoding: " .. (track.encoding or "") }
        bitrate_kbps:set { text = "Bitrate (kbps): " .. (track.bitrate_kbps or "") }
        sample_rate:set { text = "Sample rate: " .. (track.sample_rate or "") }
        num_channels:set { text = "Channels: " .. (track.num_channels or "") }
        bits_per_sample:set { text = "Bits per sample: " .. (track.bits_per_sample or "") }
        path:set { text = "Path: " .. (track.uri or "") }
      end),
    }
  end,
}
