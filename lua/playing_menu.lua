
-- SPDX-FileCopyrightText: 2025 ailurux <ailuruxx@gmail.com>
--
-- SPDX-License-Identifier: GPL-3.0-only

local lvgl = require("lvgl")
local widgets = require("widgets")
local backstack = require("backstack")
local font = require("font")
local playback = require("playback")
local queue = require("queue")
local screen = require("screen")
local theme = require("theme")
local track_info = require("track_info")
local styles = require("styles")

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


    local menu_items = lvgl.List(self.root, {
      w = lvgl.PCT(100),
      h = lvgl.PCT(100),
      flex_grow = 1,
    })

    local info_btn = menu_items:add_btn(nil, "Track Info")
    info_btn:onClicked(function()
      backstack.push(track_info:new())
    end)
    info_btn:add_style(styles.list_item)

    local current_artist = nil
    local album_artist = nil
    local current_album = nil

    local artist_btn = menu_items:add_btn(nil, "Go To Artist")
    artist_btn:add_style(styles.list_item)
    artist_btn:onClicked(function()
      local found_iter = nil
      local media_type = nil
      for _, idx in ipairs(database.indexes()) do
        if idx:id() == database.IndexTypes.ALL_ARTISTS then
          -- Find the sub-index for this artist.
          local artist_iter = idx:iter()
          -- Workaround for lack of pairs/ipairs on these iterators.
          local artist_record = artist_iter:next()
          while artist_record do
            if artist_record:title() == current_artist then
              found_iter = artist_record:contents()
              media_type = idx:type()
              goto artist_done
            end
            artist_record = artist_iter:next()
          end
        end
      end
      ::artist_done::
      if found_iter then
        backstack.push(require("browser"):new {
          title = current_artist,
          iterator = found_iter,
          mediatype = media_type,
        })
      end
    end)

    local album_btn = menu_items:add_btn(nil, "Go To Album")
    album_btn:add_style(styles.list_item)
    album_btn:onClicked(function()
      local found_iter = nil
      local media_type = nil
      for _, idx in ipairs(database.indexes()) do
        if idx:id() == database.IndexTypes.ALBUMS_BY_ARTIST then
          -- Find the sub-index for this artist.
          local artist_iter = idx:iter()
          -- Workaround for lack of pairs/ipairs on these iterators.
          local artist_record = artist_iter:next()
          while artist_record do
            if artist_record:title() == album_artist then
              -- Find the sub-sub-index for this album.
              local album_iter = artist_record:contents()
              local album_record = album_iter:next()
              while album_record do
                if album_record:title() == current_album then
                  found_iter = album_record:contents()
                  media_type = idx:type()
                  goto album_done
                end
                album_record = album_iter:next()
              end
            end
            artist_record = artist_iter:next()
          end
        end
      end
      ::album_done::
      if found_iter then
        backstack.push(require("browser"):new {
          title = current_album,
          iterator = found_iter,
          mediatype = media_type,
        })
      end
    end)
    

    local clear_btn = menu_items:add_btn(nil, "Clear Queue")
    clear_btn:onClicked(function()
        queue.clear()
        backstack.pop()
    end)
    clear_btn:add_style(styles.list_item)

    self.bindings = self.bindings + {
      playback.track:bind(function(track)
        if not track then
          artist_btn:add_flag(lvgl.FLAG.HIDDEN)
          album_btn:add_flag(lvgl.FLAG.HIDDEN)
          return
        end
        current_artist = track.artist
        if not current_artist then
          artist_btn:add_flag(lvgl.FLAG.HIDDEN)
        else
          artist_btn:clear_flag(lvgl.FLAG.HIDDEN)
        end
        current_album = track.album
        if not current_album then
          album_btn:add_flag(lvgl.FLAG.HIDDEN)
        else
          album_btn:clear_flag(lvgl.FLAG.HIDDEN)
        end
        album_artist = track.album_artist
      end),
    }

  end
}
