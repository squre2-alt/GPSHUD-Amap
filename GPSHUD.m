// GPSHUD.m — 零依赖版本 v2
// 修复点：
//  1. iOS 13+ SceneDelegate 下自建 UIWindow 不显示 → 改为挂到宿主 keyWindow
//  2. 加震动信号：加载成功时震动一下，便于确认 dylib 是否真的被加载
//  3. 多重显示时机 + 日志，便于诊断
// 不依赖 Cydia Substrate / ElleKit，适合 TrollFools / TrollStore 注入。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>

#pragma mark - 日志（NSLog + 落盘，便于导出诊断）

static void GPSHUDWriteLog(NSString *line) {
    NSLog(@"[GPSHUD] %@", line);
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!dir) return;
    NSString *path = [dir stringByAppendingPathComponent:@"gpshud_diag.log"];
    NSString *full = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], line];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[full dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [full writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

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
@property (nonatomic, strong) UIWindow *fallbackWindow;
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

// 找到当前显示中的 keyWindow（兼容 iOS 13+ SceneDelegate）
- (UIWindow *)findKeyWindow {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
            if (scene.activationState == UISceneActivationStateForegroundActive &&
                [scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                for (UIWindow *w in ws.windows) {
                    if (w.isKeyWindow) return w;
                }
                if (ws.windows.firstObject) return ws.windows.firstObject;
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [[UIApplication sharedApplication] keyWindow];
#pragma clang diagnostic pop
}

- (void)showHUD {
    if (self.hudView && self.hudView.superview) {
        return; // 已经显示
    }

    GPSHUDView *view = [[GPSHUDView alloc] initWithFrame:CGRectZero];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    self.hudView = view;

    UIWindow *host = [self findKeyWindow];
    if (host) {
        // 方案 A（首选）：直接挂到宿主 keyWindow，必定可见
        [host addSubview:view];
        [NSLayoutConstraint activateConstraints:@[
            [view.topAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.topAnchor constant:55],
            [view.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:12],
            [view.widthAnchor constraintEqualToConstant:265],
        ]];
        GPSHUDWriteLog(@"HUD attached to host keyWindow");
    } else {
        // 方案 B（兜底）：自建 window，绑定 active scene
        UIWindow *window = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
                    break;
                }
            }
        }
        if (!window) window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
        window.windowLevel = UIWindowLevelAlert + 100;
        window.backgroundColor = [UIColor clearColor];
        window.userInteractionEnabled = NO;
        [window addSubview:view];
        [NSLayoutConstraint activateConstraints:@[
            [view.topAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.topAnchor constant:55],
            [view.leadingAnchor constraintEqualToAnchor:window.leadingAnchor constant:12],
            [view.widthAnchor constraintEqualToConstant:265],
        ]];
        window.hidden = NO;
        self.fallbackWindow = window;
        GPSHUDWriteLog(@"HUD attached to fallback window");
    }

    if (!self.timer) {
        self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                      target:self
                                                    selector:@selector(refresh)
                                                    userInfo:nil
                                                     repeats:YES];
    }
    [self refresh];
}

- (void)refresh {
    // 每次刷新把浮窗置顶，防止被后加的视图盖住
    UIView *sup = self.hudView.superview;
    if (sup) [sup bringSubviewToFront:self.hudView];

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
        if (acc < 0) {
            level = @"无效定位";
        } else if (acc < 8) {
            level = @"强";
        } else if (acc < 20) {
            level = @"良好";
        } else if (acc < 50) {
            level = @"一般";
        } else if (acc < 100) {
            level = @"弱";
        } else {
            level = @"极弱";
        }
        double speed = best.speed >= 0 ? best.speed * 3.6 : 0;
        detail = [NSString stringWithFormat:
                  @"水平精度: %.1f m\n信号等级: %@\n速度: %.1f km/h\n海拔: %.1f m",
                  acc, level, speed, best.altitude];
    }

    NSString *text = [NSString stringWithFormat:
        @"GPS HUD 已加载\nhook命中: %ld 次 | 管理器: %lu\n%@",
        (long)self.hookHits, (unsigned long)count, detail];

    self.hudView.label.text = text;
}

@end

#pragma mark - Swizzle

@interface CLLocationManager (GPSHUD)
- (instancetype)gpshud_init;
- (void)gpshud_startUpdatingLocation;
- (void)gpshud_requestLocation;
- (void)gpshud_startMonitoringSignificantLocationChanges;
@end

@implementation CLLocationManager (GPSHUD)

- (instancetype)gpshud_init {
    id o = [self gpshud_init];
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

static void GPSHUDSwizzle(Class cls, SEL origSel, SEL customSel) {
    Method origMethod = class_getInstanceMethod(cls, origSel);
    Method customMethod = class_getInstanceMethod(cls, customSel);
    if (!origMethod || !customMethod) {
        GPSHUDWriteLog([NSString stringWithFormat:@"swizzle skipped: %@", NSStringFromSelector(origSel)]);
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
    GPSHUDWriteLog([NSString stringWithFormat:@"swizzled: %@", NSStringFromSelector(origSel)]);
}

__attribute__((constructor)) static void GPSHUDLoad(void) {
    GPSHUDWriteLog([NSString stringWithFormat:@"dylib loaded, PID=%d", getpid()]);

    // 震动一次：打开高德时震一下 = dylib 确实加载了
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);

    Class cls = [CLLocationManager class];
    GPSHUDSwizzle(cls, @selector(init), @selector(gpshud_init));
    GPSHUDSwizzle(cls, @selector(startUpdatingLocation), @selector(gpshud_startUpdatingLocation));
    GPSHUDSwizzle(cls, @selector(requestLocation), @selector(gpshud_requestLocation));
    GPSHUDSwizzle(cls, @selector(startMonitoringSignificantLocationChanges),
                  @selector(gpshud_startMonitoringSignificantLocationChanges));

    // 多个时间点尝试显示，确保 keyWindow 就绪
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [[GPSHUDManager shared] showHUD];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [[GPSHUDManager shared] showHUD];
    });
}
