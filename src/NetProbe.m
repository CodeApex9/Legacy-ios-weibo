/*
 * NetProbe.m — NSURLConnection / NSJSONSerialization 真机自检
 * （仅 make DIAG=1 时编译进二进制；正常交付版完全不含此文件代码）
 *
 * 目的：验证越狱 iOS 5/6/7 上的 app 能否自己发 HTTPS 请求、并用系统
 * NSJSONSerialization 解析微博返回的 JSON，从而判断是否必须依赖常开中继。
 *
 * 两个对照请求：
 *   1) http://192.168.8.96:8765/probe  局域网明文 —— 验证 NSURLConnection 基础链路
 *   2) https://m.weibo.cn/api/...       公网 HTTPS  —— 验证 TLS 握手 + 根证书信任
 * 第 2 步拿到数据后立刻做 JSON 解析，逐字段记录结果。
 *
 * 结果写入设备 /tmp/legacy_net.txt，用 SSH cat 读取，不依赖屏幕或日志系统。
 * 刻意手写最小 ObjC 声明、不 import LegacyKit.h，以便 mini / full 两种 SDK 模式
 * 编译行为一致；刻意绕开 stdio，用 open/write/close 立即落盘。
 *
 * 调用点：AppDelegate.m 的 setupWindow 末尾（window 已显示，避开启动看门狗）。
 * 注意：这里用同步请求仅为诊断方便，正式客户端必须改异步 delegate / 后台线程。
 */

#ifdef LEGACY_DIAG

typedef signed char BOOL;
typedef struct objc_object   *id;
typedef struct objc_selector *SEL;
typedef struct objc_class    *Class;
typedef unsigned int NSUInteger;
typedef int          NSInteger;
#define nil ((id)0)

@interface NSObject
+ (id)alloc;
- (id)init;
- (oneway void)release;
+ (Class)class;
- (BOOL)isKindOfClass:(Class)cls;
@end

@interface NSString : NSObject
+ (id)stringWithUTF8String:(const char *)s;
- (const char *)UTF8String;
@end

@interface NSNumber : NSObject
- (int)intValue;
@end

@interface NSDictionary : NSObject
- (id)objectForKey:(id)key;
@end

@interface NSArray : NSObject
- (NSUInteger)count;
- (id)objectAtIndex:(NSUInteger)index;
@end

@interface NSURL : NSObject
+ (id)URLWithString:(NSString *)s;
@end

@interface NSURLRequest : NSObject
+ (id)requestWithURL:(NSURL *)url
          cachePolicy:(NSUInteger)policy
      timeoutInterval:(double)seconds;
@end

@interface NSData : NSObject
- (NSUInteger)length;
- (const void *)bytes;
@end

@interface NSURLResponse : NSObject
- (NSInteger)statusCode;   /* NSHTTPURLResponse 的方法；消息发送只按 selector 匹配 */
@end

@interface NSURLConnection : NSObject
+ (NSData *)sendSynchronousRequest:(NSURLRequest *)request
                 returningResponse:(NSURLResponse **)response
                             error:(id *)error;
@end

@interface NSJSONSerialization : NSObject
+ (id)JSONObjectWithData:(NSData *)data
                   options:(NSUInteger)options
                     error:(id *)error;
@end

extern int open(const char *, int, ...);
extern long write(int, const void *, unsigned long);
extern int close(int);
extern unsigned long strlen(const char *);

static char sImageURL[768] = { 0 };

static void nwrite(const char *buf, unsigned long len)
{
    /* O_WRONLY(0x1) | O_CREAT(0x200) | O_APPEND(0x8) = 0x209 */
    int fd = open("/tmp/legacy_net.txt", 0x209, 0644);
    if (fd >= 0) {
        if (len) write(fd, buf, len);
        close(fd);
    }
}

/* 把真机实际收到的响应体整块落盘，便于 scp 回 Mac 分析真实字段结构。
   O_WRONLY(0x1) | O_CREAT(0x200) | O_TRUNC(0x400) = 0x601 */
static void nwrite_raw(const char *path, NSData *data)
{
    int fd = open(path, 0x601, 0644);
    if (fd >= 0) {
        if (data && [data length])
            write(fd, [data bytes], (unsigned long)[data length]);
        close(fd);
    }
}

static void ncopy_cstr(char *dst, unsigned long cap, const char *src)
{
    unsigned long i = 0;
    if (!src) { dst[0] = 0; return; }
    while (src[i] && i + 1 < cap) { dst[i] = src[i]; i++; }
    dst[i] = 0;
}

