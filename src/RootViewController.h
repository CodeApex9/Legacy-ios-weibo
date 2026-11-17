#import "LegacyKit.h"

/* 无实例变量：见 AppDelegate.m 顶部说明，界面状态一律用 C 静态变量 */
@interface RootViewController : UIViewController
- (void)refreshTapped:(id)sender;
- (void)feedChanged:(id)sender;
- (void)tabHot:(id)sender;               /* 自绘 tab：热门 */
- (void)tabFollow:(id)sender;            /* 自绘 tab：关注 */
- (void)tabMine:(id)sender;              /* 自绘 tab：我的 */
- (void)switchTabIndex:(int)idx sender:(id)sender;
- (void)loginTapped:(id)sender;
- (void)closeLogin:(id)sender;
- (void)refreshQRCode:(id)sender;
- (void)closeDetail:(id)sender;
- (void)showDetail:(NSUInteger)row;
#if defined(LEGACY_UI_EXTRA) || defined(FRIENDSCHECK)
- (void)diagAutoLoadMore;
#endif
#ifdef LEGACY_UI_EXTRA
- (void)diagAutoSwitchFeedTo:(id)target;
#ifdef UIGEST
- (void)diagAutoGesture;
- (void)diagDetailGesture;
#endif
#endif
- (void)photoTapped:(id)sender;
- (void)closePhotoViewer:(id)sender;
- (void)viewerPrev:(id)sender;
- (void)viewerNext:(id)sender;
- (void)viewerDoubleTap:(id)sender;
- (void)viewerPinch:(id)sender;
- (void)viewerPan:(id)sender;
- (void)detailThumbTapped:(id)sender;
- (void)commentMoreTapped:(id)sender;    /* 正文页：查看更多评论 */
- (void)commentRetryTapped:(id)sender;   /* 正文页：评论加载失败重试 */
- (void)accountTapped:(id)sender;        /* 未登录=弹扫码层；已登录=左侧滑出账号详情 */
- (void)closeAccount:(id)sender;         /* 账号详情返回主界面 */
- (void)logoutTapped:(id)sender;         /* 退出登录：清数据+回热门+头像变登录 */
- (void)refreshAccountArea;              /* 登录态变化时刷新左上角 */
- (void)refreshAccountPanel;             /* 资料到达后刷新详情面板 */
- (void)fillAccountPanel;
- (void)showAccountPanel;
- (void)accountAnimationDidStop:(NSString *)animationID
                       finished:(id)finished
                        context:(void *)context;
#ifdef ACCOUNTCHECK
- (void)diagAccountCheck;
#endif
#ifdef TABSCHECK
- (void)diagTabHit;
- (void)diagTabAfter;
#endif
#ifdef GALLERY
- (void)galleryList;
- (void)galleryOpenDetail;
- (void)galleryScrollComments;
- (void)galleryDetailShot;
- (void)galleryCloseDetail;
- (void)galleryPanel;
- (void)galleryPanelShot;
- (void)galleryShot:(NSString *)path;
#endif
#ifdef COMMENTCHECK
- (void)diagCommentOpen;
- (void)diagCommentPhase1;
- (void)diagCommentMore;
- (void)diagCommentPhase2;
- (void)diagCommentShot;
- (void)diagCommentBottom;
- (void)diagCommentShot2;
- (void)diagCommentDone;
- (void)diagCommentAfterClose;
#endif
- (void)scrollViewDidScroll:(UIScrollView *)scrollView;
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate;
- (void)detailAnimationDidStop:(NSString *)animationID
                     finished:(id)finished
                      context:(void *)context;
@end
