#include "sim_metrics.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

#include <SDL2/SDL.h>
#include <lauxlib.h>
#include <lvgl.h>

#include "luavgl.h"

typedef struct {
  SDL_Window *window;
  SDL_Renderer *renderer;
  SDL_Texture *texture;
  uint8_t *fb1;
  uint8_t *fb2;
  uint8_t *fb_act;
  uint8_t *buf1;
  uint8_t *buf2;
  uint8_t zoom;
  uint8_t ignore_size_chg;
} sim_sdl_window_t;

static bool trace_enabled = false;

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

static int metrics_framebuffer(lua_State *L) {
  lv_display_t *display = lv_display_get_default();

  if (display == NULL) {
    return luaL_error(L, "No default LVGL display");
  }

  sim_sdl_window_t *window = lv_display_get_driver_data(display);

  if (window == NULL || window->fb_act == NULL) {
    return luaL_error(L, "SDL framebuffer is unavailable");
  }

  int32_t width = lv_display_get_horizontal_resolution(display);
  int32_t height = lv_display_get_vertical_resolution(display);
  uint32_t stride = lv_draw_buf_width_to_stride(
      width, lv_display_get_color_format(display));
  size_t size = (size_t)stride * (size_t)height;

  lua_newtable(L);
  lua_pushlstring(L, (const char *)window->fb_act, size);
  lua_setfield(L, -2, "pixels");
  lua_pushinteger(L, width);
  lua_setfield(L, -2, "width");
  lua_pushinteger(L, height);
  lua_setfield(L, -2, "height");
  lua_pushinteger(L, stride);
  lua_setfield(L, -2, "stride");
  return 1;
}

static uint32_t utf8_next(const char *text, size_t *offset) {
  const unsigned char *bytes = (const unsigned char *)text;
  unsigned char first = bytes[*offset];

  if (first == 0) {
    return 0;
  }

  if (first < 0x80) {
    *offset += 1;
    return first;
  }

  int count = first < 0xE0 ? 2 : first < 0xF0 ? 3 : 4;
  uint32_t value = first & (0x7F >> count);

  for (int index = 1; index < count; ++index) {
    unsigned char next = bytes[*offset + (size_t)index];

    if ((next & 0xC0) != 0x80) {
      *offset += 1;
      return 0xFFFD;
    }

    value = (value << 6) | (next & 0x3F);
  }

  *offset += (size_t)count;
  return value;
}

static void audit_label_glyphs(lua_State *L, lv_obj_t *object, int *result_index) {
  if (object == NULL) {
    return;
  }

  if (lv_obj_check_type(object, &lv_label_class)) {
    const char *text = lv_label_get_text(object);
    const lv_font_t *font = lv_obj_get_style_text_font(object, LV_PART_MAIN);
    size_t offset = 0;

    while (text != NULL && text[offset] != '\0') {
      uint32_t codepoint = utf8_next(text, &offset);

      if (codepoint <= 0x20 || codepoint == 0x7F) {
        continue;
      }

      lv_font_glyph_dsc_t descriptor;
      memset(&descriptor, 0, sizeof(descriptor));

      if (codepoint == 0xFFFD || font == NULL ||
          !lv_font_get_glyph_dsc(font, &descriptor, codepoint, 0)) {
        lua_newtable(L);
        lua_pushstring(L, text);
        lua_setfield(L, -2, "text");
        lua_pushinteger(L, (lua_Integer)codepoint);
        lua_setfield(L, -2, "codepoint");
        lua_rawseti(L, -2, (*result_index)++);
      }
    }
  }

  uint32_t children = lv_obj_get_child_count(object);

  for (uint32_t index = 0; index < children; ++index) {
    audit_label_glyphs(
        L,
        lv_obj_get_child(object, (int32_t)index),
        result_index);
  }
}

static int metrics_missing_glyphs(lua_State *L) {
  lv_display_t *display = lv_display_get_default();
  lua_newtable(L);

  if (display == NULL) {
    return 1;
  }

  int result_index = 1;
  audit_label_glyphs(L, lv_display_get_screen_active(display), &result_index);
  return 1;
}

