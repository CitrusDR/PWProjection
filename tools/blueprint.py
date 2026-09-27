#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
blueprint.py -- Palworld 建筑蓝图：格式定义 + 导出/校验工具

背景与定位
----------
本工具是纯数据层，**不依赖游戏、不依赖 UE4SS**。

数据来源：游戏内 PWRecon mod 的 F8（建筑类型普查）导出的
`recon_alltypes.txt`，它提供了每种建筑类型的一个样本：

    短类型名                    数量  世界坐标                        旋转(Yaw)  mesh
    Wood_Foundation              351  X=-161481.01 Y=-63697.72 Z=-942.94  -28.7    -
    MedicalPalBed_02              70  X=-276795.15 Y=206935.56 Z=-1279.95 -173.9   SM_PalBedPrimitive

注意：那份样本只给出**每种类型一个实例**的坐标。
要导出完整蓝图，需要在游戏内改成"逐实例导出"（见 README 的下一步）。
所以本工具同时提供两种入口：

  1. `samples` 模式：读 recon_alltypes.txt（每类型一个样本）
     -> 生成"类型表 + 样本"的蓝图，用于**验证格式和工具链**
  2. `raw` 模式：读逐实例原始数据（每实例一条）
     -> 生成真正的完整蓝图

蓝图格式
--------
见 `docs/蓝图格式.md`。核心设计：

* 单位：米（游戏内是厘米，导出时 /100）
* 坐标：相对 origin 的偏移；origin 为整个建筑群包围盒中心，
  并对齐到 1 米网格（"吸附"），这样蓝图便于对齐和复用。
  **注意**：origin 是**向下取整**到网格的，所以相对坐标可能出现
  略小于 0 的值（最多 -1 米），这是网格对齐的正常结果。
* 旋转：只存 yaw（度，-180..180）
* layer：按高度分层的索引，供"分层展示"功能使用
* 类型用短名（与游戏蓝图类名对应）：
    Wood_Foundation  <->  BP_BuildObject_Wood_Foundation_C

用法
----
    python blueprint.py samples "recon_alltypes.txt" -o blueprint.json
    python blueprint.py samples "recon_alltypes.txt" --split      # 按基地拆分
    python blueprint.py raw raw_buildings.json -o blueprint.json
    python blueprint.py check blueprint.json                      # 校验
    python blueprint.py stats blueprint.json                      # 统计
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
from datetime import datetime, timezone

FORMAT_NAME = "palworld-blueprint"
FORMAT_VERSION = 1

# 游戏内单位是厘米，蓝图用米
CM_PER_M = 100.0

# 对齐网格（米）
SNAP_M = 1.0

# 建筑群聚类的距离阈值（米）。基地之间通常间隔很远，基地内部紧凑。
CLUSTER_THRESHOLD_M = 60.0

# 高度分层的层厚（米）
LAYER_HEIGHT_M = 4.0


# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------

def die(msg: str, code: int = 1):
    print(f"[X] {msg}", file=sys.stderr)
    sys.exit(code)


def info(msg: str):
    print(f"    {msg}")


def head(msg: str):
    print()
    print("=" * 70)
    print(msg)
    print("=" * 70)


def round_to(v: float, nd: int) -> float:
    r = round(v, nd)
    # 避免出现 -0.0
    return 0.0 if r == 0 else r


def yn(b: bool) -> str:
    return "是" if b else "否"


# ---------------------------------------------------------------------------
# 解析 recon_alltypes.txt
# ---------------------------------------------------------------------------

LINE_RE = re.compile(
    r"^(?P<type>\S+)\s+"
    r"(?P<count>\d+)\s+"
    r"X=(?P<x>-?[\d.]+)\s+Y=(?P<y>-?[\d.]+)\s+Z=(?P<z>-?[\d.]+)\s+"
    r"(?P<yaw>-?[\d.]+)\s+"
    r"(?P<mesh>\S+)\s*$"
)


