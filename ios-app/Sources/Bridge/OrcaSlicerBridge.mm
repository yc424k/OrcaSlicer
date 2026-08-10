// libslic3r leaves the NanoSVG implementation to the final binary (the desktop
// GUI compiles it in BitmapCache.cpp); on iOS the bridge provides it.
#define NANOSVG_IMPLEMENTATION
#include <nanosvg.h>

#import "OrcaSlicerBridge.h"

#include "libslic3r/libslic3r_version.h"
#include "libslic3r/AppConfig.hpp"
#include "libslic3r/Model.hpp"
#include "libslic3r/PresetBundle.hpp"
#include "libslic3r/Print.hpp"
#include "libslic3r/PrintConfig.hpp"
#include "libslic3r/TriangleMesh.hpp"
#include "libslic3r/Utils.hpp"
#include "libslic3r/GCode/GCodeProcessor.hpp"

#include <exception>
#include <string>

using namespace Slic3r;

static PresetBundle         *s_bundle       = nullptr;
static AppConfig            *s_app_config   = nullptr;
static GCodeProcessorResult *s_last_gcode   = nullptr;

static NSError *make_error(const std::string &what)
{
    return [NSError errorWithDomain:@"OrcaSlicerCore"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithUTF8String:what.c_str()]}];
}

static NSArray<NSString *> *collect_presets(const PresetCollection &collection, bool only_compatible)
{
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (const Preset &preset : collection) {
        if (!preset.is_system)
            continue;
        if (only_compatible && !preset.is_compatible)
            continue;
        [names addObject:[NSString stringWithUTF8String:preset.name.c_str()]];
    }
    return names;
}

// The slicing config: selected presets when initialized, defaults otherwise.
static DynamicPrintConfig current_config()
{
    if (s_bundle) {
        DynamicPrintConfig config = s_bundle->full_config();
        config.normalize_fdm();
        return config;
    }
    return DynamicPrintConfig::full_print_config();
}

// Shared tail of both slice paths: model is loaded, run the print pipeline.
static void run_print_pipeline(Model &model, const char *output_path)
{
    DynamicPrintConfig config = current_config();
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

    if (!s_last_gcode)
        s_last_gcode = new GCodeProcessorResult();
    s_last_gcode->reset();
    print.export_gcode(output_path, s_last_gcode, nullptr);
}

@implementation OrcaSlicerCore

+ (NSString *)coreVersion
{
    return @SLIC3R_VERSION;
}

#pragma mark - Preset system

+ (BOOL)initializeWithResourcesPath:(NSString *)resourcesPath dataPath:(NSString *)dataPath error:(NSError **)error
{
    try {
        set_resources_dir(resourcesPath.UTF8String);
        set_data_dir(dataPath.UTF8String);

        auto bundle     = std::make_unique<PresetBundle>();
        auto app_config = std::make_unique<AppConfig>();

        // System presets are read from data_dir/system, which the desktop app
        // populates via its preset updater. On iOS, link it straight to the
        // bundled read-only profiles instead of copying 80 MB. Must run before
        // setup_directories(): the app bundle path changes on every reinstall,
        // and a dangling old symlink would make its create_directory fail.
        namespace fs = boost::filesystem;
        const fs::path system_dir = fs::path(data_dir()) / PRESET_SYSTEM_DIR;
        const fs::path profiles   = fs::path(resources_dir()) / "profiles";
        boost::system::error_code ec;
        if (fs::is_symlink(fs::symlink_status(system_dir)))
            fs::remove(system_dir, ec);
        else if (fs::is_directory(system_dir) && fs::is_empty(system_dir, ec))
            fs::remove(system_dir, ec);
        if (!fs::exists(fs::symlink_status(system_dir)))
            fs::create_directory_symlink(profiles, system_dir, ec);
        if (ec)
            throw std::runtime_error("cannot link system presets: " + ec.message());

        bundle->setup_directories();
        bundle->load_presets(*app_config, ForwardCompatibilitySubstitutionRule::EnableSilent);

        // System presets are only visible for vendors the user enabled in the
        // desktop setup wizard (stored in AppConfig). There is no wizard here,
        // and select_preset_by_name() refuses invisible presets — show all.
        for (Preset &preset : bundle->printers)
            if (preset.is_system) preset.is_visible = true;
        for (Preset &preset : bundle->prints)
            if (preset.is_system) preset.is_visible = true;
        for (Preset &preset : bundle->filaments)
            if (preset.is_system) preset.is_visible = true;

        bundle->update_compatible(PresetSelectCompatibleType::Always);

        s_bundle     = bundle.release();
        s_app_config = app_config.release();
        return YES;
    } catch (const std::exception &ex) {
        if (error) *error = make_error(ex.what());
    } catch (...) {
        if (error) *error = make_error("unknown error while loading presets");
    }
    return NO;
}

