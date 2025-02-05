-- SPDX-FileCopyrightText: 2025 Sam Lord <code@samlord.co.uk>
--
-- SPDX-License-Identifier: GPL-3.0-only

local lvgl = require("lvgl")
local widgets = require("widgets")
local backstack = require("backstack")
local playing = require("playing")
local filesystem = require("filesystem")
local screen = require("screen")
local font = require("font")
local theme = require("theme")
local playback = require("playback")
local queue = require("queue")
local playlist_iterator = require("playlist_iterator")
local img = require("images")


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

    local get_icon_func = function(item)
      if item:is_directory() then
        return img.file_directory
      else
        return img.file_playlist
      end
    end

    widgets.InfiniteList(self.root, playlist_iterator:create(self.iterator), {
      focus_first_item = true,
      get_icon = get_icon_func,
      callback = function(item)
        return function()
          if item:is_directory() then
            backstack.push(
              require("playlist_browser"):new {
                title = self.title,
                iterator = filesystem.iterator(item:filepath()),
                breadcrumb = item:filepath()
              })
          elseif
              playlist_iterator:is_playlist(item) then
            -- TODO: playlist viewer
            queue.open_playlist(item:filepath())
            playback.playing:set(true)
            backstack.push(playing:new())
          end
        end
      end
    })
  end
}