def parse_alltypes(path: str) -> tuple[list[dict], dict]:
    """解析 recon_alltypes.txt，返回 (样本列表, 元信息)"""
    if not os.path.isfile(path):
        die(f"找不到输入文件: {path}")

    samples: list[dict] = []
    meta: dict = {"source": os.path.basename(path), "total_declared": None,
                  "stats_line": None, "skipped": 0}

    with open(path, "r", encoding="utf-8-sig") as fh:
        for raw in fh:
            line = raw.rstrip("\n").rstrip("\r")
            if not line.strip():
                continue

            # 抓元信息行
            if "PalBuildObject 总数" in line:
                m = re.search(r"=\s*(\d+)", line)
                if m:
                    meta["total_declared"] = int(m.group(1))
                continue
            if line.startswith("统计:"):
                meta["stats_line"] = line.strip()
                continue
            if line.startswith("#") or line.startswith("-") or line.startswith("短类型名"):
                continue
            if line.startswith("请把") or line.startswith("这份表") or line.startswith("共 "):
                continue

            m = LINE_RE.match(line)
            if not m:
                meta["skipped"] += 1
                continue

            mesh = m.group("mesh")
            samples.append({
                "type": m.group("type"),
                "count": int(m.group("count")),
                "world_cm": [float(m.group("x")), float(m.group("y")), float(m.group("z"))],
                "yaw": float(m.group("yaw")),
                "mesh": None if mesh in ("-", "") else mesh,
            })

    if not samples:
        die("没有解析出任何建筑样本，请检查输入文件格式")
    return samples, meta


# ---------------------------------------------------------------------------
# 基地聚类
# ---------------------------------------------------------------------------

def cluster_by_position(entries: list[dict], threshold_m: float) -> list[list[int]]:
    """单链聚类：把空间上接近的实例归为一组（一个基地）。

    entries 里每项需要有 "m" 键（米单位的 [x,y,z]）。
    返回若干组的下标列表。
    """
    n = len(entries)
    parent = list(range(n))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    th2 = threshold_m * threshold_m
    # O(n^2) 足够：单存档几百到几千件
    for i in range(n):
        xi, yi, zi = entries[i]["m"]
        for j in range(i + 1, n):
            xj, yj, zj = entries[j]["m"]
            dx, dy, dz = xi - xj, yi - yj, zi - zj
            if dx * dx + dy * dy + dz * dz <= th2:
                union(i, j)

    groups: dict[int, list[int]] = {}
    for i in range(n):
        groups.setdefault(find(i), []).append(i)
    return list(groups.values())


# ---------------------------------------------------------------------------
# 构建蓝图
# ---------------------------------------------------------------------------

