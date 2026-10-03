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
    cases = []

    def mutant(label, old, new):
        if old not in base:
            print("  ! 跳过（锚点没找到，可能代码已改）：%s" % label)
            return
        cases.append((label, base.replace(old, new, 1)))

    # ★ 变异体必须是【语法上依然平衡】的，否则测的是"另一个问题"，
    #   结论也解释不通（本轮就踩过：变异体多出一个花括号，反而让规则 5 漏报）。
    def mutant_ok(label, old, new):
        if old not in base:
            print("  ! 跳过（锚点没找到，可能代码已改）：%s" % label)
            return
        t = base.replace(old, new, 1)
        for op, cl in [("{", "}"), ("(", ")"), ("[", "]")]:
            if t.count(op) != t.count(cl):
                print("  ! 变异体本身括号不平衡，测试无效，已跳过：%s" % label)
                return
        cases.append((label, t))

    mutant_ok("静态初始化器里用 @\"...\"",
              'NO,  "拦截+计数" }', 'NO,  @"拦截+计数" }')
    mutant_ok("实参个数不符",
              "XNRFmtOff(gProbeEndFirst)", "XNRFmtOff(gProbeEndFirst, 1)")
    mutant_ok("常量定义被删",
              "static const NSInteger kStatePulling = 2;", "")
    mutant_ok("出现几何写入",
              "static BOOL kProbeTrigger = YES;",
              "static BOOL kProbeTrigger = YES;\nstatic void badGeom(id v){ [v setContentOffset:CGPointZero]; }")
    mutant_ok("出现 Logos 钩子",
              "#pragma mark - 配置", "%hook Foo\n%end\n\n#pragma mark - 配置")
    # 探针不再转交原实现：把 reloadData 探针里的两行转交代码整段删掉（花括号保持平衡）
    mutant_ok("探针不再转交原实现",
              "    IMP orig = XNROrigFor(self, _cmd);\n"
              "    if (orig) ((void (*)(id, SEL))orig)(self, _cmd);\n"
              "}\n\n"
              "// ② 刷新结束",
              "}\n\n"
              "// ② 刷新结束")
    # 这一条是故意造括号不平衡，不做平衡校验
    cases.append(("括号不平衡", base + "\nstatic void broken(void) {\n"))

    ok = True
    tmpdir = tempfile.mkdtemp(prefix="xhscheck_")

    # 先确认「原样代码」是能过的，否则后面的判定没意义
    p0 = subprocess.run([sys.executable, os.path.abspath(__file__),
                         os.path.abspath(DEFAULT)], capture_output=True)
    if p0.returncode != 0:
        print("  ✗ 原始文件本身就没通过自检 —— 先修好它再谈反向测试")
        print(p0.stdout.decode("utf-8", "replace"))
        return False

    for label, text in cases:
        fp = os.path.join(tmpdir, "case.x")
        open(fp, "w", encoding="utf-8", newline="\n").write(text)
        r = subprocess.run([sys.executable, os.path.abspath(__file__), fp],
                           capture_output=True)
        caught = (r.returncode == 1)
        ok = ok and caught
        msg = r.stdout.decode("utf-8", "replace").strip().split("\n")[0] if caught else ""
        print("  %s %s%s" % ("✓" if caught else "✗ 没抓到！", label,
                             ("  → " + msg) if msg else ""))

    print("\n反向测试：%s" % ("全部通过 ✓ 这个检查器是有效的" if ok else "有漏网之鱼 ✗ 检查器不可靠"))
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
for m in re.finditer(r"^static\s+[^;\n=]*=\s*\{.*?\n\};", code, re.M | re.S):
    if '@"' in m.group(0):
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
for fn in ["XNRPresentStats", "XNRStatsRetry", "XNRInstallGates", "XNRInstallWhenReady",
           "XNRFmtOff", "XNRProbeNote", "XNRPageOfAny", "XNRIsRefreshControl",
           "XNRRecordEventKind", "XNRAllEvents", "XNRRecordEvent"]:
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
if problems:
    for p in problems:
        print("::error file=%s::%s" % (path, p))
    print("\n静态自检未通过，共 %d 个问题。" % len(problems))
    sys.exit(1)

print("静态自检通过 ✓  常量齐全 / 零 Logos·substrate / 零几何写入 / 无非法语义调用 / "
      "探针原样放行 / 无静态初始化 @\" / 括号平衡 / 函数唯一 / 先定义后调用 / LF 无 BOM")
