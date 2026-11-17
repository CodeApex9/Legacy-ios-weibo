#import "RootViewController.h"
#import "WeiboStore.h"
#import "ImageLoader.h"
#import "WeiboLogin.h"
#import "WeiboComments.h"
#import "Diag.h"

/*
 * A 版「系统原生蓝」热门流
 *   - 顶部蓝条压到 52pt（20pt 状态栏 + 32pt 条），比原来的 64pt 紧凑
 *   - 分组表格 = 独立圆角白卡；cell 内自定义排版：头像 / 作者 / 正文 / 配图 / 转评赞
 *   - 自己实现下拉刷新（不用 iOS 6 才有的 UIRefreshControl，iOS 5 也能跑）
 *   - 详情用 beginAnimations/commitAnimations 从右滑入 + 背景压暗，关闭反向滑出
 *   - 图片异步下载，完成只精确刷新可见 cell，不整表 reloadData
 *
 * 所有状态为文件级 C 静态变量，不用 ObjC ivar（见 AppDelegate.m 顶部说明）。
 * 枚举值写数字，避免 iOS 5~9 SDK 头差异：
 *   UITableViewStyleGrouped = 1, UITableViewCellStyleSubtitle = 3
 */

#define kNavHeight      52.0f
#define kRefreshHeight  60.0f
#define kPhotoSize      80.0f
#define kThumbSize      76.0f      /* 九宫格单图边长 */
#define kThumbGap       6.0f
#define kPhotoBaseTag   200        /* 200..208 缩略图，300..308 点击按钮 */
#define kPhotoBtnBase   300
#define kMaxThumbs      9
#define kLoadMoreHeight 44.0f

#define kTagAvatar 101
#define kTagAuthor 102
#define kTagBody   103
#define kTagPhoto  104
#define kTagStats  105

static UITableView  *sTableView = nil;
static UILabel      *sStatusLabel = nil;
static UILabel      *sAccountLabel = nil;
static UIImageView  *sAccountAvatar = nil;   /* 已登录：左上角圆形头像 */
static UIButton     *sAccountHit = nil;      /* 账号区点击热区 */
/* 账号详情左侧滑出面板 */
static UIView       *sAccountPanel = nil;
static UIView       *sAccountShade = nil;
static UIImageView  *sAccountBigAvatar = nil;
static UILabel      *sAccountName = nil;
static int           sAccountAnimating = 0;
static UISegmentedControl *sSegment = nil;
/* tab 皮肤：深蓝槽 + 亮蓝浮块，独立视图垫在 sSegment 下方（控件本身透明） */
static UIImageView  *sSegGroove = nil;
static UIImageView  *sSegBlock = nil;
static NSArray      *sPosts = nil;
static id            sSelf = nil;

static UIView       *sRefreshHeader = nil;
static UILabel      *sRefreshLabel = nil;
static UIActivityIndicatorView *sRefreshSpinner = nil;
static int           sRefreshState = 0;      /* 0 常态 1 下拉 2 松开可刷新 3 加载中 */

/* 上拉加载更多：底部 footer */
static UIView       *sLoadMoreFooter = nil;
static UILabel      *sLoadMoreLabel = nil;
static UIActivityIndicatorView *sLoadMoreSpinner = nil;
static int           sLoadMoreTriggered = 0;  /* 防止一次滚动重复触发 */

/* 图片全屏查看器 */
static UIView       *sViewerOverlay = nil;
static UIImageView  *sViewerImage = nil;
static UILabel      *sViewerPage = nil;
static NSArray      *sViewerURLs = nil;      /* 大图 URL 数组 */
static NSUInteger    sViewerIndex = 0;
static NSUInteger    sViewerRow = 0;         /* 来自哪条微博 */
static CGFloat       sViewerScale = 1.0f;    /* 查看器当前缩放 */
static CGPoint       sViewerPan = {0, 0};  /* 放大后的平移 */
static CGFloat       sViewerPinchBase = 1.0f;         /* 捏合起始倍数 */

static void SetLoadMoreLabel(void);

/* RoundView 定义在下方，这里先声明（C 需先见声明） */
static void RoundView(UIView *view, CGFloat radius);

/* 方案 A 三个 tab 皮肤。
   做法：UISegmentedControl 只负责文字与点击（背景全透明），
   深蓝槽(sSegGroove) + 亮蓝浮块(sSegBlock) 是两个独立 UIImageView，
   垫在控件下方。块的位置由 layoutSegmentBlock 按选中段计算——
   这样四边留缝和圆角完全可控，不受系统绘制分段背景图的规则干扰。 */
static void ApplySegmentSkin(UISegmentedControl *seg)
{
    /* 透明底图：让系统不再画默认的灰底/分隔线 */
    UIImage *clear = [UIImage imageNamed:@"SegDivider"];   /* 1x1 全透明 RGBA */
    if (clear) {
        [seg setBackgroundImage:clear
                       forState:kControlStateNormal barMetrics:kBarMetricsDefault];
        [seg setBackgroundImage:clear
                       forState:kControlStateSelected barMetrics:kBarMetricsDefault];
        [seg setBackgroundImage:clear
                       forState:kControlStateHighlighted barMetrics:kBarMetricsDefault];
        /* 补全所有左右状态组合，否则未覆盖的组合会落回系统默认深色分隔线 */
        {
            const NSInteger st[3] = { kControlStateNormal,
                                      kControlStateSelected,
                                      kControlStateHighlighted };
            int li, ri;
            for (li = 0; li < 3; li++) {
                for (ri = 0; ri < 3; ri++) {
                    [seg setDividerImage:clear
                     forLeftSegmentState:st[li] rightSegmentState:st[ri]
                              barMetrics:kBarMetricsDefault];
                }
            }
        }
    }

    UIColor *dimText = [UIColor colorWithRed:0.82f green:0.89f blue:0.97f alpha:1.0f];
    UIColor *shadow = [UIColor colorWithRed:0.05f green:0.14f blue:0.28f alpha:0.7f];
    NSValue *offset = [NSValue valueWithCGSize:CGSizeMake(0.0f, -1.0f)];
    NSMutableDictionary *attrNormal = [[NSMutableDictionary alloc] init];
    [attrNormal setObject:dimText forKey:kUITextAttributeTextColor];
    [attrNormal setObject:shadow forKey:kUITextAttributeTextShadowColor];
    [attrNormal setObject:offset forKey:kUITextAttributeTextShadowOffset];
    [seg setTitleTextAttributes:attrNormal forState:kControlStateNormal];
    [attrNormal release];

    NSMutableDictionary *attrSelected = [[NSMutableDictionary alloc] init];
    [attrSelected setObject:[UIColor whiteColor] forKey:kUITextAttributeTextColor];
    [attrSelected setObject:shadow forKey:kUITextAttributeTextShadowColor];
    [attrSelected setObject:offset forKey:kUITextAttributeTextShadowOffset];
    [seg setTitleTextAttributes:attrSelected forState:kControlStateSelected];
    [attrSelected release];
}

/* 按当前选中段，把亮蓝块移到该段位置（块四边留缝由图片透明边自动形成）。
   段宽 = 控件宽/3，控件 frame 已知，纯算术，不动布局。 */
static void layoutSegmentBlock(void)
{
    CGRect f;
    CGFloat segW;
    NSInteger idx;
    if (!sSegment || !sSegBlock) return;
    f = [sSegment frame];
    segW = CGRectGetWidth(f) / 3.0f;
    idx = [sSegment selectedSegmentIndex];
    if (idx < 0 || idx > 2) idx = 0;
    [sSegBlock setFrame:CGRectMake(f.origin.x + segW * (CGFloat)idx,
                                   f.origin.y, segW, CGRectGetHeight(f))];
}

/* 加载提示跟当前 tab 联动：热门 / 关注 / 我的 */
static NSString *LoadingText(void)
{
    return [NSString stringWithFormat:@"正在加载%@微博…", WeiboStoreFeedName()];
}

/* app 内扫码登录弹层 */
static UIView       *sLoginOverlay = nil;
static UIImageView  *sQRImageView = nil;
static UILabel      *sLoginLabel = nil;
static UIButton     *sLoginButton = nil;

static UIView       *sDetailOverlay = nil;
static UIView       *sShadeView = nil;
static UIImageView  *sDetailAvatar = nil;
static NSUInteger    sDetailIndex = 0;
static int           sDetailAnimating = 0;   /* 1 滑入中 2 滑出中 */
/* 详情多图九宫格：大图数组 + 9 个缩略图/按钮（和主界面同款布局） */
static NSArray      *sDetailURLs = nil;         /* 大图 URL（查看器用） */
static UIImageView  *sDetailThumbs[kMaxThumbs] = {0};
static UIButton     *sDetailThumbBtns[kMaxThumbs] = {0};
static NSUInteger    sDetailThumbCount = 0;
#define kDetailThumbTag   400
#define kDetailThumbBtn   500

/* 正文页底部评论区：白卡 + 内容层。内容层每次重建（UIView 未暴露 subviews，
   无法逐个子视图清理），重建成本只有十几~几十个 label，iPhone 5 上无压力。 */
static UIScrollView *sDetailScroll = nil;
static UIView       *sCommentWrap = nil;
static UIView       *sCommentBody = nil;
static CGFloat       sDetailCardW = 0.0f;
static CGFloat       sDetailCardH = 0.0f;
static NSString     *sCommentMid = nil;      /* 当前正文的微博 id（重试用） */
#define kCommentAvatarTag 800
static int           sFirstDataArrived = 0;
#ifdef SHOTCHECK
static int           sShotDone = 0;
static int           sShotScheduled = 0;
#endif
#ifdef FRIENDSCHECK
static int           sFeedChkPhase = 0;    /* 0=热门 1=关注 */
static int           sFeedChkStage = 0;    /* 0=待上拉 1=待统计 */
static int           sFeedChkBefore = 0;
static int           sFeedChkSwitched = 0;
static int           sFeedChkSeenLoading = 0;
#endif
#ifdef COMMENTCHECK
static int           sCommentChkStage = 0;
#endif
#ifdef GALLERY
static int           sGalleryStage = 0;
#endif

#ifdef LEGACY_DIAG
static int           sAutoRefreshDone = 0;
static int           sAutoDetailDone = 0;
#endif
#ifdef LEGACY_UI_EXTRA
static int           sAutoExtraLoadMore = 0;
static int           sAutoExtraViewer = 0;
static int           sAutoExtraSwitched = 0;
static int           sAutoExtraFeedDone = 0;
#endif

typedef struct {
    CGFloat height;
    CGFloat bodyH;
    CGFloat photoY;
    CGFloat statsY;
    int     hasPhoto;
    int     photoCount;    /* 缩略图张数 0..9 */
    int     photoRows;     /* 九宫格行数 */
    CGFloat photoH;        /* 图片区总高度 */
} CellLayout;

/* 取一条微博的图片 URL 数组（列表缩略图） */
static NSArray *PhotosOfPost(NSDictionary *post)
{
    id arr = post ? [post objectForKey:@"photos"] : nil;
    if (!arr || ![arr isKindOfClass:[NSArray class]]) return nil;
    if ([arr count] == 0) return nil;
    return (NSArray *)arr;
}

/* 按 UTF-8 长度估算换行数：中文算 1 个字符宽、ASCII 算 0.55，
   iOS 5/6 上没有可靠的 sizeWithFont 声明可用，纯 C 估算最稳。 */
static int CountLines(NSString *text, CGFloat width, CGFloat fontSize, int maxLines)
{
    const char *p = text ? [text UTF8String] : (const char *)0;
    CGFloat perLine = width / fontSize;
    CGFloat cur = 0.0f;
    int lines = 1;
    if (!p) return 1;
    while (*p) {
        unsigned char c = (unsigned char)*p;
        if (c == '\n') { lines++; cur = 0.0f; p += 1; }
        else if (c >= 0xF0) { cur += 1.0f; p += 4; }
        else if (c >= 0xE0) { cur += 1.0f; p += 3; }
        else if (c >= 0xC0) { cur += 0.7f; p += 2; }
        else                { cur += 0.55f; p += 1; }
        if (cur >= perLine) { lines++; cur = 0.0f; }
        if (maxLines > 0 && lines >= maxLines) return maxLines;
    }
    return lines;
}

static CellLayout LayoutForPost(NSDictionary *post, CGFloat cellW)
{
    CellLayout L;
    CGFloat textW = cellW - 60.0f - 12.0f;
    NSString *text  = [post objectForKey:@"text"];
    NSString *thumb = [post objectForKey:@"thumb"];
    NSArray *photos;
    int lines, cols;

    photos = PhotosOfPost(post);
    L.photoCount = photos ? (int)[photos count] : 0;
    if (L.photoCount == 0 && thumb && [thumb length] > 0) L.photoCount = 1;
    L.hasPhoto = L.photoCount > 0 ? 1 : 0;

    /* 九宫格：1 张大图(用 kPhotoSize)；2~4 张两列；5~9 张三列。
       行数用查表，避免除法符号 __udivsi3（mini libSystem 没有）。 */
    if (L.photoCount <= 1) {
        L.photoRows = 1;
        L.photoH = kPhotoSize;
    } else {
        static const signed char rows2[10] = {0,1,1,2,2,3,3,4,4,5};
        static const signed char rows3[10] = {0,1,1,1,2,2,2,3,3,3};
        cols = (L.photoCount <= 4) ? 2 : 3;
        if (cols == 2) L.photoRows = rows2[L.photoCount <= 9 ? L.photoCount : 9];
        else           L.photoRows = rows3[L.photoCount <= 9 ? L.photoCount : 9];
        L.photoH = (CGFloat)L.photoRows * kThumbSize
                 + (CGFloat)(L.photoRows - 1) * kThumbGap;
    }

    lines = CountLines(text, textW, 14.0f, L.hasPhoto ? 2 : 3);
    L.bodyH   = (CGFloat)lines * 19.3f;
    L.photoY  = 32.0f + L.bodyH + 7.0f;
    L.statsY  = L.hasPhoto ? (L.photoY + L.photoH + 7.0f)
                           : (32.0f + L.bodyH + 6.0f);
    L.height  = L.statsY + 18.0f + 11.0f;
    return L;
}

/* CALayer 只通过消息发送设置圆角，不需要额外链接 QuartzCore */
static void RoundView(UIView *view, CGFloat radius)
{
    LegacyLayerShim *layer = (LegacyLayerShim *)[view layer];
    if (!layer) return;
    [layer setCornerRadius:radius];
    [layer setMasksToBounds:YES];
}

/* 统一页面底色：亚麻贴图平铺（8pt 循环）。三个界面共用同一个函数，
   避免列表 / 正文 / 账号面板各自写死色值后出现色差。 */
static UIColor *LinenColor(void)
{
    UIImage *tex = [UIImage imageNamed:@"Linen"];
    if (tex) return [UIColor colorWithPatternImage:tex];
    return [UIColor colorWithRed:0.93f green:0.92f blue:0.90f alpha:1.0f];
}

/* V0.3 拟物皮肤：给容器加一圈内嵌虚线缝线。
   缝线不能画进九宫格底图（中间段拉伸会把虚线拉长），所以做成 1pt 高的
   可平铺贴图，用 colorWithPatternImage 铺在四条细视图上——任意长度都是
   等距 3pt 实 / 3pt 虚，和 iOS 5 的皮革缝线观感一致。 */
static void AddStitchBorder(UIView *host, CGFloat inset)
{
    UIImage *h = [UIImage imageNamed:@"StitchH"];
    UIImage *v = [UIImage imageNamed:@"StitchV"];
    CGRect b;
    CGFloat w, hh;
    UIView *top, *bottom, *left, *right;

    if (!host || !h || !v) return;
    b = [host bounds];
    w = CGRectGetWidth(b);
    hh = CGRectGetHeight(b);
    if (w < inset * 2.0f + 10.0f || hh < inset * 2.0f + 10.0f) return;

    top = [[UIView alloc] initWithFrame:CGRectMake(inset, inset, w - inset * 2.0f, 1.0f)];
    bottom = [[UIView alloc] initWithFrame:CGRectMake(inset, hh - inset - 1.0f,
                                                      w - inset * 2.0f, 1.0f)];
    left = [[UIView alloc] initWithFrame:CGRectMake(inset, inset + 3.0f, 1.0f,
                                                    hh - inset * 2.0f - 6.0f)];
    right = [[UIView alloc] initWithFrame:CGRectMake(w - inset - 1.0f, inset + 3.0f, 1.0f,
                                                     hh - inset * 2.0f - 6.0f)];

    [top setBackgroundColor:[UIColor colorWithPatternImage:h]];
    [bottom setBackgroundColor:[UIColor colorWithPatternImage:h]];
    [left setBackgroundColor:[UIColor colorWithPatternImage:v]];
    [right setBackgroundColor:[UIColor colorWithPatternImage:v]];

    [top setUserInteractionEnabled:NO];
    [bottom setUserInteractionEnabled:NO];
    [left setUserInteractionEnabled:NO];
    [right setUserInteractionEnabled:NO];

    [host addSubview:top];
    [host addSubview:bottom];
    [host addSubview:left];
    [host addSubview:right];
    [top release];
    [bottom release];
    [left release];
    [right release];
}

