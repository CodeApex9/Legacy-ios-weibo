#ifndef IMAGE_LOADER_H
#define IMAGE_LOADER_H

#import "LegacyKit.h"

/*
 * 极简图片加载器：异步 NSURLConnection + 进程内内存缓存。
 *
 * 真机确认（iPhone 5 / iOS 6.1.4）：
 *   头像 https://tvax*.sinaimg.cn/...  配图 https://wx*.sinaimg.cn/orj480/...
 *   两者都能被 CFNetwork / Secure Transport 直连，返回 200 + JPEG。
 *
 * 设计约束（见 AppDelegate.m 顶部说明）：
 *   - 自定义类不能有 ObjC ivar，所有状态用文件级 C 静态变量；
 *   - 槽位定长 96 条，避免 NSMutableDictionary 与额外类符号；
 *   - 下载完成只回调一次 UI 精确刷新可见 cell，不整表 reloadData；
 *   - 不用 block、不用 GCD，兼容 iOS 5。
 *
 * 用法：ImageLoaderRequest(url) 发起（幂等），ImageLoaderCachedImage(url)
 *       取图；nil 表示仍在下载或失败，UI 显示占位图。
 */

void     ImageLoaderSetUpdateCallback(void (*callback)(void));
UIImage *ImageLoaderCachedImage(NSString *url);
void     ImageLoaderRequest(NSString *url);
void     ImageLoaderReset(void);

#endif /* IMAGE_LOADER_H */
