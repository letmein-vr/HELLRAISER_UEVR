# See https://github.com/build-cpp/cmkr for more information

cmake_minimum_required(VERSION 3.15)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_BINARY_DIR)
	message(FATAL_ERROR "In-tree builds are not supported. Run CMake from a separate directory: cmake -B build")
endif()

# Regenerate CMakeLists.txt automatically in the root project
set(CMKR_ROOT_PROJECT OFF)
if(CMAKE_CURRENT_SOURCE_DIR STREQUAL CMAKE_SOURCE_DIR)
	set(CMKR_ROOT_PROJECT ON)


	# Enable folder support
	set_property(GLOBAL PROPERTY USE_FOLDERS ON)
endif()


 
add_compile_options($<$<CXX_COMPILER_ID:MSVC>:/MP>)

project(HellraiserAimFix-proj)

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} /MP")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /MP")

set(ASMJIT_STATIC ON CACHE BOOL "" FORCE)

if ("${CMAKE_BUILD_TYPE}" MATCHES "Release")
    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} /MT")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /MT")

    # Statically compile runtime
    string(REGEX REPLACE "/MD" "/MT" CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS}")
    string(REGEX REPLACE "/MD" "/MT" CMAKE_C_FLAGS "${CMAKE_C_FLAGS}")
    string(REGEX REPLACE "/MD" "/MT" CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE}")
    string(REGEX REPLACE "/MD" "/MT" CMAKE_C_FLAGS_RELEASE "${CMAKE_C_FLAGS_RELEASE}")

    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")
    message(NOTICE "Building in Release mode")
endif()

include(FetchContent)

message(STATUS "Fetching bddisasm (v1.34.10)...")
FetchContent_Declare(bddisasm
	GIT_REPOSITORY
		"https://github.com/bitdefender/bddisasm"
	GIT_TAG
		v1.34.10
)
FetchContent_MakeAvailable(bddisasm)

message(STATUS "Fetching spdlog (76fb40d95455f249bd70824ecfcae7a8f0930fa3)...")
FetchContent_Declare(spdlog
	GIT_REPOSITORY
		"https://github.com/gabime/spdlog"
	GIT_TAG
		76fb40d95455f249bd70824ecfcae7a8f0930fa3
)
FetchContent_MakeAvailable(spdlog)

message(STATUS "Fetching kananlib (153b177593a97042a57608b36d4253fa5e982914)...")
FetchContent_Declare(kananlib
	GIT_REPOSITORY
		"https://github.com/cursey/kananlib"
	GIT_TAG
		153b177593a97042a57608b36d4253fa5e982914
)
FetchContent_MakeAvailable(kananlib)

# Target glm_static
set(CMKR_TARGET glm_static)
set(glm_static_SOURCES "")

list(APPEND glm_static_SOURCES
	"D:/Claude Dev/OW2AimFixProject/dependencies/glm/glm/detail/glm.cpp"
)

list(APPEND glm_static_SOURCES
)

set(CMKR_SOURCES ${glm_static_SOURCES})
add_library(glm_static STATIC)

if(glm_static_SOURCES)
	target_sources(glm_static PRIVATE ${glm_static_SOURCES})
endif()


target_include_directories(glm_static PUBLIC
	"D:/Claude Dev/OW2AimFixProject/dependencies/glm"
)

unset(CMKR_TARGET)
unset(CMKR_SOURCES)

# Target HellraiserAimFix
set(CMKR_TARGET HellraiserAimFix)
set(HellraiserAimFix_SOURCES "")

list(APPEND HellraiserAimFix_SOURCES
	"src/Plugin.cpp"
	"src/Plugin.hpp"
	"D:/UEVR Dev/UEVR-PureDark-AFW-Joey-Merged-updated/include/uevr/API.hpp"
	"D:/UEVR Dev/UEVR-PureDark-AFW-Joey-Merged-updated/include/uevr/Plugin.hpp"
	"D:/UEVR Dev/UEVR-PureDark-AFW-Joey-Merged-updated/include/uevr/API.h"
)

list(APPEND HellraiserAimFix_SOURCES
)

set(CMKR_SOURCES ${HellraiserAimFix_SOURCES})
add_library(HellraiserAimFix SHARED)

if(HellraiserAimFix_SOURCES)
	target_sources(HellraiserAimFix PRIVATE ${HellraiserAimFix_SOURCES})
endif()



target_compile_features(HellraiserAimFix PUBLIC
	cxx_std_23
)

target_compile_options(HellraiserAimFix PUBLIC
	"/GS-"
	"/bigobj"
	"/EHa"
	"/MP"
)

target_include_directories(HellraiserAimFix PUBLIC
	"shared/"
	"src/"
	"D:/UEVR Dev/UEVR-PureDark-AFW-Joey-Merged-updated/include/"
	"include/"
)

target_link_libraries(HellraiserAimFix PUBLIC
	kananlib
	glm_static
	bddisasm
)
target_include_directories(HellraiserAimFix PRIVATE ${bddisasm_SOURCE_DIR}/inc)

target_compile_definitions(HellraiserAimFix PUBLIC 
    NOMINMAX
    WINVER=0x0A00
)

unset(CMKR_TARGET)
unset(CMKR_SOURCES)

