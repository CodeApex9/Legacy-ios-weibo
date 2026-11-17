#import "WeiboComments.h"
#import "WeiboStore.h"
#import "Diag.h"

/*
 * 评论数据层：只用一个 @interface/@implementation 的空壳类做 NSURLConnection
 * 的 delegate，所有状态放在文件级静态变量里（与本工程手工链接方式保持一致，
 * 不引入自定义类的 ivar 布局依赖）。
 */

extern unsigned long strlen(const char *);
extern void *malloc(unsigned long);
extern void  free(void *);

static NSMutableArray  *sList = nil;        /* NSMutableArray<NSDictionary *> */
static NSMutableData   *sBuffer = nil;
static NSURLConnection *sConn = nil;
static id               sDelegate = nil;
static NSString        *sMid = nil;         /* 当前微博 id/mid（实测两者同值） */
static NSString        *sMaxID = nil;       /* 下一页游标 */
static int              sMaxIDType = 0;
static int              sState = 0;         /* 0 空闲 1 加载中 2 成功 3 失败 4 没有评论 */
static int              sHasMore = 0;
static int              sLoadingMore = 0;
static int              sTotal = 0;
static NSString        *sError = nil;
static void           (*sUpdateCallback)(void) = 0;
/* 请求代号：关闭正文页/重新加载时自增，迟到的回调据此丢弃，
   避免 overaly 已销毁后还去改界面（野指针）。 */
static int              sGen = 0;
static int              sReqGen = 0;

/* ---------- JSON 取值：NSNull / 类型不符时统一返回 nil ---------- */
static NSString *AsString(id obj)
{
    return [obj isKindOfClass:[NSString class]] ? (NSString *)obj : nil;
}
static id AsDict(id obj)
{
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}
static id AsArray(id obj)
{
    return [obj isKindOfClass:[NSArray class]] ? obj : nil;
}
static id AsNumber(id obj)
{
    return [obj isKindOfClass:[NSNumber class]] ? obj : nil;
}
/* id / max_id 在不同接口里既可能是字符串也可能是数字，统一转字符串 */
static NSString *AsIDString(id obj)
{
    if ([obj isKindOfClass:[NSString class]]) return (NSString *)obj;
    if ([obj isKindOfClass:[NSNumber class]]) return [(NSNumber *)obj stringValue];
    return nil;
}

/* ---------- 文本归一化 ----------
   评论正文过完 HTML 清理后常带首尾空格和多余换行，iOS 5 上没有
   stringByTrimming… 可用，这里用纯 C 做：去首尾空白、折叠连续空格、
   把连续换行压成一个。中文按字节拷贝，只判断 ASCII 空白，安全。 */
static NSString *NormalizeText(NSString *src)
{
    const char *p;
    char *out;
    unsigned long n, i, j = 0;
    int lastSpace = 1, hasNL = 0;
    NSString *result;

    if (!src) return @"";
    p = [src UTF8String];
    if (!p) return @"";
    n = strlen(p);
    out = (char *)malloc(n + 2);
    if (!out) return src;

    for (i = 0; i < n; i++) {
        unsigned char c = (unsigned char)p[i];
        if (c == '\r') continue;
        if (c == '\n') { hasNL = 1; continue; }
        if (c == ' ' || c == '\t') {
            if (j == 0 || lastSpace) continue;
            out[j++] = ' ';
            lastSpace = 1;
            continue;
        }
        if (hasNL) {
            if (j > 0) { out[j++] = '\n'; lastSpace = 1; }
            hasNL = 0;
        }
        out[j++] = (char)c;
        lastSpace = 0;
    }
    while (j > 0 && (out[j - 1] == ' ' || out[j - 1] == '\n')) j--;
    out[j] = '\0';
    result = [NSString stringWithUTF8String:out];
    free(out);
    return result ? result : @"";
}

/* ---------- 时间 ----------
   接口给的是 "Mon Nov 02 15:08:08 +0800 2026"，太占地方，
   折成 "11-02 15:08"。认不出来（例如「刚刚」「5分钟前」）就原样返回。 */
static int MonthIndex(const char *m)
{
    static const char *kNames[12] = {
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
    };
    int i;
    for (i = 0; i < 12; i++) {
        if (m[0] == kNames[i][0] && m[1] == kNames[i][1] && m[2] == kNames[i][2])
            return i + 1;
    }
    return 0;
}

