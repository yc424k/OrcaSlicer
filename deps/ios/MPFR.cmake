# iOS cross build of MPFR. Mirrors deps/MPFR/MPFR.cmake but targets the
# iphoneos SDK and skips autoreconf (not installed on the host; the release
# tarball already ships a working configure).

ExternalProject_Add(dep_MPFR
    URL https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.2.tar.bz2
        https://www.mpfr.org/mpfr-4.2.2/mpfr-4.2.2.tar.bz2
    URL_HASH SHA256=9ad62c7dc910303cd384ff8f1f4767a655124980bb6d8650fe62c815a231bb7b
    DOWNLOAD_DIR ${DEP_DOWNLOAD_DIR}/MPFR
    BUILD_IN_SOURCE ON
    # Refresh autotools output timestamps so make does not try to re-run
    # autoconf/automake (not installed on the host) after extraction.
    PATCH_COMMAND sh -c "touch aclocal.m4 && find . -name Makefile.in -exec touch {} + && touch configure"
    CONFIGURE_COMMAND env "CC=${CMAKE_C_COMPILER}" "CXX=${CMAKE_CXX_COMPILER}" "CFLAGS=${_gmp_ccflags}" "CXXFLAGS=${_gmp_ccflags}" ./configure --prefix=${DESTDIR} --enable-shared=no --enable-static=yes --with-gmp=${DESTDIR} ${_gmp_build_tgt}
    BUILD_COMMAND make -j${NPROC}
    INSTALL_COMMAND make install
    DEPENDS dep_GMP
)
