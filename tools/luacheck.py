#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
luacheck.py -- Lua 静态检查（AI 无法执行 Lua，这是替代方案）

为什么需要它
------------
2026-09-26 发生过一次真实的游戏崩溃事故：

    一次"去重"编辑误删了 `playerPawn` 函数定义，
    但调用处还在 → "attempt to call a nil value (global 'playerPawn')"
    → Lua 错误 → 游戏崩溃（EXCEPTION_ACCESS_VIOLATION）

当时的检查只做了"括号配平"和"手写的关键函数存在性列表"，
**都发现不了这个问题**。

后来（PWProjection 阶段）又差点踩两个新坑：

    1) 在双引号字符串里嵌了双引号:
           return true, "可用（游戏自带的"可放置"材质）"
       这在 Lua 里会被切开成多个 token，属于**词法错误**。
       全局引号数量是偶数，所以"引号配平"也发现不了。

    2) 少写一个 `end`。
       只有真正的词法 + 块结构检查才能发现。

所以本工具做一个真正的 Lua 词法分析器 + 块结构平衡检查：

  1. 词法: 逐字符扫描，正确处理注释/长注释/长字符串/短字符串/数字/标识符
     - 短字符串跨行 -> 报错（Lua 不允许）
     - 代码区出现非 ASCII 字符 -> 报错（这是上面 1) 的典型症状）
     - 代码区出现无法识别的字符 -> 报错
  2. 块结构: 统计 function/if/for/while/do/repeat 与 end/until 的配对
     （for ... do / while ... do 的 do 不重复计数）
  3. 未定义的被调用标识符（PWRecon 那次崩溃的直接原因）
  4. 重名函数定义、括号配平
  5. 已知易错点: pcall(StaticFindObject, ...)、print() 里的中文、`unpack(`

用法
----
    python luacheck.py <file.lua> [more.lua ...]
    python luacheck.py <dir>              # 目录下所有 .lua
    python luacheck.py <file.lua> --verbose

退出码：0 = 无严重问题；1 = 有严重问题
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from collections import Counter

# ---------------------------------------------------------------------------
# Lua 5.4 词法表
# ---------------------------------------------------------------------------

LUA_KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return",
    "then", "true", "until", "while",
}

LUA_BASE_GLOBALS = {
    "_G", "_VERSION", "assert", "collectgarbage", "dofile", "error", "getmetatable",
    "ipairs", "load", "loadfile", "next", "pairs", "pcall", "print", "rawequal",
    "rawget", "rawlen", "rawset", "require", "select", "setmetatable", "tonumber",
    "tostring", "type", "xpcall", "unpack", "module", "loadstring", "arg",
    "string", "table", "math", "io", "os", "coroutine", "utf8", "debug",
    "bit32", "_ENV",
}

# UE4SS / Palworld mod 里用到的已知全局（调用它们不算未定义）
UE4SS_GLOBALS = {
    # 反射与查询
    "FindAllOf", "FindFirstOf", "StaticFindObject", "FindObject",
    "LoadAsset", "StaticConstructObject", "CreateInvalidObject",
    "FName", "NAME_None", "EFindName", "UnrealVersion", "ModRef", "TypedValue",
    # 文本/结构体构造（★ FText 有实机证据: Mods\FirstPerson 里
    # `TextBlock:SetText(FText("第一人称"))`，中文能进去能显示）
    "FText",
    # 钩子
    "RegisterHook", "UnregisterHook",
    "RegisterKeyBind", "RegisterKeyBindAsync", "IsKeyBindRegistered",
    "UnregisterKeyBind", "RegisterKey",
    "RegisterConsoleCommandHandler", "RegisterConsoleCommandGlobalHandler",
    "RegisterLoadMapPreHook", "RegisterLoadMapPostHook",
    "RegisterInitGameStatePreHook", "RegisterInitGameStatePostHook",
    "RegisterBeginPlayPreHook", "RegisterBeginPlayPostHook",
    "RegisterEndPlayPreHook", "RegisterEndPlayPostHook",
    "RegisterEngineTickPreHook", "RegisterEngineTickPostHook",
    "RegisterProcessConsoleExecPreHook", "RegisterProcessConsoleExecPostHook",
    "RegisterULocalPlayerExecPreHook", "RegisterULocalPlayerExecPostHook",
    "RegisterCallFunctionByNameWithArgumentsPreHook",
    "RegisterCallFunctionByNameWithArgumentsPostHook",
    "RegisterConsoleCommandHandlerGlobalHandler",
    "NotifyOnNewObject", "RegisterCustomEvent",
    # 线程调度
    "ExecuteInGameThread", "ExecuteInGameThreadWithDelay",
    "ExecuteWithDelay", "ExecuteAsync",
    # 枚举
    "Key", "ModifierKey",
    # 调试 / 转储
    "DumpAllObjects", "DumpStaticMeshes", "DumpAllActors", "DumpUSMAP", "DumpJMAP",
    "GenerateSDK", "GenerateUHTCompatibleHeaders", "IterateGameDirectories",
    # 工具
    "UE4SS", "jsb", "Profiler",
}

