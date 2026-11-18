#import "AppDelegate.h"
#import "RootViewController.h"
#import "Diag.h"

#ifdef LEGACY_DIAG
/* 见 NetProbe.m：真机 NSURLConnection 联网自检，只在 DIAG=1 时编译进二进制 */
void LegacyNetProbe(void);
#endif
#ifdef SPECIALPROBE
/* 见 SpecialProbe.m：「特别关注」数据源探针，仅 DIAG=1 SPECIALPROBE=1 */
void WeiboSpecialProbe(void);
#endif

/*
 * 刻意不使用 ObjC 实例变量：本二进制跳过 crt1.o、由 ld64 手工链接，
 * non-fragile ObjC2 ABI 的 _OBJC_IVAR_$ 偏移变量在 iOS 5/6 的 libobjc 上
 * 可能未初始化，导致 ivar 实际读到对象起始的 isa（非零）而非 nil。
 * 曾因此让 setupWindow 的幂等判断误判为"已建 window"而直接返回，界面全黑。
 * C 静态变量不依赖 ObjC runtime 的 ivar 布局，最稳妥。
 */
static UIWindow *sWindow = nil;

@implementation AppDelegate

/* 两个生命周期回调都实现：
   iOS 3.0+ 优先走 application:didFinishLaunchingWithOptions:，
   applicationDidFinishLaunching: 作为老系统/异常情况的兜底。
   setupWindow 内做幂等保护，避免两个回调都触发时重复建 window。 */
- (void)setupWindow
{
    diag("setupWindow: entered");
    if (sWindow) { diag("setupWindow: already created -> return"); return; }
    diag("setupWindow: no window yet, continue");

    CGRect screenBounds = [[UIScreen mainScreen] bounds];
    diag("setupWindow: got screen bounds");

    UIWindow *window = [[UIWindow alloc] initWithFrame:screenBounds];
    diag("setupWindow: window allocated");
    sWindow = window;

    RootViewController *root = [[RootViewController alloc] init];
    diag("setupWindow: root vc allocated");
    [window setRootViewController:root];
    diag("setupWindow: root vc set");
    [root release];

    [window makeKeyAndVisible];
    diag("setupWindow: window made key and visible");

#if defined(LEGACY_DIAG) && !defined(LEGACY_UI_PROBE)
    /* window 已显示后才做同步网络请求，避开 SpringBoard 的启动看门狗。
       UIPROBE=1 的界面自检构建跳过它，避免阻塞主线程打乱下拉/动画时序。 */
    LegacyNetProbe();
#endif
#ifdef SPECIALPROBE
    WeiboSpecialProbe();
#endif
}

/* 运行时换肤：换掉 rootViewController，让所有界面的 imageNamed: 重新按
   新皮肤取名。旧 VC 的 view 随之释放，静态指针在 loadView 里重建。 */
+ (void)rebuildRoot
{
    if (!sWindow) return;
    RootViewController *fresh = [[RootViewController alloc] init];
    [sWindow setRootViewController:fresh];
    [sWindow makeKeyAndVisible];
    [fresh release];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    (void)application;
    (void)launchOptions;
    [self setupWindow];
    return YES;
}

- (void)applicationDidFinishLaunching:(UIApplication *)application
{
    (void)application;
    [self setupWindow];
}

- (void)dealloc
{
    [sWindow release];
    sWindow = nil;
    [super dealloc];
}

@end
