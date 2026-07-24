#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

#include <lvgl.h>

#include "src/drivers/sdl/lv_sdl_keyboard.h"
#include "src/drivers/sdl/lv_sdl_mouse.h"
#include "src/drivers/sdl/lv_sdl_mousewheel.h"
#include "src/drivers/sdl/lv_sdl_window.h"

static lv_obj_t *status_label;

static void button_clicked(lv_event_t *event)
{
    (void)event;
    lv_label_set_text(status_label, "Button works!");
}

int main(void)
{
    lv_init();

    lv_display_t *display = lv_sdl_window_create(160, 128);

    if (display == NULL) {
        fprintf(stderr, "Failed to create SDL display.\n");
        return 1;
    }

    /* 3x scale gives a 480 x 384 desktop window. */
    lv_sdl_window_set_zoom(display, 3.0f);
    lv_sdl_window_set_title(display, "Tangara UI Simulator");
    lv_sdl_window_set_resizeable(display, true);

    lv_indev_t *mouse = lv_sdl_mouse_create();
    lv_indev_t *keyboard = lv_sdl_keyboard_create();
    lv_indev_t *wheel = lv_sdl_mousewheel_create();

    (void)mouse;

    lv_group_t *group = lv_group_create();
    lv_group_set_default(group);

    lv_indev_set_group(keyboard, group);
    lv_indev_set_group(wheel, group);

    lv_obj_t *screen = lv_screen_active();
    lv_obj_set_style_bg_color(screen, lv_color_hex(0x10131A), 0);

    lv_obj_t *title = lv_label_create(screen);
    lv_label_set_text(title, "Tangara");
    lv_obj_set_style_text_color(title, lv_color_hex(0xFFFFFF), 0);
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 10);

    status_label = lv_label_create(screen);
    lv_label_set_text(status_label, "Desktop simulator ready");
    lv_obj_set_style_text_color(status_label, lv_color_hex(0xAEB7C5), 0);
    lv_obj_align(status_label, LV_ALIGN_CENTER, 0, -4);

    lv_obj_t *button = lv_button_create(screen);
    lv_obj_set_size(button, 76, 28);
    lv_obj_align(button, LV_ALIGN_BOTTOM_MID, 0, -8);
    lv_obj_add_event_cb(button, button_clicked, LV_EVENT_CLICKED, NULL);

    lv_obj_t *button_label = lv_label_create(button);
    lv_label_set_text(button_label, "Continue");
    lv_obj_center(button_label);

    lv_group_add_obj(group, button);
    lv_group_focus_obj(button);

    while (true) {
        uint32_t delay_ms = lv_timer_handler();

        if (delay_ms < 1) {
            delay_ms = 1;
        } else if (delay_ms > 20) {
            delay_ms = 20;
        }

        usleep(delay_ms * 1000);
    }

    return 0;
}
