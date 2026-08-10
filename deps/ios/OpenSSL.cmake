# iOS cross build of OpenSSL. Mirrors deps/OpenSSL/OpenSSL.cmake but uses the
# ios64-xcrun / iossimulator-xcrun configuration targets (arm64, sysroot
# handled by xcrun).

if (CMAKE_OSX_SYSROOT MATCHES "[Ss]imulator")
    set(_openssl_target iossimulator-xcrun)
    set(_openssl_min_flag "-mios-simulator-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET}")
else ()
    set(_openssl_target ios64-xcrun)
    set(_openssl_min_flag "-miphoneos-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET}")
endif ()

ExternalProject_Add(dep_OpenSSL
    URL "https://github.com/openssl/openssl/archive/OpenSSL_1_1_1w.tar.gz"
    URL_HASH SHA256=2130E8C2FB3B79D1086186F78E59E8BC8D1A6AEDF17AB3907F4CB9AE20918C41
    DOWNLOAD_DIR ${DEP_DOWNLOAD_DIR}/OpenSSL
    CONFIGURE_COMMAND ./Configure ${_openssl_target}
        "${_openssl_min_flag}"
        "--openssldir=${DESTDIR}"
        "--prefix=${DESTDIR}"
        "--libdir=lib"
        no-shared
        no-asm
        no-ssl3-method
        no-dynamic-engine
    BUILD_IN_SOURCE ON
    BUILD_COMMAND make -j${NPROC}
    INSTALL_COMMAND make -j${NPROC} install_sw
)
