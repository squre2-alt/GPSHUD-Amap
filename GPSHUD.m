// GPSHUD.m — 诊断版 v3
// 目标：找出"重启后不提示信号弱"的根因
// 新增诊断维度：
//  1. 数据年龄（最后一条定位距今多久）—— 判断定位服务是否卡住/注入陈旧数据
//  2. 每个管理器的更新时间 + 精度（区分哪个会话在供数）
//  3. 精度范围（min/max/avg）+ 采样数
//  4. 定位回调频率（每秒几次）—— 判断定位流是否活跃
//  5. 详细日志落盘 gpshud_diag.log，重启前后各导出一份对比
// 零依赖：仅 objc runtime swizzle，不依赖 Substrate/ElleKit。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>

#pragma mark - 日志

static NSString *GPSHUDLogPath(void) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return dir ? [dir stringByAppendingPathComponent:@"gpshud_diag.log"] : nil;
}

static void GPSHUDWriteLog(NSString *line) {
    NSLog(@"[GPSHUD] %@", line);
    NSString *path = GPSHUDLogPath();
    if (!path) return;
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss";
    NSString *full = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:[NSDate date]], line];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[full dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [full writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

#pragma mark - 诊断记录

@interface GPSLocSample : NSObject
@property (nonatomic, strong) NSDate *time;
@property (nonatomic, assign) double acc;
@property (nonatomic, assign) double speed;
@end
@implementation GPSLocSample
@end

#pragma mark - 浮窗

@interface GPSHUDView : UIView
@property (nonatomic, strong) UILabel *label;
@end

@implementation GPSHUDView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.80];
        self.layer.cornerRadius = 10;
        self.layer.borderColor = [UIColor redColor].CGColor;
        self.layer.borderWidth = 1.5;
        self.clipsToBounds = YES;

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
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

// 诊断状态
@property (nonatomic, strong) NSDate *lastLocationTime;      // 最后一次收到定位回调的墙钟时间
@property (nonatomic, strong) NSDate *lastLocTimestamp;      // 最后一条 CLLocation 的时间戳
@property (nonatomic, assign) NSInteger updateCount;         // 定位更新次数
@property (nonatomic, assign) double minAcc;
@property (nonatomic, assign) double maxAcc;
@property (nonatomic, assign) double sumAcc;
@property (nonatomic, assign) NSInteger accSamples;
@property (nonatomic, strong) NSMutableArray<GPSLocSample *> *history;
@property (nonatomic, assign) BOOL loggedStall;

+ (instancetype)shared;
- (void)registerManager:(CLLocationManager *)m;
- (void)noteLocation:(CLLocation *)loc;
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
        _history = [NSMutableArray array];
        _minAcc = -1;
        _maxAcc = 0;
    }
    return self;
}

- (void)registerManager:(CLLocationManager *)m {
    if (!m) return;
    self.hookHits++;
    [self.managers addObject:m];
}

