package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

package.loaded["device"] = {
    storage_root = function()
        return "/storage"
    end,
}

local requested_variants = {}

package.loaded["device_identity"] = {
    media_path = function(item_id)
        return "/media/" .. item_id
    end,
    artwork_path = function(
        item_id,
        variant
    )
        table.insert(
            requested_variants,
            variant
        )
        return
            "/artwork/" ..
            item_id ..
            "/" ..
            variant
    end,
}

package.loaded["sync_client"] = {
    url = function(path)
        return "http://server" .. path
    end,
}

package.loaded["sync_reconcile"] = nil
local reconcile =
    require("sync_reconcile")

local shared_artwork = {
    thumbnail =
        "/.tangara-artwork/albums/album-sq28.png",
    thumbnail_item_id = "album-id",
    cover =
        "/.tangara-artwork/albums/album-sq66.png",
    cover_item_id = "album-id",
    background =
        "/.tangara-artwork/albums/album-bg160x128-v3.png",
    background_item_id = "album-id",
}

local manifest = {
    device = {id = "device"},
    items = {
        {
            jellyfin_id = "track-1",
            local_path = "/Music/track-1.flac",
            artwork = shared_artwork,
        },
        {
            jellyfin_id = "track-2",
            local_path = "/Music/track-2.flac",
            artwork = shared_artwork,
        },
    },
}

local plan, plan_error =
    reconcile.plan(
        manifest,
        {},
        function()
            return false
        end
    )

assert(plan, plan_error)
assert(
    plan.counts.download == 2 and
        plan.counts.artwork == 3 and
        plan.counts.actions == 5,
    "reconcile did not deduplicate all three album artwork variants"
)

local expected = {
    "thumbnail",
    "cover",
    "background",
}

for index, variant in ipairs(expected) do
    local action = plan.artwork[index]

    assert(
        action and
            action.artwork_variant ==
                variant and
            action.artwork_path ==
                "/artwork/album-id/" ..
                variant and
            action.artwork_url ==
                "http://server/artwork/album-id/" ..
                variant,
        "reconcile built the wrong " ..
            variant ..
            " artwork action"
    )

    assert(
        requested_variants[index] ==
            variant,
        "reconcile requested artwork variants in an unstable order"
    )
end

print(
    "Sync reconcile downloads thumbnail, cover, and uniform blurred background once per album"
)
os.exit(0)
