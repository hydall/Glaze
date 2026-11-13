# The setup launcher and the tool that packs it; see launcher.cpp.
#
#   cmake -S windows/installer/launcher -B build/setup-launcher
#     -DGLAZE_VERSION=0.9.1
#   cmake --build build/setup-launcher --config Release
cmake_minimum_required(VERSION 3.15)
project(GlazeSetupLauncher LANGUAGES CXX RC)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# Static CRT: the launcher runs before anything is installed, so it cannot
# lean on a Visual C++ runtime being present.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

set(GLAZE_VERSION "0.0.0" CACHE STRING "Version stamped into the file")
string(REGEX REPLACE "[-+].*$" "" _numeric "${GLAZE_VERSION}")
string(REPLACE "." ";" _parts "${_numeric}")
list(LENGTH _parts _count)
while(_count LESS 4)
  list(APPEND _parts 0)
  list(LENGTH _parts _count)
endwhile()
list(JOIN _parts "," _version_number)

add_executable(GlazeSetup WIN32 launcher.cpp launcher.rc)
target_compile_definitions(GlazeSetup PRIVATE UNICODE _UNICODE)
target_link_libraries(GlazeSetup PRIVATE cabinet shell32)
set_source_files_properties(launcher.rc PROPERTIES COMPILE_DEFINITIONS
  "GLAZE_VERSION_NUMBER=${_version_number};GLAZE_VERSION_STRING=\"${GLAZE_VERSION}\"")
if(MSVC)
  # The manifest comes from launcher.rc; the linker's own would clash.
  target_link_options(GlazeSetup PRIVATE /MANIFEST:NO)
endif()

add_executable(setup_pack launcher.cpp)
target_compile_definitions(setup_pack PRIVATE GLAZE_PACKER UNICODE _UNICODE)
target_link_libraries(setup_pack PRIVATE cabinet)
