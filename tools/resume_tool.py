#!/usr/bin/env python3
"""查看 / 删除 `pwpr_placements.json`（"投影位置 + 进度记忆"）里的记录。

## 为什么有这个工具

玩家 2026-09-29 问:

> 「如果我要删掉这些记录应该怎么搞，直接删某个文件吗？」

* 直接删**整个文件**当然可以（= 全部忘记），但有时只想删**某一张蓝图**或**某一处**；
* 手改 JSON 容易改坏（少一个逗号 → 游戏读不出来 → 记忆静默失效）；
* 所以给一个小工具，**只做增删查**，写回去的格式和 `pwpr_resume.lua` **完全一致**
  （格式定义只有一处: `tools/check_resume_json.py` 的 `render()`）。

## ⚠️ 用之前必须知道的两件事

1. **先把游戏关掉**（或至少返回标题并退出）——
   游戏里那份记录在**内存**里，退出时会**写回文件**，你在外面删了也会被覆盖；
2. 文件位置（相对游戏根目录）:
   `Mods\\NativeMods\\UE4SS\\Mods\\PWProjection\\Scripts\\pwpr_placements.json`

## 用法

```powershell
# 看现在记了什么（蓝图 / 每处的位置 / 朝向 / 进度件数 / 时间）
python tools\\resume_tool.py --file "<...>\\Scripts\\pwpr_placements.json" list

# 删掉某张蓝图的**第 2 处**记录（序号见 list 输出）
python tools\\resume_tool.py --file "<...>" drop-site "base_xxx.blueprint.json" 2

# 只清掉某一处的**进度**（保留位置: 下次还会沿用位置，但不再"已建好不画"）
python tools\\resume_tool.py --file "<...>" drop-progress "base_xxx.blueprint.json" 2

# 删掉整张蓝图的所有记录
python tools\\resume_tool.py --file "<...>" drop-blueprint "base_xxx.blueprint.json"

# 全部忘记（等价于删掉整个文件，但会留下一个合法的空文件）
python tools\\resume_tool.py --file "<...>" drop-all
```

加 `--dry-run` 只打印会改什么，不写文件。

退出码: 0 = 成功, 1 = 参数/文件有问题
"""
import argparse
import io
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_resume_json import render  # 写盘格式的唯一来源（与 Lua 侧是镜像）


def load(path):
    if not os.path.exists(path):
        print("文件不存在: %s" % path)
        print("（还没放过投影？那就没有记录可删。）")
        return None
    text = io.open(path, encoding="utf-8").read()
    try:
        obj = json.loads(text)
    except ValueError as exc:
        print("!! 这个文件不是合法 JSON（%s）" % exc)
        print("   要么是还没写过，要么是被改坏了。可以直接删掉它（= 全部忘记），")
        print("   游戏下次会重新生成。")
        return None
    placements = obj.get("placements")
    if not isinstance(placements, dict):
        print("!! 文件里没有 placements 段 —— 建议直接删掉这个文件。")
        return None
    # 规整成 { 蓝图: [site, ...] }
    out = {}
    for name, v in placements.items():
        if isinstance(v, dict) and isinstance(v.get("sites"), list):
            out[name] = v["sites"]
        elif isinstance(v, dict) and "x" in v:      # v1 的单条格式
            out[name] = [v]
        else:
            out[name] = []
    return out


def save(path, entries, dry_run):
    text = render(entries) + "\r\n"
    if dry_run:
        print("[dry-run] 会写入 %d 张蓝图 / %d 处记录"
              % (len(entries), sum(len(v) for v in entries.values())))
        return
    io.open(path, "w", encoding="utf-8", newline="").write(text)
    print("已写入 %s（%d 张蓝图 / %d 处记录）"
          % (path, len(entries), sum(len(v) for v in entries.values())))


def fmt_site(i, s):
    t = s.get("t") or 0
    when = time.strftime("%Y-%m-%d %H:%M", time.localtime(t)) if t else "?"
    return ("    [%d] 锚点 (%.0f, %.0f, %.0f)  朝向 %.0f 度  "
            "微调 (%.0f, %.0f, %.0f)  尺寸 %.0f×%.0f×%.0f 米  进度 %d 件  记于 %s"
            % (i, s.get("x", 0), s.get("y", 0), s.get("z", 0), s.get("yaw", 0),
               s.get("ox", 0), s.get("oy", 0), s.get("oz", 0),
               (s.get("sx", 0) or 0) / 100.0, (s.get("sy", 0) or 0) / 100.0,
               (s.get("sz", 0) or 0) / 100.0, len(s.get("placed", []) or []), when))


