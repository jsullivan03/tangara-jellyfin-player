-- SPDX-FileCopyrightText: 2025 Sam Lord <code@samlord.co.uk>
--
-- SPDX-License-Identifier: GPL-3.0-only

local lvgl = require("lvgl")
local widgets = require("widgets")
local database = require("database")
local sd_card = require("sd_card")
local backstack = require("backstack")
local browser = require("browser")
local playing = require("playing")
local styles = require("styles")
local filesystem = require("filesystem")
local screen = require("screen")
local font = require("font")
local theme = require("theme")
local img = require("images")
local playback = require("playback")
local queue = require("queue")
local table_iterator = require("table_iterator")


return screen:new {
  create_ui = function(self)
    self.root = lvgl.Object(nil, {
      flex = {
        flex_direction = "column",
        flex_wrap = "wrap",
        justify_content = "flex-start",
        align_items = "flex-start",
        align_content = "flex-start"
      },
      w = lvgl.HOR_RES(),
      h = lvgl.VER_RES()
    })
    self.root:center()

    self.status_bar = widgets.StatusBar(self, {
      back_cb = backstack.pop,
      title = self.title
    })

    local header = self.root:Object {
      flex = {
        flex_direction = "column",
        flex_wrap = "wrap",
        justify_content = "flex-start",
        align_items = "flex-start",
        align_content = "flex-start"
      },
      w = lvgl.HOR_RES(),
      h = lvgl.SIZE_CONTENT,
      pad_left = 4,
      pad_right = 4,
      pad_bottom = 2,
      scrollbar_mode = lvgl.SCROLLBAR_MODE.OFF
    }
    theme.set_subject(header, "header")

    if self.breadcrumb then
      header:Label {
        text = self.breadcrumb,
        text_font = font.fusion_10
      }
    end

    local playlists = {}
    -- Find playlists
    local fs_iter = filesystem.iterator("")
    for item in fs_iter do
      if
        item:filepath():match("%.playlist$") or
        item:filepath():match("%.m3u8?$") then
          table.insert(playlists, item)
      end
    end

    widgets.InfiniteList(self.root, table_iterator:create(playlists), {
      focus_first_item = true,
      callback = function(item)
        return function()
          queue.open_playlist(item:filepath())
          playback.playing:set(true)
          backstack.push(playing:new())
        end
      end
    })
  end
}


