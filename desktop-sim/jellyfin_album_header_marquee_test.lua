package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
require("mocks").install(lvgl)

package.loaded["jellyfin_marquee"] = nil
package.loaded["jellyfin_list_ui"] = nil

local list_ui =
    require("jellyfin_list_ui")

local owner = {}
local long_album_name =
    "THE FIRST SOUND OF THE FUTURE PAST"

list_ui.create_root(
    owner,
    long_album_name
)

assert(
    owner.header_marquee and
        owner.header ==
            owner.header_marquee.view,
    "list header was not converted to the shared marquee controller"
)

owner.header_marquee:refresh(true)
owner.header_marquee:start()

assert(
    owner.header_marquee.measured == true and
        owner.header_marquee.overflow > 0 and
        owner.header_marquee.active == true,
    "long album header did not measure as an active scrolling marquee"
)

list_ui.restore_controls(owner)
assert(
    owner.header_marquee.active == false,
    "album header marquee did not stop when its screen hid"
)

print(
    "Long album names scroll in the centered list header and stop off-screen"
)
os.exit(0)
