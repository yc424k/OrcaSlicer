// Minimal headless slicing smoke test for core-only (ORCA_CORE_ONLY) builds,
// e.g. the iOS port: slices a 20 mm cube with default settings and writes the
// G-code to the given path. Exits 0 on success.
//
// orca_core_smoke_main() is a plain entry point so an iOS test app can call it
// directly; the standalone main() is compiled unless ORCA_SMOKE_NO_MAIN is set.

// libslic3r leaves the NanoSVG implementation to the final binary (the desktop
// GUI compiles it in BitmapCache.cpp); a core-only consumer must provide it.
#define NANOSVG_IMPLEMENTATION
#include <nanosvg.h>

#include "libslic3r/Model.hpp"
#include "libslic3r/Print.hpp"
#include "libslic3r/PrintConfig.hpp"
#include "libslic3r/TriangleMesh.hpp"

#include <fstream>
#include <iostream>

int orca_core_smoke_main(const char *gcode_path)
{
    using namespace Slic3r;
    try {
        DynamicPrintConfig config = DynamicPrintConfig::full_print_config();
        config.set_key_value("gcode_comments", new ConfigOptionBool(true));

        Model        model;
        ModelObject *object = model.add_object();
        object->name = "smoke_cube";
        object->add_volume(make_cube(20., 20., 20.));
        object->add_instance();
        object->ensure_on_bed();

        Print print;
        print.auto_assign_extruders(object);
        print.apply(model, config);
        print.validate();
        print.set_status_silent();
        print.process();
        print.export_gcode(gcode_path, nullptr, nullptr);

        std::ifstream in(gcode_path, std::ios::binary | std::ios::ate);
        const auto    size = in.tellg();
        std::cout << "smoke test G-code: " << gcode_path << " (" << size << " bytes)" << std::endl;
        return (in.good() && size > 0) ? 0 : 1;
    } catch (const std::exception &ex) {
        std::cerr << "smoke test failed: " << ex.what() << std::endl;
        return 2;
    }
}

#ifndef ORCA_SMOKE_NO_MAIN
int main(int argc, char **argv)
{
    return orca_core_smoke_main(argc > 1 ? argv[1] : "smoke_cube.gcode");
}
#endif
