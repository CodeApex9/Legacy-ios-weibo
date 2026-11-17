#ifndef WEIBO_COMMENTS_H
#define WEIBO_COMMENTS_H

#import "LegacyKit.h"

/*
 * 微博评论数据层（正文页底部用）。
 *
 * 接口：m.weibo.cn/comments/hotflow?id=<id>&mid=<id>&max_id_type=<t>[&max_id=<m>]
 *   - id 和 mid 必须同时带，只带 id 会返回 ok:0；实测 mblog.id == mblog.mid，
 *     所以直接复用 post 里已存的 id 即可。
 *   - 每页 20 条，data.total_number 是总数，data.max_id + max_id_type 翻下一页。
 *   - 无评论时返回 ok:0 + msg「还没有人评论哦~快来抢沙发！」，属正常空态，
 *     不能当失败处理。
 *
 * 和 WeiboStore 一样：不建自定义类实例变量，状态全部是文件级 C 静态变量；
 * 每条评论一个 NSMutableDictionary：
 *   id / name / avatar / text / time / likes / subs（前 2 条二级回复）/ hasPic
 *
 * 状态：0=空闲 1=加载中 2=成功 3=失败 4=没有评论
 */

int        WeiboCommentsState(void);
NSArray   *WeiboCommentsList(void);          /* NSArray<NSDictionary *> */
int        WeiboCommentsTotal(void);         /* 接口给的总条数 */
NSString  *WeiboCommentsErrorText(void);
int        WeiboCommentsHasMore(void);
int        WeiboCommentsLoadingMore(void);

void       WeiboCommentsSetUpdateCallback(void (*callback)(void));
void       WeiboCommentsLoad(NSString *mid);  /* 首屏：清空旧数据再拉第一页 */
void       WeiboCommentsLoadMore(void);       /* 追加下一页 */
void       WeiboCommentsCancel(void);         /* 关闭正文页：取消在途请求并清空 */

#endif /* WEIBO_COMMENTS_H */
