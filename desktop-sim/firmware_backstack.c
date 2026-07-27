#include "firmware_backstack.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <lauxlib.h>
#include <lvgl.h>

#include "luavgl.h"

#define MAX_SCREEN_DEPTH 64
#define MAX_RETIRED_SCREENS 64

typedef struct {
    lv_obj_t *root;
    lv_obj_t *content;
    lv_obj_t *alert;
    lv_group_t *group;
    int lua_ref;
    uint64_t serial;
} firmware_screen_t;

typedef struct {
    lua_State *L;
    lv_indev_t *keyboard;
    lv_indev_t *wheel;
    firmware_screen_t *current;
    firmware_screen_t *loaded;
    firmware_screen_t *stack[MAX_SCREEN_DEPTH];
    size_t depth;
    firmware_screen_t *retired[MAX_RETIRED_SCREENS];
    size_t retired_count;
    uint64_t next_serial;
    bool load_pending;
} firmware_backstack_state_t;

static firmware_backstack_state_t state;

static void call_method(
    firmware_screen_t *screen,
    const char *name
) {
    lua_State *L = state.L;

    if (screen == NULL || screen->lua_ref == LUA_NOREF) {
        return;
    }

    lua_rawgeti(L, LUA_REGISTRYINDEX, screen->lua_ref);
    lua_getfield(L, -1, name);

    if (!lua_isfunction(L, -1)) {
        lua_pop(L, 2);
        return;
    }

    lua_pushvalue(L, -2);

    if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
        lua_error(L);
        return;
    }

    lua_pop(L, 1);
}

static void activate_screen_context(firmware_screen_t *screen) {
    if (screen == NULL) {
        return;
    }

    luavgl_set_root(state.L, screen->content);
    lv_group_set_default(screen->group);
}

static bool can_pop(firmware_screen_t *screen) {
    lua_State *L = state.L;

    if (screen == NULL || screen->lua_ref == LUA_NOREF) {
        return true;
    }

    lua_rawgeti(L, LUA_REGISTRYINDEX, screen->lua_ref);
    lua_getfield(L, -1, "can_pop");

    if (!lua_isfunction(L, -1)) {
        lua_pop(L, 2);
        return true;
    }

    lua_pushvalue(L, -2);

    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        lua_error(L);
        return false;
    }

    bool result = lua_toboolean(L, -1);
    lua_pop(L, 2);
    return result;
}

static firmware_screen_t *create_native_screen(
    lua_State *L,
    int table_index
) {
    firmware_screen_t *screen = calloc(1, sizeof(*screen));

    if (screen == NULL) {
        luaL_error(L, "Unable to allocate simulator screen");
        return NULL;
    }

    screen->lua_ref = LUA_NOREF;
    screen->serial = ++state.next_serial;
    screen->root = lv_obj_create(NULL);
    screen->content = lv_obj_create(screen->root);
    screen->alert = lv_obj_create(screen->root);
    screen->group = lv_group_create();

    if (
        screen->root == NULL ||
        screen->content == NULL ||
        screen->alert == NULL ||
        screen->group == NULL
    ) {
        luaL_error(L, "Unable to allocate LVGL simulator screen");
        return NULL;
    }

    lv_obj_set_size(screen->root, lv_pct(100), lv_pct(100));
    lv_obj_set_size(screen->content, lv_pct(100), lv_pct(100));
    lv_obj_set_size(screen->alert, LV_SIZE_CONTENT, LV_SIZE_CONTENT);
    lv_obj_center(screen->root);
    lv_obj_center(screen->content);
    lv_obj_center(screen->alert);
    lv_obj_set_style_bg_opa(screen->alert, LV_OPA_TRANSP, 0);
    lv_obj_set_scrollbar_mode(screen->root, LV_SCROLLBAR_MODE_OFF);
    lv_obj_set_scrollbar_mode(screen->content, LV_SCROLLBAR_MODE_OFF);
    lv_group_set_wrap(screen->group, false);

    luavgl_set_root(L, screen->content);
    lv_group_set_default(screen->group);

    table_index = lua_absindex(L, table_index);
    lua_getfield(L, table_index, "create_ui");

    if (lua_isfunction(L, -1)) {
        lua_pushvalue(L, table_index);

        if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
            lua_error(L);
            return NULL;
        }
    } else {
        lua_pop(L, 1);
    }

    lua_pushvalue(L, table_index);
    screen->lua_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    return screen;
}

static void destroy_screen(firmware_screen_t *screen) {
    if (screen == NULL) {
        return;
    }

    if (state.loaded == screen) {
        state.loaded = NULL;
    }

    if (state.L != NULL && screen->lua_ref != LUA_NOREF) {
        luaL_unref(state.L, LUA_REGISTRYINDEX, screen->lua_ref);
        screen->lua_ref = LUA_NOREF;
    }

    if (screen->group != NULL) {
        lv_group_delete(screen->group);
        screen->group = NULL;
    }

    if (screen->root != NULL) {
        lv_obj_delete(screen->root);
        screen->root = NULL;
    }

    free(screen);
}


static void retire_screen(firmware_screen_t *screen) {
    if (screen == NULL) {
        return;
    }

    if (state.retired_count >= MAX_RETIRED_SCREENS) {
        luaL_error(state.L, "Simulator retired-screen queue is full");
        return;
    }

    state.retired[state.retired_count++] = screen;
}

static void destroy_retired_screens(void) {
    for (size_t index = 0; index < state.retired_count; ++index) {
        destroy_screen(state.retired[index]);
        state.retired[index] = NULL;
    }

    state.retired_count = 0;
}

