#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#include <lvgl.h>
#include "luavgl.h"

#include "src/drivers/sdl/lv_sdl_keyboard.h"
#include "src/drivers/sdl/lv_sdl_mouse.h"
#include "src/drivers/sdl/lv_sdl_mousewheel.h"
#include "src/drivers/sdl/lv_sdl_window.h"

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

    if (run_lua_file(L, script) != 0) {
        lua_close(L);
        return 1;
    }

    while (true) {
        uint32_t delay_ms = lv_timer_handler();

        if (delay_ms < 1) {
            delay_ms = 1;
        } else if (delay_ms > 20) {
            delay_ms = 20;
        }

        usleep(delay_ms * 1000);
    }

    lua_close(L);
    return 0;
}
