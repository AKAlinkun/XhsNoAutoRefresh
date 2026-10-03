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
// v1.0.3 是【早期安装版】：上一版那个数字给出的答案很干脆 —— 闸门装于「启动后 4.2 秒」，
//        而刷新发生在 1~2 秒。**不是入口选错，是时间不对。**
//        本版【只改安装时机这一个机制】：后台队列尽早起步（首轮延迟 40ms）+ 持续重扫到 3 秒
//        （收编晚加载的框架）+「已扫过的类」哈希集合（让重扫不拖慢 App）。
//        另加两项只读观测：
//          ① 轮询 scrollView.refreshControl.isRefreshing —— 回答「那个圈圈是不是 UIRefreshControl」
//             （它由 scrollView 内部驱动时不走 -beginRefreshing）
//          ② 轮询 contentOffset / adjustedContentInset —— 「列表是不是被程序性地拉下去了」
//             这一路【完全不依赖任何挂钩】，能直接给出那一次刷新的时间点和页面。
//             为的是区分两种都表现为"触发 0"的可能：
//               (a) 没赶上时间；(b) Swift 对 @objc 但非 dynamic 的方法走 vtable 直接派发，
//                   根本不经过 objc_msgSend —— 那样钩子挂得再早也不会被调用。
//        顺带修掉两个只在真机上才看得见的显示问题：弹窗标题中文花屏（%s 在 NSString 格式化里
//        按平台默认 C 编码 MacRoman 解释，不是 UTF-8）与「挂钩类数」标签错标。
//        一键回退：kEarlyInstall = NO（改一行即回到 v1.0.2 的主队列路径）。
//
// v1.0.4 是【安全优先版】—— 起因是一次真机事故：
//        v1.0.3 装上后「第一次能打开、切后台回来还能弹窗，但**第二次打开就闪退**」。
//        复盘：v1.0.3 让后台线程在「构造函数之后 40ms」就动手扫类表 + 换实现。
//        但构造函数跑在 dyld 阶段，**40ms 之后 dyld 很可能还在加载其余几十个框架** ——
//        也就是说那 40ms 根本没有"离开 dyld"，只是在 dyld 中间。
//        在运行时还没稳定时从后台线程 objc_copyClassList + method_setImplementation，
//        正是铁律 2 警告的那类事，表现就是这种"有时崩有时不崩"的随机崩溃。
//        本版四条改动，每条都能单独归因：
//          A. 早期安装**默认关闭** → 回到 v1.0.2 那条真机验证过不闪退的主队列路径；
//             并做成**运行时可切换**（弹窗上一个按钮，下次启动生效），不需要改代码。
//          B. 修掉根因：不再"掐表 40ms"，改成**等 dyld 真正静下来**（用 _dyld_image_count()
//             做只读静默检测），确定 dyld 收工后才开始扫。
//          C. 重扫窗口 3 秒 → 6 秒（冷启动 dyld 慢、热启动 UI 来得早，两边都要覆盖）。
//          D. 新增「启动阶段墓碑」：把每个关键阶段写进 Documents/XNR_phase.log，
//             下次启动读出并显示「上次启动止于哪一阶段」——
//             闪退时我们什么都看不到（进程直接没了），这个墓碑就是唯一的见证者。
//        另把只读几何观测加密（0.15s × 20s），并在"列表被程序性拉下"的那一刻
//        顺带记下【这个 scrollView 有没有 refreshControl、顶上几个子视图是什么类】——
//        那几乎就是直接看到"那个圈圈是谁家的"。
// ---------------------------------------------------------------------------

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>   // _dyld_image_count()：只读的"dyld 加载了几个镜像"，用于静默检测
#import <ctype.h>
// 注：v1.0.3 起早期安装改用 dispatch_after 串联，不再需要 <unistd.h>（usleep）。
//     万一以后要加回阻塞式节流再 import 即可 —— 但请先看 XNREarlyInstallStep 上面的那段说明。

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
static const char *kVersion            = "1.0.4";

// ★★★ v1.0.4：早期安装默认【关闭】。
//
// 真机事故（v1.0.3）：装上后「第一次能打开、切后台回来能弹窗，第二次打开就闪退」。
// 复盘结论：v1.0.3 让后台线程在「构造函数之后 40ms」就扫类表 + 换实现。
//   但构造函数跑在 dyld 阶段 —— **40ms 之后 dyld 往往还在加载其余几十个框架**，
//   那 40ms 根本没有"离开 dyld"，只是在 dyld 中间。
//   在运行时还没稳定时从后台线程 objc_copyClassList + method_setImplementation，
//   正是铁律 2 警告的那类事 → 表现就是"有时崩有时不崩"的随机崩溃。
//   （这也解释了为什么第一次能开：冷启动那 4 秒里主线程被占满，
//     我们的后台扫描先跑完了，没和应用自己的 UI 活动重叠。热启动就不一样了。）
//
// 所以本版：**默认走主队列那条真机验证过不闪退的路径**，早期安装降级为**可选实验**，
// 且改成"等 dyld 静下来再动手"（见 XNRDyldSettled）。
// ⚠️ 用户可以在弹窗上点按钮切换，下次启动生效，**不需要改代码/重新编译**。
static NSString *kEarlyInstallKey      = @"XNREarlyInstall";   // 存 NSUserDefaults 的键
static BOOL      kEarlyInstall         = NO;   // ★ 默认关！运行时会被 UserDefaults 覆盖

// —— 早期安装（仅在 kEarlyInstall = YES 时生效）的三个参数 ——
static double kDyldSampleMs     = 50.0;   // 每多少毫秒抽查一次 dyld 镜像数
static double kDyldQuietSamples = 5.0;    // 连续多少次"没有新镜像"才认为 dyld 收工（5×50ms=250ms）
static double kDyldMaxWaitSecs  = 12.0;   // 兜底：最多等这么久，超时就照常开始（别无限等）
static double kEarlyRescanSecs  = 6.0;    // ★ 持续重扫到启动后多少秒（3→6：冷启动 dyld 更慢）
static double kEarlyIntervalMs  = 150.0;  // 重扫间隔(ms)。6s / 150ms ≈ 40 轮

static BOOL   kPollRefreshCtrl   = YES;   // 低频轮询（纯只读）：① refreshControl.isRefreshing
                                          //   ② 列表有没有被程序性拉下去
static double kPollIntervalSecs  = 0.15;  // ★ 0.3 → 0.15 秒：加密采样，别漏掉那一瞬间
static int    kPollMaxTicks      = 134;   // ≈ 20 秒后自动停（不做长期轮询）


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

