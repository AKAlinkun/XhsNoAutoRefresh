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
// v1.0.2 是【探针定位版】：真机数据显示 7 个刷新控件全挂上了、但 -beginRefreshing 一次都没被调用
//        → 这次自动刷新根本不走这个入口。本版【不改拦截逻辑】，只加三个只读探针
//          （-setState: / -endRefreshing / -reloadData：只数数、记一条栈、原样转交原实现）
//          外加「闸门安装于启动后多少秒」，用来判断钩子是不是挂晚了。
// ---------------------------------------------------------------------------

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <ctype.h>

#pragma mark - 配置

static BOOL kBlockRefresh = YES;    // 总闸：NO = 只观察不拦（排障用）
static BOOL kShowAlert    = YES;    // 诊断/探针版：切回前台弹一次统计。确认可用后改 NO
static BOOL kProbeTrigger = YES;    // 记录刷新来源（哪个页面 + 调用栈）

// 安全阀（逻辑是「任何异常情况一律放行」）
// ★ 阀① 默认【关闭】：用户实测「打开小红书直接就刷新了」→ 这次刷新发生在启动后 1~2 秒内，
//   而 1.5 秒的启动宽限正好可能把它放过。首屏安全已经由阀②（空列表放行）负责，阀① 是多余的。
//   想重新打开就把下面改成 YES、秒数填上即可。
static BOOL   kStartupGrace      = NO;
static double kStartupGraceSecs  = 0.0;
static BOOL   kSkipWhenEmptyView = YES;   // 阀②：列表还没内容 → 这是首屏加载，放行（★ 本插件的关键一条）
static BOOL   kBreakRetryLoop    = YES;   // 阀③
static double kCooldownSecs      = 30.0;

// ★ v1.0.2：包名不再作为「装不装」的硬开关（见 XNRInstallWhenReady 注释）。
//   这里只用于日志和弹窗展示，方便一眼核对是不是目标 App。
static const char *kTargetBundlePrefix = "com.xingin.";
static const char *kVersion            = "1.0.2";

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
static NSString *gRealBundleID = nil;   // ★ 本进程真实包名 —— 排障第一信息，直接打进弹窗

static NSTimeInterval gStartTime     = 0;
static NSTimeInterval gLastAllow     = 0;
static NSTimeInterval gCooldownUntil = 0;
static NSTimeInterval gBlockWinStart = 0;
static int            gBlockInWindow = 0;

static double gFirstSeenOffset = -1.0;   // ★ 首次触发发生在启动后多少秒（决定宽限该设多少）
static BOOL   gFirstSeenBlocked = NO;    // 首次触发是被吃掉了还是被放行了
static BOOL   gFirstSeenDone    = NO;    // 是否已经记过「首次触发」

// ★★ v1.0.2 新增：只读探针（只数数、不改行为、一律调用原实现）
//    起因：真机数据显示「7 个刷新控件都挂上了，但 beginRefreshing 一次都没被调用」
//    → 说明小红书这次刷新不走 beginRefreshing。必须找出真正的驱动点。
static double gInstallOffset     = -1;   // 安装成功发生在启动后多少秒（判断是否漏掉了启动瞬间的刷新）
static int    gProbeReload       = 0;    // -reloadData 调用次数
static double gProbeReloadFirst  = -1;   // 首次 reloadData 距启动秒数

static int    gProbeSetState     = 0;    // -setState: 调用次数
static int    gProbeSetRefresh   = 0;    // 其中 state == 3(Refreshing) 的次数
static double gProbeSetFirst     = -1;   // 首次 setState:Refreshing 距启动秒数
static int    gProbeSetMaxState  = -1;   // 见过的最大 state 值

static int    gProbeEndRefresh   = 0;    // -endRefreshing 调用次数
static double gProbeEndFirst     = -1;   // 首次 endRefreshing 距启动秒数

static NSMutableArray *gHookedNames = nil;
static NSString      *gPerGateInfo  = nil;   // 每个挂钩各挂上了多少个类（弹窗里展示）

