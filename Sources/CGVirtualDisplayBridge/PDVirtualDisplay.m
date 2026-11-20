#import "PDVirtualDisplay.h"

// Private CoreGraphics CGVirtualDisplay class declarations (macOS 11+ / Apple Silicon & Intel)
@interface CGVirtualDisplayMode : NSObject
@property (readonly, nonatomic) CGFloat refreshRate;
@property (readonly, nonatomic) NSUInteger width;
@property (readonly, nonatomic) NSUInteger height;
- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
                  refreshRate:(CGFloat)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) NSUInteger hiDPI;
@property (nonatomic, strong) NSArray<CGVirtualDisplayMode *> *modes;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) NSUInteger maxPixelsWide;
@property (nonatomic) NSUInteger maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) uint32_t productID;
@property (nonatomic) uint32_t vendorID;
@property (nonatomic) uint32_t serialNum;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@property (nonatomic, copy) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

@interface PDVirtualDisplay ()
@property (nonatomic, strong, nullable) CGVirtualDisplay *display;
@property (nonatomic, readwrite) CGDirectDisplayID displayID;
@property (nonatomic, readwrite) NSUInteger logicalWidth;
@property (nonatomic, readwrite) NSUInteger logicalHeight;
@property (nonatomic, readwrite) BOOL hiDPI;
@property (nonatomic, readwrite) double refreshRate;
@end

@implementation PDVirtualDisplay

- (nullable instancetype)initWithName:(NSString *)name
                         logicalWidth:(NSUInteger)width
                        logicalHeight:(NSUInteger)height
                                  ppi:(NSUInteger)ppi
                                hiDPI:(BOOL)hiDPI
                          refreshRate:(double)refreshRate {
    self = [super init];
    if (!self) { return nil; }

    Class descClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    if (!descClass || !displayClass) {
        return nil;
    }

    NSUInteger scale = hiDPI ? 2 : 1;
    // Allow headroom up to 4K so dynamic resolution/orientation switches work seamlessly.
    NSUInteger maxW = MAX(width * scale, 3840);
    NSUInteger maxH = MAX(height * scale, 2560);

    CGVirtualDisplayDescriptor *desc = [[descClass alloc] init];
    desc.queue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
    desc.name = name;
    desc.maxPixelsWide = maxW;
    desc.maxPixelsHigh = maxH;

    double effectivePPI = (double)MAX(ppi, 72);
    double widthMM = ((double)(width * scale) / effectivePPI) * 25.4;
    double heightMM = ((double)(height * scale) / effectivePPI) * 25.4;
    desc.sizeInMillimeters = CGSizeMake(widthMM, heightMM);

    // sRGB / Display P3-friendly primaries
    desc.redPrimary = CGPointMake(0.6400, 0.3300);
    desc.greenPrimary = CGPointMake(0.3000, 0.6000);
    desc.bluePrimary = CGPointMake(0.1500, 0.0600);
    desc.whitePoint = CGPointMake(0.3127, 0.3290);

    desc.vendorID = 0x5044;  // "PD"
    desc.productID = 0x0001;
    desc.serialNum = 0x0001;

    CGVirtualDisplay *virtualDisplay = [[displayClass alloc] initWithDescriptor:desc];
    if (!virtualDisplay) {
        return nil;
    }

    _display = virtualDisplay;
    _displayID = virtualDisplay.displayID;
    _logicalWidth = width;
    _logicalHeight = height;
    _hiDPI = hiDPI;
    _refreshRate = refreshRate;

    if (![self applyLogicalWidth:width logicalHeight:height hiDPI:hiDPI refreshRate:refreshRate]) {
        _display = nil;
        _displayID = kCGNullDirectDisplay;
        return nil;
    }

    return self;
}

- (BOOL)applyLogicalWidth:(NSUInteger)width
            logicalHeight:(NSUInteger)height
                    hiDPI:(BOOL)hiDPI
              refreshRate:(double)refreshRate {
    if (!self.display) {
        return NO;
    }

    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    if (!settingsClass || !modeClass) {
        return NO;
    }

    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;

    // Provide primary mode (and 1x mode when HiDPI is active)
    CGVirtualDisplayMode *primaryMode = [[modeClass alloc] initWithWidth:width
                                                                  height:height
                                                             refreshRate:refreshRate];
    settings.modes = @[primaryMode];

    BOOL ok = [self.display applySettings:settings];
    if (ok) {
        self.logicalWidth = width;
        self.logicalHeight = height;
        self.hiDPI = hiDPI;
        self.refreshRate = refreshRate;
    }
    return ok;
}

- (BOOL)isActive {
    return self.display != nil && self.displayID != kCGNullDirectDisplay;
}

- (void)teardown {
    self.display = nil;
    self.displayID = kCGNullDirectDisplay;
}

- (void)dealloc {
    [self teardown];
}

@end
