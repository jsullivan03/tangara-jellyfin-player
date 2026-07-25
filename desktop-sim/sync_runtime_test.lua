package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")

require("mocks").install(lvgl)

local sync_runtime =
    require("sync_runtime")

local item_id =
    os.getenv("TANGARA_SIM_ITEM_ID")

local local_path =
    os.getenv("TANGARA_SIM_LOCAL_PATH")

local expected_size =
    tonumber(
        os.getenv("TANGARA_SIM_EXPECTED_SIZE")
    )

assert(
    type(item_id) == "string" and
    item_id ~= "",
    "TANGARA_SIM_ITEM_ID is required"
)

assert(
    type(local_path) == "string" and
    local_path:sub(1, 1) == "/",
    "TANGARA_SIM_LOCAL_PATH is required"
)

assert(
    expected_size and expected_size > 0,
    "TANGARA_SIM_EXPECTED_SIZE is required"
)

local final_path =
    "desktop-sim/sd" .. local_path

local partial_path =
    final_path .. ".part"

local manifest_path =
    "desktop-sim/sd/" ..
    ".tangara_sync_manifest.json"

local inventory_path =
    "desktop-sim/sd/" ..
    ".tangara_sync_managed_paths"

local function read_file(path)
    local file = io.open(path, "rb")

    if not file then
        return nil
    end

    local contents = file:read("*a")
    file:close()

    return contents
end

local function file_size(path)
    local file = io.open(path, "rb")

    if not file then
        return nil
    end

    local size = file:seek("end")
    file:close()

    return size
end

local started, start_result =
    sync_runtime.start()

if not started then
    error(start_result)
end

print("full sync runtime started")

local started_at = os.time()
local last_megabytes = -1
local finished = false

lvgl.Timer {
    period = 100,
    cb = function()
        if finished then
            return
        end

        local partial_size =
            file_size(partial_path) or 0

        local megabytes =
            math.floor(
                partial_size /
                1024 /
                1024
            )

        if megabytes ~= last_megabytes then
            last_megabytes = megabytes

            print(
                "runtime downloaded " ..
                megabytes ..
                " MiB"
            )
        end

        local result =
            sync_runtime.last_apply_result()

        if result then
            finished = true

            if not result.ok then
                io.stderr:write(
                    "runtime apply failed: " ..
                    tostring(result.error) ..
                    "\n"
                )

                os.exit(1)
            end

            local downloaded_size =
                file_size(final_path)

            assert(
                downloaded_size == expected_size,
                "downloaded file size was " ..
                tostring(downloaded_size)
            )

            local manifest =
                assert(
                    read_file(manifest_path),
                    "manifest cache is missing"
                )

            assert(
                manifest:find(
                    item_id,
                    1,
                    true
                ),
                "manifest cache lacks item"
            )

            local inventory =
                assert(
                    read_file(inventory_path),
                    "managed inventory is missing"
                )

            assert(
                inventory:find(
                    local_path,
                    1,
                    true
                ),
                "managed inventory lacks path"
            )

            print(
                "full automatic sync runtime passed"
            )

            print(
                "downloaded file: " ..
                final_path
            )

            os.exit(0)
        end

        if os.time() - started_at > 120 then
            finished = true

            local latest =
                sync_runtime.last_result()

            io.stderr:write(
                "full sync runtime timed out\n"
            )

            if type(latest) == "table" then
                io.stderr:write(
                    "last error: " ..
                    tostring(latest.error) ..
                    "\n"
                )

                io.stderr:write(
                    "plan error: " ..
                    tostring(latest.plan_error) ..
                    "\n"
                )
            end

            os.exit(1)
        end
    end,
}
