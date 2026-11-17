#import "WeiboLogin.h"
#import "Diag.h"

#define QR_API    "https://passport.weibo.com/sso/v2/qrcode/image?entry=weibo&size=180"
#define CHECK_API "https://passport.weibo.com/sso/v2/qrcode/check?qrid=%s&entry=weibo"
#define CONFIG_API "https://m.weibo.cn/api/config"
#define PC_UA "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
#define MOBILE_UA "Mozilla/5.0 (iPhone; CPU iPhone OS 10_3 like Mac OS X) AppleWebKit/603.1.30 (KHTML, like Gecko) Version/10.0 Mobile/14E277 Safari/602.1"

/* stage: 1 二维码JSON 2 二维码图片 3 轮询check 4 换票 5 校验config */
static int               sState = 0;
static int               sStage = 0;
static NSString         *sQrid = nil;
static NSString         *sTicketURL = nil;
static NSString         *sUID = nil;
static NSString         *sName = nil;
static NSURLConnection  *sConn = nil;
static NSMutableData    *sBuffer = nil;
static id                sDelegate = nil;
static NSTimer          *sTimer = nil;
static int               sPollCount = 0;
static void            (*sCallback)(int, UIImage *, NSString *) = 0;

extern int   open(const char *, int, ...);
extern long  write(int, const void *, unsigned long);
extern int   close(int);
extern unsigned long strlen(const char *);

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

static void Notify(int state, UIImage *qr, NSString *msg)
{
    sState = state;
    if (sCallback) sCallback(state, qr, msg);
}

static void StopTimer(void)
{
    if (sTimer) { [sTimer invalidate]; sTimer = nil; }
}

static void CancelConnection(void)
{
    if (sConn) { [sConn cancel]; [sConn release]; sConn = nil; }
    if (sBuffer) { [sBuffer release]; sBuffer = nil; }
}

/* 从 sharedHTTPCookieStorage 收集登录 Cookie，按服务端实际需要的顺序拼串。
   NSURLConnection 默认自动把 Set-Cookie 存进 shared storage，所以换票后
   这里就能读到 SUB / SUBP / ALF / SCF / SSOLoginState 等。 */
static NSString *CollectCookieHeader(void)
{
    NSArray *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies];
    NSUInteger i, j, n = cookies ? [cookies count] : 0;
    NSString *order[] = { @"SUB", @"SUBP", @"SSOLoginState", @"ALF", @"SCF",
                          @"_T_WM", @"WEIBOCN_FROM", @"M_WEIBOCN_PARAMS",
                          @"XSRF-TOKEN", @"mweibo_short_token", @"WBPSESS", nil };
    NSMutableString *out = [[NSMutableString alloc] init];
    BOOL hasSub = NO;

    /* 同名 Cookie 在多个域下各存一份（SUB/SUBP/ALF 等各 3 份）。
       全部拼进去会让服务端读到重复冲突的 SUB 并返回 ok:-100。
       每个名字只取一份，按 order 顺序输出。 */
    for (j = 0; order[j] != nil; j++) {
        NSString *chosen = nil;
        for (i = 0; i < n; i++) {
            NSHTTPCookie *c = (NSHTTPCookie *)[cookies objectAtIndex:i];
            NSString *name = [c name];
            if (!name || ![name isEqualToString:order[j]]) continue;
            if (!chosen) chosen = [c value];   /* 同名只取第一个 */
        }
        if (!chosen) continue;
        if ([out length] > 0) [out appendString:@"; "];
        [out appendFormat:@"%@=%@", order[j], chosen];
        if ([order[j] isEqualToString:@"SUB"]) hasSub = YES;
    }
    if (!hasSub) { [out release]; return nil; }
    /* 与 Mac 扫码脚本一致：移动端需要 MLOGIN=1 才认登录态 */
    [out appendString:@"; MLOGIN=1"];
    return [out autorelease];
}

/* 写登录态到本地：<HOME>/weibo_login.txt。越狱 app 的 home 是 /var/mobile，
   可写；bundle 里的 Login.txt 保持只读，作为预置凭据。 */
static void SaveLoginLocally(NSString *cookie, NSString *uid, NSString *name)
{
    NSString *path = [NSString stringWithFormat:@"%@/weibo_login.txt", NSHomeDirectory()];
    NSString *content = [NSString stringWithFormat:
                         @"uid=%@\nfeed=107603%@\nname=%@\ncookie=%@\n",
                         uid ? uid : @"", uid ? uid : @"",
                         name ? name : @"已登录", cookie];
    const char *p = [path UTF8String];
    const char *v = [content UTF8String];
    int fd;
    if (!p || !v) return;
    /* O_WRONLY(0x1) | O_CREAT(0x200) | O_TRUNC(0x400) = 0x601 */
    fd = open(p, 0x601, 0644);
    if (fd >= 0) {
        write(fd, v, strlen(v));
        close(fd);
    }
    diag("WeiboLogin: login state saved locally");
}

