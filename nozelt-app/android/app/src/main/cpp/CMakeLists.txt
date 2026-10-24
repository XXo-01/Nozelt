cmake_minimum_required(VERSION 3.22.1)
project(nozelt_native)

add_library(
    nozelt_spawn
    SHARED
    native_core_process.cpp
)

find_library(log-lib log)
target_link_libraries(nozelt_spawn ${log-lib})