// ★ 取证按【事件类型】分开记账（v1.0.2）。
//   起因：v1.0.0/1.0.1 是全局限额 4 条 + 全局每 1.5 秒节流一条。
//   探针加上之后，启动瞬间会有好几个 reloadData 抢先把 4 条额度占满，
//   而最关键的 setState:Refreshing 因为落在节流窗口里被直接丢弃 ——
//   那就等于把最该留的证据亲手删了。现在每种事件各留 3 条、各自独立节流。
typedef enum { XNREvRefresh = 0, XNREvReload = 1, XNREvEnd = 2, XNREvSetState = 3, XNREvKindCount = 4 } XNREvKind;
#define XNR_EV_PER_KIND 3
static NSMutableArray *gEvLines[XNREvKindCount];
static NSTimeInterval  gEvLast[XNREvKindCount];

static BOOL XNRPresentStats(void);      // 前置声明（定义在后面）
static void XNRStatsRetry(int tries);   // 前置声明

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
    XNRSigVoidNoArg = 0,      // v@:
    XNRSigVoidIntArg = 1      // v@:q / v@:i / v@:l  （一个整数参数，用于 -setState:）
} XNRSigKind;

// ★ 关于 XNRSigVoidIntArg 里为什么连 'i'（32 位 int）也接受：
//    arm64 上写 32 位寄存器（w0）会把 64 位寄存器的上半部分清零，
//    而状态值只有 1~5 这种小正数，所以按 NSInteger 读出来仍然是对的。
//    退一步说，即使某个实现真的把高位塞了垃圾，后果也只是「计数偏了 / 等不上 3」，
//    绝不会崩溃 —— 因为 st 只被用于计数和比较，从不参与寻址或写回。
//    宁可多接受一种宽度，也不要因为签名不匹配而漏掉真正的刷新控件。

// 只接受完全匹配的签名，其余一律不碰
static BOOL XNRSigCheck(XNRSigKind kind, const char *t) {
    if (!t) return NO;
    const char *p = XNRNextType(t);    if (!p || *p != 'v') return NO;
    p = XNRNextType(p + 1);            if (!p || *p != '@') return NO;
    p = XNRNextType(p + 1);            if (!p || *p != ':') return NO;
    p = XNRNextType(p + 1);
    switch (kind) {
        case XNRSigVoidNoArg:
            return (p == NULL);
        case XNRSigVoidIntArg:
            if (!p) return NO;
            if (*p != 'q' && *p != 'i' && *p != 'l') return NO;
            return (XNRNextType(p + 1) == NULL);
    }
    return NO;
}

#pragma mark - 动态挂钩表（(类, 方法) 双键；不用 Logos、不用 substrate）

typedef struct { Class cls; SEL sel; IMP imp; } XNRPatch;
#define XNR_MAX_PATCHES 256      // v1.0.2：探针要挂 reloadData（定义它的类很多），表放大
static XNRPatch gPatches[XNR_MAX_PATCHES];
static int      gPatchCount = 0;
static int      gPatchSkipped = 0;   // 因表满被跳过的次数

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
    if (gPatchCount >= XNR_MAX_PATCHES) { gPatchSkipped++; if (why) *why = "表满"; return NO; }

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
// kind：按事件类型分开记账，各自 1.5 秒节流、各自留 3 条 —— 防止某一类事件把额度占满
static void XNRRecordEventKind(NSString *what, NSString *page, BOOL blocked, XNREvKind kind) {
    if (!kProbeTrigger) return;
    if (kind < 0 || kind >= XNREvKindCount) return;
    NSTimeInterval now = XNRNow();
    if (now - gEvLast[kind] < 1.5) return;   // 节流：同类事件最多每 1.5 秒记一条
    gEvLast[kind] = now;

    @try {
        if (!gEvLines[kind]) gEvLines[kind] = [NSMutableArray array];
        if (gEvLines[kind].count >= XNR_EV_PER_KIND) return;

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
        [gEvLines[kind] addObject:line];
        XNRLogLine(@"🔎 %@", line);
    } @catch (NSException *e) { (void)e; }
}

