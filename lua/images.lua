-- SPDX-FileCopyrightText: 2023 jacqueline <me@jacqueline.id.au>
--
-- SPDX-License-Identifier: GPL-3.0-only

local lvgl = require("lvgl")

local img = {
  back = lvgl.ImgData("//lua/img/back.png"),
  play = lvgl.ImgData("//lua/img/play.png"),
  play_circ = lvgl.ImgData("//lua/img/playcirc.png"),
  play_small = lvgl.ImgData("//lua/img/play_small.png"),
  pause = lvgl.ImgData("//lua/img/pause.png"),
  pause_circ = lvgl.ImgData("//lua/img/pausecirc.png"),
  enqueue = lvgl.ImgData("//lua/img/enqueue.png"),
  shuffleplay = lvgl.ImgData("//lua/img/shuffleplay.png"),
  next = lvgl.ImgData("//lua/img/next.png"),
  prev = lvgl.ImgData("//lua/img/prev.png"),
  shuffle = lvgl.ImgData("//lua/img/shuffle.png"),
  shuffle_off = lvgl.ImgData("//lua/img/shuffle_off.png"),
  repeat_track = lvgl.ImgData("//lua/img/repeat.png"),
  repeat_off = lvgl.ImgData("//lua/img/repeat_off.png"),
  repeat_queue = lvgl.ImgData("//lua/img/repeat_queue.png"),
  queue = lvgl.ImgData("//lua/img/queue.png"),
  files = lvgl.ImgData("//lua/img/files.png"),
  settings = lvgl.ImgData("//lua/img/settings.png"),
  chevron = lvgl.ImgData("//lua/img/chevron.png"),
  usb = lvgl.ImgData("//lua/img/usb.png"),
  listened = lvgl.ImgData("//lua/img/listened.png"),
  unlistened = lvgl.ImgData("//lua/img/unlistened.png"),
  info = lvgl.ImgData("//lua/img/info.png"),
  menu = lvgl.ImgData("//lua/img/menu.png"),
  file_directory = lvgl.ImgData("//lua/img/file_icons/directory.png"),
  file_playlist = lvgl.ImgData("//lua/img/file_icons/playlist.png"),
  file_music = lvgl.ImgData("//lua/img/file_icons/music.png"),
  unknown = lvgl.ImgData("//lua/img/file_icons/unknown.png"),
}

return img
