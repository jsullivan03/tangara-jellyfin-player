#include "sim_metrics.h"

#include <stdint.h>
#include <stdio.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

#include <lauxlib.h>
#include <lvgl.h>

static uint64_t monotonic_us(void) {
  struct timespec value;

  if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) {
    return 0;
  }

  return (uint64_t)value.tv_sec * 1000000ULL +
         (uint64_t)value.tv_nsec / 1000ULL;
}

static uint32_t object_tree_count(lv_obj_t *object) {
  if (object == NULL) {
    return 0;
  }

  uint32_t count = 1;
  uint32_t children = lv_obj_get_child_count(object);

  for (uint32_t index = 0; index < children; ++index) {
    count += object_tree_count(lv_obj_get_child(object, (int32_t)index));
  }

  return count;
}

static uint32_t active_object_count(void) {
  lv_display_t *display = lv_display_get_default();

  if (display == NULL) {
    return 0;
  }

  return object_tree_count(lv_display_get_screen_active(display));
}

static uint32_t active_timer_count(void) {
  uint32_t count = 0;
  lv_timer_t *timer = NULL;

  while ((timer = lv_timer_get_next(timer)) != NULL) {
    ++count;
  }

  return count;
}

static uint64_t current_rss_kb(void) {
  FILE *file = fopen("/proc/self/statm", "r");

  if (file == NULL) {
    return 0;
  }

  unsigned long total_pages = 0;
  unsigned long resident_pages = 0;
  int scanned = fscanf(file, "%lu %lu", &total_pages, &resident_pages);
  fclose(file);
  (void)total_pages;

  if (scanned != 2) {
    return 0;
  }

  long page_size = sysconf(_SC_PAGESIZE);

  if (page_size <= 0) {
    return 0;
  }

  return (uint64_t)resident_pages * (uint64_t)page_size / 1024ULL;
}

static uint64_t maximum_rss_kb(void) {
  struct rusage usage;

  if (getrusage(RUSAGE_SELF, &usage) != 0) {
    return 0;
  }

  return (uint64_t)usage.ru_maxrss;
}

static double lua_memory_kb(lua_State *L) {
  int kilobytes = lua_gc(L, LUA_GCCOUNT, 0);
  int bytes = lua_gc(L, LUA_GCCOUNTB, 0);

  return (double)kilobytes + (double)bytes / 1024.0;
}

static int metrics_now_us(lua_State *L) {
  lua_pushinteger(L, (lua_Integer)monotonic_us());
  return 1;
}

static int metrics_snapshot(lua_State *L) {
  lua_newtable(L);

  lua_pushinteger(L, (lua_Integer)active_object_count());
  lua_setfield(L, -2, "active_objects");

  lua_pushinteger(L, (lua_Integer)active_timer_count());
  lua_setfield(L, -2, "timers");

  lua_pushnumber(L, lua_memory_kb(L));
  lua_setfield(L, -2, "lua_kb");

  lua_pushinteger(L, (lua_Integer)current_rss_kb());
  lua_setfield(L, -2, "rss_kb");

  lua_pushinteger(L, (lua_Integer)maximum_rss_kb());
  lua_setfield(L, -2, "max_rss_kb");

  return 1;
}

static const luaL_Reg metrics_functions[] = {
    {"now_us", metrics_now_us},
    {"snapshot", metrics_snapshot},
    {NULL, NULL},
};

int luaopen_sim_metrics(lua_State *L) {
  luaL_newlib(L, metrics_functions);
  return 1;
}
