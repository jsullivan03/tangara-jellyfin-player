package.path =
    "lua/?.lua;" ..
    "desktop-sim/?.lua;" ..
    package.path

local json = require("json")
local pending = nil
local response = nil
local catalog_request = nil
local artist_request = nil

package.loaded["device_identity"] = {
    id = function()
        return "device-日本"
    end,
    catalog_path = function(
        view,
        cursor,
        limit,
        options
    )
        catalog_request = {
            view = view,
            cursor = cursor,
            limit = limit,
            sort =
                options and options.sort,
            direction =
                options and
                options.direction,
            cache_key =
                options and
                options.cache_key,
        }
        return "/catalog/" .. view
    end,
    download_requests_path = function()
        return "/download-requests"
    end,
    jellyfin_search_path = function()
        return "/sync/search/jellyfin"
    end,
    external_search_path = function()
        return "/sync/search/external"
    end,
    downloads_path = function()
        return "/downloads"
    end,
    external_jobs_path = function()
        return "/external/jobs"
    end,
    artist_releases_path = function(
        key,
        name,
        context
    )
        artist_request = {
            key = key,
            name = name,
            context = context,
        }
        return "/artists/" .. key
    end,
}

package.loaded["sync_client"] = {
    busy = function()
        return pending ~= nil
    end,
    get = function(path, owner)
        pending = {
            method = "GET",
            path = path,
            owner = owner,
        }
        return true
    end,
    post = function(path, body, owner)
        pending = {
            method = "POST",
            path = path,
            body = body,
            owner = owner,
        }
        return true
    end,
    poll = function(owner)
        if not pending or
            pending.owner ~= owner then
            return nil
        end

        pending = nil
        return response
    end,
}

package.loaded["time"] = {
    ticks = function()
        return 12345
    end,
}

package.loaded["sync_catalog"] = nil
local catalog = require("sync_catalog")

assert(catalog.start("albums"))
assert(pending.path == "/catalog/albums")

response = {
    ok = true,
    status = 200,
    body =
        '{"items":[{"jellyfin_id":' ..
        '"album-日本","kind":"album",' ..
        '"title":"作品","artist":"音楽家",' ..
        '"artists":["音楽家","客演"],' ..
        '"artist_ids":["artist-main",' ..
        '"artist-guest"]}]}',
}

local result = assert(catalog.poll())
assert(result.ok and result.kind == "catalog")
assert(
    catalog.cached("albums").items[1]
        .title == "作品"
)
local local_releases =
    catalog.local_artist_releases {
        artist = "客演",
        jellyfin_artist_id =
            "artist-guest",
    }
assert(
    local_releases and
        local_releases.groups[1].id ==
            "features" and
        local_releases.groups[1]
            .items[1].jellyfin_id ==
            "album-日本"
)

assert(
    catalog.artist_releases {
        key =
            "opaque-album-id",
        external_item_key =
            "opaque-album-id",
        artist_key =
            "opaque-artist-id",
        jellyfin_id =
            "album-日本",
        jellyfin_artist_id =
            "artist-guest",
        title = "作品",
        artist = "客演",
    }
)
assert(
    artist_request.key ==
        "opaque-artist-id",
    "album opaque ID was used as an artist ID"
)
assert(
    artist_request.context
        .external_item_key ==
        "opaque-album-id"
)
assert(
    artist_request.context
        .jellyfin_artist_id ==
        "artist-guest"
)
assert(
    artist_request.context
        .release_title ==
        "作品"
)
response = {
    ok = true,
    status = 200,
    body =
        '{"resolution":"resolved",' ..
        '"artist":{"key":' ..
        '"opaque-artist-id",' ..
        '"name":"客演"},' ..
        '"groups":[]}',
}
assert(catalog.poll().kind == "artist")

