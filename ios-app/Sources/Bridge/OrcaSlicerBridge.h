#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin Objective-C facade over the libslic3r core for the Swift app.
/// All methods are synchronous and CPU-heavy — call them off the main thread.
@interface OrcaSlicerCore : NSObject

/// Slicer core version string (e.g. "2.5.0-dev").
+ (NSString *)coreVersion;

/// Slices a model file (STL/3MF/OBJ) with default print settings.
+ (BOOL)sliceModelAtPath:(NSString *)inputPath
             toGcodePath:(NSString *)outputPath
                   error:(NSError **)error;

/// Slices a built-in 20 mm calibration cube — no input file needed.
+ (BOOL)sliceTestCubeToGcodePath:(NSString *)outputPath
                           error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
