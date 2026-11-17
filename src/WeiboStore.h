#ifndef WEIBO_STORE_H
#define WEIBO_STORE_H

#import "LegacyKit.h"

/*
 * 热门流数据层：异步 NSURLConnection + NSJSONSerialization。
 * 接口刻意做成 C 函数，避免在手工链接工具链里引入自定义类的 ivar/协议依赖。
 * 所有状态是文件级静态变量（见 AppDelegate.m 的 ivar 说明）。
 *
 * 登录态：Mac 侧扫码登录后把 Login.txt 放进 app bundle，字段为
 *   uid=<数字> / feed=<containerid> / name=<昵称> / cookie=<整行 Cookie>
 * app 启动时 WeiboStoreInitLogin() 读取，之后所有请求用 NSMutableURLRequest
 * 带上 Cookie / Referer / X-Requested-With / 移动端 UA。Cookie 不进源码。
 *
 * 状态：0=空闲 1=加载中 2=成功 3=失败
 * 流：  0=热门（游客可用） 1=关注流 2=我的（需登录）
 */
int        WeiboStoreState(void);
NSArray   *WeiboStorePosts(void);
NSString  *WeiboStoreErrorText(void);
void       WeiboStoreSetUpdateCallback(void (*callback)(void));
void       WeiboStoreLoad(void);                    /* 刷新：清空后重新拉第一页 */
void       WeiboStoreLoadMore(void);                /* 加载更多：追加下一页 */
int        WeiboStoreLoadingMore(void);
int        WeiboStoreHasMore(void);

void       WeiboStoreInitLogin(void);
void       WeiboStoreReloadLogin(void);     /* app 内扫码成功后重新读取本地凭据 */
void       WeiboStoreLogout(void);          /* 退出：清凭据+持久化标记+清空三个tab数据 */
int        WeiboStoreLoggedIn(void);
NSString  *WeiboStoreUserName(void);
/* 当前账号资料（异步拉取）：screen_name/gender/followers_count/follow_count/
   statuses_count/description/avatar_hd。未拉到时返回 nil。 */
NSDictionary *WeiboStoreProfile(void);
void       WeiboStoreSetProfileCallback(void (*callback)(void));
void       WeiboStoreFetchProfile(void);
NSString  *WeiboStoreFeedName(void);
NSString  *WeiboStoreAltFeedName(void);   /* 旧的第二个 tab 名（兼容用） */
int        WeiboStoreFeed(void);
void       WeiboStoreSwitchFeed(int feed);

/* 供评论模块复用：当前 Cookie（未登录为 nil，热门微博的评论游客也能读）
   与微博正文的 HTML 清理逻辑（含 <img alt="[表情]"> 还原成文字）。 */
NSString  *WeiboStoreCookie(void);
NSString  *WeiboStoreCleanHTML(NSString *src);

#endif /* WEIBO_STORE_H */
