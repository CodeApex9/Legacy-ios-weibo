#ifndef LEGACY_KIT_H
#define LEGACY_KIT_H

/*
 * LegacyKit.h (full 模式)
 * 完整 SDK 模式：直接使用 toolchain/sdks-repo/iPhoneOS9.3.sdk 的头文件。
 * 用 make SDK=full 启用。数值常量与 mini 模式保持一致，
 * 避免 iOS 9.3 SDK 里枚举改名带来的差异。
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>

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
#define kGestureStateBegan         1
#define kGestureStateChanged       2
#define kGestureStateEnded         3

/* 与 mini 模式一致：借壳给 CALayer 的方法一个编译器可见的类型 */
@interface LegacyLayerShim : NSObject
- (void)setCornerRadius:(CGFloat)radius;
- (void)setMasksToBounds:(BOOL)flag;
@end

#endif /* LEGACY_KIT_H */