static NSString *FormatCommentTime(NSString *raw)
{
    const char *p, *mon, *day, *tm;
    char buf[16];
    int m, k;

    if (!raw || [raw length] == 0) return @"";
    p = [raw UTF8String];
    if (!p) return raw;
    mon = p;
    while (*mon && *mon != ' ') mon++;
    if (!*mon) return raw;
    mon++;
    m = MonthIndex(mon);
    if (m == 0) return raw;
    day = mon;
    while (*day && *day != ' ') day++;
    if (!*day || !day[1]) return raw;
    day++;
    tm = day;
    while (*tm && *tm != ' ') tm++;
    if (!*tm || !tm[1]) return raw;
    tm++;

    buf[0] = (char)('0' + m / 10);
    buf[1] = (char)('0' + m % 10);
    buf[2] = '-';
    if (day[1] == ' ' || day[1] == '\0') {   /* 个位数日期补零 */
        buf[3] = '0';
        buf[4] = day[0];
    } else {
        buf[3] = day[0];
        buf[4] = day[1];
    }
    buf[5] = ' ';
    for (k = 0; k < 5; k++) buf[6 + k] = tm[k] ? tm[k] : '0';
    buf[11] = '\0';
    return [NSString stringWithUTF8String:buf];
}

/* ---------- 单条评论 ---------- */
static NSDictionary *BuildComment(id raw)
{
    NSMutableDictionary *c;
    id obj = AsDict(raw);
    id user, subsArr;
    NSString *text, *pid;
    NSUInteger i, n;
    int picNum = 0;

    if (!obj) return nil;
    text = NormalizeText(WeiboStoreCleanHTML(AsString([obj objectForKey:@"text"])));
    if (AsNumber([obj objectForKey:@"pic_num"])) picNum = [AsNumber([obj objectForKey:@"pic_num"]) intValue];
    if (!text && picNum == 0) return nil;      /* 既没文字也没图，丢弃 */
    if (picNum > 0) {
        /* iOS 5 这一版不做评论配图，先按微博 App 的方式给个占位 */
        text = ([text length] > 0)
             ? [NSString stringWithFormat:@"%@  [图片]", text]
             : @"[图片]";
    }
    if ([text length] == 0) return nil;

    user = AsDict([obj objectForKey:@"user"]);
    c = [[NSMutableDictionary alloc] init];
    pid = AsIDString([obj objectForKey:@"id"]);
    if (pid) [c setObject:pid forKey:@"id"];
    [c setObject:(AsString([user objectForKey:@"screen_name"]) ?: @"微博用户") forKey:@"name"];
    {
        NSString *av = AsString([user objectForKey:@"profile_image_url"]);
        if (av) [c setObject:av forKey:@"avatar"];
    }
    [c setObject:text forKey:@"text"];
    [c setObject:FormatCommentTime(AsString([obj objectForKey:@"created_at"])) forKey:@"time"];
    {
        /* 接口里是 like_count（注意不是微博正文的 attitudes_count） */
        int likes = 0;
        id lv = [obj objectForKey:@"like_count"];
        if (!lv) lv = [obj objectForKey:@"like_counts"];
        if (AsNumber(lv)) likes = [AsNumber(lv) intValue];
        [c setObject:[NSNumber numberWithInt:likes] forKey:@"likes"];
    }

    /* 前 2 条二级回复：只显示「昵称：内容」，不做点开 */
    subsArr = AsArray([obj objectForKey:@"comments"]);
    n = subsArr ? [subsArr count] : 0;
    if (n > 2) n = 2;
    if (n > 0) {
        NSMutableArray *subs = [[NSMutableArray alloc] init];
        for (i = 0; i < n; i++) {
            id r = AsDict([subsArr objectAtIndex:i]);
            id ru;
            NSString *rt, *rn;
            if (!r) continue;
            rt = NormalizeText(WeiboStoreCleanHTML(AsString([r objectForKey:@"text"])));
            if ([rt length] == 0) continue;
            ru = AsDict([r objectForKey:@"user"]);
            rn = AsString([ru objectForKey:@"screen_name"]);
            [subs addObject:[NSString stringWithFormat:@"%@：%@",
                             (rn ? rn : @"微博用户"), rt]];
        }
        [c setObject:subs forKey:@"subs"];
        [subs release];
    }
    return c;
}

