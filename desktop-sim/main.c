#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

#include <SDL2/SDL.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#include <lvgl.h>
#include "luavgl.h"
#include "firmware_backstack.h"
#include "sim_metrics.h"

#include "src/drivers/sdl/lv_sdl_keyboard.h"
#include "src/drivers/sdl/lv_sdl_mouse.h"
#include "src/drivers/sdl/lv_sdl_mousewheel.h"
#include "src/drivers/sdl/lv_sdl_window.h"

static SDL_atomic_t back_requested;
static SDL_atomic_t transport_mode;
static SDL_atomic_t encoder_mode;
static SDL_atomic_t pending_encoder_ticks;
static SDL_atomic_t pending_seek_ticks;
static SDL_atomic_t pending_previous;
static SDL_atomic_t pending_next;
static SDL_atomic_t pending_toggle;
static SDL_atomic_t pending_volume_up;
static SDL_atomic_t pending_volume_down;

static int lua_set_encoder_mode(lua_State *L)
{
    bool enabled = lua_toboolean(L, 1) != 0;

    SDL_AtomicSet(&encoder_mode, enabled ? 1 : 0);

    if (!enabled) {
        SDL_AtomicSet(&pending_encoder_ticks, 0);
    }

    return 0;
}

static int lua_set_transport_mode(lua_State *L)
{
    bool enabled = lua_toboolean(L, 1) != 0;

    SDL_AtomicSet(&transport_mode, enabled ? 1 : 0);

    if (!enabled) {
        SDL_AtomicSet(&pending_seek_ticks, 0);
        SDL_AtomicSet(&pending_previous, 0);
        SDL_AtomicSet(&pending_next, 0);
        SDL_AtomicSet(&pending_toggle, 0);
        SDL_AtomicSet(&pending_volume_up, 0);
        SDL_AtomicSet(&pending_volume_down, 0);
    }

    return 0;
}

static int SDLCALL filter_sdl_event(void *userdata, SDL_Event *event)
{
    (void)userdata;

    if (
        event->type == SDL_KEYDOWN &&
        event->key.repeat == 0 &&
        event->key.keysym.sym == SDLK_ESCAPE
    ) {
        SDL_AtomicSet(&back_requested, 1);
    }

    if (!SDL_AtomicGet(&transport_mode)) {
        if (SDL_AtomicGet(&encoder_mode)) {
            if (event->type == SDL_MOUSEWHEEL) {
                int wheel_y = event->wheel.y;

                if (event->wheel.direction == SDL_MOUSEWHEEL_FLIPPED) {
                    wheel_y = -wheel_y;
                }

                SDL_AtomicAdd(
                    &pending_encoder_ticks,
                    -wheel_y
                );
                return 0;
            }

            if (event->type == SDL_KEYDOWN &&
                event->key.repeat == 0) {
                if (event->key.keysym.sym == SDLK_UP) {
                    SDL_AtomicAdd(
                        &pending_encoder_ticks,
                        -1
                    );
                    return 0;
                }

                if (event->key.keysym.sym == SDLK_DOWN) {
                    SDL_AtomicAdd(
                        &pending_encoder_ticks,
                        1
                    );
                    return 0;
                }
            }
        }

        return 1;
    }

    if (event->type == SDL_MOUSEWHEEL) {
        int wheel_y = event->wheel.y;

        if (event->wheel.direction == SDL_MOUSEWHEEL_FLIPPED) {
            wheel_y = -wheel_y;
        }

        SDL_AtomicAdd(
            &pending_seek_ticks,
            -wheel_y
        );
        return 0;
    }

    if (event->type == SDL_KEYDOWN && event->key.repeat == 0) {
        switch (event->key.keysym.sym) {
            case SDLK_LEFT:
                SDL_AtomicAdd(&pending_previous, 1);
                return 0;
            case SDLK_RIGHT:
                SDL_AtomicAdd(&pending_next, 1);
                return 0;
            case SDLK_SPACE:
                SDL_AtomicAdd(&pending_toggle, 1);
                return 0;
            case SDLK_EQUALS:
            case SDLK_KP_PLUS:
                SDL_AtomicAdd(&pending_volume_up, 1);
                return 0;
            case SDLK_MINUS:
            case SDLK_KP_MINUS:
                SDL_AtomicAdd(&pending_volume_down, 1);
                return 0;
            default:
                break;
        }
    }

    if (event->type == SDL_TEXTINPUT) {
        if (
            event->text.text[0] == '=' ||
            event->text.text[0] == '+' ||
            event->text.text[0] == '-'
        ) {
            return 0;
        }
    }

    return 1;
}

static int run_lua_file(lua_State *L, const char *filename)
{
    int status = luaL_loadfile(L, filename);

    if (status == LUA_OK) {
        status = lua_pcall(L, 0, 0, 0);
    }

    if (status != LUA_OK) {
        const char *message = lua_tostring(L, -1);

        fprintf(
            stderr,
            "Lua error in %s:\n%s\n",
            filename,
            message != NULL ? message : "Unknown Lua error"
        );

        lua_pop(L, 1);
        return -1;
    }

    return 0;
}

static void call_lua_back(lua_State *L)
{
    lua_getglobal(L, "tangara_sim_back");

    if (!lua_isfunction(L, -1)) {
        lua_pop(L, 1);
        return;
    }

    if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
        const char *message = lua_tostring(L, -1);

        fprintf(
            stderr,
            "Simulator back handler failed:\n%s\n",
            message != NULL ? message : "Unknown Lua error"
        );

        lua_pop(L, 1);
    }
}

