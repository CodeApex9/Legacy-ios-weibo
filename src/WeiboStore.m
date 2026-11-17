#import "WeiboStore.h"
#import "ImageLoader.h"
#import "Diag.h"

/*
 * 无 ObjC 实例变量：本二进制跳过 crt1.o 手工链接，自定义类一律只用
 * 文件级 C 静态变量保存状态。每条微博用一个 NSMutableDictionary 承载：
 *   text / meta / full / author / time / kind
 *   avatar  用户头像 URL
 *   thumb   列表缩略图 URL（视频封面或多图首图）
 *   large   详情大图 URL
 *
 * 真机抓到的 m.weibo.cn 热门流（2026-11）实际结构：
 *   mblog.user.profile_image_url          头像，tvax*.sinaimg.cn
 *   mblog.page_info.page_pic.url          视频封面，wx*.sinaimg.cn/orj480
 *   mblog.pics[] / bmiddle_pic            图文微博，按容器不同出现
 * 三种都做容错，取不到就留空，UI 自动省略图片区。
 */

static NSMutableArray   *sPosts = nil;
static NSMutableData    *sBuffer = nil;
static NSURLConnection *sConnection = nil;
static id                sConnectionDelegate = nil;
static int               sState = 0;
static NSString         *sErrorText = nil;
static void            (*sUpdateCallback)(void) = 0;

/* 分页：热门用 since_id 递增；关注用 max_id 游标；我的用 page 递增。
   sCursor 保存这些值（首次加载为空/1），sHasMore 由上一页返回决定。 */
static int               sPage = 1;
static NSString         *sCursor = nil;      /* 关注=max_id 字符串 */
static int               sSinceID = 1;        /* 热门=cardlistInfo.since_id */
static int               sHasMore = 1;
static int               sLoadingMore = 0;

/* 登录态：全部由 bundle 内 Login.txt 提供，源码里不含任何账号凭据 */
static NSString *sUID = nil;
static NSString *sFeedID = nil;
static NSString *sUserName = nil;
static NSString *sCookie = nil;
static int       sFeed = 0;          /* 0=热门 1=登录后的时间线 */

/* 当前账号资料：登录后异步拉取 containerid=100505{uid} 的 userInfo */
static NSMutableDictionary *sProfile = nil;
static NSMutableData    *sProfileBuffer = nil;
static NSURLConnection  *sProfileConnection = nil;
static id                sProfileDelegate = nil;
static void            (*sProfileCallback)(void) = 0;

/* 与扫码脚本补移动端 Cookie 时使用的 UA 保持一致，降低 UA/Cookie 绑定风控 */
#define kMobileUA "Mozilla/5.0 (iPhone; CPU iPhone OS 10_3 like Mac OS X) AppleWebKit/603.1.30 (KHTML, like Gecko) Version/10.0 Mobile/14E277 Safari/602.1"

extern unsigned long strlen(const char *);
extern void *malloc(unsigned long);
extern void  free(void *);
extern int   open(const char *, int, ...);
extern long  read(int, void *, unsigned long);
extern int   close(int);
extern long  write(int, const void *, unsigned long);
extern char *strncpy(char *dst, const char *src, unsigned long n);

static int StartsWith(const char *s, const char *prefix)
{
    int i = 0;
    if (!s) return 0;
    while (prefix[i]) {
        if (s[i] != prefix[i]) return 0;
        i++;
    }
    return 1;
}

static int KeyIs(const char *key, unsigned long klen, const char *literal)
{
    unsigned long i = 0;
    while (literal[i]) {
        if (i >= klen || key[i] != literal[i]) return 0;
        i++;
    }
    return i == klen;
}

/* 把 Login.txt 的一行 "k=v" 存进对应静态变量；值要 retain，
   因为 stringWithUTF8String 返回 autorelease 对象，autorelease pool 时机不定。 */
static void AssignLoginField(const char *key, unsigned long klen,
                             const char *val, unsigned long vlen)
{
    char tmp[4096];
    unsigned long i;
    NSString *s;
    if (vlen > sizeof(tmp) - 1) vlen = sizeof(tmp) - 1;
    for (i = 0; i < vlen; i++) tmp[i] = val[i];
    tmp[vlen] = '\0';
    if (vlen && tmp[vlen - 1] == '\r') tmp[vlen - 1] = '\0';
    s = [NSString stringWithUTF8String:tmp];
    if (!s) return;
    if      (KeyIs(key, klen, "uid"))    { if (sUID) [sUID release];         sUID = [s retain]; }
    else if (KeyIs(key, klen, "feed"))  { if (sFeedID) [sFeedID release];   sFeedID = [s retain]; }
    else if (KeyIs(key, klen, "name"))  { if (sUserName) [sUserName release]; sUserName = [s retain]; }
    else if (KeyIs(key, klen, "cookie")){ if (sCookie) [sCookie release];    sCookie = [s retain]; }
}

/* 读取一份登录凭据文件：bundle 里的 Login.txt（Mac 脚本预置）和
   <HOME>/weibo_login.txt（app 内扫码生成）。后者在后者覆盖前者。 */
static void LoadLoginFile(NSString *path)
{
    const char *cpath, *p, *line, *eq, *e;
    static char buf[8192];
    int fd;
    long n;

    if (!path) return;
    cpath = [path UTF8String];
    if (!cpath) return;
    fd = open(cpath, 0);            /* O_RDONLY = 0 */
    if (fd < 0) return;
    n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return;
    buf[n] = '\0';

    p = buf;
    while (*p) {
        line = p;
        while (*p && *p != '\n') p++;
        e = p;
        if (*p == '\n') p++;
        eq = line;
        while (eq < e && *eq != '=') eq++;
        if (eq < e)
            AssignLoginField(line, (unsigned long)(eq - line),
                             eq + 1, (unsigned long)(e - eq - 1));
    }
}

