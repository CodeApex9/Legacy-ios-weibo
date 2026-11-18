/*
 * SpecialProbe.m — 「特别关注」数据源一次性探针（仅 make DIAG=1 SPECIALPROBE=1 编译）
 *
 * 第二轮：网页版（weibo.com）侧边栏有「特别关注」，但它的会话域与我们手里的
 * m.weibo.cn Cookie 不同（实测 /ajax/f/groups 返回 ok=-100 踢登录）。
 * 本轮改查 m.weibo.cn 自己：抓「关注页」(m.weibo.cn/u/page/follow) 的 HTML
 * 与全部 JS 包落盘，拉回 Mac 用 grep 找「特别关注」对应的接口/containerid 构造。
 *
 * 输出：/tmp/probe_page.html + /tmp/probe_js_<n>.js（n=0..9）
 * 日志：/tmp/legacy_special.txt
 */

#include "LegacyKit.h"
#include "WeiboStore.h"
#include "Diag.h"

extern int open(const char *, int, ...);
extern long write(int, const void *, unsigned long);
extern int close(int);
extern unsigned long strlen(const char *);

static void slog(const char *tag)
{
    int fd = open("/tmp/legacy_special.txt", 0x209, 0644);
    if (fd >= 0) {
        write(fd, tag, strlen(tag));
        write(fd, "\n", 1);
        close(fd);
    }
}

#define kProbeUA @"Mozilla/5.0 (iPhone; CPU iPhone OS 10_3 like Mac OS X) " \
                 @"AppleWebKit/603.1.30 (KHTML, like Gecko) Version/10.0 " \
                 @"Mobile/14E277 Safari/602.1"

/* 页面请求：带 Cookie，不带 XHR 头（要的是 HTML 和 JS） */
static NSData *fetch_page(NSString *urlString, NSString *cookie, int *status)
{
    NSURL *url = [NSURL URLWithString:urlString];
    NSMutableURLRequest *req;
    NSHTTPURLResponse *resp = nil;
    NSData *data;

    *status = -1;
    if (!url) return nil;
    req = [NSMutableURLRequest requestWithURL:url cachePolicy:0 timeoutInterval:25.0];
    if (cookie) [req setValue:cookie forHTTPHeaderField:@"Cookie"];
    [req setValue:kProbeUA forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"https://m.weibo.cn/" forHTTPHeaderField:@"Referer"];

    data = [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:(id *)0];
    if (resp) *status = (int)[resp statusCode];
    return data;
}

/* 从 HTML 里抓 src="...js" 的地址（相对 // 与绝对都兜） */
static void fetch_scripts(NSString *html, NSString *cookie)
{
    NSRange pos = {0, 0};
    int idx = 0;
    NSUInteger len = [html length];

    while (idx < 10) {
        NSRange src = [html rangeOfString:@"src=\""
                                  options:0
                                    range:NSMakeRange(pos.location, len - pos.location)];
        if (src.location == NSNotFound || src.location >= len) break;

        NSUInteger s = src.location + src.length;
        NSRange tail = {s, len - s};
        NSRange end = [html rangeOfString:@"\""
                                  options:0
                                    range:tail];
        if (end.location == NSNotFound) break;

        NSString *raw = [html substringWithRange:NSMakeRange(s, end.location - s)];
        pos.location = end.location + end.length;

        /* 不过滤扩展名，落盘后在 Mac 上筛——mini SDK 上字符串判断出错不吃亏 */
        if ([raw length] < 8 || [raw length] > 300) continue;
        if ([raw hasSuffix:@".png"] || [raw hasSuffix:@".gif"] ||
            [raw hasSuffix:@".ico"] || [raw hasSuffix:@".css"]) continue;

        NSString *url = raw;
        if ([raw hasPrefix:@"//"])  url = [NSString stringWithFormat:@"https:%@", raw];
        else if ([raw hasPrefix:@"/"]) url = [NSString stringWithFormat:@"https://m.weibo.cn%@", raw];

        int st = -1;
        NSData *js = fetch_page(url, cookie, &st);
        NSString *path = [NSString stringWithFormat:@"/tmp/probe_js_%d.js", idx];
        BOOL ok = js ? [js writeToFile:path atomically:YES] : NO;
        slog([[NSString stringWithFormat:@"JS %d: http=%d bytes=%d saved=%@ %@",
               idx, st, js ? (int)[js length] : 0, ok ? @"Y" : @"N", url] UTF8String]);
        idx++;
    }
    slog([[NSString stringWithFormat:@"SCRIPTS: total=%d", idx] UTF8String]);
}

void WeiboSpecialProbe(void)
{
    NSString *cookie = WeiboStoreCookie();
    NSData *cfgData;
    int st = -1;

    slog("=== special probe round3 begin ===");
    slog(cookie ? "cookie: present" : "cookie: nil");

    /* 1) 频道配置：data.groups[] 即服务端分组（含特别关注），条目含 gid */
    cfgData = fetch_page(@"https://m.weibo.cn/api/config/list", cookie, &st);
    if (cfgData) [cfgData writeToFile:@"/tmp/probe_cfg.json" atomically:YES];
    slog([[NSString stringWithFormat:@"CONFIG: http=%d bytes=%d",
           st, cfgData ? (int)[cfgData length] : 0] UTF8String]);
    if (!cfgData) { slog("=== done (no config) ==="); return; }

    {
        id root = [NSJSONSerialization JSONObjectWithData:cfgData options:0 error:(id *)0];
        id groups = root ? [[root objectForKey:@"data"] objectForKey:@"groups"] : nil;
        NSString *specialGid = nil;
        NSUInteger i, n = groups ? [groups count] : 0;

        slog([[NSString stringWithFormat:@"GROUPS: count=%d", (int)n] UTF8String]);
        for (i = 0; i < n; i++) {
            id g = [groups objectAtIndex:i];
            NSString *name = [g objectForKey:@"name"];
            id gidObj = [g objectForKey:@"gid"];
            NSString *gid = [gidObj isKindOfClass:[NSString class]]
                          ? (NSString *)gidObj
                          : ([gidObj respondsToSelector:@selector(stringValue)]
                             ? [(NSNumber *)gidObj stringValue] : @"");
            slog([[NSString stringWithFormat:@"  group[%d]: %@ gid=%@", (int)i, name ?: @"(nil)", gid] UTF8String]);
            if (name && [name isEqualToString:@"特别关注"]) specialGid = gid;
        }

        /* 2) 特别关注时间线：feed/group?gid=...，分页 max_id（与 feed/friends 同款） */
        if (specialGid) {
            NSString *url = [NSString stringWithFormat:
                @"https://m.weibo.cn/feed/group?gid=%@", specialGid];
            NSData *feed = fetch_page(url, cookie, &st);
            if (feed) [feed writeToFile:@"/tmp/probe_grp.json" atomically:YES];
            slog([[NSString stringWithFormat:@"FEED: gid=%@ http=%d bytes=%d",
                   specialGid, st, feed ? (int)[feed length] : 0] UTF8String]);
        } else {
            slog("FEED: no special group found");
        }
    }

    slog("=== special probe round3 done ===");
}
