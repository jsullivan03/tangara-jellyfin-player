package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
lvgl.ImgData = function(path)
    return path
end

require("mocks").install(lvgl)

local pushed = nil
package.loaded["backstack"] = {
    pop = function()
    end,
    push = function(page)
        pushed = page
    end,
}

package.loaded["jellyfin_text_entry"] = {
    new = function(options)
        return options
    end,
}

local renamed = nil
local deleted = nil
package.loaded["sync_operation_queue"] = {
    enqueue_rename_playlist =
        function(id, name)
            renamed = {id = id, name = name}
            return {}
        end,
    enqueue_delete_playlist =
        function(id)
            deleted = id
            return {}
        end,
}

package.loaded["jellyfin_navigation"] = {
    set_back = function()
    end,
    clear_back = function()
    end,
}

for _, name in ipairs({
    "jellyfin_marquee",
    "jellyfin_list_ui",
    "jellyfin_playlist_action_sheet",
}) do
    package.loaded[name] = nil
end

local list_ui = require("jellyfin_list_ui")
local playlist_sheet =
    require("jellyfin_playlist_action_sheet")

local owner = {}
list_ui.create_root(owner, "Playlists")
local row = list_ui.add_action_row(
    owner,
    "Playlist 1",
    {
        selection_id = "playlist-1",
    }
)
owner.first_row = row.object

for index = 2, 8 do
    list_ui.add_action_row(
        owner,
        "Playlist " .. tostring(index),
        {
            selection_id =
                "playlist-" .. tostring(index),
        }
    )
end

owner.request_playlist_rebuild = function(self)
    self.rebuild_requested = true
end

list_ui.install_controls(owner)
owner.list:scroll_to {
    x = 0,
    y = 60,
    anim = false,
}
local scroll_anchor_before =
    row.object:get_coords().y1
local sheet = playlist_sheet.attach(owner)

assert(sheet:open {
    id = "playlist-1",
    name = "Playlist 1",
})
assert(
    sheet:state().open and
        sheet:state().button_count == 2 and
        sheet:state().labels[1] ==
            "Rename playlist" and
        sheet:state().labels[2] ==
            "Delete playlist",
    "Playlist action sheet did not expose rename and delete"
)
assert(
    row.object:get_coords().y1 ==
        scroll_anchor_before,
    "Opening playlist actions changed the Playlists page scroll position"
)

assert(sheet:activate("rename"))
assert(
    pushed and
        pushed.title == "Rename playlist" and
        pushed.initial_value == "Playlist 1",
    "Rename did not open prefilled rotary text entry"
)
assert(pushed.on_submit("Renamed Mix"))
assert(
    renamed and
        renamed.id == "playlist-1" and
        renamed.name == "Renamed Mix" and
        owner.needs_playlist_rebuild == true,
    "Rename did not queue an offline playlist operation"
)
assert(
    row.object:get_coords().y1 ==
        scroll_anchor_before,
    "Closing playlist actions changed the Playlists page scroll position"
)

pushed = nil
assert(sheet:open {
    id = "playlist-1",
    name = "Playlist 1",
})
assert(sheet:activate("delete"))
assert(
    sheet:state().page == "confirm" and
        sheet:state().labels[1] == "Cancel" and
        sheet:state().labels[2] ==
            "Confirm delete",
    "Playlist delete did not require confirmation"
)
assert(sheet:activate("confirm_delete"))

lvgl.Timer {
    period = 25,
    repeat_count = 1,
    cb = function()
        local ok, failure = pcall(function()
            assert(
                deleted == "playlist-1" and
                    owner.rebuild_requested == true and
                    not sheet:state().open,
                "Confirmed delete did not queue offline removal and refresh the page"
            )

            list_ui.restore_controls(owner)
            print(
                "Playlist long-hold actions queue offline rename and confirmed delete"
            )
            os.exit(0)
        end)

        if not ok then
            io.stderr:write(tostring(failure), "\n")
            os.exit(1)
        end
    end,
}