/* 退出标记文件：用户点"退出登录"后写入内容 "1"，屏蔽 bundle 内只读的
   预置 Login.txt（那文件删不掉），保证 App 重启后仍是未登录；重新扫码
   登录时写入 "0"。用纯 C open/read/write，不依赖 NSFileManager；
   libSystem.tbd 未登记 unlink，故不删文件、改用内容 0/1 表达状态。 */
static const char *LogoutMarkerPath(void)
{
    static char path[1024];
    const char *home = [NSHomeDirectory() UTF8String];
    const char *suffix = "/weibo_logout.flag";
    unsigned long n, i;
    if (!home) return 0;
    n = strlen(home);
    if (n > sizeof(path) - 1) n = sizeof(path) - 1;
    for (i = 0; i < n; i++) path[i] = home[i];
    for (i = 0; suffix[i] && n + i < sizeof(path) - 1; i++) path[n + i] = suffix[i];
    path[n + i] = '\0';
    return path;
}

static int LogoutMarked(void)
{
    const char *p = LogoutMarkerPath();
    char c = 0;
    int fd;
    if (!p) return 0;
    fd = open(p, 0);           /* O_RDONLY */
    if (fd < 0) return 0;
    if (read(fd, &c, 1) > 0 && c == '1') { close(fd); return 1; }
    close(fd);
    return 0;
}

static void SetLogoutMarked(int on)
{
    const char *p = LogoutMarkerPath();
    int fd;
    if (!p) return;
    fd = open(p, 0x601, 0644);   /* WRONLY|CREAT|TRUNC */
    if (fd >= 0) { write(fd, on ? "1" : "0", 1); close(fd); }
}

void WeiboStoreInitLogin(void)
{
    /* 用户主动退出后，忽略 bundle 预置与本地扫码凭据，保持未登录 */
    if (LogoutMarked()) {
        diag("WeiboStore: logged out marker present, skip credentials");
        return;
    }
    /* 先读 bundle 预置，再读本地扫码结果（本地优先） */
    LoadLoginFile([[NSBundle mainBundle] pathForResource:@"Login" ofType:@"txt"]);
    LoadLoginFile([NSString stringWithFormat:@"%@/weibo_login.txt", NSHomeDirectory()]);
    diag(sCookie ? "WeiboStore: login credential loaded" : "WeiboStore: no login credential");
}

void WeiboStoreReloadLogin(void)
{
    if (sUID)      { [sUID release];      sUID = nil; }
    if (sFeedID)   { [sFeedID release];   sFeedID = nil; }
    if (sUserName) { [sUserName release]; sUserName = nil; }
    if (sCookie)   { [sCookie release];   sCookie = nil; }
    if (sProfile)  { [sProfile release];  sProfile = nil; }
    SetLogoutMarked(0);   /* 重新扫码登录：清除退出标记 */
    WeiboStoreInitLogin();
}

/* 退出登录：清除内存凭据、删除本地扫码文件、写退出标记屏蔽 bundle 凭据，
   并清空三个 tab 的帖子缓存与分页状态。关注/我的数据随之消失。 */
void WeiboStoreLogout(void)
{
    const char *lp;
    if (sUID)      { [sUID release];      sUID = nil; }
    if (sFeedID)   { [sFeedID release];   sFeedID = nil; }
    if (sUserName) { [sUserName release]; sUserName = nil; }
    if (sCookie)   { [sCookie release];   sCookie = nil; }
    if (sProfile)  { [sProfile release];  sProfile = nil; }
    if (sProfileConnection) { [sProfileConnection cancel]; [sProfileConnection release]; sProfileConnection = nil; }
    if (sProfileBuffer)     { [sProfileBuffer release];     sProfileBuffer = nil; }

    /* 清本地扫码凭据：截断为 0 字节（LoadLoginFile 读到空即视为无凭据） */
    lp = [[NSString stringWithFormat:@"%@/weibo_login.txt", NSHomeDirectory()] UTF8String];
    if (lp) {
        int lfd = open(lp, 0x601, 0644);   /* WRONLY|CREAT|TRUNC */
        if (lfd >= 0) close(lfd);
    }
    SetLogoutMarked(1);

    /* 清帖子缓存与分页/连接状态（关注、我的内容一并清空） */
    if (sConnection) { [sConnection cancel]; [sConnection release]; sConnection = nil; }
    if (sBuffer)     { [sBuffer release];  sBuffer = nil; }
    if (sPosts)      { [sPosts release];   sPosts = nil; }
    if (sCursor)     { [sCursor release];  sCursor = nil; }
    if (sErrorText)  { [sErrorText release]; sErrorText = nil; }
    sFeed = 0;
    sState = 0;
    sPage = 1;
    sSinceID = 1;
    sHasMore = 1;
    sLoadingMore = 0;
    diag("WeiboStore: logged out, caches cleared");
}

/* ---------- 当前账号资料（用于左上角头像与账号详情面板） ---------- */
static NSString *AsString(id obj);
static id AsDict(id obj);
static id AsNumber(id obj);

/* 资料接口里 followers_count 有时返回字符串「468」，有时是 NSNumber，
   统一转成 NSNumber，避免粉丝数丢失。 */