// ★ v1.0.3：安装改成「后台早期安装 + 主队列兜底」两条路径后，日志会从两个线程写。
//   `seekToEndOfFile` + `writeData` 不是原子操作，两边同时写会互相覆盖/写花。
//   → 加一把锁把它串行化。（注意 @try 里不能提前 return，否则会漏掉解锁。）
static void XNRLogLine(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSLog(@"[XNR] %@", msg);

    static NSLock *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSLock alloc] init]; });

    [lock lock];
    @try {
        NSString *path = XNRLogPath();
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
        NSString *line = [NSString stringWithFormat:@"%@  %@\n", [NSDate date], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) { (void)e; }
    @finally { [lock unlock]; }        // ★ 用 @finally 释放，绝不依赖"走到函数末尾"
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
static BOOL gMainInstallMarked = NO;   // 是否已经写过 main-install-done 这行墓碑（只写一次）
static int  gInstallTries = 0;   // 第几轮尝试安装（用于日志与重试上限）
static NSString *gRealBundleID = nil;   // ★ 本进程真实包名 —— 排障第一信息，直接打进弹窗

// ★★ v1.0.3：安装时间线（只读观测）
//    要回答的问题：「最后一次成功扫描发生在启动后几秒」「一共扫了几轮」「每轮各挂到几处」
static volatile int   gInstalling   = 0;   // 简易自旋锁：同一时刻只允许一个安装者在跑
static int            gTryCount     = 0;   // 扫描轮次
static double         gFirstTryOffset = -1;// 第一轮扫描发生的时刻（★ 这一个数就能说明"排得早≠跑得早"）
static double         gLastTryOffset  = -1;// 最后一轮扫描的时刻
static NSMutableArray *gTimeline    = nil; // 每轮："第N轮 @X.XXs → 命中K"

// ★★ v1.0.3：UIRefreshControl 低频轮询（只读观测）
//    要回答的问题：「那个圈圈到底是不是 UIRefreshControl 在转」
//    因为 UIRefreshControl 若由 scrollView 内部驱动，是【不经过】-beginRefreshing 的
//    （beginRefreshing 是给外部代码程序化调用用的），所以我们改从结果侧观测。
static int      gPollTicks      = 0;    // 已经轮询了几次
static int      gPollScrollSeen = 0;    // 见过的 UIScrollView 数量（用来证明确实在扫）
static int      gPollHits       = 0;    // 见到 refreshControl.isRefreshing == YES 的次数
static double   gPollFirst      = -1;   // 首次见到刷新的时刻
static NSString *gPollPage      = nil;  // 首次见到刷新时，那个 scrollView 所在的页面

// ★★ v1.0.3 追加的第二路观测（同样是纯只读）：**列表是不是被「程序性地」拉下去了**。
//    背景：v1.0.2 真机数据里 beginRefreshing / endRefreshing / setState: 全都是 0 ——
//    说明那一次刷新【一个挂钩都没惊动】。这可能意味着：
//      (a) 我们挂晚了（时间问题）；或
//      (b) 它是 Swift 内部调用（Swift 对 @objc 但非 dynamic 的方法走 vtable/直接调用，
//          **根本不经过 objc_msgSend，也就永远绕过 method_setImplementation**）；或
//      (c) 它压根不是刷新控件，只是列表被重置了。
//    要区分这三者，最省事的办法是**不靠任何挂钩**，直接看几何量：
//      列表静止在顶部时  contentOffset.y == -adjustedContentInset.top
//      下拉露出圈圈时    contentOffset.y 会更小（更负），即  (-y) - inset.top > 0
//    再加上「没人在拖 / 没在惯性滑动」这个条件 → 就是**程序性下拉**，也就是我们要抓的那一下。
//    ★ 这仍然是"只读"：只读 contentOffset 和 inset，一个几何值都不写（铁律 3 不禁止读，只禁止写）。
//    ★ 而且它给出的正是我们最缺的那个数：**那一下到底发生在启动后第几秒**。
static int      gPollPullHits  = 0;     // 见到"程序性下拉"的次数
static double   gPollPullFirst = -1;    // 首次见到的时刻 ★ 关键数据
static double   gPollPullMax   = 0;     // 下拉得最深的一次（点）
static NSString *gPollPullPage = nil;   // 首次见到时所在的页面
// ★ v1.0.4 追加：第一次抓到"程序性下拉"的现场快照 —— 这就是"那个圈圈是谁家的"的答案。
//   记三件事：① scrollView 自己的类名；② 它有没有 refreshControl（有的话是什么类）；
//            ③ 它顶部那几个子视图是什么类（刷新头一定在其中）。
static NSString *gPollPullDetail = nil;
static BOOL      gPollPullPullDone = NO;

static NSTimeInterval gStartTime     = 0;
static NSTimeInterval gLastAllow     = 0;
static NSTimeInterval gCooldownUntil = 0;
static NSTimeInterval gBlockWinStart = 0;
static int            gBlockInWindow = 0;

static double gFirstSeenOffset = -1.0;   // ★ 首次触发发生在启动后多少秒（决定宽限该设多少）
static BOOL   gFirstSeenBlocked = NO;    // 首次触发是被吃掉了还是被放行了
static BOOL   gFirstSeenDone    = NO;    // 是否已经记过「首次触发」

#pragma mark - ★★ v1.0.4 启动阶段墓碑（用来定位"上次崩在哪一阶段"）

// 起因：v1.0.3 真机上「第一次能开，第二次打开就闪退」—— 闪退时我们**什么都看不到**：
//       进程直接没了，弹窗没机会弹，NSLog 也留在设备上拿不出来。
//       **唯一的办法是让程序在崩溃之前，一路把"我到哪儿了"写到磁盘上。**
//
// 做法：每到一个关键阶段，就往 Documents/XNR_phase.log 追加一行：
//         launch#N | 阶段名 | 启动后X.XXXs
//       每行都 open→seek→write→close，**立刻落盘、不经缓存**（要的就是"崩了也能留下"）。
//       下次启动时读这个文件：找出"上一次启动"那批行里的最后一行，
//       就知道上次**止步于哪个阶段** —— 这比任何猜测都硬。
//
// 为什么用独立文件而不是复用 XNR_fix.log：
//   ① 墓碑必须逐行落盘、绝不能和别的日志共享缓冲/锁；
//   ② 即使 XNR_fix.log 被写坏，也不该影响这个判断。
//
// 阶段名（ASCII，见 check_tweak.py 第 13 条：C 字符串不许带中文）：
//   constructor          构造函数里 gStartTime 落地
//   early-wait-dyld      后台开始等 dyld 静默
//   dyld-settled         dyld 静默达成（镜像数不再变化）
//   early-scan-done      早期安装扫完整个窗口
//   main-install-done    主队列那次安装完成
//   stats-shown          统计弹窗成功弹出
//   poll-done            轮询结束
#define XNR_PHASE_CONSTRUCTOR   "constructor"
#define XNR_PHASE_EARLY_WAIT    "early-wait-dyld"
#define XNR_PHASE_DYLD_SETTLED  "dyld-settled"
#define XNR_PHASE_EARLY_DONE    "early-scan-done"
#define XNR_PHASE_MAIN_DONE     "main-install-done"
#define XNR_PHASE_STATS_SHOWN   "stats-shown"
#define XNR_PHASE_POLL_DONE     "poll-done"

static NSString *XNRPhasePath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/XNR_phase.log"];
}

static int      gLaunchNo       = 0;     // 本次启动的序号（从墓碑文件的已有记录里推出来）
static NSString *gPrevPhaseName = nil;   // 上一次启动止步于哪个阶段
static double   gPrevPhaseAt    = -1;    // 上一次启动止步于启动后多少秒
static int      gPrevLaunchNo   = 0;

