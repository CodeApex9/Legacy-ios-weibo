# LegacyApp — 在 macOS 27 / Apple Silicon 上为越狱 iOS 5 / 6 / 7 构建 armv7 app
#
# 当前工程：iOS 6 微博「热门流」客户端（A 版系统原生拟物化风格）。
#   数据层 src/WeiboStore.m：异步 NSURLConnection + NSJSONSerialization，无中继。
#   图片层 src/ImageLoader.m：异步下载头像/配图 + 内存缓存，只刷新可见 cell。
#   界面层 src/RootViewController.m：52pt 蓝色渐变条 + 分组表格圆角白卡 +
#                                     自绘下拉刷新 + 详情滑入过渡动画。
#   纹理 src 同级的 scripts/make_assets.py 逐像素预渲染，设备端只显示位图。
#
#   make              构建 .app（默认 mini SDK，完全离线可编）
#   make ipa          构建并打包 build/LegacyApp.ipa
#   make verify       检查产物架构、最低系统版本、依赖库与签名
#   make SDK=full ipa 使用完整 iOS 9.3 SDK（需先跑 scripts/fetch-sdk.sh）
#   make DIAG=1 ipa   真机自检版（含 NetProbe.m；联网 + NSJSONSerialization，
#                     结果写设备 /tmp/legacy_boot.txt 与 /tmp/legacy_net.txt）
#   make DIAG=1 UIPROBE=1 ipa  只跑界面交互自检（下拉刷新/详情动画/图片解码），
#                     跳过 NetProbe 的同步请求，日志同样写 /tmp/legacy_boot.txt
#   make clean        清理（不会删除 Resources/Login.txt 登录凭据）
#
# 登录态：先跑 `python3 scripts/weibo_login.py --ip 192.168.8.171`，
# 手机微博扫码后脚本会生成 Resources/Login.txt 并注入设备；之后每次 make ipa
# 都会把这个文件一起打进 bundle。Cookie 由 .gitignore 排除，不入库。
#
# DIAG=1 会额外编译 src/NetProbe.m，用 NSURLConnection 依次请求
#   http://<Mac局域网IP>:8765/probe 与 https://m.weibo.cn/api/container/getIndex?...
# 前者是对照组，需要 Mac 上临时起一个 8765 端口的 HTTP 服务；IP 写在 NetProbe.m
# 里，换网络环境时改那一行即可。正常交付版不含此文件的任何代码。
#
# 目标设备：iPhone 4S (iOS 5) / iPhone 5 (iOS 6) / iPhone 5c、5s (iOS 7)
# 单一 armv7 二进制即可覆盖四台；5s 与 5 的 armv7s 也能运行 armv7。
#
# 【重要】不要给自定义类加 ObjC 实例变量(ivar)。本二进制跳过 crt1.o 手工链接，
# non-fragile ObjC2 ABI 的 _OBJC_IVAR_$ 偏移变量在 iOS 5/6 libobjc 上可能未
# 初始化，ivar 会读到对象起始的 isa(非零)而非 nil，曾导致 window 被判定为
# "已创建"而跳过、界面全黑。状态一律用 C 静态变量保存，见 AppDelegate.m。

SDK ?= mini
SDK_MODE ?= $(SDK)

# 链接一律走精简 stub：干净、只含 armv7 需要的符号，且已验证与 ld64 27106 兼容。
# 完整 SDK 的 patched tbd 混入 i386/x86_64，新版 ld64 会误判为 iOS-simulator。
STUB_ROOT := ../toolchain/mini-sdk

ifeq ($(SDK_MODE),full)
HEADER_ROOT := ../toolchain/sdks-repo/iPhoneOS9.3.sdk
INCDIR      := include/full
else
HEADER_ROOT := $(STUB_ROOT)
INCDIR      := include/mini
endif

ARCH    := armv7
TRIPLE  := armv7-apple-ios5.0
MIN_VER := 5.0
SDK_VER := 9.3

BUILD := build
APP   := $(BUILD)/Payload/LegacyApp.app
EXEC  := $(APP)/LegacyApp
OBJS  := $(BUILD)/main.o $(BUILD)/AppDelegate.o $(BUILD)/RootViewController.o \
         $(BUILD)/WeiboStore.o $(BUILD)/ImageLoader.o $(BUILD)/WeiboLogin.o \
         $(BUILD)/WeiboComments.o
# 头文件改动必须触发全量重编，否则 DIAG 与非 DIAG 的 .o 会混进同一个二进制
HEADERS := include/mini/LegacyKit.h include/full/LegacyKit.h \
           src/AppDelegate.h src/RootViewController.h src/WeiboStore.h \
           src/ImageLoader.h src/WeiboLogin.h src/WeiboComments.h src/Diag.h
# 真机联网自检模块只在 DIAG=1 时编译，不给正常交付版增加任何符号与体积
ifeq ($(DIAG),1)
OBJS += $(BUILD)/NetProbe.o
endif

CFLAGS := -target $(TRIPLE) -arch $(ARCH) -isysroot $(HEADER_ROOT) \
          -miphoneos-version-min=$(MIN_VER) -fobjc-runtime=ios-5.0 \
          -fno-objc-arc -fno-modules -O2 -I$(INCDIR) \
          -Wno-incompatible-sysroot -Wno-deprecated-declarations \
          -Wno-unguarded-availability -Wno-unused-parameter