static NSNumber *ProfileNumber(id obj)
{
    NSNumber *n = AsNumber(obj);
    if (n) return n;
    {
        NSString *s = AsString(obj);
        if (s && [s length] > 0)
            return [NSNumber numberWithInt:[s intValue]];
    }
    return nil;
}

@interface WeiboProfileDelegate : NSObject @end

@implementation WeiboProfileDelegate
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{ (void)connection; (void)response; }
- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{ (void)connection; if (sProfileBuffer && data) [sProfileBuffer appendData:data]; }
- (void)parseProfile
{
    id root = sProfileBuffer ? [NSJSONSerialization JSONObjectWithData:sProfileBuffer
                                                               options:0 error:(id *)0] : nil;
    id data = AsDict([root objectForKey:@"data"]);
    id ui   = AsDict([data objectForKey:@"userInfo"]);
    if (ui && [ui count] > 0) {
        NSMutableDictionary *p = [[NSMutableDictionary alloc] init];
        NSString *v;
        NSNumber *n;
        if ((v = AsString([ui objectForKey:@"screen_name"])))    [p setObject:v forKey:@"name"];
        if ((v = AsString([ui objectForKey:@"gender"])))          [p setObject:v forKey:@"gender"];
        if ((v = AsString([ui objectForKey:@"description"])))     [p setObject:v forKey:@"desc"];
        if ((v = AsString([ui objectForKey:@"avatar_hd"])))       [p setObject:v forKey:@"avatar"];
        else if ((v = AsString([ui objectForKey:@"profile_image_url"]))) [p setObject:v forKey:@"avatar"];
        if ((n = ProfileNumber([ui objectForKey:@"followers_count"]))) [p setObject:n forKey:@"followers"];
        if ((n = ProfileNumber([ui objectForKey:@"follow_count"])))    [p setObject:n forKey:@"follow"];
        if ((n = ProfileNumber([ui objectForKey:@"statuses_count"])))  [p setObject:n forKey:@"statuses"];
        if (sProfile) [sProfile release];
        sProfile = p;   /* 转移所有权 */
        diag("WeiboStore: profile parsed");
    }
}
- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    (void)connection;
    [self parseProfile];
    if (sProfileConnection) { [sProfileConnection release]; sProfileConnection = nil; }
    if (sProfileBuffer)     { [sProfileBuffer release];     sProfileBuffer = nil; }
    if (sProfileCallback) sProfileCallback();
}
- (void)connection:(NSURLConnection *)connection didFailWithError:(id)error
{
    (void)connection; (void)error;
    diag("WeiboStore: profile request failed");
    if (sProfileConnection) { [sProfileConnection release]; sProfileConnection = nil; }
    if (sProfileBuffer)     { [sProfileBuffer release];     sProfileBuffer = nil; }
}
@end

void WeiboStoreSetProfileCallback(void (*callback)(void)) { sProfileCallback = callback; }
NSDictionary *WeiboStoreProfile(void) { return sProfile; }

void WeiboStoreFetchProfile(void)
{
    NSURL *url;
    NSMutableURLRequest *req;
    if (!WeiboStoreLoggedIn() || !sUID || [sUID length] == 0) return;
    if (sProfileConnection) return;   /* 正在拉取，避免重复 */
    url = [NSURL URLWithString:
           [NSString stringWithFormat:
            @"https://m.weibo.cn/api/container/getIndex?containerid=100505%@", sUID]];
    sProfileBuffer = [[NSMutableData alloc] init];
    if (!sProfileDelegate) sProfileDelegate = [[WeiboProfileDelegate alloc] init];
    req = [NSMutableURLRequest requestWithURL:url cachePolicy:0 timeoutInterval:15.0];
    [req setValue:sCookie forHTTPHeaderField:@"Cookie"];
    [req setValue:@"https://m.weibo.cn/" forHTTPHeaderField:@"Referer"];
    [req setValue:@"XMLHttpRequest" forHTTPHeaderField:@"X-Requested-With"];
    [req setValue:@"1" forHTTPHeaderField:@"MWeibo-Pwa"];
    [req setValue:[NSString stringWithUTF8String:kMobileUA] forHTTPHeaderField:@"User-Agent"];
    sProfileConnection = [[NSURLConnection alloc] initWithRequest:req
                                                        delegate:sProfileDelegate
                                                startImmediately:YES];
    if (!sProfileConnection) { [sProfileBuffer release]; sProfileBuffer = nil; }
}

/* 三个流：0=热门（游客可用） 1=关注 2=我的
   关注流走独立接口 /feed/friends，返回 data.statuses[]（不是 cards）。
   翻页参数真机/接口实测：
     热门 102803     -> ?since_id=N（N 取上一页 cardlistInfo.since_id，递增）
     关注 feed/friends-> ?max_id=<上一页 data.max_id>
     我的 107603{uid}-> ?page=N（N 从 1 递增）
   sPage==1 时不带翻页参数，取第一页。 */