static NSURLConnection *StartRequest(NSString *urlString, NSString *ua,
                                     NSString *referer, BOOL xhr)
{
    NSURL *url = [NSURL URLWithString:urlString];
    NSMutableURLRequest *req;
    NSURLConnection *conn;
    if (!url) return nil;
    req = [NSMutableURLRequest requestWithURL:url
                                 cachePolicy:0
                             timeoutInterval:15.0];
    [req setValue:ua forHTTPHeaderField:@"User-Agent"];
    if (referer) [req setValue:referer forHTTPHeaderField:@"Referer"];
    if (xhr) [req setValue:@"XMLHttpRequest" forHTTPHeaderField:@"X-Requested-With"];
    conn = [[NSURLConnection alloc] initWithRequest:req
                                          delegate:sDelegate
                                 startImmediately:NO];
    if (conn) [conn start];
    return conn;
}

static void StartQRCode(void)
{
    sStage = 1;
    CancelConnection();
    sBuffer = [[NSMutableData alloc] init];
    sConn = StartRequest([NSString stringWithUTF8String:QR_API],
                         [NSString stringWithUTF8String:PC_UA],
                         @"https://passport.weibo.com/sso/signin", NO);
    diag(sConn ? "WeiboLogin: qrcode request started" : "WeiboLogin: qrcode request failed");
}

static void StartCheck(void)
{
    NSString *url;
    sStage = 3;
    CancelConnection();
    if (!sQrid) { Notify(6, nil, @"二维码失效，请重试"); return; }
    url = [NSString stringWithFormat:
           [NSString stringWithUTF8String:CHECK_API], [sQrid UTF8String]];
    sBuffer = [[NSMutableData alloc] init];
    sConn = StartRequest(url,
                         [NSString stringWithUTF8String:PC_UA],
                         @"https://passport.weibo.com/sso/signin", NO);
}

static void StartTicket(void)
{
    sStage = 4;
    CancelConnection();
    if (!sTicketURL) { Notify(6, nil, @"换票地址缺失，请重试"); return; }
    sBuffer = [[NSMutableData alloc] init];
    /* 关键：用 PC UA 访问换票 URL，NSURLConnection 自动跟随跳转并存 Cookie */
    sConn = StartRequest(sTicketURL,
                         [NSString stringWithUTF8String:PC_UA],
                         @"https://passport.weibo.com/", NO);
    diag("WeiboLogin: ticket exchange started");
}

/* 换票后必须再访问一次 m.weibo.cn 首页，让移动端域拿到 SUB/SUBP。
   Mac 侧扫码脚本验证过：只访问 passport 的 ticket URL，CookieJar 里没有 SUB；
   补这一步后才会下发移动端登录 Cookie。 */
static void StartMobileCookie(void)
{
    sStage = 6;
    CancelConnection();
    sBuffer = [[NSMutableData alloc] init];
    diag("WeiboLogin: fetch m.weibo.cn to seal mobile cookie");
    sConn = StartRequest(@"https://m.weibo.cn/",
                         [NSString stringWithUTF8String:MOBILE_UA],
                         @"https://m.weibo.cn/", NO);
}

static void StartConfig(void)
{
    sStage = 5;
    CancelConnection();
    sBuffer = [[NSMutableData alloc] init];
    diag("WeiboLogin: config request started");
    sConn = StartRequest([NSString stringWithUTF8String:CONFIG_API],
                         [NSString stringWithUTF8String:MOBILE_UA],
                         @"https://m.weibo.cn/", YES);
}

