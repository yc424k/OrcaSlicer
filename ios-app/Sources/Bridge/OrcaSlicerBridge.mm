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
#include "libslic3r/calib.hpp"
#include "libslic3r/CutUtils.hpp"
#include "libslic3r/Flow.hpp"
#include "libslic3r/Geometry.hpp"

#include <cmath>

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

// Armed calibration: extra config overrides + the core's Calib_Params for the
// next slice. Reset by any normal scene operation.
static Calib_Params          s_calib_params;
static DynamicPrintConfig    s_calib_overrides;
static NSString             *s_calib_label = nil;

static void reset_calibration()
{
    s_calib_params      = Calib_Params();
    s_calib_params.mode = CalibMode::Calib_None;
    s_calib_overrides   = DynamicPrintConfig();
    s_calib_label       = nil;
}

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
    config.apply(s_calib_overrides);

    print.apply(model, config);
    if (s_calib_params.mode != CalibMode::Calib_None)
        print.set_calib_params(s_calib_params);
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
        Model model = Model::read_from_file(inputPath.UTF8String, nullptr, nullptr, LoadStrategy::LoadModel | LoadStrategy::AddDefaultInstances);
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
    reset_calibration();
    try {
        Model loaded;
        NSString *ext = path.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"step"] || [ext isEqualToString:@"stp"]) {
#ifdef ORCA_NO_OCCT
            throw std::runtime_error("this build has no STEP support");
#else
            // STEP goes through the OCCT-based Step loader, not
            // read_from_file (mirrors the desktop import path).
            loaded = Model::read_from_step(path.UTF8String, LoadStrategy::AddDefaultInstances,
                                           nullptr, nullptr, nullptr, 0.003, 0.5, false);
#endif
        } else {
            loaded = Model::read_from_file(path.UTF8String, nullptr, nullptr, LoadStrategy::LoadModel | LoadStrategy::AddDefaultInstances);
        }
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
    reset_calibration();
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
    reset_calibration();
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

#pragma mark - Calibration

// Loads a bundled calibration model as the sole scene object.
static ModelObject *load_calib_model(const char *relative_path)
{
    scene().clear_objects();
    Model loaded = Model::read_from_file(resources_dir() + relative_path, nullptr, nullptr, LoadStrategy::LoadModel | LoadStrategy::AddDefaultInstances);
    if (loaded.objects.empty())
        throw std::runtime_error("calibration model is empty");
    ModelObject *added = scene().add_object(*loaded.objects.front());
    if (added->instances.empty())
        added->add_instance();
    return added;
}

// Horizontal plane cut, mirroring the desktop Plater::cut_horizontal; returns
// the replacement object (the cut's results are copied into the scene while
// the Cut still owns the originals).
static ModelObject *calib_cut(ModelObject *object, double z, bool keep_lower)
{
    const Vec3d offset = object->instances.front()->get_offset();
    Cut cut(object, 0, Geometry::translation_transform(z * Vec3d::UnitZ() - offset),
            keep_lower ? ModelObjectCutAttribute::KeepLower : ModelObjectCutAttribute::KeepUpper);
    const ModelObjectPtrs &pieces = cut.perform_with_plane();
    if (pieces.empty())
        return object;
    Model &model = scene();
    for (size_t i = 0; i < model.objects.size(); ++i)
        if (model.objects[i] == object) {
            model.delete_object(i);
            break;
        }
    return model.add_object(*pieces.front());
}