static NSString *FeedURLString(void)
{
    if (sFeed == 1) {
        /* 只要有游标就带 max_id。原先依赖 sPage>1，但关注流的 sPage 不递增，
           导致永远拉到同一页首页（全是重复）。首屏 sCursor 为空，自然走首页。 */
        if (sCursor && [sCursor length] > 0)
            return [NSString stringWithFormat:
                    @"https://m.weibo.cn/feed/friends?max_id=%@", sCursor];
        return @"https://m.weibo.cn/feed/friends";
    }
    if (sFeed == 2 && sFeedID && [sFeedID length] > 0) {
        const char *cid = [sFeedID UTF8String];
        if (cid && StartsWith(cid, "107603") && sUID && [sUID length] > 0) {
            return [NSString stringWithFormat:
                    @"https://m.weibo.cn/api/container/getIndex?type=uid&value=%@&containerid=%@&page=%d",
                    sUID, sFeedID, sPage];
        }
        return [NSString stringWithFormat:
                @"https://m.weibo.cn/api/container/getIndex?containerid=%@&page=%d",
                sFeedID, sPage];
    }
    /* 热门：since_id 递增 */
    return [NSString stringWithFormat:
            @"https://m.weibo.cn/api/container/getIndex?containerid=102803&since_id=%d",
            sSinceID];
}

/* JSON 里大量字段是 NSNull，直接发 objectForKey:/intValue 会 unrecognized selector。
   统一先按真实类过滤，nil 上发消息在 ObjC 里安全返回 0。 */
static NSString *AsString(id obj)
{
    if (obj && [obj isKindOfClass:[NSString class]]) return (NSString *)obj;
    return nil;
}

static id AsDict(id obj)
{
    if (obj && [obj isKindOfClass:[NSDictionary class]]) return obj;
    return nil;
}

static id AsArray(id obj)
{
    if (obj && [obj isKindOfClass:[NSArray class]]) return obj;
    return nil;
}

static id AsNumber(id obj)
{
    if (obj && [obj isKindOfClass:[NSNumber class]]) return obj;
    return nil;
}

static NSString *NormalizeURL(NSString *url)
{
    const char *p;
    if (!url) return nil;
    p = [url UTF8String];
    if (!p) return nil;
    if (p[0] == '/' && p[1] == '/')
        return [NSString stringWithFormat:@"https:%@", url];
    return url;
}

/* 微博 text 是 HTML 片段：去标签、<br> 转行、<img alt> 保留表情文字、还原实体。
   用 C 逐字节扫描，避免为 NSString 补一堆替换方法的声明与符号。 */
static NSString *CleanHTMLString(NSString *src)
{
    const char *p;
    char *out;
    unsigned long n, i = 0, j = 0;
    NSString *result;

    if (!src) return @"";
    p = [src UTF8String];
    if (!p) return @"";
    n = strlen(p);
    out = (char *)malloc(n + 2);
    if (!out) return src;
    result = nil;

    while (i < n) {
        if (p[i] == '<') {
            int isBr = 0, isImg = 0;
            unsigned long k = i + 1, tagStart = i, a, q;
            if (k + 1 < n && (p[k] == 'b' || p[k] == 'B') &&
                (p[k + 1] == 'r' || p[k + 1] == 'R')) {
                isBr = 1;
            }
            if (k + 2 < n && (p[k] == 'i' || p[k] == 'I') &&
                (p[k + 1] == 'm' || p[k + 1] == 'M') &&
                (p[k + 2] == 'g' || p[k + 2] == 'G')) {
                isImg = 1;
            }
            while (i < n && p[i] != '>') i++;
            if (i < n) i++;

            /* <img alt="[doge]" ...> 的表情文字要留在正文里，否则整段表情消失 */
            if (isImg) {
                a = tagStart;
                while (a + 4 < i &&
                       !(p[a] == 'a' && p[a+1] == 'l' && p[a+2] == 't' && p[a+3] == '=')) a++;
                if (a + 4 < i) {
                    q = a + 4;
                    while (q < i && p[q] != '\'' && p[q] != '"') q++;
                    if (q < i) {
                        char quote = p[q];
                        unsigned long e = q + 1;
                        while (e < i && p[e] != quote) out[j++] = p[e++];
                    }
                }
            }
            if (isBr && j > 0 && out[j - 1] != '\n') out[j++] = '\n';
            continue;
        }
        if (p[i] == '&') {
            if (i + 6 <= n && p[i+1]=='n' && p[i+2]=='b' && p[i+3]=='s' &&
                p[i+4]=='p' && p[i+5]==';') {
                out[j++] = ' '; i += 6; continue;
            }
            if (i + 5 <= n && p[i+1]=='a' && p[i+2]=='m' && p[i+3]=='p' && p[i+4]==';') {
                out[j++] = '&'; i += 5; continue;
            }
            if (i + 4 <= n && p[i+1]=='l' && p[i+2]=='t' && p[i+3]==';') {
                out[j++] = '<'; i += 4; continue;
            }
            if (i + 4 <= n && p[i+1]=='g' && p[i+2]=='t' && p[i+3]==';') {
                out[j++] = '>'; i += 4; continue;
            }
            if (i + 6 <= n && p[i+1]=='q' && p[i+2]=='u' && p[i+3]=='o' &&
                p[i+4]=='t' && p[i+5]==';') {
                out[j++] = '"'; i += 6; continue;
            }
        }
        out[j++] = p[i++];
    }
    out[j] = '\0';
    result = [NSString stringWithUTF8String:out];
    free(out);
    return result ? result : src;
}

/* 评论正文和微博正文用的是同一套 HTML（emoji 也是 <img alt="[笑]">），
   直接复用上面的清理逻辑，避免两处规则不一致。 */
NSString *WeiboStoreCleanHTML(NSString *src)
{
    return CleanHTMLString(src);
}

/* 评论模块复用当前登录 Cookie；未登录返回 nil，请求头不带 Cookie 即可。 */
NSString *WeiboStoreCookie(void)
{
    return sCookie;
}

