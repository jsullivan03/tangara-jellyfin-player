#include "lua/lua_http.hpp"

#include <mutex>
#include <optional>
#include <string>
#include <utility>

#include "lua.hpp"

#include "esp_err.h"
#include "esp_http_client.h"

#include "lua/bridge.hpp"

namespace lua {
namespace {

constexpr size_t kMaxBodyBytes = 64 * 1024;
constexpr size_t kMaxRequestBodyBytes = 64 * 1024;

struct HttpResult {
  bool ok = false;
  int status = 0;
  std::string body;
  std::string error;
};

struct ResponseBuffer {
  std::string body;
  bool too_large = false;
};

std::mutex sMutex;
bool sBusy = false;
std::optional<HttpResult> sResult;

auto handle_http_event(esp_http_client_event_t* event) -> esp_err_t {
  if (event->event_id != HTTP_EVENT_ON_DATA ||
      event->data == nullptr ||
      event->data_len <= 0) {
    return ESP_OK;
  }

  auto* response = static_cast<ResponseBuffer*>(event->user_data);

  if (response == nullptr) {
    return ESP_OK;
  }

  const size_t incoming_size = static_cast<size_t>(event->data_len);

  if (response->body.size() + incoming_size > kMaxBodyBytes) {
    response->too_large = true;
    return ESP_FAIL;
  }

  response->body.append(
      static_cast<const char*>(event->data),
      incoming_size
  );

  return ESP_OK;
}

auto complete_request(HttpResult result) -> void {
  std::lock_guard<std::mutex> lock(sMutex);
  sResult = std::move(result);
  sBusy = false;
}

auto perform_request(
    std::string url,
    esp_http_client_method_t method,
    std::string request_body
) -> void {
  ResponseBuffer response;

  esp_http_client_config_t config{};
  config.url = url.c_str();
  config.event_handler = handle_http_event;
  config.user_data = &response;
  config.timeout_ms = 10000;
  config.disable_auto_redirect = false;

  esp_http_client_handle_t client = esp_http_client_init(&config);

  if (client == nullptr) {
    HttpResult result;
    result.error = "failed to initialize HTTP client";
    complete_request(std::move(result));
    return;
  }

  esp_http_client_set_method(client, method);
  esp_http_client_set_header(client, "Accept", "application/json");
  esp_http_client_set_header(client, "Accept-Encoding", "identity");

  if (method == HTTP_METHOD_POST || method == HTTP_METHOD_PUT) {
    esp_http_client_set_header(
        client,
        "Content-Type",
        "application/json"
    );

    if (!request_body.empty()) {
      esp_http_client_set_post_field(
          client,
          request_body.data(),
          static_cast<int>(request_body.size())
      );
    }
  }

  const esp_err_t request_error = esp_http_client_perform(client);
  const int status = esp_http_client_get_status_code(client);

  esp_http_client_cleanup(client);

  HttpResult result;
  result.status = status;
  result.body = std::move(response.body);

  if (response.too_large) {
    result.error = "HTTP response exceeded 65536 bytes";
  } else if (request_error != ESP_OK) {
    result.error = esp_err_to_name(request_error);
  } else if (status < 200 || status >= 300) {
    result.error = "HTTP status " + std::to_string(status);
  } else {
    result.ok = true;
  }

  complete_request(std::move(result));
}

auto start_request(
    lua_State* state,
    esp_http_client_method_t method,
    bool accepts_body,
    bool requires_body
) -> int {
  Bridge* instance = Bridge::Get(state);

  size_t url_length = 0;
  const char* url_value = luaL_checklstring(
      state,
      1,
      &url_length
  );

  std::string url{url_value, url_length};
  std::string request_body;

  if (accepts_body) {
    size_t body_length = 0;
    const char* body_value = nullptr;

    if (requires_body) {
      body_value = luaL_checklstring(
          state,
          2,
          &body_length
      );
    } else {
      body_value = luaL_optlstring(
          state,
          2,
          "",
          &body_length
      );
    }

    if (body_length > kMaxRequestBodyBytes) {
      lua_pushboolean(state, false);
      lua_pushliteral(
          state,
          "HTTP request body exceeded 65536 bytes"
      );
      return 2;
    }

    request_body.assign(body_value, body_length);
  }

  if (url.rfind("http://", 0) != 0 &&
      url.rfind("https://", 0) != 0) {
    lua_pushboolean(state, false);
    lua_pushliteral(
        state,
        "URL must begin with http:// or https://"
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
          "HTTP request already in progress"
      );
      return 2;
    }

    sBusy = true;
    sResult.reset();
  }

  instance->services().bg_worker().Dispatch<void>(
      [
        url = std::move(url),
        method,
        request_body = std::move(request_body)
      ]() mutable {
        perform_request(
            std::move(url),
            method,
            std::move(request_body)
        );
      }
  );

  lua_pushboolean(state, true);
  return 1;
}

auto get(lua_State* state) -> int {
  return start_request(
      state,
      HTTP_METHOD_GET,
      false,
      false
  );
}

auto post(lua_State* state) -> int {
  return start_request(
      state,
      HTTP_METHOD_POST,
      true,
      false
  );
}

auto put(lua_State* state) -> int {
  return start_request(
      state,
      HTTP_METHOD_PUT,
      true,
      true
  );
}

auto busy(lua_State* state) -> int {
  std::lock_guard<std::mutex> lock(sMutex);
  lua_pushboolean(state, sBusy);
  return 1;
}

auto poll(lua_State* state) -> int {
  std::optional<HttpResult> result;

  {
    std::lock_guard<std::mutex> lock(sMutex);

    if (!sResult) {
      lua_pushnil(state);
      return 1;
    }

    result = std::move(sResult);
    sResult.reset();
  }

  lua_createtable(state, 0, 4);

  lua_pushboolean(state, result->ok);
  lua_setfield(state, -2, "ok");

  lua_pushinteger(state, result->status);
  lua_setfield(state, -2, "status");

  lua_pushlstring(
      state,
      result->body.data(),
      result->body.size()
  );
  lua_setfield(state, -2, "body");

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

const luaL_Reg kHttpFunctions[] = {
    {"get", get},
    {"post", post},
    {"put", put},
    {"busy", busy},
    {"poll", poll},
    {nullptr, nullptr},
};

auto open_http(lua_State* state) -> int {
  luaL_newlib(state, kHttpFunctions);
  return 1;
}

}

auto RegisterHttpModule(lua_State* state) -> void {
  luaL_requiref(state, "http", open_http, true);
  lua_pop(state, 1);
}

}
