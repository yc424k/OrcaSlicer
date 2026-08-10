# iOS build of Eigen. Mirrors deps/Eigen/Eigen.cmake but disables the BLAS and
# LAPACK sub-libraries: their Fortran sources get compiled for macOS by the
# host gfortran (which cannot target iOS), and libslic3r only uses the headers.

orcaslicer_add_cmake_project(Eigen
    URL https://gitlab.com/libeigen/eigen/-/archive/5.0.1/eigen-5.0.1.zip
    URL_HASH SHA256=0dbb1f9e3aaad66f352c03227d8c983f6f0b49e0b07e71a7300f4abcc01aee12
    CMAKE_ARGS
        -DEIGEN_BUILD_BLAS:BOOL=OFF
        -DEIGEN_BUILD_LAPACK:BOOL=OFF
        -DEIGEN_BUILD_DEMOS:BOOL=OFF
        -DEIGEN_BUILD_TESTING:BOOL=OFF
    DEPENDS dep_Boost dep_GMP dep_MPFR
)
