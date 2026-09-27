#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
luacheck_selftest.py -- 验证 luacheck.py 真的能抓到那些会崩游戏的写法

背景
----
2026-09-26 的崩溃是"调用了被误删的函数定义"，当时的检查工具**没抓到**。
如果检查工具本身没被测过，那它给的"通过"就没有意义。

所以这里用"已知错误的样例"反向验证 luacheck：
每个 BAD 样例都是本项目中真实出现过（或差点出现）的错误。

用法:
    python tools/luacheck_selftest.py
退出码: 0 = 全部符合预期
"""

from __future__ import annotations

import contextlib
import io
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import luacheck  # noqa: E402

# ---------------------------------------------------------------------------
# 必须被判为"有问题"的样例
# ---------------------------------------------------------------------------

BAD = {
    # 本项目真实出现过：双引号字符串里又写了双引号
    "embedded_quote.lua": '''
local function f()
    return true, "可用（游戏自带的"可放置"材质）"
end
return f
''',

    # 少写一个 end
    "missing_end.lua": '''
local function a()
    if true then
        return 1
    end

local function b()
    return 2
end
return b
''',

    # PWRecon 崩溃的直接原因：调用了被误删的定义
    "undefined_global_call.lua": '''
local function onKey()
    -- playerPawn 的定义被误删了，但调用还在
    local pawn = playerPawn()
    return pawn
end
return onKey
''',

    # Lua 5.4 里裸 unpack 不存在
    "bare_unpack.lua": '''
local function f(t)
    return unpack(t)
end
return f
''',

    # 这种写法实测触发过原生层崩溃
    "pcall_staticfindobject.lua": '''
local function f()
    local ok, o = pcall(StaticFindObject, "/Script/Engine.Actor")
    return ok, o
end
return f
''',

    # 短字符串没有闭合
    "unterminated_string.lua": '''
local s = "hello
return s
''',

    # 多余的 end
    "extra_end.lua": '''
local function f()
    return 1
end
end
return f
''',

    # 在 local 声明【之前】就使用它 —— 2026-09-26 22:14 真实踩的坑：
    # type_keywords 用了写在它后面的 local SYNONYMS，
    # 所有其它检查都通过，一进游戏按 K 就报 nil。
    "use_before_local.lua": '''
local function keywords(name)
    -- SYNONYMS 的 local 声明在下面，这里会解析成全局 = nil
    return SYNONYMS[name] or name
end

local SYNONYMS = { foundation = "floor" }

return keywords
''',

    # Lua 的 %w 不含下划线 —— 2026-09-26 真实踩的坑：
    # 从网格组件全名里解析宿主建筑类型名的模式写成 BP_BuildObject_([%w]+)_C，
    # 结果带下划线的类型（WeaponFactory_Dirty_4 等）全被静默漏掉，
    # 表现得像"这些建筑没有网格组件"，差点导出错误结论。
    "percent_w_underscore.lua": '''
local function owner_type(component_full_name)
    -- 错: [%w] 不含下划线，跨不过 "SphereFactory_Black_04"
    return component_full_name:match("BP_BuildObject_([%w]+)_C")
end

return owner_type
''',

    # Lua 保留字当字段名/方法名 —— 2026-09-27 真实踩的坑：
    # pwpr_notify.lua 里写了 function Notify.repeat()。
    # repeat 是块起始关键字，所以这是【语法错误】: 整个文件都加载不了，
    # 症状是 mod 一行日志都不打、直接 init failed。
    # 当时静态检查器先报的是"块结构平衡: 结束时深度 = 1"（看着像少写 end）。
    "keyword_as_field.lua": '''
local Notify = {}

function Notify.repeat()
    return true
end

function Notify.show(text)
    return text
end

return Notify
''',

    # 冒号调用也一样是语法错误
    "keyword_as_method.lua": '''
local Obj = {}

function Obj:end()
    return 1
end

return Obj
''',

    # 禁用的反射枚举 —— 2026-09-27 真实踩的坑：
    # S9 探测第 2 步用 ForEachFunction + ForEachProperty 枚举
    # PlayerController 的函数与参数签名，**直接崩游戏**（崩溃栈全在 UE4SS）。
    # 踩坑记录 3c-3 / 3f-2 早就记过 ForEachProperty 不可用，只是当时没做成检查项。
    "banned_foreach_function.lua": '''
local function dump_functions(obj)
    local names = {}
    obj:ForEachFunction(function(f)
        names[#names + 1] = f
    end)
    return names
end

return dump_functions
''',

    "banned_foreach_property.lua": '''
local function dump_props(obj)
    local out = {}
    obj:ForEachProperty(function(p)
        out[#out + 1] = p
    end)
    return out
end

return dump_props
''',
}

# ---------------------------------------------------------------------------
# 必须判为"没问题"的样例（防止误报把工具变成噪音）
# ---------------------------------------------------------------------------

GOOD = {
    # ★ 反面样例的【正确写法】必须判为没问题，否则工具会把对的也拦下来
    "good_pattern_underscore.lua": '''
local function owner_type(component_full_name)
    -- 对: 字符类里显式加上下划线，先按 _C_<数字> 精确定位
    local t = component_full_name:match("BP_BuildObject_([%w_]-)_C_%d+")
    if t == nil then
        t = component_full_name:match("BP_BuildObject_([%w_]+)_C")
    end
    return t
end

return owner_type
''',

    # 模块表 + 点号函数 + 参数 + 中文字符串/注释
    "good_module.lua": '''-- 这是一个注释，里面有中文
local Util = {}

--- 文档注释：参数 v 可能是 nil
function Util.pick(v, key)
    if v == nil then return nil end
    local ok, r = pcall(function() return v[key] end)
    if ok then return r end
    return nil
end

function Util.join(dir, name, sep)
    sep = sep or "\\\\"
    return tostring(dir) .. sep .. tostring(name)
end

local function inner(list, fn)
    local out = {}
    for i = 1, #list do
        out[#out + 1] = fn(list[i])
    end
    return out
end

Util.inner = inner
Util.LABEL = "中文标签也可以放在字符串里"
return Util
''',

    # ★ 保留字检查的【反面样例】: 名字里含保留字但不是字段名，
    #   或者保留字出现在字符串/注释里 —— 都不该报错。
    "good_keyword_not_field.lua": '''
local Notify = {}

-- repeat / end / for 这些词出现在注释里完全正常
Notify.resend = function()
    return true
end

function Notify.show(text)
    local msg = "x.end 和 y.repeat 只是字符串，不是字段访问"
    local many = { for_each = 1, ending = 2, repeats = 3 }
    if text == nil then return msg end
    return msg .. tostring(many.repeats)
end

return Notify
''',

    # ★ 反射禁用检查的【反面样例】: 名字里含 ForEach 但不是被禁的那三个，
    #   以及注释/字符串里提到它们 —— 都不该报错。
    "good_foreach_names.lua": '''
local M = {}

-- 注释里提到 ForEachProperty 是正常的（这里就是记录这个坑）
function M.walk(list)
    local out = {}
    for i = 1, #list do
        out[#out + 1] = list[i]
    end
    local msg = "ForEachFunction 和 ForEachProperty 已被禁用，改用 FindAllOf"
    return out, msg
end

local function ForEachWrapper(fn)
    return fn
end

M.wrap = ForEachWrapper
return M
''',

    # 各种块结构嵌套
    "good_blocks.lua": '''
local t = {}

function t.run(n)
    local sum = 0
    for i = 1, n do
        if i % 2 == 0 then
            sum = sum + i
        elseif i == 7 then
            sum = sum - i
        else
            while sum > 100 do
                sum = sum - 10
            end
        end
    end
    repeat
        sum = sum + 1
    until sum > 3
    do
        local x = sum
        sum = x
    end
    return sum
end

return t
''',

    # 长字符串 / 长注释
    "good_long.lua": '''
--[[
  长注释里可以有 "引号" 和 '单引号'
]]
local HELP = [[
  多行文本
  也可以有 "引号"
]]
local function f(a, b)
    return a .. b
end
return f, HELP
''',

    # 声明顺序正确：表在使用它的函数之前声明
    "good_local_order.lua": '''
local TABLE = { key = 1, other = 2 }

local function f()
    return TABLE.key
end

local function g(k)
    return TABLE[k], f()
end

return g
''',
}


def run_case(name: str, source: str, tmpdir: str) -> int:
    path = os.path.join(tmpdir, name)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(source)
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = luacheck.check_file(path)
    return rc


# ---------------------------------------------------------------------------
# 跨模块接口检查的样例
#   单文件检查抓不到"调用了不存在的模块函数" —— 每个文件自己都合法，
#   只有连起来才错。所以这一项必须单独验证。
# ---------------------------------------------------------------------------

CROSS_MOD_A = '''
local B = require("cross_mod_b")
local function go(n)
    return B.hello(n)
end
return go
'''

CROSS_MOD_B = '''
local B = {}
function B.hello(x)
    return x
end
B.VERSION = 1
return B
'''

CROSS_MOD_A_TYPO = '''
local B = require("cross_mod_b")
local function go(n)
    -- 拼错了：定义里是 hello，不是 helo
    return B.helo(n)
end
return go
'''


def run_cross(tmpdir: str, sources: dict):
    """返回 (problems, checked)"""
    sub = os.path.join(tmpdir, "cross")
    shutil.rmtree(sub, ignore_errors=True)
    os.makedirs(sub, exist_ok=True)
    for name, src in sources.items():
        with open(os.path.join(sub, name), "w", encoding="utf-8") as fh:
            fh.write(src)
    files = sorted(os.path.join(sub, n) for n in sources)
    return luacheck.check_cross_module(sub, files)


def main() -> int:
    # 注意: 不用系统临时目录 —— 开发环境里 %TEMP% 可能被沙箱拒绝写入。
    # 固定放在项目 out/ 下，跑完就删。
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    outdir = os.path.join(root, "out")
    os.makedirs(outdir, exist_ok=True)
    tmpdir = os.path.join(outdir, "luacheck-selftest-tmp")
    shutil.rmtree(tmpdir, ignore_errors=True)
    os.makedirs(tmpdir, exist_ok=True)
    ok, bad = 0, []

    try:
        for name, src in sorted(BAD.items()):
            rc = run_case(name, src, tmpdir)
            if rc != 0:
                ok += 1
                print("[OK]   正确判为有问题: {}".format(name))
            else:
                bad.append(name)
                print("[FAIL] 漏报（应该有问题却通过）: {}".format(name))

        for name, src in sorted(GOOD.items()):
            rc = run_case(name, src, tmpdir)
            if rc == 0:
                ok += 1
                print("[OK]   正确判为没问题: {}".format(name))
            else:
                bad.append(name)
                print("[FAIL] 误报（应该通过却报错）: {}".format(name))

        # ---- 跨模块接口检查 ----
        cross_good, n_good = run_cross(tmpdir, {
            "cross_mod_a.lua": CROSS_MOD_A,
            "cross_mod_b.lua": CROSS_MOD_B,
        })
        if not cross_good and n_good > 0:
            ok += 1
            print("[OK]   跨模块检查：正确的调用没有误报（校验了 {} 次）"
                  .format(n_good))
        else:
            bad.append("cross_good")
            print("[FAIL] 跨模块检查误报或没校验到任何调用: {} checked={}"
                  .format(cross_good, n_good))

        cross_bad, n_bad = run_cross(tmpdir, {
            "cross_mod_a.lua": CROSS_MOD_A_TYPO,
            "cross_mod_b.lua": CROSS_MOD_B,
        })
        hit = any(p[3] == "helo" for p in cross_bad)
        if hit:
            ok += 1
            print("[OK]   跨模块检查：抓到了 B.helo(...) 这个拼写错误")
        else:
            bad.append("cross_typo")
            print("[FAIL] 跨模块检查漏报拼写错误: {} checked={}"
                  .format(cross_bad, n_bad))
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    total = len(BAD) + len(GOOD) + 2
    print()
    print("=" * 70)
    print("luacheck 自检: {}/{} 通过".format(ok, total))
    if bad:
        print("不符合预期: {}".format(", ".join(bad)))
    print("=" * 70)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
