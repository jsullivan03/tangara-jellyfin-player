/*
 * Copyright 2023 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "ui/screen_splash.hpp"

#include "core/lv_obj.h"
#include "core/lv_obj_pos.h"
#include "core/lv_obj_style.h"
#include "lvgl.h"
#include "misc/lv_area.h"
#include "misc/lv_color.h"
#include "misc/lv_style.h"

#include "esp_app_desc.h"

LV_IMG_DECLARE(splash);

namespace ui {
namespace screens {

Splash::Splash() {
  lv_obj_t* logo = lv_img_create(root_);
  lv_obj_set_size(logo, lv_pct(100), lv_pct(100));
  lv_obj_set_style_bg_opa(logo, LV_OPA_COVER, 0);
  lv_obj_set_style_bg_color(logo, lv_color_black(), 0);
  lv_img_set_src(logo, &splash);
  lv_obj_center(logo);

  lv_obj_t* version_label = lv_label_create(root_);
  lv_label_set_text(version_label, esp_app_get_description()->version);
  lv_obj_align(version_label, LV_ALIGN_CENTER, 0, 30);
}

Splash::~Splash() {}

}  // namespace screens
}  // namespace ui
