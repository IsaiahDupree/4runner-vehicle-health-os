cmake_minimum_required(VERSION 3.16)

execute_process(
    COMMAND git describe --always --dirty --abbrev=12
    WORKING_DIRECTORY ${CMAKE_CURRENT_LIST_DIR}/../..
    OUTPUT_VARIABLE VHOS_BUILD_ID
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
)

if(NOT VHOS_BUILD_ID)
    set(VHOS_BUILD_ID "unknown")
endif()

add_compile_definitions(VHOS_BUILD_ID="${VHOS_BUILD_ID}")

set(PROJECT_VER "0.1.0-dev.1")
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
idf_build_set_property(MINIMAL_BUILD ON)
project(vhos_ac_sensor_node)
