#import "LegacyKit.h"

/* 无实例变量：见 AppDelegate.m 顶部说明，改用 C 静态变量持有 window */
@interface AppDelegate : NSObject
- (void)setupWindow;
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions;
- (void)applicationDidFinishLaunching:(UIApplication *)application;
@end