// 启动时调用一次：算出本次序号 + 读出"上一次止步阶段"
static void XNRPhaseLoad(void) {
    @try {
        NSString *all = [NSString stringWithContentsOfFile:XNRPhasePath()
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
        if (!all.length) { gLaunchNo = 1; return; }

        int maxNo = 0;
        NSMutableArray *lines = [NSMutableArray array];
        for (NSString *ln in [all componentsSeparatedByString:@"\n"]) {
            if (!ln.length) continue;
            [lines addObject:ln];
            NSArray *f = [ln componentsSeparatedByString:@"|"];
            if (f.count >= 2) {
                int no = [[f[0] stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceCharacterSet]] intValue];
                if (no > maxNo) maxNo = no;
            }
        }
        gLaunchNo = maxNo + 1;

        // 找"最大的、且小于本次序号"的那一批 → 上一次启动
        int prevNo = 0;
        for (NSString *ln in lines) {
            NSArray *f = [ln componentsSeparatedByString:@"|"];
            if (f.count < 3) continue;
            int no = [[f[0] stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceCharacterSet]] intValue];
            if (no > 0 && no < gLaunchNo && no > prevNo) prevNo = no;
        }
        if (prevNo <= 0) return;
        for (NSString *ln in lines) {
            NSArray *f = [ln componentsSeparatedByString:@"|"];
            if (f.count < 3) continue;
            int no = [[f[0] stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceCharacterSet]] intValue];
            if (no != prevNo) continue;
            gPrevLaunchNo   = prevNo;
            gPrevPhaseName  = [f[1] stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceCharacterSet]];
            gPrevPhaseAt    = [[f[2] stringByTrimmingCharactersInSet:
                                [NSCharacterSet whitespaceCharacterSet]] doubleValue];
        }
    } @catch (NSException *e) { (void)e; }
}

// 追加一行墓碑。线程安全、不依赖任何其它设施、失败就悄悄算了（永远不能因为它崩）。
static void XNRMarkPhase(const char *name) {
    if (gLaunchNo <= 0) return;
    static NSLock *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSLock alloc] init]; });

    [lock lock];
    @try {
        double at = (gStartTime > 0) ? (XNRNow() - gStartTime) : 0.0;
        NSString *line = [NSString stringWithFormat:@"launch#%d | %s | %.3f\n",
                          gLaunchNo, name ? name : "?", at];
        NSString *path = XNRPhasePath();
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (fh) {
            @try { [fh seekToEndOfFile];
                    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; }
            @finally { [fh closeFile]; }        // ★ 无论如何都要关掉，否则句柄泄漏
        }
    } @catch (NSException *e) { (void)e; }
    @finally { [lock unlock]; }
}

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
// ★ v1.0.3：定义在安装段，但扫描循环里要用 —— 它负责"这个类是不是第一次见到"
static BOOL XNRSeenAndAdd(Class c);     // 前置声明

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

