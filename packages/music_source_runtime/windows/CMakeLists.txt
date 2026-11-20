cmake_minimum_required(VERSION 3.10)
set(PROJECT_NAME "music_source_runtime")
project(${PROJECT_NAME} LANGUAGES CXX C)

cmake_policy(VERSION 3.10...3.24)

set(PLUGIN_NAME "${PROJECT_NAME}_plugin")

# ---- QuickJS: compiled as C11 with MSVC stdatomic support ----
set(QUICKJS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/quickjs")
add_library(quickjs_msr STATIC "${QUICKJS_DIR}/quickjs-amalgam.c")
set_source_files_properties("${QUICKJS_DIR}/quickjs-amalgam.c" PROPERTIES LANGUAGE C)
target_include_directories(quickjs_msr PUBLIC "${QUICKJS_DIR}")
target_compile_options(quickjs_msr PRIVATE
  "$<$<C_COMPILER_ID:MSVC>:/utf-8>"
  "$<$<C_COMPILER_ID:MSVC>:/std:c11>"
  "$<$<C_COMPILER_ID:MSVC>:/experimental:c11atomics>"
)

# ---- Plugin shared library ----
add_library(${PLUGIN_NAME} SHARED
  "include/music_source_runtime/music_source_runtime_plugin.h"
  "music_source_runtime_plugin.cpp"
  "music_source_bridge.cpp"
  "music_source_bridge.h"
  "music_source_crypto.cpp"
  "music_source_crypto.h"
)
apply_standard_settings(${PLUGIN_NAME})
# bridge.cpp contains UTF-8 Chinese string literals; MSVC must treat source and
# execution charset as UTF-8 or C2001 ("newline in constant") is emitted.
target_compile_options(${PLUGIN_NAME} PRIVATE
  "$<$<CXX_COMPILER_ID:MSVC>:/utf-8>"
)
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE "${QUICKJS_DIR}")
target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter flutter_wrapper_plugin
  quickjs_msr
  bcrypt.lib crypt32.lib
)

# Copy the preload script next to the plugin DLL for build-tree runs, and list
# it as a bundled library so the install step also places it beside the exe.
add_custom_command(TARGET ${PLUGIN_NAME} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/music_source_preload.js"
    "$<TARGET_FILE_DIR:${PLUGIN_NAME}>/music_source_preload.js"
)

set(${PROJECT_NAME}_bundled_libraries
  "${CMAKE_CURRENT_SOURCE_DIR}/music_source_preload.js"
  PARENT_SCOPE
)