ALL_KNOWN_GLOBALS = LUA_BASE_GLOBALS | UE4SS_GLOBALS

# ★ 禁用名单：实测会把游戏打崩的 UE4SS 反射枚举接口（见 check_banned_reflection）
#   2026-09-27: ForEachFunction / ForEachProperty 直接崩游戏（崩溃栈全在 UE4SS）。
#   安全替代: FindAllOf("精确类名")。
BANNED_REFLECTION = ["ForEachProperty", "ForEachFunction", "ForEachUObject"]

PUNCT_CHARS = set("+-*/%^#<>=&|~(){}[];:,.")


# ---------------------------------------------------------------------------
# 1. 词法分析器
# ---------------------------------------------------------------------------

class LexError:
    __slots__ = ("line", "msg")

    def __init__(self, line, msg):
        self.line = line
        self.msg = msg


NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
NUMBER_RE = re.compile(
    r"0[xX][0-9a-fA-F]+"
    r"|\d+\.\d*(?:[eE][-+]?\d+)?"
    r"|\.\d+(?:[eE][-+]?\d+)?"
    r"|\d+(?:[eE][-+]?\d+)?"
)
LONG_OPEN_RE = re.compile(r"\[(=*)\[")


def tokenize(src: str):
    """返回 (tokens, errors)。
    token = (kind, text, line)，kind ∈ {name, keyword, number, string, punct}
    """
    tokens = []
    errors = []
    i, n = 0, len(src)
    line = 1

    while i < n:
        c = src[i]

        if c == "\n":
            line += 1
            i += 1
            continue
        if c in " \t\r\f\v":
            i += 1
            continue

        # ---- 注释 ----
        if src.startswith("--", i):
            m = LONG_OPEN_RE.match(src, i + 2)
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, m.end())
                if j < 0:
                    errors.append(LexError(line, "长注释 [[ 未闭合"))
                    return tokens, errors
                line += src.count("\n", i, j + len(close))
                i = j + len(close)
            else:
                j = src.find("\n", i)
                i = n if j < 0 else j
            continue

        # ---- 长字符串 ----
        m = LONG_OPEN_RE.match(src, i)
        if m:
            close = "]" + m.group(1) + "]"
            j = src.find(close, m.end())
            if j < 0:
                errors.append(LexError(line, "长字符串 [[ 未闭合"))
                return tokens, errors
            line += src.count("\n", i, j + len(close))
            tokens.append(("string", "<long>", line))
            i = j + len(close)
            continue

        # ---- 短字符串 ----
        if c == '"' or c == "'":
            quote = c
            start_line = line
            j = i + 1
            closed = False
            while j < n:
                ch = src[j]
                if ch == "\\":
                    if j + 1 < n and src[j + 1] == "\n":
                        line += 1
                    j += 2
                    continue
                if ch == "\n":
                    break
                if ch == quote:
                    closed = True
                    break
                j += 1
            if not closed:
                errors.append(LexError(
                    start_line,
                    "短字符串这一行没有闭合（Lua 的 \"...\" 不能跨行）——"
                    " 常见原因: 字符串里又写了双引号"))
                # 跳到行尾继续，尽量多报几个错
                k = src.find("\n", i)
                i = n if k < 0 else k
                continue
            tokens.append(("string", src[i:j + 1], start_line))
            i = j + 1
            continue

        # ---- 数字 ----
        if c.isdigit() or (c == "." and i + 1 < n and src[i + 1].isdigit()):
            m = NUMBER_RE.match(src, i)
            if m and m.group(0):
                tokens.append(("number", m.group(0), line))
                i = m.end()
                continue

        # ---- 标识符 / 关键字 ----
        m = NAME_RE.match(src, i)
        if m:
            w = m.group(0)
            tokens.append(("keyword" if w in LUA_KEYWORDS else "name", w, line))
            i = m.end()
            continue

        # ---- 运算符 / 标点 ----
        if src.startswith("...", i):
            tokens.append(("punct", "...", line))
            i += 3
            continue
        if src.startswith("..", i):
            tokens.append(("punct", "..", line))
            i += 2
            continue
        if c in PUNCT_CHARS:
            tokens.append(("punct", c, line))
            i += 1
            continue

        # ---- 其它：非法字符 ----
        if ord(c) > 127:
            errors.append(LexError(
                line,
                "代码区出现非 ASCII 字符 {!r} (U+{:04X}) —— "
                "通常是字符串提前被引号截断，导致中文落到了代码区".format(
                    c, ord(c))))
        else:
            errors.append(LexError(
                line, "无法识别的字符 {!r} (U+{:04X})".format(c, ord(c))))
        i += 1

    return tokens, errors