static NSDictionary *PostAt(NSUInteger idx)
{
    if (sPosts && idx < [sPosts count]) return [sPosts objectAtIndex:idx];
    return nil;
}

/* 图片到达后只更新可见 cell 的头像 + 九宫格，以及详情页/查看器的图。
   避免几十张图触发同样多次 reloadData 造成 iPhone 5 上滚动卡顿。 */
static void UpdateVisibleImages(void)
{
    NSArray *cells = sTableView ? [sTableView visibleCells] : nil;
    NSUInteger i, j, n = cells ? [cells count] : 0;
    UIView *cv;
    UIImageView *iv;
    UIImage *img;
    NSArray *photos;

    /* 左上角账号头像：资料头像异步下载完成后刷新（否则一直停在占位图） */
    if (sAccountAvatar && WeiboStoreLoggedIn()) {
        NSDictionary *ap = WeiboStoreProfile();
        NSString *au = ap ? [ap objectForKey:@"avatar"] : nil;
        img = au ? ImageLoaderCachedImage(au) : nil;
        if (img) [sAccountAvatar setImage:img];
    }
    /* 账号详情面板大头像同样刷新 */
    if (sAccountBigAvatar && WeiboStoreLoggedIn()) {
        NSDictionary *ap = WeiboStoreProfile();
        NSString *au = ap ? [ap objectForKey:@"avatar"] : nil;
        img = au ? ImageLoaderCachedImage(au) : nil;
        if (img) [sAccountBigAvatar setImage:img];
    }

    for (i = 0; i < n; i++) {
        UITableViewCell *cell = (UITableViewCell *)[cells objectAtIndex:i];
        NSIndexPath *ip = [sTableView indexPathForCell:cell];
        NSDictionary *post = ip ? PostAt((NSUInteger)[ip section]) : nil;
        UIImageView *av;
        if (!post) continue;
        cv = [cell contentView];
        av = (UIImageView *)[cv viewWithTag:kTagAvatar];
        img = ImageLoaderCachedImage([post objectForKey:@"avatar"]);
        if (img && av) [av setImage:img];

        photos = PhotosOfPost(post);
        if (!photos) {
            /* 单图槽位现在是 kPhotoBaseTag(200)，不是旧的 kTagPhoto(104)。
               用错 tag 会导致单图下载完成后永远显示灰色占位图。 */
            iv = (UIImageView *)[cv viewWithTag:kPhotoBaseTag];
            img = ImageLoaderCachedImage([post objectForKey:@"thumb"]);
            if (img && iv) [iv setImage:img];
            continue;
        }
        for (j = 0; j < [photos count] && j < kMaxThumbs; j++) {
            iv = (UIImageView *)[cv viewWithTag:(kPhotoBaseTag + (NSInteger)j)];
            img = ImageLoaderCachedImage([photos objectAtIndex:j]);
            if (img && iv) [iv setImage:img];
        }
    }

    if (sDetailOverlay) {
        NSDictionary *post = PostAt(sDetailIndex);
        if (post && sDetailAvatar) {
            img = ImageLoaderCachedImage([post objectForKey:@"avatar"]);
            if (img) [sDetailAvatar setImage:img];
        }
        /* 详情九宫格：每张缩略图按各自 URL 异步刷新 */
        if (sDetailThumbCount > 0) {
            NSUInteger k, kn = sDetailThumbCount > [sDetailURLs count]
                             ? [sDetailURLs count] : sDetailThumbCount;
            for (k = 0; k < kn; k++) {
                img = ImageLoaderCachedImage([sDetailURLs objectAtIndex:k]);
                if (img && sDetailThumbs[k]) [sDetailThumbs[k] setImage:img];
            }
        }
        /* 评论头像：按 tag 精确刷新，不重建评论区（重建会丢滚动位置） */
        if (sCommentBody) {
            NSArray *cl = WeiboCommentsList();
            NSUInteger ci, cn = cl ? [cl count] : 0;
            for (ci = 0; ci < cn; ci++) {
                NSString *u = [[cl objectAtIndex:ci] objectForKey:@"avatar"];
                UIImageView *cv;
                if (!u) continue;
                cv = (UIImageView *)[sCommentBody viewWithTag:(kCommentAvatarTag + (NSInteger)ci)];
                if (!cv) continue;
                img = ImageLoaderCachedImage(u);
                if (img) [cv setImage:img];
            }
        }
    }
    if (sViewerOverlay && sViewerImage && sViewerIndex < [sViewerURLs count]) {
        img = ImageLoaderCachedImage([sViewerURLs objectAtIndex:sViewerIndex]);
        if (img) [sViewerImage setImage:img];
    }
}

static void SetRefreshState(int state)
{
    sRefreshState = state;
    if (state == 2) diag("UI: refresh state 2 (release to refresh)");
    if (state == 3) diag("UI: refresh state 3 (loading)");
    if (!sRefreshLabel) return;
    if (state == 2)       [sRefreshLabel setText:@"松开立即刷新"];
    else if (state == 3)  [sRefreshLabel setText:LoadingText()];
    else                  [sRefreshLabel setText:@"下拉可以刷新"];
    if (state == 3) [sRefreshSpinner startAnimating];
    else            [sRefreshSpinner stopAnimating];
}

static void EndRefresh(void)
{
    if (sRefreshState != 3) return;
    sRefreshState = 0;
    diag("UI: EndRefresh, inset restored");
    [sRefreshSpinner stopAnimating];
    [sRefreshLabel setText:@"下拉可以刷新"];
    [UIView beginAnimations:@"refreshEnd" context:(void *)0];
    [UIView setAnimationDuration:0.30];
    [UIView setAnimationCurve:kAnimationCurveEaseInOut];
    [sTableView setContentInset:UIEdgeInsetsMake(0, 0, 0, 0)];
    [UIView commitAnimations];
}

static void BeginRefresh(void)
{
    if (WeiboStoreState() == 1 || sRefreshState == 3) return;
    diag("UI: BeginRefresh -> WeiboStoreLoad");
    SetRefreshState(3);
    [UIView beginAnimations:@"refreshBegin" context:(void *)0];
    [UIView setAnimationDuration:0.25];
    [UIView setAnimationCurve:kAnimationCurveEaseInOut];
    [sTableView setContentInset:UIEdgeInsetsMake(kRefreshHeight, 0, 0, 0)];
    [UIView commitAnimations];
    WeiboStoreLoad();
}

static void ReloadTable(void)
{
    int state = WeiboStoreState();
    sPosts = WeiboStorePosts();
    if (sTableView && [sTableView contentOffset].y > 5.0f)
        diag("UI: reload with POSITIVE contentOffset (list was scrolled)");
    else
        diag("UI: reload with zero/negative contentOffset");
    if (state != 1) EndRefresh();
    /* 首批数据到达时把列表拉回顶部：SpringBoard 快照/前后台恢复有时会留下
       一个非零 contentOffset，会让第一条卡片的上半截藏在导航条后面。 */
    if (state == 2 && !sFirstDataArrived) {
        sFirstDataArrived = 1;
        if (sTableView && sRefreshState != 3)
            [sTableView setContentOffset:CGPointMake(0, 0) animated:NO];
    }
    if (sTableView) [sTableView reloadData];
    SetLoadMoreLabel();
    if (state != 1) sLoadMoreTriggered = 0;   /* 一页加载完成后允许再次触发 */
    if (!sStatusLabel) return;

    if (state == 1) {
        [sStatusLabel setText:LoadingText()];
        [sStatusLabel setHidden:(sRefreshState == 3) ? YES : NO];
    } else if (state == 3) {
        [sStatusLabel setText:WeiboStoreErrorText()];
        [sStatusLabel setHidden:NO];
    } else {
        [sStatusLabel setHidden:YES];
    }

#ifdef SHOTCHECK
    /* 界面截图自检：首屏数据到达后延迟 2s（等图片下载）渲染整屏到 /tmp/legacy_shot.png */
    if (state == 2 && sSelf && !sShotScheduled && [sPosts count] > 0) {
        sShotScheduled = 1;
        [(RootViewController *)sSelf performSelector:@selector(diagTakeScreenshot)
                                          withObject:nil afterDelay:2.0];
    }
#endif

#ifdef GALLERY
    /* 只读采集：等数据真正落地再拍，避免拍到「正在加载」的空白页 */
    if (sSelf && sPosts && [sPosts count] > 0) {
        if (sGalleryStage == 0) {
            sGalleryStage = 1;
        } else if (sGalleryStage == 1 && state == 2 && !WeiboStoreLoadingMore()) {
            sGalleryStage = 2;
            [(RootViewController *)sSelf performSelector:@selector(galleryList)
                                              withObject:nil afterDelay:2.0];
        }
    }
#endif

#ifdef COMMENTCHECK
    /* 评论自检：先确保在热门流（关注流评论普遍很少，压不到翻页），
       拿到数据后自动打开评论最多的那条微博正文。 */
    if (sSelf && sPosts && [sPosts count] > 0) {
        if (sCommentChkStage == 0) {
            sCommentChkStage = 1;
            diag("COMMENTCHECK: switch to feed 0");
            [sSegment setSelectedSegmentIndex:0];
            [(RootViewController *)sSelf feedChanged:nil];
        } else if (sCommentChkStage == 1 && state == 2 && WeiboStoreFeed() == 0) {
            sCommentChkStage = 2;
            [(RootViewController *)sSelf performSelector:@selector(diagCommentOpen)
                                              withObject:nil afterDelay:1.0];
        }
    }
#endif

#ifdef FRIENDSCHECK
    /* 翻页自检：先热门(0) 再关注(1)，各推一次上拉，统计新增与重复。
       覆盖 cards 与 statuses 两条解析路径，确认修复关注流不影响热门。
       用 FRIENDSCHECK=1 启用。 */
    if (sFeedChkPhase < 2) {
        if (WeiboStoreLoadingMore()) {
            sFeedChkSeenLoading = 1;
        } else if (state == 2 && sPosts && [sPosts count] > 0) {
            if (WeiboStoreFeed() != sFeedChkPhase) {
                if (!sFeedChkSwitched) {
                    sFeedChkSwitched = 1;
                    diag([[NSString stringWithFormat:@"FEEDCHECK: switch feed=%d",
                           sFeedChkPhase] UTF8String]);
                    [sSegment setSelectedSegmentIndex:sFeedChkPhase];
                    [(RootViewController *)sSelf feedChanged:nil];
                }
            } else if (sFeedChkStage == 0) {
                sFeedChkStage = 1;
                sFeedChkSeenLoading = 0;
                sFeedChkBefore = (int)[sPosts count];
                diag([[NSString stringWithFormat:@"FEEDCHECK: feed=%d trigger load-more, before=%d",
                       sFeedChkPhase, sFeedChkBefore] UTF8String]);
                [(RootViewController *)sSelf performSelector:@selector(diagAutoLoadMore)
                                                  withObject:nil afterDelay:0.8];
            } else if (sFeedChkSeenLoading) {
                int after = (int)[sPosts count];
                int dup = 0;
                NSUInteger k, n = [sPosts count];
                NSMutableDictionary *seen = [[NSMutableDictionary alloc] init];
                for (k = 0; k < n; k++) {
                    NSString *pid = [[sPosts objectAtIndex:k] objectForKey:@"id"];
                    if (!pid) continue;
                    if ([seen objectForKey:pid]) dup++;
                    else [seen setObject:@"1" forKey:pid];
                }
                [seen release];
                diag([[NSString stringWithFormat:@"FEEDCHECK: OK feed=%d before=%d after=%d new=%d dup=%d",
                       sFeedChkPhase, sFeedChkBefore, after, after - sFeedChkBefore, dup] UTF8String]);
                sFeedChkPhase++;
                sFeedChkStage = 0;
                sFeedChkSwitched = 0;
                sFeedChkSeenLoading = 0;
            }
        }
    }
#endif

#ifdef LEGACY_UI_EXTRA
    /* 扩展交互自检：上拉加载更多 → 数据追加后弹出图片查看器。
       与扫码自检(UI_PROBE)互斥，用 UIEXTRA=1 单独启用。 */
    if (state == 2 && sSelf && sPosts && [sPosts count] > 0) {
#ifdef UIFEED
        /* 先切到指定 tab（编译宏 UIFEED=0/1/2），验证该流的多图与空图卡 */
        if (!sAutoExtraFeedDone) {
            sAutoExtraFeedDone = 1;
            diag("UIEXTRA: auto switch to target feed");
            [(RootViewController *)sSelf diagAutoSwitchFeedTo:(id)(NSInteger)UIFEED];
        } else
#endif
        if (!sAutoExtraLoadMore) {
            sAutoExtraLoadMore = 1;
            diag("UIEXTRA: schedule auto load-more");
            [(RootViewController *)sSelf performSelector:@selector(diagAutoLoadMore)
                                              withObject:nil afterDelay:1.0];
        } else if (!sAutoExtraSwitched) {
            sAutoExtraSwitched = 1;
#ifdef DETAILCHECK
            /* 找第一条多图微博打开详情，验证多图切换与页码 */
            [(RootViewController *)sSelf performSelector:@selector(diagDetailMulti)
                                              withObject:nil afterDelay:1.0];
#elif defined(LEGACY_UI_VIEWER_CHECK) || defined(UIGEST)
            diag("UIEXTRA: load-more done, schedule photo viewer");
            [(RootViewController *)sSelf performSelector:@selector(diagAutoPhoto)
                                              withObject:nil afterDelay:1.2];
#else
            diag("UIEXTRA: load-more done (viewer check off)");
#endif
        }
    }
#endif

#ifdef LEGACY_DIAG
    /* 界面自检：第一次数据到达 -> 模拟一次下拉刷新；刷新后再次成功 -> 自动滑入详情。
       两条交互路径都会写 /tmp/legacy_boot.txt，可 SSH 回读，不依赖触摸模拟。 */
#ifndef LEGACY_UI_EXTRA
    if (state == 2 && sSelf && sPosts && [sPosts count] > 0) {
        if (!sAutoRefreshDone) {
            sAutoRefreshDone = 1;
#ifdef LEGACY_UI_PROBE
            /* app 内扫码登录自检：启动即弹登录层，二维码由手机扫 */
            diag("UI: schedule auto in-app QR login");
            [(RootViewController *)sSelf performSelector:@selector(diagAutoLogin)
                                              withObject:nil afterDelay:0.8];
#else
            diag("UI: schedule auto pull-refresh");
            [(RootViewController *)sSelf performSelector:@selector(diagAutoPull)
                                              withObject:nil afterDelay:0.8];
#endif
        } else if (!sAutoDetailDone) {
            sAutoDetailDone = 1;
            if (WeiboStoreLoggedIn()) {
                /* 已登录时自检重点变成「切到登录流并成功加载」 */
                diag("UI: schedule auto switch to logged-in feed");
                [(RootViewController *)sSelf performSelector:@selector(diagAutoSwitchFeed)
                                                  withObject:nil afterDelay:1.0];
            } else {
                diag("UI: schedule auto detail push");
                [(RootViewController *)sSelf performSelector:@selector(diagAutoDetail)
                                                  withObject:nil afterDelay:1.2];
            }
        }
    }
#endif   /* !LEGACY_UI_EXTRA */
#endif   /* LEGACY_DIAG */
}

static UILabel *MakeLabel(CGRect frame, CGFloat size, BOOL bold, CGFloat gray)
{
    UILabel *label = [[UILabel alloc] initWithFrame:frame];
    [label setFont:bold ? [UIFont boldSystemFontOfSize:size]
                        : [UIFont systemFontOfSize:size]];
    [label setTextColor:[UIColor colorWithRed:gray green:gray blue:gray + 0.03f alpha:1.0f]];
    [label setBackgroundColor:[UIColor clearColor]];
    [label setNumberOfLines:0];
    return label;
}