// 兼容旧调用点（拦截/放行都属于「beginRefreshing」这一类）
static void XNRRecordEvent(NSString *what, NSString *page, BOOL blocked) {
    XNRRecordEventKind(what, page, blocked, XNREvRefresh);
}

// 把所有类型的事件拼成一段给弹窗看
static NSString *XNRAllEvents(void) {
    NSMutableArray *all = [NSMutableArray array];
    static const char *names[XNREvKindCount] = { "刷新事件", "列表重载", "刷新结束", "状态被写" };
    for (int k = 0; k < XNREvKindCount; k++) {
        if (!gEvLines[k] || !gEvLines[k].count) continue;
        [all addObject:[NSString stringWithFormat:@"— %s —\n%@", names[k],
                        [gEvLines[k] componentsJoinedByString:@"\n\n"]]];
    }
    return all.count ? [all componentsJoinedByString:@"\n\n"] : @"";
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

#pragma mark - ★★ 只读探针（v1.0.2）：只数数 + 记一条调用栈，一律调用原实现
//  用途：真机数据显示 7 个刷新控件全挂上了、但 -beginRefreshing 一次都没被调用
//  → 说明这次刷新不走 beginRefreshing，必须找出真正的驱动点。
//  ★ 这三个探针【绝不改变任何行为】：数一下、可能记一条栈、然后原样调用原实现。

// ★ 只能在主线程调用：从任意 view（刷新控件本身就是 UIView）找宿主 VC 名，仅用于日志
static NSString *XNRPageOfAny(id obj) {
    @try {
        if (![NSThread isMainThread]) return @"(后台线程)";
        if ([obj isKindOfClass:[UIView class]]) {
            UIViewController *vc = XNRViewControllerOf((UIView *)obj);
            if (vc) {
                const char *n = class_getName(object_getClass(vc));
                if (n) return [NSString stringWithUTF8String:n];
            }
        }
    } @catch (NSException *e) { (void)e; }
    return @"";
}

static void XNRProbeNote(int *counter, double *firstField) {
    __sync_fetch_and_add(counter, 1);
    if (*counter == 1 && gStartTime > 0) *firstField = XNRNow() - gStartTime;
}

// ① 列表重载 —— 刷新必然伴随数据重载，用它可以定位「那一刻」和调用来源
static void XNRHookedReloadData(id self, SEL _cmd) {
    XNRProbeNote(&gProbeReload, &gProbeReloadFirst);
    if (gProbeReload <= 30) {
        XNRRecordEventKind([NSString stringWithFormat:@"reloadData @ %@", XNRClassName(self)],
                           XNRPageOfAny(self), NO, XNREvReload);
    }
    IMP orig = XNROrigFor(self, _cmd);
    if (orig) ((void (*)(id, SEL))orig)(self, _cmd);
}

// ② 刷新结束 —— 只要刷过，它一定会被调用。用它来判定「刷新确实发生了」
static void XNRHookedEndRefreshing(id self, SEL _cmd) {
    XNRProbeNote(&gProbeEndRefresh, &gProbeEndFirst);
    if (gProbeEndRefresh <= 30) {
        XNRRecordEventKind([NSString stringWithFormat:@"endRefreshing @ %@", XNRClassName(self)],
                           XNRPageOfAny(self), NO, XNREvEnd);
    }
    IMP orig = XNROrigFor(self, _cmd);
    if (orig) ((void (*)(id, SEL))orig)(self, _cmd);
}

// ③ 刷新状态被写 —— MJRefresh 的圈圈一定是通过它进入 Refreshing 态的。
//    如果 beginRefreshing 没被调用、它却被写成了 3，那就找到真凶了（调用栈会指出是谁写的）。
static void XNRHookedSetState(id self, SEL _cmd, NSInteger st) {
    __sync_fetch_and_add(&gProbeSetState, 1);
    if (st > gProbeSetMaxState) gProbeSetMaxState = (int)st;
    if (st == 3) {                                   // 3 = Refreshing
        __sync_fetch_and_add(&gProbeSetRefresh, 1);
        if (gProbeSetFirst < 0 && gStartTime > 0) gProbeSetFirst = XNRNow() - gStartTime;
        if (gProbeSetRefresh <= 30) {
            XNRRecordEventKind([NSString stringWithFormat:@"setState:Refreshing(3) @ %@", XNRClassName(self)],
                               XNRPageOfAny(self), NO, XNREvSetState);
        }
    }
    IMP orig = XNROrigFor(self, _cmd);
    if (orig) ((void (*)(id, SEL, NSInteger))orig)(self, _cmd, st);   // ★ 原样放行
}

#pragma mark - 安装

// 要挂的东西一览（v1.0.2 起改成表驱动，方便以后增删）
//   refreshControlOnly = YES → 只在「刷新控件家族」的类上挂；NO → 任何【自己实现】了这个方法的类都挂
//   ★ 「刷新控件家族」的判定（v1.0.2 定稿，框架无关）：
//       类名含 "Refresh"  或  该类自己实现了 -beginRefreshing
//     —— 单靠类名会漏掉名字奇怪的实现；单靠 beginRefreshing 会漏掉不实现它的自研控件。
//        两条并集，两边都不漏。
// ★ label 是 const char *（不是 NSString *）：这个数组是【静态存储期】的初始化器，
//   ObjC 的 @"..." 字面量在静态初始化里既不是编译期常量、类型也对不上，
//   clang 会直接以 -Werror,-Wincompatible-pointer-types 报错（v1.0.2 首轮 CI 就栽在这）。
//   → 静态初始化器里只允许 C 字符串字面量。
typedef struct {
    const char     *selName;
    IMP             repl;
    XNRSigKind      sig;
    BOOL            refreshControlOnly;
    const char     *label;
} XNRGateDef;

static const XNRGateDef gGateDefs[] = {
    { "beginRefreshing",  (IMP)&XNRHookedBeginRefreshing, XNRSigVoidNoArg,  NO,  "拦截+计数" },
    { "endRefreshing",    (IMP)&XNRHookedEndRefreshing,   XNRSigVoidNoArg,  YES, "探针:刷新结束" },
    { "setState:",        (IMP)&XNRHookedSetState,        XNRSigVoidIntArg, YES, "探针:状态被写" },
    { "reloadData",       (IMP)&XNRHookedReloadData,      XNRSigVoidNoArg,  NO,  "探针:列表重载" },
};
#define XNR_GATE_COUNT (sizeof(gGateDefs) / sizeof(gGateDefs[0]))

static BOOL XNRNameLooksLikeRefresh(const char *nm) {
    if (!nm) return NO;
    return strstr(nm, "Refresh") != NULL;
}

static BOOL XNRIsRefreshControl(Class c) {
    if (XNRNameLooksLikeRefresh(class_getName(c))) return YES;
    return XNRClassDefines(c, @selector(beginRefreshing));
}

static int XNRInstallGates(void) {
    if (gInstalled) return gHooked;

    NSMutableArray *names = [NSMutableArray array];   // beginRefreshing 命中的类（弹窗里展示）
    NSMutableArray *notes = [NSMutableArray array];
    NSMutableArray *perGate = [NSMutableArray array]; // 每个探针挂了多少个
    int n = 0;

    // ★★ 命中规则（框架无关）：只要某个类【自己实现】了目标方法且签名完全匹配，就挂它。
    //    B站 那版靠「类名里有没有 Refresh」猜；小红书实测用的是 MJRefresh + 自研 Swift 头 + RN 控件，
    //    类名五花八门，所以这里改成靠「方法定义」判定。
    unsigned int count = 0;
    Class *list = objc_copyClassList(&count);
    if (list) {
        for (unsigned int i = 0; i < count; i++) {
            Class c = list[i];
            if (!c) continue;
            const char *nm = class_getName(c);
            if (!nm) continue;

            BOOL isRefreshFamily = XNRIsRefreshControl(c);

            for (unsigned int g = 0; g < XNR_GATE_COUNT; g++) {
                const XNRGateDef *d = &gGateDefs[g];
                if (d->refreshControlOnly && !isRefreshFamily) continue;

                SEL sel = sel_registerName(d->selName);
                // 便宜的前置过滤：整条继承链上都没有这个方法 → 跳过
                if (!class_getInstanceMethod(c, sel)) continue;
                // 家族限定的探针，只挂在「刷新控件家族」的类上（避免挂到全 App 的 reloadData）
                if (!d->refreshControlOnly && strcmp(d->selName, "reloadData") == 0) {
                    // reloadData：只挂列表类（UICollectionView / UITableView 及其子类），别挂全 App
                    if (![c isSubclassOfClass:[UICollectionView class]] &&
                        ![c isSubclassOfClass:[UITableView class]]) continue;
                }

                const char *w = NULL;
                if (XNRPatchMethod(c, sel, d->repl, d->sig, &w)) {
                    gHooked++;
                    if (strcmp(d->selName, "beginRefreshing") == 0) { n++; [names addObject:[NSString stringWithUTF8String:nm]]; }
                } else if (w && strcmp(w, "继承来的(避碰父类)") && strcmp(w, "方法不存在") && strcmp(w, "已挂过")) {
                    [notes addObject:[NSString stringWithFormat:@"%s.%s 跳过(%s)", nm, d->selName, w]];
                }
            }
        }
        free(list);
    }

    for (unsigned int g = 0; g < XNR_GATE_COUNT; g++) {
        int cnt = 0;
        for (int i = 0; i < gPatchCount; i++) {
            if (sel_isEqual(gPatches[i].sel, sel_registerName(gGateDefs[g].selName))) cnt++;
        }
        [perGate addObject:[NSString stringWithFormat:@"%s=%d", gGateDefs[g].selName, cnt]];
    }

    gHookedNames = names;
    gPerGateInfo = perGate.count ? [perGate componentsJoinedByString:@" "] : @"";
    if (gPatchCount > 0) gInstalled = YES;      // ★ 有任何一个挂上了就算装好；否则等下一轮重试
    if (gStartTime <= 0) gStartTime = XNRNow();
    if (gInstallOffset < 0) gInstallOffset = XNRNow() - gStartTime;

    XNRLogLine(@"=== v%s 安装（第 %d 轮，启动后 %.1fs）：共 %d 处  %@",
               kVersion, gInstallTries, XNRNow() - gStartTime, gPatchCount,
               perGate.count ? [perGate componentsJoinedByString:@" "] : @"");
    XNRLogLine(@"     beginRefreshing 命中类(%d): %@", n,
               names.count ? [names componentsJoinedByString:@", "] : @"(无)");
    if (notes.count) XNRLogLine(@"     跳过: %@", [notes componentsJoinedByString:@"; "]);
    if (gPatchSkipped) XNRLogLine(@"     ⚠️ 有 %d 处因挂钩表满被跳过", gPatchSkipped);

    return (int)gPatchCount;
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

static BOOL XNRAlert(NSString *title, NSString *msg, NSString *btn) {
    if (!kShowAlert) return NO;
    if (![NSThread isMainThread]) return NO;
    if (!XNRCanPresent()) return NO;
    @try {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                                  message:msg
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:btn style:UIAlertActionStyleDefault handler:nil]];
        [XNRRootVC() presentViewController:a animated:YES completion:nil];
        return YES;
    } @catch (NSException *e) { (void)e; return NO; }
}