+ (BOOL)startCalibration:(NSString *)mode
                   start:(double)start
                     end:(double)end
                    step:(double)step
                   error:(NSError **)error
{
    try {
        reset_calibration();
        DynamicPrintConfig config = current_config();
        const auto *nozzle_opt = config.option<ConfigOptionFloats>("nozzle_diameter");
        const double nozzle = (nozzle_opt && !nozzle_opt->values.empty()) ? nozzle_opt->values.front() : 0.4;

        Calib_Params params;
        params.start = start;
        params.end   = end;
        params.step  = step;

        if ([mode isEqualToString:@"temp"]) {
            // Desktop Plater::calib_temp (no nozzle-based resize).
            params.mode = CalibMode::Calib_Temp_Tower;
            params.step = -std::abs(step); // blocks go hot (bottom) -> cold (top)
            ModelObject *obj = load_calib_model("/calib/temperature_tower/temperature_tower.drc");
            auto bb = obj->bounding_box_exact();
            long blocks = lround((500. - end) / 5. + 1);
            if (blocks > 0 && blocks * 10. - EPSILON < bb.size().z())
                obj = calib_cut(obj, blocks * 10. - EPSILON, true);
            bb = obj->bounding_box_exact();
            blocks = lround((500. - start) / 5.);
            if (blocks > 0 && blocks * 10. + EPSILON < bb.size().z())
                obj = calib_cut(obj, blocks * 10. + EPSILON, false);
            obj->config.set_key_value("brim_type", new ConfigOptionEnum<BrimType>(btOuterOnly));
            obj->config.set_key_value("brim_width", new ConfigOptionFloat(5.0));
            obj->config.set_key_value("brim_object_gap", new ConfigOptionFloat(0.0));
            obj->config.set_key_value("alternate_extra_wall", new ConfigOptionBool(false));
            obj->config.set_key_value("seam_slope_type", new ConfigOptionEnum<SeamScarfType>(SeamScarfType::None));
            obj->config.set_key_value("overhang_reverse", new ConfigOptionBool(false));
            obj->config.set_key_value("precise_z_height", new ConfigOptionBool(false));
            const int start_temp = int(lround(start));
            s_calib_overrides.set_key_value("nozzle_temperature_initial_layer", new ConfigOptionInts(1, start_temp));
            s_calib_overrides.set_key_value("nozzle_temperature", new ConfigOptionInts(1, start_temp));
            drop_on_bed_center(obj);
            s_calib_label = @"온도 타워";
        } else if ([mode isEqualToString:@"volspeed"]) {
            // Desktop Plater::calib_max_vol_speed.
            params.mode = CalibMode::Calib_Vol_speed_Tower;
            ModelObject *obj = load_calib_model("/calib/volumetric_speed/SpeedTestStructure.drc");
            const auto *bed = config.option<ConfigOptionPoints>("printable_area");
            if (bed && bed->values.size() >= 3) {
                BoundingBoxf bed_ext;
                for (const Vec2d &p : bed->values) bed_ext.merge(p);
                const double scale = (bed_ext.size().x() - 10.) / obj->bounding_box_exact().size().x();
                if (scale < 1.0) obj->scale(scale, 1., 1.);
            }
            const double line_width   = nozzle * 1.75;
            const double layer_height = nozzle * 0.8;
            obj->config.set_key_value("enable_overhang_speed", new ConfigOptionBoolsNullable(1, false));
            obj->config.set_key_value("wall_loops", new ConfigOptionInt(1));
            obj->config.set_key_value("alternate_extra_wall", new ConfigOptionBool(false));
            obj->config.set_key_value("top_shell_layers", new ConfigOptionInt(0));
            obj->config.set_key_value("bottom_shell_layers", new ConfigOptionInt(0));
            obj->config.set_key_value("sparse_infill_density", new ConfigOptionPercent(0));
            obj->config.set_key_value("outer_wall_line_width", new ConfigOptionFloatOrPercent(line_width, false));
            obj->config.set_key_value("layer_height", new ConfigOptionFloat(layer_height));
            obj->config.set_key_value("brim_type", new ConfigOptionEnum<BrimType>(btOuterAndInner));
            obj->config.set_key_value("brim_width", new ConfigOptionFloat(5.0));
            obj->config.set_key_value("brim_object_gap", new ConfigOptionFloat(0.0));
            obj->config.set_key_value("precise_z_height", new ConfigOptionBool(false));
            const auto *cur_vol = config.option<ConfigOptionFloats>("filament_max_volumetric_speed");
            const double vol = std::max(cur_vol && !cur_vol->values.empty() ? cur_vol->values.front() : 0., 200.);
            s_calib_overrides.set_key_value("filament_max_volumetric_speed", new ConfigOptionFloats(1, vol));
            s_calib_overrides.set_key_value("slow_down_layer_time", new ConfigOptionFloats(1, 0.));
            s_calib_overrides.set_key_value("spiral_mode", new ConfigOptionBool(true));
            s_calib_overrides.set_key_value("timelapse_type", new ConfigOptionEnum<TimelapseType>(tlTraditional));
            s_calib_overrides.set_key_value("max_volumetric_extrusion_rate_slope", new ConfigOptionFloat(0));
            const double height = (end - start + 1.) / step;
            if (height < obj->bounding_box_exact().size().z())
                obj = calib_cut(obj, height, true);
            const auto *flow_ratio = config.option<ConfigOptionFloatsNullable>("filament_flow_ratio");
            const double mm3 = Flow(float(line_width), float(layer_height), float(nozzle)).mm3_per_mm() *
                               (flow_ratio && !flow_ratio->values.empty() ? flow_ratio->get_at(0) : 1.0);
            params.start = start / mm3;
            params.end   = end / mm3;
            params.step  = step / mm3;
            drop_on_bed_center(obj);
            s_calib_label = @"최대 체적 속도";
        } else if ([mode isEqualToString:@"retraction"]) {
            // Desktop Plater::calib_retraction.
            params.mode = CalibMode::Calib_Retraction_tower;
            ModelObject *obj = load_calib_model("/calib/retraction/retraction_tower.drc");
            const double layer_height = nozzle <= 0.1 ? 0.05 : (nozzle <= 0.2 ? 0.1 : 0.2);
            s_calib_overrides.set_key_value("use_firmware_retraction", new ConfigOptionBool(false));
            s_calib_overrides.set_key_value("initial_layer_print_height", new ConfigOptionFloat(layer_height));
            obj->config.set_key_value("wall_loops", new ConfigOptionInt(2));
            obj->config.set_key_value("top_shell_layers", new ConfigOptionInt(0));
            obj->config.set_key_value("bottom_shell_layers", new ConfigOptionInt(3));
            obj->config.set_key_value("sparse_infill_density", new ConfigOptionPercent(0));
            obj->config.set_key_value("layer_height", new ConfigOptionFloat(layer_height));
            obj->config.set_key_value("alternate_extra_wall", new ConfigOptionBool(false));
            obj->config.set_key_value("seam_position", new ConfigOptionEnum<SeamPosition>(spAligned));
            obj->config.set_key_value("wall_sequence", new ConfigOptionEnum<WallSequence>(WallSequence::InnerOuter));
            obj->config.set_key_value("overhang_reverse", new ConfigOptionBool(false));
            obj->config.set_key_value("precise_z_height", new ConfigOptionBool(false));
            const double height = 1.0 + 0.4 + (end - start) / step - EPSILON;
            if (height < obj->bounding_box_exact().size().z())
                obj = calib_cut(obj, height, true);
            drop_on_bed_center(obj);
            s_calib_label = @"리트랙션 타워";
        } else if ([mode isEqualToString:@"vfa"]) {
            // Desktop Plater::calib_vfa (no nozzle-based resize).
            params.mode = CalibMode::Calib_VFA_Tower;
            params.vfa_layer_height = 0.0;
            ModelObject *obj = load_calib_model("/calib/vfa/vfa.drc");
            const double height = vfa_base_block_height * ((end - start) / step + 1) - EPSILON;
            if (height < obj->bounding_box_exact().size().z())
                obj = calib_cut(obj, height, true);
            s_calib_overrides.set_key_value("slow_down_layer_time", new ConfigOptionFloats(1, 0.));
            s_calib_overrides.set_key_value("enable_overhang_speed", new ConfigOptionBoolsNullable(1, false));
            s_calib_overrides.set_key_value("timelapse_type", new ConfigOptionEnum<TimelapseType>(tlTraditional));
            s_calib_overrides.set_key_value("wall_loops", new ConfigOptionInt(1));
            s_calib_overrides.set_key_value("alternate_extra_wall", new ConfigOptionBool(false));
            s_calib_overrides.set_key_value("top_shell_layers", new ConfigOptionInt(0));
            s_calib_overrides.set_key_value("bottom_shell_layers", new ConfigOptionInt(1));
            s_calib_overrides.set_key_value("sparse_infill_density", new ConfigOptionPercent(0));
            s_calib_overrides.set_key_value("detect_thin_wall", new ConfigOptionBool(false));
            s_calib_overrides.set_key_value("spiral_mode", new ConfigOptionBool(true));
            s_calib_overrides.set_key_value("precise_z_height", new ConfigOptionBool(false));
            drop_on_bed_center(obj);
            s_calib_label = @"VFA (미세 진동)";
        } else if ([mode isEqualToString:@"pa_tower"]) {
            // Desktop Plater::_calib_pa_tower.
            params.mode = CalibMode::Calib_PA_Tower;
            ModelObject *obj = load_calib_model("/calib/pressure_advance/tower_with_seam.drc");
            obj->config.set_key_value("alternate_extra_wall", new ConfigOptionBool(false));
            obj->config.set_key_value("seam_position", new ConfigOptionEnum<SeamPosition>(spRear));
            obj->config.set_key_value("wall_loops", new ConfigOptionInt(2));
            obj->config.set_key_value("top_shell_layers", new ConfigOptionInt(0));
            obj->config.set_key_value("bottom_shell_layers", new ConfigOptionInt(0));
            obj->config.set_key_value("sparse_infill_density", new ConfigOptionPercent(0));
            obj->config.set_key_value("brim_type", new ConfigOptionEnum<BrimType>(btEar));
            obj->config.set_key_value("brim_object_gap", new ConfigOptionFloat(0.));
            obj->config.set_key_value("brim_ears_max_angle", new ConfigOptionFloat(135.));
            obj->config.set_key_value("brim_width", new ConfigOptionFloat(6.));
            obj->config.set_key_value("seam_slope_type", new ConfigOptionEnum<SeamScarfType>(SeamScarfType::None));
            s_calib_overrides.set_key_value("slow_down_layer_time", new ConfigOptionFloats(1, 1.));
            s_calib_overrides.set_key_value("max_volumetric_extrusion_rate_slope", new ConfigOptionFloat(0));
            const double height = std::ceil((end - start) / step) + 1;
            if (height < obj->bounding_box_exact().size().z())
                obj = calib_cut(obj, height, true);
            drop_on_bed_center(obj);
            s_calib_label = @"PA 타워";
        } else if ([mode isEqualToString:@"pa_line"]) {
            // Desktop Plater::calib_pa, PA line branch.
            params.mode = CalibMode::Calib_PA_Line;
            ModelObject *obj = load_calib_model("/calib/pressure_advance/pressure_advance_test.drc");
            s_calib_overrides.set_key_value("overhang_reverse", new ConfigOptionBool(false));
            s_calib_overrides.set_key_value("precise_z_height", new ConfigOptionBool(false));
            drop_on_bed_center(obj);
            s_calib_label = @"PA 라인";
        } else if ([mode hasPrefix:@"flow_"]) {
            // Desktop Plater::calib_flowrate + adjust_settings_for_flowrate_calib
            // (single extruder).
            params.mode = CalibMode::Calib_Flow_Rate;
            const bool linear = [mode containsString:@"yolo"];
            const int  pass   = [mode hasSuffix:@"2"] ? 2 : 1;
            const char *path  = linear
                ? (pass == 1 ? "/calib/filament_flow/Orca-LinearFlow.3mf"
                             : "/calib/filament_flow/Orca-LinearFlow_fine.3mf")
                : (pass == 1 ? "/calib/filament_flow/flowrate-test-pass1.3mf"
                             : "/calib/filament_flow/flowrate-test-pass2.3mf");
            scene().clear_objects();
            Model loaded = Model::read_from_file(resources_dir() + path, nullptr, nullptr, LoadStrategy::LoadModel | LoadStrategy::AddDefaultInstances);
            if (loaded.objects.empty())
                throw std::runtime_error("calibration model is empty");
            for (ModelObject *object : loaded.objects) {
                ModelObject *added = scene().add_object(*object);
                if (added->instances.empty())
                    added->add_instance();
            }

            const double xy_scale     = nozzle / 0.6;
            const double layer_height = nozzle / 2.0;
            double first_layer_height = config.option<ConfigOptionFloat>("initial_layer_print_height")->value;
            first_layer_height        = std::max(first_layer_height, layer_height);
            const double z_scale      = (first_layer_height + 9 * layer_height) / 2.;

            const auto *flow_opt     = config.option<ConfigOptionFloatsNullable>("filament_flow_ratio");
            const double cur_flow    = flow_opt && !flow_opt->values.empty() ? flow_opt->get_at(0) : 1.0;
            const auto *fmvs_opt     = config.option<ConfigOptionFloats>("filament_max_volumetric_speed");
            const double fmvs        = fmvs_opt && !fmvs_opt->values.empty() ? fmvs_opt->values.front() : 20.;
            double line_width = config.get_abs_value("line_width", nozzle);
            if (line_width <= EPSILON)
                line_width = nozzle * 1.125; // 0 = auto in the presets
            double preset_lh = config.option<ConfigOptionFloat>("layer_height")->value;
            if (preset_lh <= EPSILON)
                preset_lh = nozzle / 2.;
            const Flow   flow{float(line_width), float(preset_lh), float(nozzle)};
            const double max_speed   = linear
                ? fmvs / (flow.mm3_per_mm() * (cur_flow + (pass == 2 ? 0.035 : 0.05)) / cur_flow)
                : fmvs / (flow.mm3_per_mm() * (pass == 1 ? 1.2 : 1.));
            auto capped_speed = [&](const char *key) {
                const auto *opt = config.option<ConfigOptionFloatsNullable>(key);
                const double cur = opt && !opt->values.empty() ? opt->get_at(0) : max_speed;
                return std::floor(std::min(cur, max_speed));
            };
            const double solid_speed = capped_speed("internal_solid_infill_speed");
            const double top_speed   = capped_speed("top_surface_speed");

            for (ModelObject *obj : scene().objects) {
                obj->scale(xy_scale > 1.2 ? xy_scale : 1., xy_scale > 1.2 ? xy_scale : 1., z_scale);
                obj->ensure_on_bed();
                auto &c = obj->config;
                c.set_key_value("wall_loops", new ConfigOptionInt(1));
                c.set_key_value("only_one_wall_top", new ConfigOptionBool(true));
                c.set_key_value("thick_internal_bridges", new ConfigOptionBool(false));
                c.set_key_value("enable_extra_bridge_layer", new ConfigOptionEnum<EnableExtraBridgeLayer>(eblDisabled));
                c.set_key_value("internal_bridge_density", new ConfigOptionPercent(100));
                c.set_key_value("sparse_infill_density", new ConfigOptionPercent(35));
                c.set_key_value("min_width_top_surface", new ConfigOptionFloatOrPercent(100, true));
                c.set_key_value("bottom_shell_layers", new ConfigOptionInt(2));
                c.set_key_value("top_shell_layers", new ConfigOptionInt(5));
                c.set_key_value("top_shell_thickness", new ConfigOptionFloat(0));
                c.set_key_value("bottom_shell_thickness", new ConfigOptionFloat(0));
                c.set_key_value("detect_thin_wall", new ConfigOptionBool(true));
                c.set_key_value("filter_out_gap_fill", new ConfigOptionFloat(0));
                c.set_key_value("sparse_infill_pattern", new ConfigOptionEnum<InfillPattern>(ipRectilinear));
                c.set_key_value("top_surface_line_width", new ConfigOptionFloatOrPercent(nozzle * 1.2, false));
                c.set_key_value("internal_solid_infill_line_width", new ConfigOptionFloatOrPercent(nozzle * 1.2, false));
                c.set_key_value("top_surface_pattern", new ConfigOptionEnum<InfillPattern>(ipMonotonic));
                c.set_key_value("top_solid_infill_flow_ratio", new ConfigOptionFloat(1.));
                c.set_key_value("infill_direction", new ConfigOptionFloat(45));
                c.set_key_value("solid_infill_direction", new ConfigOptionFloat(135));
                c.set_key_value("center_of_surface_pattern", new ConfigOptionEnum<CenterOfSurfacePattern>(CenterOfSurfacePattern::Each_Surface));
                c.set_key_value("separated_infills", new ConfigOptionBool(false));
                c.set_key_value("align_infill_direction_to_model", new ConfigOptionBool(true));
                c.set_key_value("ironing_type", new ConfigOptionEnum<IroningType>(IroningType::NoIroning));
                c.set_key_value("internal_solid_infill_speed", new ConfigOptionFloatsNullable(1, solid_speed));
                c.set_key_value("top_surface_speed", new ConfigOptionFloatsNullable(1, top_speed));
                c.set_key_value("seam_slope_type", new ConfigOptionEnum<SeamScarfType>(SeamScarfType::None));
                c.set_key_value("gap_fill_target", new ConfigOptionEnum<GapFillTarget>(GapFillTarget::gftNowhere));
                c.set_key_value("calib_flowrate_topinfill_special_order", new ConfigOptionBool(true));
                c.set_key_value("top_surface_fill_order", new ConfigOptionEnum<SurfaceFillOrder>(SurfaceFillOrder::Default));

                // The flow modifier is encoded in the object name: flowrate_xxx.
                std::string name = obj->name;
                double modifier = 0.;
                if (name.length() > 9) {
                    name = name.substr(9);
                    if (!name.empty() && name[0] == 'm')
                        name[0] = '-';
                    try { modifier = std::stod(name); } catch (...) {}
                }
                c.set_key_value("print_flow_ratio",
                                new ConfigOptionFloat(linear ? (cur_flow + modifier) / cur_flow
                                                             : 1. + modifier / 100.));
            }

            s_calib_overrides.set_key_value("layer_height", new ConfigOptionFloat(layer_height));
            s_calib_overrides.set_key_value("alternate_extra_wall", new ConfigOptionBool(false));
            s_calib_overrides.set_key_value("initial_layer_print_height", new ConfigOptionFloat(first_layer_height));
            s_calib_overrides.set_key_value("reduce_crossing_wall", new ConfigOptionBool(true));
            s_calib_overrides.set_key_value("max_volumetric_extrusion_rate_slope", new ConfigOptionFloat(0));
            s_calib_label = linear ? (pass == 1 ? @"유량 YOLO" : @"유량 YOLO (미세)")
                                   : (pass == 1 ? @"유량 Pass 1" : @"유량 Pass 2");
        } else if ([mode isEqualToString:@"is_freq"] || [mode isEqualToString:@"is_damp"] ||
                   [mode isEqualToString:@"cornering"]) {
            // Desktop Plater::calib_input_shaping_freq / _damp / Calib_Cornering
            // (ringing tower model variant, single extruder).
            const bool cornering = [mode isEqualToString:@"cornering"];
            params.mode = cornering ? CalibMode::Calib_Cornering
                        : ([mode isEqualToString:@"is_freq"] ? CalibMode::Calib_Input_shaping_freq
                                                             : CalibMode::Calib_Input_shaping_damp);
            ModelObject *obj = load_calib_model(cornering ? "/calib/cornering/SCV-V2.drc"
                                                          : "/calib/input_shaping/ringing_tower.drc");

            const auto *flavor_opt = config.option<ConfigOptionEnum<GCodeFlavor>>("gcode_flavor");
            const auto *junction   = config.option<ConfigOptionFloats>("machine_max_junction_deviation");
            const bool  has_junction = flavor_opt && flavor_opt->value == GCodeFlavor::gcfMarlinFirmware &&
                                       junction && !junction->values.empty() && junction->values.front() > 0;
            if (has_junction) {
                const double value = cornering ? end : std::max(junction->values.front(), 0.25);
                s_calib_overrides.set_key_value("machine_max_junction_deviation", new ConfigOptionFloats(1, value));
                s_calib_overrides.set_key_value("default_junction_deviation", new ConfigOptionFloatsNullable(1, 0.));
            } else {
                const bool  klipper = flavor_opt && flavor_opt->value == GCodeFlavor::gcfKlipper;
                const auto *jerk_x  = config.option<ConfigOptionFloats>("machine_max_jerk_x");
                const auto *jerk_y  = config.option<ConfigOptionFloats>("machine_max_jerk_y");
                const double base   = klipper ? 5. : 10.;
                const double vx = cornering ? end : std::max(jerk_x && !jerk_x->values.empty() ? jerk_x->values.front() : 0., base);
                const double vy = cornering ? end : std::max(jerk_y && !jerk_y->values.empty() ? jerk_y->values.front() : 0., base);
                s_calib_overrides.set_key_value("machine_max_jerk_x", new ConfigOptionFloats(1, vx));
                s_calib_overrides.set_key_value("machine_max_jerk_y", new ConfigOptionFloats(1, vy));
                s_calib_overrides.set_key_value("default_jerk", new ConfigOptionFloatsNullable(1, 0.));
            }

            const auto *pa_enabled = config.option<ConfigOptionBools>("enable_pressure_advance");
            if (!pa_enabled || pa_enabled->values.empty() || !pa_enabled->values.front()) {
                s_calib_overrides.set_key_value("enable_pressure_advance", new ConfigOptionBools(1, true));
                s_calib_overrides.set_key_value("pressure_advance", new ConfigOptionFloatsNullable(1, 0.));
                s_calib_overrides.set_key_value("adaptive_pressure_advance", new ConfigOptionBools(1, false));
            }

            if (cornering) {
                s_calib_overrides.set_key_value("input_shaping_emit", new ConfigOptionBool(true));
                s_calib_overrides.set_key_value("input_shaping_type", new ConfigOptionEnum<InputShaperType>(InputShaperType::Disable));
                const auto *fmvs_opt = config.option<ConfigOptionFloats>("filament_max_volumetric_speed");
                const double fmvs = fmvs_opt && !fmvs_opt->values.empty() ? fmvs_opt->values.front() : 0.;
                s_calib_overrides.set_key_value("filament_max_volumetric_speed", new ConfigOptionFloats(1, std::max(fmvs, 200.)));
            } else {
                s_calib_overrides.set_key_value("input_shaping_emit", new ConfigOptionBool(false));
            }
            if (params.mode == CalibMode::Calib_Input_shaping_freq)
                s_calib_overrides.set_key_value("layer_height", new ConfigOptionFloat(0.2));

            s_calib_overrides.set_key_value("slow_down_layer_time", new ConfigOptionFloats(1, 0.));
            s_calib_overrides.set_key_value("slow_down_min_speed", new ConfigOptionFloats(1, 0.));
            s_calib_overrides.set_key_value("slow_down_for_layer_cooling", new ConfigOptionBools(1, false));
            s_calib_overrides.set_key_value("enable_overhang_speed", new ConfigOptionBoolsNullable(1, false));
            s_calib_overrides.set_key_value("timelapse_type", new ConfigOptionEnum<TimelapseType>(tlTraditional));
            s_calib_overrides.set_key_value("wall_loops", new ConfigOptionInt(1));
            s_calib_overrides.set_key_value("top_shell_layers", new ConfigOptionInt(0));
            s_calib_overrides.set_key_value("bottom_shell_layers", new ConfigOptionInt(1));
            s_calib_overrides.set_key_value("sparse_infill_density", new ConfigOptionPercent(0));
            s_calib_overrides.set_key_value("detect_thin_wall", new ConfigOptionBool(false));
            s_calib_overrides.set_key_value("spiral_mode", new ConfigOptionBool(true));
            s_calib_overrides.set_key_value("spiral_mode_smooth", new ConfigOptionBool(false));
            s_calib_overrides.set_key_value("bottom_surface_pattern", new ConfigOptionEnum<InfillPattern>(ipRectilinear));
            const auto *msx = config.option<ConfigOptionFloats>("machine_max_speed_x");
            const auto *msy = config.option<ConfigOptionFloats>("machine_max_speed_y");
            const auto *acc = config.option<ConfigOptionFloats>("machine_max_acceleration_extruding");
            const double max_speed = std::min(msx && !msx->values.empty() ? msx->values.front() : 200.,
                                              msy && !msy->values.empty() ? msy->values.front() : 200.);
            const double max_accel = acc && !acc->values.empty() ? acc->values.front() : 5000.;
            s_calib_overrides.set_key_value("outer_wall_speed", new ConfigOptionFloatsNullable(1, max_speed));
            s_calib_overrides.set_key_value("default_acceleration", new ConfigOptionFloatsNullable(1, max_accel));
            s_calib_overrides.set_key_value("outer_wall_acceleration", new ConfigOptionFloatsNullable(1, max_accel));
            s_calib_overrides.set_key_value("precise_z_height", new ConfigOptionBool(false));
            obj->config.set_key_value("brim_type", new ConfigOptionEnum<BrimType>(btOuterOnly));
            obj->config.set_key_value("brim_width", new ConfigOptionFloat(3.0));
            obj->config.set_key_value("brim_object_gap", new ConfigOptionFloat(0.0));
            drop_on_bed_center(obj);
            s_calib_label = cornering ? @"코너링" : (params.mode == CalibMode::Calib_Input_shaping_freq
                                                     ? @"인풋 셰이핑 주파수" : @"인풋 셰이핑 댐핑");
        } else {
            throw std::runtime_error("unknown calibration mode");
        }

        s_calib_params = params;
        return YES;
    } catch (const std::exception &ex) {
        reset_calibration();
        if (error) *error = make_error(ex.what());
    } catch (...) {
        reset_calibration();
        if (error) *error = make_error("unknown calibration error");
    }
    return NO;
}

+ (NSString *)activeCalibration
{
    return s_calib_label;
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
