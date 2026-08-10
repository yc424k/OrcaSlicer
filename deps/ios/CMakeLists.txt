if(${CMAKE_VERSION} VERSION_GREATER_EQUAL "4.0")
    set(CMAKE_POLICY_VERSION_MINIMUM 3.5 CACHE STRING "" FORCE)
endif()

#
# iOS dependency bundle for the iPad port.
#
# Builds the subset of OrcaSlicer dependencies needed by libslic3r (no GUI):
# no wxWidgets/GLEW/GLFW/OpenCSG/python, no OCCT (STEP import disabled on iOS),
# no OpenCV (colored-OBJ import disabled on iOS), no CURL (networking is done
# natively by the iOS app).
#
# Configure and build:
#   cmake -S deps/ios -B deps/build/ios -G Ninja \
#         -DCMAKE_TOOLCHAIN_FILE=<repo>/cmake/ios.toolchain.cmake
#   cmake --build deps/build/ios
#

cmake_minimum_required(VERSION 3.20)

if(POLICY CMP0135) # DOWNLOAD_EXTRACT_TIMESTAMP
    cmake_policy(SET CMP0135 NEW)
endif()

project(OrcaSlicer-deps-ios C CXX)

if (NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    message(FATAL_ERROR "This project must be configured with the iOS toolchain: "
            "-DCMAKE_TOOLCHAIN_FILE=<repo>/cmake/ios.toolchain.cmake")
endif ()

include(ExternalProject)
include(ProcessorCount)

ProcessorCount(NPROC)
if (NPROC EQUAL 0)
    set(NPROC 1)
endif ()

# Share the download cache with the desktop deps build.
set(DEP_DOWNLOAD_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../DL_CACHE CACHE PATH "Path for downloaded source packages.")

set(DESTDIR "${CMAKE_BINARY_DIR}/OrcaSlicer_dep_ios" CACHE PATH "Path to dependencies install directory")
set(DESTDIR "${DESTDIR}/usr/local/")

if (NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif ()

find_package(Git REQUIRED)
set(PATCH_CMD ${GIT_EXECUTABLE} apply --verbose --ignore-space-change --whitespace=fix)

get_filename_component(CMAKE_TOOLCHAIN_FILE "${CMAKE_TOOLCHAIN_FILE}" ABSOLUTE BASE_DIR "${CMAKE_BINARY_DIR}")

# The included per-dependency scripts branch on this for macOS arm/x86 cross
# builds; for iOS we always take the plain path and rely on the toolchain file.
set(IS_CROSS_COMPILE FALSE)

execute_process(
    COMMAND ${GIT_EXECUTABLE} rev-parse --is-inside-work-tree
    RESULT_VARIABLE REV_PARSE_RESULT
    OUTPUT_VARIABLE REV_PARSE_OUTPUT
    OUTPUT_STRIP_TRAILING_WHITESPACE
)
if((REV_PARSE_RESULT EQUAL 0) AND (REV_PARSE_OUTPUT STREQUAL "true"))
    set(IN_GIT_REPO TRUE)
    # Relative path from the repository root, used by patch steps (git apply --directory).
    file(RELATIVE_PATH BINARY_DIR_REL ${CMAKE_SOURCE_DIR}/../.. ${CMAKE_BINARY_DIR})
endif ()

set(DEP_CMAKE_OPTS
    "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
    # Forward the resolved sysroot: the toolchain file alone would default the
    # sub-builds to the device SDK even when this project targets the simulator.
    "-DCMAKE_OSX_SYSROOT=${CMAKE_OSX_SYSROOT}"
    "-DCMAKE_OSX_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET}"
    "-DCMAKE_FIND_FRAMEWORK=LAST"
    "-DCMAKE_FIND_APPBUNDLE=LAST"
)

function(orcaslicer_add_cmake_project projectname)
    cmake_parse_arguments(P_ARGS "FORWARD_CONFIG" "INSTALL_DIR;BUILD_COMMAND;INSTALL_COMMAND" "CMAKE_ARGS" ${ARGN})

    ExternalProject_Add(
        dep_${projectname}
        EXCLUDE_FROM_ALL    ON
        INSTALL_DIR         ${DESTDIR}
        DOWNLOAD_DIR        ${DEP_DOWNLOAD_DIR}/${projectname}
        CMAKE_ARGS
            -DCMAKE_POLICY_VERSION_MINIMUM=3.5
            -DCMAKE_INSTALL_PREFIX:STRING=${DESTDIR}
            -DCMAKE_MODULE_PATH:STRING=${PROJECT_SOURCE_DIR}/../../cmake/modules
            -DCMAKE_PREFIX_PATH:STRING=${DESTDIR}
            -DCMAKE_DEBUG_POSTFIX:STRING=d
            -DCMAKE_TOOLCHAIN_FILE:STRING=${CMAKE_TOOLCHAIN_FILE}
            -DCMAKE_BUILD_TYPE:STRING=${CMAKE_BUILD_TYPE}
            -DBUILD_SHARED_LIBS:BOOL=OFF
            ${DEP_CMAKE_OPTS}
            ${P_ARGS_CMAKE_ARGS}
        ${P_ARGS_UNPARSED_ARGUMENTS}
        BUILD_COMMAND ${CMAKE_COMMAND} --build . --config Release -- -j${NPROC}
        INSTALL_COMMAND ${CMAKE_COMMAND} --build . --target install --config Release
    )
endfunction(orcaslicer_add_cmake_project)

# No dep_ZLIB on iOS: building zlib breaks against the iOS SDK (zutil.h
# redefines fdopen on Apple platforms) and the SDK ships its own libz anyway.
set(ZLIB_PKG "")
include(${CMAKE_CURRENT_SOURCE_DIR}/../PNG/PNG.cmake)
set(PNG_PKG dep_PNG)
include(${CMAKE_CURRENT_SOURCE_DIR}/../EXPAT/EXPAT.cmake)
set(EXPAT_PKG dep_EXPAT)

include(${CMAKE_CURRENT_SOURCE_DIR}/../Boost/Boost.cmake)
include(${CMAKE_CURRENT_SOURCE_DIR}/../Cereal/Cereal.cmake)
include(${CMAKE_CURRENT_SOURCE_DIR}/../Qhull/Qhull.cmake)
include(${CMAKE_CURRENT_SOURCE_DIR}/../TBB/TBB.cmake)

include(${CMAKE_CURRENT_SOURCE_DIR}/../Blosc/Blosc.cmake)
include(${CMAKE_CURRENT_SOURCE_DIR}/../OpenEXR/OpenEXR.cmake)
include(${CMAKE_CURRENT_SOURCE_DIR}/OpenVDB.cmake)

# iOS-specific cross builds of the autotools/perl based dependencies.
include(${CMAKE_CURRENT_SOURCE_DIR}/GMP.cmake)
include(${CMAKE_CURRENT_SOURCE_DIR}/MPFR.cmake)
include(${CMAKE_CURRENT_SOURCE_DIR}/Eigen.cmake)
include(${CMAKE_CURRENT_SOURCE_DIR}/../CGAL/CGAL.cmake)

include(${CMAKE_CURRENT_SOURCE_DIR}/../NLopt/NLopt.cmake)
include(${CMAKE_CURRENT_SOURCE_DIR}/../libnoise/libnoise.cmake)
include(${CMAKE_CURRENT_SOURCE_DIR}/../Draco/Draco.cmake)

include(${CMAKE_CURRENT_SOURCE_DIR}/OpenSSL.cmake)

include(${CMAKE_CURRENT_SOURCE_DIR}/../JPEG/JPEG.cmake)
include(${CMAKE_CURRENT_SOURCE_DIR}/../FREETYPE/FREETYPE.cmake)

add_custom_target(deps ALL DEPENDS
    dep_PNG
    dep_EXPAT
    dep_Boost
    dep_Cereal
    dep_Qhull
    dep_TBB
    dep_Blosc
    dep_OpenEXR
    dep_OpenVDB
    dep_GMP
    dep_MPFR
    dep_Eigen
    dep_CGAL
    dep_NLopt
    dep_libnoise
    dep_Draco
    dep_OpenSSL
    dep_JPEG
    dep_FREETYPE
)
