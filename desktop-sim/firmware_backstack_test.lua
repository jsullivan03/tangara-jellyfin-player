package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
local simulator = require("mocks").install(lvgl)
local backstack = require("firmware_backstack")
local screen = require("screen")

package.loaded["backstack"] = backstack
package.preload["backstack"] = function()
    return backstack
end

local events = {}

local function record(value)
    table.insert(events, value)
end

local function test_screen(name)
    return screen:new {
        create_ui = function(self)
            record("create:" .. name)

            self.root = lvgl.Object(
                nil,
                {
                    w = 160,
                    h = 128,
                    pad_all = 0,
                    border_width = 0,
                }
            )

            self.button = self.root:Button {
                x = 4,
                y = 4,
                w = 80,
                h = 24,
            }

            lvgl.group.get_default():add_obj(
                self.button
            )
            lvgl.group.focus_obj(
                self.button
            )
        end,

        on_show = function()
            record("show:" .. name)
        end,

        on_hide = function()
            record("hide:" .. name)
        end,
    }
end

local first = test_screen("first")
local second = test_screen("second")

backstack.reset(first)
backstack.flush(6)

assert(backstack.current() == first)
assert(backstack.depth() == 0)
assert(backstack.is_focused(first.button))

backstack.push(second)
backstack.flush(6)

assert(backstack.current() == second)
assert(backstack.depth() == 1)
assert(backstack.is_focused(second.button))

backstack.pop()
backstack.flush(6)

assert(backstack.current() == first)
assert(backstack.depth() == 0)
assert(backstack.is_focused(first.button))

local expected = {
    "create:first",
    "show:first",
    "create:second",
    "hide:first",
    "show:second",
    "hide:second",
    "show:first",
}

assert(#events == #expected)

for index, value in ipairs(expected) do
    assert(
        events[index] == value,
        string.format(
            "Lifecycle mismatch at %d: expected %s, got %s",
            index,
            value,
            tostring(events[index])
        )
    )
end

print(
    "Firmware-parity screen lifecycle and per-screen focus groups passed"
)

os.exit(0)
