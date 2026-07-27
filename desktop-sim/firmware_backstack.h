#pragma once

#include <lua.h>
#include <lvgl.h>

void firmware_backstack_init(
    lua_State *L,
    lv_indev_t *keyboard,
    lv_indev_t *wheel
);

void firmware_backstack_service(void);
void firmware_backstack_shutdown(void);
int luaopen_firmware_backstack(lua_State *L);
