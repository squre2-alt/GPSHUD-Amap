// GPSHUD.m — 零依赖版本（不依赖 Cydia Substrate / ElleKit）
// 仅用系统 Objective-C runtime 做 method swizzling，适合巨魔(TrollStore)注入。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>

#pragma mark - 自检浮窗

@interface GPSHUDView : UIView
@property (nonatomic, strong) UILabel *label;
@end

@implementation GPSHUDView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.78];
        self.layer.cornerRadius = 10;
        self.layer.borderColor = [UIColor redColor].CGColor;
        self.layer.borderWidth = 1.5;
        self.clipsToBounds = YES;

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        label.numberOfLines = 0;
        [self addSubview:label];
        self.label = label;

        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
            [label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
            [label.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
            [label.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8],
        ]];
    }
    return self;
}

@end

#pragma mark - 管理器

@interface GPSHUDManager : NSObject
@property (nonatomic, strong) NSHashTable<CLLocationManager *> *managers;
@property (nonatomic, strong) UIWindow *hudWindow;
@property (nonatomic, strong) GPSHUDView *hudView;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) NSInteger hookHits;
+ (instancetype)shared;
- (void)registerManager:(CLLocationManager *)m;
- (void)showHUD;
@end

@implementation GPSHUDManager

+ (instancetype)shared {
    static GPSHUDManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _managers = [NSHashTable weakObjectsHashTable];
    }
    return self;
}

- (void)registerManager:(CLLocationManager *)m {
    if (!m) return;
    self.hookHits++;
    [self.managers addObject:m];
}

- (void)showHUD {
    if (self.hudWindow) return;

    UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectZero];
    window.windowLevel = UIWindowLevelAlert + 100;
    window.backgroundColor = [UIColor clearColor];
    window.userInteractionEnabled = NO; // 不拦截触摸

    GPSHUDView *view = [[GPSHUDView alloc] initWithFrame:CGRectZero];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [window addSubview:view];
    self.hudView = view;

    [NSLayoutConstraint activateConstraints:@[
        [view.topAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.topAnchor constant:55],
        [view.leadingAnchor constraintEqualToAnchor:window.leadingAnchor constant:12],
        [view.widthAnchor constraintEqualToConstant:265],
    ]];

    window.hidden = NO;
    self.hudWindow = window;

    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                  target:self
                                                selector:@selector(refresh)
                                                userInfo:nil
                                                 repeats:YES];
    [self refresh];
    NSLog(@"[GPSHUD] HUD shown, hookHits=%ld", (long)self.hookHits);
}

- (void)refresh {
    NSUInteger count = self.managers.allObjects.count;
    CLLocation *best = nil;
    for (CLLocationManager *m in self.managers.allObjects) {
        CLLocation *l = m.location;
        if (!l) continue;
        if (!best ||
            (l.horizontalAccuracy >= 0 &&
             (best.horizontalAccuracy < 0 || l.horizontalAccuracy < best.horizontalAccuracy))) {
            best = l;
        }
    }

    NSString *detail;
    if (!best) {
        detail = count > 0 ? @"已捕获定位管理器,等待定位数据…" : @"未捕获定位管理器(hook 未命中)";
    } else {
        double acc = best.horizontalAccuracy;
        NSString *level;
        UIColor *color;
        if (acc < 0) {
            level = @"无效定位"; color = [UIColor systemRedColor];
        } else if (acc < 8) {
            level = @"强"; color = [UIColor systemGreenColor];
        } else if (acc < 20) {
            level = @"良好"; color = [UIColor systemYellowColor];
        } else if (acc < 50) {
            level = @"一般"; color = [UIColor systemOrangeColor];
        } else if (acc < 100) {
            level = @"弱"; color = [UIColor systemRedColor];
        } else {
            level = @"极弱"; color = [UIColor systemRedColor];
        }
        double speed = best.speed >= 0 ? best.speed * 3.6 : 0;
        detail = [NSString stringWithFormat:
                  @"水平精度: %.1f m\n信号等级: %@\n速度: %.1f km/h\n海拔: %.1f m",
                  acc, level, speed, best.altitude];
    }

    NSString *text = [NSString stringWithFormat:
        @"GPS HUD 已加载\nhook命中: %ld 次 | 管理器: %lu\n%@",
        (long)self.hookHits, (unsigned long)count, detail];

    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:text attributes:@{
        NSForegroundColorAttributeName: [UIColor whiteColor],
        NSFontAttributeName: [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular],
    }];
    self.hudView.label.attributedText = attr;
}

@end

#pragma mark - Swizzle 实现

@interface CLLocationManager (GPSHUD)
- (instancetype)gpshud_init;
- (void)gpshud_startUpdatingLocation;
- (void)gpshud_requestLocation;
- (void)gpshud_startMonitoringSignificantLocationChanges;
@end

@implementation CLLocationManager (GPSHUD)

- (instancetype)gpshud_init {
    id o = [self gpshud_init]; // 交换后指向原始 init
    [[GPSHUDManager shared] registerManager:o];
    return o;
}

- (void)gpshud_startUpdatingLocation {
    [self gpshud_startUpdatingLocation];
    [[GPSHUDManager shared] registerManager:self];
}

- (void)gpshud_requestLocation {
    [self gpshud_requestLocation];
    [[GPSHUDManager shared] registerManager:self];
}

- (void)gpshud_startMonitoringSignificantLocationChanges {
    [self gpshud_startMonitoringSignificantLocationChanges];
    [[GPSHUDManager shared] registerManager:self];
}

@end

// 健壮 swizzle：方法继承自父类时，先添加再替换，避免污染父类
static void GPSHUDSwizzle(Class cls, SEL origSel, SEL customSel) {
    Method origMethod = class_getInstanceMethod(cls, origSel);
    Method customMethod = class_getInstanceMethod(cls, customSel);
    if (!origMethod || !customMethod) {
        NSLog(@"[GPSHUD] swizzle skipped: %@", NSStringFromSelector(origSel));
        return;
    }
    const char *types = method_getTypeEncoding(origMethod);
    IMP origImp = method_getImplementation(origMethod);
    IMP customImp = method_getImplementation(customMethod);

    if (class_addMethod(cls, origSel, customImp, types)) {
        class_replaceMethod(cls, customSel, origImp, types);
    } else {
        method_exchangeImplementations(origMethod, customMethod);
    }
    NSLog(@"[GPSHUD] swizzled: %@", NSStringFromSelector(origSel));
}

__attribute__((constructor)) static void GPSHUDLoad(void) {
    NSLog(@"[GPSHUD] dylib loaded");

    Class cls = [CLLocationManager class];
    GPSHUDSwizzle(cls, @selector(init), @selector(gpshud_init));
    GPSHUDSwizzle(cls, @selector(startUpdatingLocation), @selector(gpshud_startUpdatingLocation));
    GPSHUDSwizzle(cls, @selector(requestLocation), @selector(gpshud_requestLocation));
    GPSHUDSwizzle(cls, @selector(startMonitoringSignificantLocationChanges),
                  @selector(gpshud_startMonitoringSignificantLocationChanges));

    // 延迟显示，等 UIApplication / keyWindow 就绪
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [[GPSHUDManager shared] showHUD];
    });
}