def build_blueprint(name: str, entries_m: list[dict], meta_extra: dict | None = None) -> dict:
    """entries_m: [{"type":..., "m":[x,y,z], "yaw":..., "mesh":...}, ...]"""
    if not entries_m:
        die("没有建筑实例，无法生成蓝图")

    # ------------------------------------------------------------------
    # 按类型聚合 mesh
    #
    # 实测发现：同一类型的【不同实例】，Mesh 属性可用性不一致。
    # 例如 MedicalPalBed_02 在某个据点里能读到 SM_PalBedPrimitive，
    # 在另一个据点里却读不到。
    #
    # 所以不能"逐实例"决定 mesh，必须【按类型聚合】：扫描该类型的所有
    # 实例，取第一个有值的作为该类型的代表网格。
    # 这样任何蓝图里的类型表都是尽量完整的。
    # ------------------------------------------------------------------
    type_mesh: dict[str, str] = {}
    types_all: set[str] = set()
    for e in entries_m:
        t = e["type"]
        types_all.add(t)
        mesh = e.get("mesh")
        if mesh and not type_mesh.get(t):
            type_mesh[t] = mesh

    xs = [e["m"][0] for e in entries_m]
    ys = [e["m"][1] for e in entries_m]
    zs = [e["m"][2] for e in entries_m]

    cx = (min(xs) + max(xs)) / 2.0
    cy = (min(ys) + max(ys)) / 2.0
    cz = (min(zs) + max(zs)) / 2.0

    # origin 吸附到网格，便于对齐
    origin = [
        round_to(math.floor(cx / SNAP_M) * SNAP_M, 3),
        round_to(math.floor(cy / SNAP_M) * SNAP_M, 3),
        round_to(math.floor(cz / SNAP_M) * SNAP_M, 3),
    ]

    zmin = min(zs)
    buildings = []
    for e in entries_m:
        rx = e["m"][0] - origin[0]
        ry = e["m"][1] - origin[1]
        rz = e["m"][2] - origin[2]
        layer = int((e["m"][2] - zmin) // LAYER_HEIGHT_M)

        b = {
            "t": e["type"],
            "p": [round_to(rx, 3), round_to(ry, 3), round_to(rz, 3)],
            "yaw": round_to(e["yaw"], 2),
        }
        # mesh 优先用实例自己的；没有则回填该类型的代表网格
        mesh = e.get("mesh") or type_mesh.get(e["type"])
        if mesh:
            b["mesh"] = mesh
        b["layer"] = layer
        buildings.append(b)

    # 类型统计（mesh 用聚合结果，保证同类型一致）
    types: dict[str, dict] = {}
    for b in buildings:
        t = types.setdefault(b["t"], {"count": 0, "mesh": type_mesh.get(b["t"])})
        t["count"] += 1
    for t, d in types.items():
        if d["mesh"] is None:
            d["mesh"] = type_mesh.get(t)

    layers = {}
    for b in buildings:
        L = layers.setdefault(b["layer"], {"count": 0,
                                          "z_min": b["p"][2], "z_max": b["p"][2]})
        L["count"] += 1
        L["z_min"] = min(L["z_min"], b["p"][2])
        L["z_max"] = max(L["z_max"], b["p"][2])

    size = {
        "x": round_to(max(xs) - min(xs), 3),
        "y": round_to(max(ys) - min(ys), 3),
        "z": round_to(max(zs) - min(zs), 3),
    }

    bp = {
        "$format": FORMAT_NAME,
        "version": FORMAT_VERSION,
        "meta": {
            "name": name,
            "createdAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "source": "PWRecon (UE4SS)",
            "gameVersion": "Palworld 1.0.x",
            "total": len(buildings),
            "typeCount": len(types),
            "layerCount": len(layers),
            "units": "meter",
            "origin": origin,
            "size": size,
            "meshCoverage": {
                "typesWithMesh": len(type_mesh),
                "typesTotal": len(types_all),
            },
        },
        "stats": {
            "types": dict(sorted(types.items(), key=lambda kv: -kv[1]["count"])),
            "layers": dict(sorted(layers.items(), key=lambda kv: int(kv[0]))),
        },
        "buildings": buildings,
    }
    if meta_extra:
        bp["meta"].update(meta_extra)
    return bp


# ---------------------------------------------------------------------------
# 校验
# ---------------------------------------------------------------------------

REQUIRED_TOP = ["$format", "version", "meta", "buildings"]


def check_blueprint(bp: dict) -> tuple[list[str], list[str]]:
    """返回 (错误列表, 警告列表)"""
    errors: list[str] = []
    warnings: list[str] = []

    for k in REQUIRED_TOP:
        if k not in bp:
            errors.append(f"缺少顶层字段: {k}")
    if errors:
        return errors, warnings

    if bp["$format"] != FORMAT_NAME:
        errors.append(f"$format 不是 {FORMAT_NAME}: {bp['$format']!r}")
    if bp["version"] != FORMAT_VERSION:
        warnings.append(f"version={bp['version']}（当前工具支持 {FORMAT_VERSION}）")

    m = bp["meta"]
    for k in ("name", "total", "origin", "units"):
        if k not in m:
            errors.append(f"meta 缺少字段: {k}")
    if m.get("units") != "meter":
        errors.append(f"units 必须是 'meter'，实际 {m.get('units')!r}")

    blds = bp["buildings"]
    if not isinstance(blds, list):
        errors.append("buildings 必须是数组")
        return errors, warnings
    if m.get("total") != len(blds):
        errors.append(f"meta.total={m.get('total')} 与实际条数 {len(blds)} 不一致")

    types_seen: dict[str, int] = {}
    layers_seen: dict[int, int] = {}
    zs: list[float] = []

    for i, b in enumerate(blds):
        tag = f"buildings[{i}]"
        if not isinstance(b, dict):
            errors.append(f"{tag} 不是对象")
            continue
        t = b.get("t")
        if not isinstance(t, str) or not t:
            errors.append(f"{tag}.t 缺失或非字符串")
        else:
            types_seen[t] = types_seen.get(t, 0) + 1

        p = b.get("p")
        if not (isinstance(p, list) and len(p) == 3
                and all(isinstance(v, (int, float)) for v in p)):
            errors.append(f"{tag}.p 必须是 3 个数字")
        else:
            zs.append(float(p[2]))

        if not isinstance(b.get("yaw", 0), (int, float)):
            errors.append(f"{tag}.yaw 必须是数字")
        yaw = float(b.get("yaw", 0))
        if not (-180.0 <= yaw <= 180.0):
            warnings.append(f"{tag}.yaw={yaw} 超出 -180..180")

        if "layer" not in b:
            warnings.append(f"{tag} 缺少 layer")
        else:
            layers_seen[int(b["layer"])] = layers_seen.get(int(b["layer"]), 0) + 1

    # 统计一致性
    stats = bp.get("stats") or {}
    st_types = stats.get("types") or {}
    for t, cnt in st_types.items():
        actual = types_seen.get(t)
        if actual is None:
            warnings.append(f"stats.types 里的 {t} 在 buildings 里不存在")
        elif actual != cnt.get("count"):
            errors.append(f"stats.types[{t}].count={cnt.get('count')} 与实际 {actual} 不符")

    # 包围盒与 size 一致性
    if zs and m.get("size"):
        pass  # size 是整体包围盒，单独校验意义不大

    if not types_seen:
        errors.append("没有任何建筑")
    return errors, warnings


# ---------------------------------------------------------------------------
# 子命令
# ---------------------------------------------------------------------------

def cmd_samples(args):
    head("从 recon_alltypes.txt 生成蓝图（每类型一个样本）")
    samples, meta = parse_alltypes(args.input)
    info(f"解析出 {len(samples)} 种类型（跳过 {meta['skipped']} 行）")
    if meta.get("total_declared"):
        info(f"游戏内声明建筑总数: {meta['total_declared']}")
    if meta.get("stats_line"):
        info(meta["stats_line"])
    info("注意：每个类型只有一个样本，生成的蓝图仅用于验证格式与工具链")

    # 厘米 -> 米
    entries = []
    for s in samples:
        entries.append({
            "type": s["type"],
            "m": [v / CM_PER_M for v in s["world_cm"]],
            "yaw": s["yaw"],
            "mesh": s["mesh"],
            "count": s["count"],
        })

    if args.split:
        groups = cluster_by_position(entries, CLUSTER_THRESHOLD_M)
        info(f"按位置聚类得到 {len(groups)} 个建筑群（阈值 {CLUSTER_THRESHOLD_M} 米）")
        outdir = args.outdir or os.path.dirname(os.path.abspath(args.output)) or "."
        os.makedirs(outdir, exist_ok=True)
        for gi, idxs in enumerate(sorted(groups, key=lambda g: -len(g))):
            sub = [entries[i] for i in idxs]
            cx = sum(e["m"][0] for e in sub) / len(sub)
            cy = sum(e["m"][1] for e in sub) / len(sub)
            name = f"base_{gi+1}_{cx:.0f}_{cy:.0f}"
            bp = build_blueprint(name, sub)
            path = os.path.join(outdir, f"{name}.blueprint.json")
            write_json(path, bp)
            info(f"  {name}: {len(sub)} 种类型, "
                 f"{bp['meta']['size']} 米 -> {os.path.basename(path)}")
        return 0

    bp = build_blueprint(args.name or "sample-all-types", entries,
                         meta_extra={"note": "每类型单样本，仅供工具链验证"})
    write_json(args.output, bp)
    info(f"已写出 {args.output}")
    print_summary(bp)
    return 0


# ---------------------------------------------------------------------------
# 解析 PWRecon 的逐实例导出（TSV）
# ---------------------------------------------------------------------------

def parse_pwbuild(path: str) -> tuple[list[dict], dict]:
    """解析 PWRecon v0.6 的 buildings_raw.tsv。

    格式:
        #PWBUILD|version=1|units=cm|total=N|mode=...|center=x,y,z|radius=..|time=..
        #type\tx\ty\tz\tyaw\tmesh\tbaseCampId\tgroupId\townerId
        Wood_Foundation\t-161481.00\t-63697.72\t-942.94\t-28.69\t-\t-\t-\tPalMapObjectModel_2147432823
    """
    if not os.path.isfile(path):
        die(f"找不到输入文件: {path}")

    entries: list[dict] = []
    meta: dict = {"source": os.path.basename(path), "skipped": 0, "header": {}}

    with open(path, "r", encoding="utf-8-sig") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.rstrip("\n").rstrip("\r")
            if not line:
                continue

            if line.startswith("#PWBUILD|"):
                for part in line.split("|")[1:]:
                    if "=" in part:
                        k, v = part.split("=", 1)
                        meta["header"][k.strip()] = v.strip()
                continue
            if line.startswith("#"):
                continue

            cols = line.split("\t")
            if len(cols) < 5:
                meta["skipped"] += 1
                continue
            try:
                x, y, z = float(cols[1]), float(cols[2]), float(cols[3])
                yaw = float(cols[4])
            except ValueError:
                meta["skipped"] += 1
                continue

            def opt(i):
                if i >= len(cols):
                    return None
                v = cols[i].strip()
                return None if v in ("", "-") else v

            entries.append({
                "type": cols[0],
                "m": [x / CM_PER_M, y / CM_PER_M, z / CM_PER_M],
                "yaw": yaw,
                "mesh": opt(5),
                "baseCampId": opt(6),
                "groupId": opt(7),
                "ownerId": opt(8),
            })

    if not entries:
        die("没有解析出任何建筑实例（检查文件是否为 PWRecon 的 buildings_raw.tsv）")
    return entries, meta


# ---------------------------------------------------------------------------
# 筛选
# ---------------------------------------------------------------------------

def filter_entries(entries: list[dict], args) -> tuple[list[dict], str]:
    """按命令行参数筛选建筑。返回 (筛选后的列表, 筛选说明)"""
    desc = []

    # 1) 按据点（baseCampId）
    if getattr(args, "camp", None):
        want = str(args.camp)
        before = len(entries)
        entries = [e for e in entries if (e.get("baseCampId") or "") == want]
        desc.append(f"据点 baseCampId={want} ({before} -> {len(entries)})")
        if not entries:
            die(f"没有属于据点 {want} 的建筑。先用 `camps` 子命令列出可用据点 ID")

    # 2) 按 ID 子串（方便手输短标识）
    if getattr(args, "match", None):
        sub = str(args.match)
        before = len(entries)
        entries = [e for e in entries
                   if sub in (e.get("baseCampId") or "")
                   or sub in (e.get("groupId") or "")
                   or sub in (e.get("ownerId") or "")]
        desc.append(f"ID 含 '{sub}' ({before} -> {len(entries)})")
        if not entries:
            die(f"没有 ID 含 '{sub}' 的建筑")

    # 3) 按坐标范围（单位米）
    box = getattr(args, "box", None)
    if box:
        try:
            parts = [float(v) for v in str(box).split(",")]
            if len(parts) != 6:
                raise ValueError("需要 6 个数")
            x0, y0, z0, x1, y1, z1 = parts
        except ValueError as exc:
            die(f"--box 格式错误（应为 x0,y0,z0,x1,y1,z1 六个数字）: {exc}")
        lo = [min(x0, x1), min(y0, y1), min(z0, z1)]
        hi = [max(x0, x1), max(y0, y1), max(z0, z1)]
        before = len(entries)
        entries = [e for e in entries
                   if all(lo[i] <= e["m"][i] <= hi[i] for i in range(3))]
        desc.append(f"坐标范围 [{lo[0]:.0f},{lo[1]:.0f},{lo[2]:.0f}]~"
                    f"[{hi[0]:.0f},{hi[1]:.0f},{hi[2]:.0f}] ({before} -> {len(entries)})")
        if not entries:
            die("该坐标范围内没有建筑")

    # 4) 按半径（围绕某个中心）
    radius = getattr(args, "radius", None)
    if radius is not None:
        center = getattr(args, "center", None)
        if center:
            try:
                c = [float(v) for v in str(center).split(",")]
                if len(c) != 3:
                    raise ValueError("需要 3 个数")
            except ValueError as exc:
                die(f"--center 格式错误（应为 x,y,z）: {exc}")
        else:
            # 没给中心就用当前集合的质心
            c = [sum(e["m"][i] for e in entries) / len(entries) for i in range(3)]
            info(f"未指定 --center，使用质心 {[round(v,1) for v in c]}")
        r = float(radius)
        before = len(entries)
        r2 = r * r
        entries = [e for e in entries
                   if sum((e["m"][i] - c[i]) ** 2 for i in range(3)) <= r2]
        desc.append(f"半径 {r:.0f} 米 @ [{c[0]:.0f},{c[1]:.0f},{c[2]:.0f}] "
                    f"({before} -> {len(entries)})")
        if not entries:
            die("该半径内没有建筑")

    # 5) 限制数量（取距中心最近的 N 个）
    limit = getattr(args, "limit", None)
    if limit:
        n = int(limit)
        if n < len(entries):
            c = [sum(e["m"][i] for e in entries) / len(entries) for i in range(3)]
            entries = sorted(
                entries,
                key=lambda e: sum((e["m"][i] - c[i]) ** 2 for i in range(3))
            )[:n]
            desc.append(f"限制为最近的 {n} 个")

    if not desc:
        desc.append(f"未筛选，全部 {len(entries)} 个")
    return entries, "; ".join(desc)


def load_entries(path: str) -> tuple[list[dict], dict]:
    """自动识别输入格式：PWRecon TSV 或 JSON。"""
    if path.lower().endswith((".tsv", ".txt")):
        return parse_pwbuild(path)

    with open(path, "r", encoding="utf-8-sig") as fh:
        data = json.load(fh)

    items = data.get("buildings") if isinstance(data, dict) else data
    if not isinstance(items, list) or not items:
        die("原始数据里没有建筑列表")

    meta = {"source": os.path.basename(path), "skipped": 0}
    entries = []
    for i, it in enumerate(items):
        if not isinstance(it, dict):
            die(f"第 {i} 条不是对象")
        t = it.get("type") or it.get("t") or it.get("MapObjectId")
        if not t:
            die(f"第 {i} 条缺少 type 字段")
        pos = (it.get("world_cm") or it.get("location") or it.get("pos")
               or it.get("p") or it.get("Position"))
        if not (isinstance(pos, list) and len(pos) >= 3):
            die(f"第 {i} 条缺少坐标（world_cm/location/pos）")
        unit = it.get("unit", "cm")
        scale = 1.0 if unit == "m" else CM_PER_M
        entries.append({
            "type": t,
            "m": [float(pos[0]) / scale, float(pos[1]) / scale, float(pos[2]) / scale],
            "yaw": float(it.get("yaw") or it.get("Yaw") or 0.0),
            "mesh": it.get("mesh"),
            "baseCampId": it.get("baseCampId"),
            "groupId": it.get("groupId"),
            "ownerId": it.get("ownerId"),
        })
    return entries, meta


# ---------------------------------------------------------------------------
# 子命令: camps —— 列出数据里的据点
# ---------------------------------------------------------------------------

def cmd_camps(args):
    head("数据里包含的据点")
    entries, meta = load_entries(args.input)
    info(f"总建筑数: {len(entries)}")

    groups: dict[str, list[dict]] = {}
    for e in entries:
        key = e.get("baseCampId") or "(无 baseCampId)"
        groups.setdefault(key, []).append(e)

    if len(groups) == 1 and "(无 baseCampId)" in groups:
        info("所有建筑的 baseCampId 都是空 —— 该字段在这个版本/存档里不可用，")
        info("请改用 --box / --radius 或用 `split` 按位置聚类。")
        return 0

    print()
    print(f"  {'据点 ID (baseCampId)':<44}{'建筑数':>7}  {'中心(米)':<28} 尺寸(米)")
    print("  " + "-" * 108)
    for key, items in sorted(groups.items(), key=lambda kv: -len(kv[1])):
        xs = [e["m"][0] for e in items]
        ys = [e["m"][1] for e in items]
        zs = [e["m"][2] for e in items]
        cx = sum(xs) / len(xs)
        cy = sum(ys) / len(ys)
        cz = sum(zs) / len(zs)
        size = (max(xs) - min(xs), max(ys) - min(ys), max(zs) - min(zs))
        print(f"  {key:<44}{len(items):>7}  "
              f"({cx:>8.0f},{cy:>8.0f},{cz:>7.0f})      "
              f"{size[0]:.0f}x{size[1]:.0f}x{size[2]:.0f}")
    print()
    print("  用 `raw <输入> --camp <据点ID> -o <输出>` 只导出某个据点。")
    return 0


def cmd_raw(args):
    head("从逐实例数据生成蓝图")
    entries, meta = load_entries(args.input)
    info(f"读入 {len(entries)} 个建筑实例（{meta.get('source')}）")
    if meta.get("header"):
        h = meta["header"]
        info(f"导出来源: mode={h.get('mode')} "
             f"center={h.get('center')} radius={h.get('radius')} "
             f"游戏内总数={h.get('total')}")
    if meta.get("skipped"):
        info(f"跳过无法解析的行: {meta['skipped']}")

    if args.split:
        return split_and_write(entries, args)

    entries, desc = filter_entries(entries, args)
    info(f"筛选: {desc}")
    if not entries:
        die("筛选后没有建筑")

    name = args.name or os.path.splitext(os.path.basename(args.input))[0]
    bp = build_blueprint(name, entries, meta_extra={"filter": desc})
    write_json(args.output, bp)
    info(f"已写出 {args.output}")
    print_summary(bp)
    return 0


def split_and_write(entries: list[dict], args) -> int:
    """按据点（若可用）或位置聚类拆成多个蓝图。"""
    groups: list[list[dict]] = []

    if args.by == "camp" or (args.by == "auto" and any(e.get("baseCampId") for e in entries)):
        bucket: dict[str, list[dict]] = {}
        for e in entries:
            bucket.setdefault(e.get("baseCampId") or "(unknown)", []).append(e)
        groups = list(bucket.values())
        info(f"按 baseCampId 拆分得到 {len(groups)} 组")
    else:
        idx = cluster_by_position(entries, args.threshold)
        groups = [[entries[i] for i in g] for g in idx]
        info(f"按位置聚类拆分得到 {len(groups)} 组（阈值 {args.threshold} 米）")

    outdir = args.outdir or os.path.dirname(os.path.abspath(args.output)) or "."
    os.makedirs(outdir, exist_ok=True)

    for gi, sub in enumerate(sorted(groups, key=lambda g: -len(g))):
        cx = sum(e["m"][0] for e in sub) / len(sub)
        cy = sum(e["m"][1] for e in sub) / len(sub)
        key = sub[0].get("baseCampId") or ""
        tag = f"_{key[-8:]}" if key else ""
        name = f"base_{gi+1}_{cx:.0f}_{cy:.0f}{tag}"
        bp = build_blueprint(name, sub)
        path = os.path.join(outdir, f"{name}.blueprint.json")
        write_json(path, bp)
        sz = bp["meta"]["size"]
        info(f"  {name}: {len(sub)} 件 / {bp['meta']['typeCount']} 种 / "
             f"{sz['x']:.0f}x{sz['y']:.0f}x{sz['z']:.0f} 米 -> {os.path.basename(path)}")

    # 顺便写一个合并文件（含全部）
    if args.also_all:
        bp = build_blueprint("all", entries)
        p = os.path.join(outdir, "all.blueprint.json")
        write_json(p, bp)
        info(f"  另写出合并文件 {os.path.basename(p)}（{len(entries)} 件）")
    return 0



def cmd_check(args):
    head("校验蓝图")
    bp = read_json(args.input)
    errors, warnings = check_blueprint(bp)
    info(f"文件: {args.input}")
    info(f"格式: {bp.get('$format')}  version={bp.get('version')}")
    info(f"建筑数: {len(bp.get('buildings') or [])}")
    print()
    if errors:
        print(f"  [错误] {len(errors)} 项")
        for e in errors[:40]:
            print(f"    - {e}")
    else:
        print("  [通过] 无错误")
    if warnings:
        print(f"  [警告] {len(warnings)} 项")
        for w in warnings[:40]:
            print(f"    - {w}")
    return 1 if errors else 0


def cmd_stats(args):
    head("蓝图统计")
    bp = read_json(args.input)
    m = bp.get("meta") or {}
    info(f"名称    : {m.get('name')}")
    info(f"创建时间: {m.get('createdAt')}")
    info(f"建筑总数: {m.get('total')}")
    info(f"类型数  : {m.get('typeCount')}")
    info(f"层数    : {m.get('layerCount')}")
    info(f"原点(米): {m.get('origin')}")
    info(f"尺寸(米): {m.get('size')}")

    stats = bp.get("stats") or {}
    types = stats.get("types") or {}
    if types:
        print()
        print(f"  {'类型':<34}{'数量':>6}  mesh")
        print("  " + "-" * 66)
        for t, d in list(types.items())[:40]:
            print(f"  {t:<34}{d.get('count', 0):>6}  {d.get('mesh') or '-'}")
        if len(types) > 40:
            print(f"  ... 其余 {len(types) - 40} 种")

    layers = stats.get("layers") or {}
    if layers:
        print()
        print(f"  {'层':>4}{'数量':>8}  Z 范围(相对) ")
        print("  " + "-" * 50)
        for L, d in sorted(layers.items(), key=lambda kv: int(kv[0])):
            print(f"  {L:>4}{d.get('count', 0):>8}  "
                  f"{d.get('z_min'):.1f} .. {d.get('z_max'):.1f}")
    return 0


# ---------------------------------------------------------------------------
# IO / 输出
# ---------------------------------------------------------------------------

def write_json(path: str, obj) -> None:
    d = os.path.dirname(os.path.abspath(path))
    if d:
        os.makedirs(d, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, ensure_ascii=False, indent=1)
        fh.write("\n")


def read_json(path: str):
    if not os.path.isfile(path):
        die(f"找不到文件: {path}")
    with open(path, "r", encoding="utf-8-sig") as fh:
        return json.load(fh)


def print_summary(bp: dict) -> None:
    m = bp["meta"]
    print()
    print(f"  建筑总数: {m['total']}    类型: {m['typeCount']}    层: {m['layerCount']}")
    print(f"  原点(米): {m['origin']}")
    print(f"  尺寸(米): {m['size']['x']} x {m['size']['y']} x {m['size']['z']}")
    print()
    print("  类型分布（前 12）:")
    for t, d in list(bp["stats"]["types"].items())[:12]:
        print(f"    {t:<34}{d['count']:>5}  {d.get('mesh') or '-'}")


# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

def main() -> int:
    p = argparse.ArgumentParser(
        description="Palworld 建筑蓝图格式工具",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("samples", help="从 recon_alltypes.txt（每类型一样本）生成蓝图")
    sp.add_argument("input")
    sp.add_argument("-o", "--output", default="blueprint.json")
    sp.add_argument("-n", "--name", default=None)
    sp.add_argument("--split", action="store_true", help="按位置聚类拆成多个基地")
    sp.add_argument("--outdir", default=None, help="--split 时的输出目录")
    sp.set_defaults(func=cmd_samples)

    sp = sub.add_parser("raw", help="从逐实例数据生成蓝图（支持筛选）")
    sp.add_argument("input", help="PWRecon 的 buildings_raw.tsv 或 JSON")
    sp.add_argument("-o", "--output", default="blueprint.json")
    sp.add_argument("-n", "--name", default=None)

    g = sp.add_argument_group("筛选（可组合，按顺序生效: camp -> match -> box -> radius -> limit）")
    g.add_argument("--camp", default=None,
                   help="只保留该 baseCampId 的建筑（用 camps 子命令列出）")
    g.add_argument("--match", default=None,
                   help="baseCampId/groupId/ownerId 含该子串的建筑")
    g.add_argument("--box", default=None, metavar="x0,y0,z0,x1,y1,z1",
                   help="坐标范围（米），只保留盒内的建筑")
    g.add_argument("--radius", type=float, default=None,
                   help="半径（米），配合 --center 使用")
    g.add_argument("--center", default=None, metavar="x,y,z",
                   help="--radius 的中心（米）；省略则用当前集合的质心")
    g.add_argument("--limit", type=int, default=None,
                   help="只保留距中心最近的 N 个")

    g2 = sp.add_argument_group("拆分输出")
    g2.add_argument("--split", action="store_true", help="拆成多个蓝图文件")
    g2.add_argument("--by", choices=["auto", "camp", "cluster"], default="auto",
                    help="拆分依据：auto=有据点用据点否则聚类；camp=按据点；cluster=按位置聚类")
    g2.add_argument("--threshold", type=float, default=CLUSTER_THRESHOLD_M,
                    help=f"位置聚类阈值（米），默认 {CLUSTER_THRESHOLD_M}")
    g2.add_argument("--outdir", default=None, help="拆分输出目录")
    g2.add_argument("--also-all", action="store_true", help="另外写出合并全部的文件")
    sp.set_defaults(func=cmd_raw)

    sp = sub.add_parser("camps", help="列出数据里包含的据点（用于 --camp）")
    sp.add_argument("input")
    sp.set_defaults(func=cmd_camps)

    sp = sub.add_parser("check", help="校验蓝图文件")
    sp.add_argument("input")
    sp.set_defaults(func=cmd_check)

    sp = sub.add_parser("stats", help="打印蓝图统计")
    sp.add_argument("input")
    sp.set_defaults(func=cmd_stats)

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
