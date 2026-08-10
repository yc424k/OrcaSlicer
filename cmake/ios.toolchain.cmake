# CMake toolchain for building OrcaSlicer dependencies and libslic3r for iOS (device, arm64).
#
# Usage:
#   cmake -S deps/ios -B deps/build/ios -G Ninja \
#         -DCMAKE_TOOLCHAIN_FILE=<repo>/cmake/ios.toolchain.cmake

set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR arm64)

set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "Target architecture")
set(CMAKE_OSX_SYSROOT iphoneos CACHE STRING "Target SDK")
# FORCE: the top-level CMakeLists pre-seeds an 11.3 macOS deployment target
# before project() (i.e. before this file is read), which must not leak into
# iOS builds. Override the minimum iOS version via ORCA_IOS_DEPLOYMENT_TARGET.
set(ORCA_IOS_DEPLOYMENT_TARGET "16.0" CACHE STRING "Minimum iOS version")
set(CMAKE_OSX_DEPLOYMENT_TARGET "${ORCA_IOS_DEPLOYMENT_TARGET}" CACHE STRING "Minimum iOS version" FORCE)

# Cross-compiled test binaries cannot run on the build host.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# Plain executables (dependency build tools, configure checks) must not be
# turned into .app bundles nor require code signing at build time.
set(CMAKE_MACOSX_BUNDLE OFF)
set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO")

# Build tools (git, compilers, generators) come from the host; libraries must
# come from the iOS SDK or the deps DESTDIR (via CMAKE_PREFIX_PATH), never
# from Homebrew or other macOS prefixes.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)
set(CMAKE_IGNORE_PREFIX_PATH /opt/homebrew /usr/local)
set(CMAKE_IGNORE_PATH /opt/homebrew/lib /opt/homebrew/include /usr/local/lib /usr/local/include)