/* 从 pics 容器里取第一张图：数组时取 [0]，字典时取 allValues[0]。
   每条元素可能是字符串 URL，也可能是 {url, large:{url}}。 */
static NSString *FirstPicURL(id pics, NSString **largeOut)
{
    id item = nil, u, lg, dict;
    NSArray *arr = AsArray(pics);
    NSString *small = nil;

    if (arr && [arr count] > 0) {
        item = [arr objectAtIndex:0];
    } else if ((dict = AsDict(pics)) != nil) {
        NSArray *vals = AsArray([dict allValues]);
        if (vals && [vals count] > 0) item = [vals objectAtIndex:0];
    }
    if (!item) return nil;

    small = AsString(item);
    if (!small && (dict = AsDict(item)) != nil) {
        small = AsString([dict objectForKey:@"url"]);
        lg = AsDict([dict objectForKey:@"large"]);
        u = lg ? AsString([lg objectForKey:@"url"]) : nil;
        if (u && largeOut) *largeOut = u;
    }
    return small;
}

static NSString *PickPhoto(id mblog, NSString **largeOut);

/* 取一条微博的全部配图 URL：优先 pics 数组，其次单图字段，最后视频封面。
   写进 post 的 "photos"（NSMutableArray of NSString）与 "photoLarges"（大图），
   列表据此排九宫格，图片查看器据此左右切换。最多取 9 张。 */
static void CollectPhotos(id mblog, NSMutableArray *thumbs, NSMutableArray *larges,
                          NSString **oneThumb, NSString **oneLarge)
{
    id pics, arrId, dict, item, u, lg;
    NSArray *arr;
    NSUInteger i, n;

    if (!thumbs || !larges) return;
    pics = [mblog objectForKey:@"pics"];
    arr = AsArray(pics);
    if (!arr && (dict = AsDict(pics)) != nil) arr = AsArray([dict allValues]);

    if (arr && [arr count] > 0) {
        n = [arr count] > 9 ? 9 : [arr count];
        for (i = 0; i < n; i++) {
            item = [arr objectAtIndex:i];
            NSString *small = AsString(item);
            NSString *big = nil;
            if (!small && (dict = AsDict(item)) != nil) {
                small = AsString([dict objectForKey:@"url"]);
                if (!small) small = AsString([dict objectForKey:@"thumbnail_pic"]);
                lg = AsDict([dict objectForKey:@"large"]);
                if (lg) big = AsString([lg objectForKey:@"url"]);
                if (!big) big = AsString([dict objectForKey:@"original_pic"]);
            }
            small = NormalizeURL(small);
            big = NormalizeURL(big);
            if (!small) small = big;
            if (!small) continue;
            [thumbs addObject:small];
            [larges addObject:(big ? big : small)];
        }
    }

    /* 没有 pics（视频/单图）：退回 bmiddle_pic / page_pic */
    if ([thumbs count] == 0) {
        NSString *t = PickPhoto(mblog, oneLarge);
        if (t) {
            [thumbs addObject:t];
            [larges addObject:(*oneLarge ? *oneLarge : t)];
        }
    }
    if ([thumbs count] > 0 && oneThumb) *oneThumb = [thumbs objectAtIndex:0];
    /* 详情页大图：pics 多图时也要给 large 赋值（原来只有单图 PickPhoto 路径才写，
       导致多图/转发微博列表有图、详情页却不显示）。取第一张大图。 */
    if ([larges count] > 0 && oneLarge && !*oneLarge)
        *oneLarge = [larges objectAtIndex:0];
}

/* 按热门流真实结构挑一张配图，返回列表用 URL，详情大图写 largeOut */
static NSString *PickPhoto(id mblog, NSString **largeOut)
{
    id pics, pageInfo, pagePic;
    NSString *url = nil;

    /* 1) 图文微博：pics 数组/字典 */
    pics = [mblog objectForKey:@"pics"];
    url = FirstPicURL(pics, largeOut);
    if (url) return NormalizeURL(url);

    /* 2) 单图微博的老字段 */
    url = AsString([mblog objectForKey:@"bmiddle_pic"]);
    if (!url) url = AsString([mblog objectForKey:@"thumbnail_pic"]);
    if (url) {
        NSString *orig = AsString([mblog objectForKey:@"original_pic"]);
        if (largeOut) *largeOut = orig ? orig : url;
        return NormalizeURL(url);
    }

    /* 3) 视频/文章：page_info.page_pic.url（当前热门流绝大多数走这里） */
    pageInfo = AsDict([mblog objectForKey:@"page_info"]);
    if (pageInfo) {
        pagePic = [pageInfo objectForKey:@"page_pic"];
        url = AsString(pagePic);
        if (!url) url = AsString([AsDict(pagePic) objectForKey:@"url"]);
        if (url) {
            if (largeOut) *largeOut = url;
            return NormalizeURL(url);
        }
    }
    return nil;
}

/* 转发微博：外层 text 常是「转发微博」占位，真正内容在 retweeted_status。
   组合成「转发评论\n@原作者: 原文」；外层无图时用原微博的图。
   retweet 传回原作者名（写进 originName），供正文前缀使用。 */