/* ---------- 正文页底部评论区 ----------
   在正文白卡下方追加一张白色圆角卡：标题行 + 每条评论（头像/昵称/正文/时间·赞/
   前两条二级回复）+ 底部「查看更多评论」。
   评论是异步到的，所以这个函数会被重复调用，每次整块重建内容层并重算
   scroll 的 contentSize —— 只碰详情页自己的 scroll，不动主列表任何状态。 */
static void LayoutComments(void)
{
    NSArray *list;
    NSUInteger i, n;
    int state, loadingMore;
    CGFloat wrapW, padX = 10.0f, avatarW = 26.0f, gap = 8.0f;
    CGFloat textX, textW, y = 0.0f, footerH = 0.0f;
    UIImage *img;

    if (!sCommentWrap) return;          /* 详情页已关闭，回调迟到了 */
    wrapW = sDetailCardW;
    textX = padX + avatarW + gap;
    textW = wrapW - textX - padX;

    if (sCommentBody) { [sCommentBody removeFromSuperview]; sCommentBody = nil; }
    sCommentBody = [[UIView alloc] initWithFrame:CGRectMake(0, 0, wrapW, 0)];
    [sCommentBody setBackgroundColor:[UIColor clearColor]];
    [sCommentWrap addSubview:sCommentBody];
    [sCommentBody release];   /* 由 wrap 持有，静态指针只做引用 */

    list = WeiboCommentsList();
    n = list ? [list count] : 0;
    state = WeiboCommentsState();
    loadingMore = WeiboCommentsLoadingMore();

    /* 标题行 */
    {
        UILabel *t = MakeLabel(CGRectMake(padX, 8.0f, 90.0f, 20.0f), 15.0f, YES, 0.16f);
        [t setText:@"评论"];
        [sCommentBody addSubview:t];
        [t release];
    }
    {
        NSString *right = nil;
        if (state == 1) right = @"加载中…";
        else if (n > 0) {
            int total = WeiboCommentsTotal();
            /* total_number 会把已删除/被过滤的评论也算进去，可能大于实际能拿到的；
               没有下一页时按实际条数显示，避免「共 25 条」却只列出 15 条 */
            if (!WeiboCommentsHasMore() || total <= (int)n) total = (int)n;
            right = [NSString stringWithFormat:@"共 %d 条", total];
        }
        if (right) {
            UILabel *r = MakeLabel(CGRectMake(wrapW - padX - 130.0f, 10.0f, 130.0f, 18.0f),
                                   12.0f, NO, 0.50f);
            [r setText:right];
            [sCommentBody addSubview:r];
            [r release];
        }
    }
    {
        UIView *line = [[UIView alloc] initWithFrame:CGRectMake(padX, 31.0f, wrapW - padX * 2.0f, 1.0f)];
        [line setBackgroundColor:[UIColor colorWithRed:0.90f green:0.89f blue:0.87f alpha:1.0f]];
        [sCommentBody addSubview:line];
        [line release];
    }
    y = 32.0f;

    /* 空态 / 失败 / 加载中 */
    if (n == 0 && (state == 1 || state == 4 || state == 3)) {
        UILabel *tip = MakeLabel(CGRectMake(padX, y + 10.0f, wrapW - padX * 2.0f, 20.0f),
                                 13.0f, NO, 0.55f);
        [tip setText:(state == 1 ? @"正在加载评论…"
                       : (state == 4 ? @"还没有人评论"
                                     : (WeiboCommentsErrorText() ? WeiboCommentsErrorText()
                                                                 : @"评论加载失败")))];
        [tip setTextAlignment:kTextAlignCenter];
        [sCommentBody addSubview:tip];
        [tip release];
        y += 44.0f;
        if (state == 3) {
            UIButton *retry = [UIButton buttonWithType:kButtonTypeRounded];
            [retry setFrame:CGRectMake((wrapW - 120.0f) / 2.0f, y, 120.0f, 30.0f)];
            [retry setTitle:@"点击重试" forState:kControlStateNormal];
            [retry setTitleColor:[UIColor colorWithRed:0.15f green:0.35f blue:0.62f alpha:1.0f]
                        forState:kControlStateNormal];
            [[retry titleLabel] setFont:[UIFont boldSystemFontOfSize:13.0f]];
            if (sSelf) [retry addTarget:sSelf action:@selector(commentRetryTapped:)
                      forControlEvents:kControlEventTouchUpInside];
            [sCommentBody addSubview:retry];
            y += 38.0f;
        }
    }

    /* 每条评论 */
    for (i = 0; i < n; i++) {
        NSDictionary *c = [list objectAtIndex:i];
        NSString *text = [c objectForKey:@"text"];
        NSString *name = [c objectForKey:@"name"];
        NSString *when = [c objectForKey:@"time"];
        NSString *avatar = [c objectForKey:@"avatar"];
        NSArray *subs = [c objectForKey:@"subs"];
        id likesObj = [c objectForKey:@"likes"];
        int likes = likesObj ? [likesObj intValue] : 0;
        CGFloat textH = (CGFloat)CountLines(text, textW, 13.0f, 0) * 18.0f;
        CGFloat rowTop = y, metaY, subY, subH = 0.0f;
        UIImageView *av;
        UILabel *lb;

        if (textH < 18.0f) textH = 18.0f;

        av = [[UIImageView alloc] initWithFrame:CGRectMake(padX, rowTop + 10.0f, avatarW, avatarW)];
        [av setContentMode:kContentModeScaleAspectFill];
        [av setClipsToBounds:YES];
        [av setTag:(kCommentAvatarTag + (NSInteger)i)];
        RoundView(av, 4.0f);
        if (avatar) {
            ImageLoaderRequest(avatar);
            img = ImageLoaderCachedImage(avatar);
            [av setImage:img ? img : [UIImage imageNamed:@"Avatar"]];
        } else {
            [av setImage:[UIImage imageNamed:@"Avatar"]];
        }
        [sCommentBody addSubview:av];
        [av release];

        lb = MakeLabel(CGRectMake(textX, rowTop + 8.0f, textW, 17.0f), 12.0f, YES, 0.16f);
        [lb setText:name];
        [sCommentBody addSubview:lb];
        [lb release];

        lb = MakeLabel(CGRectMake(textX, rowTop + 25.0f, textW, textH), 13.0f, NO, 0.20f);
        [lb setText:text];
        [sCommentBody addSubview:lb];
        [lb release];

        metaY = rowTop + 25.0f + textH + 3.0f;
        {
            NSString *meta = (likes > 0)
                ? [NSString stringWithFormat:@"%@    赞 %d", (when ? when : @""), likes]
                : (when ? when : @"");
            lb = MakeLabel(CGRectMake(textX, metaY, textW, 14.0f), 11.0f, NO, 0.55f);
            [lb setText:meta];
            [sCommentBody addSubview:lb];
            [lb release];
        }

        subY = metaY + 15.0f;
        if (subs && [subs count] > 0) {
            NSUInteger sIdx, sCnt = [subs count];
            CGFloat sy = subY + 6.0f;
            UIView *box;
            for (sIdx = 0; sIdx < sCnt; sIdx++) {
                NSString *st = [subs objectAtIndex:sIdx];
                subH += (CGFloat)CountLines(st, textW - 12.0f, 11.0f, 0) * 15.0f + 3.0f;
            }
            box = [[UIView alloc] initWithFrame:CGRectMake(textX, subY, textW, subH + 8.0f)];
            [box setBackgroundColor:[UIColor colorWithRed:0.955f green:0.95f blue:0.94f alpha:1.0f]];
            RoundView(box, 3.0f);
            [sCommentBody addSubview:box];
            for (sIdx = 0; sIdx < sCnt; sIdx++) {
                NSString *st = [subs objectAtIndex:sIdx];
                CGFloat lh = (CGFloat)CountLines(st, textW - 12.0f, 11.0f, 0) * 15.0f;
                UILabel *sl = MakeLabel(CGRectMake(6.0f, sy - subY, textW - 12.0f, lh),
                                        11.0f, NO, 0.38f);
                [sl setText:st];
                [box addSubview:sl];
                [sl release];
                sy += lh + 3.0f;
            }
            [box release];
            subH += 8.0f;
        }

        y = rowTop + 25.0f + textH + 15.0f + subH + 10.0f;
        /* 分隔线（最后一条不画，避免压着底边） */
        if (i + 1 < n) {
            UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(padX, y, wrapW - padX * 2.0f, 1.0f)];
            [sep setBackgroundColor:[UIColor colorWithRed:0.92f green:0.91f blue:0.90f alpha:1.0f]];
            [sCommentBody addSubview:sep];
            [sep release];
        }
    }

    /* 底部：查看更多评论 */
    if (n > 0 && (WeiboCommentsHasMore() || loadingMore)) {
        UIButton *more = [UIButton buttonWithType:kButtonTypeRounded];
        [more setFrame:CGRectMake(0, y, wrapW, 40.0f)];
        [more setTitle:(loadingMore ? @"正在加载…" : @"查看更多评论") forState:kControlStateNormal];
        [more setTitleColor:[UIColor colorWithRed:0.35f green:0.35f blue:0.35f alpha:1.0f]
                   forState:kControlStateNormal];
        [[more titleLabel] setFont:[UIFont boldSystemFontOfSize:13.0f]];
        if (sSelf && !loadingMore)
            [more addTarget:sSelf action:@selector(commentMoreTapped:)
          forControlEvents:kControlEventTouchUpInside];
        [sCommentBody addSubview:more];
        footerH = 40.0f;
    }

    {
        CGFloat bodyH = y + footerH + 8.0f;
        CGFloat wrapY = 10.0f + sDetailCardH + 10.0f;
        [sCommentBody setFrame:CGRectMake(0, 0, wrapW, bodyH)];
        [sCommentWrap setFrame:CGRectMake(10.0f, wrapY, wrapW, bodyH)];
        if (sDetailScroll) {
            CGFloat w = CGRectGetWidth([[UIScreen mainScreen] bounds]);
            [sDetailScroll setContentSize:CGSizeMake(w, wrapY + bodyH + 20.0f)];
        }
    }
}

@implementation RootViewController

- (void)loadView
{
    CGRect bounds = [[UIScreen mainScreen] bounds];
    CGFloat w = CGRectGetWidth(bounds);
    CGFloat h = CGRectGetHeight(bounds);
    CGFloat navH = kNavHeight;

    /* 必须先读登录态，导航条上的账号名与 tab 名都依赖它 */
    WeiboStoreInitLogin();

    UIView *rootView = [[UIView alloc] initWithFrame:bounds];
    [rootView setBackgroundColor:LinenColor()];
    [self setView:rootView];
    [rootView release];

    /* 蓝色渐变导航条：位图由 scripts/make_assets.py 按 52pt 预渲染 */
    UIImageView *navBg = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, w, navH)];
    [navBg setImage:[UIImage imageNamed:@"NavBar"]];
    [[self view] addSubview:navBg];
    [navBg release];

    /* 左侧账号区：未登录显示「登录」按钮（点扫码），已登录显示圆形头像
       （点账号详情从左侧滑出）。52pt 蓝条内 h=30 → y=11 垂直居中。 */
    sAccountLabel = [[UILabel alloc] initWithFrame:CGRectMake(4.0f, 13.0f, 60.0f, 26.0f)];
    [sAccountLabel setText:@"登录"];
    [sAccountLabel setFont:[UIFont systemFontOfSize:14.0f]];
    [sAccountLabel setTextColor:[UIColor whiteColor]];
    [sAccountLabel setTextAlignment:kTextAlignCenter];
    [sAccountLabel setBackgroundColor:[UIColor clearColor]];
    [sAccountLabel setNumberOfLines:1];
    [[self view] addSubview:sAccountLabel];

    sAccountAvatar = [[UIImageView alloc] initWithFrame:CGRectMake(9.0f, 13.0f, 26.0f, 26.0f)];
    [sAccountAvatar setContentMode:kContentModeScaleAspectFill];
    [sAccountAvatar setClipsToBounds:YES];
    RoundView(sAccountAvatar, 13.0f);
    [sAccountAvatar setHidden:YES];
    [[self view] addSubview:sAccountAvatar];

    sAccountHit = [UIButton buttonWithType:kButtonTypeRounded];
    [sAccountHit setFrame:CGRectMake(4.0f, 11.0f, 64.0f, 30.0f)];
    [sAccountHit setTitle:@"" forState:kControlStateNormal];
    [sAccountHit addTarget:self action:@selector(accountTapped:)
     forControlEvents:kControlEventTouchUpInside];
    [[self view] addSubview:sAccountHit];

    WeiboStoreSetProfileCallback(ProfileChanged);
    [self refreshAccountArea];
    if (WeiboStoreLoggedIn()) WeiboStoreFetchProfile();

    /* 中间：热门 / 关注 / 我的 三段。UISegmentedControl 从 iOS 5 就有，
       UIKit.tbd 已登记类符号，无需额外链接。 */
    NSArray *tabs = [NSArray arrayWithObjects:@"热门", @"关注", @"我的", nil];
    CGRect segFrame = CGRectMake(68.0f, 12.0f, w - 136.0f, 28.0f);

    /* 深蓝槽：独立视图垫底，圆角矩形（方案 A 的凹槽） */
    sSegGroove = [[UIImageView alloc] initWithFrame:segFrame];
    [sSegGroove setImage:[UIImage imageNamed:@"SegNormal"]];
    [sSegGroove setContentMode:kContentModeScaleToFill];
    [sSegGroove setBackgroundColor:[UIColor colorWithRed:0.14f green:0.29f blue:0.49f alpha:1.0f]];
    RoundView(sSegGroove, 6.0f);
    [[self view] addSubview:sSegGroove];
    [sSegGroove release];

    /* 亮蓝浮块：四边留缝、独立圆角，位置随选中段移动 */
    sSegBlock = [[UIImageView alloc] initWithFrame:segFrame];
    [sSegBlock setImage:[UIImage imageNamed:@"SegBlock"]];
    [sSegBlock setContentMode:kContentModeScaleToFill];
    [[self view] addSubview:sSegBlock];
    [sSegBlock release];

    sSegment = [[UISegmentedControl alloc] initWithItems:tabs];
    [sSegment setFrame:segFrame];
    [sSegment setSegmentedControlStyle:kSegmentedStyleBar];
    [sSegment setSelectedSegmentIndex:0];
    [sSegment addTarget:self action:@selector(feedChanged:)
      forControlEvents:kControlEventValueChanged];
    ApplySegmentSkin(sSegment);  /* 方案 A 立体皮肤：控件透明，只留文字 */
    layoutSegmentBlock();        /* 浮块定位到第 0 段 */
    [[self view] addSubview:sSegment];

    /* 右侧原「刷新」按钮已移除（用户要求）。刷新仍可用下拉手势触发，
       refreshTapped: 保留不删，避免影响其他调用点。 */

    /* 分组表格：灰亚麻底 + 圆角白卡，cell 必须复用（512MB 内存） */
    sTableView = [[UITableView alloc]
                   initWithFrame:CGRectMake(0, navH, w, h - navH)
                           style:1];
    [sTableView setDataSource:self];
    [sTableView setDelegate:self];
    [sTableView setRowHeight:120.0f];

    /* 亚麻底：分组表默认会铺 iOS 自带的浅蓝灰条纹，和 V0.3 的米色纸卡不搭。
       backgroundView 与 backgroundColor 双保险——不同系统版本对 grouped
       表背景的绘制路径不一致，只设一个可能仍露出系统条纹。 */
    {
        UIColor *linenColor = LinenColor();
        UIView *bg;
        [sTableView setBackgroundColor:linenColor];
        bg = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, h - navH)];
        [bg setBackgroundColor:linenColor];
        [sTableView setBackgroundView:bg];
        [bg release];
    }

    [[self view] addSubview:sTableView];

    /* 下拉刷新头：作为 tableView 的子视图放在内容区上方（负 y），随拖动露出。
       不用 UIRefreshControl —— 那是 iOS 6 新增，iOS 5 会直接找不到类。 */
    sRefreshHeader = [[UIView alloc]
                      initWithFrame:CGRectMake(0, -kRefreshHeight, w, kRefreshHeight)];
    [sRefreshHeader setBackgroundColor:[UIColor clearColor]];
    [sTableView addSubview:sRefreshHeader];

    sRefreshSpinner = [[UIActivityIndicatorView alloc]
                       initWithActivityIndicatorStyle:kIndicatorStyleGray];
    [sRefreshSpinner setFrame:CGRectMake(w / 2.0f - 74.0f, 21.0f, 20.0f, 20.0f)];
    [sRefreshSpinner setHidesWhenStopped:YES];
    [sRefreshHeader addSubview:sRefreshSpinner];

    sRefreshLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 20.0f, w, 22.0f)];
    [sRefreshLabel setText:@"下拉可以刷新"];
    [sRefreshLabel setFont:[UIFont systemFontOfSize:13.0f]];
    [sRefreshLabel setTextColor:[UIColor colorWithRed:0.38f green:0.39f blue:0.42f alpha:1.0f]];
    [sRefreshLabel setTextAlignment:kTextAlignCenter];
    [sRefreshLabel setBackgroundColor:[UIColor clearColor]];
    [sRefreshHeader addSubview:sRefreshLabel];

    /* 上拉加载更多 footer：放在表格内容区底部，随滚动露出 */
    sLoadMoreFooter = [[UIView alloc]
                       initWithFrame:CGRectMake(0, 0, w, kLoadMoreHeight)];
    [sLoadMoreFooter setBackgroundColor:[UIColor clearColor]];
    sLoadMoreSpinner = [[UIActivityIndicatorView alloc]
                        initWithActivityIndicatorStyle:kIndicatorStyleGray];
    [sLoadMoreSpinner setFrame:CGRectMake(w / 2.0f - 66.0f, 12.0f, 20.0f, 20.0f)];
    [sLoadMoreSpinner setHidesWhenStopped:YES];
    [sLoadMoreFooter addSubview:sLoadMoreSpinner];
    sLoadMoreLabel = [[UILabel alloc]
                      initWithFrame:CGRectMake(0, 11.0f, w, 22.0f)];
    [sLoadMoreLabel setText:@"上拉加载更多"];
    [sLoadMoreLabel setFont:[UIFont systemFontOfSize:13.0f]];
    [sLoadMoreLabel setTextColor:[UIColor colorWithRed:0.38f green:0.39f blue:0.42f alpha:1.0f]];
    [sLoadMoreLabel setTextAlignment:kTextAlignCenter];
    [sLoadMoreLabel setBackgroundColor:[UIColor clearColor]];
    [sLoadMoreFooter addSubview:sLoadMoreLabel];
    [sTableView setTableFooterView:sLoadMoreFooter];
    [sLoadMoreFooter release];

    sStatusLabel = [[UILabel alloc]
                    initWithFrame:CGRectMake(20.0f, navH + 60.0f, w - 40.0f, 60.0f)];
    [sStatusLabel setText:LoadingText()];
    [sStatusLabel setFont:[UIFont systemFontOfSize:14.0f]];
    [sStatusLabel setTextColor:[UIColor colorWithRed:0.35f green:0.35f blue:0.38f alpha:1.0f]];
    [sStatusLabel setTextAlignment:kTextAlignCenter];
    [sStatusLabel setBackgroundColor:[UIColor clearColor]];
    [sStatusLabel setNumberOfLines:2];
    [[self view] addSubview:sStatusLabel];

    sSelf = self;
    WeiboStoreSetUpdateCallback(ReloadTable);
    ImageLoaderSetUpdateCallback(UpdateVisibleImages);
    WeiboStoreLoad();
    diag("RootViewController: loadView finished");
