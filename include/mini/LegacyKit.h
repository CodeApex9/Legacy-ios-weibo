#ifndef LEGACY_KIT_H
#define LEGACY_KIT_H

/*
 * LegacyKit.h (mini 模式)
 * 精简版 iOS 5 / 6 / 7 接口声明，用于在 macOS 27 + Apple Silicon 上
 * 不依赖完整 Xcode SDK 直接交叉编译 armv7 应用。
 *
 * 这里只声明用到的类与方法。要用新的系统类时，在本文件补一条
 * @interface 声明，并在 toolchain/mini-sdk 对应 .tbd 里补上
 * _OBJC_CLASS_$_XXX 符号即可。用 make SDK=full 可切换到完整 iOS 9.3 SDK 头。
 *
 * 【注意】自定义类不要声明实例变量(ivar)，状态请用 C 静态变量：
 * 手工链接的 non-fragile ABI 二进制在 iOS 5/6 上 ivar 偏移可能未初始化，
 * 会读到 isa 而非 nil。详见 AppDelegate.m 顶部说明。
 */

typedef signed char BOOL;
#define YES ((BOOL)1)
#define NO  ((BOOL)0)

typedef struct objc_object   *id;
typedef struct objc_selector *SEL;
typedef struct objc_class    *Class;

#ifndef nil
#define nil ((id)0)
#endif
#ifndef Nil
#define Nil ((Class)0)
#endif

typedef int           NSInteger;
typedef unsigned int  NSUInteger;
typedef float         CGFloat;