static NSString *BuildRetweetText(id mblog, id retweet, NSString **originName)
{
    NSString *outer, *inner, *oname, *result;
    id ouser;

    if (!retweet) return nil;
    ouser = AsDict([retweet objectForKey:@"user"]);
    oname = AsString([ouser objectForKey:@"screen_name"]);
    if (originName) *originName = oname;

    outer = CleanHTMLString(AsString([mblog objectForKey:@"text"]));
    /* 「转发微博」是无评论转发的占位，不显示；//@xxx:转发微博 这类也弱化 */
    if (!outer || [outer length] == 0 ||
        [outer isEqualToString:@"转发微博"] ||
        [outer isEqualToString:@"None"])
        outer = nil;

    inner = CleanHTMLString(AsString([retweet objectForKey:@"text"]));
    if (!inner || [inner length] == 0) inner = @"";

    if (outer && [outer length] > 0) {
        NSString *prefix = oname ? [NSString stringWithFormat:@"@%@: ", oname] : @"";
        result = [NSString stringWithFormat:@"%@\n%@%@", outer, prefix, inner];
    } else {
        NSString *prefix = oname ? [NSString stringWithFormat:@"@%@: ", oname] : @"";
        result = [NSString stringWithFormat:@"%@%@", prefix, inner];
    }
    return result;
}

static void ParseBuffer(void)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSMutableArray *list = [[NSMutableArray alloc] init];
    id root = nil, cards = nil, okVal = nil;
    int apiOK = 0;
    NSUInteger i, cnt;

    diag("WeiboStore: parse begin");
    if (sBuffer) {
        root = [NSJSONSerialization JSONObjectWithData:sBuffer
                                               options:0
                                                 error:(id *)0];
    }
    if (root) {
        okVal = [root objectForKey:@"ok"];
        apiOK = okVal ? [AsNumber(okVal) intValue] : 0;
        cards = [AsDict([root objectForKey:@"data"]) objectForKey:@"cards"];
    }
    /* 登录态过期/风控时接口返回 ok:-100 / -101，body 里没有 cards。
       给可操作的提示，别让用户误以为是网络坏了。 */
    if (apiOK != 1) {
        diag("WeiboStore: api non-ok, treat as login/network failure");
        if (sPosts) { [sPosts release]; sPosts = nil; }
        [list release];
        sErrorText = (apiOK == -100 || apiOK == -101)
                     ? @"登录已过期，点左上角「登录」重新扫码"
                     : @"接口返回异常，请下拉重试";
        [pool drain];
        return;
    }
    cards = AsArray(cards);
    if (!cards) cards = AsArray([AsDict([root objectForKey:@"data"]) objectForKey:@"statuses"]);
    cnt = cards ? [cards count] : 0;

    for (i = 0; i < cnt; i++) {
        id card  = AsDict([cards objectAtIndex:i]);
        /* 热门/我的：data.cards[].mblog；关注流：data.statuses[] 本身就是微博。
           没有 mblog 包裹时，只有「自身就是一条微博」(有 user 和 text)才算，
           跳过 card_type=11 这类功能入口卡（微博回忆/管理定时发博），
           否则会被当成无作者的空微博显示成「匿名」。 */
        id mblog = AsDict([card objectForKey:@"mblog"]);
        if (!mblog) {
            if (!AsDict([card objectForKey:@"user"]) || ![card objectForKey:@"text"])
                continue;
            mblog = card;
        }
        id user, name, created, rep, com, att, pageInfo, retweet;
        NSString *clean, *meta, *kind, *avatar, *thumb = nil, *large = nil;
        NSString *originName = nil, *retweetText;
        NSMutableArray *photos, *photoLarges;
        NSMutableDictionary *post;

        if (!mblog) continue;   /* 推荐位/广告卡没有 mblog */
        user    = AsDict([mblog objectForKey:@"user"]);
        name    = AsString([user objectForKey:@"screen_name"]);
        created = AsString([mblog objectForKey:@"created_at"]);
        rep     = AsNumber([mblog objectForKey:@"reposts_count"]);
        com     = AsNumber([mblog objectForKey:@"comments_count"]);
        att     = AsNumber([mblog objectForKey:@"attitudes_count"]);

        retweet = AsDict([mblog objectForKey:@"retweeted_status"]);
        retweetText = BuildRetweetText(mblog, retweet, &originName);
        clean = retweetText ? retweetText
                            : CleanHTMLString(AsString([mblog objectForKey:@"text"]));
        avatar = NormalizeURL(AsString([user objectForKey:@"profile_image_url"]));
        if (!avatar) avatar = NormalizeURL(AsString([user objectForKey:@"avatar_hd"]));

        photos = [[NSMutableArray alloc] init];
        photoLarges = [[NSMutableArray alloc] init];
        CollectPhotos(mblog, photos, photoLarges, &thumb, &large);
        /* 转发常常外层无图、图在原微博里 */
        if ([photos count] == 0 && retweet)
            CollectPhotos(retweet, photos, photoLarges, &thumb, &large);
        large = large ? NormalizeURL(large) : nil;

        pageInfo = AsDict([mblog objectForKey:@"page_info"]);
        if (!pageInfo && retweet) pageInfo = AsDict([retweet objectForKey:@"page_info"]);
        kind = @"";
        if (retweet) kind = @"转发";
        if (pageInfo) {
            NSString *t = AsString([pageInfo objectForKey:@"type"]);
            if (t && [t isEqualToString:@"video"]) kind = @"视频";
        }

        /* created_at 是完整英文时间戳，放进两行 meta 会把「转评赞」挤掉，
           列表只显示作者 + 转评赞，原始时间另存 time 字段给详情页。 */
        meta = [NSString stringWithFormat:@"%@\n转 %d   评 %d   赞 %d%@",
                name ? name : @"匿名",
                [rep intValue], [com intValue], [att intValue],
                ([kind length] > 0) ? @"   ·  视频" : @""];

        post = [[NSMutableDictionary alloc] init];
        [post setObject:[NSString stringWithFormat:@"转 %d   评 %d   赞 %d%@",
                         [rep intValue], [com intValue], [att intValue],
                         ([kind length] > 0) ? @"   ·  视频" : @""]
                forKey:@"stats"];
        [post setObject:clean forKey:@"text"];
        [post setObject:meta  forKey:@"meta"];
        [post setObject:clean forKey:@"full"];
        [post setObject:(name ? name : @"匿名") forKey:@"author"];
        [post setObject:(created ? created : @"") forKey:@"time"];
        [post setObject:kind forKey:@"kind"];
        /* 存微博 id 字符串：关注流翻页去重要用，UI 不读这个 key */
        {
            NSString *pid = AsString([mblog objectForKey:@"id"]);
            if (pid && [pid length] > 0) [post setObject:pid forKey:@"id"];
        }
        if (avatar) [post setObject:avatar forKey:@"avatar"];
        if (thumb)  [post setObject:thumb  forKey:@"thumb"];
        if (large)  [post setObject:large  forKey:@"large"];
        [post setObject:photos      forKey:@"photos"];
        [post setObject:photoLarges forKey:@"photoLarges"];
        [photos release];
        [photoLarges release];
        [list addObject:post];
        [post release];
    }

    /* 更新分页游标：热门读 cardlistInfo.since_id，关注读 data.max_id，我的用 page */
    if (root) {
        id data = AsDict([root objectForKey:@"data"]);
        if (sFeed == 0) {
            id cli = AsDict([data objectForKey:@"cardlistInfo"]);
            id sid = [cli objectForKey:@"since_id"];
            if (sid) sSinceID = [AsNumber(sid) intValue];
            else sSinceID += 1;
            sHasMore = ([list count] > 0) ? 1 : 0;
        } else if (sFeed == 1) {
            /* data.max_id 实测是数字(NSNumber)，另有 max_id_str 为同值字符串。
               毫秒级时间戳超过 int 范围，必须走字符串而不是 intValue，否则被截断。 */
            id mid = [data objectForKey:@"max_id_str"];
            if (!mid || ![mid isKindOfClass:[NSString class]] || [(NSString *)mid length] == 0)
                mid = [data objectForKey:@"max_id"];
            if (mid) {
                NSString *cur = nil;
                if ([mid isKindOfClass:[NSString class]])
                    cur = (NSString *)mid;
                else if ([mid isKindOfClass:[NSNumber class]])
                    cur = [(NSNumber *)mid stringValue];
                if (cur && [cur length] > 0) {
                    if (sCursor) [sCursor release];
                    sCursor = [cur retain];
                }
            }
            sHasMore = ([list count] > 0) ? 1 : 0;
        } else {
            sHasMore = ([list count] > 0) ? 1 : 0;
        }
    }

    /* 加载更多：把新一页追加到已有列表；刷新：替换 */
    if (sLoadingMore && sPosts && [sPosts count] > 0) {
        if (sFeed == 1) {
            /* 关注流：max_id 分页偶尔会回带上一页末条，按 id 去重后再追加，
               避免列表里出现重复微博。热门/我的保持原样，不走这段。 */
            NSMutableDictionary *seen = [[NSMutableDictionary alloc] init];
            NSUInteger k;
            int added = 0;
            for (k = 0; k < [sPosts count]; k++) {
                NSString *pid = [[sPosts objectAtIndex:k] objectForKey:@"id"];
                if (pid) [seen setObject:@"1" forKey:pid];
            }
            for (k = 0; k < [list count]; k++) {
                NSDictionary *np = [list objectAtIndex:k];
                NSString *pid = [np objectForKey:@"id"];
                if (pid && [seen objectForKey:pid]) continue;   /* 已存在，跳过 */
                if (pid) [seen setObject:@"1" forKey:pid];
                [sPosts addObject:np];
                added++;
            }
            [seen release];
            /* 全被去重（这页没有新内容）说明到头了，避免无限上拉 */
            if (added == 0) sHasMore = 0;
#ifdef LEGACY_DIAG
            diag([[NSString stringWithFormat:@"WeiboStore: friends append added=%d total=%d",
                   added, (int)[sPosts count]] UTF8String]);
#endif
            [list release];
        } else {
            [sPosts addObjectsFromArray:list];
            [list release];
        }
    } else {
        if (sPosts) [sPosts release];
        sPosts = list;   /* 转移所有权，不 release */
    }
    diag([sPosts count] > 0 ? "WeiboStore: parse ok" : "WeiboStore: parse empty");
    [pool drain];
}

