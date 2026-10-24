# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(nozelt LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "nozelt")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# The Go/mihomo runtime is built independently as a stable C ABI and shipped
# beside the portable executable for dart:ffi loading.
set(NOZELT_CORE_DLL
  "${CMAKE_CURRENT_SOURCE_DIR}/../../nozelt-core/build/windows/nozelt_core.dll")
if(NOT EXISTS "${NOZELT_CORE_DLL}")
  message(FATAL_ERROR
    "Missing nozelt_core.dll. Run nozelt-core/scripts/build_windows_dll.ps1 first.")
endif()
install(FILES "${NOZELT_CORE_DLL}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)
install(FILES
  "${CMAKE_CURRENT_SOURCE_DIR}/../../nozelt-core/build/windows/nozelt-network-recovery.exe"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../scripts/recover_windows_network.ps1"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../../nozelt-core/third_party/wf/LICENSE"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}/licenses" RENAME "Tailscale-WFP-BSD-3-Clause.txt"
  COMPONENT Runtime)

set(NOZELT_NATIVE_CORES_DIR
  "${CMAKE_CURRENT_SOURCE_DIR}/../../native-cores/build/windows")
foreach(NATIVE_CORE_FILE xray.exe singbox-runner.exe wintun.dll)
  if(NOT EXISTS "${NOZELT_NATIVE_CORES_DIR}/${NATIVE_CORE_FILE}")
    message(FATAL_ERROR
      "Missing ${NATIVE_CORE_FILE}. Build native-cores for Windows first.")
  endif()
  install(FILES "${NOZELT_NATIVE_CORES_DIR}/${NATIVE_CORE_FILE}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
endforeach()

# Xray resolves geoip:/geosite: routing rules from these databases. Keep the
# same pinned assets as Android beside xray.exe so provider-native documents
# behave identically on both platforms.
set(NOZELT_XRAY_ASSETS_DIR
  "${CMAKE_CURRENT_SOURCE_DIR}/../android/app/src/main/assets/xray")
foreach(XRAY_ASSET_FILE geoip.dat geosite.dat)
  if(NOT EXISTS "${NOZELT_XRAY_ASSETS_DIR}/${XRAY_ASSET_FILE}")
    message(FATAL_ERROR
      "Missing Xray asset ${XRAY_ASSET_FILE}. Restore Android Xray assets first.")
  endif()
  install(FILES "${NOZELT_XRAY_ASSETS_DIR}/${XRAY_ASSET_FILE}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
endforeach()

install(FILES
  "${CMAKE_CURRENT_SOURCE_DIR}/../../native-cores/licenses/Mihomo-GPL-3.0.txt"
  "${CMAKE_CURRENT_SOURCE_DIR}/../../native-cores/licenses/Xray-core-MPL-2.0.txt"
  "${CMAKE_CURRENT_SOURCE_DIR}/../../native-cores/licenses/sing-box-GPL-3.0-or-later.txt"
  "${CMAKE_CURRENT_SOURCE_DIR}/../../native-cores/licenses/Wintun-prebuilt-LICENSE.txt"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/licenses"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
