-- SPDX-FileCopyrightText: 2023 jacqueline <me@jacqueline.id.au>
--
-- SPDX-License-Identifier: GPL-3.0-only

-- require() everything else needed for the main menu + global bindings. Do
-- this now instead of in init_ui because loading and parsing the scripts can
-- take a while.
local vol = require("volume")
local theme = require("theme")
local controls = require("controls")
local time = require("time")
local sd_card = require("sd_card")
local backstack = require("backstack")
local main_menu = require("main_menu")
local sync_runtime = require("sync_runtime")

local saved_theme = theme.theme_filename()
local res = theme.load_theme(saved_theme)
if not res then
  -- Set a default theme (in case the saved theme does not load)
  local default_theme = require("theme_light")
  theme.set(default_theme)
end

sync_runtime.start()

local lock_time = time.ticks()

-- Set up property bindings that are used across every screen.
GLOBAL_BINDINGS = {
  -- Show a compact side volume HUD while the display is awake. The lock
  -- switch is Tangara's pocket mode, so volume changes remain silent there.
  vol.current_pct:bind(function(pct)
    require("volume_hud").show(pct)
  end),
  -- When the device has been locked for a while, default to showing the now
  -- playing screen after unlocking.
  controls.lock_switch:bind(function(locked)
    if locked then
      lock_time = time.ticks()
      collectgarbage()
    elseif time.ticks() - lock_time > 8000 then
      local queue = require("queue")
      if queue.size:get() > 0 then
        require("playing"):push_if_not_shown()
      end
    end
  end),
  controls.wheel_scheme:bind(function()
    -- Set up a shortcut for jumping straight to the 'now playing' screen.
    -- Implemented as a binding so that the shortcut is still applied even if
    -- the control scheme is changed at runtime.
    local hooks = controls.hooks()
    local input_method = hooks.wheel or hooks.dpad
    if input_method and input_method.right then
      input_method.right.long_press = function()
        local local_session =
          require("jellyfin_playback_session")

        if not local_session.open_now_playing() then
          require("playing"):push_if_not_shown()
        end
      end
    end
  end),
  sd_card.mounted:bind(function(mounted)
    backstack.reset(main_menu:new())
  end),
}
