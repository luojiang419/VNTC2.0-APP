# This file controls Flutter-level build steps. It should not be edited.
cmake_minimum_required(VERSION 3.14)

set(DUPLICATION_LIBRARY "${CMAKE_CURRENT_BINARY_DIR}/Debug/duplication.dll")

# Published to parent scope for install step.
set(DUPLICATION_LIBRARY ${DUPLICATION_LIBRARY} PARENT_SCOPE)

add_library(duplication SHARED
  "DDAImpl.cpp"
  "DDAImpl.h"
)

set_target_properties(duplication PROPERTIES
  POSITION_INDEPENDENT_CODE ON)