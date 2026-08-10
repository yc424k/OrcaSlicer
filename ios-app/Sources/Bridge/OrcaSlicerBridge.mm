// libslic3r leaves the NanoSVG implementation to the final binary (the desktop
// GUI compiles it in BitmapCache.cpp); on iOS the bridge provides it.
#define NANOSVG_IMPLEMENTATION
#include <nanosvg.h>

#import "OrcaSlicerBridge.h"

#include "libslic3r/libslic3r_version.h"
#include "libslic3r/Model.hpp"
#include "libslic3r/Print.hpp"
#include "libslic3r/PrintConfig.hpp"
#include "libslic3r/TriangleMesh.hpp"

#include <exception>
#include <string>

using namespace Slic3r;

static NSError *make_error(const std::string &what)
{
    return [NSError errorWithDomain:@"OrcaSlicerCore"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithUTF8String:what.c_str()]}];
}

// Shared tail of both slice paths: model is loaded, run the print pipeline.
static void run_print_pipeline(Model &model, const char *output_path)
{
    DynamicPrintConfig config = DynamicPrintConfig::full_print_config();
    config.set_key_value("gcode_comments", new ConfigOptionBool(true));

    Print print;
    for (ModelObject *mo : model.objects) {
        mo->ensure_on_bed();
        print.auto_assign_extruders(mo);
    }
    print.apply(model, config);
    print.validate();
    print.set_status_silent();
    print.process();
    print.export_gcode(output_path, nullptr, nullptr);
}

@implementation OrcaSlicerCore

+ (NSString *)coreVersion
{
    return @SLIC3R_VERSION;
}

+ (BOOL)sliceModelAtPath:(NSString *)inputPath toGcodePath:(NSString *)outputPath error:(NSError **)error
{
    try {
        Model model = Model::read_from_file(inputPath.UTF8String);
        run_print_pipeline(model, outputPath.UTF8String);
        return YES;
    } catch (const std::exception &ex) {
        if (error) *error = make_error(ex.what());
    } catch (...) {
        if (error) *error = make_error("unknown slicer error");
    }
    return NO;
}

+ (BOOL)sliceTestCubeToGcodePath:(NSString *)outputPath error:(NSError **)error
{
    try {
        Model        model;
        ModelObject *object = model.add_object();
        object->name = "test_cube";
        object->add_volume(make_cube(20., 20., 20.));
        object->add_instance();
        run_print_pipeline(model, outputPath.UTF8String);
        return YES;
    } catch (const std::exception &ex) {
        if (error) *error = make_error(ex.what());
    } catch (...) {
        if (error) *error = make_error("unknown slicer error");
    }
    return NO;
}

@end