@interface WeiboStoreDelegate : NSObject @end

@implementation WeiboStoreDelegate

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    (void)connection;
    (void)response;
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    (void)connection;
    if (sBuffer && data) [sBuffer appendData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    (void)connection;
    diag("WeiboStore: connection finished");
    ParseBuffer();
    sState = (sPosts && [sPosts count] > 0) ? 2 : 3;
    if (sState == 3 && !sErrorText) sErrorText = @"接口返回空数据，下拉刷新重试";
    sLoadingMore = 0;                       /* 不论成败都复位加载更多标志 */
    if (sConnection) { [sConnection release]; sConnection = nil; }
    if (sBuffer)     { [sBuffer release];     sBuffer = nil; }
    if (sUpdateCallback) sUpdateCallback();
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(id)error
{
    (void)connection;
    (void)error;
    diag("WeiboStore: connection failed");
    /* 加载更多失败时保留已有列表，不覆盖成全屏错误 */
    if (sLoadingMore) {
        sLoadingMore = 0;
        sState = (sPosts && [sPosts count] > 0) ? 2 : 3;
    } else {
        sState = 3;
        sErrorText = @"网络连接失败，请检查 Wi-Fi 后下拉重试";
    }
    if (sConnection) { [sConnection release]; sConnection = nil; }
    if (sBuffer)     { [sBuffer release];     sBuffer = nil; }
    if (sUpdateCallback) sUpdateCallback();
}

@end

int WeiboStoreState(void)       { return sState; }
NSArray  *WeiboStorePosts(void) { return sPosts; }
NSString *WeiboStoreErrorText(void) { return sErrorText; }

int WeiboStoreLoggedIn(void) { return (sCookie && [sCookie length] > 0) ? 1 : 0; }
NSString *WeiboStoreUserName(void) { return sUserName ? sUserName : @""; }
int WeiboStoreFeed(void) { return sFeed; }

NSString *WeiboStoreAltFeedName(void)
{
    return @"关注";
}

NSString *WeiboStoreFeedName(void)
{
    if (sFeed == 1) return @"关注";
    if (sFeed == 2) return @"我的";
    return @"热门";
}

void WeiboStoreSetUpdateCallback(void (*callback)(void))
{
    sUpdateCallback = callback;
}

void WeiboStoreSwitchFeed(int feed)
{
    if (sFeed == feed) return;
    if (feed == 1 && !WeiboStoreLoggedIn()) return;   /* 关注流需登录 */
    if (feed == 2 && !WeiboStoreLoggedIn()) return;   /* 我的需登录 */
    sFeed = feed;
    if (sConnection) { [sConnection cancel]; [sConnection release]; sConnection = nil; }
    if (sBuffer)     { [sBuffer release];     sBuffer = nil; }
    if (sPosts)      { [sPosts release];      sPosts = nil; }
    sState = 0;
    sPage = 1;
    sSinceID = 1;
    sHasMore = 1;
    sLoadingMore = 0;
    if (sCursor) { [sCursor release]; sCursor = nil; }
    WeiboStoreLoad();
}

/* 发起一次 feed 请求（刷新或加载更多共用）。调用前分页状态已调好。 */
static void StartFeedRequest(void)
{
    NSURL *url;
    NSURLRequest *request;

    if (sConnection) { [sConnection cancel]; [sConnection release]; sConnection = nil; }
    if (sBuffer)     { [sBuffer release];     sBuffer = nil; }
    sBuffer = [[NSMutableData alloc] init];
    sState = 1;

    if (!sConnectionDelegate) {
        sConnectionDelegate = [[WeiboStoreDelegate alloc] init];
    }
    url = [NSURL URLWithString:FeedURLString()];
    if (WeiboStoreLoggedIn()) {
        /* 带登录态时补齐移动端请求头：Referer / XHR / UA 与扫码时一致，
           否则服务端可能按游客处理或触发风控。 */
        NSMutableURLRequest *auth = [NSMutableURLRequest
                                     requestWithURL:url
                                       cachePolicy:0
                                   timeoutInterval:15.0];
        [auth setValue:sCookie forHTTPHeaderField:@"Cookie"];
        [auth setValue:@"https://m.weibo.cn/" forHTTPHeaderField:@"Referer"];
        [auth setValue:@"XMLHttpRequest" forHTTPHeaderField:@"X-Requested-With"];
        [auth setValue:@"1" forHTTPHeaderField:@"MWeibo-Pwa"];
        [auth setValue:[NSString stringWithUTF8String:kMobileUA]
          forHTTPHeaderField:@"User-Agent"];
        request = auth;
    } else {
        request = [NSURLRequest requestWithURL:url
                                  cachePolicy:0
                              timeoutInterval:15.0];
    }
    sConnection = [[NSURLConnection alloc] initWithRequest:request
                                                 delegate:sConnectionDelegate
                                        startImmediately:YES];
    if (!sConnection) {
        sState = 3;
        sErrorText = @"无法创建网络连接";
    }
    if (sUpdateCallback) sUpdateCallback();
}

void WeiboStoreLoad(void)
{
    if (sState == 1) return;   /* 正在加载，避免重复请求 */

    diag("WeiboStore: load begin");
    sPage = 1;
    sSinceID = 1;
    sHasMore = 1;
    sLoadingMore = 0;
    if (sCursor) { [sCursor release]; sCursor = nil; }

    /* 新一批数据带新的签名 URL，旧图片缓存与在途请求一并清掉 */
    ImageLoaderReset();
    sErrorText = nil;
    StartFeedRequest();
}

void WeiboStoreLoadMore(void)
{
    if (sState == 1) return;          /* 正在加载（首屏或上一页） */
    if (!sHasMore) return;            /* 没有更多 */
    if (!sPosts || [sPosts count] == 0) return;

    diag("WeiboStore: load more begin");
    sLoadingMore = 1;
    /* 关注用 max_id 游标；我的用 page；热门用 since_id。
       ParseBuffer 会在成功后推进游标，这里先为 page 型加一。 */
    if (sFeed == 0) sSinceID += 0;    /* 由返回 cardlistInfo.since_id 推进 */
    else if (sFeed == 2) sPage += 1;
    /* 不清空图片缓存：旧 cell 还在用，只追加新图 */
    sErrorText = nil;
    StartFeedRequest();
}

int WeiboStoreLoadingMore(void) { return sLoadingMore; }
int WeiboStoreHasMore(void)     { return sHasMore; }
