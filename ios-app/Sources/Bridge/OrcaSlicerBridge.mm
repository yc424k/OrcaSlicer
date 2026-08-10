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
#include "libslic3r/ModelArrange.hpp"

#include <atomic>
#include <exception>
#include <mutex>
#include <string>

using namespace Slic3r;

static PresetBundle         *s_bundle       = nullptr;
static AppConfig            *s_app_config   = nullptr;
static GCodeProcessorResult *s_last_gcode   = nullptr;
static Model                *s_scene        = nullptr;

// Slicing runs on a background thread; the UI polls progress and may cancel.
static std::atomic<int>      s_progress{-1};
static Print                *s_active_print = nullptr;
static std::mutex            s_active_print_mutex;

static Model &scene()
{
    if (!s_scene) s_scene = new Model();
    return *s_scene;
}

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
    print.set_status_callback([](const PrintBase::SlicingStatus &st) {
        if (st.percent >= 0)
            s_progress = st.percent;
    });

    {
        std::lock_guard<std::mutex> lock(s_active_print_mutex);
        s_active_print = &print;
    }
    s_progress = 0;
    try {
        print.process();
        if (!s_last_gcode)
            s_last_gcode = new GCodeProcessorResult();
        s_last_gcode->reset();
        print.export_gcode(output_path, s_last_gcode, nullptr);
    } catch (...) {
        std::lock_guard<std::mutex> lock(s_active_print_mutex);
        s_active_print = nullptr;
        s_progress     = -1;
        throw;
    }
    {
        std::lock_guard<std::mutex> lock(s_active_print_mutex);
        s_active_print = nullptr;
    }
    s_progress = -1;
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

+ (BOOL)saveCurrentPresetAs:(NSString *)name tab:(NSString *)tab
{
    PresetCollection *coll = collection_for_tab(tab);
    if (!coll) return NO;
    try {
        coll->save_current_preset(name.UTF8String);
        if ([tab isEqualToString:@"filament"])
            s_bundle->filament_presets = {s_bundle->filaments.get_selected_preset_name()};
        return YES;
    } catch (const std::exception &) {
        return NO;
    }
}

+ (CGSize)bedSize
{
    DynamicPrintConfig config = current_config();
    const auto *bed = config.option<ConfigOptionPoints>("printable_area");
    if (!bed || bed->values.size() < 3)
        return CGSizeZero;
    BoundingBoxf bbox;
    for (const Vec2d &p : bed->values)
        bbox.merge(p);
    return CGSizeMake(bbox.size().x(), bbox.size().y());
}

#pragma mark - Config editing

static PresetCollection *collection_for_tab(NSString *tab)
{
    if (!s_bundle) return nullptr;
    if ([tab isEqualToString:@"process"]) return &s_bundle->prints;
    if ([tab isEqualToString:@"filament"]) return &s_bundle->filaments;
    if ([tab isEqualToString:@"printer"]) return &s_bundle->printers;
    return nullptr;
}

static NSString *ui_type_for(ConfigOptionType type)
{
    switch (type & ~coVectorType) {
    case coBool: return @"bool";
    case coEnum: return @"enum";
    case coInt: return @"int";
    case coFloat:
    case coPercent:
    case coFloatOrPercent: return @"number";
    default: return @"string";
    }
}

+ (NSArray<NSDictionary<NSString *, id> *> *)configOptionsForTab:(NSString *)tab
{
    PresetCollection *coll = collection_for_tab(tab);
    if (!coll) return @[];

    const DynamicPrintConfig &edited = coll->get_edited_preset().config;
    const DynamicPrintConfig &preset = coll->get_selected_preset().config;

    NSMutableArray *options = [NSMutableArray array];
    for (const std::string &key : edited.keys()) {
        const ConfigOptionDef *def = print_config_def.get(key);
        // Hide developer-mode and GUI-less internal options (no label).
        if (!def || def->mode == comDevelop || def->label.empty())
            continue;

        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"key"]      = @(key.c_str());
        entry[@"label"]    = @(def->label.c_str());
        entry[@"tooltip"]  = @(def->tooltip.c_str());
        entry[@"category"] = @(def->category.empty() ? "Other" : def->category.c_str());
        entry[@"unit"]     = @(def->sidetext.c_str());
        entry[@"type"]     = ui_type_for(def->type);
        entry[@"value"]    = @(edited.opt_serialize(key).c_str());
        entry[@"presetValue"] = @(preset.has(key) ? preset.opt_serialize(key).c_str() : "");

        if ((def->type & ~coVectorType) == coEnum) {
            NSMutableArray *values = [NSMutableArray array];
            NSMutableArray *labels = [NSMutableArray array];
            for (size_t i = 0; i < def->enum_values.size(); ++i) {
                [values addObject:@(def->enum_values[i].c_str())];
                [labels addObject:@(i < def->enum_labels.size() ? def->enum_labels[i].c_str()
                                                                : def->enum_values[i].c_str())];
            }
            entry[@"enumValues"] = values;
            entry[@"enumLabels"] = labels;
        }
        [options addObject:entry];
    }
    return options;
}