// 把「距启动多少秒」格式化成好看的一小段；没发生过就写明
static NSString *XNRFmtOff(double t) {
    if (t < 0) return @"未发生";
    return [NSString stringWithFormat:@"启动后 %.1fs", t];
}

// 返回 YES = 已经不需要再试了（弹成功 / 或本来就不需要弹）
static BOOL XNRPresentStats(void) {
    if (!kShowAlert) return YES;                     // 关掉了，没什么可重试
    if (gStartTime <= 0) return NO;
    if (XNRNow() - gStartTime < 10.0) return NO;     // 启动 10 秒内不打扰
    if (!XNRCanPresent()) return NO;                 // 不在稳定态 → 稍后重试

    @try {
        NSString *cls   = gHookedNames.count ? [gHookedNames componentsJoinedByString:@"\n"] : @"(没找到任何 -beginRefreshing 实现)";
        NSString *hints = XNRAllEvents();
        if (!hints.length) hints = @"(还没捕捉到 —— 从装上到现在什么事件都没记到)";
        NSString *valve = kStartupGrace
            ? [NSString stringWithFormat:@"启动宽限剩 %.1fs%@%@",
               MAX(0.0, kStartupGraceSecs - (XNRNow() - gStartTime)),
               (gCooldownUntil > XNRNow()) ? @"·熔断中" : @"",
               gCooldownHit ? [NSString stringWithFormat:@"·熔断过 %d 次", gCooldownHit] : @""]
            : [NSString stringWithFormat:@"启动宽限: 关（空列表放行 %@）%@",
               kSkipWhenEmptyView ? @"开" : @"关",
               gCooldownHit ? [NSString stringWithFormat:@"·熔断过 %d 次", gCooldownHit] : @""];

        // ★★ v1.0.1 新增：把「本进程真实包名」摆在最上面 —— 排障第一信息
        NSString *tgt   = [NSString stringWithUTF8String:kTargetBundlePrefix];
        NSString *bidLn = [NSString stringWithFormat:@"%@%@  (目标前缀 %@)",
                           gRealBundleID ?: @"(还没取到)",
                           (gRealBundleID && [gRealBundleID hasPrefix:tgt]) ? @"  ✓匹配" : @"  ✗不匹配",
                           tgt];

        // ★★ 这一行是判断启动宽限该设多少的关键数据
        NSString *first = (gFirstSeenOffset < 0)
            ? @"(还没触发过任何刷新)"
            : [NSString stringWithFormat:@"启动后 %.1f 秒 → %@",
               gFirstSeenOffset, gFirstSeenBlocked ? @"已吃掉 ⛔️" : @"被放行了 ✅"];

        NSString *lastAllow = (gLastAllow > 0)
            ? [NSString stringWithFormat:@"%.0f 秒前", XNRNow() - gLastAllow]
            : @"(还没有)";

        NSString *msg = [NSString stringWithFormat:
            @"本进程包名\n%@\n\n"
             "闸门安装于         %@\n"
             "各挂钩命中          %@\n"
             "挂钩类数: %d    %@\n\n"
             "beginRefreshing  触发 %d / 放行 %d / 吃掉 %d\n"
             "触发来源          主线程 %d / 后台线程 %d\n"
             "首次触发          %@\n"
             "最近一次放行       %@\n\n"
             "★ 只读探针（只数数，绝不改行为）\n"
             "  reloadData          %d 次   首次 %@\n"
             "  endRefreshing       %d 次   首次 %@\n"
             "  setState: 总写入     %d 次   (最大 state = %@)\n"
             "  └ 写入 Refreshing(3) %d 次   首次 %@\n\n"
             "放行原因明细（判断插件是否按预期工作的关键）\n"
             "  列表还没内容(首屏加载)  %d\n"
             "  用户自己在拖            %d\n"
             "  启动宽限内             %d\n"
             "  上拉加载更多            %d\n"
             "  熔断静默期             %d\n"
             "  拿不到判断依据(放行)     %d\n\n"
             "挂钩的类:\n%@\n\n"
             "抓到的事件（含调用栈，每类最多 3 条）:\n%@",
            bidLn,
            (gInstallOffset < 0) ? @"(还没装上)" : [NSString stringWithFormat:@"启动后 %.1f 秒", gInstallOffset],
            gPerGateInfo.length ? gPerGateInfo : @"(无)",
            gHooked, valve,
            gSeenBegin, gAllowBegin, gBlockedBeg,
            gSeenMain, gSeenBG,
            first, lastAllow,
            gProbeReload, XNRFmtOff(gProbeReloadFirst),
            gProbeEndRefresh, XNRFmtOff(gProbeEndFirst),
            gProbeSetState, (gProbeSetMaxState < 0) ? @"没写过" : [NSString stringWithFormat:@"%d", gProbeSetMaxState],
            gProbeSetRefresh, XNRFmtOff(gProbeSetFirst),
            gAllowEmpty, gAllowUser, gAllowGrace, gAllowFooter, gAllowCool, gAllowNoInfo,
            cls, hints];

        BOOL ok = XNRAlert([NSString stringWithFormat:@"XhsNoRefresh v%s 统计", kVersion], msg, @"好");
        if (ok) {
            XNRLogLine(@"--- 前台统计：包名=%@ 装于%.1fs 钩=%d 见=%d(主%d/后%d) 放行=%d 吃掉=%d 首次@%.1fs",
                       gRealBundleID, gInstallOffset, gHooked, gSeenBegin, gSeenMain, gSeenBG,
                       gAllowBegin, gBlockedBeg, gFirstSeenOffset);
            XNRLogLine(@"--- 探针：reloadData=%d(首%.1fs) endRefreshing=%d(首%.1fs) setState=%d(最大%d) 其中Refreshing=%d(首%.1fs)",
                       gProbeReload, gProbeReloadFirst,
                       gProbeEndRefresh, gProbeEndFirst,
                       gProbeSetState, gProbeSetMaxState,
                       gProbeSetRefresh, gProbeSetFirst);
        }
        return ok;
    } @catch (NSException *e) { (void)e; return NO; }
}