#ifdef ACCOUNTCHECK
    /* 启动即触发账号自检（同步，不依赖 run loop 延迟调度/数据加载） */
    [self diagAccountCheck];
#endif
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    (void)tableView;
    /* 每条微博一个 section，iOS 6 grouped 表格会渲染成独立圆角白卡 */
    return sPosts ? (NSInteger)[sPosts count] : 0;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    (void)section;
    return 1;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSDictionary *post;
    CGFloat w = CGRectGetWidth([[UIScreen mainScreen] bounds]);
    (void)tableView;
    post = PostAt((NSUInteger)[indexPath section]);
    if (!post) return 120.0f;
    return LayoutForPost(post, w - 20.0f).height;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
          cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *cellId = @"PostCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    UIView *cv;
    UIImageView *avatar, *photo;
    UIButton *photoBtn;
    UILabel *author, *body, *stats;
    NSArray *photos;
    NSUInteger pi;
    NSDictionary *post = PostAt((NSUInteger)[indexPath section]);
    CGFloat w = CGRectGetWidth([[UIScreen mainScreen] bounds]);
    CGFloat cellW = w - 20.0f;
    CGFloat textW = cellW - 72.0f;
    CellLayout L = post ? LayoutForPost(post, cellW) : (CellLayout){120.0f, 40.0f, 0, 0, 0};
    UIImage *img;

    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:3
                                      reuseIdentifier:cellId] autorelease];
        cv = [cell contentView];

        avatar = [[UIImageView alloc] initWithFrame:CGRectMake(12.0f, 12.0f, 40.0f, 40.0f)];
        [avatar setTag:kTagAvatar];
        [avatar setContentMode:kContentModeScaleAspectFill];
        [avatar setClipsToBounds:YES];
        [avatar setBackgroundColor:[UIColor colorWithRed:0.88f green:0.88f blue:0.88f alpha:1.0f]];
        RoundView(avatar, 6.0f);
        [cv addSubview:avatar];
        [avatar release];

        author = MakeLabel(CGRectMake(60.0f, 9.0f, textW, 20.0f), 15.0f, YES, 0.16f);
        [author setTag:kTagAuthor];
        [author setNumberOfLines:1];
        [cv addSubview:author];
        [author release];

        body = MakeLabel(CGRectMake(60.0f, 32.0f, textW, 58.0f), 14.0f, NO, 0.13f);
        [body setTag:kTagBody];
        [cv addSubview:body];
        [body release];

        /* 九宫格：预建 9 个 imageView + 9 个透明按钮，按需显示。
           按钮 tag = kPhotoBtnBase + 索引，点击时从按钮 tag 反推行号。 */
        for (pi = 0; pi < kMaxThumbs; pi++) {
            photo = [[UIImageView alloc]
                     initWithFrame:CGRectMake(60.0f, L.photoY, kThumbSize, kThumbSize)];
            [photo setTag:(kPhotoBaseTag + (NSInteger)pi)];
            [photo setContentMode:kContentModeScaleAspectFill];
            [photo setClipsToBounds:YES];
            [photo setBackgroundColor:[UIColor colorWithRed:0.90f green:0.90f blue:0.90f alpha:1.0f]];
            RoundView(photo, 5.0f);
            [photo setHidden:YES];
            [cv addSubview:photo];
            [photo release];

            photoBtn = [UIButton buttonWithType:kButtonTypeRounded];
            [photoBtn setFrame:CGRectMake(60.0f, L.photoY, kThumbSize, kThumbSize)];
            [photoBtn setTag:(kPhotoBtnBase + (NSInteger)pi)];
            [photoBtn setTitle:@"" forState:kControlStateNormal];
            [photoBtn setHidden:YES];
            [photoBtn addTarget:self action:@selector(photoTapped:)
              forControlEvents:kControlEventTouchUpInside];
            [cv addSubview:photoBtn];
        }

        stats = MakeLabel(CGRectMake(60.0f, L.statsY, textW, 18.0f), 12.0f, NO, 0.48f);
        [stats setTag:kTagStats];
        [stats setNumberOfLines:1];
        [cv addSubview:stats];
        [stats release];
    } else {
        cv = [cell contentView];
        avatar = (UIImageView *)[cv viewWithTag:kTagAvatar];
        author = (UILabel *)[cv viewWithTag:kTagAuthor];
        body   = (UILabel *)[cv viewWithTag:kTagBody];
        stats  = (UILabel *)[cv viewWithTag:kTagStats];
    }

    if (!post) return cell;

    [body   setFrame:CGRectMake(60.0f, 32.0f, textW, L.bodyH)];
    [body   setNumberOfLines:L.hasPhoto ? 2 : 3];
    [stats  setFrame:CGRectMake(60.0f, L.statsY, textW, 18.0f)];

    [author setText:[post objectForKey:@"author"]];
    [body   setText:[post objectForKey:@"text"]];
    [stats  setText:[post objectForKey:@"stats"]];

    /* 占位图 -> 缓存图 -> 异步请求；图片到达后由 UpdateVisibleImages 替换 */
    ImageLoaderRequest([post objectForKey:@"avatar"]);
    img = ImageLoaderCachedImage([post objectForKey:@"avatar"]);
    [avatar setImage:img ? img : [UIImage imageNamed:@"Avatar"]];

    photos = PhotosOfPost(post);
    if (!photos) {
        NSString *thumb = [post objectForKey:@"thumb"];
        /* 无图的微博：必须把所有槽位隐藏。cell 是复用的，若不隐藏，
           上一个 cell 的图片槽位会残留并盖住本行的转评赞文字、溢出卡片。 */
        if (!thumb || [thumb length] == 0) {
            for (pi = 0; pi < kMaxThumbs; pi++) {
                [[cv viewWithTag:(kPhotoBaseTag + (NSInteger)pi)] setHidden:YES];
                [[cv viewWithTag:(kPhotoBtnBase + (NSInteger)pi)] setHidden:YES];
            }
            return cell;
        }
        /* 单图（兜底）：九宫格槽位只显示第 0 张，用大图尺寸 */
        photo = (UIImageView *)[cv viewWithTag:kPhotoBaseTag];
        photoBtn = (UIButton *)[cv viewWithTag:kPhotoBtnBase];
        [photo setFrame:CGRectMake(60.0f, L.photoY, kPhotoSize, kPhotoSize)];
        [photoBtn setFrame:CGRectMake(60.0f, L.photoY, kPhotoSize, kPhotoSize)];
        [photo setHidden:NO];
        [photoBtn setHidden:NO];
        for (pi = 1; pi < kMaxThumbs; pi++) {
            [[cv viewWithTag:(kPhotoBaseTag + (NSInteger)pi)] setHidden:YES];
            [[cv viewWithTag:(kPhotoBtnBase + (NSInteger)pi)] setHidden:YES];
        }
        ImageLoaderRequest(thumb);
        img = ImageLoaderCachedImage(thumb);
        [photo setImage:img ? img : [UIImage imageNamed:@"Photo"]];
        return cell;
    }

    /* 九宫格布局：单张用大图尺寸，多张按 L.photoRows 行列排布 */
    {
        int cols = (L.photoCount == 1) ? 1 : (L.photoCount <= 4 ? 2 : 3);
        CGFloat side = (L.photoCount == 1) ? kPhotoSize : kThumbSize;
        /* 行列查表，避免 / 与 %：mini libSystem 没有 __udivsi3。
           索引 = (cols-1)*9 + pi */
        static const signed char RC[54] = {
            /* cols=1: row,col */
            0,0, 1,0, 2,0, 3,0, 4,0, 5,0, 6,0, 7,0, 8,0,
            /* cols=2: 4 张图排 2 行，后 5 个位置用不到，填 0 */
            0,0, 0,1, 1,0, 1,1, 0,0, 0,0, 0,0, 0,0, 0,0,
            /* cols=3 */
            0,0, 0,1, 0,2, 1,0, 1,1, 1,2, 2,0, 2,1, 2,2
        };
        for (pi = 0; pi < (NSUInteger)L.photoCount && pi < kMaxThumbs; pi++) {
            int row = RC[(cols - 1) * 18 + (int)pi * 2];
            int col = RC[(cols - 1) * 18 + (int)pi * 2 + 1];
            CGFloat x = 60.0f + (CGFloat)col * (side + kThumbGap);
            CGFloat y = L.photoY + (CGFloat)row * (side + kThumbGap);
            NSString *u = [photos objectAtIndex:pi];
            photo = (UIImageView *)[cv viewWithTag:(kPhotoBaseTag + (NSInteger)pi)];
            photoBtn = (UIButton *)[cv viewWithTag:(kPhotoBtnBase + (NSInteger)pi)];
            [photo setFrame:CGRectMake(x, y, side, side)];
            [photoBtn setFrame:CGRectMake(x, y, side, side)];
            [photo setHidden:NO];
            [photoBtn setHidden:NO];
            ImageLoaderRequest(u);
            img = ImageLoaderCachedImage(u);
            [photo setImage:img ? img : [UIImage imageNamed:@"Photo"]];
        }
        for (; pi < kMaxThumbs; pi++) {
            [[cv viewWithTag:(kPhotoBaseTag + (NSInteger)pi)] setHidden:YES];
            [[cv viewWithTag:(kPhotoBtnBase + (NSInteger)pi)] setHidden:YES];
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self showDetail:(NSUInteger)[indexPath section]];
}

/* ---------- 图片全屏查看器 ---------- */

- (UIButton *)findPhotoButton:(id)sender
{
    UIButton *btn = (UIButton *)sender;
    if (!btn || ![btn isKindOfClass:[UIButton class]]) return nil;
    return btn;
}

/* 找出点击按钮所在的行：遍历可见 cell 的 contentView */
- (NSUInteger)rowForPhotoButton:(UIButton *)btn
{
    NSArray *cells = sTableView ? [sTableView visibleCells] : nil;
    NSUInteger i, n = cells ? [cells count] : 0;
    for (i = 0; i < n; i++) {
        UITableViewCell *cell = (UITableViewCell *)[cells objectAtIndex:i];
        UIView *hit = [[cell contentView] viewWithTag:[btn tag]];
        if (hit == btn) {
            NSIndexPath *ip = [sTableView indexPathForCell:cell];
            if (ip) return (NSUInteger)[ip section];
        }
    }
    return NSNotFound;
}

- (void)photoTapped:(id)sender
{
    UIButton *btn = [self findPhotoButton:sender];
    NSUInteger idx, row;
    NSDictionary *post;
    NSArray *larges;

    if (!btn) return;
    idx = (NSUInteger)([btn tag] - kPhotoBtnBase);
    row = [self rowForPhotoButton:btn];
    if (row == NSNotFound) return;
    post = PostAt(row);
    if (!post) return;

    /* 大图数组优先用 photoLarges，否则用 photos，最后退回单张 large/thumb */
    larges = [post objectForKey:@"photoLarges"];
    if (!larges || ![larges isKindOfClass:[NSArray class]] || [larges count] == 0)
        larges = [post objectForKey:@"photos"];
    if (!larges || [larges count] == 0) {
        NSString *one = [post objectForKey:@"large"];
        if (!one) one = [post objectForKey:@"thumb"];
        if (!one) return;
        larges = [NSArray arrayWithObject:one];
        idx = 0;
    }
    if (idx >= [larges count]) idx = 0;

    if (sViewerURLs) [sViewerURLs release];
    sViewerURLs = [larges retain];
    sViewerIndex = idx;
    sViewerRow = row;
    [self showPhotoViewer];
}

