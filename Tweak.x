// XhsNoAutoRefresh — 小红书 iOS 客户端：禁止「一打开就自动刷新」
// ---------------------------------------------------------------------------
// 目标 App 包名：com.xingin.discover   ← ★ iOS 是这个！com.xingin.xhs 是【安卓】包名，别搞混
// 适用：iOS 14 ~ 17.0 + TrollStore（巨魔），用 TrollFools 注入 dylib
//
// 设计上直接继承了 BiliNoAutoRefresh 用真机血换来的四条铁律：
//   铁律 1：零 Logos、不依赖 CydiaSubstrate（Logos+substrate 在 TrollFools 下会闪退）
//   铁律 2：__attribute__((constructor)) 里只排延后任务，绝不碰 ObjC 运行时
//   铁律 3：本版【完全不写任何几何值】（不碰 contentOffset / contentInset / frame）
//   铁律 4：不断言线程——用 [NSThread isMainThread] 实测计数并打进弹窗
//
// v1.0.0 是【诊断版】：弹窗默认开着，装完先看数据再决定下一步。
// ---------------------------------------------------------------------------

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <ctype.h>

#pragma mark - 配置

static BOOL kBlockRefresh = YES;    // 总闸：NO = 只观察不拦（排障用）
static BOOL kShowAlert    = YES;    // v1.0.0 诊断版：切回前台弹一次统计。确认可用后改 NO
static BOOL kProbeTrigger = YES;    // 记录刷新来源（哪个页面 + 调用栈）

// 安全阀（逻辑是「任何异常情况一律放行」）
static BOOL   kStartupGrace      = YES;   // 阀①
static double kStartupGraceSecs  = 1.5;   // ★ 故意很短：B站那套 20 秒在这里会正好放过你要拦的那次
static BOOL   kSkipWhenEmptyView = YES;   // 阀②：列表还没内容 → 这是首屏加载，放行（★ 本插件的关键一条）
static BOOL   kBreakRetryLoop    = YES;   // 阀③
static double kCooldownSecs      = 30.0;

// ★ 用「前缀」而不是全等：万一包名有 .dev / .enterprise 之类的变体也不会失效
static const char *kTargetBundlePrefix = "com.xingin.";
static const char *kVersion            = "1.0.0";

static const NSInteger kStatePulling = 2;

// 类型垫片：避免把 objc_msgSend 强转成函数指针（clang 会报错）
@protocol XNRRefreshLike <NSObject>
- (NSInteger)state;
- (UIScrollView *)scrollView;
@end

#pragma mark - 基础工具

static const char *XNRClassNameC(id obj) {
    if (!obj) return NULL;
    Class c = object_getClass(obj);
    return c ? class_getName(c) : NULL;
}

static NSString *XNRClassName(id obj) {
    const char *n = XNRClassNameC(obj);
    return n ? [NSString stringWithUTF8String:n] : @"(nil)";
}

// 上拉加载更多用的 footer 一律不拦（只看类名，不碰 UIKit → 任何线程都安全）
static BOOL XNRIsFooter(id comp) {
    const char *n = XNRClassNameC(comp);
    return n && strstr(n, "Footer") != NULL;
}

// ★ 只能在主线程调用：沿响应链找宿主 VC，只用于日志
static UIViewController *XNRViewControllerOf(UIView *v) {
    if (!v) return nil;
    id r = v;
    for (int i = 0; i < 12 && r; i++) {
        if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
        if (![r isKindOfClass:[UIResponder class]]) break;
        r = [(UIResponder *)r nextResponder];
    }
    return nil;
}

static NSTimeInterval XNRNow(void) {
    return [NSDate timeIntervalSinceReferenceDate];
}

#pragma mark - 日志（低频：只在放行/拦截时写，不拖慢滚动）

static NSString *XNRLogPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/XNR_fix.log"];
}

