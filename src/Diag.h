#ifndef LEGACY_DIAG_H
#define LEGACY_DIAG_H

/*
 * 启动自检（仅 make DIAG=1 时编译）。
 * 通过 SSH 读设备上的 /tmp/legacy_boot.txt，即可确认 main 与
 * AppDelegate / loadView 是否真的执行，不依赖屏幕或日志系统。
 *
 * 刻意绕开 stdio：用 open/write/close 直接写，避免 FILE* 缓冲与
 * 主线程挂起时的 stdio 锁导致标记丢失（会造成"卡住"的假象）。
 */

#ifdef LEGACY_DIAG
extern int open(const char *, int, ...);
extern long write(int, const void *, unsigned long);
extern int close(int);
extern unsigned long strlen(const char *);
static void diag(const char *tag)
{
    /* O_WRONLY(0x1) | O_CREAT(0x200) | O_APPEND(0x8) = 0x209 */
    int fd = open("/tmp/legacy_boot.txt", 0x209, 0644);
    if (fd >= 0) {
        unsigned long n = strlen(tag);
        write(fd, tag, n);
        write(fd, "\n", 1);
        close(fd);
    }
}
#else
#define diag(tag) ((void)0)
#endif

#endif /* LEGACY_DIAG_H */
