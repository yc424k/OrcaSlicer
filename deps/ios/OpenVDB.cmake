# iOS build of OpenVDB. Mirrors deps/OpenVDB/OpenVDB.cmake, but applies the
# clang19 patch without git-apply's --directory flag (the patch is not in git
# format, and git refuses that combination; the in-worktree cwd prefix is
# applied automatically instead).

orcaslicer_add_cmake_project(OpenVDB
    URL https://github.com/tamasmeszaros/openvdb/archive/a68fd58d0e2b85f01adeb8b13d7555183ab10aa5.zip
    URL_HASH SHA256=f353e7b99bd0cbfc27ac9082de51acf32a8bc0b3e21ff9661ecca6f205ec1d81
    PATCH_COMMAND git apply --verbose --ignore-space-change --whitespace=fix ${CMAKE_CURRENT_LIST_DIR}/../OpenVDB/0001-clang19.patch
    DEPENDS dep_TBB dep_Blosc dep_OpenEXR dep_Boost
    CMAKE_ARGS
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
        -DOPENVDB_BUILD_PYTHON_MODULE=OFF
        -DUSE_BLOSC=ON
        -DOPENVDB_CORE_SHARED=OFF
        -DOPENVDB_CORE_STATIC=ON
        -DOPENVDB_ENABLE_RPATH:BOOL=OFF
        -DTBB_STATIC=ON
        -DOPENVDB_BUILD_VDB_PRINT=OFF
        -DDISABLE_DEPENDENCY_VERSION_CHECKS=ON
)