// ★★ v1.0.3 并发安全（这是 v1.0.3 引入后台安装后【必须】补上的一处）：
//   v1.0.2 里安装只在主线程跑、钩子也基本在主线程触发，所以查表是"单线程"的、不用管。
//   v1.0.3 安装跑在后台线程了 —— 于是会出现：后台正在往 gPatches 里写第 N 条，
//   而主线程上某个钩子已经在遍历这张表。若此时 gPatchCount 已经先涨了，
//   读到的就是一条【字段没写完】的垃圾记录 → 回查出一个野 IMP → **崩溃**。
//
//   解法是标准的"先写数据、再用屏障发布 count"：
//     写端：写完 cls/sel/imp → __sync_synchronize() → 才把 count 加 1
//     读端：先一把屏障把 count 的读取"锚住"，再遍历 0..count-1
//   这样读到 count=N 时，第 0..N-1 条一定已经完整可见。
//   （安装者本身被自旋锁限制成"同一时刻只有一个"，所以是单生产者模型。）
static IMP XNROrigFor(id self, SEL sel) {
    __sync_synchronize();                          // ★ 获取屏障：拿 count 之前先把内存视图同步好
    int cnt = gPatchCount;                         // 只读一次，避免遍历途中 count 变化
    Class c = object_getClass(self);
    for (Class k = c; k != Nil; k = class_getSuperclass(k)) {
        for (int i = 0; i < cnt; i++) {
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

// ★★ v1.0.3：这里原来写的是【中文】的 const char *（"空参数" / "已挂过" / "继承来的(避碰父类)"…），
//    而它在日志与弹窗里是用 `%s` 输出的 —— 和 XNRAllEvents 那个"花屏"是**同一个坑**
//    （`%s` 在 NSString 格式化里按平台默认 C 编码解释，不是 UTF-8）。
//    这类 bug 由 check_tweak.py 第 13 条静态拦下，然后逐个改成「内部用 ASCII 标识符 + 显示时翻译」：
//      · 内部：ASCII，便于 strcmp 比较，且交给 %s 也绝不会花屏；
//      · 显示：由 XNRWhyText() 翻成中文 @"..."，走 %@ 输出。
#define XNRW_EMPTY   "empty-arg"      // 参数为空
#define XNRW_PATCHED "already"        // 已经挂过了
#define XNRW_FULL    "table-full"     // 挂钩表满
#define XNRW_INHERIT "inherited"      // 继承来的（避碰父类）
#define XNRW_NOMETH  "no-method"      // 方法不存在
#define XNRW_BADSIG  "bad-sig"        // 签名不匹配
#define XNRW_SETFAIL "impl-failed"    // 换实现失败

// 把 ASCII 的跳过原因翻成给人看的中文（ASCII 原因不用翻译，原样返回）
static NSString *XNRWhyText(const char *w) {
    if (!w) return @"(无)";
    if (!strcmp(w, XNRW_EMPTY))   return @"空参数";
    if (!strcmp(w, XNRW_PATCHED)) return @"已挂过";
    if (!strcmp(w, XNRW_FULL))    return @"挂钩表满";
    if (!strcmp(w, XNRW_INHERIT)) return @"继承来的(避碰父类)";
    if (!strcmp(w, XNRW_NOMETH))  return @"方法不存在";
    if (!strcmp(w, XNRW_BADSIG))  return @"签名不匹配";
    if (!strcmp(w, XNRW_SETFAIL)) return @"换实现失败";
    return [NSString stringWithUTF8String:w] ?: @"(未知原因)";   // 例如"类型签名"这种自由文本
}

static BOOL XNRPatchMethod(Class c, SEL sel, IMP repl, XNRSigKind kind, const char **why) {
    if (!c || !sel || !repl) { if (why) *why = XNRW_EMPTY; return NO; }
    if (XNRIsPatched(c, sel)) { if (why) *why = XNRW_PATCHED; return NO; }
    if (gPatchCount >= XNR_MAX_PATCHES) { gPatchSkipped++; if (why) *why = XNRW_FULL; return NO; }

    if (!XNRClassDefines(c, sel)) { if (why) *why = XNRW_INHERIT; return NO; }

    Method m = class_getInstanceMethod(c, sel);
    if (!m) { if (why) *why = XNRW_NOMETH; return NO; }
    const char *t = method_getTypeEncoding(m);
    if (!XNRSigCheck(kind, t)) { if (why) *why = t ? t : XNRW_BADSIG; return NO; }

    IMP old = method_setImplementation(m, repl);
    if (!old || old == repl) { if (why) *why = XNRW_SETFAIL; return NO; }

    // ★★ 发布顺序（配合 XNROrigFor 里的获取屏障）：
    //    先把整条记录写完，再同步内存，最后才让 gPatchCount 涨 —— 顺序绝不能反。
    //    反过来写的话，主线程上的钩子可能读到"count 已涨、字段还没写完"的垃圾条目。
    int idx = gPatchCount;
    gPatches[idx].cls = c;
    gPatches[idx].sel = sel;
    gPatches[idx].imp = old;
    __sync_synchronize();          // ★ 释放屏障
    gPatchCount = idx + 1;         // ★ 发布
    return YES;
}

#pragma mark - 取证：记下「哪个页面、被放行还是被拦」

// ★ v1.0.3：取证加锁。
//   gEvLines[kind] 是 NSMutableArray —— 【不是线程安全】的。
//   而 -reloadData 这种钩子在真实 App 里是可能从后台线程触发的，
//   两个线程同时 addObject / 同时懒初始化，就可能直接崩在里面。
//   节流与计数也一并放进锁里，避免两个线程同时通过节流检查。
static NSLock *XNREventLock(void) {
    static NSLock *l = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ l = [[NSLock alloc] init]; });
    return l;
}

// page 由调用方传入（主线程里取好），本函数自身不碰 UIKit
// kind：按事件类型分开记账，各自 1.5 秒节流、各自留 3 条 —— 防止某一类事件把额度占满
//
// ★ 锁必须配 @finally 释放：本函数里有好几处 `return`，
//   而 ObjC 的 return / 异常都【不会】执行 @try 之后的普通语句 —— 只有 @finally 保证一定跑到。
//   （写成 "@try{} @catch{} [lk unlock];" 的话，一旦走到 return，锁就永远不释放 → 整机卡死。
//     这类"提前 return 漏解锁"是加锁时最容易犯、也最难查的错。）
static void XNRRecordEventKind(NSString *what, NSString *page, BOOL blocked, XNREvKind kind) {
    if (!kProbeTrigger) return;
    if (kind < 0 || kind >= XNREvKindCount) return;

    NSLock *lk = XNREventLock();
    [lk lock];
    @try {
        NSTimeInterval now = XNRNow();
        if (now - gEvLast[kind] < 1.5) return;   // 节流：同类事件最多每 1.5 秒记一条
        gEvLast[kind] = now;

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
    @finally { [lk unlock]; }                     // ★ 无论 return 还是抛异常，都会执行到
}

// 兼容旧调用点（拦截/放行都属于「beginRefreshing」这一类）
static void XNRRecordEvent(NSString *what, NSString *page, BOOL blocked) {
    XNRRecordEventKind(what, page, blocked, XNREvRefresh);
}

// 把所有类型的事件拼成一段给弹窗看
//
// ★★ v1.0.3 修掉一个真机上才看得见的显示 bug（"中文花屏"）：
//    v1.0.2 这里写的是
//        static const char *names[] = { "刷新事件", "列表重载", ... };   // 文件作用域，不能写 @"..."
//        [NSString stringWithFormat:@"— %s —", names[k]];
//    真机弹窗上那行字变成了 `— ÂåöÈ•ÉàçÊÖÑ —`。
//    ****根因：`%s` 在 NSString 的格式化里【不是按 UTF-8 解释】，而是按"平台默认 C 字符串编码"
//    （Apple 平台上是 MacRoman）**** —— 把一个 UTF-8 的中文串交给 %s，必然花屏。
//    （ASCII 的 %s 没问题，所以类名/SEL 那些用 %s 一直是好的，只有中文暴露了这个坑。）
//
//    这类 bug 最阴的地方：**本地和 CI 都发现不了**（编译没问题、自检也没管），
//    只有真机弹窗上才会看见。→ 已在 check_tweak.py 加了第 13 条：
//    **C 字符串字面量里不许出现非 ASCII 字符**，面向用户的文案一律写 `@"..."`。
//    这里的修法就是最直接的：改成**函数内局部**的 NSString 数组（函数内不能写文件作用域 static
//    的那种初始化，但普通局部变量是运行时构造的，完全合法）。
static NSString *XNRAllEvents(void) {
    NSMutableArray *all = [NSMutableArray array];
    NSArray<NSString *> *names = @[@"刷新事件", @"列表重载", @"刷新结束", @"状态被写"];
    for (int k = 0; k < XNREvKindCount; k++) {
        if (!gEvLines[k] || !gEvLines[k].count) continue;
        NSString *title = (k < (int)names.count) ? names[k] : [NSString stringWithFormat:@"类型%d", k];
        [all addObject:[NSString stringWithFormat:@"— %@ —\n%@", title,
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
// ★ 这个数组是【静态存储期】的初始化器，所以字段里只能写 C 字符串字面量：
//   ObjC 的 @"..." 在静态初始化里既不是编译期常量、类型也对不上，
//   clang 会直接以 -Werror,-Wincompatible-pointer-types 报错（v1.0.2 首轮 CI 就栽在这）。
//   → 静态初始化器里只允许 C 字符串字面量。
//
// ★ v1.0.3 删掉了原来的 `label`（const char *）字段：它是一段中文说明，但**从头到尾没被用过**，
//   而且留着一串中文 C 字符串迟早会被 `%s` 输出成花屏（见 XNRAllEvents 上面那段）。
//   现在每个挂钩的中文说明挪到下面这行注释里 —— 注释不会进二进制，零风险。
typedef struct {
    const char     *selName;
    IMP             repl;
    XNRSigKind      sig;
    BOOL            refreshControlOnly;
} XNRGateDef;

// 各挂钩的用途（对应下标 0~3）：
//   beginRefreshing  拦截 + 计数   ← 本插件唯一会"吃"的行为
//   endRefreshing    只读探针：刷新结束（只要刷过一定会调用它）
//   setState:        只读探针：刷新状态被写（MJRefresh 的圈圈走这里进 Refreshing）
//   reloadData       只读探针：列表重载（定位"那一刻"与调用来源）
static const XNRGateDef gGateDefs[] = {
    { "beginRefreshing",  (IMP)&XNRHookedBeginRefreshing, XNRSigVoidNoArg,  NO  },
    { "endRefreshing",    (IMP)&XNRHookedEndRefreshing,   XNRSigVoidNoArg,  YES },
    { "setState:",        (IMP)&XNRHookedSetState,        XNRSigVoidIntArg, YES },
    { "reloadData",       (IMP)&XNRHookedReloadData,      XNRSigVoidNoArg,  NO  },
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

// ★★ v1.0.3：本函数【刻意做成可反复调用】的（幂等）——
//    每轮只挂"还没挂过的"（靠 XNRIsPatched 去重），所以可以持续重扫，
//    把**晚加载的框架**（XYSpark、React Native 控件）也收进来。
//    v1.0.2 里开头有 `if (gInstalled) return gHooked;`，第一轮成功后就再也不扫了 ——
//    那是个真 bug：先挂上 UIRefreshControl 就等于把后面才出现的刷新头判了死刑。
static int XNRInstallGates(void) {
    if (!gHookedNames) gHookedNames = [NSMutableArray array];
    NSMutableArray *names = gHookedNames;             // ★ 直接往持久数组里追加（跨轮累积）
    NSMutableArray *notes = [NSMutableArray array];
    NSMutableArray *perGate = [NSMutableArray array]; // 每个挂钩各挂上了多少个（从全局表统计，天然准确）
    int n = 0;                                        // 本轮【新】挂上的 beginRefreshing 数

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

            // ★ v1.0.3：跳过之前几轮已经处理过的类。
            //   这是让"持续重扫"可行且不拖慢 App 的关键 —— 否则每轮都要对全部三万多类
            //   × 4 个挂钩沿继承链找方法，一轮就是几百毫秒。有了它，重扫的代价只剩"新出现的类"。
            if (!XNRSeenAndAdd(c)) continue;

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
                    if (strcmp(d->selName, "beginRefreshing") == 0) {
                        n++;
                        // ★ v1.0.3：安装现在跑在【后台线程】，而弹窗在主线程读这个数组。
                        //   NSMutableArray 被一边追加一边遍历 = 直接崩。加一把对象锁兜住。
                        //   （v1.0.2 安装全程在主队列，不存在这个竞争，所以以前不需要。）
                        @synchronized(names) { [names addObject:[NSString stringWithUTF8String:nm]]; }
                    }
                } else if (w && strcmp(w, XNRW_INHERIT) && strcmp(w, XNRW_NOMETH) && strcmp(w, XNRW_PATCHED)) {
                    // ★ 原因经 XNRWhyText() 翻成中文、走 %@（不能用 %s，会花屏）
                    [notes addObject:[NSString stringWithFormat:@"%s.%s 跳过(%@)", nm, d->selName, XNRWhyText(w)]];
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

    gPerGateInfo = perGate.count ? [perGate componentsJoinedByString:@" "] : @"";
    // ★★ v1.0.3 修正一处语义错误：v1.0.2 里 gInstallOffset 是【每轮都尝试赋值】，
    //    所以它记的其实是"第一轮失败扫描的时刻"，而不是"真正挂上钩子的时刻" ——
    //    弹窗上那个 4.2 秒因此是有歧义的。现在只在真的挂上东西时才记。
    if (gPatchCount > 0 && !gInstalled) {
        gInstalled = YES;
        if (gInstallOffset < 0) gInstallOffset = XNRNow() - gStartTime;
    }
    if (gStartTime <= 0) gStartTime = XNRNow();

    XNRLogLine(@"=== v%s 安装（第 %d 轮，启动后 %.2fs）：本轮新增 %d 处，累计 %d 处  %@",
               kVersion, gInstallTries, XNRNow() - gStartTime, n, gPatchCount,
               perGate.count ? [perGate componentsJoinedByString:@" "] : @"");
    if (n > 0) {   // 只在真有新增时才打这一行（重扫会很频繁，避免刷屏）
        XNRLogLine(@"     本轮新增 beginRefreshing 类(%d): %@", n,
                   names.count ? [names componentsJoinedByString:@", "] : @"(无)");
    }
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

// ★ v1.0.4：多了一个可选的"额外按钮 + 回调"，用来在弹窗上直接切换「早期安装」开关。
//   为什么要做成按钮：真机闪退后用户没法改代码重编译，而**必须能自己把那个开关关掉**。
//   （extraTitle 传 nil 就是老行为。）
static BOOL XNRAlert(NSString *title, NSString *msg, NSString *btn,
                     NSString *extraTitle, void (^extraBlock)(void)) {
    if (!kShowAlert) return NO;
    if (![NSThread isMainThread]) return NO;
    if (!XNRCanPresent()) return NO;
    @try {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                                  message:msg
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:btn style:UIAlertActionStyleDefault handler:nil]];
        if (extraTitle.length) {
            [a addAction:[UIAlertAction actionWithTitle:extraTitle
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *act) {
                (void)act;
                if (extraBlock) extraBlock();
            }]];
        }
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
        // ★ v1.0.3：这里的快照必须在锁里取 —— 后台安装线程可能正在往 gHookedNames 追加，
        //   而 -componentsJoinedByString: 会遍历它（边追加边遍历 = 崩）。
        NSString *cls = nil;
        int clsCnt = 0;
        @synchronized(gHookedNames) {
            if (!gHookedNames) gHookedNames = [NSMutableArray array];
            clsCnt = (int)gHookedNames.count;
            cls = gHookedNames.count
                ? [gHookedNames componentsJoinedByString:@"\n"]
                : @"(没找到任何 -beginRefreshing 实现)";
        }
        NSString *hints = XNRAllEvents();
        if (!hints.length) hints = @"(还没捕捉到 —— 从装上到现在什么事件都没记到)";
        // 注意：外层已经写了「启动宽限」四个字，这里不要再重复（v1.0.2 的弹窗里重复了两次）
        NSString *valve = kStartupGrace
            ? [NSString stringWithFormat:@"开，剩 %.1fs%@%@",
               MAX(0.0, kStartupGraceSecs - (XNRNow() - gStartTime)),
               (gCooldownUntil > XNRNow()) ? @"·熔断中" : @"",
               gCooldownHit ? [NSString stringWithFormat:@"·熔断过 %d 次", gCooldownHit] : @""]
            : [NSString stringWithFormat:@"关（空列表放行 %@）%@",
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

        // ★ v1.0.3：安装时间线 + 轮询观测
        NSString *instStr  = (gInstallOffset < 0) ? @"(还没装上)" : [NSString stringWithFormat:@"启动后 %.2f 秒", gInstallOffset];
        NSString *firstTry = (gFirstTryOffset < 0) ? @"(还没扫过)" : [NSString stringWithFormat:@"启动后 %.2f 秒", gFirstTryOffset];
        NSString *lastTry  = (gLastTryOffset < 0) ? @"(还没扫过)" : [NSString stringWithFormat:@"启动后 %.2f 秒", gLastTryOffset];
        // ★ 同上：时间线也要在锁里取快照（后台安装线程可能正在追加）
        NSString *timeline = nil;
        @synchronized(gTimeline) {
            if (!gTimeline) gTimeline = [NSMutableArray array];
            timeline = gTimeline.count ? [gTimeline componentsJoinedByString:@"  "] : @"(还没有)";
        }
        NSString *maxState = (gProbeSetMaxState < 0) ? @"没写过" : [NSString stringWithFormat:@"%d", gProbeSetMaxState];
        NSString *pollPage = gPollPage ?: @"(还没见到)";
        NSString *pullDetail = gPollPullDetail.length ? gPollPullDetail : @"(还没抓到现场)";

        // ★★ v1.0.4：把"上一次启动止步于哪一阶段"摆到最上面 —— 闪退唯一的见证者。
        NSString *prevLn = nil;
        if (gPrevLaunchNo <= 0) {
            prevLn = @"(墓碑里还没有上一次的记录)";
        } else {
            prevLn = [NSString stringWithFormat:@"启动#%d 止于 %@ @ %.2fs%@",
                      gPrevLaunchNo, gPrevPhaseName ?: @"?", gPrevPhaseAt,
                      ([gPrevPhaseName isEqualToString:@"stats-shown"] ||
                       [gPrevPhaseName isEqualToString:@"poll-done"])
                        ? @"（看起来是正常走完的）" : @"  ⚠️ 之后就没有记录了 → 很可能就崩在这一步之后"];
        }
        NSString *modeLn = kEarlyInstall
            ? @"开（后台早期安装；若闪退请点下面的按钮关掉）"
            : @"关（只走主队列，安全）";

        NSString *msg = [NSString stringWithFormat:
            @"★ 上次启动\n%@\n"
             "★ 本次为启动#%d   早期安装：%@\n\n"
             "本进程包名\n%@\n\n"
             "闸门安装于         %@\n"
             "首轮扫描于         %@\n"
             "扫描轮次           %d 轮   最后一轮 %@\n"
             "各挂钩命中          %@\n"
             "挂钩落脚点         %d 处（其中 beginRefreshing 覆盖 %d 个类）\n"
             "启动宽限           %@\n\n"
             "beginRefreshing  触发 %d / 放行 %d / 吃掉 %d\n"
             "触发来源          主线程 %d / 后台线程 %d\n"
             "首次触发          %@\n"
             "最近一次放行       %@\n\n"
             "★ 只读探针（只数数，绝不改行为）\n"
             "  reloadData          %d 次   首次 %@\n"
             "  endRefreshing       %d 次   首次 %@\n"
             "  setState: 总写入     %d 次   (最大 state = %@)\n"
             "  └ 写入 Refreshing(3) %d 次   首次 %@\n\n"
             "★ 轮询观测（只读：不靠任何挂钩，直接看界面结果）\n"
             "  轮询 %d 次   见过 scrollView %d 个\n"
             "  ① refreshControl 正在转   %d 次   首次 %@\n"
             "     首次所在页面            %@\n"
             "  ② 列表被程序性拉下         %d 次   首次 %@\n"
             "     最深拉下                %.0f pt\n"
             "     首次所在页面            %@\n"
             "     ★ 现场                  %@\n\n"
             "放行原因明细（判断插件是否按预期工作的关键）\n"
             "  列表还没内容(首屏加载)  %d\n"
             "  用户自己在拖            %d\n"
             "  启动宽限内             %d\n"
             "  上拉加载更多            %d\n"
             "  熔断静默期             %d\n"
             "  拿不到判断依据(放行)     %d\n\n"
             "安装时间线（#轮次@时刻→本轮新增）:\n%@\n\n"
             "挂钩的类:\n%@\n\n"
             "抓到的事件（含调用栈，每类最多 3 条）:\n%@",
            prevLn,
            gLaunchNo, modeLn,
            bidLn,
            instStr, firstTry, gTryCount, lastTry,
            gPerGateInfo.length ? gPerGateInfo : @"(无)",
            gHooked, clsCnt, valve,
            gSeenBegin, gAllowBegin, gBlockedBeg,
            gSeenMain, gSeenBG,
            first, lastAllow,
            gProbeReload, XNRFmtOff(gProbeReloadFirst),
            gProbeEndRefresh, XNRFmtOff(gProbeEndFirst),
            gProbeSetState, maxState,
            gProbeSetRefresh, XNRFmtOff(gProbeSetFirst),
            gPollTicks, gPollScrollSeen,
            gPollHits, XNRFmtOff(gPollFirst),
            pollPage,
            gPollPullHits, XNRFmtOff(gPollPullFirst),
            gPollPullMax,
            gPollPullPage ?: @"(还没见到)",
            pullDetail,
            gAllowEmpty, gAllowUser, gAllowGrace, gAllowFooter, gAllowCool, gAllowNoInfo,
            timeline, cls, hints];

        // ★ v1.0.4：弹窗上直接给一个开关（下次启动生效），这样即使闪退也不需要改代码
        NSString *toggle = kEarlyInstall ? @"关闭早期安装（下次启动生效，更安全）"
                                         : @"开启早期安装（下次启动生效，有闪退风险）";
        BOOL ok = XNRAlert([NSString stringWithFormat:@"XhsNoRefresh v%s 统计", kVersion],
                           msg, @"好", toggle, ^{
            BOOL want = !kEarlyInstall;
            [[NSUserDefaults standardUserDefaults] setBool:want forKey:kEarlyInstallKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
            XNRLogLine(@"=== 用户切换早期安装 → %@（下次启动生效）", want ? @"开" : @"关");
        });
        if (ok) {
            XNRMarkPhase(XNR_PHASE_STATS_SHOWN);
            XNRLogLine(@"--- 前台统计：包名=%@ 装于%.2fs 首扫%.2fs 轮次=%d 钩=%d 见=%d(主%d/后%d) 放行=%d 吃掉=%d",
                       gRealBundleID, gInstallOffset, gFirstTryOffset, gTryCount, gHooked,
                       gSeenBegin, gSeenMain, gSeenBG, gAllowBegin, gBlockedBeg);
            XNRLogLine(@"--- 探针：reloadData=%d(首%.1fs) endRefreshing=%d(首%.1fs) setState=%d(最大%d) 其中Refreshing=%d(首%.1fs)",
                       gProbeReload, gProbeReloadFirst,
                       gProbeEndRefresh, gProbeEndFirst,
                       gProbeSetState, gProbeSetMaxState,
                       gProbeSetRefresh, gProbeSetFirst);
            XNRLogLine(@"--- 轮询：%d 次 / 见过scrollView %d / ①正在刷新 %d 次（首次 %.2fs 于 %@）",
                       gPollTicks, gPollScrollSeen, gPollHits, gPollFirst, gPollPage ?: @"-");
            XNRLogLine(@"--- 轮询：②程序性拉下 %d 次（首次 %.2fs 于 %@，最深 %.0fpt）",
                       gPollPullHits, gPollPullFirst, gPollPullPage ?: @"-", gPollPullMax);
            XNRLogLine(@"--- 下拉现场：%@", gPollPullDetail ?: @"(没抓到)");
            XNRLogLine(@"--- 墓碑：本次 启动#%d，上次 启动#%d 止于 %@@%.2fs",
                       gLaunchNo, gPrevLaunchNo, gPrevPhaseName ?: @"-", gPrevPhaseAt);
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
// ★★ v1.0.3：把「扫描安装」包装成一个带【自旋锁 + 时间线】的轮次。
//
//   自旋锁是必需的：安装现在有【后台早期】和【主队列兜底】两条路径，
//   两边同时扫的话，同一个 (类, 方法) 可能被两个线程同时换实现，
//   而且 gPatchCount 递增与 gPatches 写入会互相踩（读到半更新的表 = 崩）。
//   限制成"同一时刻只有一个安装者"，就回到了 v1.0.2 那种单线程写表的安全前提。
static int XNRInstallAttempt(void) {
    if (__sync_lock_test_and_set(&gInstalling, 1)) return 0;   // 有人在装 → 让给他
    int n = 0;
    @try {
        double off = (gStartTime > 0) ? (XNRNow() - gStartTime) : 0.0;
        gInstallTries = gTryCount + 1;
        n = XNRInstallGates();
        gTryCount++;
        if (gFirstTryOffset < 0) gFirstTryOffset = off;
        gLastTryOffset = off;
        if (!gTimeline) gTimeline = [NSMutableArray array];
        // ★ 与主线程弹窗的读取配对加锁（详见 XNRPresentStats 里取快照那段）
        @synchronized(gTimeline) {
            if (gTimeline.count < 40) {
                [gTimeline addObject:[NSString stringWithFormat:@"#%d@%.2fs→%d处", gTryCount, off, n]];
            }
        }
    } @catch (NSException *e) {
        XNRLogLine(@"⚠️ 安装轮次抛异常：%@", e);
    }
    __sync_lock_release(&gInstalling);
    return n;
}

// ★★ v1.0.3：已扫过的类放进哈希集合，重扫时直接跳过 —— 这是让"持续重扫"可行且不拖慢 App 的关键。
//   不这么做的话，每轮都要对【全部三万多个类】× 4 个挂钩做 class_getInstanceMethod（要沿继承链找），
//   一轮就是几百毫秒，几十轮下来会把 App 启动拖垮。
//   有了它，重扫的代价只剩下"新出现的那些类"，未加载完的框架一出现就能立刻被挂上。
#define XNR_SEEN_SIZE 65536u          // 512KB 静态表；三万多个类的装载率约 0.5，够用
static Class gSeenClasses[XNR_SEEN_SIZE];

static BOOL XNRSeenAndAdd(Class c) {  // 返回 YES = 这是第一次见到的类
    if (!c) return NO;
    uintptr_t h = ((uintptr_t)c >> 4) & (XNR_SEEN_SIZE - 1);
    for (unsigned i = 0; i < 64; i++) {
        unsigned idx = (unsigned)((h + i) & (XNR_SEEN_SIZE - 1));
        Class cur = gSeenClasses[idx];
        if (cur == c) return NO;
        if (cur == NULL) { gSeenClasses[idx] = c; return YES; }
    }
    return YES;                        // 表满 → 保守当作新类，宁可多扫
}

// 主队列兜底路径：跟 v1.0.2 一样（但间隔固定 0.3 秒，不再递增）。
// 现在它只是兜底 —— 正常情况下早期安装早就成功了。
static void XNRInstallWhenReady(int tries) {
    @try {
        if (!gRealBundleID) {
            gRealBundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"(拿不到)";
            NSString *tgt = [NSString stringWithUTF8String:kTargetBundlePrefix];
            XNRLogLine(@"=== 本进程包名: %@  |  目标前缀: %@  |  匹配: %@",
                       gRealBundleID, tgt,
                       [gRealBundleID hasPrefix:tgt] ? @"是" : @"否（但这版不再因此中止，继续尝试安装）");
        }

        XNRInstallAttempt();

        if (gInstalled) {                       // 挂上了，兜底路径收工
            if (!gMainInstallMarked) { gMainInstallMarked = YES;
                XNRMarkPhase(XNR_PHASE_MAIN_DONE); }
            return;
        }

        if (tries + 1 >= XNR_MAX_TRIES) {
            XNRLogLine(@"⚠️ 兜底路径试了 %d 轮仍未挂上任何钩子"
                       @"（若开了早期安装，看 XNR_fix.log 的安装时间线）", XNR_MAX_TRIES);
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            XNRInstallWhenReady(tries + 1);
        });
    } @catch (NSException *e) {
        XNRLogLine(@"⚠️ 安装过程抛异常：%@", e);
    }
}

// ★★★ v1.0.3 的机制：后台早期安装 + 持续重扫。（v1.0.4 起默认关闭，见 kEarlyInstall）
//
//   为什么离开主队列：v1.0.2 实测「闸门安装于 启动后 4.2 秒」，
//   而用户的现象（打开就刷新）发生在启动后 1~2 秒 —— 钩子挂上时那一次早打完了。
//   App 启动时主线程被 dyld 加载几十个框架 + 自己的启动任务占满，
//   排在主队列上的任务要等它整段跑完才轮到。**排得早 ≠ 跑得早。**
//
//   为什么必须持续重扫：晚加载的框架（XYSpark、React Native 控件）在头几百毫秒里还不存在，
//   只扫一轮的话永远挂不上它们。（v1.0.2 里"第一轮成功就 return"也是同一个 bug 的一种形态。）
//
//   ★★★ v1.0.4 修掉的根因（这一段是这次真机闪退的复盘）：
//     v1.0.3 写的是"构造函数之后 40ms 就开始扫"。当时的想法是"构造函数在 dyld 里，
//     等 40ms 就离开 dyld 了" —— **这个想法是错的**。
//     构造函数跑在 dyld 序列的早期，而 dyld 要加载几十个框架；
//     **构造函数之后 40ms，dyld 多半还在加载剩下的那些**。那 40ms 根本没有"离开 dyld"，
//     只是在 dyld 中间。在运行时还没稳定时从后台线程 objc_copyClassList +
//     method_setImplementation，正是铁律 2 警告的那类事。
//     → 真机表现：`第一次能打开、切后台回来还能弹窗，第二次打开就闪退`（随机崩溃）。
//
//   ★ 正确的判据不是"掐表"，而是"**dyld 到底有没有收工**"：
//     用 `_dyld_image_count()`（只读一个计数器，任何时刻调用都安全、不碰 ObjC 运行时）
//     每 50ms 抽样一次，**连续 5 次都没有新镜像加入** → 认为 dyld 收工，才允许开始扫。
//     这比任何固定毫秒数都可靠：冷启动 dyld 可能要好几秒，热启动可能只要几百毫秒。
//
//   ★ 为什么用 dispatch_after 串起来、而不是 usleep 循环：
//     GCD 全局并发队列的工作线程数是有限的。用 usleep 把线程按住几秒，等于从系统的线程池里
//     "借走"一个线程不放 —— 轻则拖慢 App 自己的后台任务，重则让线程池饥饿。
//     dispatch_after 是"排一个将来的时间点"，**排完立刻归还线程**，全程不占用。
static BOOL XNRDyldSettled(void) {
    // 只被后台这一条链调用，所以函数内 static 不需要加锁
    static uint32_t lastCount = 0;
    static int      quiet     = 0;
    uint32_t now = _dyld_image_count();
    if (now == lastCount) quiet++;
    else { quiet = 0; lastCount = now; }
    return (quiet >= (int)kDyldQuietSamples);
}

static void XNREarlyInstallStep(int round);      // 前置声明（下面定义）

// 第一阶段：等 dyld 静下来。只有在 kEarlyInstall = YES 时才会走到这里。
static void XNRDyldWaitStep(int round) {
    if (!kEarlyInstall) return;

    double elapsed = (gStartTime > 0) ? (XNRNow() - gStartTime) : 0.0;

    if (XNRDyldSettled()) {
        XNRMarkPhase(XNR_PHASE_DYLD_SETTLED);
        XNRLogLine(@"=== dyld 已静下来（镜像数 %u，等了约 %.2fs），开始早期安装",
                   _dyld_image_count(), elapsed);
        XNREarlyInstallStep(0);
        return;
    }

    if (elapsed >= kDyldMaxWaitSecs) {
        // 兜底：万一某个 App 一直在 dlopen，也别无限等下去
        XNRLogLine(@"⚠️ 等 dyld 静默超时（%.1fs，当前镜像数 %u），仍按计划开始安装",
                   elapsed, _dyld_image_count());
        XNREarlyInstallStep(0);
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kDyldSampleMs * NSEC_PER_MSEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        @autoreleasepool { XNRDyldWaitStep(round + 1); }
    });
}

// 第二阶段：持续重扫（幂等），直到启动后 kEarlyRescanSecs 秒
static void XNREarlyInstallStep(int round) {
    if (!kEarlyInstall) return;

    // 每轮只做一件事：扫一轮类表，挂上还没挂的钩子（幂等，可反复调用）
    XNRInstallAttempt();

    double elapsed = (gStartTime > 0) ? (XNRNow() - gStartTime) : 0.0;
    if (elapsed >= kEarlyRescanSecs) {
        XNRLogLine(@"--- 早期安装收工：共扫 %d 轮，累计 %d 处，最后一次在启动后 %.2fs",
                   gTryCount, gPatchCount, gLastTryOffset);
        XNRMarkPhase(XNR_PHASE_EARLY_DONE);
        return;
    }

    // ★ 注意：这里的 block 捕获 round（值捕获），递归改成了"排下一轮"，不再占用当前线程
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kEarlyIntervalMs * NSEC_PER_MSEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        @autoreleasepool { XNREarlyInstallStep(round + 1); }
    });
}

#pragma mark - ★ v1.0.3 只读观测：UIRefreshControl 轮询

// 为什么要从"结果侧"观测：UIRefreshControl 如果是由 scrollView 内部驱动进入刷新态的，
// 它【不经过】-beginRefreshing（那个方法是给外部代码程序化调用用的）。
// 所以我们直接读 scrollView.refreshControl.isRefreshing —— 只读属性，不改任何东西。
static void XNRPollScan(UIView *v) {
    if (!v) return;
    @try {
        if ([v isKindOfClass:[UIScrollView class]]) {
            UIScrollView *sv = (UIScrollView *)v;
            gPollScrollSeen++;
            UIRefreshControl *rc = sv.refreshControl;
            if (rc && rc.isRefreshing) {
                gPollHits++;
                if (gPollFirst < 0 && gStartTime > 0) {
                    gPollFirst = XNRNow() - gStartTime;
                    gPollPage  = XNRPageOfAny(v) ?: @"(未识别)";
                    XNRLogLine(@"🔎 轮询发现 UIRefreshControl 正在刷新：启动后 %.2fs  页面: %@",
                               gPollFirst, gPollPage ?: @"?");
                }
            }

            // ★ v1.0.3：第二路观测 —— 列表被"程序性地"拉下去了吗？（纯只读，见上面变量处的说明）
            //   条件：超出顶部 30pt 以上，且没有任何人在拖 / 没有惯性滑动
            //   → 那就是 App 自己在把列表往下拉（露出刷新圈圈），正是我们要抓的那一下。
            double over = (-(sv.contentOffset.y)) - sv.adjustedContentInset.top;
            if (over > 30.0 && !sv.isDragging && !sv.isTracking && !sv.isDecelerating) {
                gPollPullHits++;
                if (over > gPollPullMax) gPollPullMax = over;
                if (gPollPullFirst < 0 && gStartTime > 0) {
                    gPollPullFirst = XNRNow() - gStartTime;
                    gPollPullPage  = XNRPageOfAny(v) ?: @"(未识别)";
                    XNRLogLine(@"🔎 轮询发现列表被程序性拉下 %.0fpt（没人在拖）：启动后 %.2fs  页面: %@",
                               over, gPollPullFirst, gPollPullPage ?: @"?");
                }
                // ★★ v1.0.4：抓一次"现场" —— 这是"那个圈圈到底是谁家的"唯一的直接证据。
                //   我们没法从钩子看（一次都没触发），那就看**那一刻列表顶上到底摆着什么视图**。
                if (!gPollPullPullDone) {
                    gPollPullPullDone = YES;
                    @try {
                        NSString *rcInfo = sv.refreshControl
                            ? [NSString stringWithFormat:@"有(UIRefreshControl 系) 正在转=%@",
                               sv.refreshControl.isRefreshing ? @"是" : @"否"]
                            : @"没有 refreshControl → 刷新头是自研的";
                        NSMutableArray *tops = [NSMutableArray array];
                        for (UIView *sub in sv.subviews) {
                            if (sub.hidden) continue;
                            if (sub.frame.origin.y <= 200.0) {
                                [tops addObject:NSStringFromClass(object_getClass(sub))];
                                if (tops.count >= 6) break;
                            }
                        }
                        gPollPullDetail = [NSString stringWithFormat:
                            @"scrollView=%@ / %@ / 顶部子视图: %@",
                            NSStringFromClass(object_getClass(sv)),
                            rcInfo,
                            tops.count ? [tops componentsJoinedByString:@", "] : @"(无)"];
                        XNRLogLine(@"🔎 下拉现场：%@", gPollPullDetail);
                    } @catch (NSException *e) { (void)e; }
                }
            }
        }
        for (UIView *sub in v.subviews) XNRPollScan(sub);
    } @catch (NSException *e) { (void)e; }
}

static void XNRPollTick(int tick) {
    if (!kPollRefreshCtrl) return;
    if (tick >= kPollMaxTicks) {                  // 约 20 秒后自动停，不做长期轮询
        XNRMarkPhase(XNR_PHASE_POLL_DONE);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kPollIntervalSecs * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            gPollTicks++;
            for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)sc).windows) XNRPollScan(w);
            }
        } @catch (NSException *e) { (void)e; }
        XNRPollTick(tick + 1);
    });
}

