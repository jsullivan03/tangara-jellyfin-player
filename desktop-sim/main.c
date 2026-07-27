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

#include "src/drivers/sdl/lv_sdl_keyboard.h"
#include "src/drivers/sdl/lv_sdl_mouse.h"
#include "src/drivers/sdl/lv_sdl_mousewheel.h"
#include "src/drivers/sdl/lv_sdl_window.h"

static SDL_atomic_t back_requested;

static int SDLCALL watch_sdl_event(void *userdata, SDL_Event *event)
{
    (void)userdata;

    if (
        event->type == SDL_KEYDOWN &&
        event->key.repeat == 0 &&
        event->key.keysym.sym == SDLK_ESCAPE
    ) {
        SDL_AtomicSet(&back_requested, 1);
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

    SDL_AddEventWatch(watch_sdl_event, NULL);

    if (run_lua_file(L, script) != 0) {
        SDL_DelEventWatch(watch_sdl_event, NULL);

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

    SDL_DelEventWatch(watch_sdl_event, NULL);
    firmware_backstack_shutdown();
    lua_close(L);
    return 0;
}