typedef struct { CGFloat x; CGFloat y; } CGPoint;
typedef struct { CGFloat width; CGFloat height; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;
typedef struct { CGFloat top; CGFloat left; CGFloat bottom; CGFloat right; } UIEdgeInsets;
/* a,b,c,d 为缩放/旋转分量，tx,ty 为平移 */
typedef struct { CGFloat a; CGFloat b; CGFloat c; CGFloat d; CGFloat tx; CGFloat ty; } CGAffineTransform;

static inline CGPoint CGPointMake(CGFloat x, CGFloat y) { CGPoint p; p.x = x; p.y = y; return p; }
static inline CGSize  CGSizeMake(CGFloat w, CGFloat h)  { CGSize s; s.width = w; s.height = h; return s; }
static inline CGRect  CGRectMake(CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
    CGRect r; r.origin = CGPointMake(x, y); r.size = CGSizeMake(w, h); return r;
}
static inline UIEdgeInsets UIEdgeInsetsMake(CGFloat t, CGFloat l, CGFloat b, CGFloat r) {
    UIEdgeInsets e; e.top = t; e.left = l; e.bottom = b; e.right = r; return e;
}
static inline CGFloat CGRectGetWidth(CGRect r)  { return r.size.width; }
static inline CGFloat CGRectGetHeight(CGRect r) { return r.size.height; }
static inline CGFloat CGRectGetMidX(CGRect r)   { return r.origin.x + r.size.width / 2; }
static inline CGFloat CGRectGetMidY(CGRect r)   { return r.origin.y + r.size.height / 2; }
static inline CGFloat CGRectGetMaxY(CGRect r)   { return r.origin.y + r.size.height; }

/* CoreGraphics C 函数（mini SDK tbd 已登记符号） */
extern CGAffineTransform CGAffineTransformMakeScale(CGFloat sx, CGFloat sy);
extern CGAffineTransform CGAffineTransformScale(CGAffineTransform t, CGFloat sx, CGFloat sy);
extern CGAffineTransform CGAffineTransformMakeTranslation(CGFloat tx, CGFloat ty);
extern const CGAffineTransform CGAffineTransformIdentity;

/* 数值取自 iOS 5~7 公开枚举，写成常量避免不同 SDK 命名差异 */
#define kTextAlignCenter           1
#define kTextAlignLeft             0
#define kButtonTypeRounded         0
#define kControlStateNormal        0
#define kControlEventTouchUpInside (1 << 6)
#define kContentModeScaleToFill    0
#define kContentModeScaleAspectFit 1
#define kContentModeScaleAspectFill 2
#define kIndicatorStyleGray        2
#define kAnimationCurveEaseInOut  0
#define kCellSelectionStyleNone   0
#define kControlEventValueChanged  (1 << 12)
#define kSegmentedStyleBar         2
/* UIControlState：iOS 5 起选中态为 1<<2，高亮为 1<<0 */
#define kControlStateHighlighted   1
#define kControlStateSelected      4
#define kBarMetricsDefault         0
/* UITextAttribute* 字符串常量的真实值，写成字面量避免链接期符号 */
#define kUITextAttributeFont             @"UITextAttributeFont"
#define kUITextAttributeTextColor        @"UITextAttributeTextColor"
#define kUITextAttributeTextShadowColor  @"UITextAttributeTextShadowColor"
#define kUITextAttributeTextShadowOffset @"UITextAttributeTextShadowOffset"

/* Foundation */
@interface NSObject
+ (id)alloc;
- (id)init;
- (id)retain;
- (oneway void)release;
- (id)autorelease;
- (void)dealloc;
+ (Class)class;
- (Class)class;
- (BOOL)respondsToSelector:(SEL)selector;
- (BOOL)isKindOfClass:(Class)cls;
- (void)performSelector:(SEL)selector withObject:(id)object afterDelay:(double)delay;
@end

@interface NSString : NSObject
+ (id)stringWithFormat:(NSString *)format, ...;
+ (id)stringWithUTF8String:(const char *)s;
- (NSUInteger)length;
- (const char *)UTF8String;
- (BOOL)isEqualToString:(NSString *)other;
- (BOOL)hasPrefix:(NSString *)prefix;
- (float)floatValue;
- (int)intValue;
@end

@interface NSMutableString : NSString
- (void)appendString:(NSString *)other;
- (void)appendFormat:(NSString *)format, ...;
@end

@interface NSNumber : NSObject
+ (NSNumber *)numberWithInt:(int)value;
- (int)intValue;
- (NSInteger)integerValue;
- (NSString *)stringValue;   /* 微博 max_id 是 64 位数字，只能用字符串取，避免 int 截断 */
@end

/* NSValue：UITextAttributeTextShadowOffset 需要它包一个 CGSize */
@interface NSValue : NSObject
+ (NSValue *)valueWithCGSize:(CGSize)size;
@end

@interface NSArray : NSObject
+ (id)arrayWithObjects:(id)firstObj, ...;
+ (NSArray *)arrayWithObject:(id)obj;
- (NSUInteger)count;
- (id)objectAtIndex:(NSUInteger)index;
@end

#define NSNotFound ((NSInteger)-1)

@interface NSMutableArray : NSArray
- (void)addObject:(id)obj;
- (void)addObjectsFromArray:(NSArray *)other;
@end

@interface NSDictionary : NSObject
- (id)objectForKey:(id)key;
- (NSUInteger)count;
- (NSArray *)allValues;
@end

@interface NSMutableDictionary : NSDictionary
- (void)setObject:(id)obj forKey:(id)key;
@end

@interface NSData : NSObject
+ (id)dataWithContentsOfFile:(NSString *)path;
- (BOOL)writeToFile:(NSString *)path atomically:(BOOL)flag;
- (NSUInteger)length;
- (const void *)bytes;
@end

@interface NSMutableData : NSData
- (void)appendData:(NSData *)data;
- (void)setLength:(NSUInteger)length;
@end

@interface NSURL : NSObject
+ (id)URLWithString:(NSString *)s;
@end

@interface NSURLRequest : NSObject
+ (id)requestWithURL:(NSURL *)url
          cachePolicy:(NSUInteger)policy
      timeoutInterval:(double)seconds;
@end

@interface NSMutableURLRequest : NSURLRequest
+ (id)requestWithURL:(NSURL *)url
         cachePolicy:(NSUInteger)policy
     timeoutInterval:(double)seconds;
- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field;
- (void)setHTTPMethod:(NSString *)method;
@end

@interface NSURLResponse : NSObject
- (NSURL *)URL;
@end

@interface NSHTTPURLResponse : NSURLResponse
- (NSDictionary *)allHeaderFields;
- (NSInteger)statusCode;
@end

@interface NSError : NSObject @end

@interface NSTimer : NSObject
+ (NSTimer *)scheduledTimerWithTimeInterval:(double)seconds
                                    target:(id)target
                                  selector:(SEL)selector
                                  userInfo:(id)userInfo
                                   repeats:(BOOL)repeats;
- (void)invalidate;
@end

@interface NSHTTPCookie : NSObject
- (NSString *)name;
- (NSString *)value;
@end

@interface NSHTTPCookieStorage : NSObject
+ (NSHTTPCookieStorage *)sharedHTTPCookieStorage;
- (NSArray *)cookies;
@end

NSString *NSHomeDirectory(void);

@interface NSURLConnection : NSObject
- (id)initWithRequest:(NSURLRequest *)request
              delegate:(id)delegate
     startImmediately:(BOOL)startNow;
- (void)start;
- (void)cancel;
@end

@interface NSJSONSerialization : NSObject
+ (id)JSONObjectWithData:(NSData *)data
                   options:(NSUInteger)options
                     error:(id *)error;
@end

@interface NSIndexPath : NSObject
+ (id)indexPathForRow:(NSInteger)row inSection:(NSInteger)section;
- (NSInteger)row;
- (NSInteger)section;
@end

@interface NSBundle : NSObject
+ (NSBundle *)mainBundle;
- (id)objectForInfoDictionaryKey:(NSString *)key;
- (NSString *)pathForResource:(NSString *)name ofType:(NSString *)ext;
- (NSString *)bundlePath;
@end

@interface NSAutoreleasePool : NSObject
- (void)drain;
@end

void NSLog(NSString *format, ...);
NSString *NSStringFromClass(Class cls);

/* UIKit */
@interface UIResponder : NSObject @end

@interface UIView : UIResponder
- (id)initWithFrame:(CGRect)frame;
- (void)addSubview:(UIView *)view;
- (void)removeFromSuperview;
- (void)setBackgroundColor:(id)color;
- (void)setFrame:(CGRect)frame;
- (CGRect)frame;
- (CGRect)bounds;
- (void)setHidden:(BOOL)hidden;
- (id)hitTest:(CGPoint)point withEvent:(id)event;   /* 自检用：确认按钮命中 */
- (BOOL)isHidden;
- (void)setAlpha:(CGFloat)alpha;
- (void)setTag:(NSInteger)tag;
- (NSInteger)tag;
- (id)viewWithTag:(NSInteger)tag;
- (id)superview;
- (id)layer;                                  /* CALayer；只做消息发送，无需链接 QuartzCore */
- (void)setContentMode:(NSInteger)mode;
- (void)setClipsToBounds:(BOOL)flag;
- (void)setUserInteractionEnabled:(BOOL)flag;
- (void)setTransform:(CGAffineTransform)t;
- (CGAffineTransform)transform;
- (void)addGestureRecognizer:(id)recognizer;
- (CGPoint)center;
- (void)setCenter:(CGPoint)center;
/* iOS 2.0 起就有的老式 UIView 动画，不用 block，避开 blocks runtime 依赖 */
+ (void)beginAnimations:(NSString *)animationID context:(void *)context;
+ (void)setAnimationDuration:(double)duration;
+ (void)setAnimationCurve:(NSInteger)curve;
+ (void)setAnimationDelegate:(id)delegate;
+ (void)setAnimationDidStopSelector:(SEL)selector;
+ (void)commitAnimations;
@end

@class UIImage;

@interface UIColor : NSObject
+ (UIColor *)whiteColor;
+ (UIColor *)blackColor;
+ (UIColor *)clearColor;
+ (UIColor *)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a;
/* 平铺贴图做底色（iOS 2.0 起可用）：V0.3 用它把 1pt 缝线铺成等距虚线 */
+ (UIColor *)colorWithPatternImage:(UIImage *)image;
@end

@interface UIFont : NSObject
+ (UIFont *)systemFontOfSize:(CGFloat)size;
+ (UIFont *)boldSystemFontOfSize:(CGFloat)size;
@end

@interface UIImage : NSObject
+ (UIImage *)imageNamed:(NSString *)name;
+ (UIImage *)imageWithData:(NSData *)data;
- (UIImage *)resizableImageWithCapInsets:(UIEdgeInsets)capInsets;  /* iOS 5+，锁定四角只拉伸中段 */
@end

@interface UIImageView : UIView
- (void)setImage:(UIImage *)image;
- (UIImage *)image;
@end

@interface UILabel : UIView
- (void)setText:(NSString *)text;
- (void)setFont:(UIFont *)font;
- (void)setTextColor:(UIColor *)color;
- (void)setBackgroundColor:(UIColor *)color;
- (void)setTextAlignment:(NSInteger)alignment;
- (void)setNumberOfLines:(NSInteger)lines;
- (void)setShadowColor:(UIColor *)color;
- (void)setShadowOffset:(CGSize)offset;
@end

@interface UIControl : UIView
- (void)addTarget:(id)target action:(SEL)action forControlEvents:(NSUInteger)events;
- (void)sendActionsForControlEvents:(NSUInteger)controlEvents;
@end

@interface UIButton : UIControl
+ (id)buttonWithType:(NSInteger)type;
- (UILabel *)titleLabel;
- (void)setTitle:(NSString *)title forState:(NSUInteger)state;
- (void)setTitleColor:(UIColor *)color forState:(NSUInteger)state;
- (void)setBackgroundImage:(UIImage *)image forState:(NSUInteger)state;
- (void)setTitleShadowColor:(UIColor *)color forState:(NSUInteger)state;
@end

@interface UIScrollView : UIView
- (CGPoint)contentOffset;
- (CGSize)contentSize;
- (void)setContentOffset:(CGPoint)offset animated:(BOOL)animated;
- (void)setContentInset:(UIEdgeInsets)insets;
- (void)setContentSize:(CGSize)size;
- (void)setShowsVerticalScrollIndicator:(BOOL)show;
- (void)setPagingEnabled:(BOOL)enabled;
- (void)setShowsHorizontalScrollIndicator:(BOOL)show;
- (void)setBounces:(BOOL)bounces;
- (void)setDelegate:(id)delegate;
- (void)setMinimumZoomScale:(CGFloat)scale;
- (void)setMaximumZoomScale:(CGFloat)scale;
- (void)setZoomScale:(CGFloat)scale animated:(BOOL)animated;
- (CGFloat)zoomScale;
@end

/* 手势：state 常量取自 UIGestureRecognizerState（iOS 5 起） */
#define kGestureStateBegan   1
#define kGestureStateChanged 2
#define kGestureStateEnded   3

@interface UIGestureRecognizer : NSObject
- (id)initWithTarget:(id)target action:(SEL)action;
- (void)addTarget:(id)target action:(SEL)action;
- (NSInteger)state;
- (void)setEnabled:(BOOL)enabled;
@end

@interface UITapGestureRecognizer : UIGestureRecognizer
- (void)setNumberOfTapsRequired:(NSUInteger)n;
- (NSUInteger)numberOfTapsRequired;
@end

@interface UIPinchGestureRecognizer : UIGestureRecognizer
- (CGFloat)scale;
- (void)setScale:(CGFloat)scale;
- (CGFloat)velocity;
@end

@interface UIPanGestureRecognizer : UIGestureRecognizer
- (CGPoint)translationInView:(UIView *)view;
- (void)setTranslation:(CGPoint)translation inView:(UIView *)view;
- (CGFloat)velocityInView:(UIView *)view;
@end

@interface UITableView : UIScrollView
- (id)initWithFrame:(CGRect)frame style:(NSInteger)style;
- (void)setDataSource:(id)dataSource;
- (void)setDelegate:(id)delegate;
- (void)setRowHeight:(CGFloat)height;
- (void)reloadData;
- (id)dequeueReusableCellWithIdentifier:(NSString *)identifier;
- (void)deselectRowAtIndexPath:(NSIndexPath *)indexPath animated:(BOOL)animated;
- (id)cellForRowAtIndexPath:(NSIndexPath *)indexPath;
- (NSIndexPath *)indexPathForCell:(id)cell;
- (NSArray *)visibleCells;
- (void)setTableFooterView:(UIView *)view;
- (void)setBackgroundView:(UIView *)view;
@end

@interface UITableViewCell : UIView
- (id)initWithStyle:(NSInteger)style reuseIdentifier:(NSString *)identifier;
- (UIView *)contentView;
- (UILabel *)textLabel;
- (UILabel *)detailTextLabel;
- (UIImageView *)imageView;
- (void)setAccessoryType:(NSInteger)type;
- (void)setSelectionStyle:(NSInteger)style;
@end

@interface UIActivityIndicatorView : UIView
- (id)initWithActivityIndicatorStyle:(NSInteger)style;
- (void)startAnimating;
- (void)stopAnimating;
- (void)setHidesWhenStopped:(BOOL)hides;
@end

@interface UISegmentedControl : UIControl
- (id)initWithItems:(NSArray *)items;
- (void)setSegmentedControlStyle:(NSInteger)style;
- (void)setSelectedSegmentIndex:(NSInteger)index;
- (NSInteger)selectedSegmentIndex;
- (void)setTintColor:(UIColor *)color;
/* iOS 5 起支持的分段皮肤 API，真机完整实现，方法走运行时派发不需 tbd 符号 */
- (void)setBackgroundImage:(UIImage *)image forState:(NSInteger)state barMetrics:(NSInteger)barMetrics;
- (void)setDividerImage:(UIImage *)image forLeftSegmentState:(NSInteger)leftState rightSegmentState:(NSInteger)rightState barMetrics:(NSInteger)barMetrics;
- (void)setTitleTextAttributes:(NSDictionary *)attributes forState:(NSInteger)state;
@end

/* 只借这个壳给 CALayer 的方法一个编译器可见的类型，不实例化、不链接符号 */
@interface LegacyLayerShim : NSObject
- (void)setCornerRadius:(CGFloat)radius;
- (void)setMasksToBounds:(BOOL)flag;
- (void)setShadowOpacity:(CGFloat)opacity;
- (void)setShadowOffset:(CGSize)offset;
- (void)setShadowRadius:(CGFloat)radius;
- (void)renderInContext:(void *)ctx;   /* ctx 真实类型 CGContextRef，截图用 */
@end

@interface UITextView : UIScrollView
- (void)setText:(NSString *)text;
- (void)setEditable:(BOOL)editable;
- (void)setFont:(UIFont *)font;
- (void)setTextColor:(UIColor *)color;
@end

@interface UIScreen : NSObject
+ (UIScreen *)mainScreen;
- (CGRect)bounds;
- (CGRect)applicationFrame;
@end

@interface UIDevice : NSObject
+ (UIDevice *)currentDevice;
- (NSString *)systemVersion;
- (NSString *)model;
- (NSString *)name;
@end

@interface UIApplication : UIResponder
+ (UIApplication *)sharedApplication;
- (void)setStatusBarHidden:(BOOL)hidden;
@end

@interface UIWindow : UIView
- (void)setRootViewController:(id)viewController;
- (void)makeKeyAndVisible;
@end

@interface UIViewController : UIResponder
- (UIView *)view;
- (void)setView:(UIView *)view;
- (void)loadView;
- (void)viewDidLoad;
@end

int UIApplicationMain(int argc, char *argv[], NSString *principalClassName, NSString *delegateClassName);

/* 离屏渲染截图（自检用）：把 UIView 层级渲染成 PNG 写文件，设备无 screencapture 时验证界面 */
void UIGraphicsBeginImageContext(CGSize size);
void UIGraphicsBeginImageContextWithOptions(CGSize size, BOOL opaque, CGFloat scale);
void *UIGraphicsGetCurrentContext(void);
id   UIGraphicsGetImageFromCurrentImageContext(void);
void UIGraphicsEndImageContext(void);
id   UIImagePNGRepresentation(id image);

#endif /* LEGACY_KIT_H */