static void nlog(const char *tag)
{
    nwrite(tag, strlen(tag));
    nwrite("\n", 1);
}

static void nlog_ulong(const char *tag, unsigned long v)
{
    char b[96];
    unsigned long i = 0, k;
    char tmp[24], rev[24];
    unsigned long t = 0, r = 0;

    while (i < 60 && tag[i]) { b[i] = tag[i]; i++; }
    b[i++] = '=';

    if (v == 0) {
        tmp[t++] = '0';
    } else {
        while (v) { rev[r++] = (char)('0' + (v % 10)); v /= 10; }
        while (r) tmp[t++] = rev[--r];
    }
    for (k = 0; k < t; k++) b[i++] = tmp[k];
    b[i++] = '\n';
    nwrite(b, i);
}

static void nlog_prefix(const char *tag, const char *p, unsigned long n)
{
    char b[256];
    unsigned long i = 0, k;
    while (i < 60 && tag[i]) { b[i] = tag[i]; i++; }
    for (k = 0; k < n && i < 240; k++, i++) {
        char c = p[k];
        if (c == '\n' || c == '\r' || c == '\t') c = ' ';
        b[i] = c;
    }
    b[i++] = '\n';
    nwrite(b, i);
}

static void nlog_cstr(const char *tag, const char *s)
{
    char b[256];
    unsigned long i = 0, k = 0;
    while (i < 60 && tag[i]) { b[i] = tag[i]; i++; }
    while (s && s[k] && i < 240) {
        char c = s[k++];
        if (c == '\n' || c == '\r' || c == '\t') c = ' ';
        b[i++] = c;
    }
    b[i++] = '\n';
    nwrite(b, i);
}

static NSData *nprobe(const char *label, const char *urlCString, double timeout)
{
    NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:urlCString]];
    NSURLRequest *req = [NSURLRequest requestWithURL:url
                                         cachePolicy:0
                                     timeoutInterval:timeout];
    NSURLResponse *resp = nil;
    NSData *data;

    nlog(label);
    nlog_ulong("NET: url object", url ? 1 : 0);
    nlog_ulong("NET: request object", req ? 1 : 0);

    data = [NSURLConnection sendSynchronousRequest:req
                                  returningResponse:&resp
                                              error:(id *)0];
    nlog("NET: sendSynchronousRequest returned");
    nlog_ulong("NET: response status", resp ? (unsigned long)[resp statusCode] : 0);
    nlog_ulong("NET: data length", data ? (unsigned long)[data length] : 0);

    if (data && [data length] > 0) {
        unsigned long n = [data length];
        if (n > 120) n = 120;
        nlog_prefix("NET: body prefix=", (const char *)[data bytes], n);
    }
    return data;
}

static const char *nstr(id obj)
{
    if (obj && [obj isKindOfClass:[NSString class]])
        return [(NSString *)obj UTF8String];
    return "(null)";
}

/* 确认热门流里头像 / 配图字段的真实结构，并挑一个图片 URL 留给 case 3 实测 CDN。 */
static void probe_images(id mblog)
{
    id user, avatar, bmiddle, thumbnail, original, pics;
    id chosen = nil;

    nlog("IMG: ===== begin =====");
    if (!mblog) { nlog("IMG: no mblog -> abort"); return; }

    user      = [mblog objectForKey:@"user"];
    avatar    = user ? [user objectForKey:@"profile_image_url"] : nil;
    bmiddle   = [mblog objectForKey:@"bmiddle_pic"];
    thumbnail = [mblog objectForKey:@"thumbnail_pic"];
    original  = [mblog objectForKey:@"original_pic"];
    pics      = [mblog objectForKey:@"pics"];

    nlog_cstr("IMG: user.profile_image_url=", nstr(avatar));
    nlog_cstr("IMG: bmiddle_pic=", nstr(bmiddle));
    nlog_cstr("IMG: thumbnail_pic=", nstr(thumbnail));
    nlog_cstr("IMG: original_pic=", nstr(original));
    nlog_ulong("IMG: pics is NSArray",
               pics ? [pics isKindOfClass:[NSArray class]] : 0);
    nlog_ulong("IMG: pics is NSDictionary",
               pics ? [pics isKindOfClass:[NSDictionary class]] : 0);

    if (pics && [pics isKindOfClass:[NSArray class]]) {
        nlog_ulong("IMG: pics count", [pics count]);
        if ([pics count] > 0) {
            id p0 = [pics objectAtIndex:0];
            id u0, large, lu;
            nlog_ulong("IMG: pics[0] is NSDictionary",
                       p0 ? [p0 isKindOfClass:[NSDictionary class]] : 0);
            u0    = [p0 objectForKey:@"url"];
            large = [p0 objectForKey:@"large"];
            lu    = large ? [large objectForKey:@"url"] : nil;
            nlog_cstr("IMG: pics[0].url=", nstr(u0));
            nlog_cstr("IMG: pics[0].large.url=", nstr(lu));
            if (!chosen) chosen = lu;
            if (!chosen) chosen = u0;
        }
    }

    if (!chosen) chosen = bmiddle;
    if (!chosen) chosen = thumbnail;
    if (!chosen) chosen = avatar;
    if (chosen && [chosen isKindOfClass:[NSString class]]) {
        const char *u = [(NSString *)chosen UTF8String];
        if (u[0] == '/' && u[1] == '/') {
            ncopy_cstr(sImageURL, sizeof(sImageURL), "https:");
            {
                unsigned long k = 0;
                while (sImageURL[k]) k++;
                ncopy_cstr(sImageURL + k, sizeof(sImageURL) - k, u);
            }
        } else {
            ncopy_cstr(sImageURL, sizeof(sImageURL), u);
        }
        nlog_cstr("IMG: chosen url=", sImageURL);
    }
    nlog("IMG: ===== done =====");
}

