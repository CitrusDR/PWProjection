#!/usr/bin/env python3
"""建筑吸附算法的离线验证（合成数据）。

为什么要这个工具
================
`pwpr_snap.lua` 是"投票 + 复核"的启发式算法，**错了不会崩、只会把投影挪到
错地方** —— 而验证它必须在游戏里跑一轮（玩家要花时间部署+进游戏+按键+发日志）。
所以先在合成数据上把算法跑通，再去实机。

本机**没有 Lua 解释器**（UE4SS 内嵌的那个没法单独调用），所以这里是
`pwpr_snap.lua` 算法的 **Python 复刻**。复刻有走样的风险，于是加了两道防线:

  ① 常量防漂移: 脚本会**读 `pwpr_snap.lua` 原文**，把 VOTE_CELL_CM /
     YAW_BUCKET / YAW_TOL / MAX_YAW_CAND / MAX_OFFSET_PEAK 抽出来，
     和本文件顶部的同名常量比对（不一致直接报错）。
  ② 结构防漂移: 脚本会检查 Lua 文件里仍然存在关键函数/关键表达式
     （见 REQUIRED_LUA_SNIPPETS）—— 改了 Lua 侧的结构就该来改这里。

结论写进 `docs\\踩坑记录.md`：算法在哪些情形下可靠、哪些情形下有已知局限。

用法:
    python tools/snap_sim.py            # 跑全部场景
    python tools/snap_sim.py -v         # 额外打印每步日志
退出码: 0 = 全部通过, 1 = 有场景失败
"""
import math
import os
import random
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LUA = os.path.join(ROOT, "mod", "PWProjection", "Scripts", "pwpr_snap.lua")

# ---- 本文件复刻用的常量（必须和 pwpr_snap.lua 一致，见脚本头 ①）-----------
VOTE_CELL_CM = 25.0
YAW_BUCKET = 5.0
YAW_TOL = 10.0
MAX_YAW_CAND = 3
MAX_OFFSET_PEAK = 2
SEED_MAX = 30
SCORE_SAMPLES = 120
FINAL_VERIFY = 3
DEDUP_CM = 50.0

# ---- 结构防漂移: Lua 侧必须仍然有这些东西（见脚本头 ②）------------------
REQUIRED_LUA_SNIPPETS = [
    "function Snap.solve(bp, place0, opts)",
    "function Snap.gather(cx, cy, cz, radius_cm)",
    "function Snap.read_anchor(obj)",
    "function Snap.measure_grid(anchors, min_cm, max_cm)",
    "local function match_pairs(recs, ancs, place, yaw, radius_cm, stride)",
    "local function yaw_candidates(matched, yaw_now, search)",
    "local function offset_peaks(matched, yaw, want)",
    "local function build_grid(indexed, cell)",
    "local function nearest_grid(g, t, x, y, z)",
    "local function pick_score_samples(recs, ancs, max)",
    "local function score_samples(samples, grid, place, yaw)",
    "local function seed_candidates(matched, ancs, yaw, want)",
    # 核心几何关系: "让第 k 件落在参照 a 上 ⇒ place = a - R(yaw)·rel"
    "local px = p.a.x - (p.r.x * c - p.r.y * s)",
    "local py = p.a.y - (p.r.x * s + p.r.y * c)",
    "local pz = p.a.z - p.r.z",
    # 蓝图里一条记录的世界位置 = place + R(place.yaw)·rel
    "local wx = place.x + (r.x * c - r.y * s)",
    "local wy = place.y + (r.x * s + r.y * c)",
    "local wz = place.z + r.z",
]