static void XNRLogLine(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSLog(@"[XNR] %@", msg);

    @try {
        NSString *path = XNRLogPath();
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
        NSString *line = [NSString stringWithFormat:@"%@  %@\n", [NSDate date], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) return;
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (NSException *e) { (void)e; }
}

#pragma mark - 计数器 / 运行状态

static int  gHooked      = 0;    // 成功挂钩的类数
static int  gSeenBegin   = 0;    // -beginRefreshing 被调用次数
static int  gAllowBegin  = 0;    // 放行次数
static int  gBlockedBeg  = 0;    // 吃掉次数
static int  gSeenMain    = 0;    // 其中来自主线程的调用
static int  gSeenBG      = 0;    // 其中来自后台线程的调用
static int  gCooldownHit = 0;    // 熔断触发次数

// 「为什么放行」的分项计数（诊断用：这是判断插件是否按你预期工作的关键）
static int  gAllowEmpty  = 0;    // 列表还没内容 → 首屏加载
static int  gAllowUser   = 0;    // 用户自己在拖
static int  gAllowGrace  = 0;    // 启动宽限内
static int  gAllowCool   = 0;    // 熔断静默期
static int  gAllowFooter = 0;    // 上拉加载更多
static int  gAllowNoInfo = 0;    // 拿不到判断依据（宁可漏拦）

static BOOL gInstalled = NO;
static int  gInstallTries = 0;   // 第几轮尝试安装（用于日志与重试上限）

static NSTimeInterval gStartTime     = 0;
static NSTimeInterval gLastAllow     = 0;
static NSTimeInterval gCooldownUntil = 0;
static NSTimeInterval gBlockWinStart = 0;
static int            gBlockInWindow = 0;

static double gFirstSeenOffset = -1.0;   // ★ 首次触发发生在启动后多少秒（决定宽限该设多少）
static BOOL   gFirstSeenBlocked = NO;    // 首次触发是被吃掉了还是被放行了
static BOOL   gFirstSeenDone    = NO;    // 是否已经记过「首次触发」

static NSMutableArray *gHookedNames = nil;
static NSMutableArray *gFound       = nil;
static NSTimeInterval  gFoundLast   = 0;

static void XNRShowStats(void);   // 前置声明（定义在后面）

#pragma mark - 刷新控件判定（★ 只有 XNRIsFooter 允许在后台线程调用）

static NSInteger XNRStateOf(id comp) {
    id p = (id<XNRRefreshLike>)comp;
    @try {
        if ([p respondsToSelector:@selector(state)]) return [p state];
    } @catch (NSException *e) { (void)e; }
    return 1;   // Idle
}

static UIScrollView *XNRScrollViewOf(id comp) {
    id p = (id<XNRRefreshLike>)comp;
    @try {
        if ([p respondsToSelector:@selector(scrollView)]) {
            id sv = [p scrollView];
            if ([sv isKindOfClass:[UIScrollView class]]) return (UIScrollView *)sv;
        }
    } @catch (NSException *e) { (void)e; }
    return nil;
}

// 用户正在拖屏幕 → 手动下拉，必须放行。★ 只能在主线程调用
static BOOL XNRIsUserDriven(id comp) {
    if (XNRStateOf(comp) == kStatePulling) return YES;
    UIScrollView *sv = XNRScrollViewOf(comp);
    if (sv && (sv.isDragging || sv.isTracking || sv.isDecelerating)) return YES;
    return NO;
}

// 这一页是谁？（宿主 VC 的类名）★ 只能在主线程调用
static NSString *XNRPageOf(id comp) {
    UIScrollView *sv = XNRScrollViewOf(comp);
    if (!sv) return nil;
    UIViewController *vc = XNRViewControllerOf(sv);
    if (!vc) return nil;
    Class c = object_getClass(vc);
    const char *n = c ? class_getName(c) : NULL;
    return n ? [NSString stringWithUTF8String:n] : nil;
}

#pragma mark - 方法签名校验（防参数错位崩溃）

static const char *XNRNextType(const char *t) {
    if (!t) return NULL;
    while (*t && isdigit((unsigned char)*t)) t++;
    return (*t) ? t : NULL;
}

typedef enum {
    XNRSigVoidNoArg = 0       // v@:
} XNRSigKind;

// 只接受「返回值 void + self/_cmd 且没有多余参数」的签名，其余一律不碰
static BOOL XNRSigCheck(XNRSigKind kind, const char *t) {
    if (!t) return NO;
    const char *p = XNRNextType(t);    if (!p || *p != 'v') return NO;
    p = XNRNextType(p + 1);            if (!p || *p != '@') return NO;
    p = XNRNextType(p + 1);            if (!p || *p != ':') return NO;
    p = XNRNextType(p + 1);
    switch (kind) {
        case XNRSigVoidNoArg:
            return (p == NULL);
    }
    return NO;
}

#pragma mark - 动态挂钩表（(类, 方法) 双键；不用 Logos、不用 substrate）

typedef struct { Class cls; SEL sel; IMP imp; } XNRPatch;
static XNRPatch gPatches[32];
static int      gPatchCount = 0;

static IMP XNROrigFor(id self, SEL sel) {
    Class c = object_getClass(self);
    for (Class k = c; k != Nil; k = class_getSuperclass(k)) {
        for (int i = 0; i < gPatchCount; i++) {
            if (gPatches[i].cls == k && sel_isEqual(gPatches[i].sel, sel)) return gPatches[i].imp;
        }
    }
    return NULL;
}

// ★ 这个类「自己」实现过这个 SEL 吗？（不向父类递归 —— 这正是我们要的判定）
static BOOL XNRClassDefines(Class c, SEL sel) {
    if (!c || !sel) return NO;
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    if (!ms) return NO;
    BOOL found = NO;
    for (unsigned int i = 0; i < n; i++) {
        if (sel_isEqual(method_getName(ms[i]), sel)) { found = YES; break; }
    }
    free(ms);
    return found;
}

static BOOL XNRIsPatched(Class c, SEL sel) {
    for (int i = 0; i < gPatchCount; i++) {
        if (gPatches[i].cls == c && sel_isEqual(gPatches[i].sel, sel)) return YES;
    }
    return NO;
}

static BOOL XNRPatchMethod(Class c, SEL sel, IMP repl, XNRSigKind kind, const char **why) {
    if (!c || !sel || !repl) { if (why) *why = "空参数"; return NO; }
    if (XNRIsPatched(c, sel)) { if (why) *why = "已挂过"; return NO; }
    if (gPatchCount >= 32)    { if (why) *why = "表满";   return NO; }

    if (!XNRClassDefines(c, sel)) { if (why) *why = "继承来的(避碰父类)"; return NO; }

    Method m = class_getInstanceMethod(c, sel);
    if (!m) { if (why) *why = "方法不存在"; return NO; }
    const char *t = method_getTypeEncoding(m);
    if (!XNRSigCheck(kind, t)) { if (why) *why = t ? t : "无签名"; return NO; }

    IMP old = method_setImplementation(m, repl);
    if (!old || old == repl) { if (why) *why = "换实现失败"; return NO; }

    gPatches[gPatchCount].cls = c;
    gPatches[gPatchCount].sel = sel;
    gPatches[gPatchCount].imp = old;
    gPatchCount++;
    return YES;
}

#pragma mark - 取证：记下「哪个页面、被放行还是被拦」

// page 由调用方传入（主线程里取好），本函数自身不碰 UIKit
static void XNRRecordEvent(NSString *what, NSString *page, BOOL blocked) {
    if (!kProbeTrigger) return;
    NSTimeInterval now = XNRNow();
    if (now - gFoundLast < 1.5) return;      // 节流：最多每 1.5 秒记一条
    gFoundLast = now;

    @try {
        if (!gFound) gFound = [NSMutableArray array];
        if (gFound.count >= 4) return;       // 只留 4 条

        NSMutableArray *frames = [NSMutableArray array];
        for (NSString *s in [NSThread callStackSymbols]) {
            if ([s containsString:@"XNRHooked"] || [s containsString:@"XNRRecordEvent"]) continue;
            [frames addObject:s];
            if (frames.count >= 5) break;
        }
        NSString *line = [NSString stringWithFormat:@"%@ %@  页面: %@\n    ↳ %@",
                          blocked ? @"⛔️" : @"✅", what,
                          page ?: @"(未识别)",
                          [frames componentsJoinedByString:@"\n    ↳ "]];
        [gFound addObject:line];
        XNRLogLine(@"🔎 %@", line);
    } @catch (NSException *e) { (void)e; }
}

#pragma mark - 闸门决策（故障一律放行：宁可漏拦，绝不卡住界面）

typedef enum {
    XNRBlock             = 0,   // ★ 唯一会拦的分支
    XNRAllowFooter       = 1,   // 上拉加载更多
    XNRAllowEmpty        = 2,   // 列表还没内容 → 这是首屏加载
    XNRAllowUser         = 3,   // 用户自己在下拉
    XNRAllowGrace        = 4,   // 启动宽限内
    XNRAllowCooldown     = 5,   // 熔断静默期
    XNRAllowNoInfo       = 6    // 拿不到判断依据
} XNRDecision;

// ★ 线程纪律：非主线程时绝不读 UIKit。
//   在 B站 上实测过：钩子实际跑在主线程，但调用链可能源于 App 的线程池，
//   所以这里用「实测计数」而不是推断——判断依据也按「后台也能算的 / 必须主线程的」分成两组。
static XNRDecision XNRDecide(id comp) {
    if (!kBlockRefresh) return XNRAllowNoInfo;

    // —— 下面这两条不碰 UIKit，任何线程都能算 ——
    @try {
        if (XNRIsFooter(comp)) return XNRAllowFooter;
    } @catch (NSException *e) { (void)e; return XNRAllowNoInfo; }

    NSTimeInterval now = XNRNow();
    if (kStartupGrace && (now - gStartTime) < kStartupGraceSecs) return XNRAllowGrace;
    if (kBreakRetryLoop && now < gCooldownUntil) return XNRAllowCooldown;

    // —— 下面这些要读 UIKit，只在主线程做 ——
    if (![NSThread isMainThread]) return XNRAllowNoInfo;   // 后台线程：判不动 → 放行

    @try {
        // ② 用户自己在下拉 → 这是他主动要刷新
        if (XNRIsUserDriven(comp)) return XNRAllowUser;

        // ★ 关键一条：列表里还没有任何内容 → 这次刷新是在「加载首屏」，不是多余刷新 → 放行。
        //   这条替代了 B站 那套「启动宽限 20 秒」：因为我们要拦的恰恰是「一打开就刷新」，
        //   用时间宽限会正好把它放过；用「列表有没有内容」判断才既保首屏、又能拦到目标。
        if (kSkipWhenEmptyView) {
            UIScrollView *sv = XNRScrollViewOf(comp);
            if (!sv) return XNRAllowNoInfo;                // 拿不到列表 → 宁可漏拦
            if (sv.contentSize.height < 1.0) return XNRAllowEmpty;
        }
    } @catch (NSException *e) { (void)e; return XNRAllowNoInfo; }

    return XNRBlock;   // 页面已有内容，却还要自动刷新 → 这就是你要干掉的那一次
}

// 记录一次拦截；3 秒内拦太多次 → 判定为重试循环 → 熔断静默
static void XNRNoteBlocked(void) {
    NSTimeInterval now = XNRNow();
    if (now - gBlockWinStart > 3.0) { gBlockWinStart = now; gBlockInWindow = 0; }
    gBlockInWindow++;
    if (kBreakRetryLoop && gBlockInWindow > 6 && now >= gCooldownUntil) {
        gCooldownUntil = now + kCooldownSecs;
        __sync_fetch_and_add(&gCooldownHit, 1);
        XNRLogLine(@"⚠️ 3 秒内拦了 %d 次，疑似 App 在重试 → 熔断静默 %.0f 秒",
                   gBlockInWindow, kCooldownSecs);
    }
}

#pragma mark - 唯一的钩子：-beginRefreshing

static void XNRHookedBeginRefreshing(id self, SEL _cmd) {
    __sync_fetch_and_add(&gSeenBegin, 1);
    BOOL onMain = [NSThread isMainThread];
    if (onMain) __sync_fetch_and_add(&gSeenMain, 1);
    else        __sync_fetch_and_add(&gSeenBG, 1);

    // ★ 记下「首次触发」发生在启动后几秒 —— 这是判断启动宽限该设多少的关键数据
    BOOL isFirst = NO;
    @try {
        if (!gFirstSeenDone && gStartTime > 0) {
            gFirstSeenDone   = YES;
            gFirstSeenOffset = XNRNow() - gStartTime;
            gFirstSeenBlocked = NO;      // 下面若被拦会置 YES
            isFirst = YES;
        }
    } @catch (NSException *e) { (void)e; }

    XNRDecision d = XNRDecide(self);

    if (d == XNRBlock) {
        __sync_fetch_and_add(&gBlockedBeg, 1);
        if (isFirst) gFirstSeenBlocked = YES;
        XNRNoteBlocked();

        if (onMain) {
            if (gBlockedBeg <= 20) {
                XNRLogLine(@"⛔️ 拦截 beginRefreshing → %@  页面: %@",
                           XNRClassName(self), XNRPageOf(self) ?: @"(未识别)");
            }
            XNRRecordEvent([NSString stringWithFormat:@"beginRefreshing @ %@", XNRClassName(self)],
                           XNRPageOf(self), YES);
        } else {
            if (gBlockedBeg <= 20) {
                XNRLogLine(@"⛔️ 拦截 beginRefreshing（后台线程）→ %@", XNRClassName(self));
            }
            XNRRecordEvent([NSString stringWithFormat:@"beginRefreshing @ %@（后台线程）",
                            XNRClassName(self)], @"(后台线程触发)", YES);
        }
        // ★ 拦完什么都不做：不写几何值、不代叫 App 的 API、不弹窗。
        //   v1.0.0 刻意不带「收尾」——先确认拦得住、不闪退，再单独加收尾（一次只动一个变量）。
        return;
    }

    switch (d) {
        case XNRAllowFooter:   __sync_fetch_and_add(&gAllowFooter, 1); break;
        case XNRAllowEmpty:    __sync_fetch_and_add(&gAllowEmpty,  1); break;
        case XNRAllowUser:     __sync_fetch_and_add(&gAllowUser,   1); break;
        case XNRAllowGrace:    __sync_fetch_and_add(&gAllowGrace,  1); break;
        case XNRAllowCooldown: __sync_fetch_and_add(&gAllowCool,   1); break;
        case XNRAllowNoInfo:   __sync_fetch_and_add(&gAllowNoInfo, 1); break;
        case XNRBlock:         break;   // 不会走到这里：上面已经 return 了（列出以免 -Wswitch 告警）
    }

    __sync_fetch_and_add(&gAllowBegin, 1);
    gLastAllow = XNRNow();

    if (gAllowBegin <= 12) {
        XNRLogLine(@"✅ 放行 beginRefreshing → %@  原因代码 %d  页面: %@",
                   XNRClassName(self), (int)d,
                   onMain ? (XNRPageOf(self) ?: @"(未识别)") : @"(后台线程)");
    }

    IMP orig = XNROrigFor(self, _cmd);
    if (orig) ((void (*)(id, SEL))orig)(self, _cmd);
}

#pragma mark - 安装

static int XNRInstallGates(void) {
    if (gInstalled) return gHooked;

    SEL sBegin = @selector(beginRefreshing);
    NSMutableArray *names = [NSMutableArray array];
    NSMutableArray *notes = [NSMutableArray array];
    int n = 0;

    // ★★ 命中规则（框架无关）：只要某个类【自己实现】了 -beginRefreshing 且签名是 v@:，
    //    它就是刷新控件 —— 不管它是 MJRefresh、自研框架、还是 UIKit 自带的 UIRefreshControl。
    //    B站 那版是靠「类名里有没有 Refresh」猜的；小红书不一定用 MJRefresh，所以这里改成靠方法定义判定。
    unsigned int count = 0;
    Class *list = objc_copyClassList(&count);
    if (list) {
        for (unsigned int i = 0; i < count; i++) {
            Class c = list[i];
            if (!c) continue;
            const char *nm = class_getName(c);
            if (!nm) continue;

            // 便宜的前置过滤：整个继承链上都没有这个方法 → 直接跳过，省掉绝大部分扫描成本
            if (!class_getInstanceMethod(c, sBegin)) continue;

            const char *w = NULL;
            if (XNRPatchMethod(c, sBegin, (IMP)&XNRHookedBeginRefreshing, XNRSigVoidNoArg, &w)) {
                gHooked++; n++;
                [names addObject:[NSString stringWithUTF8String:nm]];
            } else if (w && strcmp(w, "继承来的(避碰父类)") && strcmp(w, "方法不存在")) {
                [notes addObject:[NSString stringWithFormat:@"%s 跳过(%s)", nm, w]];
            }
        }
        free(list);
    }

    gHookedNames = names;
    if (n > 0) gInstalled = YES;        // ★ 只有真的挂上了才算「装好」；否则等下一轮重试
    if (gStartTime <= 0) gStartTime = XNRNow();

    XNRLogLine(@"=== v%s 闸门安装（第 %d 轮）：%d 个 → %@  %@", kVersion, gInstallTries, n,
               names.count ? [names componentsJoinedByString:@", "] : @"(没有找到任何 -beginRefreshing 实现)",
               notes.count ? [notes componentsJoinedByString:@"; "] : @"");
    if (n > 0) {
        XNRLogLine(@"=== 安全阀：启动宽限 %.1fs(%@) / 空列表放行 %@ / 重试熔断 %@(%.0fs)",
                   kStartupGraceSecs, kStartupGrace ? @"开" : @"关",
                   kSkipWhenEmptyView ? @"开" : @"关",
                   kBreakRetryLoop ? @"开" : @"关", kCooldownSecs);
    }
    return n;
}

#pragma mark - 统计弹窗（只在用户主动切回前台时弹，且绝不在转场中弹）

static UIViewController *XNRRootVC(void) {
    @try {
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w.isKeyWindow && w.rootViewController) return w.rootViewController;
            }
        }
        return UIApplication.sharedApplication.keyWindow.rootViewController;
    } @catch (NSException *e) { (void)e; return nil; }
}

