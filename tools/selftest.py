#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
selftest.py -- 蓝图工具链自检

为什么需要它
------------
目前的 recon 数据只有"每类型一个样本"，没法验证导出器在**完整规模**
（单存档 649 个实例 / 79 种类型 / 多基地 / 多层）下的行为。

本脚本用**合成数据**造出完整规模的原始数据，跑一遍
生成 -> 校验 -> 统计 -> 往返 的完整链路，确认：

  1. 数量守恒：输入 N 个实例，蓝图里就是 N 个
  2. 类型守恒：每个类型的实例数与输入一致
  3. 坐标正确：所有坐标都在包围盒内，且相对原点
  4. 分层正确：层号单调对应高度
  5. 校验器能发现被破坏的蓝图（负向测试）
  6. Yaw 归一化到 -180..180

用法:
    python selftest.py
    python selftest.py --instances 2000 --types 90 --bases 4
"""

from __future__ import annotations

import argparse
import json
import math
import os
import random
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
BLUEPRINT_PY = os.path.join(HERE, "blueprint.py")

PASS = "  [通过]"
FAIL = "  [失败]"


class Result:
    def __init__(self):
        self.ok = 0
        self.bad = 0

    def check(self, cond: bool, label: str, detail: str = ""):
        if cond:
            self.ok += 1
            print(f"{PASS} {label}")
        else:
            self.bad += 1
            print(f"{FAIL} {label}   {detail}")


def run(args: list[str]) -> tuple[int, str]:
    r = subprocess.run([sys.executable, BLUEPRINT_PY] + args,
                       capture_output=True, text=True, encoding="utf-8",
                       errors="replace")
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def synth(n_instances: int, n_types: int, n_bases: int, seed: int,
          with_camp_id: bool = False) -> list[dict]:
    """造合成实例：每个基地里随机散布若干建筑，带多层结构。"""
    rng = random.Random(seed)
    type_names = [f"Synth_Type_{i:03d}" for i in range(n_types)]

    # 基地中心：彼此相距很远（模拟真实存档里基地分布）
    base_centers = []
    for b in range(n_bases):
        base_centers.append((
            rng.uniform(-400000, 400000),
            rng.uniform(-400000, 400000),
            rng.uniform(-5000, 30000),
        ))

    items = []
    for i in range(n_instances):
        b = rng.randrange(n_bases)
        cx, cy, cz = base_centers[b]
        # 基地内：50 米见方，向上堆 3 层，每层 4 米
        layer = rng.randrange(4)
        x = cx + rng.uniform(-2500, 2500)      # 厘米
        y = cy + rng.uniform(-2500, 2500)
        z = cz + layer * 400 + rng.uniform(-20, 20)
        # 吸附到 1 米（100 厘米）网格，模拟游戏行为
        x = round(x / 100.0) * 100.0
        y = round(y / 100.0) * 100.0
        z = round(z / 100.0) * 100.0
        it = {
            "type": type_names[rng.randrange(n_types)],
            "world_cm": [x, y, z],
            "yaw": rng.choice([0.0, 90.0, 180.0, -90.0, rng.uniform(-180, 180)]),
        }
        if with_camp_id:
            # 用基地下标造一个稳定的据点 ID（模拟 Guid）
            it["baseCampId"] = f"CAMP{b:02d}" + "0" * 28
        items.append(it)
    return items


def write_pwbuild(path: str, items: list[dict], mode: str = "all",
                  center=(0.0, 0.0, 0.0), radius: float = 0.0) -> None:
    """写出 PWRecon v0.6 的 TSV 格式，用于测解析与筛选。"""
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(f"#PWBUILD|version=1|units=cm|total={len(items)}|mode={mode}"
                 f"|center={center[0]:.1f},{center[1]:.1f},{center[2]:.1f}"
                 f"|radius={radius:.0f}|time=0\n")
        fh.write("#type\tx\ty\tz\tyaw\tmesh\tbaseCampId\tgroupId\townerId\n")
        for it in items:
            x, y, z = it["world_cm"]
            fh.write(f"{it['type']}\t{x:.2f}\t{y:.2f}\t{z:.2f}\t{it['yaw']:.2f}"
                     f"\t-\t{it.get('baseCampId') or '-'}\t-\t-\n")



def main() -> int:
    ap = argparse.ArgumentParser(description="蓝图工具链自检")
    ap.add_argument("--instances", type=int, default=800)
    ap.add_argument("--types", type=int, default=60)
    ap.add_argument("--bases", type=int, default=3)
    ap.add_argument("--seed", type=int, default=20260926)
    ap.add_argument("--tmpdir", default=None,
                    help="临时目录（默认 out/selftest-tmp，必须在工作区内）")
    args = ap.parse_args()

    # 默认用工作区内的目录：系统 %TEMP% 可能被沙箱拦
    if args.tmpdir:
        tmp = args.tmpdir
    else:
        tmp = os.path.join(os.path.dirname(HERE), "out", "selftest-tmp")
    os.makedirs(tmp, exist_ok=True)

    print("=" * 70)
    print("蓝图工具链自检（合成数据）")
    print("=" * 70)
    print(f"  实例数 {args.instances}  类型数 {args.types}  基地数 {args.bases}")
    print(f"  临时目录 {tmp}")

    items = synth(args.instances, args.types, args.bases, args.seed)

    res = Result()

    # 每次运行用独立的子目录，避免累积上一次的产物导致计数断言误报
    tmp = os.path.join(tmp, f"r{args.instances}_{args.types}_{args.bases}_{args.seed}")
    # 清空（同一组参数重跑时可复现）
    if os.path.isdir(tmp):
        shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp, exist_ok=True)
    print(f"  本次运行目录 {tmp}")

    # ---------------------------------------------------------------- 1. 生成
    print()
    print("---- 1. raw 模式生成 ----")
    raw_path = os.path.join(tmp, "raw.json")
    with open(raw_path, "w", encoding="utf-8") as fh:
        json.dump(items, fh)

    bp_path = os.path.join(tmp, "bp.json")
    code, out = run(["raw", raw_path, "-o", bp_path, "-n", "selftest"])
    res.check(code == 0, "raw 生成退出码为 0", f"code={code}\n{out[-800:]}")
    res.check(os.path.isfile(bp_path), "蓝图文件已生成")
    if not os.path.isfile(bp_path):
        return 1

    with open(bp_path, "r", encoding="utf-8") as fh:
        bp = json.load(fh)

    # ---------------------------------------------------------------- 2. 数量守恒
    print()
    print("---- 2. 数量守恒 ----")
    blds = bp["buildings"]
    res.check(len(blds) == args.instances,
              f"实例数守恒 ({args.instances})", f"实际 {len(blds)}")
    res.check(bp["meta"]["total"] == len(blds), "meta.total 与数组长度一致")

    in_types: dict[str, int] = {}
    for it in items:
        in_types[it["type"]] = in_types.get(it["type"], 0) + 1
    out_types: dict[str, int] = {}
    for b in blds:
        out_types[b["t"]] = out_types.get(b["t"], 0) + 1
    res.check(in_types == out_types,
              f"类型分布守恒 ({len(in_types)} 种)",
              f"差异 {set(in_types.items()) ^ set(out_types.items())}")

    # ---------------------------------------------------------------- 3. 坐标正确
    print()
    print("---- 3. 坐标正确性 ----")
    ox, oy, oz = bp["meta"]["origin"]
    in_min = [min(it["world_cm"][i] / 100.0 for it in items) for i in range(3)]
    in_max = [max(it["world_cm"][i] / 100.0 for it in items) for i in range(3)]

    # 每个实例的位置 = origin + p，应能还原回输入（允许 1 米吸附误差）
    worst = 0.0
    for it, b in zip(items, blds):
        src = [v / 100.0 for v in it["world_cm"]]
        got = [ox + b["p"][0], oy + b["p"][1], oz + b["p"][2]]
        d = max(abs(src[i] - got[i]) for i in range(3))
        worst = max(worst, d)
    res.check(worst <= 0.02, f"坐标往返误差 <= 0.02 米", f"最大误差 {worst:.4f}")

    size = bp["meta"]["size"]
    exp_size = [in_max[i] - in_min[i] for i in range(3)]
    ok_size = all(abs(size[k] - exp_size[i]) < 0.02
                  for i, k in enumerate(["x", "y", "z"]))
    res.check(ok_size, "包围盒尺寸与输入一致",
              f"期望 {[round(v,3) for v in exp_size]} 实际 {size}")

    # 相对坐标以【包围盒中心】为原点，所以范围是 ±size/2（加上 1 米吸附余量）
    SNAP = 1.0
    axes = ["x", "y", "z"]
    bad_box = []
    for b in blds:
        for i, k in enumerate(axes):
            half = size[k] / 2.0
            if not (-half - SNAP - 0.02 <= b["p"][i] <= half + SNAP + 0.02):
                bad_box.append((k, b["p"][i], half))
                break
        if len(bad_box) >= 3:
            break
    res.check(not bad_box,
              "所有相对坐标都在 ±size/2 内（原点=包围盒中心）",
              f"越界样例 {bad_box}")

    # 同时验证"中心化"这个性质：相对坐标的均值应接近 0
    for i, k in enumerate(axes):
        vals = [b["p"][i] for b in blds]
        mid = (min(vals) + max(vals)) / 2.0
        if abs(mid) > SNAP + 0.02:
            res.check(False, f"{k} 方向已中心化", f"中点 {mid:.3f} 偏离 0 过多")
            break
    else:
        res.check(True, "三个方向的相对坐标都已中心化（中点≈0）")

    # ---------------------------------------------------------------- 4. 分层
    print()
    print("---- 4. 分层正确性 ----")
    layers = sorted({b["layer"] for b in blds})
    res.check(len(layers) >= 1, f"产生的层数合理 ({len(layers)} 层)")

    # 层号应对应高度：层号越大，z 越大（允许同层内浮动）
    by_layer: dict[int, list[float]] = {}
    for b in blds:
        by_layer.setdefault(b["layer"], []).append(b["p"][2])
    layer_max = {L: max(v) for L, v in by_layer.items()}
    monotonic = all(
        layer_max[a] <= layer_max[b]
        for a, b in zip(layers, layers[1:])
    )
    res.check(monotonic, "层号与高度单调对应",
              f"层->zMax { {k: round(v,1) for k,v in sorted(layer_max.items())} }")

    # ---------------------------------------------------------------- 5. yaw
    print()
    print("---- 5. Yaw 归一化 ----")
    bad_yaw = [b["yaw"] for b in blds if not (-180.0 <= b["yaw"] <= 180.0)]
    res.check(not bad_yaw, "所有 yaw 在 -180..180", f"越界 {bad_yaw[:5]}")

    # ---------------------------------------------------------------- 6. 校验器正向
    print()
    print("---- 6. 校验器（正向）----")
    code, out = run(["check", bp_path])
    res.check(code == 0, "完整蓝图校验通过", f"code={code}\n{out[-600:]}")

    # ---------------------------------------------------------------- 7. 校验器负向
    print()
    print("---- 7. 校验器（负向：应能发现被破坏的蓝图）----")

    # 7a. total 与实际不符
    bad = json.loads(json.dumps(bp))
    bad["meta"]["total"] = len(blds) + 5
    p = os.path.join(tmp, "bad_total.json")
    with open(p, "w", encoding="utf-8") as fh:
        json.dump(bad, fh)
    code, _ = run(["check", p])
    res.check(code != 0, "能发现 meta.total 不一致")

    # 7b. 坐标缺失
    bad = json.loads(json.dumps(bp))
    del bad["buildings"][0]["p"]
    p = os.path.join(tmp, "bad_pos.json")
    with open(p, "w", encoding="utf-8") as fh:
        json.dump(bad, fh)
    code, _ = run(["check", p])
    res.check(code != 0, "能发现坐标缺失")

    # 7c. 单位错误
    bad = json.loads(json.dumps(bp))
    bad["meta"]["units"] = "cm"
    p = os.path.join(tmp, "bad_units.json")
    with open(p, "w", encoding="utf-8") as fh:
        json.dump(bad, fh)
    code, _ = run(["check", p])
    res.check(code != 0, "能发现单位不是 meter")

    # 7d. 统计不一致
    bad = json.loads(json.dumps(bp))
    k = next(iter(bad["stats"]["types"]))
    bad["stats"]["types"][k]["count"] = 99999
    p = os.path.join(tmp, "bad_stats.json")
    with open(p, "w", encoding="utf-8") as fh:
        json.dump(bad, fh)
    code, _ = run(["check", p])
    res.check(code != 0, "能发现 stats 与实际数量不符")

    # 7e. 格式名错误
    bad = json.loads(json.dumps(bp))
    bad["$format"] = "something-else"
    p = os.path.join(tmp, "bad_format.json")
    with open(p, "w", encoding="utf-8") as fh:
        json.dump(bad, fh)
    code, _ = run(["check", p])
    res.check(code != 0, "能发现 $format 不匹配")

    # ---------------------------------------------------------------- 8. 拆分
    print()
    print("---- 8. 按基地拆分 ----")
    outdir = os.path.join(tmp, "bases")
    code, out = run(["raw", raw_path, "--split", "--outdir", outdir,
                     "-o", os.path.join(tmp, "unused.json")])
    # raw 模式没实现 --split，应该报错或忽略；这里只验证 samples 模式的 split
    code, out = run(["samples", os.path.join(HERE, "..", "data",
                                             "recon_alltypes.txt"),
                     "--split", "--outdir", outdir])
    if code == 0 and os.path.isdir(outdir):
        files = [f for f in os.listdir(outdir) if f.endswith(".json")]
        res.check(len(files) >= 1, f"samples --split 产出 {len(files)} 个基地蓝图")
        # 每个子蓝图都应能通过校验
        allok = True
        detail = ""
        for f in files:
            c, o = run(["check", os.path.join(outdir, f)])
            if c != 0:
                allok = False
                detail = f"{f}: {o[-300:]}"
                break
        res.check(allok, "所有拆分出的基地蓝图都校验通过", detail)
    else:
        res.check(False, "samples --split 执行失败", out[-400:])

    # ---------------------------------------------------------------- 9. TSV 解析
    print()
    print("---- 9. PWRecon TSV 解析 ----")
    tsv_items = synth(args.instances, args.types, args.bases, args.seed + 1,
                      with_camp_id=True)
    tsv_path = os.path.join(tmp, "buildings_raw.tsv")
    write_pwbuild(tsv_path, tsv_items)

    tsv_bp = os.path.join(tmp, "from_tsv.blueprint.json")
    code, out = run(["raw", tsv_path, "-o", tsv_bp, "-n", "from-tsv"])
    res.check(code == 0, "TSV 解析并生成蓝图成功", f"code={code}\n{out[-700:]}")
    if os.path.isfile(tsv_bp):
        with open(tsv_bp, "r", encoding="utf-8") as fh:
            tbp = json.load(fh)
        res.check(len(tbp["buildings"]) == len(tsv_items),
                  f"TSV 实例数守恒 ({len(tsv_items)})",
                  f"实际 {len(tbp['buildings'])}")
        res.check(tbp["meta"]["units"] == "meter", "TSV 厘米 -> 米 换算正确")
        c, o = run(["check", tsv_bp])
        res.check(c == 0, "TSV 生成的蓝图通过校验", o[-400:])
    else:
        res.check(False, "TSV 蓝图文件未生成")

    # ---------------------------------------------------------------- 10. 筛选
    print()
    print("---- 10. 筛选（按据点 / 坐标范围 / 半径）----")

    # 10a. camps 子命令应能列出 N 个据点
    code, out = run(["camps", tsv_path])
    res.check(code == 0 and f"{args.bases}" in out,
              f"camps 列出据点（预期 {args.bases} 个）", out[-400:])

    # 10b. --camp 只保留该据点的建筑
    camp_id = tsv_items[0]["baseCampId"]
    expect_camp = sum(1 for it in tsv_items if it.get("baseCampId") == camp_id)
    out_camp = os.path.join(tmp, "camp.blueprint.json")
    code, out = run(["raw", tsv_path, "--camp", camp_id, "-o", out_camp])
    res.check(code == 0, f"--camp 执行成功", out[-400:])
    if os.path.isfile(out_camp):
        with open(out_camp, "r", encoding="utf-8") as fh:
            cbp = json.load(fh)
        res.check(len(cbp["buildings"]) == expect_camp,
                  f"--camp 只保留该据点 ({expect_camp} 件)",
                  f"实际 {len(cbp['buildings'])}")
        # 据点蓝图应当很紧凑
        sz = cbp["meta"]["size"]
        compact = sz["x"] < 200 and sz["y"] < 200
        res.check(compact, f"--camp 结果紧凑 ({sz['x']:.0f}x{sz['y']:.0f} 米)")
    else:
        res.check(False, "--camp 输出未生成")

    # 10c. --box 坐标范围
    # 注意：坐标可能是负数（Palworld 世界坐标经常是负的），
    # argparse 会把 "-123.4,..." 误认为选项名，所以必须用 --box=<值> 形式。
    xs = [it["world_cm"][0] / 100.0 for it in tsv_items]
    ys = [it["world_cm"][1] / 100.0 for it in tsv_items]
    zs = [it["world_cm"][2] / 100.0 for it in tsv_items]
    x0, x1 = min(xs), max(xs)
    y0, y1 = min(ys), max(ys)
    z0, z1 = min(zs), max(zs)
    xmid = (x0 + x1) / 2.0
    expect_box = sum(1 for it in tsv_items if it["world_cm"][0] / 100.0 <= xmid)
    out_box = os.path.join(tmp, "box.blueprint.json")
    boxval = f"{x0-1},{y0-1},{z0-1},{xmid},{y1+1},{z1+1}"
    code, out = run(["raw", tsv_path, f"--box={boxval}", "-o", out_box])
    res.check(code == 0, "--box 执行成功（用 --box= 形式传负数）", out[-400:])
    if os.path.isfile(out_box):
        with open(out_box, "r", encoding="utf-8") as fh:
            bbp = json.load(fh)
        res.check(len(bbp["buildings"]) == expect_box,
                  f"--box 只保留盒内建筑 ({expect_box} 件)",
                  f"实际 {len(bbp['buildings'])}")
        maxx = max(b["p"][0] for b in bbp["buildings"]) + bbp["meta"]["origin"][0]
        res.check(maxx <= xmid + 0.02, f"--box 上界生效 (maxX={maxx:.1f} <= {xmid:.1f})")
    else:
        res.check(False, "--box 输出未生成")

    # 10c-2. 不带 = 的负数坐标应当被 argparse 拒绝（记录这个坑）
    code, _ = run(["raw", tsv_path, "--box", boxval, "-o",
                   os.path.join(tmp, "should_fail.json")])
    res.check(code != 0, "负数坐标若不写 = 会被 argparse 拒绝（已知限制）")

    # 10d. --radius + --center（用真实存在建筑的位置做中心，保证测到东西）
    anchor = tsv_items[0]
    cxx = anchor["world_cm"][0] / 100.0
    cyy = anchor["world_cm"][1] / 100.0
    czz = anchor["world_cm"][2] / 100.0
    rad = 60.0
    expect_r = sum(1 for it in tsv_items
                   if ((it["world_cm"][0] / 100.0 - cxx) ** 2
                       + (it["world_cm"][1] / 100.0 - cyy) ** 2
                       + (it["world_cm"][2] / 100.0 - czz) ** 2) <= rad * rad)
    out_r = os.path.join(tmp, "radius.blueprint.json")
    code, out = run(["raw", tsv_path, "--center", f"{cxx},{cyy},{czz}",
                     "--radius", str(rad), "-o", out_r])
    res.check(code == 0, "--radius 执行成功", out[-400:])
    if os.path.isfile(out_r):
        with open(out_r, "r", encoding="utf-8") as fh:
            rbp = json.load(fh)
        res.check(len(rbp["buildings"]) == expect_r,
                  f"--radius 只保留半径内建筑 ({expect_r} 件)",
                  f"实际 {len(rbp['buildings'])}")
        # 半径筛选后的尺寸不应超过 2*半径
        sz = rbp["meta"]["size"]
        res.check(max(sz["x"], sz["y"], sz["z"]) <= 2 * rad + 2,
                  f"--radius 结果尺寸受控 (最大边 {max(sz['x'], sz['y'], sz['z']):.1f} <= {2*rad})")
    else:
        res.check(False, "--radius 输出未生成")

    # 10e. --limit
    out_lim = os.path.join(tmp, "limit.blueprint.json")
    code, out = run(["raw", tsv_path, "--limit", "10", "-o", out_lim])
    if os.path.isfile(out_lim):
        with open(out_lim, "r", encoding="utf-8") as fh:
            lbp = json.load(fh)
        res.check(len(lbp["buildings"]) == 10, "--limit 生效（10 件）",
                  f"实际 {len(lbp['buildings'])}")
    else:
        res.check(False, "--limit 输出未生成")

    # 10f. --split --by camp
    splitdir = os.path.join(tmp, "bycamp")
    code, out = run(["raw", tsv_path, "--split", "--by", "camp",
                     "--outdir", splitdir, "-o", os.path.join(tmp, "x.json")])
    files = ([f for f in os.listdir(splitdir) if f.endswith(".json")]
             if os.path.isdir(splitdir) else [])
    res.check(code == 0 and len(files) == args.bases,
              f"--split --by camp 产出 {args.bases} 个文件",
              f"实际 {len(files)} 个\n{out[-400:]}")
    allok = True
    for f in files:
        c, o = run(["check", os.path.join(splitdir, f)])
        if c != 0:
            allok = False
            break
    res.check(allok, "--by camp 拆出的蓝图都通过校验")
    # 拆出的建筑总数应等于原始总数
    total_split = 0
    for f in files:
        with open(os.path.join(splitdir, f), "r", encoding="utf-8") as fh:
            total_split += len(json.load(fh)["buildings"])
    res.check(total_split == len(tsv_items),
              f"拆分后总数守恒 ({len(tsv_items)})", f"实际 {total_split}")

    # ---------------------------------------------------------------- 汇总
    print()
    print("=" * 70)
    print(f"结果: {res.ok} 项通过, {res.bad} 项失败")
    print("=" * 70)
    print(f"临时目录: {tmp}")
    return 1 if res.bad else 0


if __name__ == "__main__":
    sys.exit(main())
