#import "LegacyKit.h"
#import "AppDelegate.h"
#import "Diag.h"

/* 跳过 crt1.o 后手工补齐老 C 运行时全局，Foundation / UIKit 可能读取。 */
int NXArgc = 1;
char **NXArgv;
char **environ;
char *__progname = "LegacyApp";

static char *sAppArgv[] = { "LegacyApp", (char *)0 };
static char *sEmptyEnv[] = { (char *)0 };

int main(int argc, char *argv[])
{
    /* 入口由 dyld 直接跳入，不依赖寄存器传参，自己构造安全的 argc/argv。 */
    (void)argc;
    (void)argv;
    NXArgv = sAppArgv;
    environ = sEmptyEnv;
    diag("main: before UIApplicationMain");

    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    int result = UIApplicationMain(NXArgc, sAppArgv, nil, @"AppDelegate");
    [pool release];
    return result;
}