- (void)showPhotoViewer
{
    CGRect bounds = [[UIScreen mainScreen] bounds];
    CGFloat w = CGRectGetWidth(bounds);
    CGFloat h = CGRectGetHeight(bounds);
    UIImage *img;

    if (sViewerOverlay) return;

    sViewerOverlay = [[UIView alloc] initWithFrame:bounds];
    [sViewerOverlay setBackgroundColor:[UIColor colorWithRed:0.05f green:0.05f blue:0.07f alpha:0.96f]];

    /* 不再整屏点击关闭：只保留右上角关闭按钮。
       左右滑动切图、双击/双指缩放、放大后拖动平移。 */
    sViewerImage = [[UIImageView alloc]
                    initWithFrame:CGRectMake(0, (h - w) / 2.0f, w, w)];
    [sViewerImage setContentMode:kContentModeScaleAspectFit];
    [sViewerImage setBackgroundColor:[UIColor clearColor]];
    [sViewerImage setUserInteractionEnabled:YES];
    [sViewerOverlay addSubview:sViewerImage];

    /* 双击缩放 */
    UITapGestureRecognizer *dbl = [[UITapGestureRecognizer alloc]
                                   initWithTarget:self action:@selector(viewerDoubleTap:)];
    [dbl setNumberOfTapsRequired:2];
    [sViewerImage addGestureRecognizer:dbl];
    [dbl release];
    /* 双指捏合缩放 */
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc]
                                       initWithTarget:self action:@selector(viewerPinch:)];
    [sViewerImage addGestureRecognizer:pinch];
    [pinch release];
    /* 单指拖动：未放大切图，放大后平移 */
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                   initWithTarget:self action:@selector(viewerPan:)];
    [sViewerImage addGestureRecognizer:pan];
    [pan release];

    /* 多图时显示左右切换与页码 */
    if ([sViewerURLs count] > 1) {
        UIButton *prev = [UIButton buttonWithType:kButtonTypeRounded];
        [prev setFrame:CGRectMake(10.0f, h / 2.0f - 20.0f, 44.0f, 40.0f)];
        [prev setTitle:@"‹" forState:kControlStateNormal];
        [prev setTitleColor:[UIColor whiteColor] forState:kControlStateNormal];
        [prev addTarget:self action:@selector(viewerPrev:)
          forControlEvents:kControlEventTouchUpInside];
        [sViewerOverlay addSubview:prev];

        UIButton *next = [UIButton buttonWithType:kButtonTypeRounded];
        [next setFrame:CGRectMake(w - 54.0f, h / 2.0f - 20.0f, 44.0f, 40.0f)];
        [next setTitle:@"›" forState:kControlStateNormal];
        [next setTitleColor:[UIColor whiteColor] forState:kControlStateNormal];
        [next addTarget:self action:@selector(viewerNext:)
          forControlEvents:kControlEventTouchUpInside];
        [sViewerOverlay addSubview:next];

        sViewerPage = [[UILabel alloc]
                       initWithFrame:CGRectMake(w / 2.0f - 60.0f, h - 60.0f, 120.0f, 30.0f)];
        [sViewerPage setTextAlignment:kTextAlignCenter];
        [sViewerPage setFont:[UIFont systemFontOfSize:15.0f]];
        [sViewerPage setTextColor:[UIColor whiteColor]];
        [sViewerPage setBackgroundColor:[UIColor clearColor]];
        [sViewerOverlay addSubview:sViewerPage];
    }

    UIButton *closeBtn = [UIButton buttonWithType:kButtonTypeRounded];
    [closeBtn setFrame:CGRectMake(w - 64.0f, 24.0f, 54.0f, 30.0f)];
    [closeBtn setTitle:@"关闭" forState:kControlStateNormal];
    [closeBtn setTitleColor:[UIColor whiteColor] forState:kControlStateNormal];
    [closeBtn addTarget:self action:@selector(closePhotoViewer:)
      forControlEvents:kControlEventTouchUpInside];
    [sViewerOverlay addSubview:closeBtn];

    [[self view] addSubview:sViewerOverlay];
    [self updateViewerImage];
}

- (void)updateViewerImage
{
    NSString *url;
    UIImage *img;
    if (!sViewerImage || sViewerIndex >= [sViewerURLs count]) return;
    url = [sViewerURLs objectAtIndex:sViewerIndex];
    ImageLoaderRequest(url);
    img = ImageLoaderCachedImage(url);
    [sViewerImage setImage:img ? img : [UIImage imageNamed:@"Photo"]];
    /* 切图时复位缩放与平移 */
    sViewerScale = 1.0f;
    sViewerPan = CGPointMake(0, 0);
    [sViewerImage setTransform:CGAffineTransformIdentity];
    if (sViewerPage)
        [sViewerPage setText:[NSString stringWithFormat:@"%d / %d",
                              (int)(sViewerIndex + 1), (int)[sViewerURLs count]]];
    diag("UI: photo viewer page changed");
}

/* 把缩放+平移应用到查看器图片：transform = translate(pan) * scale(s) */
static void ApplyViewerTransform(void)
{
    if (!sViewerImage) return;
    CGAffineTransform t = CGAffineTransformMakeScale(sViewerScale, sViewerScale);
    t.tx = sViewerPan.x;
    t.ty = sViewerPan.y;
    [sViewerImage setTransform:t];
}

- (void)viewerDoubleTap:(id)sender
{
    (void)sender;
    if (sViewerScale > 1.01f) {
        sViewerScale = 1.0f;
        sViewerPan = CGPointMake(0, 0);
    } else {
        sViewerScale = 2.5f;
        sViewerPan = CGPointMake(0, 0);
    }
    ApplyViewerTransform();
    diag("UI: viewer double tap zoom");
}

- (void)viewerPinch:(id)sender
{
    UIPinchGestureRecognizer *g = (UIPinchGestureRecognizer *)sender;
    CGFloat s;
    if (!g) return;
    if ([g state] == kGestureStateBegan) {
        sViewerPinchBase = sViewerScale;   /* 记录起始倍数 */
    }
    s = sViewerPinchBase * [g scale];
    if (s < 1.0f) s = 1.0f;
    if (s > 4.0f) s = 4.0f;
    sViewerScale = s;
    if ([g state] == kGestureStateEnded) {
        if (sViewerScale < 1.05f) { sViewerScale = 1.0f; sViewerPan = CGPointMake(0, 0); }
    }
    ApplyViewerTransform();
}

- (void)viewerPan:(id)sender
{
    UIPanGestureRecognizer *g = (UIPanGestureRecognizer *)sender;
    CGPoint tr;
    if (!g) return;
    if (sViewerScale <= 1.01f) {
        /* 未放大：拖动切换图片。结束时按水平位移决定上一张/下一张 */
        if ([g state] == kGestureStateEnded) {
            tr = [g translationInView:sViewerImage];
            if (tr.x < -50.0f && sViewerIndex + 1 < [sViewerURLs count]) {
                sViewerIndex += 1;
                [self updateViewerImage];
                diag("UI: viewer swipe next");
            } else if (tr.x > 50.0f && sViewerIndex > 0) {
                sViewerIndex -= 1;
                [self updateViewerImage];
                diag("UI: viewer swipe prev");
            }
            [g setTranslation:CGPointMake(0, 0) inView:sViewerImage];
        }
        return;
    }
    /* 放大后：拖动平移 */
    tr = [g translationInView:sViewerImage];
    sViewerPan.x += tr.x;
    sViewerPan.y += tr.y;
    [g setTranslation:CGPointMake(0, 0) inView:sViewerImage];
    ApplyViewerTransform();
}

/* ---------- 详情九宫格点击：弹出全屏查看器（双击/左右滑动/双指缩放全复用） ---------- */
- (void)detailThumbTapped:(id)sender
{
    UIButton *bt = (UIButton *)sender;
    NSUInteger idx;
    if (!bt || ![bt isKindOfClass:[UIButton class]]) return;
    if ([bt tag] < kDetailThumbBtn) return;
    idx = (NSUInteger)([bt tag] - kDetailThumbBtn);
    if ([sDetailURLs count] == 0) return;
    if (idx >= [sDetailURLs count]) idx = 0;

    if (sViewerURLs) [sViewerURLs release];
    sViewerURLs = [sDetailURLs retain];
    sViewerIndex = idx;
    sViewerRow = sDetailIndex;
    diag("UI: detail thumb tapped -> open viewer");
    [self showPhotoViewer];
}

- (void)viewerPrev:(id)sender
{
    (void)sender;
    if (sViewerIndex > 0) sViewerIndex -= 1;
    else sViewerIndex = [sViewerURLs count] - 1;
    [self updateViewerImage];
}

- (void)viewerNext:(id)sender
{
    (void)sender;
    if (sViewerIndex + 1 < [sViewerURLs count]) sViewerIndex += 1;
    else sViewerIndex = 0;
    [self updateViewerImage];
}

- (void)closePhotoViewer:(id)sender
{
    (void)sender;
    if (sViewerOverlay) {
        [sViewerOverlay removeFromSuperview];
        [sViewerOverlay release];
        sViewerOverlay = nil;
    }
    sViewerImage = nil;
    sViewerPage = nil;
    sViewerScale = 1.0f;
    sViewerPan = CGPointMake(0, 0);
    if (sViewerURLs) { [sViewerURLs release]; sViewerURLs = nil; }
}

/* 更新底部「上拉加载更多」提示 */
static void SetLoadMoreLabel(void)
{
    if (!sLoadMoreLabel) return;
    if (WeiboStoreLoadingMore()) {
        [sLoadMoreLabel setText:@"正在加载…"];
        [sLoadMoreSpinner startAnimating];
    } else if (!WeiboStoreHasMore()) {
        [sLoadMoreLabel setText:@"没有更多了"];
        [sLoadMoreSpinner stopAnimating];
    } else {
        [sLoadMoreLabel setText:@"上拉加载更多"];
        [sLoadMoreSpinner stopAnimating];
    }
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    CGFloat y = [scrollView contentOffset].y;
    CGFloat contentH = [scrollView contentSize].height;
    CGFloat viewH = [scrollView bounds].size.height;

    /* 上拉加载：滑到距底部一个屏幕内触发一次 */
    if (contentH > viewH && y + viewH > contentH - viewH * 0.9f) {
        if (!sLoadMoreTriggered && !WeiboStoreLoadingMore() && WeiboStoreHasMore()
            && WeiboStoreState() != 1) {
            sLoadMoreTriggered = 1;
            diag("UI: load more triggered at bottom");
            SetLoadMoreLabel();
            WeiboStoreLoadMore();
        }
    } else {
        /* 离开底部区域后复位，允许下次再触发 */
        if (y + viewH < contentH - viewH * 1.4f) sLoadMoreTriggered = 0;
    }

    if (sRefreshState == 3) return;
    if (y <= -kRefreshHeight) SetRefreshState(2);
    else if (y < -4.0f)      SetRefreshState(1);
    else                     SetRefreshState(0);
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate
{
    (void)scrollView;
    (void)decelerate;
    if (sRefreshState == 2) BeginRefresh();
}

- (void)showDetail:(NSUInteger)row
{
    CGRect bounds = [[UIScreen mainScreen] bounds];
    CGFloat w = CGRectGetWidth(bounds);
    CGFloat h = CGRectGetHeight(bounds);
    CGFloat navH = kNavHeight;
    NSDictionary *post = PostAt(row);
    if (!post || sDetailOverlay || sDetailAnimating == 2) return;

    NSString *avatarURL = [post objectForKey:@"avatar"];
    NSString *largeURL  = [post objectForKey:@"large"];
    NSString *fullText  = [post objectForKey:@"full"];
    NSArray *dimgs = [post objectForKey:@"photoLarges"];
    NSArray *thumbs = PhotosOfPost(post);   /* 和主界面同一份缩略图数组 */
    BOOL hasPhoto;
    CGFloat cardW = w - 20.0f;
    CGFloat textW = cardW - 24.0f;
    int lines = CountLines(fullText, textW, 15.0f, 60);
    CGFloat bodyH = (CGFloat)lines * 20.6f;
    CGFloat photoY = 58.0f + bodyH + 10.0f;
    UIImage *img;

    /* 详情大图数组：优先 photoLarges，若空则退回单张 large。
       九宫格缩略图用 photos（与主界面一致），点击进查看器看大图。 */
    if (sDetailURLs) { [sDetailURLs release]; sDetailURLs = nil; }
    if (dimgs && [dimgs isKindOfClass:[NSArray class]] && [dimgs count] > 0) {
        sDetailURLs = [dimgs retain];
    } else if (largeURL) {
        sDetailURLs = [[NSArray arrayWithObject:largeURL] retain];
    }

    /* 九宫格尺寸：和主界面 LayoutForPost 完全同一套规则
       （1 张 80pt，2~4 两张列、5~9 三列 76pt，行数查表避开除法） */
    sDetailThumbCount = thumbs ? (NSUInteger)[thumbs count] : 0;
    if (sDetailThumbCount == 0 && largeURL) sDetailThumbCount = 1;  /* 单图兜底 */
    if (sDetailThumbCount > kMaxThumbs) sDetailThumbCount = kMaxThumbs;
    hasPhoto = (sDetailThumbCount > 0);

    CGFloat photoH = 0.0f;
    if (hasPhoto) {
        if (sDetailThumbCount <= 1) {
            photoH = kPhotoSize;
        } else {
            int cols = (sDetailThumbCount <= 4) ? 2 : 3;
            int rows;
            static const signed char rows2[10] = {0,1,1,2,2,3,3,4,4,5};
            static const signed char rows3[10] = {0,1,1,1,2,2,2,3,3,3};
            if (cols == 2) rows = rows2[sDetailThumbCount <= 9 ? sDetailThumbCount : 9];
            else           rows = rows3[sDetailThumbCount <= 9 ? sDetailThumbCount : 9];
            photoH = (CGFloat)rows * kThumbSize + (CGFloat)(rows - 1) * kThumbGap;
        }
    }
    CGFloat statsY = photoY + photoH + (hasPhoto ? 10.0f : 0.0f);
    CGFloat cardH = statsY + 20.0f + 14.0f;

    UIView *overlay = [[UIView alloc] initWithFrame:CGRectMake(w, 0, w, h)];
    [overlay setBackgroundColor:LinenColor()];

    UIImageView *navBg = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, w, navH)];
    [navBg setImage:[UIImage imageNamed:@"NavBar"]];
    [overlay addSubview:navBg];
    [navBg release];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(70.0f, 13.0f, w - 140.0f, 26.0f)];
    [title setText:@"微博正文"];
    [title setFont:[UIFont boldSystemFontOfSize:17.0f]];
    [title setTextColor:[UIColor whiteColor]];
    [title setTextAlignment:kTextAlignCenter];
    [title setBackgroundColor:[UIColor clearColor]];
    [overlay addSubview:title];
    [title release];

    UIButton *back = [UIButton buttonWithType:kButtonTypeRounded];
    [back setFrame:CGRectMake(8.0f, 13.0f, 60.0f, 26.0f)];
    [back setTitle:@"返回" forState:kControlStateNormal];
    [back setTitleColor:[UIColor whiteColor] forState:kControlStateNormal];
    [[back titleLabel] setFont:[UIFont boldSystemFontOfSize:14.0f]];
    [back addTarget:self action:@selector(closeDetail:)
   forControlEvents:kControlEventTouchUpInside];
    [overlay addSubview:back];

    /* 左边缘细阴影，滑入时有纵深 */
    UIView *edge = [[UIView alloc] initWithFrame:CGRectMake(-6.0f, 0, 6.0f, h)];
    [edge setBackgroundColor:[UIColor blackColor]];
    [edge setAlpha:0.18f];
    [overlay addSubview:edge];
    [edge release];

    UIScrollView *scroll = [[UIScrollView alloc]
                            initWithFrame:CGRectMake(0, navH, w, h - navH)];
    [scroll setContentSize:CGSizeMake(w, cardH + 20.0f)];
    [overlay addSubview:scroll];

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(10.0f, 10.0f, cardW, cardH)];
    [card setBackgroundColor:[UIColor whiteColor]];
    RoundView(card, 8.0f);
    [scroll addSubview:card];

    UIImageView *av = [[UIImageView alloc]
                       initWithFrame:CGRectMake(12.0f, 12.0f, 40.0f, 40.0f)];
    [av setContentMode:kContentModeScaleAspectFill];
    [av setClipsToBounds:YES];
    RoundView(av, 6.0f);
    [card addSubview:av];
    if (avatarURL) {
        ImageLoaderRequest(avatarURL);
        img = ImageLoaderCachedImage(avatarURL);
        [av setImage:img ? img : [UIImage imageNamed:@"Avatar"]];
    }
    sDetailAvatar = av;
    [av release];

    UILabel *who = MakeLabel(CGRectMake(60.0f, 12.0f, cardW - 72.0f, 20.0f), 15.0f, YES, 0.16f);
    [who setText:[post objectForKey:@"author"]];
    [card addSubview:who];
    [who release];

    UILabel *when = MakeLabel(CGRectMake(60.0f, 33.0f, cardW - 72.0f, 16.0f), 11.0f, NO, 0.50f);
    [when setText:[post objectForKey:@"time"]];
    [card addSubview:when];
    [when release];

    UILabel *body = MakeLabel(CGRectMake(12.0f, 58.0f, textW, bodyH), 15.0f, NO, 0.13f);
    [body setText:fullText];
    [card addSubview:body];
    [body release];

    /* 九宫格：和主界面同一套布局与点击逻辑。缩略图数组取 post.photos，
       点击按钮 tag = kDetailThumbBtn + i，进全屏查看器看第 i 张大图。 */
    {
        int pi;
        int cols = (sDetailThumbCount == 1) ? 1 : (sDetailThumbCount <= 4 ? 2 : 3);
        CGFloat side = (sDetailThumbCount == 1) ? kPhotoSize : kThumbSize;
        static const signed char RC[54] = {
            0,0, 1,0, 2,0, 3,0, 4,0, 5,0, 6,0, 7,0, 8,0,
            0,0, 0,1, 1,0, 1,1, 0,0, 0,0, 0,0, 0,0, 0,0,
            0,0, 0,1, 0,2, 1,0, 1,1, 1,2, 2,0, 2,1, 2,2
        };
        /* 先清空旧槽位（复用时防残留） */
        for (pi = 0; pi < kMaxThumbs; pi++) { sDetailThumbs[pi] = nil; sDetailThumbBtns[pi] = nil; }
        for (pi = 0; pi < (int)sDetailThumbCount; pi++) {
            int row = RC[(cols - 1) * 18 + pi * 2];
            int col = RC[(cols - 1) * 18 + pi * 2 + 1];
            CGFloat x = 12.0f + (CGFloat)col * (side + kThumbGap);
            CGFloat y = photoY + (CGFloat)row * (side + kThumbGap);
            UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(x, y, side, side)];
            [iv setContentMode:kContentModeScaleAspectFill];
            [iv setClipsToBounds:YES];
            RoundView(iv, 4.0f);
            [card addSubview:iv];

            UIButton *bt = [UIButton buttonWithType:kButtonTypeRounded];
            [bt setFrame:CGRectMake(x, y, side, side)];
            [bt setTag:(kDetailThumbBtn + pi)];
            [bt setTitle:@"" forState:kControlStateNormal];
            [bt addTarget:self action:@selector(detailThumbTapped:)
              forControlEvents:kControlEventTouchUpInside];
            [card addSubview:bt];

            sDetailThumbs[pi] = iv;
            sDetailThumbBtns[pi] = bt;
            /* 占位图 -> 缓存图 -> 异步请求 */
            NSString *u = (thumbs && pi < (int)[thumbs count]) ? [thumbs objectAtIndex:pi] : nil;
            if (!u) u = largeURL;   /* 单图兜底 */
            ImageLoaderRequest(u);
            img = ImageLoaderCachedImage(u);
            [iv setImage:img ? img : [UIImage imageNamed:@"Photo"]];
            [iv release];
        }
    }

    UILabel *nums = MakeLabel(CGRectMake(12.0f, statsY, textW, 20.0f), 12.0f, NO, 0.48f);
    [nums setText:[post objectForKey:@"stats"]];
    [card addSubview:nums];
    [nums release];

    /* 评论区：正文卡下方的白色圆角卡。先把壳搭出来（显示「加载中」），
       评论到达后由 LayoutComments 回调填充并重算 contentSize。 */
    sDetailScroll = scroll;
    sDetailCardW = cardW;
    sDetailCardH = cardH;
    sCommentWrap = [[UIView alloc] initWithFrame:CGRectMake(10.0f, 10.0f + cardH + 10.0f,
                                                            cardW, 60.0f)];
    [sCommentWrap setBackgroundColor:[UIColor whiteColor]];
    RoundView(sCommentWrap, 8.0f);
    [scroll addSubview:sCommentWrap];
    [sCommentWrap release];   /* 由 scroll 持有；关闭时随 overlay 一起释放 */
    WeiboCommentsSetUpdateCallback(LayoutComments);
    LayoutComments();
    sCommentMid = [post objectForKey:@"id"];
    WeiboCommentsLoad(sCommentMid);

    [card release];
    [scroll release];

    sDetailIndex = row;
    sDetailOverlay = overlay;

    sShadeView = [[UIView alloc] initWithFrame:CGRectMake(0, navH, w, h - navH)];
    [sShadeView setBackgroundColor:[UIColor blackColor]];
    [sShadeView setAlpha:0.0f];
    [[self view] addSubview:sShadeView];
    [[self view] addSubview:overlay];

    sDetailAnimating = 1;
    [UIView beginAnimations:@"detailIn" context:(void *)1];
    [UIView setAnimationDuration:0.30];
    [UIView setAnimationCurve:kAnimationCurveEaseInOut];
    [UIView setAnimationDelegate:self];
    [UIView setAnimationDidStopSelector:@selector(detailAnimationDidStop:finished:context:)];
    [overlay setFrame:CGRectMake(0, 0, w, h)];
    [sShadeView setAlpha:0.28f];
    [UIView commitAnimations];
    diag("RootViewController: detail push animation started");
}