# ==========================================================================
# 0. 防漂移检查
# ==========================================================================
def check_no_drift(verbose=False):
    src = open(LUA, encoding="utf-8").read()
    bad = []
    for name, mine in (("VOTE_CELL_CM", VOTE_CELL_CM), ("YAW_BUCKET", YAW_BUCKET),
                       ("YAW_TOL", YAW_TOL), ("MAX_YAW_CAND", MAX_YAW_CAND),
                       ("MAX_OFFSET_PEAK", MAX_OFFSET_PEAK)):
        m = re.search(r"^Snap\.%s\s*=\s*([0-9.]+)" % name, src, re.M)
        if m is None:
            bad.append("Lua 里找不到 Snap.%s" % name)
            continue
        if abs(float(m.group(1)) - mine) > 1e-9:
            bad.append("Snap.%s: Lua=%s 本脚本=%s ⇒ 两边不一致，请同步"
                       % (name, m.group(1), mine))
    for snip in REQUIRED_LUA_SNIPPETS:
        if snip not in src:
            bad.append("Lua 里找不到这段结构（算法可能改了）: %s" % snip)
    if bad:
        print("[严重] 防漂移检查失败:")
        for b in bad:
            print("   -", b)
        print("  ⇒ 本脚本是 pwpr_snap.lua 的复刻；Lua 侧改了算法，就必须来改这里。")
        return False
    if verbose:
        print("  防漂移检查通过（%d 个常量 + %d 段结构）"
              % (5, len(REQUIRED_LUA_SNIPPETS)))
    return True


# ==========================================================================
# 1. 算法复刻（对应 pwpr_snap.lua 的函数）
# ==========================================================================
def dist2(ax, ay, az, bx, by, bz):
    dx, dy, dz = ax - bx, ay - by, az - bz
    return dx * dx + dy * dy + dz * dz


def nearest(x, y, z, lst, r2):
    best, bestd = None, r2
    for a in lst:
        d = dist2(a["x"], a["y"], a["z"], x, y, z)
        if d <= bestd:
            bestd, best = d, a
    if best is None:
        return None
    return best, math.sqrt(bestd)


def index_anchors(anchors):
    out = {}
    for a in anchors:
        out.setdefault(a["t"], []).append(a)
    return out


def index_records(bp):
    out, total = {}, 0
    for b in bp["buildings"]:
        rx, ry, rz = b["p"][0] * 100.0, b["p"][1] * 100.0, b["p"][2] * 100.0
        out.setdefault(b["t"], []).append(
            {"x": rx, "y": ry, "z": rz, "yaw": b["yaw"]})
        total += 1
    return out, total


