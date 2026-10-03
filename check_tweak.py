#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
XhsNoAutoRefresh 交付前静态自检
================================
为什么需要它：Windows 上编不了 Theos（没有 iOS clang），
每一次 CI 编译失败 = 用户多跑一轮「上传 → 等 Actions → 下载 → 注入」（5~10 分钟）。
所以用不依赖编译器的静态检查，把能提前发现的问题在本地和 CI 都拦掉。

用法：
    本地   python check_tweak.py [Tweak.x 路径]
    CI     python3 check_tweak.py          （仓库根目录，默认读 ./Tweak.x）

★ 这个文件是**唯一的检查来源**：本地和 CI 共用同一份，避免两处规则漂移。
"""

import re
import sys

DEFAULT = "Tweak.x"


def _selftest():
    """反向测试：往好代码里注入已知错误，确认本检查器真的能 exit 1。

    ★ 为什么必须有这个：本轮开发中先后发现【两次检查自身静默失效】——
      ① 静态初始化块的正则没锚定「顶格 static」，`.` 一路吞到后面的代码里 → 误报；
      ② 函数定义正则匹配不了 `NSString *Foo(` 这种「星号紧贴函数名」的返回类型，
         函数根本没进表，于是「先定义后调用」「实参个数」两条规则**全部静默不生效**。
      没做反向测试的话，这两次都会以「自检通过 ✓」的形式骗过我们，然后在 CI 上炸。
    """
    import os
    import subprocess
    import tempfile

    base = open(DEFAULT, "rb").read().decode("utf-8")
    cases = []          # 期望【报错】的变异体
    clean_cases = []    # ★ 期望【通过】的变异体（防假阳性）—— 见 mutant_clean
    missing = []      # ★ 锚点找不到的用例：**必须判为失败**，见下面 mutant_ok 的说明

    def mutant(label, old, new):
        if old not in base:
            print("  ✗ 锚点没找到：%s" % label)
            missing.append(label)
            return
        cases.append((label, base.replace(old, new, 1)))

    # ★ v1.0.8：变异体必须是【语法上依然平衡】的，否则测的是"另一个问题"，
    #   结论也解释不通（本轮就踩过：变异体多出一个花括号，反而让规则 5 漏报）。
    #   ★★ 而 v1.0.8 又发现了这层校验的**另一半漏洞**：
    #     一个变异体可能**被别的规则顺手兜住** —— 于是 exit code 是 1、"✓ 抓到了"，
    #     但被测的那条规则其实一次都没响。测试绿了，规则却是坏的。
    #   → 所以 mutant_ok 增加 `expect`：**必须由这条规则抓**（在输出里出现指定的那句话）。
    #     这是本项目反复学到的那条纪律的一个新侧面：**"报错了"不等于"报的是我要查的那件事"。**
    def mutant_ok(label, old, new, expect=None):
        if old not in base:
            # ★★ v1.0.4：锚点找不到**不能只是"跳过"** —— 那等于这条检查从此悄悄失效，
            #   而我们恰恰是因为"检查器静默失效"栽过三次。所以这里直接判为失败，
            #   逼着我们每次改代码后把锚点同步更新（或明确删掉这条规则）。
            print("  ✗ 锚点没找到（这条规则的测试已经失效了，请更新锚点）：%s" % label)
            missing.append(label)
            return
        t = base.replace(old, new, 1)
        for op, cl in [("{", "}"), ("(", ")"), ("[", "]")]:
            if t.count(op) != t.count(cl):
                print("  ！变异体本身括号不平衡，测试无效：%s" % label)
                missing.append(label)
                return
        cases.append((label, t, expect))

    # ★★ v1.0.5：反向测试原来只测"该报的报了没有"，**测不出"不该报的乱报了"**。
    #   而本项目栽在假阳性上的次数并不比漏报少：
    #     规则 13 第一版报 42 处假阳性（ObjC 相邻字面量拼接）、
    #     `#pragma mark` 里的中文引号被当成字符串、
    #     规则 6 的 `.*?\n};` 遇到同行闭合的 static 数组就吞到几百行外、
    #     规则 14 把三元运算符 `? :` 的冒号当成选择器冒号。
    #   假阳性比漏报更危险：它会**逼着人把本来正确的代码改坏**，而且改完就"绿了"，没人知道是规则错。
    #   所以补这一类用例：这些变异体**必须 exit 0**。
    def mutant_clean(label, old, new):
        if old not in base:
            print("  ✗ 锚点没找到（这条「不许误报」的测试已经失效）：%s" % label)
            missing.append(label)
            return
        clean_cases.append((label, base.replace(old, new, 1)))

    mutant_ok("静态初始化器里用 @\"...\"",
              'XNRSigVoidNoArg,  NO  },\n    { "endRefreshing"',
              'XNRSigVoidNoArg,  NO, @"拦截+计数" },\n    { "endRefreshing"', expect="静态初始化块里出现")
    mutant_ok("实参个数不符",
              "XNRFmtOff(gProbeEndFirst)", "XNRFmtOff(gProbeEndFirst, 1)", expect="个实参，但定义是")
    mutant_ok("常量定义被删",
              "static const NSInteger kStatePulling = 2;", "", expect="但没有定义")
    mutant_ok("出现几何写入",
              "static BOOL kProbeTrigger = YES;",
              "static BOOL kProbeTrigger = YES;\nstatic void badGeom(id v){ [v setContentOffset:CGPointZero]; }", expect="几何写入")
    mutant_ok("出现 Logos 钩子",
              "#pragma mark - 配置", "%hook Foo\n%end\n\n#pragma mark - 配置", expect="Logos 钩子")
    # ★ v1.0.8 机制禁令：把取类表换回 objc_copyClassList（= 退回 1347 ms 的病根）
    #   ★ 这条的特别之处：它是**覆盖率探针先指出"这是盲区"、然后才被堵上**的第一条。
    #     （探针里那条 `[盲区] 把 objc_getClassList 换回 objc_copyClassList` 现在应当被报到。）
    #   ★ 它**测的是"真代码"**（锚点是 XNRCopyClassList 的调用点），不是"造一段假源码"。
    mutant_ok("把取类表换回 objc_copyClassList（退回病根）",
              "XNRCopyClassList(&gWalkCount);",
              "objc_copyClassList(&gWalkCount);",
              expect="objc_copyClassList")
    # 探针不再转交原实现：把 reloadData 探针里的两行转交代码整段删掉（花括号保持平衡）
    mutant_ok("探针不再转交原实现",
              "    IMP orig = XNROrigFor(self, _cmd);\n"
              "    if (orig) ((void (*)(id, SEL))orig)(self, _cmd);\n"
              "}\n\n"
              "// ② 刷新结束",
              "}\n\n"
              "// ② 刷新结束", expect="没有把调用转交原实现")
    # 格式化占位符与实参不符：从那个 37 占位符的弹窗模板里删掉一个实参
    mutant_ok("格式化占位符与实参不符",
              "            gProbeReload, XNRFmtOff(gProbeReloadFirst),\n", "", expect="个占位符，但传了")
    # 加锁后提前 return 漏解锁：把 @finally 拆成普通语句
    mutant_ok("加锁后提前 return 漏解锁",
              "@finally { [lk unlock]; }", "[lk unlock];", expect="没有 @finally")
    # C 字符串里写中文 → 经 %s 输出会花屏（真机上才看得见的 bug）
    #   ★ 锚点特意选 kTargetBundlePrefix：它的值不随版本号变化，不会因为"改版本号"而失效
    mutant_ok("C 字符串字面量里写中文",
              'static const char *kTargetBundlePrefix = "com.xingin.";',
              'static const char *kTargetBundlePrefix = "com.xingin.测试";', expect="非 ASCII")
    # 漏写 @：把 C 字符串当对象传给选择器/函数（ARC 下是硬编译错误）
    #   ★ 变异体的内容**必须是纯 ASCII**，否则会同时触发规则 13，测的就不是规则 14 了
    mutant_ok("C 字符串当对象用（漏写 @）",
              '[NSString stringWithFormat:@"XhsNoRefresh v%s  ✅ 已复制到剪贴板", kVersion]',
              '[NSString stringWithFormat:"XhsNoRefresh v%s ok", kVersion]', expect="传了 C 字符串字面量")
    # ★ v1.0.6：占位符【类型】位置（规则 11c）。
    #   「个数对、类型不对」也是崩溃级，而 v1.0.6 一次加了 4 个新的 %@，正是高发场景。
    #   这两个变异体都保持实参个数不变，所以只会命中 11c、不会命中 11 —— 测的就是新规则本身。
    mutant_ok("占位符类型不符（%@ 吃到 int 实参）",
              "            gProbeReload, XNRFmtOff(gProbeReloadFirst),",
              "            gProbeReload, gProbeReload,", expect="是数值/标量")
    mutant_ok("占位符类型不符（%d 吃到对象实参）",
              "            gProbeReload, XNRFmtOff(gProbeReloadFirst),",
              "            kVersion, XNRFmtOff(gProbeReloadFirst),", expect="会把指针当整数解释")
    # ★ v1.0.7：规则 8 的「关键函数清单」是一条**会腐烂的清单** ——
    #   本轮把 XNRInstallGates 拆成四个函数时就踩到了：清单没同步 →
    #   规则 8 立刻以"真定义出现 0 次"报警（这正是它该做的，但说明清单必须跟着改）。
    #   这个用例保证它的**计数**仍然有效（造一处重复真定义）。
    mutant_ok("关键函数出现两处真定义",
              "static void XNRRefreshGateInfo(void) {",
              "static void XNRRefreshGateInfo(void) {\n}\nstatic void XNRRefreshGateInfo(void) {", expect="真定义出现 2 次")
    # 这一条是故意造括号不平衡，不做平衡校验
    cases.append(("括号不平衡", base + "\nstatic void broken(void) {\n"))
    # ★ v1.0.8：规则 16 —— 「字符串被半角引号截断」。
    #   ★★ 变异体**照着真实 bug 的形态来**（这才是关键）：真实那一行有 **4** 个引号（偶数），
    #      所以"数引号个数"那种写法根本抓不到它；抓到它的是"中文跑到了代码区"这条子判据。
    #      变异体故意不做成"引号根本未闭合"—— 那会连锁污染其它规则（见规则 16 上面的实测），
    #      虽然也会报错，但测的就不是"这条规则能不能抓到真 bug"了。
    #   ★★ 而这条规则本身，就是**新写的代码自己踩出来的**（见规则 16 上面的说明）——
    #      这正是「新写法要当场造变异体」的另一半价值：它能长出**新规则**。
    mutant_ok("字符串被半角引号截断（中文漏到代码区）",
              '@"=== v%s 窄快扫：取类表 %.0f ms（%d 个类）/ 遍历 %.0f ms / "',
              '@"=== v%s 窄快扫：取类表 %.0f ms（%d 个类）/ "遍历" %.0f ms / "',
              expect="代码区**里出现了中文字符")
    #   再补一个"引号根本没闭合"的形态，专门验证子判据 (a)
    mutant_ok("字符串没有闭合（引号成奇数）",
              "static BOOL gInstalled = NO;",
              'static BOOL gInstalled = NO;\nstatic const char *zq = "abc;',
              expect="双引号没有配对")

    # ── 以下是「不许误报」的用例：必须 exit 0 ─────────────────────────────
    # 规则 6 的终止符：同一行闭合的 static 数组，后面隔着几十行代码里还有 @"..."
    mutant_clean("同行闭合的 static 数组（不该报）",
                 "static BOOL gInstalled = NO;",
                 'static BOOL gInstalled = NO;\nstatic const char *zt[] = { "a", "b" };')
    # 规则 14 的两条豁免：白名单里的 C 字符串函数 + 三元运算符的冒号
    mutant_clean("strcmp/三元冒号（不该报）",
                 "    if (gLaunchNo <= 0) return;",
                 "    if (gLaunchNo <= 0) return;\n"
                 '    const char *zn = (strcmp(name, "?") == 0) ? "a" : "b";\n'
                 "    (void)zn;")
    # 规则 11c 的"拿不准就沉默"：三元、下标、强制转换 一律不算类型 ——
    #   ★ 这是本规则的命门。它一旦开始猜，就会误报；误报会逼着人把正确代码改坏。
    mutant_clean("类型拿不准的实参不报警（三元/下标/强转）",
                 "    if (gLaunchNo <= 0) return;",
                 "    if (gLaunchNo <= 0) return;\n"
                 '    NSString *zz = [NSString stringWithFormat:@"%@ %.1f", (id)nil, pool[0]];\n'
                 "    (void)zz;")
    # ★ v1.0.8：规则 16 的两条豁免 —— 它们是这条规则一开始就必须避开的假阳性来源。
    # ① `//` 注释里可以随便出现引号（本文件注释里就有好几处；若按"整行数引号"必误报）
    mutant_clean("注释里的引号（不该报）",
                 "    if (gLaunchNo <= 0) return;",
                 "    if (gLaunchNo <= 0) return;\n"
                 "    // 这就是所谓的\"边界\"情况：注释里可以随便写 \" 引号\n")
    # ② 字符串里的转义引号 `\"` 不结束字符串（漏了这条，正常代码会被判成错）
    mutant_clean("字符串里的转义引号（不该报）",
                 "    if (gLaunchNo <= 0) return;",
                 "    if (gLaunchNo <= 0) return;\n"
                 '    NSString *ze = @"a\\"b"; (void)ze;\n')
    # ③ `#pragma mark - <中文>` 是唯一豁免的"代码区带中文"形态（本工程有 16 处）
    mutant_clean("#pragma mark 里的中文（不该报）",
                 "    if (gLaunchNo <= 0) return;",
                 "    if (gLaunchNo <= 0) return;\n"
                 "#pragma mark - 中文小标题里也可以有 \" 这种引号\n")

    ok = True
    tmpdir = tempfile.mkdtemp(prefix="xhscheck_")

    # 先确认「原样代码」是能过的，否则后面的判定没意义
    p0 = subprocess.run([sys.executable, os.path.abspath(__file__),
                         os.path.abspath(DEFAULT)], capture_output=True)
    if p0.returncode != 0:
        print("  ✗ 原始文件本身就没通过自检 —— 先修好它再谈反向测试")
        print(p0.stdout.decode("utf-8", "replace"))
        return False

    for c in cases:
        label, text = c[0], c[1]
        expect = c[2] if len(c) > 2 else None
        fp = os.path.join(tmpdir, "case.x")
        open(fp, "w", encoding="utf-8", newline="\n").write(text)
        r = subprocess.run([sys.executable, os.path.abspath(__file__), fp],
                           capture_output=True)
        caught = (r.returncode == 1)
        out = r.stdout.decode("utf-8", "replace")
        msg = out.strip().split("\n")[0] if caught else ""
        # ★ v1.0.8：不只要求"报错了"，还要求"报的是这条规则"
        if caught and expect and expect not in out:
            caught = False
            print("  ✗ %s  —— 报是报了，但**不是这条规则抓的**（期望输出里含 %r）；"
                  "说明这个变异体被别的规则顺手兜住了，被测的规则其实没响" % (label, expect))
            print("      实际输出：%s" % msg)
        ok = ok and caught
        if caught:
            print("  ✓ %s%s" % (label, ("  → " + msg) if msg else ""))
        elif not (expect and expect not in out):
            print("  ✗ 没抓到！%s" % label)

    # ★ 反面用例：这些必须【通过】，报错就说明规则写得太激进
    for label, text in clean_cases:
        fp = os.path.join(tmpdir, "clean.x")
        open(fp, "w", encoding="utf-8", newline="\n").write(text)
        r = subprocess.run([sys.executable, os.path.abspath(__file__), fp],
                           capture_output=True)
        clean = (r.returncode == 0)
        ok = ok and clean
        msg = "" if clean else r.stdout.decode("utf-8", "replace").strip().split("\n")[0]
        print("  %s %s%s" % ("✓" if clean else "✗ 误报了！", label,
                             ("  → " + msg) if msg else ""))

    if missing:
        print("\n  ⚠️ 有 %d 条用例的锚点没找到 → 这些规则【当前完全没有被测到】：%s"
              % (len(missing), "、".join(missing)))
        print("     处理办法：把锚点更新成新代码里的等价片段；若这条规则确实不再需要，就把它删掉。")
        ok = False

    # ★ v1.0.8：把条数**由脚本自己算出来打出来**。
    #   起因：v1.0.8 加了 2 条必报用例（14 → 16），但 `control` 和 README 里还写着
    #   「15 必报」—— 数字对不上。★ 凡是"人手工维护的计数"，迟早会腐烂；
    #   唯一可靠的办法是让它**从数据里长出来**，而不是写在别处。
    n_must  = len(cases)
    n_clean = len(clean_cases)
    print("\n反向测试：%s （必报 %d 条 + 必不报 %d 条，共 %d 条用例）"
          % ("全部通过 ✓ 这个检查器是有效的" if ok else "不可靠 ✗ —— 别拿它当交付依据",
             n_must, n_clean, n_must + n_clean))
    return ok


if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
    sys.exit(0 if _selftest() else 1)

path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT

try:
    raw = open(path, "rb").read()
except OSError as e:
    print("::error file=%s::读不到 %s（%s）" % (path, path, e))
    sys.exit(1)

src = raw.decode("utf-8", errors="replace")
# 去掉注释与字符串，避免注释/字面量里的词被当成代码
s = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
s = re.sub(r"//[^\n]*", "", s)
# ★ v1.0.4：`#pragma` 是预处理指令，它后面的内容是给编译器的注释性标记，**不是字符串字面量**。
#   起因：第 13 条规则上线后，把 `#pragma mark - ... （用来定位"……"）` 里的中文引号
#   当成了 C 字符串 → 误报。**这类"假阳性逼你改掉本来正确的代码"必须修在规则里，而不是改代码。**
#   （只清掉行内容、保留换行符，所以后面的行号不受影响。）
s = re.sub(r"^[ \t]*#[ \t]*pragma[^\n]*", "", s, flags=re.M)
code = re.sub(r'"(?:[^"\\]|\\.)*"', '""', s)

problems = []


def add(msg):
    problems.append(msg)


def line_of(pos):
    return code[:pos].count("\n") + 1


# ── 1. 常量定义齐全 ────────────────────────────────────────────────────────
# 起因：B站那版曾把两行紧挨的常量声明误删一行 → "use of undeclared identifier"
for name in sorted(set(re.findall(r"\b([kg][A-Z]\w*)\b", code))):
    if not re.search(r"\b" + name + r"\s*(=|;|\[)", s):
        ln = next((i + 1 for i, l in enumerate(s.splitlines())
                   if re.search(r"\b" + name + r"\b", l)), 0)
        add("常量 %s 被使用（第 %d 行）但没有定义" % (name, ln))

# ── 2. 零 Logos / 零 substrate ─────────────────────────────────────────────
# 铁律 1：TrollFools 原位注入环境下，Logos %hook + CydiaSubstrate 会闪退
for pat, msg in [(r"^\s*%hook", "出现 Logos 钩子 %hook（本工程应零 Logos）"),
                 (r"#\s*import\s*[^\n]*substrate", "引用了 substrate 头文件"),
                 (r"MSHookMessageEx|MSHookIvar", "调用了 substrate API")]:
    if re.search(pat, src, re.M):
        add(msg)

# ── 3. 零几何写入 ─────────────────────────────────────────────────────────
# 铁律 3：写几何值（contentOffset/contentInset/frame）会和 App 的布局系统互相纠正 → 卡死
for pat in [r"setContentInset\s*:", r"setContentOffset\s*:", r"setFrame\s*:"]:
    if re.search(pat, code):
        add("出现几何写入 %s（本工程明令禁止：会与布局系统互相纠正导致卡死）" % pat.split("\\")[0])

# ── 4. 禁止「直接发消息调用」App 的语义 API ────────────────────────────────
# 把 setState: / endRefreshing 挂成【只读探针】是允许的；
# 禁止的是【直接发消息调用】它们 —— 那才是"下拉即闪退 / 卡死"的成因。
# 正则必须写成「右方括号 + 选择器」的形式，否则会被挂钩表里的字符串误伤。
for pat, msg in [(r"\]\s*endRefreshing\s*\]", "直接发消息调用 endRefreshing（禁止）"),
                 (r"\]\s*setState\s*:", "直接发消息调用 setState:（禁止）"),
                 (r"\]\s*reloadData\s*\]", "直接发消息调用 reloadData（禁止）")]:
    if re.search(pat, code):
        add(msg)

# ── 4b. ★ v1.0.8 机制禁令：不许再用 objc_copyClassList ───────────────────────
#   v1.0.8 的**全部意义**就是「取类表不强制 realize」，靠的是换成 objc_getClassList。
#   一旦有人把它换回去（比如心想"反正语义一样、两种写法都扫真类"），
#   v1.0.7 那个 **1347 ms 的病根就原样回来** —— 而它**编得过、跑得通、静态上完全合法**，
#   没有任何别的检查会响。★ 这正是覆盖率探针里那条「已知盲区」，
#   现在把它**从盲区里拿出来**，做成一条零风险的禁令。
#   ★ 判据必须作用在 `code`（已去注释、去字符串）上：
#     本工程**注释里**提到 objc_copyClassList 有 11 处（都是解释"为什么不用它"），
#     作用在原文上必误报；实测 `code` 里它是 **0 次** → 这条规则零假阳性风险。
if re.search(r"\bobjc_copyClassList\b", code):
    add("出现 objc_copyClassList（v1.0.8 起明令禁止：它内部会先 realizeAllClasses()，"
        "把镜像里所有还没 realize 的类一口气全 realize 一遍 —— 真机实测在主队列上花了 1347 ms，"
        "正好遮住我们自己的观测窗口）。取类表请统一用 XNRCopyClassList()")

# ── 5. 只读探针必须把调用「原样转交」给原实现 ──────────────────────────────
# 防止有人把探针写成"只计数不转交" → 那就是偷偷改行为（等于把 -reloadData 废掉）
def func_body(text, name):
    """定位 `static ... name( ... )  {`，再用【花括号配对】取出完整函数体。

    ★ 不能图省事写成 `.*?\\n\\}`：一旦这段代码里花括号多一个或少一个，
      非贪婪匹配就会一路吞进【下一个函数】，于是从邻居身上读到 XNROrigFor，
      本该报的问题变成不报 —— 假阴性。这个坑是 --selftest 抓出来的。
    """
    m = re.search(r"^static\s+[^\n;{}]*?\b" + re.escape(name) + r"\s*\([^;{}]*\)\s*\{", text, re.M)
    if not m:
        return None
    depth, i = 0, m.end() - 1          # m.end()-1 指向 '{'
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[m.end() - 1:i + 1]
        i += 1
    return None


for fn in ["XNRHookedReloadData", "XNRHookedEndRefreshing", "XNRHookedSetState"]:
    body = func_body(code, fn)
    if body is None:
        add("找不到探针函数 %s 的定义" % fn)
    elif "XNROrigFor" not in body:
        add("探针 %s 没有把调用转交原实现（必须原样放行）" % fn)

# ── 6. 静态存储期的初始化器里禁止 ObjC 字面量 @"..." ───────────────────────
# 通则是：静态初始化器只允许 C 常量表达式。@"..." 在静态初始化里既不是编译期常量、
# 类型也对不上 —— clang 会以 -Werror,-Wincompatible-pointer-types 直接报错。
# （v1.0.2 首轮 CI 就栽在这：结构体字段是 const char *，初始化却写成 @"..."）
# 6a 文件作用域的结构体/数组初始化块
#     ★ 必须锚定「顶格的 static」：函数体内缩进的 static 不是文件级初始化，
#       而且它的 "};" 常在同一行，不锚定就会让 .*? 一路吞到后面别的代码里 → 误报
#     ★★ v1.0.5 修掉终止符：原来写 `.*?\n};`，遇到
#        `static const char *zt[] = { "a", "b" };`（**同一行闭合**）时，
#        `\n};` 在这个块里根本不存在 → `.*?` 继续往后吞几百行，直到撞上别的函数的 `\n};`，
#        于是把中间所有 @"..." 都算成"这个初始化块里的" → 假阳性。
#        （又是那条通则：**新规则一跑就报假阳性，先怀疑规则写错了。**）
#        现在改成**花括号配对**取块，与写法无关。
for m in re.finditer(r"^static\s+[^;\n=]*=\s*\{", code, re.M):
    _d, _k = 0, m.end() - 1
    while _k < len(code):
        if code[_k] == "{":
            _d += 1
        elif code[_k] == "}":
            _d -= 1
            if _d == 0:
                break
        _k += 1
    if '@"' in code[m.start():_k + 1]:
        add("第 %d 行起的静态初始化块里出现 @\"...\"：静态初始化只允许 C 字符串" % line_of(m.start()))
# 6b 单行静态变量
for m in re.finditer(r"^static\s+([A-Za-z_][\w\s\*]*?)\s+(\w+)\s*=\s*@\"", code, re.M):
    typ = m.group(1).strip()
    if not re.match(r"^(NSString|NSMutableString|NSArray|NSMutableArray|NSDictionary|"
                    r"NSMutableDictionary|NSNumber|NSData|NSDate|NSOrderedSet|id)\b", typ):
        add("静态变量 %s 声明为 `%s` 却用 @\"...\" 初始化（静态初始化只允许 C 字符串）"
            % (m.group(2), typ))

# ── 7. 括号平衡 ───────────────────────────────────────────────────────────
for op, cl in [("{", "}"), ("(", ")"), ("[", "]")]:
    if code.count(op) != code.count(cl):
        add("括号不平衡：%s=%d 但 %s=%d" % (op, code.count(op), cl, code.count(cl)))

# ── 8. 关键函数必须只有一处「真定义」 ──────────────────────────────────────
# 起因：曾用脚本删重复函数时按 "\n}\n" 定位，误匹配到内层闭包，
#       把函数截断成半截、反而制造出重复定义，而 clang 的报错完全指向别处。
# ★ v1.0.7：清单随安装机制改名而更新 —— XNRInstallGates 拆成了
#   XNRScanOneClass（单类处理）/ XNRInstallNarrow（窄快扫）/
#   XNRInstallChunkStep（分片推进）/ XNRRefreshGateInfo（收尾统计）/ XNRNarrowRescanLoop（重扫循环）。
#   ⚠️ 拆函数时**必须同步改这里**，否则这条规则会以"真定义出现 0 次"的形式报警（这正是它的作用）。
# ★ v1.0.8：新增 XNRCopyClassList（取类表，不强制 realize）—— 它是本版唯一的机制改动，
#   而且必须在 XNRInstallNarrow 之前定义（规则 9"先定义后调用"也会跟着管它）。
for fn in ["XNRPresentStats", "XNRStatsRetry", "XNRInstallWhenReady",
           "XNRScanOneClass", "XNRInstallNarrow", "XNRInstallChunkStep",
           "XNRRefreshGateInfo", "XNRNarrowRescanLoop", "XNRCopyClassList",
           "XNRFmtOff", "XNRFmtTimes", "XNRProbeNote", "XNRPageOfAny", "XNRIsRefreshControl",
           "XNRRecordEventKind", "XNRAllEvents", "XNRRecordEvent",
           "XNRInstallAttempt", "XNREarlyInstallStep", "XNRPollScan", "XNRPollTick",
           "XNRSeenAndAdd"]:
    # 只统计「真定义」：返回类型 + 名字 + 参数 + 紧跟 {（前置声明以 ; 结尾，不算）
    n = len(re.findall(r"^static\s+[^\n;{}]*?\b" + fn + r"\s*\([^;{]*\)\s*\{", code, re.M))
    if n != 1:
        add("函数 %s 的真定义出现 %d 次（应为 1）" % (fn, n))

# ── 9. 函数「先定义后调用」+ 实参个数一致 ──────────────────────────────────
# 没本地编译器，这两类错只能靠静态分析拦；而每轮 CI 失败都要用户等 5~10 分钟。
def split_top(text):
    """按顶层逗号切分，跳过 () [] {} 与字符串/字符字面量"""
    out, depth, cur, i, q = [], 0, "", 0, None
    while i < len(text):
        ch = text[i]
        if q:
            if ch == "\\":
                cur += text[i:i + 2]
                i += 2
                continue
            if ch == q:
                q = None
            cur += ch
            i += 1
            continue
        if ch in "\"'":
            q = ch
            cur += ch
            i += 1
            continue
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
            i += 1
            continue
        cur += ch
        i += 1
    if cur.strip() or out:
        out.append(cur.strip())
    return out


def match_paren(text, open_idx):
    depth, i, q = 0, open_idx, None
    while i < len(text):
        ch = text[i]
        if q:
            if ch == "\\":
                i += 2
                continue
            if ch == q:
                q = None
            i += 1
            continue
        if ch in "\"'":
            q = ch
            i += 1
            continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


# ★ 返回类型可能长这样：`NSString *XNRFmtOff(`（星号紧贴函数名）、`const char *XNRFmtOff(`。
#   所以不能切成「类型 + 空格 + 名字」，要改成「名字之前的一串任意字符（不含换行/;/{}）」——
#   否则 `NSString *Foo(` 这种定义根本进不了函数表，后面的检查会**全部静默失效**（踩过）。
_DEF_RE = r"^static\s+[^\n;{}]*?([A-Za-z_]\w*)\s*\(([^;{}]*)\)\s*\{"
_DECL_RE = r"^static\s+[^\n;{}]*?([A-Za-z_]\w*)\s*\([^;{}]*\)\s*;"

defs, decls = {}, {}
for m in re.finditer(_DEF_RE, code, re.M):
    ps = split_top(m.group(2))
    variadic = any("..." in p for p in ps)
    nargs = 0 if (len(ps) == 1 and ps[0].strip() in ("void", "")) else len([p for p in ps if p])
    defs.setdefault(m.group(1), []).append((m.start(), m.end(), nargs, variadic))
for m in re.finditer(_DECL_RE, code, re.M):
    decls.setdefault(m.group(1), []).append((m.start(), m.end()))


def spans(name):
    out = [(t[0], t[1]) for t in defs.get(name, [])]
    out += [(t[0], t[1]) for t in decls.get(name, [])]
    return out


def inside_own_sig(name, pos):
    """pos 是否落在该函数自己的定义/声明签名里 —— 那就不是调用点"""
    return any(a <= pos < b for a, b in spans(name))


for name, dlist in defs.items():
    dpos, dend, nargs, variadic = min(dlist, key=lambda t: t[0])
    for m in re.finditer(r"(?<![\w$])" + re.escape(name) + r"\s*\(", code):
        cpos = m.start()
        if inside_own_sig(name, cpos):
            continue                        # 定义/声明自己的参数表，不是调用
        if not any(b <= cpos for _, b in decls.get(name, [])) and cpos < dend:
            add("第 %d 行调用了 %s，但它的定义在第 %d 行之后、且没有前置声明"
                % (line_of(cpos), name, line_of(dpos)))
            continue
        if variadic:
            continue
        op = m.end() - 1
        cl = match_paren(code, op)
        if cl < 0:
            continue
        args = split_top(code[op + 1:cl])
        if len(args) == 1 and not args[0].strip():
            args = []
        if len(args) != nargs:
            add("第 %d 行调用 %s 传了 %d 个实参，但定义是 %d 个形参"
                % (line_of(cpos), name, len(args), nargs))

# ── 10. 行尾符必须 LF、且不带 BOM ─────────────────────────────────────────
if b"\r\n" in raw:
    add("检测到 CRLF 行尾符，必须转成 LF")
if raw[:3] == b"\xef\xbb\xbf":
    add("文件带 UTF-8 BOM，必须去掉")

# ── 汇总 ──────────────────────────────────────────────────────────────────
# ── 11. 格式化字符串的占位符个数 == 实参个数 ────────────────────────────────
# 这是【运行时崩溃】级的问题：-initWithFormat:arguments: 遇到数量不匹配会抛 NSException，
# 而弹窗正好在那一刻炸掉 —— 而且本工程刚写了一个 37 个占位符的超长模板，人工数不现实。
# 覆盖两处：`[NSString stringWithFormat:@"...", args]` 和 `XNRLogLine(@"...", args)`。
def leading_literals(text, start):
    """吃掉从 start 起的连续字符串字面量（ObjC 会把相邻字面量自动拼接），返回 (拼接结果, 结束下标)"""
    i, lits = start, []
    while True:
        while i < len(text) and text[i] in " \t\n\r":
            i += 1
        j = i
        if text[j:j + 2] == '@"':
            j += 1
        if j < len(text) and text[j] == '"':
            j += 1
            buf = []
            while j < len(text) and text[j] != '"':
                if text[j] == "\\":
                    buf.append(text[j:j + 2])
                    j += 2
                    continue
                buf.append(text[j])
                j += 1
            lits.append("".join(buf))
            i = j + 1
            continue
        break
    if not lits:
        return None, start
    return "".join(lits), i


def count_placeholders(fmt):
    """数 % 占位符；%% 是转义，不算"""
    n, i = 0, 0
    while i < len(fmt):
        if fmt[i] == "%":
            if i + 1 < len(fmt) and fmt[i + 1] == "%":
                i += 2
                continue
            n += 1
        i += 1
    return n


# ── 11c. 占位符的【类型】与实参位置对不对得上 ───────────────────────────────
# 规则 11 只数【个数】。但「个数对、类型不对」同样是崩溃级：
#     [NSString stringWithFormat:@"%@", gSomeCount]   → 把整数当对象解引用 → EXC_BAD_ACCESS
# 而 v1.0.6 恰好一次性加了 4 个新的 %@（时间轴那四行），这种错最容易在
# 「格式串上插了一行、实参忘了跟着改」或「复制粘贴换了变量名」时发生。
#
# ★★ 已知盲区（做不到，也不该假装做到）：**同类型实参之间的顺序调换**。
#    四个 %@ 配四个 NSString*，谁在前谁在后，静态检查无论如何看不出来 ——
#    只能靠「实参顺序与格式串自上而下逐行对应」这条人工纪律。
#    ★ 本项目已经栽过两次「检查器规则写太激进」的假阳性，而假阳性比漏报更危险，
#      所以本规则**只在类型能确定时才说话**，拿不准一律沉默。
_SCALAR_TYPES = ("unsigned", "signed", "int", "long", "short", "char", "BOOL", "bool",
                 "float", "double", "NSInteger", "NSUInteger", "CGFloat", "NSTimeInterval",
                 "size_t", "ptrdiff_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t",
                 "int8_t", "int16_t", "int32_t", "int64_t")


def _strip_comments(text):
    """剥离注释后建立变量表 —— 否则注释里的 `*foo`、`(NSString *)` 会被当成变量声明。
    注意：调用点传进来的 `s` 其实上面已经剥过一次注释了（见本文件 189~195 行）；
    这里保留独立的一份是为了让本段规则**自成一体**，不依赖"上面恰好剥过"这个隐含前提。"""
    out = []
    for ln in text.split("\n"):
        if ln.lstrip().startswith("//"):
            continue
        if '"' not in ln:
            k = ln.find("//")
            if k >= 0:
                ln = ln[:k]
        out.append(ln)
    return "\n".join(out)


_code = _strip_comments(s)
_scalar_vars = set()
for _m in re.finditer(r"\b(?:%s)\s+([A-Za-z_]\w*)" % "|".join(_SCALAR_TYPES), _code):
    _scalar_vars.add(_m.group(1))
# 指针声明：本项目统一写成 `Type *name`（星号紧贴变量名），所以这里不允许星号后有空格 ——
# 否则 `a * b` 这种乘法也会被当成指针声明，凭空造出假变量。
_object_vars = set()
for _m in re.finditer(r"\*([A-Za-z_]\w*)", _code):
    _object_vars.add(_m.group(1))


def placeholder_kinds(fmt):
    """按出现顺序返回每个占位符要的类型：'obj' / 'scalar' / None(不知道)。
    遇到 `*` 宽度/精度（会吃掉额外实参，位置对应关系就乱了）直接放弃整条串。"""
    out, i = [], 0
    while i < len(fmt):
        if fmt[i] != "%":
            i += 1
            continue
        if i + 1 < len(fmt) and fmt[i + 1] == "%":
            i += 2
            continue
        j = i + 1
        while j < len(fmt) and fmt[j] in "-+ #0'":
            j += 1
        if j < len(fmt) and fmt[j] == "*":          # 宽度来自实参 → 位置对不上，放弃
            return None
        while j < len(fmt) and fmt[j].isdigit():
            j += 1
        if j < len(fmt) and fmt[j] == ".":
            j += 1
            if j < len(fmt) and fmt[j] == "*":
                return None
            while j < len(fmt) and fmt[j].isdigit():
                j += 1
        while j < len(fmt) and fmt[j] in "hlLqjzt":
            j += 1
        if j >= len(fmt):
            break
        c = fmt[j]
        if c == "@":
            out.append("obj")
        elif c in "diouxXceEfFgGaA":
            out.append("scalar")
        else:
            out.append(None)                        # %s %p %n … 不管
        i = j + 1
    return out


def _arg_kind(a):
    """判断单个实参的类型：'obj' / 'scalar' / None(拿不准)。
    ★ 只在能确定时才返回，其余一律 None —— 宁可漏报也不误报。"""
    a = a.strip()
    if not a:
        return None
    if a.startswith('@"') or a.startswith("@["):
        return "obj"
    if re.fullmatch(r"-?\d+(?:\.\d+)?[fFuUlL]*", a) or re.fullmatch(r"0[xX][0-9a-fA-F]+[uUlL]*", a):
        return "scalar"
    if re.fullmatch(r"[A-Za-z_]\w*", a):
        if a in ("nil", "NULL", "YES", "NO", "true", "false"):
            return None
        if a in _scalar_vars and a not in _object_vars:
            return "scalar"
        if a in _object_vars and a not in _scalar_vars:
            return "obj"
        return None
    return None


def check_fmt_types(line_no, fmt, args, api):
    """逐位置比对「占位符要什么」与「实参是什么」，只在两边都确定时才判。"""
    kinds = placeholder_kinds(fmt)
    if kinds is None or len(kinds) != len(args):
        return
    for pos, (kd, raw) in enumerate(zip(kinds, args), 1):
        if kd is None:
            continue
        ak = _arg_kind(raw)
        if ak is None or ak == kd:
            continue
        if kd == "obj" and ak == "scalar":
            add("第 %d 行 %s 的第 %d 个占位符是 %%@（要对象），但第 %d 个实参 `%s` 是数值/标量"
                " —— 会把整数当对象解引用，运行必崩"
                % (line_no, api, pos, pos, raw.strip()[:48]))
        else:
            add("第 %d 行 %s 的第 %d 个占位符是数值（%%d/%%f 之类），但第 %d 个实参 `%s` 是对象"
                " —— 会把指针当整数解释（通常是插了一行、实参没跟着改）"
                % (line_no, api, pos, pos, raw.strip()[:48]))


# 11a stringWithFormat:
for m in re.finditer(r"stringWithFormat\s*:", s):
    fmt, j = leading_literals(s, m.end())
    if fmt is None:
        continue
    # 找到这条消息的收尾 ']'（要跳过实参里嵌套的括号/方括号/字符串）
    depth_b = depth_p = depth_c = 0
    q, k, end = None, j, len(s)
    while k < len(s):
        ch = s[k]
        if q:
            if ch == "\\":
                k += 2
                continue
            if ch == q:
                q = None
            k += 1
            continue
        if ch in "\"'":
            q = ch
            k += 1
            continue
        if ch == "(":
            depth_p += 1
        elif ch == ")":
            depth_p -= 1
        elif ch == "{":
            depth_c += 1
        elif ch == "}":
            depth_c -= 1
        elif ch == "[":
            if depth_p == 0 and depth_c == 0:
                depth_b += 1
        elif ch == "]":
            if depth_p == 0 and depth_c == 0:
                if depth_b == 0:
                    end = k
                    break
                depth_b -= 1
        k += 1
    tail = s[j:end].strip()
    args = split_top(tail[1:]) if tail.startswith(",") else []
    if len(args) == 1 and not args[0].strip():
        args = []
    np = count_placeholders(fmt)
    if np != len(args):
        add("第 %d 行 stringWithFormat: 有 %d 个占位符，但传了 %d 个实参"
            % (s[:m.start()].count("\n") + 1, np, len(args)))
    else:
        # ★ v1.0.6：个数对了还要看【类型位置】对不对（规则 11c）
        check_fmt_types(s[:m.start()].count("\n") + 1, fmt, args, "stringWithFormat:")

# 11b 本工程自己的 XNRLogLine(fmt, ...)
for m in re.finditer(r"XNRLogLine\s*\(", s):
    op = m.end() - 1
    cl = match_paren(s, op)
    if cl < 0:
        continue
    inner = s[op + 1:cl]
    args = split_top(inner)
    if not args or not args[0].strip().startswith('@"'):
        continue
    fmt, _ = leading_literals(s, op + 1)
    if fmt is None:
        continue
    np = count_placeholders(fmt)
    if np != len(args) - 1:
        add("第 %d 行 XNRLogLine 的格式串有 %d 个占位符，但传了 %d 个实参"
            % (s[:m.start()].count("\n") + 1, np, len(args) - 1))
    else:
        # ★ v1.0.6：同上（规则 11c）
        check_fmt_types(s[:m.start()].count("\n") + 1, fmt, args[1:], "XNRLogLine")

# ── 12. 加锁的函数必须用 @finally 释放锁 ────────────────────────────────────
# ObjC 的 return 和异常都【不会】执行 @try 之后的普通语句 —— 只有 @finally 保证一定跑到。
# 所以写成「[lk lock]; @try { if (...) return; ... } @catch{} [lk unlock];」时，
# 一旦走到那个 return，锁就永远不释放 → 整个 App 当场死锁，而且极难定位。
# 这是加锁时最容易犯的错，所以做成硬检查。
for name in defs:
    body = func_body(code, name)
    if not body or not re.search(r"\w+\s+lock\]", body):
        continue
    if "@finally" in body:
        continue
    m_lock = re.search(r"\w+\s+lock\]", body)
    if re.search(r"\breturn\b", body[m_lock.end():]):
        add("函数 %s 里 [.. lock] 之后有 return 但没有 @finally —— 提前 return 会跳过解锁（当场死锁）"
            % name)

# ── 13. C 字符串字面量里禁止出现非 ASCII 字符 ───────────────────────────────
# 起因（★ 一个只有真机才看得见的显示 bug）：
#   v1.0.2 弹窗上那一行小标题显示成了  `— ÂåöÈ•ÉàçÊÖÑ —`（本该是「列表重载」）。
#   写法是「文件作用域 static const char *names[] = { "列表重载", ... }」+ `%s` 输出。
#
# ****根因：`%s` 在 NSString 的格式化里【不是按 UTF-8 解释】，而是按"平台默认 C 字符串编码"
#   （Apple 平台上是 MacRoman）。把 UTF-8 的中文交给 %s，必然花屏。****
#   ASCII 的 %s 一直没事（类名 / SEL / 版本号），所以只有中文暴露了这个坑。
#
# 为什么必须做成静态检查：**它编得过、自检也管不到，只有真机弹窗上才看得见** ——
# 而这正是本工程最不能出问题的地方（弹窗就是唯一的诊断通道）。
# 处理办法：**面向用户的文案一律写 @"..."；C 字符串只留给 SEL / 类名 / 版本号这类 ASCII 内容。**
# （注意 `@"..."` 不受此限：它是 ObjC 字面量，本身就是 UTF-8 的 NSString。）
#
# ★ 实现上的坑：ObjC 允许**相邻字面量自动拼接**，所以那个 37 行的弹窗模板里
#   只有第一行带 `@`，后面几行全是裸 `"..."` —— 它们仍然是 ObjC 字面量，**不能报**。
#   （第一版规则没管这个，一跑就报 42 个假阳性，全是模板的续行。）
#   判定办法：按出现顺序扫所有字面量，看它前面（跳过空白）是 `@`、还是「紧接上一个字面量」；
#   后者就继承上一个的"是不是 ObjC 字面量"属性。
_lits = [(m.start(), m.end(), m.group(0))
         for m in re.finditer(r'"(?:[^"\\\n]|\\.)*"', s)]
_prev_end, _prev_objc = -1, False
for _st, _en, _lit in _lits:
    _k = _st - 1
    while _k >= 0 and s[_k] in " \t\n\r":
        _k -= 1
    if _k >= 0 and s[_k] == "@":
        _objc = True
    elif _k + 1 == _prev_end:          # 紧接上一个字面量（中间只有空白）→ 拼接，继承属性
        _objc = _prev_objc
    else:
        _objc = False
    if not _objc and any(ord(ch) > 127 for ch in _lit):
        add("第 %d 行的 C 字符串字面量里有非 ASCII 字符（%s…）："
            "中文文案必须写成 @\"...\"，否则经 %%s 输出会花屏"
            % (s[:_st].count("\n") + 1, _lit[:20]))
    _prev_end, _prev_objc = _en, _objc

# ── 14. C 字符串字面量被当成对象用（漏写 @） ────────────────────────────────
# 起因（★ 一次"绿灯其实是漏网"的自查）：
#   v1.0.5 给弹窗加「一键复制」时，顺手写了个变异体 `[NSString stringWithFormat:"…"]`
#   去验证检查器看得见新代码 —— 结果**检查器放它过去了**。
#   而这在 ARC 下是**硬编译错误**：
#     error: implicit conversion of 'char *' to 'NSString *' is disallowed with ARC
#   （规则 13 只管"中文 C 字符串会花屏"，用的是纯 ASCII 的变异体，所以它不响。）
#
# 判据：C 字符串字面量（不带 @）紧跟在
#   · **选择器的冒号**后面（`actionWithTitle:"…"`）
#   · **函数名 + `(`** 后面（`XNRLogLine("…")`）
# 时 → 该位置要的是对象，判为漏写 @。
#
#   ★ 只查「第一个参数」的位置，第 2 个参数往后**故意不查**：
#     `[NSString stringWithFormat:@"%s", "abc"]` 这种把 C 字符串喂给 %s 的写法
#     是合法且常用的（本工程就靠它输出类名/SEL），查了必然误报。
#   ★ 白名单里的 API 本来就吃 const char *（SEL / 类名 / str* 家族），必须放行，
#     否则等于逼着人把正确代码改错（规则 13 第一版就是这么翻车的）。
_ALLOW_CHARSTAR_FN = {
    "strcmp", "strncmp", "strcasecmp", "strncasecmp", "strcpy", "strncpy",
    "strcat", "strlen", "memcmp", "memcpy", "memset", "printf", "fprintf",
    "sprintf", "snprintf", "puts", "syslog", "fopen", "open", "access",
    "objc_getClass", "objc_lookUpClass", "objc_getMetaClass", "objc_getRequiredClass",
    "sel_registerName",
}
_ALLOW_CHARSTAR_SFX = ("UTF8String", "CString")   # stringWithUTF8String: / getCString:


def _is_ternary_colon(text, colon_idx):
    """这个冒号是不是三元运算符 `? :` 的那一个（而不是选择器名后面的那一个）。

    ★ 为什么必须分开：规则 14 上线后第一跑就报了一个假阳性 ——
        `gLaunchNo, name ? name : "?", at`
      这里的 `"?"` 前面确实是个冒号，但那是**三元运算符**的冒号，不是选择器的。
      照那个报错去改代码，反而会把本来正确的写法改坏。
      （**一条新规则一跑就报假阳性 → 先怀疑规则写错了**，这是本项目第 N 次印证。）

    判据：从冒号往回扫，做括号配对；若在同一层遇到 `?` → 它就是三元的。
    """
    depth = 0
    i = colon_idx - 1
    while i >= 0:
        ch = text[i]
        if ch in ")]}":
            depth += 1
        elif ch in "([{":
            if depth == 0:
                return False          # 到了这一层的开头还没见到 ? → 不是三元
            depth -= 1
        elif ch == "?" and depth == 0:
            return True
        elif ch == ";" and depth == 0:
            return False
        i -= 1
    return False


def _cstr_takes_object(text, st):
    """判断起点为 st 的 C 字符串字面量是否落在"需要对象"的位置上。
       返回 (是否可疑, 用于报错的名字)。"""
    i = st - 1
    while i >= 0 and text[i] in " \t\n\r":
        i -= 1
    if i < 0 or text[i] not in ":(":
        return (False, "")
    if text[i] == ":" and _is_ternary_colon(text, i):
        return (False, "")            # `cond ? a : "b"` —— 这是三元，不是选择器
    j = i - 1
    while j >= 0 and text[j] in " \t\n\r":
        j -= 1
    k = j
    while k >= 0 and (text[k].isalnum() or text[k] == "_"):
        k -= 1
    name = text[k + 1:j + 1]
    if not name or any(name.endswith(sfx) for sfx in _ALLOW_CHARSTAR_SFX):
        return (False, name)
    if text[i] == ":":
        return (True, name + ":")
    if name in _ALLOW_CHARSTAR_FN:
        return (False, name)
    if name.isupper() or name.startswith("XNR_"):
        return (False, name)          # 全大写/带工程前缀的宏 —— 判不准，宁可漏报
    return (True, name + "(")


_prev_end2, _prev_objc2 = -1, False
for _st, _en, _lit in _lits:
    _k = _st - 1
    while _k >= 0 and s[_k] in " \t\n\r":
        _k -= 1
    if _k >= 0 and s[_k] == "@":
        _objc2 = True
    elif _k + 1 == _prev_end2:
        _objc2 = _prev_objc2
    else:
        _objc2 = False
    if not _objc2:
        _bad, _nm = _cstr_takes_object(s, _st)
        if _bad:
            add("第 %d 行：`%s` 的位置传了 C 字符串字面量（漏写 @）—— "
                "ARC 下这是硬编译错误（implicit conversion of 'char *' to 'NSString *'）。"
                "改成 @\"...\"；若该 API 本来就要 C 字符串，把它加进 _ALLOW_CHARSTAR_* 白名单"
                % (s[:_st].count("\n") + 1, _nm))
    _prev_end2, _prev_objc2 = _en, _objc2

# ── 16. 字符串字面量不许被意外截断（两个子判据） ───────────────────────────
# 起因（v1.0.8，本版新写的代码**自己踩的**）：
#   新加的一句日志里，中文文案中间夹了一对**半角**双引号：
#       XNRLogLine(@"=== 窄快扫整块耗时 %.0f ms"
#                  @"—— 这两半才是"我们挡住主线程"的账", ...);
#   字符串在第二个 `"` 处提前结束，于是 `我们挡住主线程` 变成了一段**裸代码**。
#   ★ clang 对这种情况的报错会指向别处（通常是后面某一行的 `%` 或某个变量名），极难反查；
#     本机没有 iOS clang，只能靠静态检查先兜住。
#
# ★★ 一开始我写的是"每行双引号数必须为偶数"——**它抓不到这个 bug**：
#    那一行有 4 个引号，是偶数（第一对闭合、第二对又重新打开）。
#    真正的特征是**中文出现在了"代码区"**（既不在字符串里、也不在注释里）。
#    这是本项目必然会出现的一类错（弹窗那 50 多个占位符的模板全是中文），所以按这个特征查。
#
# 子判据：
#   (a) 逐行双引号必须配对（`\` 转义要跳过、`//` 之后不再看）—— 抓"字符串根本没闭合"。
#       ★ 这条本身不是重点，但它是"污染源"：一个没闭合的引号会让**后面所有规则一起失灵**
#         （实测：把 `static const char *zq = "abc"def";` 插到文件开头，规则 7 报括号不平衡、
#          规则 8 报 23 个函数"真定义出现 0 次" —— 全是同一个未闭合引号的连锁反应）。
#   (b) 代码区不许出现非 ASCII 字符 —— 抓"字符串被提前截断、中文漏到代码里"。
#   ★ 豁免：`#pragma mark - <中文>` 这种行（本工程有 16 处）。**只豁免 `#pragma`**，
#     `#import` / `#define` 这些行照常检查 —— 豁免面越小，这条规则越可信。
_pragma_ok = ("#pragma",)
_line_no = 0
for _ln in s.split("\n"):
    _line_no += 1
    if _ln.lstrip().startswith(_pragma_ok):
        continue
    _in_str = False
    _j = 0
    _hit = None
    while _j < len(_ln):
        _ch = _ln[_j]
        if _in_str:
            if _ch == "\\":               # 转义：连同下一个字符一起跳过
                _j += 2
                continue
            if _ch == '"':
                _in_str = False
            _j += 1
            continue
        if _ch == '"':
            _in_str = True
        elif _ch == "/" and _j + 1 < len(_ln) and _ln[_j + 1] == "/":
            break                         # 行注释 → 后面不看了
        elif ord(_ch) > 127:
            _hit = _ch
            break
        _j += 1
    if _in_str:
        add("第 %d 行的双引号没有配对 —— 字符串字面量没有闭合。"
            "★ 这一处会让**后面所有规则一起失灵**（括号数、函数定义全乱），"
            "而 clang 的报错会指向别处，所以必须在这里先拦下。"
            "中文文案里的引号请写成全角「」或 \\\"：%s"
            % (_line_no, _ln.strip()[:70]))
    elif _hit is not None:
        add("第 %d 行的**代码区**里出现了中文字符「%s」—— 说明某个字符串字面量被半角引号"
            "提前截断了（中文漏到了字符串外面）。中文只能出现在 @\"...\" 里或 // 注释里。"
            "线索：%s" % (_line_no, _hit, _ln.strip()[:70]))

if problems:
    for p in problems:
        print("::error file=%s::%s" % (path, p))
    print("\n静态自检未通过，共 %d 个问题。" % len(problems))
    sys.exit(1)

print("静态自检通过 ✓  常量齐全 / 零 Logos·substrate / 零几何写入 / 无非法语义调用 / "
      "探针原样放行 / 无静态初始化 @\" / 括号平衡 / 函数唯一 / 先定义后调用 / LF 无 BOM / "
      "占位符数相符 / 占位符类型相符 / 加锁配 @finally / C 字符串无非 ASCII / "
      "C 字符串没被当对象用 / 字符串没被意外截断")
