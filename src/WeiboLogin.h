#ifndef WEIBO_LOGIN_H
#define WEIBO_LOGIN_H

#import "LegacyKit.h"

/*
 * app 内扫码登录（iOS 5+，不用 UIWebView）。
 *
 * 微博登录页本身跑不动（ES6 访客系统 + 易盾滑块），但登录**接口**是纯 JSON：
 *   1) GET passport.weibo.com/sso/v2/qrcode/image  拿 qrid + 二维码图片 URL
 *   2) 下载二维码 PNG，交给界面显示
 *   3) 每 2 秒 GET .../qrcode/check?qrid=...  看 retcode
 *   4) 成功后 GET data.url 换票；NSURLConnection 自动把 SUB/SUBP 存进
 *      sharedHTTPCookieStorage
 *   5) GET m.weibo.cn/api/config 校验 login=true 并取 uid
 *   6) 把 Cookie 拼成字符串写到 <HOME>/weibo_login.txt，重启也有效
 *
 * 状态：0 空闲 1 取二维码中 2 二维码就绪 3 已扫待确认 4 换票中 5 成功 6 失败
 * 回调：cb(state, qrcode, message)，qrcode 仅在 state=2 时非空。
 * 所有状态是 C 静态变量，自定义类无 ivar（见 AppDelegate.m 说明）。
 */

void WeiboLoginSetCallback(void (*callback)(int state, UIImage *qrcode, NSString *message));
void WeiboLoginStart(void);
void WeiboLoginCancel(void);
int  WeiboLoginState(void);

#endif /* WEIBO_LOGIN_H */