/* ---------- 解析一页 ---------- */
static void ParseBuffer(void)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    id root = nil, data = nil, arr = nil, okv = nil, msg = nil;
    NSMutableDictionary *seen;
    int apiOK = 0, added = 0;
    NSUInteger i, cnt;

    if (sReqGen != sGen) { [pool drain]; return; }

    if (sBuffer) {
        root = [NSJSONSerialization JSONObjectWithData:sBuffer options:0 error:(id *)0];
    }
    if (root) {
        okv = [root objectForKey:@"ok"];
        apiOK = okv ? [AsNumber(okv) intValue] : 0;
        data = AsDict([root objectForKey:@"data"]);
        msg = AsString([root objectForKey:@"msg"]);
    }

    if (!data) {
        sLoadingMore = 0;
        if (apiOK == 0 && msg && [msg hasPrefix:@"还没有人评论"]) {
            sState = 4;                       /* 空态，不是失败 */
            sError = nil;
            diag("WeiboComments: no comment on this post");
        } else if (apiOK == -100 || apiOK == -101) {
            sState = 3;
            sError = @"登录已过期，点左上角「登录」重新扫码";
        } else {
            sState = 3;
            sError = @"评论加载失败，请稍后重试";
            diag("WeiboComments: api non-ok");
        }
        [pool drain];
        if (sUpdateCallback) sUpdateCallback();
        return;
    }

    arr = AsArray([data objectForKey:@"data"]);
    {
        id tv = [data objectForKey:@"total_number"];
        if (AsNumber(tv)) sTotal = [AsNumber(tv) intValue];
    }
    /* 翻页游标：max_id + max_id_type；max_id 为 0 表示到底了 */
    {
        id mv = [data objectForKey:@"max_id"];
        NSString *mstr = AsIDString(mv);
        if (!mstr) mstr = AsString([data objectForKey:@"max_id_str"]);
        if (sMaxID) { [sMaxID release]; sMaxID = nil; }
        if (mstr && [mstr length] > 0 && ![mstr isEqualToString:@"0"])
            sMaxID = [mstr retain];
        {
            id t = [data objectForKey:@"max_id_type"];
            sMaxIDType = AsNumber(t) ? [AsNumber(t) intValue] : 0;
        }
        sHasMore = (sMaxID != nil) ? 1 : 0;
    }

    /* 按评论 id 去重：翻页边界有时会回带同一条 */
    seen = [[NSMutableDictionary alloc] init];
    if (sList) {
        NSUInteger k;
        for (k = 0; k < [sList count]; k++) {
            NSString *eid = [[sList objectAtIndex:k] objectForKey:@"id"];
            if (eid) [seen setObject:@"1" forKey:eid];
        }
    }
    cnt = arr ? [arr count] : 0;
    if (!sList) sList = [[NSMutableArray alloc] init];
    for (i = 0; i < cnt; i++) {
        NSDictionary *c = BuildComment([arr objectAtIndex:i]);
        NSString *cid;
        if (!c) continue;
        cid = [c objectForKey:@"id"];
        if (cid) {
            if ([seen objectForKey:cid]) { [c release]; continue; }
            [seen setObject:@"1" forKey:cid];
        }
        [sList addObject:c];
        [c release];
        added++;
    }
    [seen release];

    sState = ([sList count] > 0) ? 2 : 4;
    if ([sList count] == 0) sHasMore = 0;
    if (added == 0 && [sList count] > 0) sHasMore = 0;   /* 整页都重复 → 到底 */
    sLoadingMore = 0;
    sError = nil;
#ifdef LEGACY_DIAG
    diag([[NSString stringWithFormat:@"WeiboComments: parsed added=%d total=%d hasMore=%d",
           added, (int)[sList count], sHasMore] UTF8String]);
#endif
    [pool drain];
    if (sUpdateCallback) sUpdateCallback();
}

@interface WeiboCommentsDelegate : NSObject @end

@implementation WeiboCommentsDelegate
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{ (void)connection; (void)response; }
- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{ (void)connection; if (sReqGen == sGen && sBuffer && data) [sBuffer appendData:data]; }
- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    (void)connection;
    if (sReqGen != sGen) return;          /* 已关闭/已重载，丢弃这一页 */
    if (sConn) { [sConn release]; sConn = nil; }
    ParseBuffer();
    if (sBuffer) { [sBuffer release]; sBuffer = nil; }
}
- (void)connection:(NSURLConnection *)connection didFailWithError:(id)error
{
    (void)connection; (void)error;
    if (sReqGen != sGen) return;
    if (sConn) { [sConn release]; sConn = nil; }
    if (sBuffer) { [sBuffer release]; sBuffer = nil; }
    sLoadingMore = 0;
    sState = 3;
    sError = @"评论加载失败，请检查网络";
    diag("WeiboComments: network failed");
    if (sUpdateCallback) sUpdateCallback();
}
@end

