# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "rust_lib_vnt_app")
project(${PROJECT_NAME} LANGUAGES CXX)

set(RUST_MANIFEST_DIR "${CMAKE_CURRENT_LIST_DIR}/../../../../../../rust")
set(RUST_RELEASE_DIR "${RUST_MANIFEST_DIR}/target/release")
set(RUST_OUTPUT_DLL "${CMAKE_CURRENT_BINARY_DIR}/Release/rust_lib_vnt_app.dll")

file(GLOB_RECURSE RUST_SOURCE_FILES
  "${RUST_MANIFEST_DIR}/src/*.rs"
  "${RUST_MANIFEST_DIR}/Cargo.toml"
  "${RUST_MANIFEST_DIR}/Cargo.lock"
  "${RUST_MANIFEST_DIR}/build.rs"
  "${RUST_MANIFEST_DIR}/vendor/tun-rs-2.5.7/*"
)

add_custom_command(
  OUTPUT "${RUST_OUTPUT_DLL}"
  COMMAND "${CMAKE_COMMAND}" -E env
          "CARGO_NET_GIT_FETCH_WITH_CLI=true"
          cargo.exe
          build
          --manifest-path "${RUST_MANIFEST_DIR}/Cargo.toml"
          --release
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/Release"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
          "${RUST_RELEASE_DIR}/rust_lib_vnt_app.dll"
          "${RUST_OUTPUT_DLL}"
  DEPENDS ${RUST_SOURCE_FILES}
  WORKING_DIRECTORY "${RUST_MANIFEST_DIR}"
  VERBATIM
)

add_custom_target(${PROJECT_NAME}_build ALL DEPENDS "${RUST_OUTPUT_DLL}")

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(rust_lib_vnt_app_bundled_libraries
  "${RUST_OUTPUT_DLL}"
  PARENT_SCOPE
)