static void HandleFinish(void)
{
    id root, data;
    NSData *buf = sBuffer;

    /* 连接已结束，必须清空 sConn。否则 pollTick 开头的
       `if (sConn) return;` 会永远为真，扫码后 app 完全不会去查状态。 */
    if (sConn) { [sConn release]; sConn = nil; }

    /* NSURLConnection 的自动 Cookie 处理会在 connectionDidFinishLoading 之前
       把 Set-Cookie 写入 shared storage，这里再读即可。 */
    if (sStage == 2) {
        UIImage *img = buf ? [UIImage imageWithData:buf] : nil;
        if (!img) { Notify(6, nil, @"二维码图片解析失败"); return; }
        StopTimer();
        sPollCount = 0;
        sTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                  target:sDelegate
                                                selector:@selector(pollTick:)
                                                userInfo:nil
                                                 repeats:YES];
        diag("WeiboLogin: QR ready, poll timer started");
        Notify(2, img, @"请用手机微博 App 扫码");
        return;
    }

    /* 换票页与移动端首页返回的是 HTML/JSONP，不是 JSON，必须放在 JSON
       解析之前处理，否则会被下面的解析失败分支当成错误直接放弃。 */
    if (sStage == 4) {
        diag("WeiboLogin: ticket page loaded");
        StartMobileCookie();
        return;
    }
    if (sStage == 6) {
        diag("WeiboLogin: mobile cookie page loaded");
        StartConfig();
        return;
    }

    root = buf ? [NSJSONSerialization JSONObjectWithData:buf options:0 error:(id *)0] : nil;
    if (!root) { diag("WeiboLogin: no JSON in response"); Notify(6, nil, @"接口返回异常，请重试"); return; }
    data = AsDict([root objectForKey:@"data"]);

    if (sStage == 1) {
        NSString *image = AsDict(data) ? [data objectForKey:@"image"] : nil;
        id qrid = [data objectForKey:@"qrid"];
        if (!image || !qrid) { Notify(6, nil, @"二维码接口返回异常"); return; }
        if ([image hasPrefix:@"//"])
            image = [NSString stringWithFormat:@"https:%@", image];
        if (sQrid) [sQrid release];
        sQrid = [[NSString stringWithFormat:@"%@", qrid] retain];
        sStage = 2;
        CancelConnection();
        sBuffer = [[NSMutableData alloc] init];
        sConn = StartRequest(image,
                             [NSString stringWithUTF8String:PC_UA],
                             @"https://passport.weibo.com/sso/signin", NO);
        return;
    }

    if (sStage == 3) {
        id rc = [root objectForKey:@"retcode"];
        int code = rc ? [rc intValue] : 0;
        if (code == 50114001) return;            /* 未扫，继续轮询 */
        diag("WeiboLogin: check returned non-pending code");
        if (code == 50114002) { Notify(3, nil, @"已扫描，请在手机上点确认"); return; }
        if (code == 20000000) {
            NSString *ticket = [data objectForKey:@"url"];
            if (!ticket || ![ticket hasPrefix:@"http"]) {
                ticket = [data objectForKey:@"alt"];
            }
            diag(ticket ? "WeiboLogin: scan confirmed, ticket url found" :
                          "WeiboLogin: scan confirmed but NO ticket url");
            if (!ticket) { Notify(6, nil, @"扫码成功但换票地址缺失"); return; }
            if (sTicketURL) [sTicketURL release];
            sTicketURL = [ticket retain];
            StopTimer();
            Notify(4, nil, @"正在获取登录凭证…");
            StartTicket();
            return;
        }
        StopTimer();
        Notify(6, nil, @"二维码已失效，请重试");
        return;
    }

    if (sStage == 5) {
        id login = [data objectForKey:@"login"];
        id uid = [data objectForKey:@"uid"];
        NSString *cookie;
        diag("WeiboLogin: config check finished");
        if (!login || ![login intValue]) { Notify(6, nil, @"登录校验失败，请重试"); return; }
        cookie = CollectCookieHeader();
        if (!cookie) { diag("WeiboLogin: no cookie collected"); Notify(6, nil, @"未拿到登录凭证，请重试"); return; }
        diag("WeiboLogin: cookie collected with SUB");
        if (sUID) [sUID release];
        sUID = uid ? [[NSString stringWithFormat:@"%@", uid] retain] : nil;
        SaveLoginLocally(cookie, sUID, sName ? sName : @"已登录");
        Notify(5, nil, @"登录成功");
        return;
    }
}

@interface WeiboLoginDelegate : NSObject @end

@implementation WeiboLoginDelegate

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    (void)connection;
    (void)response;
    if (sBuffer) [sBuffer setLength:0];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    (void)connection;
    if (sBuffer && data) [sBuffer appendData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    (void)connection;
    HandleFinish();
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(id)error
{
    (void)connection;
    (void)error;
    if (sConn) { [sConn release]; sConn = nil; }
    if (sStage == 3) return;   /* 轮询单次失败不打断整体流程 */
    if (sStage == 4) diag("WeiboLogin: ticket request FAILED");
    else if (sStage == 6) diag("WeiboLogin: mobile cookie request FAILED");
    else if (sStage == 5) diag("WeiboLogin: config request FAILED");
    else if (sStage == 1) diag("WeiboLogin: qrcode request FAILED");
    else if (sStage == 2) diag("WeiboLogin: qrcode image request FAILED");
    StopTimer();
    Notify(6, nil, @"网络连接失败，请检查 Wi-Fi");
}

- (void)pollTick:(id)sender
{
    (void)sender;
    if (sConn) return;         /* 上一次请求还没回来，跳过本次 */
    sPollCount++;
    if (sPollCount == 1) diag("WeiboLogin: first poll sent");
    if (sPollCount > 90) {
        StopTimer();
        Notify(6, nil, @"扫码超时，请重试");
        return;
    }
    StartCheck();
}

@end

void WeiboLoginSetCallback(void (*callback)(int state, UIImage *qrcode, NSString *message))
{
    sCallback = callback;
}

void WeiboLoginStart(void)
{
    WeiboLoginCancel();
    Notify(1, nil, @"正在获取二维码…");
    if (!sDelegate) sDelegate = [[WeiboLoginDelegate alloc] init];
    StartQRCode();
}

void WeiboLoginCancel(void)
{
    StopTimer();
    CancelConnection();
    if (sQrid)     { [sQrid release];     sQrid = nil; }
    if (sTicketURL){ [sTicketURL release]; sTicketURL = nil; }
    if (sUID)      { [sUID release];      sUID = nil; }
    sStage = 0;
    sState = 0;
    sPollCount = 0;
}

int WeiboLoginState(void)
{
    return sState;
}