# 真机启动自检：make DIAG=1 ipa 会在 /tmp/legacy_boot.txt 写启动标记
# make DIAG=1 UIPROBE=1 ipa：只跑界面交互自检（下拉刷新/详情动画/图片），
# 跳过 NetProbe 的同步网络请求，避免它阻塞主线程干扰时序。
ifeq ($(DIAG),1)
CFLAGS += -DLEGACY_DIAG=1
ifeq ($(UIPROBE),1)
CFLAGS += -DLEGACY_UI_PROBE=1
endif
ifeq ($(UIEXTRA),1)
CFLAGS += -DLEGACY_UI_EXTRA=1
ifneq ($(UIFEED),)
CFLAGS += -DUIFEED=$(UIFEED)
endif
ifeq ($(UIGEST),1)
CFLAGS += -DUIGEST=1
endif
ifeq ($(DETAILCHECK),1)
CFLAGS += -DDETAILCHECK=1
ifeq ($(DETAIL_NO_TAP),1)
CFLAGS += -DDETAIL_NO_TAP=1
endif
endif
endif
ifeq ($(ACCOUNTCHECK),1)
CFLAGS += -DACCOUNTCHECK=1
ifeq ($(ACCOUNT_CLOSE_CHECK),1)
CFLAGS += -DACCOUNT_CLOSE_CHECK=1
endif
endif
ifeq ($(LOGOUTCHECK),1)
CFLAGS += -DLOGOUTCHECK=1
endif
ifeq ($(FRIENDSCHECK),1)
CFLAGS += -DFRIENDSCHECK=1
endif
ifeq ($(SHOTCHECK),1)
CFLAGS += -DSHOTCHECK=1
endif
ifeq ($(COMMENTCHECK),1)
CFLAGS += -DCOMMENTCHECK=1
endif
ifeq ($(GALLERY),1)
CFLAGS += -DGALLERY=1
endif
endif

# 直接调用 ld64，由 LC_UNIXTHREAD 交给 dyld 启动 main()。
# 不链接 crt1.o：iOS 9.3 SDK 里那份是老式 ARM 汇编，ld64 27106 已不支持
# 它的 SECTDIFF 重定位；所需的 C 运行时全局在 main.m 里手工补齐。
# ld64 会依据 min version 5.0 自动选择 LC_UNIXTHREAD（iOS 5 可识别）。
# -no_pie：关掉 ASLR，避免老 dyld 对 PIE + LC_UNIXTHREAD 的 slide 处理差异，
#          也让各类越狱注入工具更容易处理；越狱分发不要求 PIE。
LDOPTS := -arch $(ARCH) -platform_version ios $(MIN_VER) $(SDK_VER) -e _main -no_pie
LDLIBS := -L$(STUB_ROOT)/usr/lib -F$(STUB_ROOT)/System/Library/Frameworks \
          -framework Foundation -framework UIKit \
          -framework CoreGraphics -framework CoreFoundation \
          -lobjc -lSystem

.PHONY: all app ipa verify clean help

all: app

$(BUILD)/%.o: src/%.m $(HEADERS)
	@mkdir -p $(BUILD)
	clang $(CFLAGS) -c $< -o $@

app: $(OBJS)
	@mkdir -p $(APP)
	ld $(LDOPTS) $(OBJS) $(LDLIBS) -o $(EXEC)
	cp Info.plist $(APP)/Info.plist
	printf 'APPL????' > $(APP)/PkgInfo
	python3 scripts/make_assets.py Resources
	cp Resources/*.png $(APP)/
	@# Login.txt 含账号凭据，只在扫码登录后才会出现；不存在时清掉旧副本
	@if [ -f Resources/Login.txt ]; then \
		cp Resources/Login.txt $(APP)/Login.txt; chmod 644 $(APP)/Login.txt; \
	else \
		rm -f $(APP)/Login.txt; \
	fi
	@if command -v ldid >/dev/null 2>&1; then \
		ldid -S $(EXEC); \
	else \
		codesign -f -s - $(EXEC); \
	fi
	@echo "构建完成: $(APP)"

ipa: app
	@cd $(BUILD) && rm -f LegacyApp.ipa && zip -qr LegacyApp.ipa Payload
	@echo "打包完成: $(BUILD)/LegacyApp.ipa"

verify: app
	@echo "=== 架构 ==="; file $(EXEC)
	@echo "=== 最低系统版本 ==="; vtool -show-build $(EXEC)
	@echo "=== 依赖库 ==="; otool -L $(EXEC)
	@echo "=== 签名 ==="; codesign -d -vvv $(EXEC) 2>&1 | head -8

clean:
	rm -rf $(BUILD)/*
	@# 清理生成的图片资源，但保留自定义 App 图标（Icon*.png）
	@for f in Resources/*.png; do \
		case "$$(basename "$$f")" in Icon.png|Icon@2x.png) ;; *) rm -f "$$f";; esac; \
	done

help:
	@echo "make / make ipa / make verify / make SDK=full ipa / make clean"
