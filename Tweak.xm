#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>

#pragma mark - HUD 视图

@interface GPSHUDView : UIView
@property (nonatomic, strong) UILabel *label;
@end

@implementation GPSHUDView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.72];
        self.layer.cornerRadius = 10;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
        self.layer.borderWidth = 0.5;
        self.clipsToBounds = YES;

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
        label.numberOfLines = 0;
        label.lineBreakMode = NSLineBreakByWordWrapping;
        [self addSubview:label];
        self.label = label;

        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
            [label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
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
+ (instancetype)shared;
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
        // 延迟安装 HUD，避免干扰 App 启动流程
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self installHUD];
            self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                          target:self
                                                        selector:@selector(refresh)
                                                        userInfo:nil
                                                         repeats:YES];
            [self refresh];
        });
    }
    return self;
}

- (void)installHUD {
    if (self.hudWindow) return;

    UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectZero];
    window.windowLevel = UIWindowLevelStatusBar + 100;
    window.backgroundColor = [UIColor clearColor];
    window.userInteractionEnabled = NO; // 不拦截触摸，导航操作不受影响

    GPSHUDView *view = [[GPSHUDView alloc] initWithFrame:CGRectZero];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [window addSubview:view];
    self.hudView = view;

    // 顶部留出刘海/灵动岛空间
    [NSLayoutConstraint activateConstraints:@[
        [view.topAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.topAnchor constant:55],
        [view.leadingAnchor constraintEqualToAnchor:window.leadingAnchor constant:12],
        [view.widthAnchor constraintEqualToConstant:255],
    ]];

    window.hidden = NO;
    self.hudWindow = window;
}

- (void)refresh {
    // 在 App 持有的所有 CLLocationManager 中挑精度最好的一条定位
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

    if (!best) {
        self.hudView.label.text = @"GPS 诊断\n等待定位数据…";
        return;
    }

    double acc = best.horizontalAccuracy; // 米，负值代表无效
    NSString *level;
    UIColor *color;
    if (acc < 0) {
        level = @"无效定位";
        color = [UIColor systemRedColor];
    } else if (acc < 8) {
        level = @"强";
        color = [UIColor systemGreenColor];
    } else if (acc < 20) {
        level = @"良好";
        color = [UIColor systemYellowColor];
    } else if (acc < 50) {
        level = @"一般";
        color = [UIColor systemOrangeColor];
    } else if (acc < 100) {
        level = @"弱";
        color = [UIColor systemRedColor];
    } else {
        level = @"极弱";
        color = [UIColor systemRedColor];
    }

    double speed = best.speed >= 0 ? best.speed * 3.6 : 0; // m/s -> km/h
    double alt = best.altitude;

    NSString *text = [NSString stringWithFormat:
        @"GPS 诊断 (精度代理)\n"
        @"水平精度: %.1f m\n"
        @"信号等级: %@\n"
        @"速度: %.1f km/h\n"
        @"海拔: %.1f m",
        acc, level, speed, alt];

    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:text attributes:@{
        NSForegroundColorAttributeName: [UIColor whiteColor],
        NSFontAttributeName: [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular],
    }];
    NSRange levelRange = [text rangeOfString:level];
    if (levelRange.location != NSNotFound) {
        [attr addAttribute:NSForegroundColorAttributeName value:color range:levelRange];
    }
    self.hudView.label.attributedText = attr;
}

@end

#pragma mark - Hooks

// 捕获 App 创建的每一个 CLLocationManager（用弱引用表，不影响生命周期）
%hook CLLocationManager

- (id)init {
    id o = %orig;
    if (o) {
        [[GPSHUDManager shared].managers addObject:o];
    }
    return o;
}

%end