// ★ v1.0.1：弹窗不再是一次性尝试 —— 拿不到稳定态就每秒再试一次，最多 5 次。
//   起因：v1.0.0 只试一次，一旦那一刻正好在转场动画里，弹窗就永远不出现了，
//        用户看到的就是「装上了却毫无反应」，而这一点点随机性足以让人排查半天。
static void XNRStatsRetry(int tries) {
    if (XNRPresentStats()) return;
    if (tries >= 5) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        XNRStatsRetry(tries + 1);
    });
}


#pragma mark - 加载入口
// ⚠️ dyld 阶段只排一个延后任务，绝不碰运行时、绝不弹窗（铁律 2）。

#define XNR_MAX_TRIES 5

// ★★ v1.0.1 修正了一处【把自己取证通道堵死】的设计错误：
//    v1.0.0 里这里是 `if (![bid hasPrefix:prefix]) return;` —— 包名不匹配就直接返回，
//    而 gStartTime 只在 XNRInstallGates 里赋值，弹窗又有 `if (gStartTime <= 0) return;`。
//    结果：包名一旦对不上 → gStartTime 永远是 0 → 弹窗被自己掐死 →
//    现象变成「明明装上了却什么都不弹、也什么都不拦」，而且无法区分
//    「Dylib 没加载 / 包名不匹配 / 扫描没找到刷新类」这三种完全不同的原因。
//    教训：**给用户看的诊断输出，绝不能挂在「目标判定是否通过」下面。**
//    现在：无论包名是什么都往下走，包名只用于日志与弹窗展示；是否真动手由「扫不扫得到刷新类」决定。
static void XNRInstallWhenReady(int tries) {
    @try {
        if (!gRealBundleID) {
            gRealBundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"(拿不到)";
            NSString *tgt = [NSString stringWithUTF8String:kTargetBundlePrefix];
            XNRLogLine(@"=== 本进程包名: %@  |  目标前缀: %@  |  匹配: %@",
                       gRealBundleID, tgt,
                       [gRealBundleID hasPrefix:tgt] ? @"是" : @"否（但这版不再因此中止，继续尝试安装）");
        }

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
        // ★★ v1.0.1：gStartTime 在这里就落地，**不再依赖安装是否成功**。
        //    这样「弹窗能不能弹出来」就与「包名/扫描结果」彻底解耦 ——
        //    只要 Dylib 被加载了，弹窗就一定会弹，我们才能拿到数据。
        if (gStartTime <= 0) gStartTime = XNRNow();

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
                XNRStatsRetry(0);
            });
        }];
    }
}
