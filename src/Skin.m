#import "LegacyKit.h"
#import "Skin.h"

/* 皮肤状态：纯 C 静态变量 + 文件持久化，沿用 weibo_slot.txt 那套做法。 */
static int sSkin = -1;   /* -1=尚未初始化 */

extern int    open(const char *, int, ...);
extern long   read(int, void *, unsigned long);
extern int    close(int);
extern long   write(int, const void *, unsigned long);
extern unsigned long strlen(const char *);

static const char *SkinPath(void)
{
    NSString *p = [NSString stringWithFormat:@"%@/weibo_skin.txt", NSHomeDirectory()];
    return [p UTF8String];
}

int SkinCurrent(void)
{
    char buf[16];
    const char *p;
    int fd;
    long n;

    if (sSkin >= 0) return sSkin;
    sSkin = 0;   /* 默认 V0.3 皮革，保留原有样式 */
    p = SkinPath();
    if (!p) return sSkin;
    fd = open(p, 0);
    if (fd < 0) return sSkin;
    n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n > 0) {
        buf[n] = '\0';
        if (buf[0] == '1') sSkin = 1;
    }
    return sSkin;
}

void SkinSet(int skin)
{
    const char *p;
    int fd;

    sSkin = (skin == 1) ? 1 : 0;
    p = SkinPath();
    if (!p) return;
    fd = open(p, 0x601, 0644);   /* WRONLY|CREAT|TRUNC */
    if (fd >= 0) {
        write(fd, sSkin ? "1\n" : "0\n", 2);
        close(fd);
    }
}

void SkinToggle(void)
{
    SkinSet(SkinCurrent() ? 0 : 1);
}

const char *SkinName(void)
{
    return SkinCurrent() ? "提醒事项" : "皮革";
}

NSString *SkinImage(NSString *name)
{
    if (SkinCurrent() == 1 && name && [name length] > 0)
        return [NSString stringWithFormat:@"R_%@", name];
    return name;
}