- (void)detailAnimationDidStop:(NSString *)animationID
                     finished:(id)finished
                      context:(void *)context
{
    (void)animationID;
    (void)finished;
    if (context == (void *)2) {
        diag("UI: detail pop animation didStop -> overlay removed");
        if (sDetailOverlay) { [sDetailOverlay removeFromSuperview]; [sDetailOverlay release]; sDetailOverlay = nil; }
        if (sShadeView)     { [sShadeView removeFromSuperview];     [sShadeView release];     sShadeView = nil; }
        sDetailAvatar = nil;
        if (sDetailURLs) { [sDetailURLs release]; sDetailURLs = nil; }
        /* 九宫格视图随 overlay 一起释放，清空悬空指针 */
        { int z; for (z = 0; z < kMaxThumbs; z++) { sDetailThumbs[z] = nil; sDetailThumbBtns[z] = nil; } }
        sDetailThumbCount = 0;
        /* 评论区：取消在途请求（迟到的回调按请求代号丢弃），视图随 overlay 释放，
           这里只清悬空指针，不再 release，避免重复释放 */
        WeiboCommentsCancel();
        sCommentWrap = nil;
        sCommentBody = nil;
        sCommentMid = nil;
        sDetailScroll = nil;
        sDetailCardW = 0.0f;
        sDetailCardH = 0.0f;
        sDetailAnimating = 0;
    } else if (context == (void *)1) {
        diag("UI: detail push animation didStop -> settled");
        sDetailAnimating = 0;
    }
}

/* 评论区：查看更多（追加下一页）/ 失败重试 */
- (void)commentMoreTapped:(id)sender
{
    (void)sender;
    if (!sCommentWrap) return;
    WeiboCommentsLoadMore();
    LayoutComments();
}

- (void)commentRetryTapped:(id)sender
{
    (void)sender;
    if (!sCommentWrap) return;
    diag("UI: comment retry tapped");
    WeiboCommentsLoad(sCommentMid);
    LayoutComments();
}

- (void)closeDetail:(id)sender
{
    CGFloat w = CGRectGetWidth([[UIScreen mainScreen] bounds]);
    CGFloat h = CGRectGetHeight([[UIScreen mainScreen] bounds]);
    (void)sender;
    if (!sDetailOverlay || sDetailAnimating == 2) return;
    sDetailAnimating = 2;
    [UIView beginAnimations:@"detailOut" context:(void *)2];
    [UIView setAnimationDuration:0.28];
    [UIView setAnimationCurve:kAnimationCurveEaseInOut];
    [UIView setAnimationDelegate:self];
    [UIView setAnimationDidStopSelector:@selector(detailAnimationDidStop:finished:context:)];
    [sDetailOverlay setFrame:CGRectMake(w, 0, w, h)];
    [sShadeView setAlpha:0.0f];
    [UIView commitAnimations];
}

#ifdef LEGACY_DIAG
#ifdef SHOTCHECK
/* 把整个 rootView 渲染成 PNG 存到设备 /tmp，用于设备无 screencapture 时验证界面 */
- (void)diagTakeScreenshot
{
    if (sShotDone) return;
    sShotDone = 1;
    CGRect b = [[UIScreen mainScreen] bounds];
    CGFloat w = CGRectGetWidth(b), h = CGRectGetHeight(b);
    id data;
    void *ctx;

    UIGraphicsBeginImageContextWithOptions(CGSizeMake(w, h), NO, 0.0f);
    ctx = UIGraphicsGetCurrentContext();
    [(LegacyLayerShim *)[[self view] layer] renderInContext:ctx];
    {
        id img = UIGraphicsGetImageFromCurrentImageContext();
        data = img ? UIImagePNGRepresentation(img) : nil;
    }
    UIGraphicsEndImageContext();

    if (data) {
        BOOL ok = [data writeToFile:@"/tmp/legacy_shot.png" atomically:YES];
        diag([[NSString stringWithFormat:@"SHOTCHECK: wrote=%@ bytes=%d",
               ok ? @"YES" : @"NO", (int)[data length]] UTF8String]);
    } else {
        diag("SHOTCHECK: png data nil");
    }
}
#endif
- (void)diagAutoPull
{
    diag("UI: auto pull: set contentOffset -70 and release");
    [sTableView setContentOffset:CGPointMake(0, -kRefreshHeight - 10.0f) animated:NO];
    [self scrollViewDidScroll:sTableView];
    [self scrollViewDidEndDragging:sTableView willDecelerate:NO];
}

- (void)diagAutoDetail
{
    diag("UI: auto detail: push from right");
    [self showDetail:0];
}

#if defined(COMMENTCHECK) || defined(GALLERY)
/* 挑「评」数最多的那条：评论少的微博拿不到翻页游标，压不到加载更多这条路径 */
static NSUInteger FindCommentPost(int *outCount)
{
    NSUInteger i, n = sPosts ? [sPosts count] : 0, best = 0;
    int bestCnt = -1;
    for (i = 0; i < n; i++) {
        const char *p = [[[sPosts objectAtIndex:i] objectForKey:@"stats"] UTF8String];
        while (p && *p) {
            /* 「评」的 UTF-8 字节：E8 AF 84 */
            if ((unsigned char)p[0] == 0xE8 && (unsigned char)p[1] == 0xAF &&
                (unsigned char)p[2] == 0x84 && p[3] == ' ') {
                int v = 0;
                const char *q = p + 3;
                while (*q == ' ') q++;
                while (*q >= '0' && *q <= '9') { v = v * 10 + (*q - '0'); q++; }
                if (v > bestCnt) { bestCnt = v; best = i; }
                break;
            }
            p++;
        }
    }
    if (outCount) *outCount = (bestCnt > 0) ? bestCnt : 0;
    if (bestCnt <= 0) return 0;
    return best;
}
#endif

#ifdef COMMENTCHECK

- (void)diagCommentOpen
{
    int cnt = 0;
    NSUInteger row = FindCommentPost(&cnt);
    diag([[NSString stringWithFormat:@"COMMENTCHECK: open detail row=%d listComments=%d",
           (int)row, cnt] UTF8String]);
    [self showDetail:row];
    [self performSelector:@selector(diagCommentPhase1) withObject:nil afterDelay:2.5];
}

- (void)diagCommentPhase1
{
    NSArray *cl = WeiboCommentsList();
    diag([[NSString stringWithFormat:
           @"COMMENTCHECK: phase1 state=%d loaded=%d apiTotal=%d hasMore=%d",
           WeiboCommentsState(), (int)(cl ? [cl count] : 0),
           WeiboCommentsTotal(), WeiboCommentsHasMore()] UTF8String]);
    [self performSelector:@selector(diagCommentMore) withObject:nil afterDelay:0.3];
}

- (void)diagCommentMore
{
    diag("COMMENTCHECK: tap load-more");
    [self commentMoreTapped:nil];
    [self performSelector:@selector(diagCommentPhase2) withObject:nil afterDelay:3.0];
}

- (void)diagCommentPhase2
{
    NSArray *cl = WeiboCommentsList();
    NSUInteger i, n = cl ? [cl count] : 0;
    NSMutableDictionary *seen = [[NSMutableDictionary alloc] init];
    int dup = 0;
    for (i = 0; i < n; i++) {
        NSString *cid = [[cl objectAtIndex:i] objectForKey:@"id"];
        if (!cid) continue;
        if ([seen objectForKey:cid]) dup++;
        else [seen setObject:@"1" forKey:cid];
    }
    [seen release];
    diag([[NSString stringWithFormat:
           @"COMMENTCHECK: phase2 count=%d dup=%d feed=%d posts=%d hasMore=%d",
           (int)n, dup, WeiboStoreFeed(),
           (int)(sPosts ? [sPosts count] : 0), WeiboCommentsHasMore()] UTF8String]);
    /* 滚到评论区，让截图能拍到评论内容 */
    if (sDetailScroll)
        [sDetailScroll setContentOffset:CGPointMake(0, 10.0f + sDetailCardH - 44.0f)
                               animated:NO];
    [self performSelector:@selector(diagCommentShot) withObject:nil afterDelay:1.5];
}

- (void)diagCommentShot
{
    CGRect b = [[UIScreen mainScreen] bounds];
    CGFloat w = CGRectGetWidth(b), h = CGRectGetHeight(b);
    id data;
    void *ctx;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(w, h), NO, 0.0f);
    ctx = UIGraphicsGetCurrentContext();
    [(LegacyLayerShim *)[[self view] layer] renderInContext:ctx];
    {
        id img = UIGraphicsGetImageFromCurrentImageContext();
        data = img ? UIImagePNGRepresentation(img) : nil;
    }
    UIGraphicsEndImageContext();
    if (data) {
        BOOL ok = [data writeToFile:@"/tmp/legacy_comment.png" atomically:YES];
        diag([[NSString stringWithFormat:@"COMMENTCHECK: shot=%@ bytes=%d",
               ok ? @"YES" : @"NO", (int)[data length]] UTF8String]);
    } else {
        diag("COMMENTCHECK: shot data nil");
    }
    /* 再滚到最底部，确认「查看更多评论」按钮的观感 */
    [self performSelector:@selector(diagCommentBottom) withObject:nil afterDelay:0.4];
}

- (void)diagCommentBottom
{
    if (sDetailScroll) {
        CGFloat ch = [sDetailScroll contentSize].height;
        CGFloat vh = [sDetailScroll bounds].size.height;
        [sDetailScroll setContentOffset:CGPointMake(0, (ch > vh ? ch - vh : 0)) animated:NO];
    }
    diag("COMMENTCHECK: scrolled to bottom");
    [self performSelector:@selector(diagCommentShot2) withObject:nil afterDelay:1.2];
}

- (void)diagCommentShot2
{
    CGRect b = [[UIScreen mainScreen] bounds];
    CGFloat w = CGRectGetWidth(b), h = CGRectGetHeight(b);
    id data;
    void *ctx;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(w, h), NO, 0.0f);
    ctx = UIGraphicsGetCurrentContext();
    [(LegacyLayerShim *)[[self view] layer] renderInContext:ctx];
    {
        id img = UIGraphicsGetImageFromCurrentImageContext();
        data = img ? UIImagePNGRepresentation(img) : nil;
    }
    UIGraphicsEndImageContext();
    if (data) {
        BOOL ok = [data writeToFile:@"/tmp/legacy_comment2.png" atomically:YES];
        diag([[NSString stringWithFormat:@"COMMENTCHECK: shot2=%@ bytes=%d",
               ok ? @"YES" : @"NO", (int)[data length]] UTF8String]);
    }
    [self performSelector:@selector(diagCommentDone) withObject:nil afterDelay:0.3];
}

/* 关闭正文页：验证评论区随 overlay 一起释放、不崩、不残留指针 */
- (void)diagCommentDone
{
    [self closeDetail:nil];
    [self performSelector:@selector(diagCommentAfterClose) withObject:nil afterDelay:1.5];
}

- (void)diagCommentAfterClose
{
    diag([[NSString stringWithFormat:
           @"COMMENTCHECK: closed overlay=%@ wrap=%@ state=%d feed=%d posts=%d",
           sDetailOverlay ? @"YES" : @"NO",
           sCommentWrap ? @"YES" : @"NO",
           WeiboCommentsState(), WeiboStoreFeed(),
           (int)(sPosts ? [sPosts count] : 0)] UTF8String]);
}
#endif

#ifdef GALLERY
/* 只读采集：依次截「主列表 / 正文+评论 / 账号详情」三张，供设计参考 */
- (void)galleryShot:(NSString *)path
{
    CGRect b = [[UIScreen mainScreen] bounds];
    CGFloat w = CGRectGetWidth(b), h = CGRectGetHeight(b);
    id data;
    void *ctx;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(w, h), NO, 0.0f);
    ctx = UIGraphicsGetCurrentContext();
    [(LegacyLayerShim *)[[self view] layer] renderInContext:ctx];
    {
        id img = UIGraphicsGetImageFromCurrentImageContext();
        data = img ? UIImagePNGRepresentation(img) : nil;
    }
    UIGraphicsEndImageContext();
    if (data) {
        BOOL ok = [data writeToFile:path atomically:YES];
        diag([[NSString stringWithFormat:@"GALLERY: %@ %@ bytes=%d",
               path, ok ? @"OK" : @"FAIL", (int)[data length]] UTF8String]);
    } else {
        diag("GALLERY: png data nil");
    }
}

- (void)galleryList
{
    /* 还没真正落到列表上（比如刚切流又刷新了）就再等一轮，最多重试 6 次 */
    if ((WeiboStoreState() != 2 || !sPosts || [sPosts count] == 0) && sGalleryStage < 12) {
        sGalleryStage++;
        [self performSelector:@selector(galleryList) withObject:nil afterDelay:1.5];
        return;
    }
    [self galleryShot:@"/tmp/gallery_1_list.png"];
    [self performSelector:@selector(galleryOpenDetail) withObject:nil afterDelay:0.8];
}

