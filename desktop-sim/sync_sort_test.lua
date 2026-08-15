package.path =
    "lua/?.lua;" ..
    package.path

local fixture_root =
    os.tmpname() .. "-sync-sort"
os.remove(fixture_root)
assert(
    os.execute(
        "mkdir -p " .. fixture_root
    )
)

package.loaded["device"] = {
    storage_root = function()
        return fixture_root
    end,
}
package.loaded["sync_sort"] = nil
local sort = require("sync_sort")

assert(sort.current("search") == "relevance")
assert(sort.current("albums") == "title_asc")
assert(sort.current("tracks") == "title_asc")
assert(sort.current("downloads") == "status")
assert(#sort.modes("albums") == 2)
assert(sort.modes("albums")[1] == "alpha")
assert(sort.modes("albums")[2] == "recent")
assert(#sort.modes("tracks") == 2)
assert(sort.modes("tracks")[1] == "alpha")
assert(sort.modes("tracks")[2] == "recent")

local initial = assert(sort.selection("tracks"))
assert(initial.method == "alpha")
assert(initial.label == "A-Z")
assert(initial.alpha_label == "A-Z")
assert(initial.recent_label == "New")

local z_to_a =
    assert(sort.toggle("tracks", "alpha"))
assert(z_to_a.method == "alpha")
assert(z_to_a.label == "Z-A")
assert(sort.current("tracks") == "title_desc")
local a_to_z =
    assert(sort.toggle("tracks", "alpha"))
assert(a_to_z.label == "A-Z")
assert(sort.current("tracks") == "title_asc")

local old =
    assert(sort.toggle("tracks", "recent"))
assert(old.method == "recent")
assert(old.label == "Old")
assert(sort.current("tracks") == "date_added_asc")
local new =
    assert(sort.toggle("tracks", "recent"))
assert(new.label == "New")
assert(sort.current("tracks") == "date_added")

assert(sort.set("tracks", "title_asc"))
assert(sort.set("albums", "date_added"))
assert(not sort.set("albums", "artist"))
assert(not sort.set("tracks", "artist"))

package.loaded["sync_sort"] = nil
sort = require("sync_sort")
assert(
    sort.current("albums") ==
        "date_added",
    "confirmed Date-added preference was not retained"
)
assert(
    sort.current("tracks") ==
        "title_asc",
    "confirmed A-Z preference was not retained"
)

local preference_path =
    fixture_root ..
    "/.tangara_sync_sort.json"
local legacy = assert(
    io.open(preference_path, "wb")
)
legacy:write(
    '{"schema_version":4,' ..
    '"albums":{' ..
        '"field":"recent",' ..
        '"alpha_descending":true,' ..
        '"recent_descending":false},' ..
    '"tracks":{' ..
        '"field":"recent",' ..
        '"alpha_descending":true,' ..
        '"recent_descending":false}}'
)
legacy:close()
package.loaded["sync_sort"] = nil
sort = require("sync_sort")
assert(
    sort.current("albums") ==
        "title_asc" and
        sort.current("tracks") ==
            "title_asc",
    "schema-4 Old preferences did not receive the one-time A-Z migration"
)
local migrated = assert(
    io.open(preference_path, "rb")
)
local migrated_contents =
    migrated:read("*a")
migrated:close()
assert(
    migrated_contents:find(
        '"schema_version":5',
        1,
        true
    ),
    "sort schema migration was not persisted"
)

local title_items = {
    {
        jellyfin_id = "charlie",
        title = "Charlie",
    },
    {
        jellyfin_id = "alpha-b",
        title = "Alpha",
    },
    {
        jellyfin_id = "alpha-a",
        title = "Alpha",
    },
}
local ascending =
    sort.apply(title_items, "title_asc")
assert(ascending[1].jellyfin_id == "alpha-a")
assert(ascending[2].jellyfin_id == "alpha-b")
assert(ascending[3].jellyfin_id == "charlie")
local descending =
    sort.apply(title_items, "title_desc")
assert(descending[1].jellyfin_id == "charlie")
assert(descending[2].jellyfin_id == "alpha-a")
assert(descending[3].jellyfin_id == "alpha-b")

local date_items = {
    {
        jellyfin_id = "old",
        title = "Old",
        date_created =
            "2025-01-01T00:00:00Z",
    },
    {
        jellyfin_id = "same-b",
        title = "Same B",
        date_created =
            "2026-07-30T12:00:00Z",
    },
    {
        jellyfin_id = "new",
        title = "New",
        date_created =
            "2026-07-31T00:00:00Z",
    },
    {
        jellyfin_id = "same-a",
        title = "Same A",
        date_created =
            "2026-07-30T12:00:00Z",
    },
}
local newest =
    sort.apply(date_items, "date_added")
assert(newest[1].jellyfin_id == "new")
assert(newest[2].jellyfin_id == "same-a")
assert(newest[3].jellyfin_id == "same-b")
assert(newest[4].jellyfin_id == "old")
local oldest =
    sort.apply(
        date_items,
        "date_added_asc"
    )
assert(oldest[1].jellyfin_id == "old")
assert(oldest[2].jellyfin_id == "same-a")
assert(oldest[3].jellyfin_id == "same-b")
assert(oldest[4].jellyfin_id == "new")

print(
    "Sync Title A-Z/Z-A and Date-added New/Old sorting passed"
)
os.execute("rm -rf " .. fixture_root)
os.exit(0)
