#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin Objective-C facade over the libslic3r core for the Swift app.
/// All methods are synchronous and CPU-heavy — call them off the main thread.
@interface OrcaSlicerCore : NSObject

/// Slicer core version string (e.g. "2.5.0-dev").
+ (NSString *)coreVersion;

#pragma mark - Preset system

/// Loads the bundled system profiles (resources dir must contain `profiles/`)
/// and the user presets under dataPath. Call once at startup.
+ (BOOL)initializeWithResourcesPath:(NSString *)resourcesPath
                           dataPath:(NSString *)dataPath
                              error:(NSError **)error;

/// All system printer preset names. Empty until initialized.
+ (NSArray<NSString *> *)printerPresets;
/// Process (print settings) presets compatible with the selected printer.
+ (NSArray<NSString *> *)processPresets;
/// Filament presets compatible with the selected printer.
+ (NSArray<NSString *> *)filamentPresets;

+ (nullable NSString *)selectedPrinter;
+ (nullable NSString *)selectedProcess;
+ (nullable NSString *)selectedFilament;

/// Selecting a printer re-resolves the compatible process/filament presets
/// (and may auto-switch the current selections).
+ (BOOL)selectPrinter:(NSString *)name error:(NSError **)error;
+ (BOOL)selectProcess:(NSString *)name error:(NSError **)error;
+ (BOOL)selectFilament:(NSString *)name error:(NSError **)error;

/// Saves the current (edited) settings of a tab as a user preset and selects
/// it. The preset is written under the data dir and survives restarts.
+ (BOOL)saveCurrentPresetAs:(NSString *)name tab:(NSString *)tab;

/// Printable area of the selected printer in mm (zero when unknown).
+ (CGSize)bedSize;

#pragma mark - Config editing

/// All editable options of one settings tab ("process" | "filament" | "printer"),
/// each described as { key, label, tooltip, category, unit, type, value,
/// presetValue, enumValues, enumLabels }. `value` is the current (edited)
/// serialized value; `presetValue` the selected preset's original.
+ (NSArray<NSDictionary<NSString *, id> *> *)configOptionsForTab:(NSString *)tab;

/// Sets a serialized value on the edited preset; slicing picks it up via
/// full_config(). Returns the normalized serialized value or nil on failure.
+ (nullable NSString *)setConfigValue:(NSString *)value
                               forKey:(NSString *)key
                                  tab:(NSString *)tab;

#pragma mark - Slicing

/// Slices a model file (STL/3MF/OBJ). Uses the selected presets when the
/// preset system is initialized, built-in defaults otherwise.
+ (BOOL)sliceModelAtPath:(NSString *)inputPath
             toGcodePath:(NSString *)outputPath
                   error:(NSError **)error;

/// Slices a built-in 20 mm calibration cube — no input file needed.
+ (BOOL)sliceTestCubeToGcodePath:(NSString *)outputPath
                           error:(NSError **)error;

/// Progress of the slicing currently running on another thread: 0–100, or -1
/// when idle. Poll from the UI.
+ (NSInteger)slicingProgress;

/// Cancels the slicing currently running on another thread; its slice call
/// fails with a cancellation error.
+ (void)cancelSlicing;

/// Statistics of the last successful slice:
/// "time" (s), "filamentMM" (mm), "filamentG" (g). Nil before the first slice.
+ (nullable NSDictionary<NSString *, NSNumber *> *)lastSliceStats;

#pragma mark - Scene editing

/// Appends the objects of a model file (STL/3MF/OBJ) to the scene.
+ (BOOL)addModelToSceneAtPath:(NSString *)path error:(NSError **)error;
/// Appends a built-in 20 mm calibration cube to the scene.
+ (BOOL)addTestCubeToScene:(NSError **)error;

/// Scene objects as { index, name, positionX, positionY, rotationZ (deg),
/// scale (factor), sizeX/Y/Z (mm of the raw mesh) }.
+ (NSArray<NSDictionary<NSString *, id> *> *)sceneObjects;
/// Raw mesh of one object for rendering: { "vertices": float32 xyz per
/// vertex, "indices": uint32 triangle indices }.
+ (nullable NSDictionary<NSString *, NSData *> *)sceneMeshAtIndex:(NSInteger)index;

+ (BOOL)removeSceneObjectAtIndex:(NSInteger)index;
+ (void)clearScene;

/// Sets the first instance's transform (position mm, rotation degrees,
/// uniform scale factor) and drops the object back onto the bed.
+ (BOOL)setSceneObjectAtIndex:(NSInteger)index
                    positionX:(double)x
                    positionY:(double)y
                    rotationZ:(double)degrees
                        scale:(double)scale
    NS_SWIFT_NAME(setSceneObject(at:positionX:positionY:rotationZ:scale:));

/// Auto-arranges all scene objects with the current config's spacing.
+ (BOOL)arrangeScene:(NSError **)error;

/// Slices the whole scene with the selected presets/config edits.
+ (BOOL)sliceSceneToGcodePath:(NSString *)outputPath error:(NSError **)error;

#pragma mark - Calibration

/// Prepares a calibration test like the desktop Calibration menu: clears the
/// scene, loads the bundled test model, applies the mode's config overrides
/// and arms the core's calibration G-code generation for the next slice.
/// Modes: "temp" | "volspeed" | "retraction" | "vfa" | "pa_tower".
+ (BOOL)startCalibration:(NSString *)mode
                   start:(double)start
                     end:(double)end
                    step:(double)step
                   error:(NSError **)error;

/// Korean label of the armed calibration, nil when none. Any normal scene
/// operation (import, add cube, clear) disarms it.
+ (nullable NSString *)activeCalibration;

/// Mode key of the armed calibration ("temp", "pa_tower", …), nil when none.
+ (nullable NSString *)activeCalibrationMode;

/// Current (edited) serialized value of one option, nil when unavailable.
+ (nullable NSString *)configValueForKey:(NSString *)key tab:(NSString *)tab;

#pragma mark - Toolpath preview

/// Toolpath vertices of the last successful slice, for the 3D preview:
///  "positions" — float32 x,y,z per vertex (mm)
///  "types"     — uint8 per vertex (GCodeProcessor EMoveType; 8=Travel, 10=Extrude)
///  "roles"     — uint8 per vertex (ExtrusionRole)
/// Returns nil when nothing has been sliced yet.
+ (nullable NSDictionary<NSString *, NSData *> *)lastToolpaths;

@end

NS_ASSUME_NONNULL_END
