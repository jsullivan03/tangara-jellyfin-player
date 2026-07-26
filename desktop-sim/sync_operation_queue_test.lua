package.path =
    "lua/?.lua;" ..
    "desktop-sim/?.lua;" ..
    package.path

local root =
    "desktop-sim/sd/operation-queue-test"

os.execute(
    "mkdir -p " .. root
)

package.preload["device"] = function()
    return {
        id = function()
            return "queue-test-device"
        end,
        storage_root = function()
            return root
        end,
    }
end

local function copy_file(source, destination)
    local input = assert(
        io.open(source, "rb")
    )
    local contents = input:read("*a")
    input:close()

    local output = assert(
        io.open(destination, "wb")
    )
    output:write(contents)
    output:close()
end

local function clean(queue)
    local paths = assert(queue.paths())

    os.remove(paths.path)
    os.remove(paths.temporary)
    os.remove(paths.backup)
end

local queue =
    require("sync_operation_queue")

clean(queue)

local local_id, create =
    queue.enqueue_create_playlist(
        "Offline Queue Test"
    )

assert(local_id, create)
assert(type(local_id) == "string")
assert(create.type == "create_playlist")

local renamed = assert(
    queue.enqueue_rename_playlist(
        local_id,
        "Offline Queue Renamed"
    )
)

assert(renamed.data.playlist_id == local_id)

package.loaded[
    "sync_operation_queue"
] = nil

queue = require("sync_operation_queue")

local status = queue.status()

assert(status.pending == 2)
assert(status.blocked == false)

local batch = assert(queue.batch(25))

assert(#batch == 2)
assert(batch[1].id == create.id)
assert(batch[2].id == renamed.id)

local summary = assert(
    queue.apply_results(
        batch,
        {
            {
                id = create.id,
                type = create.type,
                status = "applied",
                result = {
                    playlist_id =
                        "jellyfin-playlist-test",
                    local_playlist_id =
                        local_id,
                },
            },
            {
                id = renamed.id,
                type = renamed.type,
                status = "applied",
                result = {
                    playlist_id =
                        "jellyfin-playlist-test",
                    name =
                        "Offline Queue Renamed",
                },
            },
        }
    )
)

assert(summary.applied == 2)
assert(summary.pending == 0)

local resolved = assert(
    queue.resolve_playlist_id(local_id)
)

assert(
    resolved == "jellyfin-playlist-test"
)

local favorite = assert(
    queue.enqueue_set_favorite(
        "favorite-item-test",
        true
    )
)

local favorite_batch =
    assert(queue.batch(25))

assert(#favorite_batch == 1)

local failed = assert(
    queue.apply_results(
        favorite_batch,
        {
            {
                id = favorite.id,
                type = favorite.type,
                status = "failed",
                error = {
                    code = "invalid_operation",
                    message =
                        "intentional test failure",
                    retriable = false,
                },
            },
        }
    )
)

assert(failed.pending == 1)
assert(failed.blocked == true)

local blocked_batch, blocked_error =
    queue.batch(25)

assert(blocked_batch == nil)
assert(type(blocked_error) == "string")

assert(
    queue.clear_failure(favorite.id)
)

local retry_batch =
    assert(queue.batch(25))

assert(#retry_batch == 1)

assert(
    queue.apply_results(
        retry_batch,
        {
            {
                id = favorite.id,
                type = favorite.type,
                status = "applied",
                result = {
                    item_id =
                        "favorite-item-test",
                    favorite = true,
                },
            },
        }
    )
)

local paths = assert(queue.paths())
local delete_operation = assert(
    queue.enqueue_delete_playlist(
        local_id
    )
)

copy_file(
    paths.path,
    paths.backup
)

local corrupted = assert(
    io.open(paths.path, "wb")
)

corrupted:write("{broken")
corrupted:close()

package.loaded[
    "sync_operation_queue"
] = nil

queue = require("sync_operation_queue")
status = queue.status()

assert(status.recovered == true)
assert(status.pending == 1)

local delete_batch =
    assert(queue.batch(25))

assert(delete_batch[1].id ==
    delete_operation.id)

assert(
    queue.apply_results(
        delete_batch,
        {
            {
                id = delete_operation.id,
                type =
                    delete_operation.type,
                status = "applied",
                result = {
                    playlist_id =
                        "jellyfin-playlist-test",
                    deleted = true,
                },
            },
        }
    )
)

assert(
    queue.resolve_playlist_id(local_id)
        == local_id
)

clean(queue)

print(
    "durable offline operation queue passed"
)

os.exit(0)