static void make_current(
    firmware_screen_t *next,
    bool replace
) {
    firmware_screen_t *previous = state.current;

    if (previous != NULL) {
        call_method(previous, "on_hide");

        if (!replace) {
            if (state.depth >= MAX_SCREEN_DEPTH) {
                luaL_error(state.L, "Simulator screen stack is full");
                return;
            }

            state.stack[state.depth++] = previous;
        }
    }

    state.current = next;
    activate_screen_context(state.current);
    call_method(state.current, "on_show");
    state.load_pending = true;

    if (replace && previous != NULL) {
        retire_screen(previous);
    }
}

static int backstack_push(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    firmware_screen_t *screen = create_native_screen(L, 1);
    make_current(screen, false);
    return 0;
}

static int backstack_reset(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);

    while (state.depth > 0) {
        destroy_screen(state.stack[--state.depth]);
        state.stack[state.depth] = NULL;
    }

    firmware_screen_t *screen = create_native_screen(L, 1);
    make_current(screen, true);
    return 0;
}

static int backstack_pop(lua_State *L) {
    if (state.current == NULL || state.depth == 0) {
        lua_pushinteger(L, (lua_Integer)state.depth);
        return 1;
    }

    if (!can_pop(state.current)) {
        lua_pushinteger(L, (lua_Integer)state.depth);
        return 1;
    }

    firmware_screen_t *previous = state.current;
    call_method(previous, "on_hide");

    state.current = state.stack[--state.depth];
    state.stack[state.depth] = NULL;

    activate_screen_context(state.current);
    call_method(state.current, "on_show");

    state.load_pending = true;
    retire_screen(previous);

    lua_pushinteger(L, (lua_Integer)state.depth);
    return 1;
}

void firmware_backstack_service(void) {
    if (
        state.current == NULL ||
        (!state.load_pending && state.loaded == state.current)
    ) {
        return;
    }

    lv_screen_load(state.current->root);

    if (state.keyboard != NULL) {
        lv_indev_set_group(state.keyboard, state.current->group);
    }

    if (state.wheel != NULL) {
        lv_indev_set_group(state.wheel, state.current->group);
    }

    lv_group_set_default(state.current->group);
    luavgl_set_root(state.L, state.current->content);

    state.loaded = state.current;
    state.load_pending = false;
    destroy_retired_screens();
}

static int backstack_flush(lua_State *L) {
    int passes = (int)luaL_optinteger(L, 1, 4);

    if (passes < 1) {
        passes = 1;
    }

    firmware_backstack_service();

    for (int index = 0; index < passes; ++index) {
        lv_timer_handler();
        firmware_backstack_service();
    }

    return 0;
}

static int backstack_depth(lua_State *L) {
    lua_pushinteger(L, (lua_Integer)state.depth);
    return 1;
}

static int backstack_current_serial(lua_State *L) {
    if (state.current == NULL) {
        lua_pushnil(L);
    } else {
        lua_pushinteger(L, (lua_Integer)state.current->serial);
    }

    return 1;
}

static int backstack_current(lua_State *L) {
    if (state.current == NULL || state.current->lua_ref == LUA_NOREF) {
        lua_pushnil(L);
    } else {
        lua_rawgeti(L, LUA_REGISTRYINDEX, state.current->lua_ref);
    }

    return 1;
}

static int backstack_is_focused(lua_State *L) {
    if (state.current == NULL) {
        lua_pushboolean(L, false);
        return 1;
    }

    lv_obj_t *object = luavgl_to_obj(L, 1);
    lv_obj_t *focused = lv_group_get_focused(state.current->group);
    lua_pushboolean(L, object != NULL && object == focused);
    return 1;
}

static int backstack_focus(lua_State *L) {
    lv_obj_t *object = luavgl_to_obj(L, 1);

    if (object == NULL) {
        return luaL_error(L, "Expected an LVGL object");
    }

    lv_group_focus_obj(object);
    return 0;
}

static int backstack_snapshot(lua_State *L) {
    lua_newtable(L);

    lua_pushinteger(L, (lua_Integer)state.depth);
    lua_setfield(L, -2, "depth");

    lua_pushboolean(L, state.load_pending);
    lua_setfield(L, -2, "load_pending");

    if (state.current != NULL) {
        lua_pushinteger(L, (lua_Integer)state.current->serial);
        lua_setfield(L, -2, "current_serial");

        lv_obj_t *focused = lv_group_get_focused(state.current->group);
        lua_pushlightuserdata(L, focused);
        lua_setfield(L, -2, "focused_pointer");
    }

    return 1;
}

static const luaL_Reg backstack_functions[] = {
    {"push", backstack_push},
    {"pop", backstack_pop},
    {"reset", backstack_reset},
    {"flush", backstack_flush},
    {"depth", backstack_depth},
    {"current_serial", backstack_current_serial},
    {"current", backstack_current},
    {"is_focused", backstack_is_focused},
    {"focus", backstack_focus},
    {"snapshot", backstack_snapshot},
    {NULL, NULL},
};

int luaopen_firmware_backstack(lua_State *L) {
    luaL_newlib(L, backstack_functions);
    return 1;
}

void firmware_backstack_init(
    lua_State *L,
    lv_indev_t *keyboard,
    lv_indev_t *wheel
) {
    memset(&state, 0, sizeof(state));
    state.L = L;
    state.keyboard = keyboard;
    state.wheel = wheel;
}

void firmware_backstack_shutdown(void) {
    if (state.current != NULL) {
        destroy_screen(state.current);
        state.current = NULL;
    }

    while (state.depth > 0) {
        destroy_screen(state.stack[--state.depth]);
        state.stack[state.depth] = NULL;
    }

    destroy_retired_screens();
    state.loaded = NULL;
    state.L = NULL;
}
