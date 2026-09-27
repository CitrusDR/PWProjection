#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
meshmatch_sim.py -- 在真实数据上模拟"类型 -> 网格"匹配算法（离线验证）

为什么需要它
------------
Lua 跑不了，但匹配算法是纯逻辑 —— 可以在 Python 里原样模拟，
用【游戏里真实导出的数据】跑一遍，看清楚：

    · 结构件（地基/墙/屋顶…）到底能不能自动匹配上
    · 有没有误匹配（张冠李戴）
    · 哪些类型必须靠 actor 上的 mesh 或手写覆盖表

验证过之后再把规则移植到 pwbp_meshmap.lua，避免"改了 Lua 只能进游戏试"。

输入
----
    pwbp_meshes.txt    游戏里 FindAllOf("StaticMesh") 导出的注册表
    data/recon_alltypes.txt   79 种建筑类型的清单（含 recon 时读到的 mesh）

用法
----
    python tools/meshmatch_sim.py --meshes <pwbp_meshes.txt> \
                                  --types data/recon_alltypes.txt
"""

from __future__ import annotations

import argparse
import io
import json
import os
import re
import sys

# ---------------------------------------------------------------------------
# 归一化（与 Lua 侧 pwbp_meshmap.normalize 必须一致）
# ---------------------------------------------------------------------------

def normalize(s: str) -> str:
    return re.sub(r"[^a-z0-9]", "", s.lower())


CAMEL_RE = re.compile(r"[A-Z]+(?![a-z])|[A-Z][a-z0-9]*|[a-z0-9]+")


def camel_split(word: str) -> list:
    """WindowWall -> ['window','wall'] ; PalBoxV2 -> ['pal','box','v','2']"""
    return [w.lower() for w in CAMEL_RE.findall(word)]


VERSION_RE = re.compile(r"^v?\d+$")


def strip_version(word: str) -> str:
    w = re.sub(r"[Vv]\d+$", "", word)
    w = re.sub(r"_?\d\d?$", "", w)
    return w


# ---------------------------------------------------------------------------
# 语义同义词：蓝图类型名 vs 资产名 用词不同
#   实测：Palworld 的"地基"资产叫 SM_Floor_Wood（不是 Foundation）
# ---------------------------------------------------------------------------

SYNONYMS = {
    "foundation": "floor",   # Wood_Foundation  -> SM_Floor_Wood
    "doorwall": "door",      # Wood_DoorWall    -> SM_Door_Wood
    "windowwall": "window",  # 已经能被 camel 拆开，这里只作兜底
    "wallgate": "gate",
}


def apply_synonym(tok: str) -> str:
    return SYNONYMS.get(tok, tok)


# ---------------------------------------------------------------------------
# 排除关卡几何体
#   SM_pal_b00grass_Lodenfel_* / SM_Pal_b00_hurou_* 是地图场景资源，
#   不是玩家能造的建筑。留在候选里只会制造误匹配。
# ---------------------------------------------------------------------------

EXCLUDE_MARKERS = ("/stage/", "/maps/", "_b00", "lodenfel", "ztest")


def is_level_geometry(path: str) -> bool:
    p = path.lower()
    return any(m in p for m in EXCLUDE_MARKERS)


# ---------------------------------------------------------------------------
# 匹配（与 Lua 侧 MeshMap.match_by_name 的规则一一对应）
# ---------------------------------------------------------------------------

def type_keywords(type_name: str):
    """返回 (material, parts)"""
    words = []
    for chunk in type_name.split("_"):
        words.extend(camel_split(chunk))
    words = [w for w in words if w]

    if not words:
        return None, []

    material = apply_synonym(words[0])
    parts = []
    for w in words[1:]:
        if VERSION_RE.match(w):
            continue
        w = apply_synonym(w)
        if len(w) >= 3:
            parts.append(w)
    if not parts:
        # 全部关键词都是版本号（Spa_2 / ItemChest_03），
        # 或本来就是单词类型（CampFire）-> 用材料词当唯一关键词
        parts = [material]
    return material, parts


def match(type_name: str, meshes):
    """严格遵守三条规则的匹配，返回 (path, score, ties)

    规则（都是被真实数据教出来的）:
      1. 候选必须在 /Architecture/ 目录下。
         不加这条会匹配到 SM_IceBlock / SM_Electricity01 / SM_Relic_Monkey
         这种完全不相关的东西。
      2. 必须【严格】命中所有关键词 + 材料词。没有"放宽一轮"。
         放宽之后 HatchingPalEgg 会匹配到 SM_PalSpa —— 纯垃圾。
      3. 同分并列时取名字最短的；如果连长度都一样 -> 放弃（返回 nil）。
         宁可没有网格，也不要张冠李戴。
    """
    material, parts = type_keywords(type_name)
    if material is None or len(material) < 2:
        return None, 0, 0

    best, best_score, best_len, ties, same_len = None, 0, 0, 0, False
    for short, path, norm in meshes:
        if "/architecture/" not in path.lower():
            continue
        score = 0
        if material in norm:
            score += 2
        ok = True
        for p in parts:
            if p in norm:
                score += 3
            else:
                ok = False
        if not ok or score == 0:
            continue
        if score > best_score:
            best_score, best, best_len, ties, same_len = score, (short, path), len(norm), 1, False
        elif score == best_score:
            ties += 1
            if len(norm) < best_len:
                best, best_len, same_len = (short, path), len(norm), False
            elif len(norm) == best_len:
                same_len = True
    if best is None:
        return None, 0, 0
    if same_len and ties > 1:
        # 最短的也有并列 -> 无法确定，放弃
        return None, best_score, -1
    return best[1], best_score, ties


# ---------------------------------------------------------------------------
# 读数据
# ---------------------------------------------------------------------------

def load_meshes(path: str):
    meshes = []
    with io.open(path, encoding="utf-8-sig") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            m = re.match(r"^(\S+)\s+(/\S+)$", line)
            if not m:
                continue
            short, apath = m.group(1), m.group(2)
            if is_level_geometry(apath):
                continue
            meshes.append((short, apath, normalize(short)))
    return meshes


def load_types(path: str):
    """从 recon_alltypes.txt 里抓 (短类型名, 数量, recon 时的 mesh)

    实际行格式:
        Wood_Foundation   351  X=-161481.01 Y=-63697.72 Z=-942.94 -28.7   -
    """
    rows = []
    with io.open(path, encoding="utf-8-sig") as fh:
        for line in fh:
            parts = line.split()
            if len(parts) < 7:
                continue
            if not re.match(r"^\d+$", parts[1]):
                continue
            if not parts[2].startswith("X="):
                continue
            mesh = parts[-1]
            rows.append((parts[0], int(parts[1]), None if mesh == "-" else mesh))
    return rows


def load_overrides(path):
    """读 pwbp_meshmap.default.json / pwbp_meshmap.json 的有效条目。

    值可以是字符串，也可以是字符串数组（一个建筑由多个网格拼成，
    例如简约门 = 门框 + 左右门扇）。审计时统一取【列表】，
    但为兼容旧逻辑，这里把单值也包成列表再取第一个。
    """
    if not os.path.isfile(path):
        return {}
    with io.open(path, encoding="utf-8") as fh:
        d = json.load(fh)
    out = {}
    for k, v in d.items():
        if k.startswith("_"):
            continue
        if isinstance(v, str) and v:
            out[k] = v
        elif isinstance(v, list):
            vals = [x for x in v if isinstance(x, str) and x]
            if vals:
                out[k] = vals[0]
    return out


def by_short_all(meshes):
    """短名 -> 完整路径（actor 上读到的是短名，要还原成路径）"""
    d = {}
    for short, apath, _norm in meshes:
        d.setdefault(short, apath)
    return d


def resolve(t, actor_mesh, by_short, overrides, meshes):
    if actor_mesh and actor_mesh in by_short:
        return by_short[actor_mesh], "actor"
    if t in overrides:
        if overrides[t] == "-":
            return None, "suppressed(覆盖表写了-)"
        return overrides[t], "override"
    p, score, ties = match(t, meshes)
    if p is None:
        return None, ("refused(并列)" if ties == -1 else "none")
    return p, "name"


def load_blueprint_truth(directory):
    """从真实采集出来的蓝图里提取【游戏自己在 actor 上报告的网格】。

    这是目前最好的标准答案来源 —— 比 recon_alltypes.txt 更全：
      · 采集是玩家在基地里按 Y 触发的，样本就是真实基地
      · 每次采集覆盖一个基地，多采几次就覆盖多种类型
      · stats.types[t].mesh 是【游戏自己报的】，不是我们推的

    ★ 同时返回【出现过但没网格的类型】。
      这一点很重要: 审计必须拿"真实存在过的全部类型"去算，
      否则玩家新盖的类型根本不在清单里，审计就会漏报"画不出来"。
      （2026-09-26 实际踩到: 玩家加盖三层楼引入的结构件类型不在旧 recon 里，
        审计因此没报它们，看起来像"没问题"。）

    返回 (truth, all_types)
      truth     : type -> {"mesh": 短名, "count": 件数, "src": 文件名}
      all_types : set(所有出现过的类型名)
    """
    truth = {}
    all_types = set()
    if not directory or not os.path.isdir(directory):
        return truth, all_types
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".blueprint.json"):
            continue
        path = os.path.join(directory, name)
        try:
            with io.open(path, encoding="utf-8-sig") as fh:
                d = json.load(fh)
        except Exception:
            continue
        types = (d.get("stats") or {}).get("types") or {}
        for t, e in types.items():
            if not isinstance(e, dict):
                continue
            all_types.add(t)
            mesh = e.get("mesh")
            if not mesh:
                continue
            cur = truth.get(t)
            if cur is None or (e.get("count") or 0) > cur["count"]:
                truth[t] = {"mesh": mesh, "count": e.get("count") or 0,
                            "src": name}
    return truth, all_types


def main() -> int:
    ap = argparse.ArgumentParser()
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--meshes", default=None)
    ap.add_argument("--types", default=os.path.join(root, "data", "recon_alltypes.txt"))
    ap.add_argument("--extra-types", nargs="*", default=["Wood_Foundation",
                    "Wood_Wall_V2", "Wood_WindowWall", "Wood_DoorWall",
                    "Wood_Roof", "Wood_Stair", "Stone_WallGate"])
    ap.add_argument("--emit-overrides", action="store_true",
                    help="把 recon 时 actor 上【真实读到】的 mesh 输出成 "
                         "pwbp_meshmap.json 条目（这是实测记录，不是猜测）")
    ap.add_argument("--orphans", action="store_true",
                    help="列出 /Architecture/ 下没有任何类型用到的网格（孤儿资产），"
                         "用来判断'看不见的类型'到底是缺映射还是根本缺资产")
    ap.add_argument("--orphans-all", action="store_true",
                    help="同上，但范围放宽到 /Game/Pal/Model/Prop/ + /Other/")
    ap.add_argument("--audit", action="store_true",
                    help="用真实优先级链（actor > 覆盖表 > 名字匹配）逐类型"
                         "列出最终画什么，并列出【会完全看不见】的类型")
    ap.add_argument("--blueprints", default=None,
                    help="真实采集出来的蓝图目录（blueprints/）。"
                         "里面的 stats.types[].mesh 是【游戏自己报的网格】，"
                         "是比 recon 更好的标准答案来源。")
    ap.add_argument("--mapdir", default=None,
                    help="覆盖表所在目录（默认取 --meshes 所在目录）。"
                         "审计时通常要指向工作区里的 "
                         "mod/PWBlueprint/Scripts，而不是游戏里那份旧拷贝。")
    args = ap.parse_args()

    meshes_path = args.meshes
    if meshes_path is None:
        meshes_path = os.path.join(
            r"D:\Steam\steamapps\common\Palworld\Mods\NativeMods\UE4SS\Mods",
            "PWBlueprint", "Scripts", "pwbp_meshes.txt")

    meshes = load_meshes(meshes_path)
    print("候选网格（已排除关卡几何体）: {} 个".format(len(meshes)))

    rows = load_types(args.types)
    print("从 recon 读到类型: {} 个".format(len(rows)))

    known = {r[0]: r[2] for r in rows}

    # ---- 叠加真实采集里的游戏自报网格（更权威）--------------------------
    if args.blueprints:
        bp_truth, bp_all = load_blueprint_truth(args.blueprints)
        n_new = 0
        for t, e in bp_truth.items():
            if t not in known:
                n_new += 1
            known[t] = e["mesh"]
        # ★ 把【出现过但没网格的类型】也补进待审清单 ——
        #   否则玩家新盖的类型不在清单里，审计会漏报"画不出来"。
        #   （2026-09-26 实际踩到: 玩家加盖三层楼引入的结构件类型不在旧 recon 里，
        #    审计因此没报它们，看起来像"没问题"。）
        n_only = 0
        for t in sorted(bp_all):
            if t not in known:
                known[t] = None
                n_only += 1
        print("从蓝图采集补入游戏自报网格: {} 种（其中 {} 种 recon 里没有；"
              "另有 {} 种只有类型名、没有网格）"
              .format(len(bp_truth), n_new, n_only))

    names = list(dict.fromkeys(list(known.keys()) + args.extra_types))

    # ---- 孤儿资产: 注册表里有、但没有任何类型用到 -------------------------
    if args.orphans or args.orphans_all:
        sdir = args.mapdir or os.path.dirname(meshes_path)
        overrides = load_overrides(
            os.path.join(sdir, "pwbp_meshmap.default.json"))
        overrides.update(load_overrides(
            os.path.join(sdir, "pwbp_meshmap.json")))
        used = set()
        for v in overrides.values():
            if v and v != "-":
                used.add(normalize(v.rsplit("/", 1)[-1].split(".")[0]))
        name_used = set()
        for t in names:
            p, _s, _ti = match(t, meshes)
            if p:
                name_used.add(normalize(p.rsplit("/", 1)[-1].split(".")[0]))
            am = known.get(t)
            if am:
                used.add(normalize(am))

        # /Architecture/ 下的全部 vs 更宽的 /Prop/ + /Other/
        if args.orphans_all:
            roots = ("/game/pal/model/prop/", "/game/pal/model/other/")
            skip = ("/prop/resource/", "/prop/furniture/", "/prop/bread/",
                    "/prop/meat/", "/prop/mug/")
            title = "/Game/Pal/Model/Prop/ + /Other/（排除 Resource/Furniture 等非建筑）"
        else:
            roots = ("/architecture/",)
            skip = ()
            title = "/Architecture/"

        print("=== {} 下【没有任何类型用到】的网格（孤儿）===".format(title))
        print("（如果那 13 个看不见的类型里有哪个的网格存在，就会出现在这里）")
        print()
        orphans, total = [], 0
        for short, apath, norm in meshes:
            low = apath.lower()
            if not any(r in low for r in roots):
                continue
            if any(s in low for s in skip):
                continue
            total += 1
            if norm in used or norm in name_used:
                continue
            orphans.append(short)
        for s in sorted(orphans):
            print("  " + s)
        print()
        print("孤儿 {} / {} 个".format(len(orphans), total))
        return 0

    # ---- 真·优先级链审计 ------------------------------------------------
    if args.audit:
        sdir = args.mapdir or os.path.dirname(meshes_path)
        print("覆盖表目录: {}".format(sdir))
        overrides = load_overrides(
            os.path.join(sdir, "pwbp_meshmap.default.json"))
        overrides.update(load_overrides(
            os.path.join(sdir, "pwbp_meshmap.json")))
        print("覆盖表条目: {} 条".format(len(overrides)))
        print()
        print("{:<36} {:<32} {:<18} {}".format(
            "类型", "最终画什么", "来源", "对照 actor 真值"))
        print("-" * 112)
        invisible, wrong = [], []
        for t in names:
            actor_mesh = known.get(t)
            path, src = resolve(t, actor_mesh, by_short_all(meshes),
                                overrides, meshes)
            short = path.rsplit("/", 1)[-1].split(".")[0] if path else "-"
            if path is None:
                note = "**会完全看不见**"
                invisible.append((t, src))
            elif actor_mesh:
                if normalize(actor_mesh) == normalize(short):
                    note = "一致"
                else:
                    note = "!! 与 actor 真值不同: {}".format(actor_mesh)
                    wrong.append((t, actor_mesh, short, src))
            else:
                note = "(actor 无网格，无从对照)"
            print("{:<36} {:<32} {:<18} {}".format(t, short, src, note))

        print("-" * 112)
        print()
        print("=== 会完全看不见的类型（无 actor 网格 + 无覆盖表 + 名字匹配拒绝）===")
        if invisible:
            for t, src in invisible:
                print("  {:<36} ({})".format(t, src))
        else:
            print("  无")
        print()
        print("=== 与 actor 真值不一致 ===")
        if wrong:
            for t, truth, mine, src in wrong:
                print("  {:<34} 真值={:<28} 我们={:<26} 来源={}".format(
                    t, truth, mine, src))
        else:
            print("  无")
        return 0

    # ---- 生成覆盖表条目 --------------------------------------------------
    if args.emit_overrides:
        by_short = by_short_all(meshes)
        sdir = args.mapdir or os.path.dirname(meshes_path)
        cur = load_overrides(os.path.join(sdir, "pwbp_meshmap.default.json"))
        cur.update(load_overrides(os.path.join(sdir, "pwbp_meshmap.json")))

        new_entries, conflicts, same = [], [], 0
        for t in sorted(known):
            mesh = known[t]
            if not mesh:
                continue
            apath = by_short.get(mesh)
            if apath is None:
                continue
            if t not in cur:
                new_entries.append((t, apath))
            elif cur[t] != apath and cur[t] != "-":
                conflicts.append((t, cur[t], apath))
            else:
                same += 1

        print()
        print("=== ★ 新增（实测网格，覆盖表里还没有）{} 条 ===".format(
            len(new_entries)))
        for t, p in new_entries:
            print('  "{}": "{}",'.format(t, p))
        print()
        print("=== ★ 冲突（覆盖表里的值和实测不一致 —— 说明我们猜错了）{} 条 ==="
              .format(len(conflicts)))
        for t, old, truth in conflicts:
            print("  {:<28} 我们的={:<30} 实测={}".format(
                t, old.rsplit("/", 1)[-1], truth.rsplit("/", 1)[-1]))
        print()
        print("=== 与实测一致 {} 条 ===".format(same))
        return 0

    names = list(dict.fromkeys(list(known.keys()) + args.extra_types))

    hit, miss, refused = [], [], []
    agree, disagree, no_truth = [], [], []
    print()
    print("{:<36} {:>5} {:<32} {:<6} {}".format(
        "类型", "数量", "自动匹配到的网格", "分数", "对照 actor 上的真实网格"))
    print("-" * 112)
    for t in names:
        path, score, ties = match(t, meshes)
        short = path.rsplit("/", 1)[-1].split(".")[0] if path else "-"
        truth = known.get(t)
        if path is None:
            if ties == -1:
                refused.append(t)
                note = "并列无法判定 -> 放弃（正确行为）"
            else:
                miss.append(t)
                note = "未匹配"
        else:
            hit.append((t, short))
            if truth:
                if normalize(truth) == normalize(short):
                    note = "一致  {}".format(truth)
                    agree.append(t)
                else:
                    note = "!! 不一致  真实={}  我们={}".format(truth, short)
                    disagree.append((t, truth, short))
            else:
                note = "（该类型 actor 上读不到网格，无从对照）"
                no_truth.append(t)
        print("{:<36} {:>5} {:<32} {:<6} {}".format(
            t, known.get(t) or 0, short, score, note))

    print("-" * 112)
    print("匹配上 {} / 放弃（并列）{} / 未匹配 {}".format(
        len(hit), len(refused), len(miss)))
    print()
    print("=== 准确性（只统计 actor 上读得到网格的类型）===")
    print("  与真实网格【一致】: {} 个".format(len(agree)))
    print("  与真实网格【不一致】: {} 个  <- 这些是误匹配".format(len(disagree)))
    for t, truth, mine in disagree:
        print("      {:<34} 真实={:<28} 我们={}".format(t, truth, mine))
    print("  actor 上读不到、无法对照的: {} 个".format(len(no_truth)))
    print()
    print("=== 未匹配（需要 actor mesh 或手写覆盖表）===")
    for t in miss:
        print("  {:<36} (actor mesh: {})".format(t, known.get(t) or "-"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