def plan_stride(recs, ancs, budget=1500000):
    types, total = [], 0
    for t, rl in recs.items():
        al = ancs.get(t)
        if al:
            types.append((t, len(rl), len(al)))
            total += len(rl) * len(al)
    stride = {}
    if total <= budget or not types:
        for t, _, _ in types:
            stride[t] = 1
        return stride, total
    per_type = max(budget // len(types), 1)
    est = 0
    for t, nr, na in types:
        work = nr * na
        s = 1 if work <= per_type else min(math.ceil(work / per_type), nr)
        stride[t] = s
        est += math.ceil(nr / s) * na
    return stride, est


def match_pairs(recs, ancs, place, yaw, radius_cm, stride):
    rad = math.radians(yaw)
    c, s = math.cos(rad), math.sin(rad)
    r2 = radius_cm * radius_cm
    out = []
    for t, rl in recs.items():
        al = ancs.get(t)
        if al is None:
            continue
        st = stride.get(t, 1)
        for i in range(0, len(rl), st):
            r = rl[i]
            wx = place["x"] + (r["x"] * c - r["y"] * s)
            wy = place["y"] + (r["x"] * s + r["y"] * c)
            wz = place["z"] + r["z"]
            got = nearest(wx, wy, wz, al, r2)
            if got is not None:
                out.append({"r": r, "a": got[0], "d": got[1]})
    return out


def norm_yaw(d):
    d = (d or 0.0) % 360.0
    if d > 180.0:
        d -= 360.0
    return d


def yaw_candidates(matched, yaw_now, search):
    buckets = {}
    for p in matched:
        y = norm_yaw(p["a"]["yaw"] - p["r"]["yaw"])
        key = math.floor((y + 180.0) / YAW_BUCKET)
        b = buckets.setdefault(key, {"n": 0, "sum": 0.0, "key": key})
        b["n"] += 1
        b["sum"] += y
    lst = []
    for b in buckets.values():
        b["avg"] = norm_yaw(b["sum"] / b["n"])
        lst.append(b)
    lst.sort(key=lambda b: (-b["n"], b["key"]))
    out = [yaw_now]
    if search:
        for b in lst:
            if len(out) >= MAX_YAW_CAND:
                break
            if all(abs(norm_yaw(b["avg"] - o)) >= YAW_TOL for o in out):
                out.append(b["avg"])
    return out, lst


def offset_peaks(matched, yaw, want=MAX_OFFSET_PEAK):
    rad = math.radians(yaw)
    c, s = math.cos(rad), math.sin(rad)
    cell = VOTE_CELL_CM
    votes = {}
    for p in matched:
        px = p["a"]["x"] - (p["r"]["x"] * c - p["r"]["y"] * s)
        py = p["a"]["y"] - (p["r"]["x"] * s + p["r"]["y"] * c)
        pz = p["a"]["z"] - p["r"]["z"]
        key = (math.floor(px / cell), math.floor(py / cell), math.floor(pz / cell))
        v = votes.setdefault(key, {"n": 0, "sx": 0.0, "sy": 0.0, "sz": 0.0})
        v["n"] += 1
        v["sx"] += px
        v["sy"] += py
        v["sz"] += pz
    allp = [{"n": v["n"], "x": v["sx"] / v["n"], "y": v["sy"] / v["n"],
             "z": v["sz"] / v["n"]} for v in votes.values()]
    allp.sort(key=lambda p: (-p["n"], p["x"], p["y"], p["z"]))
    out = []
    min_gap = max(cell * 3.0, 100.0)
    for p in allp:
        if all(dist2(p["x"], p["y"], p["z"], q["x"], q["y"], q["z"]) >= min_gap ** 2
               for q in out):
            out.append(p)
            if len(out) >= want:
                break
    return out


def build_grid(indexed, cell):
    g = {"cell": cell, "by_type": {}}
    for t, lst in indexed.items():
        tg = g["by_type"].setdefault(t, {})
        for a in lst:
            cx, cy, cz = (math.floor(a["x"] / cell), math.floor(a["y"] / cell),
                          math.floor(a["z"] / cell))
            tg.setdefault(cx, {}).setdefault(cy, {}).setdefault(cz, []).append(a)
    return g


def nearest_grid(g, t, x, y, z):
    tg = g["by_type"].get(t)
    if tg is None:
        return None
    cell = g["cell"]
    cx0, cy0, cz0 = (math.floor(x / cell), math.floor(y / cell),
                     math.floor(z / cell))
    best, bestd = None, cell * cell
    for dx in (-1, 0, 1):
        lx = tg.get(cx0 + dx)
        if lx is None:
            continue
        for dy in (-1, 0, 1):
            ly = lx.get(cy0 + dy)
            if ly is None:
                continue
            for dz in (-1, 0, 1):
                for a in ly.get(cz0 + dz, ()):
                    d = dist2(a["x"], a["y"], a["z"], x, y, z)
                    if d <= bestd:
                        bestd, best = d, a
    if best is None:
        return None
    return best, math.sqrt(bestd)


def verify(recs, g, place, yaw):
    rad = math.radians(yaw)
    c, s = math.cos(rad), math.sin(rad)
    matched, total, sumd = 0, 0, 0.0
    for t, rl in recs.items():
        for r in rl:
            total += 1
            wx = place["x"] + (r["x"] * c - r["y"] * s)
            wy = place["y"] + (r["x"] * s + r["y"] * c)
            wz = place["z"] + r["z"]
            got = nearest_grid(g, t, wx, wy, wz)
            if got is not None:
                matched += 1
                sumd += got[1]
    return matched, total, (sumd / matched if matched else None)


def pick_score_samples(recs, ancs, max_n):
    """对应 pick_score_samples: 优先挑"附近同类参照最少"的类型（最分得清对错）。"""
    types = sorted(
        ((t, len(rl), len(ancs.get(t, ()))) for t, rl in recs.items()),
        key=lambda e: (e[2] * 1000 + e[1], e[0]))
    out, rest = [], []
    for t, nr, na in types:
        rl = recs[t]
        if len(out) + len(rl) <= max_n:
            out.extend({"t": t, "r": r} for r in rl)
        else:
            rest.append((t, nr, na))
    if len(out) < max_n:
        need = max_n - len(out)
        total = sum(nr for _, nr, _ in rest)
        step = max(1, total // need)
        taken = 0
        for t, nr, _ in rest:
            rl = recs[t]
            j = 0
            while j < len(rl) and taken < need:
                out.append({"t": t, "r": rl[j]})
                taken += 1
                j += step
            if taken >= need:
                break
    return out


def score_samples(samples, grid, place, yaw):
    rad = math.radians(yaw)
    c, s = math.cos(rad), math.sin(rad)
    m = 0
    for e in samples:
        r = e["r"]
        wx = place["x"] + (r["x"] * c - r["y"] * s)
        wy = place["y"] + (r["x"] * s + r["y"] * c)
        wz = place["z"] + r["z"]
        if nearest_grid(grid, e["t"], wx, wy, wz) is not None:
            m += 1
    return m, len(samples)


def seed_candidates(matched, ancs, yaw, want):
    """对应 seed_candidates: 由"最可信的几对"直接给出精确候选。"""
    ranked = sorted(matched, key=lambda p: (len(ancs.get(p["a"]["t"], ())),
                                            p["r"]["x"], p["r"]["y"], p["r"]["z"]))
    rad = math.radians(yaw)
    c, s = math.cos(rad), math.sin(rad)
    out = []
    for p in ranked[:want]:
        out.append({"x": p["a"]["x"] - (p["r"]["x"] * c - p["r"]["y"] * s),
                    "y": p["a"]["y"] - (p["r"]["x"] * s + p["r"]["y"] * c),
                    "z": p["a"]["z"] - p["r"]["z"],
                    "na": len(ancs.get(p["a"]["t"], ()))})
    return out


def solve(bp, place0, anchors, radius_cm=2000.0, verify_cm=150.0,
          min_matches=3, yaw_search=True, verbose=False):
    """对应 Snap.solve —— anchors 相当于 Snap.gather 的产物（引擎那步在这里被喂数据）。"""
    def log(s):
        if verbose:
            print("      " + s)

    yaw0 = place0.get("yaw", 0.0)
    # gather 半径（这里只用来过滤喂进来的 anchors，和 Lua 侧一致）
    size = bp["meta"]["size"]
    half_diag = 0.5 * math.sqrt((size["x"] * 100) ** 2 + (size["y"] * 100) ** 2
                                + (size["z"] * 100) ** 2)
    gather_r = half_diag + radius_cm + 200.0
    anchors = [a for a in anchors
               if dist2(a["x"], a["y"], a["z"], place0["x"], place0["y"],
                        place0["z"]) <= gather_r * gather_r]
    if not anchors:
        return None, "半径内没有任何建筑", None
    log("参照 %d 件（收集半径 %.0f 米）" % (len(anchors), gather_r / 100.0))

    ancs = index_anchors(anchors)
    recs, n_rec = index_records(bp)
    grid = build_grid(ancs, verify_cm)
    shared = sum(len(rl) for t, rl in recs.items() if t in ancs)
    if shared == 0:
        return None, "附近没有一件和蓝图同类型", None
    stride, est = plan_stride(recs, ancs)
    log("蓝图 %d 件; 同类可比 %d 件; 预计比较 %d 次" % (n_rec, shared, est))

    pairs0 = match_pairs(recs, ancs, place0, yaw0, radius_cm, stride)
    if not pairs0:
        return None, "阈值内找不到同类型的原建筑", None
    yaws, yaw_votes = yaw_candidates(pairs0, yaw0, yaw_search)
    log("第 1 轮配对 %d 对; 朝向候选 %s"
        % (len(pairs0), ["%.1f" % y for y in yaws]))
    log("朝向票: " + ", ".join("%.1f度(%d票)" % (b["avg"], b["n"])
                              for b in yaw_votes[:3]))

    samples = pick_score_samples(recs, ancs, SCORE_SAMPLES)
    log("打分样本 %d 条" % len(samples))

    scored = []
    for y in yaws:
        pr = pairs0 if y == yaw0 else match_pairs(recs, ancs, place0, y,
                                                 radius_cm, stride)
        if not pr:
            continue
        cands = seed_candidates(pr, ancs, y, SEED_MAX)
        n_seed = len(cands)
        for pk in offset_peaks(pr, y):
            cands.append({"x": pk["x"], "y": pk["y"], "z": pk["z"],
                          "peak": pk["n"]})
        for ci, cd in enumerate(cands):
            place = {"x": cd["x"], "y": cd["y"], "z": cd["z"], "yaw": y}
            sc, _ = score_samples(samples, grid, place, y)
            scored.append({"place": place, "yaw": y, "score": sc,
                           "src": "可信对" if ci < n_seed else "投票高峰"})
    if not scored:
        return None, "一个候选都算不出来", None

    scored.sort(key=lambda e: (-e["score"], e["place"]["x"], e["place"]["y"],
                               e["place"]["z"]))
    log("候选 %d 个; 粗筛前 5: " % len(scored)
        + " | ".join("%s 朝向%.1f (%.0f,%.0f,%.0f) %d"
                     % (e["src"], e["yaw"], e["place"]["x"], e["place"]["y"],
                        e["place"]["z"], e["score"]) for e in scored[:5]))

    final, checked = [], []
    for e in scored:
        if any(dist2(e["place"]["x"], e["place"]["y"], e["place"]["z"],
                     f["x"], f["y"], f["z"]) < DEDUP_CM ** 2 for f in final):
            continue
        final.append(e["place"])
        m, total, md = verify(recs, grid, e["place"], e["yaw"])
        log("复核 %s 朝向 %.1f (%.0f,%.0f,%.0f) → %d/%d"
            % (e["src"], e["yaw"], e["place"]["x"], e["place"]["y"],
               e["place"]["z"], m, total))
        checked.append({"place": e["place"], "yaw": e["yaw"], "matched": m,
                        "total": total, "mean_d": md, "src": e["src"]})
        if len(final) >= FINAL_VERIFY:
            break
    if not checked:
        return None, "算不出偏移", None
    checked.sort(key=lambda c: -c["matched"])
    best = checked[0]
    best["margin"] = best["matched"] - (checked[1]["matched"] if len(checked) > 1 else 0)
    best["ambiguous"] = (len(checked) > 1
                         and best["margin"] <= max(2, int((best["total"] or 0) * 0.02)))
    best["ratio"] = (best["matched"] / best["total"]) if best["total"] else 0.0
    best["low_coverage"] = best["ratio"] < 0.8

    refine_r = min(radius_cm, max(verify_cm * 3.0, 300.0))
    pr2 = match_pairs(recs, ancs, best["place"], best["yaw"], refine_r, stride)
    if pr2:
        pk2 = offset_peaks(pr2, best["yaw"], 1)
        if pk2:
            cand = {"x": pk2[0]["x"], "y": pk2[0]["y"], "z": pk2[0]["z"],
                    "yaw": best["yaw"]}
            m2, t2, md2 = verify(recs, grid, cand, best["yaw"])
            log("精修 %.0f 米内配对 %d 对 → 复核 %d/%d" % (refine_r / 100.0,
                                                        len(pr2), m2, t2))
            if m2 >= best["matched"]:
                best.update({"place": cand, "matched": m2, "total": t2,
                             "mean_d": md2, "refined": True})
    if best["matched"] < min_matches:
        return None, "只对上 %d 件（至少 %d 件）" % (best["matched"], min_matches), best

    best["anchors"] = len(anchors)
    best["records"] = n_rec
    best["yaw_before"] = yaw0
    best["yaw_after"] = norm_yaw(best["yaw"])
    best["yaw_delta"] = norm_yaw(best["yaw_after"] - yaw0)
    best["dx"] = best["place"]["x"] - place0["x"]
    best["dy"] = best["place"]["y"] - place0["y"]
    best["dz"] = best["place"]["z"] - place0["z"]
    best["shift_cm"] = math.sqrt(best["dx"] ** 2 + best["dy"] ** 2 + best["dz"] ** 2)
    return best, None, None


# ==========================================================================
# 2. 合成数据（对应游戏里的"基地"与"蓝图"）
# ==========================================================================
def make_base(seed=7, spacing=400.0, n=10, damaged=0.0, drop_facilities=False):
    """造一个基地: 地基网格 + 四面墙 + 一堆唯一的机器/设施。

    返回 actors = [ {t,x,y,z,yaw}, ... ]（世界厘米 + 度）
    """
    rnd = random.Random(seed)
    actors = []
    # 地基: 格状排列（4 米一格）—— 这就是"格状对称"的来源
    for i in range(n):
        for j in range(n):
            actors.append({"t": "Wood_Foundation",
                           "x": i * spacing, "y": j * spacing, "z": 100.0,
                           "yaw": 0.0})
    # 墙: 沿四周
    for i in range(n):
        for (x, y, yaw) in ((i * spacing, 0.0, 0.0), (i * spacing, (n - 1) * spacing, 0.0),
                            (0.0, i * spacing, 90.0), ((n - 1) * spacing, i * spacing, 90.0)):
            actors.append({"t": "Wood_Wall", "x": x, "y": y, "z": 100.0,
                           "yaw": yaw})
    # 设施: 位置刻意不对称（随机但固定种子）—— 它们是"分出胜负"的证据
    if not drop_facilities:
        kinds = ["Pulverizer", "StoneMill", "Furnace", "BreedFarm", "WorkBench",
                 "Crusher", "AssemblyLine", "PalBox", "FeedBox", "RepairBench",
                 "Kitchen", "MedBox"]
        for k in kinds:
            actors.append({"t": "BP_Facility_" + k,
                           "x": rnd.uniform(0.0, (n - 1) * spacing),
                           "y": rnd.uniform(0.0, (n - 1) * spacing),
                           "z": 100.0,
                           "yaw": rnd.choice([0.0, 90.0, 180.0, 270.0])})
    if damaged > 0.0:
        keep = []
        for a in actors:
            if a["t"] == "BP_Facility_PalBox" or rnd.random() >= damaged:
                keep.append(a)
        actors = keep
    return actors


def make_blueprint(actors, snap_m=1.0):
    """对应 pwpr_bp.lua 的 BP.build（只保留 sim 需要的部分）。"""
    minx = min(a["x"] for a in actors)
    maxx = max(a["x"] for a in actors)
    miny = min(a["y"] for a in actors)
    maxy = max(a["y"] for a in actors)
    minz = min(a["z"] for a in actors)
    maxz = max(a["z"] for a in actors)
    sc = snap_m * 100.0
    cx = math.floor(((minx + maxx) * 0.5) / sc) * sc
    cy = math.floor(((miny + maxy) * 0.5) / sc) * sc
    cz = math.floor(((minz + maxz) * 0.5) / sc) * sc
    buildings = []
    for a in actors:
        buildings.append({
            "t": a["t"],
            "p": [round((a["x"] - cx) / 100.0, 3),
                  round((a["y"] - cy) / 100.0, 3),
                  round((a["z"] - cz) / 100.0, 3)],
            "yaw": round(norm_yaw(a["yaw"]), 2),
        })
    return {"meta": {"total": len(buildings),
                     "size": {"x": (maxx - minx) / 100.0,
                              "y": (maxy - miny) / 100.0,
                              "z": (maxz - minz) / 100.0}},
            "buildings": buildings}, {"x": cx, "y": cy, "z": cz}


# ==========================================================================
# 3. 场景
# ==========================================================================
def scenario(name, bp, truth, place0, anchors, expect_offset_cm=None,
             expect_yaw=None, expect_fail=False, verbose=False, **kw):
    print("-" * 74)
    print("场景: %s" % name)
    res, err, _ = solve(bp, place0, anchors, verbose=verbose, **kw)
    if expect_fail:
        if res is None:
            print("  [通过] 按预期失败: %s" % err)
            return True
        print("  [失败] 本该失败，却给出了结果: 对上 %d/%d" % (res["matched"], res["total"]))
        return False
    if res is None:
        print("  [失败] 求解失败: %s" % err)
        return False

    # 与"真值"比: 真值位置 = 原基地的包围盒中心
    ex = truth["x"] - res["place"]["x"]
    ey = truth["y"] - res["place"]["y"]
    ez = truth["z"] - res["place"]["z"]
    e = math.sqrt(ex * ex + ey * ey + ez * ez)
    print("  对上 %d/%d 件（平均差 %.1f 厘米）; 移动 %.0f 厘米; 朝向 %.1f° → %.1f°%s%s"
          % (res["matched"], res["total"], res["mean_d"] or -1, res["shift_cm"],
             res["yaw_before"], res["yaw_after"],
             "  ⚠置信度低(差 %d 件)" % res["margin"] if res.get("ambiguous") else "",
             "  ⚠匹配率低(%.0f%%)" % (res["ratio"] * 100) if res.get("low_coverage") else ""))
    print("  与真值的偏差: (%.1f, %.1f, %.1f) 厘米 ⇒ %.1f 厘米" % (ex, ey, ez, e))
    ok = True
    if expect_offset_cm is not None and e > expect_offset_cm:
        print("  [失败] 偏差 %.1f 厘米 > 允许 %.1f 厘米" % (e, expect_offset_cm))
        ok = False
    if expect_yaw is not None and abs(norm_yaw(res["yaw_after"] - expect_yaw)) > 1.0:
        print("  [失败] 朝向 %.1f° != 期望 %.1f°" % (res["yaw_after"], expect_yaw))
        ok = False
    if ok:
        print("  [通过]")
    return ok


def main():
    verbose = "-v" in sys.argv
    print("=" * 74)
    print("建筑吸附算法验证（合成数据）")
    print("=" * 74)
    if not check_no_drift(verbose):
        return 1

    results = []

    # ---- 场景 1: 基地完好，站在基地中心附近（投影只差一点）----
    base = make_base()
    bp, truth = make_blueprint(base)
    place0 = {"x": truth["x"] + 300.0, "y": truth["y"] - 200.0,
              "z": truth["z"] + 90.0, "yaw": 0.0}
    results.append(scenario("基地完好 / 站在中心附近（差 3.7 米）", bp, truth,
                            place0, base, expect_offset_cm=30.0,
                            expect_yaw=0.0, verbose=verbose))

    # ---- 场景 2: 站在基地边上（差 15 米）----
    base = make_base()
    bp, truth = make_blueprint(base)
    place0 = {"x": truth["x"] + 1500.0, "y": truth["y"] + 900.0,
              "z": truth["z"] + 200.0, "yaw": 0.0}
    results.append(scenario("站在基地边上（差 17.5 米，阈值 20 米）", bp, truth,
                            place0, base, expect_offset_cm=40.0,
                            expect_yaw=0.0, verbose=verbose))

    # ---- 场景 3: 用户已经把小键盘转过 90°（吸附该把朝向也纠正回来）----
    base = make_base()
    bp, truth = make_blueprint(base)
    place0 = {"x": truth["x"] + 400.0, "y": truth["y"] + 300.0,
              "z": truth["z"] + 120.0, "yaw": 90.0}
    results.append(scenario("投影被转过 90°（期望吸附后回到 0°）", bp, truth,
                            place0, base, expect_offset_cm=40.0,
                            expect_yaw=0.0, verbose=verbose))

    # ---- 场景 4: 关掉朝向搜索（只平移）——用户自己负责朝向 ----
    base = make_base()
    bp, truth = make_blueprint(base)
    place0 = {"x": truth["x"] - 500.0, "y": truth["y"] + 400.0,
              "z": truth["z"] + 60.0, "yaw": 0.0}
    results.append(scenario("snap_yaw_search = false（只平移）", bp, truth,
                            place0, base, expect_offset_cm=30.0,
                            expect_yaw=0.0, yaw_search=False, verbose=verbose))

    # ---- 场景 5: 基地被拆掉三成（投影比现场多）----
    full = make_base()
    damaged = make_base(damaged=0.3)
    bp, truth = make_blueprint(full)          # 蓝图是"完整的旧样子"
    place0 = {"x": truth["x"] + 350.0, "y": truth["y"] - 250.0,
              "z": truth["z"] + 100.0, "yaw": 0.0}
    results.append(scenario("现场被拆掉约三成（蓝图是完整版）", bp, truth,
                            place0, damaged, expect_offset_cm=40.0,
                            expect_yaw=0.0, verbose=verbose))

    # ---- 场景 6: 只有格状结构、没有任何稀有件（已知局限）----
    grid_only = make_base(drop_facilities=True)
    bp, truth = make_blueprint(grid_only)
    place0 = {"x": truth["x"] + 2000.0, "y": truth["y"] + 2000.0,
              "z": truth["z"] + 100.0, "yaw": 0.0}
    res, err, _ = solve(bp, place0, grid_only, verbose=verbose)
    print("-" * 74)
    print("场景: 纯格状基地（没有稀有件 —— 已知会退化成「错一格也对得上」）")
    if res is None:
        print("  [通过] 没敢动，报告: %s（比乱挪更安全）" % err)
        results.append(True)
    else:
        ex = (truth["x"] - res["place"]["x"]) / 400.0
        ey = (truth["y"] - res["place"]["y"]) / 400.0
        print("  对上 %d/%d 件; 与真值差 (%.2f, %.2f) 格（格距 400 厘米）"
              % (res["matched"], res["total"], ex, ey))
        near_int = (abs(ex - round(ex)) < 0.05 and abs(ey - round(ey)) < 0.05)
        if near_int:
            print("  [通过] 结果落在「格距的整数倍」上 —— 正是文档里写的已知局限"
                  "（所以在场有稀有件时结果才可靠）")
            results.append(True)
        else:
            print("  [失败] 结果既不是真值、也不是整数格偏移 —— 说明投票乱了")
            results.append(False)

    # ---- 场景 7: 附近根本没有同类型的建筑（该明确失败）----
    other = [{"t": "Stone_Foundation", "x": 100.0 * i, "y": 100.0 * j,
              "z": 100.0, "yaw": 0.0} for i in range(6) for j in range(6)]
    base = make_base()
    bp, truth = make_blueprint(base)
    place0 = {"x": 0.0, "y": 0.0, "z": 0.0, "yaw": 0.0}
    results.append(scenario("附近只有别的建筑（类型全都不同）", bp, truth, place0,
                            other, expect_fail=True, verbose=verbose))

    # ---- 场景 8: 空基地（该明确失败，且不崩）----
    results.append(scenario("附近一个建筑都没有", bp, truth, place0, [],
                            expect_fail=True, verbose=verbose))

    print("=" * 74)
    n_ok = sum(1 for r in results if r)
    print("结果: %d / %d 个场景通过" % (n_ok, len(results)))
    print("=" * 74)
    return 0 if n_ok == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
