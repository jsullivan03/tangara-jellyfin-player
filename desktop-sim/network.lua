local M = {}

local runtime_root =
    os.getenv("TANGARA_SIM_RUNTIME") or
    "desktop-sim/runtime"

local function shell_quote(value)
    return "'" ..
        tostring(value):gsub("'", "'\\''") ..
        "'"
end

local function ensure_directory(path)
    local result = os.execute(
        "mkdir -p " .. shell_quote(path)
    )

    return result == true or result == 0
end

local function write_file(path, contents)
    local file, open_error = io.open(path, "wb")

    if not file then
        return false, open_error
    end

    local written, write_error =
        file:write(contents)

    if not written then
        file:close()
        return false, write_error
    end

    file:close()

    return true
end

local function read_file(path)
    local file = io.open(path, "rb")

    if not file then
        return nil
    end

    local contents = file:read("*a")
    file:close()

    return contents
end

local function read_lines(path)
    local file = io.open(path, "rb")

    if not file then
        return nil
    end

    local lines = {}

    for line in file:lines() do
        table.insert(lines, line)
    end

    file:close()

    return lines
end

local function file_size(path)
    local file = io.open(path, "rb")

    if not file then
        return 0
    end

    local size = file:seek("end") or 0
    file:close()

    return size
end

local function remove_paths(paths)
    for _, path in ipairs(paths) do
        os.remove(path)
    end
end

local function launch_script(path, contents)
    if not ensure_directory(runtime_root) then
        return false,
            "failed to create simulator runtime directory"
    end

    local written, write_error =
        write_file(path, contents)

    if not written then
        return false, write_error
    end

    local result = os.execute(
        "sh " ..
        shell_quote(path) ..
        " >/dev/null 2>&1 &"
    )

    if result ~= true and result ~= 0 then
        return false,
            "failed to start background simulator job"
    end

    return true
end

local function error_message(
    curl_status,
    http_status,
    error_path
)
    local detail = read_file(error_path) or ""
    detail = detail:gsub("%s+$", "")

    if tonumber(curl_status) ~= 0 then
        if detail ~= "" then
            return detail
        end

        return "curl exited with code " ..
            tostring(curl_status)
    end

    return "HTTP status " ..
        tostring(http_status)
end

local http = {}

local http_job = nil

local function start_http_request(
    method,
    url,
    body
)
    if type(url) ~= "string" or
        not url:match("^https?://") then
        return false,
            "URL must begin with http:// or https://"
    end

    body = body or ""

    if type(body) ~= "string" then
        return false,
            "HTTP request body must be a string"
    end

    if #body > 65536 then
        return false,
            "HTTP request body exceeded 65536 bytes"
    end

    if http_job then
        return false,
            "HTTP request already in progress"
    end

    if not ensure_directory(runtime_root) then
        return false,
            "failed to create simulator runtime directory"
    end

    local prefix = runtime_root .. "/http"
    local job = {
        body = prefix .. ".body",
        error = prefix .. ".error",
        request_body = prefix .. ".request",
        script = prefix .. ".sh",
        status = prefix .. ".status",
        status_temporary =
            prefix .. ".status.tmp",
    }

    remove_paths({
        job.body,
        job.error,
        job.request_body,
        job.script,
        job.status,
        job.status_temporary,
    })

    local written, write_error =
        write_file(job.request_body, body)

    if not written then
        return false, write_error
    end

    local body_arguments = ""

    if method == "POST" or method == "PUT" then
        body_arguments =
            " -H " ..
            shell_quote("Content-Type: application/json")

        if body ~= "" then
            body_arguments =
                body_arguments ..
                " --data-binary " ..
                shell_quote("@" .. job.request_body)
        end
    end

    local script = table.concat({
        "rm -f " ..
            shell_quote(job.status) .. " " ..
            shell_quote(job.status_temporary),
        "code=$(curl -sS -L " ..
            "--connect-timeout 10 " ..
            "--max-time 30 " ..
            "-X " .. shell_quote(method) .. " " ..
            "-H " ..
            shell_quote("Accept: application/json") ..
            body_arguments .. " " ..
            "-o " .. shell_quote(job.body) .. " " ..
            "-w '%{http_code}' " ..
            shell_quote(url) ..
            " 2>" .. shell_quote(job.error) .. ")",
        "curl_status=$?",
        "printf '%s\\n%s\\n' " ..
            "\"$curl_status\" \"$code\" > " ..
            shell_quote(job.status_temporary),
        "mv " ..
            shell_quote(job.status_temporary) ..
            " " ..
            shell_quote(job.status),
    }, "\n")

    local started, start_error =
        launch_script(job.script, script)

    if not started then
        return false, start_error
    end

    http_job = job

    return true
end

function http.get(url)
    return start_http_request(
        "GET",
        url,
        ""
    )
end

function http.post(url, body)
    return start_http_request(
        "POST",
        url,
        body or ""
    )
end

function http.put(url, body)
    return start_http_request(
        "PUT",
        url,
        body
    )