# ---------------------------------------------------------------------------
# 2. 块结构平衡
# ---------------------------------------------------------------------------

def check_block_balance(tokens):
    """返回 (problems, depth_at_end)

    计数规则:
      function / if            -> +1
      for / while              -> +1，并标记"待配对的 do"
      do                       -> 有待配对 do 就消费掉，否则 +1（独立 do 块）
      repeat                   -> +1（由 until 收）
      end                      -> -1
      until                    -> -1
    """
    problems = []
    depth = 0
    pending_do = 0

    for kind, text, line in tokens:
        if kind != "keyword":
            continue
        if text in ("function", "if"):
            depth += 1
        elif text in ("for", "while"):
            depth += 1
            pending_do += 1
        elif text == "do":
            if pending_do > 0:
                pending_do -= 1
            else:
                depth += 1
        elif text == "repeat":
            depth += 1
        elif text == "end":
            depth -= 1
            if depth < 0:
                problems.append((line, "多余的 end（此处没有任何块在打开）"))
                depth = 0
        elif text == "until":
            depth -= 1
            if depth < 0:
                problems.append((line, "多余的 until"))
                depth = 0

    return problems, depth


# ---------------------------------------------------------------------------
# 3. 剥离注释与字符串（给"调用点扫描"用）
# ---------------------------------------------------------------------------

def strip_comments_and_strings(src: str) -> str:
    out = []
    i, n = 0, len(src)
    st = "code"
    while i < n:
        c = src[i]
        if st == "code":
            if c == "-" and i + 1 < n and src[i + 1] == "-":
                m = LONG_OPEN_RE.match(src, i + 2)
                if m:
                    close = "]" + m.group(1) + "]"
                    j = src.find(close, m.end())
                    if j < 0:
                        break
                    out.append("\n" * src.count("\n", i, j + len(close)))
                    i = j + len(close)
                    continue
                st = "cm"
                i += 2
                continue
            if c == '"':
                st = "ds"; out.append(" "); i += 1; continue
            if c == "'":
                st = "ss"; out.append(" "); i += 1; continue
            m = LONG_OPEN_RE.match(src, i)
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, m.end())
                if j < 0:
                    break
                out.append(" ")
                out.append("\n" * src.count("\n", i, j + len(close)))
                i = j + len(close)
                continue
            out.append(c); i += 1; continue
        elif st == "cm":
            if c == "\n":
                st = "code"; out.append(c)
            i += 1
            continue
        elif st == "ds":
            if c == "\\":
                i += 2; continue
            if c == '"':
                st = "code"; out.append(" ")
            elif c == "\n":
                st = "code"; out.append(c)
            i += 1
            continue
        elif st == "ss":
            if c == "\\":
                i += 2; continue
            if c == "'":
                st = "code"; out.append(" ")
            elif c == "\n":
                st = "code"; out.append(c)
            i += 1
            continue
    return "".join(out)


# ---------------------------------------------------------------------------
# 4. 定义 / 调用收集
# ---------------------------------------------------------------------------

def collect_definitions(clean: str) -> dict:
    defs = {}

    def add(name, kind, line):
        defs.setdefault(name, []).append((kind, line))

    for m in re.finditer(r"^\s*(local\s+)?function\s+([\w.:]+)", clean, re.M):
        full = m.group(2)
        kind = "localfunc" if m.group(1) else "globalfunc"
        line = clean.count("\n", 0, m.start()) + 1
        # 用【完整名】记函数，避免把 Util.foo / Util.bar 误判成"Util 定义多次"
        add(full, kind, line)
        base = full.split(":")[0].split(".")[0]
        if base != full:
            # 模块表本身也算"已定义"，但不算函数重名
            add(base, "modulebase", line)

    # 函数参数（含匿名函数）也算"已定义"，否则 f(x) 里的 x 会被误报成全局
    for m in re.finditer(r"\bfunction\b\s*[\w.:]*\s*\(([^)]*)\)", clean):
        for part in m.group(1).split(","):
            nm = part.strip()
            if re.fullmatch(r"[A-Za-z_]\w*", nm or ""):
                add(nm, "param", clean.count("\n", 0, m.start()) + 1)

    for m in re.finditer(r"^\s*local\s+([\w\s,]+?)\s*(=|$)", clean, re.M):
        for part in m.group(1).split(","):
            nm = part.strip()
            if re.fullmatch(r"[A-Za-z_]\w*", nm or ""):
                add(nm, "localvar", clean.count("\n", 0, m.start()) + 1)

    for m in re.finditer(r"^\s*([A-Za-z_]\w*)\s*=", clean, re.M):
        name = m.group(1)
        if name in LUA_KEYWORDS:
            continue
        add(name, "globalvar", clean.count("\n", 0, m.start()) + 1)

    return defs