- (void)galleryOpenDetail
{
    int cnt = 0;
    NSUInteger row = FindCommentPost(&cnt);
    [self showDetail:row];
    [self performSelector:@selector(galleryScrollComments) withObject:nil afterDelay:2.6];
}

- (void)galleryScrollComments
{
    if (sDetailScroll)
        [sDetailScroll setContentOffset:CGPointMake(0, 10.0f + sDetailCardH - 44.0f)
                               animated:NO];
    [self performSelector:@selector(galleryDetailShot) withObject:nil afterDelay:1.4];
}

- (void)galleryDetailShot
{
    [self galleryShot:@"/tmp/gallery_2_detail.png"];
    [self performSelector:@selector(galleryCloseDetail) withObject:nil afterDelay:0.5];
}

- (void)galleryCloseDetail
{
    [self closeDetail:nil];
    [self performSelector:@selector(galleryPanel) withObject:nil afterDelay:0.9];
}

- (void)galleryPanel
{
    if (!WeiboStoreLoggedIn()) { diag("GALLERY: not logged in, skip account panel"); return; }
    [self showAccountPanel];
    [self performSelector:@selector(galleryPanelShot) withObject:nil afterDelay:1.6];
}

- (void)galleryPanelShot
{
    [self galleryShot:@"/tmp/gallery_3_panel.png"];
    diag("GALLERY: done");
}
#endif

#ifdef ACCOUNTCHECK
- (void)diagAccountCheck
{
    NSDictionary *p = WeiboStoreProfile();
    diag([[NSString stringWithFormat:@"ACCOUNTCHECK: logged=%d profile=%@",
           WeiboStoreLoggedIn(), p ? @"YES" : @"NO"] UTF8String]);
    if (p) {
        diag([[NSString stringWithFormat:@"ACCOUNTCHECK: name=%@ followers=%@ desc=%@",
               [p objectForKey:@"name"], [p objectForKey:@"followers"],
               [p objectForKey:@"desc"]] UTF8String]);
    }
    [self accountTapped:nil];   /* 已登录→详情面板；未登录→扫码层 */
    diag([[NSString stringWithFormat:@"ACCOUNTCHECK: panel=%@ login=%@",
           sAccountPanel ? @"YES" : @"NO", sLoginOverlay ? @"YES" : @"NO"] UTF8String]);
#ifdef ACCOUNT_CLOSE_CHECK
    if (sAccountPanel)
        [self performSelector:@selector(diagAccountClose) withObject:nil afterDelay:2.5];
#endif
#ifdef LOGOUTCHECK
    if (sAccountPanel)
        [self performSelector:@selector(diagDoLogout) withObject:nil afterDelay:2.5];
#endif
}

#ifdef LOGOUTCHECK
- (void)diagDoLogout
{
    diag("LOGOUTCHECK: tapping logout button path");
    [self logoutTapped:nil];
    [self performSelector:@selector(diagLogoutResult) withObject:nil afterDelay:0.6];
}

- (void)diagLogoutResult
{
    diag([[NSString stringWithFormat:@"LOGOUTCHECK: done logged=%d feed=%d seg=%d panel=%@ accountLabel=%@",
           WeiboStoreLoggedIn(), WeiboStoreFeed(),
           sSegment ? (int)[sSegment selectedSegmentIndex] : -1,
           sAccountPanel ? @"YES" : @"NO",
           sAccountLabel && ![sAccountLabel isHidden] ? @"LOGIN" : @"AVATAR"] UTF8String]);
}
#endif

#ifdef ACCOUNT_CLOSE_CHECK
- (void)diagAccountClose
{
    diag("ACCOUNTCHECK: closing panel via back button path");
    [self closeAccount:nil];
    /* 动画 0.25s 后才真正移除延迟读 */
    [self performSelector:@selector(diagAccountCloseResult) withObject:nil afterDelay:0.6];
}

- (void)diagAccountCloseResult
{
    diag([[NSString stringWithFormat:@"ACCOUNTCHECK: after close panel=%@",
           sAccountPanel ? @"YES" : @"NO"] UTF8String]);
}
#endif
#endif

/* 详情多图自检：打开第一条多图微博，记录初始页码，切到下一张再记录 */
#ifdef DETAILCHECK
- (void)diagDetailMulti
{
    NSUInteger i, n = sPosts ? [sPosts count] : 0, target = NSNotFound;
    for (i = 0; i < n; i++) {
        NSArray *ps = [[sPosts objectAtIndex:i] objectForKey:@"photoLarges"];
        if (ps && [ps isKindOfClass:[NSArray class]] && [ps count] > 1) {
            target = i;
            break;
        }
    }
    if (target == NSNotFound) { diag("DETAILCHECK: NO multi-image post found"); return; }
    diag([[NSString stringWithFormat:@"DETAILCHECK: open multi post at row %d, pics=%d",
           (int)target, (int)[[[sPosts objectAtIndex:target] objectForKey:@"photoLarges"] count]]
          UTF8String]);
    [self showDetail:target];
#ifndef DETAIL_NO_TAP
    [self performSelector:@selector(diagDetailTapThumb) withObject:nil afterDelay:1.2];
#endif
}

/* 模拟点击详情九宫格第 1 张，验证弹出查看器并定位 */
- (void)diagDetailTapThumb
{
    UIButton *bt = sDetailThumbBtns[1] ? sDetailThumbBtns[1] : sDetailThumbBtns[0];
    diag([[NSString stringWithFormat:@"DETAILCHECK: thumbs=%d urls=%d tapBtn=%@",
           (int)sDetailThumbCount, (int)[sDetailURLs count], bt ? @"YES" : @"NO"] UTF8String]);
    if (bt) [self detailThumbTapped:bt];
    diag([[NSString stringWithFormat:@"DETAILCHECK: viewer opened=%@ viewerIndex=%d",
           sViewerOverlay ? @"YES" : @"NO", (int)sViewerIndex] UTF8String]);
}
#endif

- (void)diagAutoSwitchFeed
{
    diag("UI: auto switch segment to feed 1");
    [sSegment setSelectedSegmentIndex:1];
    [self feedChanged:nil];
}

- (void)diagAutoLogin
{
    diag("UI: auto open in-app QR login layer");
    [self loginTapped:nil];
}

/* 上拉加载更多（自检共用）：UIEXTRA 与 FRIENDSCHECK 都需要 */
#if defined(LEGACY_UI_EXTRA) || defined(FRIENDSCHECK)
- (void)diagAutoLoadMore
{
    /* 直接把 contentOffset 设到底部，让 scrollViewDidScroll 触发加载更多 */
    CGFloat viewH = [sTableView bounds].size.height;
    CGFloat contentH = [sTableView contentSize].height;
    diag("UI: auto scroll to bottom to trigger load-more");
    [sTableView setContentOffset:CGPointMake(0, contentH - viewH) animated:NO];
    [self scrollViewDidScroll:sTableView];
}
#endif

#ifdef LEGACY_UI_EXTRA
- (void)diagAutoSwitchFeedTo:(id)target
{
    NSInteger feed = (NSInteger)target;
    diag("UIEXTRA: switch feed target");
    if (feed < 0 || feed > 2) feed = 0;
    [sSegment setSelectedSegmentIndex:feed];
    [self feedChanged:nil];
}

- (void)diagAutoPhoto
{
    NSDictionary *post = PostAt(0);
    NSMutableArray *urls = [[NSMutableArray alloc] init];
    id larges, photos;
    if (!post) { [urls release]; return; }
    /* 直接走查看器：取第一条微博的大图数组 */
    larges = [post objectForKey:@"photoLarges"];
    photos = [post objectForKey:@"photos"];
    if (larges && [larges count] > 0) [urls addObjectsFromArray:larges];
    else if (photos && [photos count] > 0) [urls addObjectsFromArray:photos];
    else {
        NSString *one = [post objectForKey:@"large"];
        if (one) [urls addObject:one];
    }
    if ([urls count] == 0) { [urls release]; return; }
    if (sViewerURLs) [sViewerURLs release];
    sViewerURLs = [urls retain];   /* 转为不可变数组所有权 */
    [urls release];
    sViewerIndex = 0;
    sViewerRow = 0;
    diag("UIEXTRA: auto open photo viewer");
    [self showPhotoViewer];
#ifdef UIGEST
    /* 手势自检：双击放大后模拟 pan 切下一张；状态写日志 */
    [self performSelector:@selector(diagAutoGesture) withObject:nil afterDelay:1.5];
#endif
}

#ifdef UIGEST
- (void)diagAutoGesture
{
    diag("UIGEST: before double tap");
    [self viewerDoubleTap:nil];
    diag(sViewerScale > 2.0f ? "UIGEST: double tap zoomed in" : "UIGEST: double tap FAILED");
    /* 关查看器 → 打开详情九宫格 → 点缩略图 → 再看器内双击，验证整条链路 */
    [self closePhotoViewer:nil];
    [self showDetail:0];
    [self performSelector:@selector(diagDetailGesture) withObject:nil afterDelay:0.8];
}

- (void)diagDetailGesture
{
    UIButton *bt = sDetailThumbBtns[0];
    diag([[NSString stringWithFormat:@"UIGEST: detail thumbs=%d",
           (int)sDetailThumbCount] UTF8String]);
    if (bt) [self detailThumbTapped:bt];
    if (sViewerOverlay) {
        [self viewerDoubleTap:nil];
        diag(sViewerScale > 2.0f ? "UIGEST: detail->viewer zoomed in" : "UIGEST: viewer zoom FAILED");
    } else {
        diag("UIGEST: detail thumb did not open viewer");
    }
}
#endif
#endif
#endif

- (void)feedChanged:(id)sender
{
    int idx = (int)[sSegment selectedSegmentIndex];
    (void)sender;
    if (idx > 0 && !WeiboStoreLoggedIn()) {
        /* 关注 / 我的 都需要登录：直接在 app 内弹扫码登录层 */
        [sSegment setSelectedSegmentIndex:0];
        layoutSegmentBlock();   /* 选中被重置回热门，浮块跟着回去 */
        [sStatusLabel setText:@"点左上角「登录」扫码后即可看关注流"];
        [sStatusLabel setHidden:NO];
        [self loginTapped:nil];
        return;
    }
    layoutSegmentBlock();
    WeiboStoreSwitchFeed(idx);
}

- (void)refreshTapped:(id)sender
{
    (void)sender;
    WeiboStoreLoad();
}

/* ---------- 左上角账号区 ---------- */

/* 资料异步到达回调：刷新头像与已打开的详情面板 */
static void ProfileChanged(void)
{
    if (sSelf) [(RootViewController *)sSelf refreshAccountArea];
    if (sAccountPanel) [(RootViewController *)sSelf refreshAccountPanel];
}

- (void)refreshAccountArea
{
    BOOL logged = WeiboStoreLoggedIn();
    NSDictionary *p = WeiboStoreProfile();
    NSString *avatarURL;

    if (!logged) {
        [sAccountLabel setHidden:NO];
        [sAccountAvatar setHidden:YES];
        [sAccountLabel setText:@"登录"];
        return;
    }
    [sAccountLabel setHidden:YES];
    [sAccountAvatar setHidden:NO];
    avatarURL = p ? [p objectForKey:@"avatar"] : nil;
    if (avatarURL) {
        ImageLoaderRequest(avatarURL);
        UIImage *img = ImageLoaderCachedImage(avatarURL);
        [sAccountAvatar setImage:img ? img : [UIImage imageNamed:@"Avatar"]];
    } else {
        [sAccountAvatar setImage:[UIImage imageNamed:@"Avatar"]];
    }
}

/* ---------- app 内扫码登录 ---------- */

static void LoginStateChanged(int state, UIImage *qrcode, NSString *message)
{
    diag("UI: in-app login state changed");
    if (state == 5) {
        diag("UI: in-app login succeeded -> reload login + follow feed");
        /* 登录成功：关掉弹层，重新读本地凭据，跳到关注流 */
        if (sSelf) [(RootViewController *)sSelf closeLogin:nil];
        WeiboStoreReloadLogin();
        if (sSelf) [(RootViewController *)sSelf refreshAccountArea];
        WeiboStoreFetchProfile();
        if (sSegment) [sSegment setSelectedSegmentIndex:1];
        layoutSegmentBlock();   /* 登录成功跳关注：浮块同步 */
        WeiboStoreSwitchFeed(1);
        return;
    }
    if (!sLoginOverlay) return;
    if (state == 2 && qrcode && sQRImageView) {
        [sQRImageView setImage:qrcode];
        [sQRImageView setAlpha:1.0f];
    }
    if (state == 1 && sQRImageView) {
        /* 刷新中：清空旧码，避免用户扫到失效的旧二维码 */
        [sQRImageView setImage:nil];
    }
    if (sLoginLabel) {
        [sLoginLabel setText:message ? message : @"正在准备二维码…"];
    }
}

- (void)showLoginLayer
{
    CGRect bounds = [[UIScreen mainScreen] bounds];
    CGFloat w = CGRectGetWidth(bounds);
    CGFloat h = CGRectGetHeight(bounds);
    CGFloat cardW = 280.0f;
    CGFloat cardH = 400.0f;
    CGFloat cardX = (w - cardW) / 2.0f;
    CGFloat cardY = (h - cardH) / 2.0f - 20.0f;

    if (sLoginOverlay) return;

    sLoginOverlay = [[UIView alloc] initWithFrame:bounds];
    [sLoginOverlay setBackgroundColor:[UIColor colorWithRed:0.10f green:0.12f blue:0.16f alpha:0.72f]];

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(cardX, cardY, cardW, cardH)];
    [card setBackgroundColor:[UIColor whiteColor]];
    RoundView(card, 10.0f);
    [sLoginOverlay addSubview:card];
    [card release];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(10.0f, 12.0f, cardW - 20.0f, 26.0f)];
    [title setText:@"微博扫码登录"];
    [title setFont:[UIFont boldSystemFontOfSize:17.0f]];
    [title setTextColor:[UIColor colorWithRed:0.12f green:0.15f blue:0.20f alpha:1.0f]];
    [title setTextAlignment:kTextAlignCenter];
    [title setBackgroundColor:[UIColor clearColor]];
    [card addSubview:title];
    [title release];

    sQRImageView = [[UIImageView alloc] initWithFrame:CGRectMake((cardW - 200.0f) / 2.0f, 46.0f, 200.0f, 200.0f)];
    [sQRImageView setBackgroundColor:[UIColor colorWithRed:0.94f green:0.94f blue:0.94f alpha:1.0f]];
    [sQRImageView setContentMode:kContentModeScaleAspectFit];
    [card addSubview:sQRImageView];

    sLoginLabel = [[UILabel alloc] initWithFrame:CGRectMake(16.0f, 254.0f, cardW - 32.0f, 44.0f)];
    [sLoginLabel setText:@"正在准备二维码…"];
    [sLoginLabel setFont:[UIFont systemFontOfSize:13.0f]];
    [sLoginLabel setTextColor:[UIColor colorWithRed:0.35f green:0.35f blue:0.38f alpha:1.0f]];
    [sLoginLabel setTextAlignment:kTextAlignCenter];
    [sLoginLabel setBackgroundColor:[UIColor clearColor]];
    [sLoginLabel setNumberOfLines:2];
    [card addSubview:sLoginLabel];

    /* 底部两个按钮：刷新二维码 / 关闭。
       kButtonTypeRounded(0) 实际是 Custom，透明背景；白卡上必须自己给背景色，
       否则白色文字落在白卡上完全看不见。 */
    sLoginButton = [UIButton buttonWithType:kButtonTypeRounded];
    [sLoginButton setFrame:CGRectMake(18.0f, cardH - 50.0f, 116.0f, 34.0f)];
    [sLoginButton setBackgroundColor:[UIColor colorWithRed:0.16f green:0.40f blue:0.72f alpha:1.0f]];
    RoundView(sLoginButton, 6.0f);
    [sLoginButton setTitle:@"刷新二维码" forState:kControlStateNormal];
    [sLoginButton setTitleColor:[UIColor whiteColor] forState:kControlStateNormal];
    [sLoginButton addTarget:self action:@selector(refreshQRCode:)
       forControlEvents:kControlEventTouchUpInside];
    [card addSubview:sLoginButton];

    UIButton *closeBtn = [UIButton buttonWithType:kButtonTypeRounded];
    [closeBtn setFrame:CGRectMake(cardW - 134.0f, cardH - 50.0f, 116.0f, 34.0f)];
    [closeBtn setBackgroundColor:[UIColor colorWithRed:0.55f green:0.57f blue:0.60f alpha:1.0f]];
    RoundView(closeBtn, 6.0f);
    [closeBtn setTitle:@"关闭" forState:kControlStateNormal];
    [closeBtn setTitleColor:[UIColor whiteColor] forState:kControlStateNormal];
    [closeBtn addTarget:self action:@selector(closeLogin:)
       forControlEvents:kControlEventTouchUpInside];
    [card addSubview:closeBtn];

    [[self view] addSubview:sLoginOverlay];
    WeiboLoginSetCallback(LoginStateChanged);
    WeiboLoginStart();
}

