local device = require("device")
local device_identity = require("device_identity")
local sync_client = require("sync_client")
local sync_manifest = require("sync_manifest")

local M = {}

local function normalize_local_path(path)
    if type(path) ~= "string" or path == "" then
        return nil, "local path must be a non-empty string"
    end

    if path:sub(1, 1) ~= "/" then
        return nil, "local path must begin with /"
    end

    if path:find("\0", 1, true) then
        return nil, "local path contains a null byte"
    end

    if path:find("[\r\n]") then
        return nil, "local path contains a line break"
    end

    local segments = {}

    for segment in path:gmatch("[^/]+") do
        if segment == "." or segment == ".." then
            return nil, "local path contains an unsafe segment"
        end

        table.insert(segments, segment)
    end

    if #segments == 0 then
        return nil, "local path must identify a file"
    end

    return "/" .. table.concat(segments, "/")
end

M.normalize_local_path = normalize_local_path

local function storage_root()
    local root, root_error = device.storage_root()

    if type(root) ~= "string" or root == "" then
        return nil, root_error or "storage root is unavailable"
    end

    return root:gsub("/+$", "")
end

local function storage_path(root, local_path)
    if root == "" then
        return local_path
    end

    return root .. local_path
end

local function default_file_exists(path)
    local file = io.open(path, "rb")

    if not file then
        return false
    end

    file:close()
    return true
end

function M.plan(manifest, managed_paths, file_exists)
    local valid_manifest, manifest_error =
        sync_manifest.validate(manifest)

    if not valid_manifest then
        return nil, manifest_error
    end

    if managed_paths ~= nil and type(managed_paths) ~= "table" then
        return nil, "managed paths must be a table"
    end

    local root, root_error = storage_root()

    if not root then
        return nil, root_error
    end

    file_exists = file_exists or default_file_exists
    managed_paths = managed_paths or {}

    local plan = {
        keep = {},
        download = {},
        artwork = {},
        actions = {},
        delete = {},
    }

    local desired_paths = {}

    for index, item in ipairs(manifest.items) do
        if type(item) ~= "table" then
            return nil, "manifest item " .. index .. " must be an object"
        end

        local local_path, path_error =
            normalize_local_path(item.local_path)

        if not local_path then
            return nil,
                "manifest item " .. index .. ": " .. path_error
        end

        if desired_paths[local_path] then
            return nil, "duplicate manifest path: " .. local_path
        end

        local media_path, media_path_error =
            device_identity.media_path(item.jellyfin_id)

        if not media_path then
            return nil,
                "manifest item " .. index .. ": " ..
                media_path_error
        end

        desired_paths[local_path] =
            "media"

        local full_path =
            storage_path(root, local_path)

        local action = {
            kind = "media",
            local_path = local_path,
            storage_path = full_path,
            media_path = media_path,
            item = item,
        }

        if file_exists(full_path) then
            table.insert(plan.keep, action)
        else
            local media_url, media_url_error =
                sync_client.url(media_path)

            if not media_url then
                return nil,
                    "manifest item " .. index .. ": " ..
                    media_url_error
            end

            action.media_url = media_url
            table.insert(plan.download, action)
            table.insert(plan.actions, action)
        end

        local artwork = item.artwork

        if type(artwork) == "table" then
            for _, artwork_variant in ipairs({
                {
                    path_key = "thumbnail",
                    item_id_key =
                        "thumbnail_item_id",
                    variant = "thumbnail",
                },
                {
                    path_key = "cover",
                    item_id_key =
                        "cover_item_id",
                    variant = "cover",
                },
                {
                    path_key = "background",
                    item_id_key =
                        "background_item_id",
                    variant = "background",
                },
            }) do
                local artwork_path_value =
                    artwork[
                        artwork_variant.path_key
                    ]
                local artwork_item_id =
                    artwork[
                        artwork_variant.item_id_key
                    ]

                if type(artwork_path_value) ==
                        "string" and
                    artwork_path_value ~= "" and
                    type(artwork_item_id) ==
                        "string" and
                    artwork_item_id ~= "" then
                    local artwork_local_path,
                        artwork_path_error =
                        normalize_local_path(
                            artwork_path_value
                        )

                    if not artwork_local_path then
                        return nil,
                            "manifest item " .. index ..
                            " artwork " ..
                            artwork_variant.variant ..
                            ": " .. artwork_path_error
                    end

                    local existing_kind =
                        desired_paths[
                            artwork_local_path
                        ]

                    if existing_kind and
                        existing_kind ~=
                            "artwork" then
                        return nil,
                            "artwork path conflicts with media path: " ..
                            artwork_local_path
                    end

                    if not existing_kind then
                        desired_paths[
                            artwork_local_path
                        ] = "artwork"

                        local artwork_storage_path =
                            storage_path(
                                root,
                                artwork_local_path
                            )

                        if not file_exists(
                            artwork_storage_path
                        ) then
                            local remote_artwork_path,
                                remote_path_error =
                                device_identity
                                    .artwork_path(
                                        artwork_item_id,
                                        artwork_variant.variant
                                    )

                            if not remote_artwork_path then
                                return nil,
                                    "manifest item " ..
                                    index ..
                                    " artwork " ..
                                    artwork_variant.variant ..
                                    ": " ..
                                    remote_path_error
                            end

                            local artwork_url,
                                artwork_url_error =
                                sync_client.url(
                                    remote_artwork_path
                                )

                            if not artwork_url then
                                return nil,
                                    "manifest item " ..
                                    index ..
                                    " artwork " ..
                                    artwork_variant.variant ..
                                    ": " ..
                                    artwork_url_error
                            end

                            local artwork_action = {
                                kind = "artwork",
                                local_path =
                                    artwork_local_path,
                                storage_path =
                                    artwork_storage_path,
                                artwork_path =
                                    remote_artwork_path,
                                artwork_url =
                                    artwork_url,
                                artwork_variant =
                                    artwork_variant.variant,
                                item = item,
                            }

                            table.insert(
                                plan.artwork,
                                artwork_action
                            )
                            table.insert(
                                plan.actions,
                                artwork_action
                            )
                        end
                    end
                end
            end
        end
    end

    local stale_paths = {}
    local seen_managed_paths = {}

    for index, path in ipairs(managed_paths) do
        local local_path, path_error =
            normalize_local_path(path)

        if not local_path then
            return nil,
                "managed path " .. index .. ": " .. path_error
        end

        if not seen_managed_paths[local_path] then
            seen_managed_paths[local_path] = true

            if not desired_paths[local_path] then
                table.insert(stale_paths, local_path)
            end
        end
    end

    table.sort(stale_paths)

    for _, local_path in ipairs(stale_paths) do
        local full_path = storage_path(root, local_path)

        if file_exists(full_path) then
            table.insert(plan.delete, {
                local_path = local_path,
                storage_path = full_path,
            })
        end
    end

    -- Download all media before artwork. This keeps the universal byte
    -- progress bar monotonic across an album or offline-library sync instead
    -- of alternating between known-size media and unknown-size artwork.
    plan.actions = {}

    for _, action in ipairs(plan.download) do
        table.insert(plan.actions, action)
    end

    for _, action in ipairs(plan.artwork) do
        table.insert(plan.actions, action)
    end

    plan.counts = {
        keep = #plan.keep,
        download = #plan.download,
        artwork = #plan.artwork,
        actions = #plan.actions,
        delete = #plan.delete,
    }

    return plan
end

return M
