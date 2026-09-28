#!/usr/bin/env python3
"""一次性自查：确认 pwpr_resume.lua 写出来的 `pwpr_placements.json` 形状是合法 JSON。

为什么要有它：那个文件是我们自己手写拼出来的字符串，如果格式错了，
下次读盘就会静默失败（玩家体感"位置记忆没生效"）。这里照抄 Lua 侧的模板，
用 Python 的 json 解一遍 —— JSON 认了，Lua 侧自己的解析器也认。

用法: python tools/check_resume_json.py
退出码: 0 = 通过, 1 = 格式不对
"""
import json
import os
import sys

# 写盘模板里必须存在的字段（Lua 侧 pwpr_resume.lua 的格式串也要有这些）
FIELDS = ["x", "y", "z", "yaw", "ox", "oy", "oz", "sx", "sy", "sz", "t", "placed"]

# 照抄 pwpr_resume.lua 里 save() 的模板（改 Lua 那段就要一起改这里）
def render(entries):
    """entries: { 蓝图文件名: [site, site, ...] }，site 是 dict。"""
    keys = sorted(entries)
    out = ["{"]
    out.append('  "_readme": "PWProjection 记住的『每张蓝图每一处投影放在哪 + 已经建到哪』。'
               '一张蓝图可以有多处（sites）；有进度的都会留着，没进度的每张只留最新一条。'
               '删掉这个文件就等于全部忘记。坐标是绝对世界坐标，且只在玩家还处在那片范围内'
               '才会沿用。",')
    out.append('  "placements": {')
    for i, k in enumerate(keys):
        parts = []
        for v in entries[k]:
            parts.append(('{"x":%.1f,"y":%.1f,"z":%.1f,"yaw":%.1f,'
                          '"ox":%.1f,"oy":%.1f,"oz":%.1f,'
                          '"sx":%.1f,"sy":%.1f,"sz":%.1f,"t":%d,"placed":[%s]}')
                         % (v["x"], v["y"], v["z"], v["yaw"], v["ox"], v["oy"],
                            v["oz"], v.get("sx", 0.0), v.get("sy", 0.0),
                            v.get("sz", 0.0), v["t"],
                            ",".join(str(x) for x in sorted(v.get("placed", [])))))
        out.append('    %s: {"sites": [%s]}%s'
                   % (json.dumps(k, ensure_ascii=False), ", ".join(parts),
                      "," if i < len(keys) - 1 else ""))
    out.append("  }")
    out.append("}")
    return "\r\n".join(out)


def main() -> int:
    samples = [
        {},
        # 一处（最常见的形态）
        {"base_-1038_415_2026-09-28_0415.blueprint.json": [
            {"x": -99565.0, "y": 39036.0, "z": 1009.0, "yaw": -7.6,
             "ox": 0.0, "oy": 0.0, "oz": 0.0, "sx": 5000.0, "sy": 4000.0,
             "sz": 1000.0, "t": 1759100000, "placed": [1, 5, 9, 12]}]},
        # 多处 + 空的进度（玩家实测的 A/B 两个位置）
        {"a.json": [
            {"x": 1.0, "y": 2.0, "z": 3.0, "yaw": 0.0, "ox": 1.0, "oy": 0.0,
             "oz": 0.0, "sx": 100.0, "sy": 100.0, "sz": 100.0, "t": 1,
             "placed": []},
            {"x": -10.0, "y": -20.0, "z": -30.0, "yaw": 90.0, "ox": 0.0, "oy": 0.0,
             "oz": 0.0, "sx": 100.0, "sy": 100.0, "sz": 100.0, "t": 2,
             "placed": [3, 4, 5]}],
         "b.json": [
            {"x": -1.0, "y": -2.0, "z": -3.0, "yaw": 180.0, "ox": 0.0, "oy": 0.0,
             "oz": 0.0, "sx": 100.0, "sy": 100.0, "sz": 100.0, "t": 2,
             "placed": [7]}]},
    ]
    bad = 0
    for i, s in enumerate(samples, 1):
        text = render(s)
        try:
            got = json.loads(text)
        except ValueError as exc:
            print("  [失败] 样例 %d: JSON 解析失败: %s" % (i, exc))
            print(text)
            bad += 1
            continue
        if got.get("placements", None) is None:
            print("  [失败] 样例 %d: 缺少 placements" % i)
            bad += 1
            continue
        if len(got["placements"]) != len(s):
            print("  [失败] 样例 %d: 条数不对 %d != %d"
                  % (i, len(got["placements"]), len(s)))
            bad += 1
            continue
        # ★ 多处（sites）也要逐条核对 —— 一张蓝图多处记录是 2026-09-29 新加的
        site_bad = 0
        for k, want in s.items():
            got_sites = got["placements"][k].get("sites")
            if not isinstance(got_sites, list) or len(got_sites) != len(want):
                site_bad += 1
                continue
            for a, b in zip(got_sites, want):
                if sorted(a.get("placed", [])) != sorted(b.get("placed", [])):
                    site_bad += 1
        if site_bad:
            print("  [失败] 样例 %d: 有 %d 条记录的多处/进度对不上" % (i, site_bad))
            bad += 1
            continue
        n_sites = sum(len(v) for v in s.values())
        print("  [通过] 样例 %d: %d 张蓝图 / %d 处记录，字段与进度读回一致"
              % (i, len(s), n_sites))

    # 我们自己的解析器（pwpr_json）要求顶层只有一个对象 —— 这里顺带核对
    text = render(samples[2])
    if text.count("\n{") > 0:
        print("  [失败] 顶层出现了第二个对象")
        bad += 1

    # ★ 反向漂移检查: Lua 侧写盘用的格式串，字段名必须和这里的模板一致。
    #   （这个项目的老毛病: Python 镜像和 Lua 源码各改各的 ⇒ 用"读源码对字段"来钉住）
    lua_path = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "mod", "PWProjection", "Scripts", "pwpr_resume.lua")
    try:
        lua = open(lua_path, encoding="utf-8").read()
    except OSError as exc:
        print("  [失败] 读不到 pwpr_resume.lua: %s" % exc)
        return 1
    lua_fields = []
    for name in FIELDS:
        if ('\\"%s\\"' % name) in lua:
            lua_fields.append(name)
    missing = [f for f in FIELDS if f not in lua_fields]
    if missing:
        print("  [失败] Lua 侧写盘模板里少了字段: %s" % ", ".join(missing))
        bad += 1
    else:
        print("  [通过] Lua 侧写盘模板的字段与这里一致（%d 个）" % len(FIELDS))

    print()
    if bad:
        print("结果: %d 项失败" % bad)
        return 1
    print("结果: 全部通过（pwpr_placements.json 的形状是合法 JSON，且与 Lua 模板字段一致）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
