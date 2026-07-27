package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")

require("mocks").install(lvgl)

local backstack =
    require("firmware_backstack")
local screen = require("screen")

package.loaded["backstack"] =
    backstack
package.preload["backstack"] =
    function()
        return backstack
    end

local test_screen =
    screen:new {
        create_ui = function(self)
            self.root =
                lvgl.Object(
                    nil,
                    {
                        w = 160,
                        h = 128,
                        pad_all = 0,
                        border_width = 0,
                    }
                )

            self.list =
                lvgl.List(
                    self.root,
                    {
                        x = 2,
                        y = 28,
                        w = 156,
                        h = 100,
                    }
                )

            self.list:set {
                pad_all = 0,
                pad_row = 1,
                border_width = 0,
                scrollbar_mode =
                    lvgl.SCROLLBAR_MODE.OFF,
            }

            self.first =
                self.list:Button {
                    w = lvgl.PCT(100),
                    h = 24,
                }

            for _ = 1, 8 do
                self.list:Button {
                    w = lvgl.PCT(100),
                    h = 24,
                }
            end
        end,
    }

backstack.reset(test_screen)
backstack.flush(8)

local before =
    test_screen.first:get_coords()

local result =
    test_screen.list:scroll_to {
        x = 0,
        y = 25,
        anim = false,
    }

assert(
    result == test_screen.list,
    "scroll_to should return the object"
)

backstack.flush(4)

local after =
    test_screen.first:get_coords()

assert(
    after.x1 == before.x1,
    "A y-only scroll unexpectedly changed x"
)

assert(
    after.y1 == before.y1 - 25,
    string.format(
        "Expected y to move by 25, before=%d after=%d",
        before.y1,
        after.y1
    )
)

print(
    "Luavgl vertical scroll binding passed"
)

os.exit(0)
