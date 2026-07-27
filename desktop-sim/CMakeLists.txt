cmake_minimum_required(VERSION 3.16)
project(tangara_desktop_sim C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

find_package(PkgConfig REQUIRED)
pkg_check_modules(SDL2 REQUIRED IMPORTED_TARGET sdl2)
pkg_check_modules(LUA53 REQUIRED IMPORTED_TARGET lua53)

set(
    LV_CONF_PATH
    "${CMAKE_CURRENT_SOURCE_DIR}/lv_conf.h"
    CACHE STRING ""
    FORCE
)

set(LV_CONF_BUILD_DISABLE_EXAMPLES ON CACHE BOOL "" FORCE)
set(LV_CONF_BUILD_DISABLE_DEMOS ON CACHE BOOL "" FORCE)
set(LV_CONF_BUILD_DISABLE_THORVG_INTERNAL ON CACHE BOOL "" FORCE)

add_subdirectory(
    "${CMAKE_CURRENT_SOURCE_DIR}/../lib/lvgl"
    "${CMAKE_BINARY_DIR}/lvgl"
)

add_executable(
    tangara-sim
    main.c
    firmware_backstack.c
    sim_metrics.c
    "${CMAKE_CURRENT_SOURCE_DIR}/../lib/luavgl/src/luavgl.c"
)

target_include_directories(
    tangara-sim
    PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/../lib/luavgl/src"
    "${CMAKE_CURRENT_SOURCE_DIR}/../lib/lvgl/src"
)

target_compile_options(
    tangara-sim
    PRIVATE
    -Wno-cast-function-type
    -Wno-type-limits
)

target_link_libraries(
    tangara-sim
    PRIVATE
    lvgl
    PkgConfig::SDL2
    PkgConfig::LUA53
    m
    pthread
)
