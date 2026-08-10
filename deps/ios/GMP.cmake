# iOS cross build of GMP. Mirrors deps/GMP/GMP.cmake but targets the iphoneos SDK.
# Note: no git-apply --directory flag here — the patch is a traditional unified
# diff, which git refuses to combine with --directory; applying from the source
# directory works because git prefixes the in-worktree cwd automatically.

# Device vs. simulator: both are arm64, but use different SDKs and min-version flags.
if (CMAKE_OSX_SYSROOT MATCHES "[Ss]imulator")
    set(_ios_sdk_name iphonesimulator)
    set(_ios_min_flag "-mios-simulator-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET}")
else ()
    set(_ios_sdk_name iphoneos)
    set(_ios_min_flag "-miphoneos-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET}")
endif ()

execute_process(COMMAND xcrun --sdk ${_ios_sdk_name} --show-sdk-path
                OUTPUT_VARIABLE _ios_sdk_path OUTPUT_STRIP_TRAILING_WHITESPACE)
execute_process(COMMAND uname -r
                OUTPUT_VARIABLE _darwin_release OUTPUT_STRIP_TRAILING_WHITESPACE)

# --build carries the host kernel version so it differs from --host, forcing
# configure into cross-compilation mode (it must not run iOS test binaries).
set(_gmp_build_tgt --build=aarch64-apple-darwin${_darwin_release} --host=aarch64-apple-darwin)
set(_gmp_ccflags "-O2 -DNDEBUG -fPIC -DPIC -fomit-frame-pointer -fno-common -arch arm64 -isysroot ${_ios_sdk_path} ${_ios_min_flag}")

ExternalProject_Add(dep_GMP
    URL https://github.com/SoftFever/OrcaSlicer_deps/releases/download/gmp-6.2.1/gmp-6.2.1.tar.bz2
    URL_HASH SHA256=eae9326beb4158c386e39a356818031bd28f3124cf915f8c5b1dc4c7a36b4d7c
    DOWNLOAD_DIR ${DEP_DOWNLOAD_DIR}/GMP
    # Idempotent (a reverse-check detects an already-patched tree, so re-running
    # the patch step on a warm source dir is safe). The touch afterwards
    # refreshes autotools output timestamps so make does not try to re-run
    # autoconf/automake (not installed on the host).
    PATCH_COMMAND sh -c "git apply --verbose ${CMAKE_CURRENT_LIST_DIR}/../GMP/0001-GMP_GCC15.patch || git apply --reverse --check ${CMAKE_CURRENT_LIST_DIR}/../GMP/0001-GMP_GCC15.patch"
          COMMAND sh -c "touch aclocal.m4 && find . -name Makefile.in -exec touch {} + && touch configure"
    BUILD_IN_SOURCE ON
    CONFIGURE_COMMAND env "CC=${CMAKE_C_COMPILER}" "CXX=${CMAKE_CXX_COMPILER}" "CFLAGS=${_gmp_ccflags}" "CXXFLAGS=${_gmp_ccflags}" ./configure --enable-shared=no --enable-cxx=yes --enable-static=yes "--prefix=${DESTDIR}" ${_gmp_build_tgt}
    BUILD_COMMAND     make -j${NPROC}
    INSTALL_COMMAND   make install
)
