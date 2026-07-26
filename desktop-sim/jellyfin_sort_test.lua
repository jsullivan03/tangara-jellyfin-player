package.path =
    "lua/?.lua;" ..
    package.path

local jellyfin_sort =
    require("jellyfin_sort")

local sorted =
    jellyfin_sort.newest_added({
        {
            id = "old",
            date_created =
                "2026-07-20T10:00:00Z",
        },
        {
            id = "missing",
            date_created = "",
        },
        {
            id = "new",
            date_created =
                "2026-07-25T10:00:00Z",
        },
    })

assert(sorted[1].id == "new")
assert(sorted[2].id == "old")
assert(sorted[3].id == "missing")

print(
    "Jellyfin date-added sorting passed"
)

os.exit(0)

