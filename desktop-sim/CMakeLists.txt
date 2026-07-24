cmake_minimum_required(VERSION 3.16)
project(tangara_desktop_sim C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

find_package(PkgConfig REQUIRED)
pkg_check_modules(SDL2 REQUIRED IMPORTED_TARGET sdl2)

# Use a desktop-specific LVGL configuration.
set(
    LV_CONF_PATH
    "${CMAKE_CURRENT_SOURCE_DIR}/lv_conf.h"
    CACHE STRING ""
    FORCE
)

# Keep the first simulator build small.
set(LV_CONF_BUILD_DISABLE_EXAMPLES ON CACHE BOOL "" FORCE)
set(LV_CONF_BUILD_DISABLE_DEMOS ON CACHE BOOL "" FORCE)
set(LV_CONF_BUILD_DISABLE_THORVG_INTERNAL ON CACHE BOOL "" FORCE)

add_subdirectory(
    "${CMAKE_CURRENT_SOURCE_DIR}/../lib/lvgl"
    "${CMAKE_BINARY_DIR}/lvgl"
)

add_executable(tangara-sim main.c)

target_link_libraries(
    tangara-sim
    PRIVATE
    lvgl
    PkgConfig::SDL2
    m
    pthread
)
