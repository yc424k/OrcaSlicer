#import <Foundation/Foundation.h>

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

#pragma mark - Slicing

/// Slices a model file (STL/3MF/OBJ). Uses the selected presets when the
/// preset system is initialized, built-in defaults otherwise.
+ (BOOL)sliceModelAtPath:(NSString *)inputPath
             toGcodePath:(NSString *)outputPath
                   error:(NSError **)error;

/// Slices a built-in 20 mm calibration cube — no input file needed.
+ (BOOL)sliceTestCubeToGcodePath:(NSString *)outputPath
                           error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