+ (NSString *)setConfigValue:(NSString *)value forKey:(NSString *)key tab:(NSString *)tab
{
    PresetCollection *coll = collection_for_tab(tab);
    if (!coll) return nil;
    try {
        DynamicPrintConfig &config = coll->get_edited_preset().config;
        config.set_deserialize_strict(key.UTF8String, value.UTF8String);
        return @(config.opt_serialize(key.UTF8String).c_str());
    } catch (const std::exception &) {
        return nil;
    }
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

#pragma mark - Scene editing

// New objects land on the bed center (Orca bed coordinates run from the
// origin corner to printable_area's opposite corner).
static Vec2d bed_center_mm()
{
    DynamicPrintConfig config = current_config();
    const auto *bed = config.option<ConfigOptionPoints>("printable_area");
    if (!bed || bed->values.size() < 3)
        return Vec2d(0., 0.);
    BoundingBoxf bbox;
    for (const Vec2d &p : bed->values)
        bbox.merge(p);
    return bbox.center();
}

static void drop_on_bed_center(ModelObject *object)
{
    const Vec2d center = bed_center_mm();
    for (ModelInstance *instance : object->instances)
        instance->set_offset(Vec3d(center.x(), center.y(), instance->get_offset().z()));
    object->ensure_on_bed();
}

+ (BOOL)addModelToSceneAtPath:(NSString *)path error:(NSError **)error
{
    try {
        Model loaded = Model::read_from_file(path.UTF8String);
        for (ModelObject *object : loaded.objects) {
            ModelObject *added = scene().add_object(*object);
            if (added->instances.empty())
                added->add_instance();
            drop_on_bed_center(added);
        }
        return YES;
    } catch (const std::exception &ex) {
        if (error) *error = make_error(ex.what());
    } catch (...) {
        if (error) *error = make_error("unknown import error");
    }
    return NO;
}

+ (BOOL)addTestCubeToScene:(NSError **)error
{
    try {
        ModelObject *object = scene().add_object();
        object->name = "cube";
        object->add_volume(make_cube(20., 20., 20.));
        object->add_instance();
        drop_on_bed_center(object);
        return YES;
    } catch (const std::exception &ex) {
        if (error) *error = make_error(ex.what());
        return NO;
    }
}

+ (NSArray<NSDictionary<NSString *, id> *> *)sceneObjects
{
    NSMutableArray *objects = [NSMutableArray array];
    if (!s_scene) return objects;
    for (size_t i = 0; i < s_scene->objects.size(); ++i) {
        const ModelObject   *object   = s_scene->objects[i];
        const ModelInstance *instance = object->instances.empty() ? nullptr : object->instances.front();
        const BoundingBoxf3  bbox     = object->raw_mesh_bounding_box();
        [objects addObject:@{
            @"index" : @(i),
            @"name" : [NSString stringWithUTF8String:object->name.c_str()],
            @"positionX" : @(instance ? instance->get_offset().x() : 0.0),
            @"positionY" : @(instance ? instance->get_offset().y() : 0.0),
            @"rotationZ" : @(instance ? instance->get_rotation().z() * 180.0 / M_PI : 0.0),
            @"scale" : @(instance ? instance->get_scaling_factor().x() : 1.0),
            @"sizeX" : @(bbox.size().x()),
            @"sizeY" : @(bbox.size().y()),
            @"sizeZ" : @(bbox.size().z()),
        }];
    }
    return objects;
}

+ (NSDictionary<NSString *, NSData *> *)sceneMeshAtIndex:(NSInteger)index
{
    if (!s_scene || index < 0 || size_t(index) >= s_scene->objects.size())
        return nil;
    const indexed_triangle_set its = s_scene->objects[index]->raw_mesh().its;

    NSMutableData *vertices = [NSMutableData dataWithLength:its.vertices.size() * 3 * sizeof(float)];
    float *v = static_cast<float *>(vertices.mutableBytes);
    for (size_t i = 0; i < its.vertices.size(); ++i) {
        v[i * 3 + 0] = its.vertices[i].x();
        v[i * 3 + 1] = its.vertices[i].y();
        v[i * 3 + 2] = its.vertices[i].z();
    }
    NSMutableData *indices = [NSMutableData dataWithLength:its.indices.size() * 3 * sizeof(uint32_t)];
    uint32_t *ix = static_cast<uint32_t *>(indices.mutableBytes);
    for (size_t i = 0; i < its.indices.size(); ++i) {
        ix[i * 3 + 0] = its.indices[i][0];
        ix[i * 3 + 1] = its.indices[i][1];
        ix[i * 3 + 2] = its.indices[i][2];
    }
    return @{@"vertices" : vertices, @"indices" : indices};
}

+ (BOOL)removeSceneObjectAtIndex:(NSInteger)index
{
    if (!s_scene || index < 0 || size_t(index) >= s_scene->objects.size())
        return NO;
    s_scene->delete_object(size_t(index));
    return YES;
}

+ (void)clearScene
{
    if (s_scene) s_scene->clear_objects();
}

+ (BOOL)setSceneObjectAtIndex:(NSInteger)index
                    positionX:(double)x
                    positionY:(double)y
                    rotationZ:(double)degrees
                        scale:(double)scale
{
    if (!s_scene || index < 0 || size_t(index) >= s_scene->objects.size())
        return NO;
    ModelObject *object = s_scene->objects[index];
    if (object->instances.empty())
        return NO;
    ModelInstance *instance = object->instances.front();
    instance->set_offset(Vec3d(x, y, instance->get_offset().z()));
    instance->set_rotation(Z, degrees * M_PI / 180.0);
    instance->set_scaling_factor(Vec3d(scale, scale, scale));
    object->ensure_on_bed();
    return YES;
}

+ (BOOL)arrangeScene:(NSError **)error
{
    try {
        DynamicPrintConfig config = current_config();
        ArrangeParams params{scaled(min_object_distance(config))};
        const auto *bed = config.option<ConfigOptionPoints>("printable_area");
        if (bed && bed->values.size() >= 3) {
            BoundingBox bbox;
            for (const Vec2d &p : bed->values)
                bbox.merge(Slic3r::Point::new_scale(p.x(), p.y()));
            arrange_objects(scene(), bbox, params);
        } else {
            arrange_objects(scene(), InfiniteBed{}, params);
        }
        for (ModelObject *object : scene().objects)
            object->ensure_on_bed();
        return YES;
    } catch (const std::exception &ex) {
        if (error) *error = make_error(ex.what());
        return NO;
    }
}

+ (BOOL)sliceSceneToGcodePath:(NSString *)outputPath error:(NSError **)error
{
    if (!s_scene || s_scene->objects.empty()) {
        if (error) *error = make_error("scene is empty");
        return NO;
    }
    try {
        run_print_pipeline(*s_scene, outputPath.UTF8String);
        return YES;
    } catch (const std::exception &ex) {
        if (error) *error = make_error(ex.what());
    } catch (...) {
        if (error) *error = make_error("unknown slicer error");
    }
    return NO;
}

#pragma mark - Slicing progress & stats

+ (NSInteger)slicingProgress
{
    return s_progress.load();
}

+ (void)cancelSlicing
{
    std::lock_guard<std::mutex> lock(s_active_print_mutex);
    if (s_active_print)
        s_active_print->cancel();
}

+ (NSDictionary<NSString *, NSNumber *> *)lastSliceStats
{
    if (!s_last_gcode || s_last_gcode->moves.empty())
        return nil;
    const PrintEstimatedStatistics &stats = s_last_gcode->print_statistics;

    const float seconds =
        stats.modes[size_t(PrintEstimatedStatistics::ETimeMode::Normal)].time;

    double volume_mm3 = 0.;
    for (const auto &entry : stats.total_volumes_per_extruder)
        volume_mm3 += entry.second;

    const double diameter = s_last_gcode->filament_diameters.empty()
                                ? 1.75 : s_last_gcode->filament_diameters.front();
    const double density  = s_last_gcode->filament_densities.empty()
                                ? 1.24 : s_last_gcode->filament_densities.front();
    const double area     = M_PI * diameter * diameter / 4.;
    const double length   = area > 0. ? volume_mm3 / area : 0.;
    const double grams    = volume_mm3 * density / 1000.;

    return @{
        @"time" : @(seconds),
        @"filamentMM" : @(length),
        @"filamentG" : @(grams),
    };
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