static void table_set_integer(
    lua_State *L, const char *name, lua_Integer value);
static void table_set_pointer(
    lua_State *L, const char *name, const void *value);

static int metrics_timers(lua_State *L) {
  lua_newtable(L);
  int result_index = 1;
  lv_timer_t *timer = NULL;

  while ((timer = lv_timer_get_next(timer)) != NULL) {
    lua_newtable(L);
    table_set_pointer(L, "pointer", timer);
    table_set_integer(L, "period", timer->period);
    table_set_integer(L, "repeat_count", timer->repeat_count);
    lua_pushboolean(L, lv_timer_get_paused(timer));
    lua_setfield(L, -2, "paused");
    lua_rawseti(L, -2, result_index++);
  }

  return 1;
}

static int metrics_wait_ms(lua_State *L) {
  lua_Integer delay_ms = luaL_optinteger(L, 1, 1);

  if (delay_ms < 0) {
    delay_ms = 0;
  }

  usleep((useconds_t)delay_ms * 1000U);
  return 0;
}

static void table_set_integer(
    lua_State *L, const char *name, lua_Integer value) {
  lua_pushinteger(L, value);
  lua_setfield(L, -2, name);
}

static void table_set_pointer(
    lua_State *L, const char *name, const void *value) {
  char text[32];
  snprintf(text, sizeof(text), "%p", value);
  lua_pushstring(L, text);
  lua_setfield(L, -2, name);
}

static int metrics_image_geometry(lua_State *L) {
  lv_obj_t *object = luavgl_to_obj(L, 1);

  if (object == NULL || !lv_obj_check_type(object, &lv_image_class)) {
    return luaL_error(L, "Expected an LVGL image object");
  }

  lv_obj_t *parent = lv_obj_get_parent(object);
  const void *source = lv_image_get_src(object);
  lv_image_header_t header;
  bool decoded = source != NULL &&
                 lv_image_decoder_get_info(source, &header) == LV_RESULT_OK;
  lv_area_t coordinates;
  lv_obj_get_coords(object, &coordinates);
  lv_area_t clip = coordinates;

  if (parent != NULL) {
    lv_area_t parent_coordinates;
    lv_obj_get_coords(parent, &parent_coordinates);
    _lv_area_intersect(&clip, &clip, &parent_coordinates);
  }

  lv_point_t pivot;
  lv_image_get_pivot(object, &pivot);

  lua_newtable(L);
  table_set_pointer(L, "object", object);
  table_set_pointer(L, "parent", parent);
  table_set_pointer(L, "descriptor", source);

  if (source != NULL && lv_image_src_get_type(source) == LV_IMAGE_SRC_FILE) {
    lua_pushstring(L, (const char *)source);
    lua_setfield(L, -2, "source");
  }

  if (decoded) {
    table_set_integer(L, "decoded_width", header.w);
    table_set_integer(L, "decoded_height", header.h);
  }

  table_set_integer(L, "width", lv_obj_get_width(object));
  table_set_integer(L, "height", lv_obj_get_height(object));
  table_set_integer(L, "x", coordinates.x1);
  table_set_integer(L, "y", coordinates.y1);
  table_set_integer(L, "zoom", lv_image_get_scale(object));
  table_set_integer(L, "pivot_x", pivot.x);
  table_set_integer(L, "pivot_y", pivot.y);

  int32_t scale = lv_image_get_scale(object);
  int32_t transformed_x1 =
      coordinates.x1 + pivot.x - (pivot.x * scale) / 256;
  int32_t transformed_y1 =
      coordinates.y1 + pivot.y - (pivot.y * scale) / 256;
  int32_t transformed_x2 = transformed_x1 +
      ((lv_obj_get_width(object) * scale + 255) / 256) - 1;
  int32_t transformed_y2 = transformed_y1 +
      ((lv_obj_get_height(object) * scale + 255) / 256) - 1;
  table_set_integer(L, "transformed_x1", transformed_x1);
  table_set_integer(L, "transformed_y1", transformed_y1);
  table_set_integer(L, "transformed_x2", transformed_x2);
  table_set_integer(L, "transformed_y2", transformed_y2);
  table_set_integer(L, "size_mode", lv_image_get_inner_align(object));
  table_set_integer(L, "offset_x", lv_image_get_offset_x(object));
  table_set_integer(L, "offset_y", lv_image_get_offset_y(object));
  table_set_integer(L, "rotation", lv_image_get_rotation(object));
  table_set_integer(L, "alignment",
                    lv_obj_get_style_align(object, LV_PART_MAIN));
  table_set_integer(L, "transform_width",
                    lv_obj_get_style_transform_width(object, LV_PART_MAIN));
  table_set_integer(L, "transform_height",
                    lv_obj_get_style_transform_height(object, LV_PART_MAIN));
  table_set_integer(L, "clip_x1", clip.x1);
  table_set_integer(L, "clip_y1", clip.y1);
  table_set_integer(L, "clip_x2", clip.x2);
  table_set_integer(L, "clip_y2", clip.y2);

  if (parent != NULL) {
    table_set_integer(L, "parent_width", lv_obj_get_width(parent));
    table_set_integer(L, "parent_height", lv_obj_get_height(parent));
  }

  return 1;
}