def cmd_list(entries, args):
    if not entries:
        print("（没有任何记录）")
        return 0
    print("共 %d 张蓝图 / %d 处记录:"
          % (len(entries), sum(len(v) for v in entries.values())))
    for name in sorted(entries):
        sites = entries[name]
        n_prog = sum(1 for s in sites if s.get("placed"))
        print("  %s  —— %d 处（其中 %d 处有进度）" % (name, len(sites), n_prog))
        for i, s in enumerate(sites, 1):
            print(fmt_site(i, s))
    return 0


def find_blueprint(entries, name):
    if name in entries:
        return name
    # 允许只写一部分（唯一匹配就行）
    hits = [k for k in entries if name.lower() in k.lower()]
    if len(hits) == 1:
        return hits[0]
    if not hits:
        print("找不到蓝图: %s" % name)
    else:
        print("这个名字匹配到多张，请写全一点:")
        for h in hits:
            print("  %s" % h)
    return None


def cmd_drop_site(entries, args):
    name = find_blueprint(entries, args.blueprint)
    if name is None:
        return 1
    sites = entries[name]
    idx = args.index
    if idx < 1 or idx > len(sites):
        print("序号超出范围（这张蓝图有 %d 处）" % len(sites))
        return 1
    print("删掉 %s 的第 %d 处:" % (name, idx))
    print(fmt_site(idx, sites[idx - 1]))
    del sites[idx - 1]
    if not sites:
        del entries[name]
    save(args.file, entries, args.dry_run)
    return 0


def cmd_drop_progress(entries, args):
    name = find_blueprint(entries, args.blueprint)
    if name is None:
        return 1
    sites = entries[name]
    idx = args.index
    if idx < 1 or idx > len(sites):
        print("序号超出范围（这张蓝图有 %d 处）" % len(sites))
        return 1
    n = len(sites[idx - 1].get("placed", []) or [])
    sites[idx - 1]["placed"] = []
    print("清掉 %s 第 %d 处的进度（原 %d 件）；位置保留" % (name, idx, n))
    save(args.file, entries, args.dry_run)
    return 0


def cmd_drop_blueprint(entries, args):
    name = find_blueprint(entries, args.blueprint)
    if name is None:
        return 1
    n = len(entries[name])
    del entries[name]
    print("删掉 %s 的全部 %d 处记录" % (name, n))
    save(args.file, entries, args.dry_run)
    return 0


def cmd_drop_all(entries, args):
    n = sum(len(v) for v in entries.values())
    entries.clear()
    print("清空全部记录（原来共 %d 处）" % n)
    save(args.file, entries, args.dry_run)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description="查看/删除 pwpr_placements.json 里的记录（先关掉游戏！）")
    ap.add_argument("--file", required=True,
                    help="pwpr_placements.json 的完整路径")
    ap.add_argument("--dry-run", action="store_true",
                    help="只打印会改什么，不写文件")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list", help="列出所有记录")

    p1 = sub.add_parser("drop-site", help="删掉某一处记录")
    p1.add_argument("blueprint")
    p1.add_argument("index", type=int)

    p2 = sub.add_parser("drop-progress", help="只清某一处的进度（保留位置）")
    p2.add_argument("blueprint")
    p2.add_argument("index", type=int)

    p3 = sub.add_parser("drop-blueprint", help="删掉某张蓝图的全部记录")
    p3.add_argument("blueprint")

    sub.add_parser("drop-all", help="全部清空")

    args = ap.parse_args()
    entries = load(args.file)
    if entries is None:
        return 1
    if args.cmd == "list":
        return cmd_list(entries, args)
    print("⚠️ 请确认**游戏已经关掉**（否则游戏退出时会把内存里的记录写回来覆盖掉这次修改）。")
    table = {
        "drop-site": cmd_drop_site,
        "drop-progress": cmd_drop_progress,
        "drop-blueprint": cmd_drop_blueprint,
        "drop-all": cmd_drop_all,
    }
    return table[args.cmd](entries, args)


if __name__ == "__main__":
    sys.exit(main())
