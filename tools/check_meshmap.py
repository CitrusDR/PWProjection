#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""网格映射表校验器 —— 校验 pwbp_meshmap.default.json 和 pwbp_meshmap.json。

为什么需要它（2026-09-26 实际踩到的三个坑）:

  1) 【字符串里嵌了双引号】-> JSON 语法错误，整张表加载失败。
     和 Lua 那边 `"这些就是"方向偏了"的原因"` 是同一类错误，
     只是换了语言。手工编辑 JSON 时非常容易犯。

  2) 【重复键】-> 修正一条映射时新加了一条，却忘了删旧的。
     JSON 规范里后者胜出，所以表面上"改了"，实际可能没改；
     更糟的是看文件的人以为旧的那条还有效。

  3) 【路径写错形式】-> 映射表里的值必须是 "Package.Object" 形式
     （例如 /Game/A/B/SM_X.SM_X），不能带类名前缀
     （"StaticMesh /Game/..."）—— 后者是 GetFullName() 的输出，
     直接填进去会读不到，而且不报错。

用法:
    python tools/check_meshmap.py mod/PWBlueprint/Scripts
退出码 0 = 全部通过。
"""
import collections
import io
import json
import os
import re
import sys

# "Package.Object" 形式: 必须有一个 "路径.ObjectName"，且 ObjectName 与文件名一致
PATH_RE = re.compile(r"^(/Game/[^ ]+)\.([^. ]+)$")


def check_one(path):
    """返回 (问题列表, 条目数, 单值数, 数组数)"""
    problems = []
    if not os.path.isfile(path):
        return problems, 0, 0, 0

    raw = io.open(path, encoding="utf-8-sig").read()

    # ---- 1. 语法 ---------------------------------------------------------
    # ★ 重复键必须在 object_pairs_hook 里当场抓。
    #   我第一版是"解析完再数 keys"—— 那是错的: object_pairs_hook 返回
    #   OrderedDict 时重复键已经被合并了，永远数不出重复。
    #   （这个漏洞是拿坏样本反向验证时发现的。）
    dups = []

    def hook(pairs):
        seen = set()
        for k, _v in pairs:
            if k in seen:
                dups.append(k)
            seen.add(k)
        return collections.OrderedDict(pairs)

    try:
        pairs = json.loads(raw, object_pairs_hook=hook)
    except ValueError as e:
        problems.append("JSON 语法错误: {}".format(e))
        problems.append("  ★ 最常见的原因: 字符串里又写了双引号。")
        problems.append("    改法: 把内层双引号换成「」或单引号。")
        return problems, 0, 0, 0

    # ---- 2. 重复键 -------------------------------------------------------
    for k, n in collections.Counter(dups).items():
        problems.append("重复键 {} 出现 {} 次（共 {} 次）—— 后者胜出，"
                        "请删掉多余的那条".format(k, n, n + 1))

    # ---- 3. 条目 ---------------------------------------------------------
    n_single = n_list = 0
    n_mapped = 0
    for k, v in pairs.items():
        if k.startswith("_"):
            continue                      # 下划线开头 = 给人看的注释
        n_mapped += 1

        if isinstance(v, str):
            values = [v]
            n_single += 1
        elif isinstance(v, list):
            values = v
            n_list += 1
            if not v:
                problems.append("{}: 数组是空的".format(k))
                continue
        else:
            problems.append("{}: 值必须是字符串或字符串数组，实际是 {}"
                            .format(k, type(v).__name__))
            continue

        for one in values:
            if not isinstance(one, str):
                problems.append("{}: 数组里有非字符串".format(k))
                continue
            if one == "-":
                continue                  # 特殊值: 不要画这个类型
            if one.startswith("StaticMesh ") or one.startswith("SkeletalMesh "):
                problems.append(
                    "{}: 值带了类名前缀 —— 那是 GetFullName() 的输出，"
                    "填进映射表会读不到（而且不报错）。去掉开头的 "
                    "'XXX ' 只留路径".format(k))
                continue
            m = PATH_RE.match(one)
            if m is None:
                problems.append("{}: 路径形式不对: {}".format(k, one))
                continue
            tail = one.rsplit("/", 1)[-1]
            obj = tail.split(".")[0]
            if m.group(2) != obj:
                problems.append(
                    "{}: Object 名和文件名不一致（{} vs {}）—— "
                    "通常是被截断或复制错了".format(k, m.group(2), obj))
    return problems, n_mapped, n_single, n_list


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else "mod/PWBlueprint/Scripts"
    total_problems = 0
    for name in ("pwbp_meshmap.default.json", "pwbp_meshmap.json"):
        p = os.path.join(d, name)
        print("=" * 74)
        print("校验: {}".format(p))
        print("=" * 74)
        probs, n, s, a = check_one(p)
        if not os.path.isfile(p):
            print("  [跳过] 文件不存在")
        elif probs:
            print("  [严重] {} 处问题:".format(len(probs)))
            for x in probs:
                print("    - " + x)
            total_problems += len(probs)
        else:
            print("  [通过] {} 条映射（单网格 {} / 多网格 {}）"
                  .format(n, s, a))
        print()
    print("=" * 74)
    if total_problems:
        print("结果: 发现 {} 处问题 —— 请修复后再部署！".format(total_problems))
    else:
        print("结果: 无问题")
    print("=" * 74)
    return 1 if total_problems else 0


if __name__ == "__main__":
    sys.exit(main())