// ★ 稳定态检查：不在转场动画里才弹（v1.4.x 的自动弹窗就是栽在这上面）
static BOOL XNRCanPresent(void) {
    @try {
        UIViewController *vc = XNRRootVC();
        if (!vc) return NO;
        if (!vc.view.window) return NO;
        if (vc.isBeingPresented || vc.isBeingDismissed) return NO;
        if (vc.isMovingToParentViewController || vc.isMovingFromParentViewController) return NO;
        if (vc.transitionCoordinator != nil) return NO;
        if (vc.presentedViewController) return NO;
        return YES;
    } @catch (NSException *e) { (void)e; return NO; }
}

static void XNRAlert(NSString *title, NSString *msg, NSString *btn) {
    if (!kShowAlert) return;
    if (![NSThread isMainThread]) return;
    if (!XNRCanPresent()) return;
    @try {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                                  message:msg
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:btn style:UIAlertActionStyleDefault handler:nil]];
        [XNRRootVC() presentViewController:a animated:YES completion:nil];
    } @catch (NSException *e) { (void)e; }
}

static void XNRShowStats(void) {
    @try {
        // ★ 弹窗由 kShowAlert 控制；即使不弹窗，也照样把统计写进日志文件，
        //   这样「日常无打扰」和「留一条排障痕迹」可以兼得。
        if (gStartTime <= 0) return;
        if (XNRNow() - gStartTime < 15.0) return;    // 启动 15 秒内不打扰

        NSString *cls   = gHookedNames.count ? [gHookedNames componentsJoinedByString:@"\n"] : @"(一个都没挂钩上!)";
        NSString *hints = gFound.count ? [gFound componentsJoinedByString:@"\n\n"] : @"(还没捕捉到 —— 从装上到现在一次都没拦到过)";
        NSString *valve = [NSString stringWithFormat:@"启动宽限剩 %.1fs%@%@",
                           MAX(0.0, kStartupGraceSecs - (XNRNow() - gStartTime)),
                           (gCooldownUntil > XNRNow()) ? @"·熔断中" : @"",
                           gCooldownHit ? [NSString stringWithFormat:@"·熔断过 %d 次", gCooldownHit] : @""];

        // ★★ 这一行是 v1.0.0 最要紧的数据：它直接告诉你「你要拦的那次刷新发生在启动后几秒」
        NSString *first = (gFirstSeenOffset < 0)
            ? @"(还没触发过任何刷新)"
            : [NSString stringWithFormat:@"启动后 %.1f 秒 → %@",
               gFirstSeenOffset, gFirstSeenBlocked ? @"已吃掉 ⛔️" : @"被放行了 ✅"];

        NSString *lastAllow = (gLastAllow > 0)
            ? [NSString stringWithFormat:@"%.0f 秒前", XNRNow() - gLastAllow]
            : @"(还没有)";

        NSString *msg = [NSString stringWithFormat:
            @"挂钩类数: %d    %@\n\n"
             "beginRefreshing  触发 %d / 放行 %d / 吃掉 %d\n"
             "触发来源          主线程 %d / 后台线程 %d\n"
             "首次触发          %@\n"
             "最近一次放行       %@\n\n"
             "放行原因明细（判断插件是否按预期工作的关键）\n"
             "  列表还没内容(首屏加载)  %d\n"
             "  用户自己在拖            %d\n"
             "  启动宽限内             %d\n"
             "  上拉加载更多            %d\n"
             "  熔断静默期             %d\n"
             "  拿不到判断依据(放行)     %d\n\n"
             "挂钩的类:\n%@\n\n"
             "被吃掉的刷新（含调用栈）:\n%@",
            gHooked, valve,
            gSeenBegin, gAllowBegin, gBlockedBeg,
            gSeenMain, gSeenBG,
            first, lastAllow,
            gAllowEmpty, gAllowUser, gAllowGrace, gAllowFooter, gAllowCool, gAllowNoInfo,
            cls, hints];

        XNRLogLine(@"--- 前台统计：钩=%d 见=%d(主%d/后%d) 放行=%d 吃掉=%d 首次@%.1fs",
                   gHooked, gSeenBegin, gSeenMain, gSeenBG,
                   gAllowBegin, gBlockedBeg, gFirstSeenOffset);

        XNRAlert([NSString stringWithFormat:@"XhsNoRefresh v%s 统计", kVersion], msg, @"好");
    } @catch (NSException *e) { (void)e; }
}

