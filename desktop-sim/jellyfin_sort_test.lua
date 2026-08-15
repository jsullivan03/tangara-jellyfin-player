package.path =
    "lua/?.lua;" ..
    package.path

local jellyfin_sort =
    require("jellyfin_sort")

local sorted =
    jellyfin_sort.newest_added({
        {
            id = "old",
            local_added_at =
                "2026-07-20T10:00:00Z",
            date_created =
                "2026-08-01T10:00:00Z",
        },
        {
            id = "missing",
            date_created = "",
        },
        {
            id = "new",
            local_added_at =
                "2026-07-25T10:00:00Z",
            date_created =
                "2026-07-01T10:00:00Z",
        },
    })

assert(sorted[1].id == "new")
assert(sorted[2].id == "old")
assert(sorted[3].id == "missing")


local device_sorted =
    jellyfin_sort.newest_added({
        {
            id = "source-newer",
            date_created =
                "2026-08-15T00:00:00Z",
        },
        {
            id = "device-new",
            local_downloaded_at = 12345,
            date_created =
                "2020-01-01T00:00:00Z",
        },
    })

assert(
    device_sorted[1].id == "device-new",
    "device download recency must outrank Jellyfin DateCreated for Local New"
)

print(
    "Local device-added sorting passed"
)

os.exit(0)