- (void)closeLogin:(id)sender
{
    (void)sender;
    WeiboLoginCancel();
    if (sLoginOverlay) {
        [sLoginOverlay removeFromSuperview];
        [sLoginOverlay release];
        sLoginOverlay = nil;
    }
    sQRImageView = nil;
    sLoginLabel = nil;
    sLoginButton = nil;
}

- (void)refreshQRCode:(id)sender
{
    (void)sender;
    diag("UI: refresh QR code tapped");
    if (sLoginLabel) [sLoginLabel setText:@"正在刷新二维码…"];
    if (sQRImageView) {
        [sQRImageView setImage:nil];
        [sQRImageView setAlpha:0.6f];
    }
    /* WeiboLoginStart 内部会 Cancel 旧会话并重新生成二维码 */
    WeiboLoginStart();
}

- (void)loginTapped:(id)sender
{
    (void)sender;
    if (sLoginOverlay) return;
    [self showLoginLayer];
}

/* ---------- 账号详情：从左侧滑出 ---------- */

- (void)accountTapped:(id)sender
{
    (void)sender;
    if (sAccountPanel || sAccountAnimating) return;
    if (!WeiboStoreLoggedIn()) {
        [self loginTapped:nil];   /* 未登录：弹扫码层（保留刷新/关闭） */
        return;
    }
    [self showAccountPanel];
}

- (void)refreshAccountPanel
{
    NSDictionary *p = WeiboStoreProfile();
    if (!p) return;
    if (sAccountName) {
        NSString *nm = [p objectForKey:@"name"];
        [sAccountName setText:nm ? nm : @"已登录"];
    }
    if (sAccountBigAvatar) {
        NSString *av = [p objectForKey:@"avatar"];
        if (av) {
            ImageLoaderRequest(av);
            UIImage *img = ImageLoaderCachedImage(av);
            [sAccountBigAvatar setImage:img ? img : [UIImage imageNamed:@"Avatar"]];
        }
    }
    /* 资料到达时重建数字/简介（面板已打开时） */
    if (sAccountPanel) {
        [self fillAccountPanel];
    }
}

/* 用资料填充面板的数字与简介（每次资料到达重建，避免依赖 ivar） */
- (void)fillAccountPanel
{
    NSDictionary *p = WeiboStoreProfile();
    if (!p || !sAccountPanel) return;
    CGFloat pw = CGRectGetWidth([sAccountPanel frame]);
    CGFloat x0 = 126.0f;
    CGFloat top = kNavHeight + 26.0f;   /* 与昵称同一行基线（蓝条 52 + 26） */
    NSNumber *num;
    NSString *val;
    int i;

    /* 先移除旧的动态子视图（tag 600..609），避免重复叠加 */
    for (i = 600; i < 610; i++) {
        UIView *old = [sAccountPanel viewWithTag:i];
        if (old) [old removeFromSuperview];
    }
    /* 昵称 + 性别图标 */
    val = [p objectForKey:@"name"];
    if (!val) val = @"已登录";
    /* 昵称用固定标签 sAccountName（refreshAccountPanel 里已设），此处只放性别图标 */
    val = [p objectForKey:@"gender"];
    if (val && [val isEqualToString:@"f"]) {
        UILabel *g = MakeLabel(CGRectMake(x0 + 112.0f, top - 2.0f, 22.0f, 22.0f), 13.0f, YES, 0.5f);
        [g setText:@"♀"]; [g setTextColor:[UIColor whiteColor]];
        [g setBackgroundColor:[UIColor colorWithRed:0.32f green:0.66f blue:0.95f alpha:1.0f]];
        [g setTextAlignment:kTextAlignCenter];
        RoundView(g, 11.0f); [g setTag:609];
        [sAccountPanel addSubview:g]; [g release];
    } else {
        UILabel *g = MakeLabel(CGRectMake(x0 + 112.0f, top - 2.0f, 22.0f, 22.0f), 13.0f, YES, 0.5f);
        [g setText:@"♂"]; [g setTextColor:[UIColor whiteColor]];
        [g setBackgroundColor:[UIColor colorWithRed:0.32f green:0.66f blue:0.95f alpha:1.0f]];
        [g setTextAlignment:kTextAlignCenter];
        RoundView(g, 11.0f); [g setTag:609];
        [sAccountPanel addSubview:g]; [g release];
    }
    /* 三组数字：粉丝 / 关注 / 微博（statuses_count 是发博数，标签须与口径一致） */
    NSArray *labels = [NSArray arrayWithObjects:@"粉丝", @"关注", @"微博", nil];
    NSArray *keys   = [NSArray arrayWithObjects:@"followers", @"follow", @"statuses", nil];
    for (i = 0; i < 3; i++) {
        /* 面板宽约 275pt，昵称右侧仅剩 ~135pt，三组各 44pt 才放得下 */
        CGFloat nx = x0 + (CGFloat)i * 45.0f;
        num = [p objectForKey:[keys objectAtIndex:i]];
        NSString *cnt = num ? [NSString stringWithFormat:@"%d", [num intValue]] : @"0";
        UILabel *cntL = MakeLabel(CGRectMake(nx, top + 30.0f, 44.0f, 22.0f), 14.0f, YES, 0.16f);
        [cntL setText:cnt]; [cntL setTag:(600 + i*2)];
        [sAccountPanel addSubview:cntL]; [cntL release];
        UILabel *labL = MakeLabel(CGRectMake(nx, top + 52.0f, 44.0f, 16.0f), 10.0f, NO, 0.50f);
        [labL setText:[labels objectAtIndex:i]]; [labL setTag:(601 + i*2)];
        [sAccountPanel addSubview:labL]; [labL release];
    }
    /* 简介行：卡片底部，深色文字 */
    val = [p objectForKey:@"desc"];
    if (val && [val length] > 0) {
        UILabel *desc = MakeLabel(CGRectMake(20.0f, top + 90.0f, pw - 60.0f, 36.0f),
                                  11.0f, NO, 0.45f);
        [desc setText:[NSString stringWithFormat:@"▤  %@", val]];
        [desc setNumberOfLines:2]; [desc setTag:607];
        [sAccountPanel addSubview:desc]; [desc release];
    }
}

- (void)showAccountPanel
{
    CGRect bounds = [[UIScreen mainScreen] bounds];
    CGFloat w = CGRectGetWidth(bounds);
    CGFloat h = CGRectGetHeight(bounds);
    CGFloat pw = w * 0.86f;
    NSDictionary *p = WeiboStoreProfile();
    NSString *nm = p ? [p objectForKey:@"name"] : nil;

    /* 半透明遮罩（点遮罩也可关闭） */
    sAccountShade = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    [sAccountShade setBackgroundColor:[UIColor colorWithRed:0 green:0 blue:0 alpha:0.45f]];
    UIButton *dismiss = [UIButton buttonWithType:kButtonTypeRounded];
    [dismiss setFrame:CGRectMake(0, 0, w, h)];
    [dismiss setTitle:@"" forState:kControlStateNormal];
    [dismiss addTarget:self action:@selector(closeAccount:)
      forControlEvents:kControlEventTouchUpInside];
    [sAccountShade addSubview:dismiss];
    [[self view] addSubview:sAccountShade];

    /* 面板：从左侧外滑入。配色与主界面统一——亚麻灰底 + 蓝色导航条 + 白色圆角卡 */
    sAccountPanel = [[UIView alloc] initWithFrame:CGRectMake(-pw, 0, pw, h)];
    [sAccountPanel setBackgroundColor:LinenColor()];

    /* 顶部蓝色导航条：复用主界面同一张 NavBar，高度同为 kNavHeight */
    UIImageView *navBg = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, pw, kNavHeight)];
    [navBg setImage:[UIImage imageNamed:@"NavBar"]];
    [sAccountPanel addSubview:navBg];
    [navBg release];

    /* V0.3 资料卡：纸白九宫格底图（自带圆角与 1px 描边）+ 内嵌虚线缝线。
       圆角由底图自带，这里不再 masksToBounds，避免把缝线在四角切掉。 */
    /* 卡片高度从 218 收到 160：内容和蓝条下 116pt 处结束，留 16pt 呼吸；
       原来的 218 在加上缝线后底部会空出一大块，看起来像漏排内容。 */
    UIImageView *card = [[UIImageView alloc] initWithFrame:CGRectMake(10.0f, kNavHeight + 10.0f,
                                                                     pw - 20.0f, 160.0f)];
    {
        UIImage *cardImg = [UIImage imageNamed:@"PanelCard"];
        if (cardImg) {
            [card setImage:[cardImg resizableImageWithCapInsets:
                              UIEdgeInsetsMake(16.0f, 16.0f, 16.0f, 16.0f)]];
        } else {
            [card setBackgroundColor:[UIColor whiteColor]];
            RoundView(card, 8.0f);
        }
    }
    [sAccountPanel addSubview:card];
    AddStitchBorder(card, 6.0f);
    [card release];

    /* 圆形大头像：资料卡内左侧，白色描边 */
    sAccountBigAvatar = [[UIImageView alloc]
                         initWithFrame:CGRectMake(18.0f, kNavHeight + 20.0f, 100.0f, 100.0f)];
    [sAccountBigAvatar setContentMode:kContentModeScaleAspectFill];
    [sAccountBigAvatar setClipsToBounds:YES];
    RoundView(sAccountBigAvatar, 50.0f);
    [sAccountBigAvatar setBackgroundColor:[UIColor colorWithRed:0.90f green:0.90f blue:0.90f alpha:1.0f]];
    [sAccountPanel addSubview:sAccountBigAvatar];
    {
        NSString *av = p ? [p objectForKey:@"avatar"] : nil;
        UIImage *img = av ? ImageLoaderCachedImage(av) : nil;
        [sAccountBigAvatar setImage:img ? img : [UIImage imageNamed:@"Avatar"]];
        if (av) ImageLoaderRequest(av);
    }

    /* 昵称：白色卡片上用深色文字 */
    sAccountName = MakeLabel(CGRectMake(126.0f, kNavHeight + 26.0f, 110.0f, 24.0f), 15.0f, YES, 0.16f);
    [sAccountName setText:nm ? nm : @"已登录"];
    [sAccountPanel addSubview:sAccountName];

    /* 数字/性别/简介 */
    [self fillAccountPanel];

    /* 返回按钮：蓝条内水平居中，白色文字（与主界面导航条控件同一水平线） */
    UIButton *backBtn = [UIButton buttonWithType:kButtonTypeRounded];
    [backBtn setFrame:CGRectMake((pw - 80.0f) / 2.0f, 13.0f, 80.0f, 26.0f)];
    [backBtn setTitle:@"‹ 返回" forState:kControlStateNormal];
    [backBtn setTitleColor:[UIColor whiteColor] forState:kControlStateNormal];
    [[backBtn titleLabel] setFont:[UIFont boldSystemFontOfSize:15.0f]];
    [backBtn addTarget:self action:@selector(closeAccount:)
      forControlEvents:kControlEventTouchUpInside];
    [sAccountPanel addSubview:backBtn];

    /* 退出登录按钮：面板右下角，红色圆角警示款 */
    UIButton *logoutBtn = [UIButton buttonWithType:kButtonTypeRounded];
    [logoutBtn setFrame:CGRectMake(pw - 108.0f, h - 56.0f, 92.0f, 36.0f)];
    [logoutBtn setTitle:@"退出登录" forState:kControlStateNormal];
    [logoutBtn setTitleColor:[UIColor whiteColor] forState:kControlStateNormal];
    [logoutBtn setBackgroundColor:[UIColor colorWithRed:0.78f green:0.20f blue:0.20f alpha:1.0f]];
    RoundView(logoutBtn, 8.0f);
    [[logoutBtn titleLabel] setFont:[UIFont boldSystemFontOfSize:14.0f]];
    [logoutBtn addTarget:self action:@selector(logoutTapped:)
      forControlEvents:kControlEventTouchUpInside];
    [sAccountPanel addSubview:logoutBtn];

    [[self view] addSubview:sAccountPanel];

    sAccountAnimating = 1;
    [UIView beginAnimations:@"accountIn" context:(void *)3];
    [UIView setAnimationDuration:0.28];
    [UIView setAnimationCurve:kAnimationCurveEaseInOut];
    [UIView setAnimationDelegate:self];
    [UIView setAnimationDidStopSelector:@selector(accountAnimationDidStop:finished:context:)];
    [sAccountPanel setFrame:CGRectMake(0, 0, pw, h)];
    [UIView commitAnimations];
}

/* 退出登录：清数据/凭据 → 关面板 → 回热门 tab → 头像变登录 → 重新拉热门。
   关注/我的 的微博随 WeiboStoreLogout 一起被清空，下次需重新扫码登录。 */
- (void)logoutTapped:(id)sender
{
    (void)sender;
    WeiboStoreLogout();                    /* 清凭据 + 持久化标记 + 清空三个 tab 数据 */

    if (sSegment) [sSegment setSelectedSegmentIndex:0];
    layoutSegmentBlock();                 /* 退出回热门：浮块同步 */
    [self refreshAccountArea];            /* 头像 → 登录按钮 */

    /* 面板滑出动画；动画结束后 sAccountPanel 释放 */
    if (sAccountPanel && !sAccountAnimating) {
        CGFloat pw = CGRectGetWidth([sAccountPanel frame]);
        CGFloat ph = CGRectGetHeight([sAccountPanel frame]);
        sAccountAnimating = 1;
        [UIView beginAnimations:@"accountOut" context:(void *)4];
        [UIView setAnimationDuration:0.25];
        [UIView setAnimationCurve:kAnimationCurveEaseInOut];
        [UIView setAnimationDelegate:self];
        [UIView setAnimationDidStopSelector:@selector(accountAnimationDidStop:finished:context:)];
        [sAccountPanel setFrame:CGRectMake(-pw, 0, pw, ph)];
        [sAccountShade setAlpha:0.0f];
        [UIView commitAnimations];
    }

    /* 热门流游客可用，缓存已清，重新拉第一页 */
    WeiboStoreLoad();

#ifdef LOGOUTCHECK
    diag([[NSString stringWithFormat:@"LOGOUTCHECK: feed=%d logged=%d seg=%d panel=%@",
          WeiboStoreFeed(), WeiboStoreLoggedIn(),
          sSegment ? (int)[sSegment selectedSegmentIndex] : -1,
          sAccountPanel ? @"YES" : @"NO"] UTF8String]);
#endif
}

- (void)closeAccount:(id)sender
{
    (void)sender;
    if (!sAccountPanel || sAccountAnimating) return;
    CGFloat pw = CGRectGetWidth([sAccountPanel frame]);
    sAccountAnimating = 1;
    [UIView beginAnimations:@"accountOut" context:(void *)4];
    [UIView setAnimationDuration:0.25];
    [UIView setAnimationCurve:kAnimationCurveEaseInOut];
    [UIView setAnimationDelegate:self];
    [UIView setAnimationDidStopSelector:@selector(accountAnimationDidStop:finished:context:)];
    [sAccountPanel setFrame:CGRectMake(-pw, 0, pw, CGRectGetHeight([sAccountPanel frame]))];
    [sAccountShade setAlpha:0.0f];
    [UIView commitAnimations];
}

- (void)accountAnimationDidStop:(NSString *)animationID
                       finished:(id)finished
                        context:(void *)context
{
    (void)animationID; (void)finished;
    if (context == (void *)4) {
        if (sAccountPanel) { [sAccountPanel removeFromSuperview]; [sAccountPanel release]; sAccountPanel = nil; }
        if (sAccountShade) { [sAccountShade removeFromSuperview]; [sAccountShade release]; sAccountShade = nil; }
        sAccountBigAvatar = nil;
        sAccountName = nil;
    }
    sAccountAnimating = 0;
}

@end