def collect_calls(clean: str) -> dict:
    calls = {}
    for m in re.finditer(r"(?<![\w.:])([A-Za-z_]\w*)\s*[\(\{]", clean):
        name = m.group(1)
        if name in LUA_KEYWORDS:
            continue
        calls.setdefault(name, []).append(clean.count("\n", 0, m.start()) + 1)

    for m in re.finditer(r"(?<![\w.:])([A-Za-z_]\w*)\s+(?=[\"'])", clean):
        name = m.group(1)
        if name in LUA_KEYWORDS:
            continue
        calls.setdefault(name, []).append(clean.count("\n", 0, m.start()) + 1)
    return calls


def check_use_before_local(src: str) -> list:
    """Lua 的 local 只对【声明之后】的代码可见。

    在声明之前使用同一个名字，它会被解析成【全局变量】= nil，
    运行时才炸 "attempt to index a nil value (global 'X')"。

    ★ 2026-09-26 22:14 真实踩过这个坑：
      pwpr_meshmap.lua 里 `type_keywords` 用了写在它【后面】的
      `local SYNONYMS`。词法、块平衡、未定义调用、跨模块接口
      —— 全部检查都通过了，一进游戏按 K 就报错。

    判定方式:
      收集【所有】会引入局部名字的地方 —— local 赋值、local function、
      函数参数、for 循环变量。然后：
        某一行用到了名字 N，只要存在一个 N 的局部声明在【这一行或之前】，
        就认为合法；否则 N 在这一行是全局变量 —— 报出来。

    为什么不用缩进判断作用域:
      试过，误报 61 处（函数参数和 for 变量没被当成声明）。
      把参数/for 变量补上、并且不比较缩进之后，两个真实场景都正确、
      误报为 0。**宁可漏报也不要误报** —— 误报会让人开始忽略检查工具。

    已知局限: 如果同名局部变量在内层作用域先出现，
      外层在后面对它的"提前使用"会被漏掉。这个取舍是有意的。
    """
    clean = strip_comments_and_strings(src)
    lines = clean.split("\n")

    decl_lines = {}      # name -> set(行号)

    def declare(names, line_no):
        for nm in names:
            nm = nm.strip()
            if nm and re.fullmatch(r"[A-Za-z_]\w*", nm):
                decl_lines.setdefault(nm, set()).add(line_no)

    for i, line in enumerate(lines, 1):
        m = re.match(r"\s*local\s+function\s+([A-Za-z_]\w*)", line)
        if m:
            declare([m.group(1)], i)
        else:
            m = re.match(
                r"\s*local\s+([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*(?:=|$)",
                line)
            if m:
                declare(m.group(1).split(","), i)

    # 函数参数（含匿名函数）
    for m in re.finditer(r"\bfunction\b[^\n(]*\(([^)]*)\)", clean):
        line_no = clean.count("\n", 0, m.start()) + 1
        declare(m.group(1).split(","), line_no)

    # for 循环变量:  for k, v in pairs(t)   /   for i = 1, n do
    # 注意 `=` 后面要接的是空格/数字，不是单词字符，所以不能写成 `(?:=|in)\b`
    # （`\b` 在 `= ` 之间不成立，会整个匹配失败）。用 `\bin\b` 分开处理。
    for m in re.finditer(
            r"\bfor\s+([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*(?:=|\bin\b)",
            clean):
        line_no = clean.count("\n", 0, m.start()) + 1
        declare(m.group(1).split(","), line_no)

    problems = []
    for name, dlines in decl_lines.items():
        pat = re.compile(r"(?<![\w.])" + re.escape(name) + r"\b")
        for i, line in enumerate(lines, 1):
            if i in dlines:              # 声明行自己不算使用
                continue
            used = False
            for m in pat.finditer(line):
                rest = line[m.end():].lstrip()
                # `name = ...` 是【表构造的键】或【赋值目标】，不是"使用"。
                # 例: local bp = { meta = {...}, size = {...} } 里的 meta/size。
                # 不排除这些会误报一大堆。
                if rest.startswith("=") and not rest.startswith("=="):
                    continue
                used = True
                break
            if not used:
                continue
            if not any(l <= i for l in dlines):
                problems.append((name, min(dlines), i))
                break
    return problems


# ---------------------------------------------------------------------------
# 5. 单文件检查
# ---------------------------------------------------------------------------