assert(catalog.search(
    "音楽家",
    {"album"},
    "relevance"
))
assert(
    pending.path ==
        "/sync/search/jellyfin"
)
response = {
    ok = true,
    status = 200,
    body =
        '{"items":[{"jellyfin_id":' ..
        '"album-日本","kind":"album",' ..
        '"title":"作品","artist":"音楽家",' ..
        '"device":{"state":"server_only"}}]}',
}
result = assert(catalog.poll())
assert(
    result.kind ==
        "search_jellyfin" and
    catalog.cached_key(
        "search:音楽家"
    ).external_search_pending == true,
    "Jellyfin results were not exposed before external completion"
)
assert(
    pending.path ==
        "/sync/search/external"
)
response = {
    ok = false,
    status = 0,
    body = "",
    error = "external timeout",
}
result = assert(catalog.poll())
assert(
    result.kind ==
        "search_external" and
        #result.payload.items == 1 and
        result.payload
            .external_available ==
            false,
    "external timeout removed valid Jellyfin results"
)

local item = {
    jellyfin_id = "album-日本",
    kind = "album",
}

assert(catalog.queue(item))
assert(pending.method == "POST")
local body = json.decode(pending.body)
assert(body.jellyfin_item_id == "album-日本")
assert(body.kind == "album")
assert(
    body.idempotency_key ==
        "device-日本:album:album-日本:12345"
)

response = {
    ok = true,
    status = 202,
    body =
        '{"request":{"id":"request-1",' ..
        '"state":"queued"}}',
}

result = assert(catalog.poll())
assert(result.ok and result.kind == "queue")
assert(
    result.payload.request.state ==
        "queued"
)
assert(item.device.state == "queued")

assert(catalog.start(
    "albums",
    nil,
    20,
    {
        sort = "date_added",
        direction = "descending",
        cache_key = "new",
    }
))
assert(catalog_request.view == "albums")
assert(catalog_request.limit == 20)
assert(
    catalog_request.sort ==
        "date_added"
)
assert(
    catalog_request.direction ==
        "descending"
)
assert(catalog_request.cache_key == "new")
response = {
    ok = true,
    status = 200,
    body =
        '{"view":"albums",' ..
        '"sort":"date_added",' ..
        '"direction":"descending",' ..
        '"items":[{"jellyfin_id":"new-1",' ..
        '"kind":"album","title":"新作"}]}',
}

result = assert(catalog.poll())
assert(
    result.ok and
        catalog.cached("new").items[1]
            .jellyfin_id ==
            "new-1"
)

assert(catalog.start(
    "albums",
    nil,
    50,
    {
        sort = "title",
        direction = "ascending",
        generation = 7,
    }
))
response = {
    ok = true,
    status = 200,
    body =
        '{"items":[' ..
        '{"jellyfin_id":"page-1"},' ..
        '{"jellyfin_id":"page-2"}' ..
        '],"total_count":4,' ..
        '"next_cursor":"cursor-2"}',
}
result = assert(catalog.poll())
assert(result.kind == "catalog")
assert(result.payload.generation == 7)
assert(result.payload.total_count == 4)