+ (NSArray<NSString *> *)printerPresets
{
    return s_bundle ? collect_presets(s_bundle->printers, false) : @[];
}

+ (NSArray<NSString *> *)processPresets
{
    return s_bundle ? collect_presets(s_bundle->prints, true) : @[];
}

+ (NSArray<NSString *> *)filamentPresets
{
    return s_bundle ? collect_presets(s_bundle->filaments, true) : @[];
}

+ (NSString *)selectedPrinter
{
    return s_bundle ? [NSString stringWithUTF8String:s_bundle->printers.get_selected_preset_name().c_str()] : nil;
}

+ (NSString *)selectedProcess
{
    return s_bundle ? [NSString stringWithUTF8String:s_bundle->prints.get_selected_preset_name().c_str()] : nil;
}

+ (NSString *)selectedFilament
{
    return s_bundle ? [NSString stringWithUTF8String:s_bundle->filaments.get_selected_preset_name().c_str()] : nil;
}

+ (BOOL)selectPrinter:(NSString *)name error:(NSError **)error
{
    if (!s_bundle) {
        if (error) *error = make_error("preset system not initialized");
        return NO;
    }
    try {
        if (!s_bundle->printers.select_preset_by_name(name.UTF8String, true)) {
            if (error) *error = make_error(std::string("unknown printer preset: ") + name.UTF8String);
            return NO;
        }
        // Re-resolve compatibility; incompatible process/filament selections
        // are switched to compatible ones automatically.
        s_bundle->update_compatible(PresetSelectCompatibleType::Always);
        s_bundle->filament_presets = {s_bundle->filaments.get_selected_preset_name()};
        return YES;
    } catch (const std::exception &ex) {
        if (error) *error = make_error(ex.what());
        return NO;
    }
}

+ (BOOL)selectProcess:(NSString *)name error:(NSError **)error
{
    if (!s_bundle) {
        if (error) *error = make_error("preset system not initialized");
        return NO;
    }
    if (!s_bundle->prints.select_preset_by_name(name.UTF8String, true)) {
        if (error) *error = make_error(std::string("unknown process preset: ") + name.UTF8String);
        return NO;
    }
    return YES;
}

+ (BOOL)selectFilament:(NSString *)name error:(NSError **)error
{
    if (!s_bundle) {
        if (error) *error = make_error("preset system not initialized");
        return NO;
    }
    if (!s_bundle->filaments.select_preset_by_name(name.UTF8String, true)) {
        if (error) *error = make_error(std::string("unknown filament preset: ") + name.UTF8String);
        return NO;
    }
    s_bundle->filament_presets = {s_bundle->filaments.get_selected_preset_name()};
    return YES;
}

#pragma mark - Slicing

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

#pragma mark - Toolpath preview

+ (NSDictionary<NSString *, NSData *> *)lastToolpaths
{
    if (!s_last_gcode || s_last_gcode->moves.empty())
        return nil;

    const auto  &moves = s_last_gcode->moves;
    const size_t count = moves.size();

    NSMutableData *positions = [NSMutableData dataWithLength:count * 3 * sizeof(float)];
    NSMutableData *types     = [NSMutableData dataWithLength:count];
    NSMutableData *roles     = [NSMutableData dataWithLength:count];

    float   *pos  = static_cast<float *>(positions.mutableBytes);
    uint8_t *type = static_cast<uint8_t *>(types.mutableBytes);
    uint8_t *role = static_cast<uint8_t *>(roles.mutableBytes);

    for (size_t i = 0; i < count; ++i) {
        const auto &m = moves[i];
        pos[i * 3 + 0] = m.position.x();
        pos[i * 3 + 1] = m.position.y();
        pos[i * 3 + 2] = m.position.z();
        type[i]        = static_cast<uint8_t>(m.type);
        role[i]        = static_cast<uint8_t>(m.extrusion_role);
    }

    return @{@"positions" : positions, @"types" : types, @"roles" : roles};
}

@end