def check_file(path: str, verbose: bool = False) -> int:
    if not os.path.isfile(path):
        print("[X] 找不到文件: {}".format(path))
        return 1

    src = open(path, "r", encoding="utf-8-sig", errors="replace").read()
    print("=" * 74)
    print("Lua 静态检查: {}".format(os.path.basename(path)))
    print("=" * 74)
    print("  行数: {}".format(src.count("\n") + 1))

    problems = 0

    # ---- 1. 词法 ---------------------------------------------------------
    tokens, lex_errors = tokenize(src)
    print()
    print("  [1] 词法分析: {} 个 token".format(len(tokens)))
    if lex_errors:
        print("  [严重] 词法错误 {} 处:".format(len(lex_errors)))
        for e in lex_errors[:20]:
            print("      行 {:>5}  {}".format(e.line, e.msg))
        if len(lex_errors) > 20:
            print("      ... 还有 {} 处".format(len(lex_errors) - 20))
        problems += len(lex_errors)
    else:
        print("      [通过] 没有词法错误")

    # ---- 2. 块结构 -------------------------------------------------------
    print()
    bal_problems, depth = check_block_balance(tokens)
    print("  [2] 块结构平衡: 结束时深度 = {}".format(depth))
    if bal_problems or depth != 0:
        if depth > 0:
            print("  [严重] 有 {} 个块没有闭合 —— 大概率是少写了 end".format(depth))
            problems += depth
        elif depth < 0:
            print("  [严重] end/until 比开块多 {}".format(-depth))
            problems += -depth
        for line, msg in bal_problems[:20]:
            print("      行 {:>5}  {}".format(line, msg))
        if bal_problems:
            problems += len(bal_problems)
    else:
        print("      [通过] 所有块都配对")

    # ---- 3. 括号配平（粗查，词法已过的话基本不会再有问题）-------------
    clean = strip_comments_and_strings(src)
    print()
    for a, b, nm in (("(", ")", "()"), ("{", "}", "{}"), ("[", "]", "[]")):
        ca, cb = clean.count(a), clean.count(b)
        if ca != cb:
            print("  [严重] {} 不平衡: {}/{}".format(nm, ca, cb))
            problems += 1
    if "(" in clean:
        print("  [3] 括号配平: 检查完成")

    # ---- 4. 定义收集 -----------------------------------------------------
    defs = collect_definitions(clean)
    n_local = sum(1 for v in defs.values() if any(k == "localfunc" for k, _ in v))
    n_global = sum(1 for v in defs.values() if any(k == "globalfunc" for k, _ in v))
    print()
    print("  [4] 定义: {} 个名字（局部函数 {} / 全局函数 {}）".format(
        len(defs), n_local, n_global))

    # ---- 5. 未定义引用（关键检查）---------------------------------------
    calls = collect_calls(clean)
    undef = {}
    for name, lines in calls.items():
        if name in ALL_KNOWN_GLOBALS or name in defs:
            continue
        undef[name] = lines

    print()
    if undef:
        print("  [严重] 未定义的被调用标识符 {} 个:".format(len(undef)))
        for name, lines in sorted(undef.items(), key=lambda kv: kv[1][0]):
            print("      {:<30} 行 {}{}".format(
                name, lines[:6], " ..." if len(lines) > 6 else ""))
        print()
        print("      ==> 这些会在运行时抛 'attempt to call a nil value (global X)'")
        print("          并可能导致【游戏崩溃】。必须补定义或改调用。")
        problems += len(undef)
    else:
        print("  [5] [通过] 没有未定义的被调用标识符")

    # ---- 6. 重名函数 -----------------------------------------------------
    dups = {k: v for k, v in defs.items()
            if len([1 for kind, _ in v if kind in ("localfunc", "globalfunc")]) > 1}
    print()
    if dups:
        print("  [警告] 同名函数定义多次（{} 个）—— 后定义的会遮蔽前面的:".format(len(dups)))
        for k, v in dups.items():
            print("      {:<30} {}".format(k, [ln for _, ln in v]))
    else:
        print("  [6] [通过] 没有重名函数定义")

    # ---- 7. 已知易错点 ---------------------------------------------------
    print()
    risky = re.findall(r"pcall\s*\(\s*(StaticFindObject)\s*,", clean)
    if risky:
        print("  [严重] 发现 {} 处 pcall(StaticFindObject, 参数) 写法".format(len(risky)))
        print("         实测这种写法触发过原生层崩溃（EXCEPTION_ACCESS_VIOLATION）")
        print('         必须改成: pcall(function() return StaticFindObject("路径") end)')
        problems += len(risky)
    else:
        print("  [7] [通过] 没有 pcall(StaticFindObject, 参数) 的危险写法")

    # 其它"把 UE4SS 原生函数直接交给 pcall"的写法：实测只有 StaticFindObject
    # 会崩，所以这里只提示不改判 —— 目的是让 review 时能看见。
    direct_native = sorted(set(re.findall(
        r"pcall\s*\(\s*([A-Z][A-Za-z0-9_]*)\s*,", clean)) - {"StaticFindObject"})
    if direct_native:
        print("  [提示] 这些 UE4SS 原生函数被直接传给 pcall（本项目中已验证可用，"
              "但换成闭包形式更稳）: {}".format(", ".join(direct_native)))

    bad_print = []
    for i, line in enumerate(src.split("\n"), 1):
        s = line.strip()
        if s.startswith("print(") and re.search(r"[\u4e00-\u9fff]", line):
            bad_print.append(i)
    if bad_print:
        print("  [警告] print() 里有中文（控制台会乱码）: 行 {}".format(bad_print[:8]))

    bare_unpack = [i for i, line in enumerate(src.split("\n"), 1)
                   if re.search(r"(?<![\w.])unpack\s*\(", line)]
    if bare_unpack:
        print("  [严重] 用了裸 unpack( —— Lua 5.4 里它不存在，要用 table.unpack: 行 {}"
              .format(bare_unpack[:8]))
        problems += len(bare_unpack)

    # ---- 8. local 声明顺序 -------------------------------------------------
    print()
    ub = check_use_before_local(src)
    if ub:
        print("  [严重] {} 处在 local 声明【之前】就使用了它:".format(len(ub)))
        for name, dline, uline in ub:
            print("      {:<24} 第 {} 行使用，但第 {} 行才 local 声明".format(
                name, uline, dline))
        print()
        print("      ==> 声明之前的引用会解析成【全局变量】= nil，")
        print("          运行时报 'attempt to index a nil value (global X)'。")
        print("          修法: 把这个 local 的声明挪到第一次使用之前。")
        problems += len(ub)
    else:
        print("  [8] [通过] 没有 local 声明顺序问题")

    # ---- 9. Lua 模式里的 %w 不匹配下划线 -----------------------------------
    print()
    pw = check_percent_w_underscore(src)
    if pw:
        print("  [严重] {} 处 Lua 模式用了 [%w] 又紧接 '_':".format(len(pw)))
        for line, frag in pw:
            print("      第 {} 行: {}".format(line, frag))
        print()
        print("      ==> Lua 的 %w = [A-Za-z0-9]，【不包含下划线】。")
        print("          所以 ( [%w]+ )_C 这种模式永远跨不过下划线，")
        print("          只能匹配没有下划线的名字，带下划线的会【静默漏掉】。")
        print("          修法: 把字符类写成 [%w_] 。")
        problems += len(pw)
    else:
        print("  [9] [通过] 没有 %w 紧接下划线的模式")

    # ---- 10. 保留字当字段名/方法名（语法错误）------------------------------
    print()
    kw = check_keyword_as_field(clean)
    if kw:
        print("  [严重] {} 处把 Lua 保留字当字段名/方法名:".format(len(kw)))
        for line, frag in kw:
            print("      第 {} 行: {}".format(line, frag))
        print()
        print("      ==> `t.repeat` / `t.end` / `obj:for(...)` 都是【语法错误】——")
        print("          不是运行到那行才错，而是整个文件都加载不了，")
        print("          症状是 mod 一行日志都不打、直接 init failed。")
        print("          修法: 换个名字（repeat -> resend / resend_last ...）。")
        problems += len(kw)
    else:
        print("  [10] [通过] 没有拿保留字当字段名/方法名")

    # ---- 11. 禁用的反射枚举接口（实测崩游戏）------------------------------
    print()
    rb = check_banned_reflection(clean)
    if rb:
        print("  [严重] {} 处用了【禁用的反射枚举】接口:".format(len(rb)))
        for line, frag in rb:
            print("      第 {} 行: {}".format(line, frag))
        print()
        print("      ==> ForEachProperty / ForEachFunction / ForEachUObject")
        print("          在本构建里【实测会把游戏打崩】（2026-09-27 16:19，")
        print("          崩溃栈 80 帧全在 UE4SS 里；踩坑记录 3c-3 / 3f-2 早有记录）。")
        print("          注意: 「UE4SS.dll 里能扫到这些字符串」不等于「Lua 能安全调用」。")
        print("          安全替代: FindAllOf(\"精确类名\") ／ obj.方法名 存在性查询。")
        problems += len(rb)
    else:
        print("  [11] [通过] 没有用禁用的反射枚举接口")

    if verbose:
        print()
        print("  ---- 全部定义 ----")
        for k, v in sorted(defs.items()):
            print("      {:<30} {}".format(k, v))

    print()
    print("=" * 74)
    if problems:
        print("结果: 发现 {} 处问题 —— 请修复后再部署！".format(problems))
    else:
        print("结果: 无严重问题")
    print("=" * 74)
    return 1 if problems else 0