// 记录一次定位，检测是否是新数据
- (void)noteLocation:(CLLocation *)loc {
    if (!loc) return;
    NSDate *ts = loc.timestamp ?: [NSDate date];
    double acc = loc.horizontalAccuracy;

    BOOL isNew = !self.lastLocTimestamp || [ts timeIntervalSinceDate:self.lastLocTimestamp] > 0.0001;
    if (isNew) {
        self.lastLocTimestamp = ts;
        self.lastLocationTime = [NSDate date];
        self.updateCount++;

        if (acc >= 0) {
            if (self.minAcc < 0 || acc < self.minAcc) self.minAcc = acc;
            if (acc > self.maxAcc) self.maxAcc = acc;
            self.sumAcc += acc;
            self.accSamples++;
        }

        GPSLocSample *s = [[GPSLocSample alloc] init];
        s.time = self.lastLocationTime;
        s.acc = acc;
        s.speed = loc.speed;
        [self.history addObject:s];
        if (self.history.count > 200) [self.history removeObjectAtIndex:0];

        self.loggedStall = NO;

        // 每次新数据写日志（含数据年龄 = 定位时间戳到现在的延迟）
        NSTimeInterval tsAge = [[NSDate date] timeIntervalSinceDate:ts];
        GPSHUDWriteLog([NSString stringWithFormat:
            @"NEW #%ld acc=%.1fm speed=%.1f tsAge=%.1fs total=%ld",
            (long)self.updateCount, acc, loc.speed, tsAge, (long)self.accSamples]);
    }

    // 检测数据停滞：超过 6 秒没有新定位
    if (!self.loggedStall && self.lastLocationTime &&
        [[NSDate date] timeIntervalSinceDate:self.lastLocationTime] > 6) {
        self.loggedStall = YES;
        GPSHUDWriteLog(@"STALL: no new location for >6s");
    }
}

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
    if (self.hudView && self.hudView.superview) return;

    GPSHUDView *view = [[GPSHUDView alloc] initWithFrame:CGRectZero];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    self.hudView = view;

    UIWindow *host = [self findKeyWindow];
    if (host) {
        [host addSubview:view];
        [NSLayoutConstraint activateConstraints:@[
            [view.topAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.topAnchor constant:55],
            [view.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:12],
            [view.widthAnchor constraintEqualToConstant:290],
        ]];
        GPSHUDWriteLog(@"HUD attached to host keyWindow");
    } else {
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
            [view.widthAnchor constraintEqualToConstant:290],
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
        [self noteLocation:l]; // 记录每个管理器的数据（内部按时间戳去重）
    }

    // 数据年龄：最后一次新定位距今多久
    double dataAge = self.lastLocationTime ? [[NSDate date] timeIntervalSinceDate:self.lastLocationTime] : -1;

    NSString *level;
    double acc = best ? best.horizontalAccuracy : -1;
    if (acc < 0) level = @"无效";
    else if (acc < 8) level = @"强";
    else if (acc < 20) level = @"良好";
    else if (acc < 50) level = @"一般";
    else if (acc < 100) level = @"弱";
    else level = @"极弱";

    NSString *rangeStr = self.accSamples > 0
        ? [NSString stringWithFormat:@"%.1f~%.1f(均%.1f)", self.minAcc, self.maxAcc, self.sumAcc / self.accSamples]
        : @"—";

    NSString *ageStr = dataAge < 0 ? @"—" : [NSString stringWithFormat:@"%.1fs", dataAge];
    NSString *fresh;
    if (dataAge < 0) fresh = @"无数据";
    else if (dataAge < 3) fresh = @"新鲜";
    else if (dataAge < 8) fresh = @"偏旧";
    else fresh = @"停滞!";

    NSString *text = [NSString stringWithFormat:
        @"GPS 诊断 v3 | %@\n"
        @"精度 %.1fm [%@] 新数据 %ld 次\n"
        @"数据年龄 %@ (%@) 会话 %lu\n"
        @"精度范围 %@\n"
        @"速度 %.1fkm/h 海拔 %.0fm\n"
        @"hook %ld | 日志: Documents/gpshud_diag.log",
        acc >= 0 ? level : @"无定位", acc, level, (long)self.updateCount,
        ageStr, fresh, (unsigned long)count,
        rangeStr,
        best && best.speed >= 0 ? best.speed * 3.6 : 0, best ? best.altitude : 0,
        (long)self.hookHits];

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
    if (!origMethod || !customMethod) return;
    const char *types = method_getTypeEncoding(origMethod);
    IMP origImp = method_getImplementation(origMethod);
    IMP customImp = method_getImplementation(customMethod);
    if (class_addMethod(cls, origSel, customImp, types)) {
        class_replaceMethod(cls, customSel, origImp, types);
    } else {
        method_exchangeImplementations(origMethod, customMethod);
    }
}

__attribute__((constructor)) static void GPSHUDLoad(void) {
    GPSHUDWriteLog(@"=== dylib loaded, diagnostic v3 ===");
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);

    Class cls = [CLLocationManager class];
    GPSHUDSwizzle(cls, @selector(init), @selector(gpshud_init));
    GPSHUDSwizzle(cls, @selector(startUpdatingLocation), @selector(gpshud_startUpdatingLocation));
    GPSHUDSwizzle(cls, @selector(requestLocation), @selector(gpshud_requestLocation));
    GPSHUDSwizzle(cls, @selector(startMonitoringSignificantLocationChanges),
                  @selector(gpshud_startMonitoringSignificantLocationChanges));

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [[GPSHUDManager shared] showHUD];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [[GPSHUDManager shared] showHUD];
    });
}