/* NSJSONSerialization 专项验证：不只看能否加载到类，还要逐字段取出真实值。 */
static void probe_json(NSData *data)
{
    id root, okVal, dataDict, cards;
    unsigned long cnt, idx;
    id foundText = nil, foundName = nil, firstMblog = nil;

    nlog("JSON: ===== begin =====");
    nlog_ulong("JSON: input length", data ? [data length] : 0);
    if (!data) { nlog("JSON: no data -> abort"); return; }

    root = [NSJSONSerialization JSONObjectWithData:data options:0 error:(id *)0];
    nlog("JSON: JSONObjectWithData returned");
    nlog_ulong("JSON: root non-nil", root ? 1 : 0);
    if (!root) { nlog("JSON: root nil -> abort"); return; }

    nlog_ulong("JSON: root is NSDictionary",
               [root isKindOfClass:[NSDictionary class]] ? 1 : 0);
    okVal = [root objectForKey:@"ok"];
    nlog_ulong("JSON: ok value", okVal ? (unsigned long)[(NSNumber *)okVal intValue] : 0);

    dataDict = [root objectForKey:@"data"];
    nlog_ulong("JSON: data dict non-nil", dataDict ? 1 : 0);
    cards = [dataDict objectForKey:@"cards"];
    nlog_ulong("JSON: cards is NSArray",
               cards ? [cards isKindOfClass:[NSArray class]] : 0);
    cnt = cards ? [cards count] : 0;
    nlog_ulong("JSON: cards count", cnt);

    /* 前几张 card 里可能混有推荐位，找第一条真正带 mblog 的微博 */
    for (idx = 0; idx < cnt && idx < 10 && !foundText; idx++) {
        id card  = [cards objectAtIndex:idx];
        id mblog = [card objectForKey:@"mblog"];
        if (mblog) {
            id user;
            if (!firstMblog) firstMblog = mblog;
            foundText = [mblog objectForKey:@"text"];
            user = [mblog objectForKey:@"user"];
            if (user) foundName = [user objectForKey:@"screen_name"];
        }
    }

    nlog_ulong("JSON: found weibo text", foundText ? 1 : 0);
    nlog_cstr("JSON: weibo text prefix=",
              foundText ? [(NSString *)foundText UTF8String] : "(null)");
    nlog_cstr("JSON: weibo author=",
              foundName ? [(NSString *)foundName UTF8String] : "(null)");

    /* 图片字段探测：确认 profile_image_url / bmiddle_pic / pics 的真实结构 */
    probe_images(firstMblog);
    nlog("JSON: ===== done =====");
}

void LegacyNetProbe(void)
{
    NSData *weiboData;

    nlog("NET: ===== probe begin =====");
    nprobe("NET: --- case 1: LAN plain HTTP ---",
           "http://192.168.8.96:8765/probe", 6.0);
    weiboData = nprobe("NET: --- case 2: public HTTPS weibo ---",
                       "https://m.weibo.cn/api/container/getIndex?containerid=102803", 12.0);
    nwrite_raw("/tmp/weibo_raw.json", weiboData);
    probe_json(weiboData);
    if (sImageURL[0]) {
        nprobe("NET: --- case 3: image CDN ---", sImageURL, 12.0);
    } else {
        nlog("NET: case 3 skipped (no image url in payload)");
    }
    nlog("NET: ===== probe done =====");
}

#endif /* LEGACY_DIAG */