def check_percent_w_underscore(src: str) -> list:
    """Lua 的 %w = [A-Za-z0-9]，【不包含下划线】。

    所以 `([%w]+)_C` 这种写法永远跨不过下划线 —— 它只能匹配没有下划线的
    名字，带下划线的会【静默漏掉】，不报错。

    ★ 这个 bug 真实发生过（2026-09-26）:
      从网格组件全名里解析宿主建筑类型名的模式
          BP_BuildObject_([%w]+)_C
      把 WeaponFactory_Dirty_4 / SphereFactory_Black_04 / Factory_Hard_4 /
      TableDresser01_Stone 这些带下划线的类型全漏了，
      而且表现得像"这些建筑根本没有网格组件" —— 差点让我得出错误结论。

    返回 [(行号, 片段)]
    """
    hits = []
    pat = re.compile(r"\[%w\]\s*[+\-*?]?\s*\)*\s*_")
    for i, line in enumerate(src.splitlines(), 1):
        if line.strip().startswith("--"):
            continue      # 注释里提到这个坑是正常的
        for m in pat.finditer(line):
            hits.append((i, m.group(0)))
    return hits


def check_keyword_as_field(src: str) -> list:
    """Lua 的 `t.xxx` / `t:xxx` 里 xxx 必须是【标识符】，保留字不行。

    所以 `function Notify.repeat()`、`x.end`、`obj:for(...)` 都是
    **语法错误** —— 不是"运行到那行才错"，而是**整个文件都加载不了**。

    ★ 这个 bug 真实发生过（2026-09-27）:
      pwpr_notify.lua 里写了 `function Notify.resend()` 之前的一版叫
      `Notify.repeat`。因为 repeat 是块起始关键字，
      静态检查器先报的是"块结构平衡: 结束时深度 = 1"（看着像少写 end），
      追下去才发现是【保留字当函数名】。
      当时的症状本该是"整个 mod 一行日志都不打、直接 init failed"。

    返回 [(行号, 片段)]
    """
    hits = []
    # 允许行尾/字符串里出现保留字；只查 [.:] 紧跟保留字且【后面不是标识符字符】
    pat = re.compile(
        r"[.:]\s*(" + "|".join(sorted(LUA_KEYWORDS)) + r")(?![\w])")
    for i, line in enumerate(src.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("--"):
            continue      # 注释里提到这个坑是正常的
        for m in pat.finditer(line):
            hits.append((i, m.group(0)))
    return hits


def check_banned_reflection(src: str) -> list:
    """禁用 UE4SS 的"反射枚举"接口 —— 实测会把游戏打崩。

    ★ 这个坑真实发生过（2026-09-27 16:19）:
      S9 屏幕提示探测的第 2 步用 `ForEachFunction` + `ForEachProperty`
      去枚举 PlayerController 的函数和参数签名，**直接崩游戏**，
      崩溃栈 80 帧全在 UE4SS 里（反射/属性遍历那套机器）。

    更糟的是：本项目的 `docs/踩坑记录.md` 早就记过两次
    （3c-3「属性枚举仍然失败」/ 3f-2「ForEachProperty 确认不可用」），
    只是当时没做成检查项，所以又被踩了一次。

    ★ 为什么会误判为"可用": 扫 UE4SS.dll 能扫到这些字符串，
      但**"反射信息存在" ≠ "Lua 能安全调用"** ——
      PrintString 也是这个模式（函数体被 Shipping 编译掉，反射还在）。

    正确的枚举方式（本项目用了几个月、安全的）:
      FindAllOf("精确类名")   ／   obj.方法名 存在性查询

    返回 [(行号, 片段)]
    """
    hits = []
    banned = "|".join(BANNED_REFLECTION)
    pat = re.compile(r"[.:]\s*(" + banned + r")\s*\(")
    for i, line in enumerate(src.splitlines(), 1):
        for m in pat.finditer(line):
            hits.append((i, m.group(0)))
    return hits


def check_cross_module(dirpath: str, files) -> list:
    """跨模块接口检查：Mod.func(...) 调用的函数在定义模块里真的存在吗？

    单文件检查抓不到这个 —— 每个文件自己都是合法的，只有连起来才错。
    典型事故：ghost.lua 调 MeshMap.resolv(...)（少个 e），
    单文件检查全绿，运行到那一步才 nil 报错。

    两个坑（都踩过）：
      1. require 的路径是【字符串】，而 strip_comments_and_strings 会把
         字符串内容清空 —— 所以 require 必须从【原文】里找，
         不能从清洗后的文本里找（否则整个检查静默失效）。
      2. 模块里的函数挂在【局部表名】上（pwpr_util.lua 里是 `Util.xxx`），
         不是文件名。所以要先统计出该文件最常用的 `function X.` 前缀。

    只检查【形如 Alias.member( 的调用】，不碰字段访问
    （MeshMap.entries 这类字段不该被当成函数查）。
    """
    mod_table, mod_defs = {}, {}
    for f in files:
        mod = os.path.splitext(os.path.basename(f))[0]
        src = open(f, "r", encoding="utf-8-sig", errors="replace").read()
        clean = strip_comments_and_strings(src)

        counter = Counter(
            m.group(1) for m in re.finditer(r"function\s+(\w+)\.(\w+)", clean))
        if not counter:
            mod_table[mod] = None
            mod_defs[mod] = set()
            continue
        table = counter.most_common(1)[0][0]
        mod_table[mod] = table
        names = set()
        for m in re.finditer(
                r"function\s+" + re.escape(table) + r"\.(\w+)", clean):
            names.add(m.group(1))
        for m in re.finditer(
                re.escape(table) + r"\.(\w+)\s*=(?!=)\s*function", clean):
            names.add(m.group(1))
        mod_defs[mod] = names

    problems = []
    checked = 0
    for f in files:
        src = open(f, "r", encoding="utf-8-sig", errors="replace").read()
        clean = strip_comments_and_strings(src)

        # alias -> module（必须用原文，因为路径是字符串）
        aliases = {}
        for m in re.finditer(
                r'local\s+(\w+)\s*=\s*require\(\s*"([\w./]+)"\s*\)', src):
            alias, target = m.group(1), m.group(2).split("/")[-1]
            if target in mod_defs and mod_table.get(target) is not None:
                aliases[alias] = target

        for alias, mod in aliases.items():
            pat = r"(?<![\w.])" + re.escape(alias) + r"\.(\w+)\s*\("
            for m in re.finditer(pat, clean):
                member = m.group(1)
                checked += 1
                if member not in mod_defs[mod]:
                    line = clean.count("\n", 0, m.start()) + 1
                    problems.append(
                        (os.path.basename(f), line, alias, member, mod))

        # 内联写法：require("pwpr_x").get(...)
        for m in re.finditer(
                r'require\(\s*"([\w./]+)"\s*\)\.(\w+)\s*\(', src):
            target, member = m.group(1).split("/")[-1], m.group(2)
            checked += 1
            if target in mod_defs and member not in mod_defs[target]:
                line = src.count("\n", 0, m.start()) + 1
                problems.append((os.path.basename(f), line,
                                 "require(" + target + ")", member, target))

    # 第二个返回值是"实际校验了多少次调用" —— 必须一起打印出来。
    # 否则一旦检查逻辑因为某种原因静默失效（比如从清洗后的文本里找 require），
    # 它会照样输出"通过"，而人不会发现它其实一个都没查。
    return problems, checked


def check(path: str, verbose: bool = False) -> int:
    if os.path.isdir(path):
        files = sorted(
            os.path.join(path, f) for f in os.listdir(path) if f.endswith(".lua")
        )
        if not files:
            print("[X] 目录里没有 .lua: {}".format(path))
            return 1
        bad = 0
        for f in files:
            if check_file(f, verbose):
                bad += 1

        print()
        print("#" * 74)
        print("# 跨模块接口检查（Mod.func(...) 是否真的存在）")
        print("#" * 74)
        cross, n_checked = check_cross_module(path, files)
        if cross:
            print("  [严重] {} 处调用了不存在的模块函数（共校验 {} 次调用）:".format(
                len(cross), n_checked))
            for fname, line, alias, member, mod in cross:
                print("      {:<22} 行 {:<6} {}.{}()  —— {} 里没有定义".format(
                    fname, line, alias, member, mod))
            print()
            print("      ==> 运行到这一行会抛 'attempt to call a nil value'")
            bad += len(cross)
        elif n_checked == 0:
            print("  [警告] 一次跨模块调用都没校验到 —— 检查可能已失效，请查代码")
            bad += 1
        else:
            print("  [通过] 校验了 {} 次跨模块调用，全部能在定义模块里找到"
                  .format(n_checked))
        print()
        print("#" * 74)
        print("# 汇总: {} 个文件, {} 个有问题".format(len(files), bad))
        print("#" * 74)
        return 1 if bad else 0
    return check_file(path, verbose)


def main() -> int:
    ap = argparse.ArgumentParser(description="Lua 静态检查（替代无法执行的 Lua）")
    ap.add_argument("paths", nargs="+", help="一个或多个 .lua 文件，或一个目录")
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    rc = 0
    for p in args.paths:
        if check(p, args.verbose):
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