assert(catalog.start(
    "albums",
    "cursor-2",
    50,
    {
        sort = "title",
        direction = "ascending",
        generation = 7,
    }
))
response = {
    ok = true,
    status = 200,
    body =
        '{"items":[' ..
        '{"jellyfin_id":"page-2"},' ..
        '{"jellyfin_id":"page-3"}' ..
        '],"total_count":4,' ..
        '"next_cursor":"cursor-3"}',
}
result = assert(catalog.poll())
assert(#result.payload.items == 3)
assert(
    result.payload.items[3].jellyfin_id ==
        "page-3",
    "catalog page boundary duplicate was retained"
)

assert(catalog.start(
    "albums",
    "cursor-3",
    50,
    {
        sort = "title",
        direction = "ascending",
        generation = 6,
    }
))
response = {
    ok = true,
    status = 200,
    body =
        '{"items":[' ..
        '{"jellyfin_id":"stale-page"}' ..
        '],"total_count":4}',
}
result = assert(catalog.poll())
assert(
    result.kind == "catalog_stale" and
        result.stale == true,
    "stale catalog generation was appended"
)
assert(#catalog.cached("albums").items == 3)

assert(catalog.start(
    "albums",
    "cursor-3",
    50,
    {
        sort = "title",
        direction = "ascending",
        generation = 7,
    }
))
response = {
    ok = true,
    status = 200,
    body =
        '{"items":[' ..
        '{"jellyfin_id":"page-4"}' ..
        '],"total_count":4,' ..
        '"next_cursor":null}',
}
result = assert(catalog.poll())
assert(#result.payload.items == 4)
assert(
    type(result.payload.next_cursor) ~= "string"
)
assert(result.payload.total_count == 4)

assert(catalog.start("tracks"))
response = {
    ok = true,
    status = 200,
    body = "<html>not JSON</html>",
}

result = assert(catalog.poll())
assert(not result.ok)
assert(
    result.error ==
        "server returned invalid JSON"
)


assert(catalog.search(
    "作品",
    {"album", "track"},
    "relevance"
))
assert(
    pending.path ==
        "/sync/search/jellyfin"
)
body = json.decode(pending.body)
assert(body.query == "作品")
assert(body.kinds[1] == "album")
response = {
    ok = true,
    status = 200,
    body =
        '{"items":[{"jellyfin_id":"album-1",' ..
        '"kind":"album","title":"作品",' ..
        '"artist":"音楽家",' ..
        '"device":{"state":"server_only"}}]}',
}
result = assert(catalog.poll())
assert(
    result.ok and
        result.kind ==
            "search_jellyfin"
)
assert(
    pending.path ==
        "/sync/search/external"
)
response = {
    ok = true,
    status = 200,
    body =
        '{"items":[' ..
        '{"key":"opaque-external-1",' ..
        '"jellyfin_id":"album-1",' ..
        '"kind":"album","title":"作品",' ..
        '"artist_key":"opaque-artist-1",' ..
        '"external_item_key":' ..
        '"opaque-external-1"},' ..
        '{"key":"opaque-external-2",' ..
        '"kind":"album","title":"外部"}' ..
        '],"external_available":true}',
}
result = assert(catalog.poll())
assert(
    result.ok and
        result.kind ==
            "search_external"
)
assert(
    #catalog.cached_key(
        "search:作品"
    ).items == 2,
    "associated external result duplicated its Jellyfin row"
)
assert(
    catalog.cached_key(
        "search:作品"
    ).items[1].external_key ==
        "opaque-external-1"
)
assert(
    catalog.cached_key(
        "search:作品"
    ).items[1].artist_key ==
        "opaque-artist-1"
)

assert(catalog.search(
    "old",
    {"album"},
    "relevance"
))
assert(
    pending.path ==
        "/sync/search/jellyfin"
)
assert(catalog.search(
    "new",
    {"album"},
    "relevance"
))
response = {
    ok = true,
    status = 200,
    body =
        '{"items":[{"jellyfin_id":"old-1",' ..
        '"kind":"album","title":"Old"}]}',
}
result = assert(catalog.poll())
assert(
    result.kind ==
        "search_stale" and
        result.stale == true,
    "older-query response was not rejected"
)
assert(
    pending.path ==
        "/sync/search/jellyfin"
)

response = {
    ok = true,
    status = 200,
    body =
        '{"items":[{"jellyfin_id":"new-1",' ..
        '"kind":"album","title":"New"}]}',
}
result = assert(catalog.poll())
assert(
    result.kind ==
        "search_jellyfin"
)
assert(
    catalog.cached_key(
        "search:old"
    ) == nil
)
assert(
    catalog.cached_key(
        "search:new"
    ).items[1].jellyfin_id ==
        "new-1"
)
assert(
    pending.path ==
        "/sync/search/external"
)

response = {
    ok = true,
    status = 200,
    body =
        '{"items":[],' ..
        '"external_available":false,' ..
        '"external_message":' ..
        '"External search unavailable"}',
}
result = assert(catalog.poll())
assert(
    result.kind ==
        "search_external"
)
assert(
    #catalog.cached_key(
        "search:new"
    ).items == 1
)
assert(
    catalog.cached_key(
        "search:new"
    ).external_available == false
)

local provider = {
    key = "opaque-external-1",
    kind = "album",
}
assert(
    catalog.external_job(
        provider,
        "jellyfin_and_device"
    )
)
body = json.decode(pending.body)
assert(
    body.destination ==
        "jellyfin_and_device"
)
assert(body.device_id == "device-日本")
response = {
    ok = true,
    status = 202,
    body =
        '{"job":{"id":"job-1",' ..
        '"state":"external_queued"}}',
}
result = assert(catalog.poll())
assert(
    result.payload.job.state ==
        "external_queued"
)

local function astroworld_jellyfin(
    artwork
)
    return {
        jellyfin_id =
            "jellyfin-astroworld",
        kind = "album",
        title = "ASTROWORLD",
        artist = "Cactus Jack",
        artists = {
            "Cactus Jack",
            "Travis Scott",
        },
        year = 2018,
        artwork_path =
            artwork ~= false and
            "/jellyfin/astroworld" or
            "",
        artwork_revision =
            artwork ~= false and
            "jellyfin-revision" or
            "",
        artwork_source = "jellyfin",
        device = {
            state = "server_only",
        },
    }
end

local function astroworld_external(
    artist,
    artwork
)
    artist = artist or
        "Travis Scott"
    return {
        key =
            "0123456789abcdef" ..
            "0123456789abcdef",
        kind = "album",
        title = "ASTROWORLD",
        artist = artist,
        artists = {artist},
        year = 2018,
        artwork_path =
            artwork ~= false and
            "/external/astroworld" or
            "",
        artwork_revision =
            "external-revision",
        artwork_source = "external",
        availability = "available",
    }
end

local jellyfin_first =
    catalog
        ._merge_search_payloads_for_test(
            {
                items = {
                    astroworld_jellyfin(
                        true
                    ),
                },
            },
            {
                items = {
                    astroworld_external(),
                },
                external_available = true,
            }
        )
assert(#jellyfin_first.items == 1)
assert(
    jellyfin_first.items[1]
        .jellyfin_id ==
        "jellyfin-astroworld"
)
assert(
    jellyfin_first.items[1]
        .device.state ==
        "server_only"
)
assert(
    jellyfin_first.items[1]
        .artwork_path ==
        "/jellyfin/astroworld"
)

local external_first =
    catalog
        ._merge_search_payloads_for_test(
            {
                items = {
                    astroworld_external(),
                },
            },
            {
                items = {
                    astroworld_jellyfin(
                        true
                    ),
                },
                external_available = true,
            }
        )
assert(#external_first.items == 1)
assert(
    external_first.items[1]
        .jellyfin_id ==
        "jellyfin-astroworld"
)
assert(
    external_first.items[1]
        .device.state ==
        "server_only"
)
assert(
    external_first.items[1]
        .artwork_path ==
        "/jellyfin/astroworld"
)

local external_fallback =
    catalog
        ._merge_search_payloads_for_test(
            {
                items = {
                    astroworld_jellyfin(
                        false
                    ),
                },
            },
            {
                items = {
                    astroworld_external(),
                },
                external_available = true,
            }
        )
assert(
    external_fallback.items[1]
        .artwork_path ==
        "/external/astroworld"
)
assert(
    external_fallback.items[1]
        .artwork_source ==
        "external"
)

local incompatible =
    astroworld_external(
        "Unrelated Artist"
    )
incompatible.artists = {
    "Unrelated Artist",
}
local separate =
    catalog
        ._merge_search_payloads_for_test(
            {
                items = {
                    astroworld_jellyfin(),
                },
            },
            {
                items = {incompatible},
                external_available = true,
            }
        )
assert(
    #separate.items == 2,
    "incompatible ASTROWORLD artist was merged"
)

print(
    "Sync catalog client request and response model passed"
)
os.exit(0)
