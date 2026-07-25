#include "lua/lua_download.hpp"

#include <array>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <optional>
#include <string>
#include <utility>

#include "lua.hpp"

#include "esp_err.h"
#include "esp_http_client.h"

#include "lua/bridge.hpp"

#include <sys/stat.h>
#include <unistd.h>

namespace lua {
namespace {

struct DownloadResult {
  bool ok = false;
  int status = 0;
  size_t bytes = 0;
  int64_t total = -1;
  std::string path;
  std::string error;
};

std::mutex sMutex;
bool sBusy = false;
size_t sBytes = 0;
int64_t sTotal = -1;
std::optional<DownloadResult> sResult;

auto destination_error(const std::string& path)
    -> std::optional<std::string> {
  if (path.rfind("/sd/", 0) != 0) {
    return "destination must begin with /sd/";
  }

  if (path.back() == '/') {
    return "destination must identify a file";
  }

  if (path.find('\0') != std::string::npos) {
    return "destination contains a null byte";
  }

  if (path.find('\r') != std::string::npos ||
      path.find('\n') != std::string::npos) {
    return "destination contains a line break";
  }

  size_t start = 1;

  while (start < path.size()) {
    const size_t end = path.find('/', start);
    const size_t length =
        end == std::string::npos ? path.size() - start : end - start;
    const std::string segment = path.substr(start, length);

    if (segment.empty()) {
      return "destination contains an empty segment";
    }

    if (segment == "." || segment == "..") {
      return "destination contains an unsafe segment";
    }

    if (end == std::string::npos) {
      break;
    }

    start = end + 1;
  }

  return std::nullopt;
}

auto ensure_parent_directories(const std::string& path)
    -> std::optional<std::string> {
  size_t slash = path.find('/', 1);

  while (slash != std::string::npos) {
    const std::string directory = path.substr(0, slash);

    if (::mkdir(directory.c_str(), 0775) != 0) {
      const int mkdir_error = errno;

      if (mkdir_error != EEXIST) {
        return "failed to create directory " + directory + ": " +
               std::strerror(mkdir_error);
      }

      struct stat info {};

      if (::stat(directory.c_str(), &info) != 0 ||
          !S_ISDIR(info.st_mode)) {
        return "path component is not a directory: " + directory;
      }
    }

    slash = path.find('/', slash + 1);
  }

  return std::nullopt;
}

auto update_progress(size_t bytes, int64_t total) -> void {
  std::lock_guard<std::mutex> lock(sMutex);
  sBytes = bytes;
  sTotal = total;
}

auto complete_download(DownloadResult result) -> void {
  std::lock_guard<std::mutex> lock(sMutex);
  sBytes = result.bytes;
  sTotal = result.total;
  sResult = std::move(result);
  sBusy = false;
}

auto perform_download(std::string url, std::string destination) -> void {
  DownloadResult result;
  result.path = destination;

  esp_http_client_config_t config{};
  config.url = url.c_str();
  config.timeout_ms = 30000;
  config.disable_auto_redirect = false;

  esp_http_client_handle_t client = esp_http_client_init(&config);

  if (client == nullptr) {
    result.error = "failed to initialize HTTP client";
    complete_download(std::move(result));
    return;
  }

  esp_http_client_set_method(client, HTTP_METHOD_GET);
  esp_http_client_set_header(client, "Accept", "application/octet-stream");
  esp_http_client_set_header(client, "Accept-Encoding", "identity");

  const esp_err_t open_error = esp_http_client_open(client, 0);

  if (open_error != ESP_OK) {
    result.error = esp_err_to_name(open_error);
    esp_http_client_cleanup(client);
    complete_download(std::move(result));
    return;
  }

  const int64_t content_length =
      esp_http_client_fetch_headers(client);

  result.status = esp_http_client_get_status_code(client);
  result.total = content_length;
  update_progress(0, content_length);

  if (result.status < 200 || result.status >= 300) {
    result.error = "HTTP status " + std::to_string(result.status);
    esp_http_client_close(client);
    esp_http_client_cleanup(client);
    complete_download(std::move(result));
    return;
  }

  const auto directory_error =
      ensure_parent_directories(destination);

  if (directory_error) {
    result.error = *directory_error;
    esp_http_client_close(client);
    esp_http_client_cleanup(client);
    complete_download(std::move(result));
    return;
  }

  const std::string temporary = destination + ".part";
  std::remove(temporary.c_str());

  FILE* file = std::fopen(temporary.c_str(), "wb");

  if (file == nullptr) {
    result.error = "failed to open temporary file: ";
    result.error += std::strerror(errno);
    esp_http_client_close(client);
    esp_http_client_cleanup(client);
    complete_download(std::move(result));
    return;
  }

  std::array<char, 8192> buffer{};
  bool failed = false;

  while (true) {
    const int read =
        esp_http_client_read(client, buffer.data(), buffer.size());

    if (read < 0) {
      result.error = "failed while reading HTTP response";
      failed = true;
      break;
    }

    if (read == 0) {
      break;
    }

    const size_t requested = static_cast<size_t>(read);
    const size_t written =
        std::fwrite(buffer.data(), 1, requested, file);

    result.bytes += written;
    update_progress(result.bytes, result.total);

    if (written != requested) {
      result.error = "failed while writing temporary file";
      failed = true;
      break;
    }
  }

  if (!failed &&
      !esp_http_client_is_complete_data_received(client)) {
    result.error = "HTTP response ended before download completed";
    failed = true;
  }

  if (!failed &&
      content_length >= 0 &&
      result.bytes != static_cast<size_t>(content_length)) {
    result.error = "download size did not match Content-Length";
    failed = true;
  }

  if (!failed && std::fflush(file) != 0) {
    result.error = "failed to flush temporary file";
    failed = true;
  }

  if (!failed && ::fsync(::fileno(file)) != 0) {
    result.error = "failed to synchronize temporary file";
    failed = true;
  }

  if (std::fclose(file) != 0 && !failed) {
    result.error = "failed to close temporary file";
    failed = true;
  }

  esp_http_client_close(client);
  esp_http_client_cleanup(client);

  if (failed) {
    std::remove(temporary.c_str());
    complete_download(std::move(result));
    return;
  }

  if (std::rename(temporary.c_str(), destination.c_str()) != 0) {
    result.error = "failed to promote temporary file: ";
    result.error += std::strerror(errno);
    std::remove(temporary.c_str());
    complete_download(std::move(result));
    return;
  }

  result.ok = true;
  complete_download(std::move(result));
}

auto start(lua_State* state) -> int {
  Bridge* instance = Bridge::Get(state);

  size_t url_length = 0;
  const char* url_value =
      luaL_checklstring(state, 1, &url_length);

  size_t destination_length = 0;
  const char* destination_value =
      luaL_checklstring(state, 2, &destination_length);

  std::string url{url_value, url_length};
  std::string destination{
      destination_value,
      destination_length,
  };

  if (url.rfind("http://", 0) != 0 &&
      url.rfind("https://", 0) != 0) {
    lua_pushboolean(state, false);
    lua_pushliteral(
        state,
        "URL must begin with http:// or https://"
    );
    return 2;
  }

  const auto path_error = destination_error(destination);

  if (path_error) {
    lua_pushboolean(state, false);
    lua_pushlstring(
        state,
        path_error->data(),
        path_error->size()
    );
    return 2;
  }

  if (!instance->services().wifi().connected()) {
    lua_pushboolean(state, false);
    lua_pushliteral(state, "WiFi is not connected");
    return 2;
  }

  {
    std::lock_guard<std::mutex> lock(sMutex);

    if (sBusy) {
      lua_pushboolean(state, false);
      lua_pushliteral(
          state,
          "download already in progress"
      );
      return 2;
    }

    sBusy = true;
    sBytes = 0;
    sTotal = -1;
    sResult.reset();
  }

  instance->services().bg_worker().Dispatch<void>(
      [
          url = std::move(url),
          destination = std::move(destination)
      ]() mutable {
        perform_download(
            std::move(url),
            std::move(destination)
        );
      }
  );

  lua_pushboolean(state, true);
  return 1;
}

auto busy(lua_State* state) -> int {
  std::lock_guard<std::mutex> lock(sMutex);
  lua_pushboolean(state, sBusy);
  return 1;
}

auto progress(lua_State* state) -> int {
  std::lock_guard<std::mutex> lock(sMutex);

  lua_createtable(state, 0, 3);

  lua_pushboolean(state, sBusy);
  lua_setfield(state, -2, "busy");

  lua_pushinteger(
      state,
      static_cast<lua_Integer>(sBytes)
  );
  lua_setfield(state, -2, "bytes");

  if (sTotal >= 0) {
    lua_pushinteger(
        state,
        static_cast<lua_Integer>(sTotal)
    );
  } else {
    lua_pushnil(state);
  }

  lua_setfield(state, -2, "total");

  return 1;
}

auto poll(lua_State* state) -> int {
  std::optional<DownloadResult> result;

  {
    std::lock_guard<std::mutex> lock(sMutex);

    if (!sResult) {
      lua_pushnil(state);
      return 1;
    }

    result = std::move(sResult);
    sResult.reset();
  }

  lua_createtable(state, 0, 6);

  lua_pushboolean(state, result->ok);
  lua_setfield(state, -2, "ok");

  lua_pushinteger(state, result->status);
  lua_setfield(state, -2, "status");

  lua_pushinteger(
      state,
      static_cast<lua_Integer>(result->bytes)
  );
  lua_setfield(state, -2, "bytes");

  if (result->total >= 0) {
    lua_pushinteger(
        state,
        static_cast<lua_Integer>(result->total)
    );
  } else {
    lua_pushnil(state);
  }

  lua_setfield(state, -2, "total");

  lua_pushlstring(
      state,
      result->path.data(),
      result->path.size()
  );
  lua_setfield(state, -2, "path");

  if (result->error.empty()) {
    lua_pushnil(state);
  } else {
    lua_pushlstring(
        state,
        result->error.data(),
        result->error.size()
    );
  }

  lua_setfield(state, -2, "error");

  return 1;
}

const luaL_Reg kDownloadFunctions[] = {
    {"start", start},
    {"busy", busy},
    {"progress", progress},
    {"poll", poll},
    {nullptr, nullptr},
};

auto open_download(lua_State* state) -> int {
  luaL_newlib(state, kDownloadFunctions);
  return 1;
}

}

auto RegisterDownloadModule(lua_State* state) -> void {
  luaL_requiref(
      state,
      "download",
      open_download,
      true
  );
  lua_pop(state, 1);
}

}