#pragma mark - 加载入口
// ⚠️ dyld 阶段只排一个延后任务，绝不碰运行时、绝不弹窗（铁律 2）。

#define XNR_MAX_TRIES 5

static void XNRInstallWhenReady(int tries) {
    @try {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSString *prefix = [NSString stringWithUTF8String:kTargetBundlePrefix];
        if (![bid hasPrefix:prefix]) return;    // 只在目标 App 进程内动作

        gInstallTries = tries + 1;
        int n = XNRInstallGates();              // 内部有 gInstalled 守卫，成功过就不会再扫

        if (n > 0) return;                      // 挂上了，收工

        // 一个都没挂上 → 很可能 App 自己的库还没加载完 → 延后重试（间隔递增）
        if (tries + 1 >= XNR_MAX_TRIES) {
            XNRLogLine(@"⚠️ 试了 %d 轮都没找到任何 -beginRefreshing 实现 —— 小红书可能不走这个入口，"
                       @"需要换拦截点（看 XNR_fix.log 与弹窗）", XNR_MAX_TRIES);
            return;
        }
        int64_t ns = (int64_t)(0.5 * (double)(tries + 1) * NSEC_PER_SEC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ns), dispatch_get_main_queue(), ^{
            XNRInstallWhenReady(tries + 1);
        });
    } @catch (NSException *e) {
        XNRLogLine(@"⚠️ 安装过程抛异常：%@", e);
    }
}

__attribute__((constructor))
static void XNRInit(void) {
    // ★ 构造函数里【只排任务】，绝不扫类表、绝不动运行时（铁律 2）
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            XNRInstallWhenReady(0);
        });

        // 切回前台时汇报一次统计（含稳定态检查）
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            (void)note;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                XNRShowStats();
            });
        }];
    }
}