static void call_lua_encoder(
    lua_State *L,
    int amount
)
{
    lua_getglobal(
        L,
        "tangara_sim_encoder_event"
    );

    if (!lua_isfunction(L, -1)) {
        lua_pop(L, 1);
        return;
    }

    lua_pushinteger(L, amount);

    if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
        const char *message =
            lua_tostring(L, -1);

        fprintf(
            stderr,
            "Simulator encoder handler failed:\n%s\n",
            message != NULL ?
                message :
                "Unknown Lua error"
        );

        lua_pop(L, 1);
    }
}

static void service_encoder(lua_State *L)
{
    int ticks =
        SDL_AtomicSet(
            &pending_encoder_ticks,
            0
        );

    if (ticks != 0) {
        call_lua_encoder(L, ticks);
    }
}

static void call_lua_transport(
    lua_State *L,
    const char *action,
    int amount
)
{
    lua_getglobal(L, "tangara_sim_transport_event");

    if (!lua_isfunction(L, -1)) {
        lua_pop(L, 1);
        return;
    }

    lua_pushstring(L, action);
    lua_pushinteger(L, amount);

    if (lua_pcall(L, 2, 0, 0) != LUA_OK) {
        const char *message = lua_tostring(L, -1);

        fprintf(
            stderr,
            "Simulator transport handler failed:\n%s\n",
            message != NULL ? message : "Unknown Lua error"
        );

        lua_pop(L, 1);
    }
}

static void service_transport(lua_State *L)
{
    int seek_ticks =
        SDL_AtomicSet(&pending_seek_ticks, 0);
    int previous =
        SDL_AtomicSet(&pending_previous, 0);
    int next = SDL_AtomicSet(&pending_next, 0);
    int toggle =
        SDL_AtomicSet(&pending_toggle, 0);
    int volume_up =
        SDL_AtomicSet(&pending_volume_up, 0);
    int volume_down =
        SDL_AtomicSet(&pending_volume_down, 0);

    if (seek_ticks != 0) {
        call_lua_transport(L, "seek", seek_ticks);
    }
    if (previous > 0) {
        call_lua_transport(L, "previous", previous);
    }
    if (next > 0) {
        call_lua_transport(L, "next", next);
    }
    if (toggle > 0) {
        call_lua_transport(L, "toggle", toggle);
    }
    if (volume_up > 0) {
        call_lua_transport(L, "volume_up", volume_up);
    }
    if (volume_down > 0) {
        call_lua_transport(L, "volume_down", volume_down);
    }
}

int main(int argc, char **argv)
{
    const char *script =
        argc > 1 ? argv[1] : "desktop-sim/ui.lua";

    lv_init();

    lv_display_t *display = lv_sdl_window_create(160, 128);

    if (display == NULL) {
        fprintf(stderr, "Failed to create the SDL display.\n");
        return 1;
    }

    lv_sdl_window_set_zoom(display, 3.0f);
    lv_sdl_window_set_title(display, "Tangara Lua Simulator");
    lv_sdl_window_set_resizeable(display, true);

    lv_indev_t *mouse = lv_sdl_mouse_create();
    lv_indev_t *keyboard = lv_sdl_keyboard_create();
    lv_indev_t *wheel = lv_sdl_mousewheel_create();

    (void)mouse;

    lv_group_t *group = lv_group_create();
    lv_group_set_default(group);

    lv_indev_set_group(keyboard, group);
    lv_indev_set_group(wheel, group);

    lua_State *L = luaL_newstate();

    if (L == NULL) {
        fprintf(stderr, "Failed to create the Lua interpreter.\n");
        return 1;
    }

    luaL_openlibs(L);

    lua_pushcfunction(L, lua_set_transport_mode);
    lua_setglobal(L, "tangara_sim_set_transport_mode");

    lua_pushcfunction(L, lua_set_encoder_mode);
    lua_setglobal(L, "tangara_sim_set_encoder_mode");

    luaL_requiref(L, "lvgl", luaopen_lvgl, 1);
    lua_pop(L, 1);

    firmware_backstack_init(L, keyboard, wheel);
    luaL_requiref(
        L,
        "firmware_backstack",
        luaopen_firmware_backstack,
        1
    );
    lua_pop(L, 1);

    luaL_requiref(L, "sim_metrics", luaopen_sim_metrics, 1);
    lua_pop(L, 1);

    SDL_SetEventFilter(filter_sdl_event, NULL);

    if (run_lua_file(L, script) != 0) {
        /*
         * Lua/LVGL objects can still reference each other after a failed
         * chunk unwinds. The process is about to terminate, so let the OS
         * reclaim them instead of running an unsafe partial teardown that
         * can double-delete Lua-owned LVGL objects.
         */
        return 1;
    }

    while (true) {
        firmware_backstack_service();
        service_encoder(L);
        service_transport(L);
        uint32_t delay_ms = lv_timer_handler();

        if (SDL_AtomicCAS(&back_requested, 1, 0)) {
            call_lua_back(L);
        }

        if (delay_ms < 1) {
            delay_ms = 1;
        } else if (delay_ms > 20) {
            delay_ms = 20;
        }

        usleep(delay_ms * 1000);
    }

    SDL_SetEventFilter(NULL, NULL);
    firmware_backstack_shutdown();
    lua_close(L);
    return 0;
}