static int metrics_trace(lua_State *L) {
  if (!trace_enabled) {
    return 0;
  }

  const char *message = luaL_checkstring(L, 1);
  fprintf(stderr, "[resume-trace %llu] %s\n",
          (unsigned long long)monotonic_us(), message);
  fflush(stderr);
  return 0;
}

static void display_trace_event(lv_event_t *event) {
  if (!trace_enabled) {
    return;
  }

  lv_event_code_t code = lv_event_get_code(event);
  const char *name = NULL;

  switch (code) {
    case LV_EVENT_INVALIDATE_AREA:
      name = "invalidate";
      break;
    case LV_EVENT_REFR_START:
      name = "refresh-start";
      break;
    case LV_EVENT_REFR_READY:
      name = "refresh-ready";
      break;
    case LV_EVENT_RENDER_START:
      name = "render-start";
      break;
    case LV_EVENT_RENDER_READY:
      name = "render-ready";
      break;
    case LV_EVENT_FLUSH_START:
      name = "flush-start";
      break;
    case LV_EVENT_FLUSH_FINISH:
      name = "flush-finish";
      break;
    default:
      return;
  }

  fprintf(stderr, "[resume-trace %llu] display %s",
          (unsigned long long)monotonic_us(), name);

  if (code == LV_EVENT_INVALIDATE_AREA) {
    const lv_area_t *area = lv_event_get_param(event);

    if (area != NULL) {
      fprintf(stderr, " area=(%ld,%ld)-(%ld,%ld)",
              (long)area->x1, (long)area->y1,
              (long)area->x2, (long)area->y2);
    }
  }

  fputc('\n', stderr);
  fflush(stderr);
}

static const luaL_Reg metrics_functions[] = {
    {"now_us", metrics_now_us},
    {"snapshot", metrics_snapshot},
    {"framebuffer", metrics_framebuffer},
    {"missing_glyphs", metrics_missing_glyphs},
    {"timers", metrics_timers},
    {"wait_ms", metrics_wait_ms},
    {"image_geometry", metrics_image_geometry},
    {"trace", metrics_trace},
    {NULL, NULL},
};

int luaopen_sim_metrics(lua_State *L) {
  const char *trace_value = getenv("TANGARA_SIM_RESUME_TRACE");
  trace_enabled = trace_value != NULL &&
                  strcmp(trace_value, "0") != 0 &&
                  strcmp(trace_value, "false") != 0;

  if (trace_enabled) {
    lv_display_t *display = lv_display_get_default();

    if (display != NULL) {
      lv_display_add_event_cb(
          display, display_trace_event, LV_EVENT_ALL, NULL);
    }
  }

  luaL_newlib(L, metrics_functions);
  return 1;
}