end

function http.busy()
    return http_job ~= nil
end

function http.poll()
    if not http_job then
        return nil
    end

    local lines = read_lines(http_job.status)

    if not lines then
        return nil
    end

    local curl_status = tonumber(lines[1]) or -1
    local status = tonumber(lines[2]) or 0
    local body = read_file(http_job.body) or ""

    local result = {
        ok =
            curl_status == 0 and
            status >= 200 and
            status < 300,
        status = status,
        body = body,
        error = nil,
    }

    if not result.ok then
        result.error = error_message(
            curl_status,
            status,
            http_job.error
        )
    end

    remove_paths({
        http_job.body,
        http_job.error,
        http_job.request_body,
        http_job.script,
        http_job.status,
        http_job.status_temporary,
    })

    http_job = nil

    return result
end

local download = {}

local download_job = nil

local function content_length(path)
    local contents = read_file(path)

    if not contents then
        return nil
    end

    contents = contents:lower()

    local total = nil

    for value in contents:gmatch(
        "content%-length:%s*(%d+)"
    ) do
        total = tonumber(value)
    end

    return total
end

function download.start(url, destination)
    if type(url) ~= "string" or
        not url:match("^https?://") then
        return false,
            "URL must begin with http:// or https://"
    end

    if type(destination) ~= "string" or
        destination == "" then
        return false,
            "download destination is required"
    end

    if download_job then
        return false,
            "download already in progress"
    end

    local parent =
        destination:match("^(.*)/[^/]+$") or "."

    local prefix = runtime_root .. "/download"
    local job = {
        destination = destination,
        error = prefix .. ".error",
        headers = prefix .. ".headers",
        script = prefix .. ".sh",
        status = prefix .. ".status",
        status_temporary =
            prefix .. ".status.tmp",
        temporary = destination .. ".part",
    }

    remove_paths({
        job.error,
        job.headers,
        job.script,
        job.status,
        job.status_temporary,
        job.temporary,
    })

    local script = table.concat({
        "mkdir -p " .. shell_quote(parent),
        "rm -f " ..
            shell_quote(job.status) .. " " ..
            shell_quote(job.status_temporary) .. " " ..
            shell_quote(job.temporary),
        "code=$(curl -sS -L " ..
            "--connect-timeout 10 " ..
            "--max-time 600 " ..
            "-D " .. shell_quote(job.headers) .. " " ..
            "-o " .. shell_quote(job.temporary) .. " " ..
            "-w '%{http_code}' " ..
            shell_quote(url) ..
            " 2>" .. shell_quote(job.error) .. ")",
        "curl_status=$?",
        "bytes=0",
        "if [ -f " ..
            shell_quote(job.temporary) ..
            " ]; then",
        "  bytes=$(wc -c < " ..
            shell_quote(job.temporary) ..
            " | tr -d '[:space:]')",
        "fi",
        "success=0",
        "case \"$code\" in",
        "  2??)",
        "    if [ \"$curl_status\" -eq 0 ]; then",
        "      success=1",
        "    fi",
        "    ;;",
        "esac",
        "if [ \"$success\" -eq 1 ]; then",
        "  mv " ..
            shell_quote(job.temporary) ..
            " " ..
            shell_quote(job.destination),
        "else",
        "  rm -f " ..
            shell_quote(job.temporary),
        "fi",
        "printf '%s\\n%s\\n%s\\n' " ..
            "\"$curl_status\" \"$code\" \"$bytes\" > " ..
            shell_quote(job.status_temporary),
        "mv " ..
            shell_quote(job.status_temporary) ..
            " " ..
            shell_quote(job.status),
    }, "\n")

    local started, start_error =
        launch_script(job.script, script)

    if not started then
        return false, start_error
    end

    download_job = job

    return true
end

function download.busy()
    return download_job ~= nil
end

function download.progress()
    if not download_job then
        return {
            busy = false,
            bytes = 0,
            total = nil,
        }
    end

    return {
        busy = true,
        bytes = file_size(
            download_job.temporary
        ),
        total = content_length(
            download_job.headers
        ),
    }
end

function download.poll()
    if not download_job then
        return nil
    end

    local lines =
        read_lines(download_job.status)

    if not lines then
        return nil
    end

    local curl_status = tonumber(lines[1]) or -1
    local status = tonumber(lines[2]) or 0
    local bytes = tonumber(lines[3]) or 0
    local total =
        content_length(download_job.headers)

    local result = {
        ok =
            curl_status == 0 and
            status >= 200 and
            status < 300,
        status = status,
        bytes = bytes,
        total = total,
        path = download_job.destination,
        error = nil,
    }

    if not result.ok then
        result.error = error_message(
            curl_status,
            status,
            download_job.error
        )
    end

    remove_paths({
        download_job.error,
        download_job.headers,
        download_job.script,
        download_job.status,
        download_job.status_temporary,
        download_job.temporary,
    })

    download_job = nil

    return result
end

M.http = http
M.download = download

return M
