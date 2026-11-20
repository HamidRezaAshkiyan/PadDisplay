#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Clean Objective-C wrapper around macOS private CGVirtualDisplay APIs.
@interface PDVirtualDisplay : NSObject

@property (nonatomic, readonly) CGDirectDisplayID displayID;
@property (nonatomic, readonly) NSUInteger logicalWidth;
@property (nonatomic, readonly) NSUInteger logicalHeight;
@property (nonatomic, readonly) BOOL hiDPI;
@property (nonatomic, readonly) double refreshRate;
@property (nonatomic, readonly) BOOL isActive;

- (nullable instancetype)initWithName:(NSString *)name
                         logicalWidth:(NSUInteger)width
                        logicalHeight:(NSUInteger)height
                                  ppi:(NSUInteger)ppi
                                hiDPI:(BOOL)hiDPI
                          refreshRate:(double)refreshRate;

- (BOOL)applyLogicalWidth:(NSUInteger)width
            logicalHeight:(NSUInteger)height
                    hiDPI:(BOOL)hiDPI
              refreshRate:(double)refreshRate;

- (void)teardown;

@end

NS_ASSUME_NONNULL_END
