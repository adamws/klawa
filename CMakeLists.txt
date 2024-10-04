cmake_minimum_required(VERSION 3.16)
project(klawa)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

find_package(SDL2 REQUIRED)
find_package(SDL2_image REQUIRED)
find_package(X11 REQUIRED)

add_executable(${CMAKE_PROJECT_NAME}
  src/main.c
)
target_link_libraries(${CMAKE_PROJECT_NAME}
  SDL2::SDL2
  SDL2_image::SDL2_image
  m
  X11::X11
  X11::Xi
)

add_custom_command(
  TARGET ${CMAKE_PROJECT_NAME} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_directory
    "$<TARGET_PROPERTY:${CMAKE_PROJECT_NAME},SOURCE_DIR>/assets"
    "$<TARGET_PROPERTY:${CMAKE_PROJECT_NAME},BINARY_DIR>/assets"
)
