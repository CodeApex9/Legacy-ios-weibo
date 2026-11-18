#import "LegacyKit.h"

/* 无实例变量：见 AppDelegate.m 顶部说明，改用 C 静态变量持有 window */
@interface AppDelegate : NSObject
- (void)setupWindow;
+ (void)rebuildRoot;              /* 运行时换肤：重建 rootViewController 让新皮肤立即生效 */
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions;
- (void)applicationDidFinishLaunching:(UIApplication *)application;
@end