__attribute__((constructor))
static void XNRInit(void) {
    // ★ 构造函数里【只排任务】，绝不扫类表、绝不动运行时（铁律 2）
    @autoreleasepool {
        // ★★ v1.0.1：gStartTime 在这里就落地，**不再依赖安装是否成功**。
        //    这样「弹窗能不能弹出来」就与「包名/扫描结果」彻底解耦 ——
        //    只要 Dylib 被加载了，弹窗就一定会弹，我们才能拿到数据。
        if (gStartTime <= 0) gStartTime = XNRNow();

        // ★ v1.0.3：这两个容器在【单线程的构造函数里】就建好。
        //    之后安装线程只往里追加、主线程只读快照，两边都不用再判 nil/竞态建表。
        if (!gHookedNames) gHookedNames = [NSMutableArray array];
        if (!gTimeline)    gTimeline    = [NSMutableArray array];

        // ★★★ v1.0.4：先读两样东西 —— ① 用户上次在弹窗里选的"是否开启早期安装"；
        //     ② 墓碑文件里"上一次启动止步于哪个阶段"。
        //     两者都必须在排任何任务之前就位，否则第一条日志/第一行墓碑会缺信息。
        //     ⚠️ 这里只做**字符串与文件读写**，不碰运行时 —— 构造函数可以安全做。
        kEarlyInstall = [[NSUserDefaults standardUserDefaults] boolForKey:kEarlyInstallKey];
        XNRPhaseLoad();
        XNRMarkPhase(XNR_PHASE_CONSTRUCTOR);

        // ★★★ v1.0.4 主路径：主队列（= v1.0.2 那条真机验证过不闪退的路径）
        //     构造函数里排的块，会在主线程第一次有空时**最先**跑（排在 App 自己的任务前面）。
        dispatch_async(dispatch_get_main_queue(), ^{
            XNRInstallWhenReady(0);
        });

        // ★ 可选的早期安装（默认关闭；用户可在弹窗上开启，下次启动生效）
        //   注意：**先等 dyld 静下来**再动手，绝不"掐表 40ms"（见 XNRDyldWaitStep 上面的复盘）。
        if (kEarlyInstall) {
            XNRMarkPhase(XNR_PHASE_EARLY_WAIT);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(kDyldSampleMs * NSEC_PER_MSEC)),
                           dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                @autoreleasepool { XNRDyldWaitStep(0); }
            });
        }

        // 只读观测：低频轮询（refreshControl.isRefreshing + 列表是否被程序性拉下）
        dispatch_async(dispatch_get_main_queue(), ^{
            XNRPollTick(0);
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