void WeiboCommentsSetUpdateCallback(void (*callback)(void)) { sUpdateCallback = callback; }
int  WeiboCommentsState(void) { return sState; }
NSArray *WeiboCommentsList(void) { return sList; }
int  WeiboCommentsTotal(void) { return sTotal; }
int  WeiboCommentsHasMore(void) { return sHasMore; }
int  WeiboCommentsLoadingMore(void) { return sLoadingMore; }
NSString *WeiboCommentsErrorText(void) { return sError; }

static void StartRequest(int more)
{
    NSURL *url;
    NSMutableURLRequest *req;
    NSString *u, *ck;
    if (sConn) { [sConn cancel]; [sConn release]; sConn = nil; }
    if (sBuffer) { [sBuffer release]; sBuffer = nil; }
    if (!sMid) return;
    sReqGen = sGen;

    if (more && sMaxID && [sMaxID length] > 0) {
        u = [NSString stringWithFormat:
             @"https://m.weibo.cn/comments/hotflow?id=%@&mid=%@&max_id=%@&max_id_type=%d",
             sMid, sMid, sMaxID, sMaxIDType];
    } else {
        u = [NSString stringWithFormat:
             @"https://m.weibo.cn/comments/hotflow?id=%@&mid=%@&max_id_type=0",
             sMid, sMid];
    }
    url = [NSURL URLWithString:u];
    if (!url) { sState = 3; sError = @"评论地址无效"; return; }

    sBuffer = [[NSMutableData alloc] init];
    if (!sDelegate) sDelegate = [[WeiboCommentsDelegate alloc] init];
    req = [NSMutableURLRequest requestWithURL:url cachePolicy:0 timeoutInterval:15.0];
    /* 未登录时 Cookie 为空：热门微博的评论游客也能读，所以不强求登录 */
    ck = WeiboStoreCookie();
    if (ck && [ck length] > 0) [req setValue:ck forHTTPHeaderField:@"Cookie"];
    [req setValue:@"https://m.weibo.cn/" forHTTPHeaderField:@"Referer"];
    [req setValue:@"XMLHttpRequest" forHTTPHeaderField:@"X-Requested-With"];
    [req setValue:@"1" forHTTPHeaderField:@"MWeibo-Pwa"];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 10_3 like Mac OS X) "
                   @"AppleWebKit/603.1.30 (KHTML, like Gecko) Version/10.0 Mobile/14E277 "
                   @"Safari/602.1" forHTTPHeaderField:@"User-Agent"];
    sConn = [[NSURLConnection alloc] initWithRequest:req
                                            delegate:sDelegate
                                    startImmediately:YES];
    if (!sConn) { [sBuffer release]; sBuffer = nil; sState = 3; sError = @"评论请求失败"; }
}

void WeiboCommentsLoad(NSString *mid)
{
    WeiboCommentsCancel();
    if (!mid || [mid length] == 0) {
        sState = 3;
        sError = @"这条微博缺少 id，无法加载评论";
        if (sUpdateCallback) sUpdateCallback();
        return;
    }
    sMid = [mid retain];
    sList = [[NSMutableArray alloc] init];
    sState = 1;
    sHasMore = 1;
    sTotal = 0;
    sLoadingMore = 0;
    sError = nil;
    StartRequest(0);
    diag("WeiboComments: load page 1");
    if (sUpdateCallback) sUpdateCallback();
}

void WeiboCommentsLoadMore(void)
{
    if (sState == 1 || sLoadingMore || !sHasMore) return;
    if (!sMid) return;
    sLoadingMore = 1;
    StartRequest(1);
    diag("WeiboComments: load more");
    if (sUpdateCallback) sUpdateCallback();
}

void WeiboCommentsCancel(void)
{
    sGen++;
    if (sConn) { [sConn cancel]; [sConn release]; sConn = nil; }
    if (sBuffer) { [sBuffer release]; sBuffer = nil; }
    if (sList) { [sList release]; sList = nil; }
    if (sMid) { [sMid release]; sMid = nil; }
    if (sMaxID) { [sMaxID release]; sMaxID = nil; }
    if (sError) { [sError release]; sError = nil; }
    sState = 0;
    sHasMore = 0;
    sLoadingMore = 0;
    sTotal = 0;
    sMaxIDType = 0;
}
