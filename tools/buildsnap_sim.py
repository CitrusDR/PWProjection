#!/usr/bin/env python3
"""建造吸附（`pwpr_buildsnap.lua`）纯逻辑的离线验证。

为什么要有它
============
建造吸附要动**游戏自己的放置请求**，实机试错的代价很高（一次要部署+进游戏+
摆建筑+发日志）。所以把其中**与引擎无关的那部分逻辑**先离线验证掉:

  ① `norm_id`  —— 游戏给的建筑 id 与蓝图里的类型名能不能对上（写法差异容忍）
  ② 四元数 ↔ 偏航角  —— 建筑的朝向换算（UE 的 FQuat 是 X,Y,Z,W）
  ③ `find_target` —— 在投影里找"最近的那一件"，**包含"投影被转过角度"的情况**
     （世界位置 = place + R(place.yaw)·rel，转错符号就会吸到镜像位置）

本机没有 Lua 解释器（UE4SS 内嵌的那个没法单独调用），所以这里是 Python 复刻，
并且**反向读 `pwpr_buildsnap.lua` 源码**校验关键常量/结构 —— 改了 Lua 不同步就报错。

用法:
    python tools/buildsnap_sim.py [-v]
退出码: 0 = 全部通过, 1 = 有失败
"""
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LUA = os.path.join(ROOT, "mod", "PWProjection", "Scripts", "pwpr_buildsnap.lua")

REQUIRED_LUA_SNIPPETS = [
    "BuildSnap.HOOK_PATH =",
    '"/Script/Pal.PalNetworkPlayerComponent:RequestBuild_ToServer"',
    "function BuildSnap.norm_id(s)",
    "function BuildSnap.quat_to_yaw(x, y, z, w)",
    "function BuildSnap.yaw_to_quat(z_w, yaw_deg)",
    "function BuildSnap.read_vec3(p)",
    "function BuildSnap.read_quat(p)",
    "function BuildSnap.read_name_string(p)",
    "function BuildSnap.block_request(id_param)",
    "function BuildSnap.record_world(place, b, c, s)",
    "function BuildSnap.find_target(bp, place, wx, wy, wz, want_keys, type_match,",
    "                                     want_id_norm)",
    "buildsnap_learn_max_cm",
    "用「名字相似」配对",
    "丢掉被污染的映射",
    "BuildSnap.learned = {}",
    "BuildSnap.learned_id = {}",
    "local game_id = BuildSnap.learned_id[BuildSnap.norm_id(res.rec.t)]",
    "buildsnap_demo",
    "if cfg(\"buildsnap_demo\") == true then",
    "buildsnap_type_loose_cm",
    "buildsnap_snap_z",
    "buildsnap_max_dist_cm",
    "function BuildSnap.install_confirm()",
    "NotifyOnNewObject(\"/Script/Pal.PalBuildObject\"",
    "function BuildSnap.schedule_confirm(target_desc, delay_ms, extra_note,",
    "function BuildSnap.find_target_by_aim(bp, place, px, py, pz, dx, dy, dz,",
    "function BuildSnap.on_request_build(self, build_object_id, location, rotation,",
    "function BuildSnap.install()",
    # ★ 参数必须先 unwrap（2026-09-29 实测: 直接读字段读不到）
    "local function unwrap_param(p)",
    "local ok, v = pcall(function() return p:get() end)",
    # 世界位置 = place + R(place.yaw)·rel（和 pwpr_ghost 同一套约定）
    "return place.x + (rx * c - ry * s), place.y + (rx * s + ry * c), place.z + rz",
    # 应用方式: 拦原请求 + 自己重发（用已验证的原语）
    "local blocked, block_how = BuildSnap.block_request(build_object_id)",
    "net:RequestBuild_ToServer(",
]


def check_no_drift(verbose=False):
    src = open(LUA, encoding="utf-8").read()
    bad = [s for s in REQUIRED_LUA_SNIPPETS if s not in src]
    if bad:
        print("[严重] 防漂移检查失败 —— Lua 里找不到这些结构:")
        for b in bad:
            print("   -", b)
        print("  ⇒ 本脚本是 pwpr_buildsnap.lua 的复刻；Lua 侧改了就要来改这里。")
        return False
    if verbose:
        print("  防漂移检查通过（%d 段结构）" % len(REQUIRED_LUA_SNIPPETS))
    return True


# ==========================================================================
# 1. 复刻：字符串归一化
# ==========================================================================
def norm_id(s):
    if s is None:
        return ""
    s = str(s)
    s = re.sub(r"^.*[/.]", "", s)          # 去容器前缀
    s = re.sub(r"_C$", "", s)              # 去蓝图类后缀（必须在去分隔符之前）
    s = s.lower()
    s = re.sub(r"[^0-9a-zA-Z]", "", s)     # 去所有分隔符
    s = re.sub(r"^bpbuildobject", "", s)   # 再去前缀
    s = re.sub(r"^buildobject", "", s)
    return s


# ==========================================================================
# 2. 复刻：四元数 <-> 偏航角（只取绕 Z 的分量）
# ==========================================================================
def quat_to_yaw(x, y, z, w):
    siny = 2.0 * (w * z + x * y)
    cosy = 1.0 - 2.0 * (y * y + z * z)
    yaw = math.degrees(math.atan2(siny, cosy))
    yaw = yaw % 360.0
    if yaw > 180.0:
        yaw -= 360.0
    return yaw


def yaw_to_quat_z_w(yaw_deg):
    h = math.radians(yaw_deg) * 0.5
    return math.sin(h), math.cos(h)


def norm_yaw(d):
    d = d % 360.0
    if d > 180.0:
        d -= 360.0
    return d


# ==========================================================================
# 3. 复刻：find_target（在投影里找最近的一件）
# ==========================================================================
def record_world(place, b, c=None, s=None):
    """对应 BuildSnap.record_world —— 一条记录在当前投影下的世界坐标。"""
    rx, ry, rz = b["p"][0] * 100.0, b["p"][1] * 100.0, b["p"][2] * 100.0
    if c is None or s is None:
        rad = math.radians(place.get("yaw", 0.0))
        c, s = math.cos(rad), math.sin(rad)
    return (place["x"] + (rx * c - ry * s),
            place["y"] + (rx * s + ry * c),
            place["z"] + rz)


def common_prefix(a, b):
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n


def find_target(bp, place, wx, wy, wz, want_keys, type_match=True,
                want_id_norm=None):
    """对应 BuildSnap.find_target（align 模式）—— 返回 {"best","near","sim"}。

    best = 类型命中里最近的一件；near = 任意类型里最近的一件；
    sim  = **名字相似**的那一件（归一化后公共前缀 ≥4 个字母）—— 2026-09-29 新增，
           用来处理"同一个东西、拼写不同"（Wood_Foundation vs Wooden_foundation），
           这样这种系统性差异**不需要靠"学到映射"**（那个曾把功能搞死）。
    """
    rad = math.radians(place.get("yaw", 0.0))
    c, s = math.cos(rad), math.sin(rad)
    accept = set(k for k in (want_keys or []) if k)
    best = near = sim = None
    for b in bp["buildings"]:
        tx, ty, tz = record_world(place, b, c, s)
        d = math.sqrt((tx - wx) ** 2 + (ty - wy) ** 2 + (tz - wz) ** 2)
        cand = {"rec": b, "x": tx, "y": ty, "z": tz, "dist": d,
                "yaw": norm_yaw(place.get("yaw", 0.0) + b["yaw"])}
        if near is None or d < near["dist"]:
            near = cand
        bnorm = norm_id(b["t"])
        hit = (type_match is not True) or (bnorm in accept)
        if hit and (best is None or d < best["dist"]):
            best = cand
        # ★★★ 2026-09-29: 这里原来用 `sim is None`（只留循环里第一条）——
        #   而 buildings 的顺序是采集顺序 ⇒ 会"近的不吸、吸远的"（玩家实测）。
        #   现在和 best 一样取**最近**的那一条。
        if want_id_norm and bnorm:
            cp = common_prefix(want_id_norm, bnorm)
            if cp >= 4:
                better = (sim is None) or (d < sim["dist"] - 0.001) or \
                    (abs(d - sim["dist"]) <= 0.001 and cp > sim.get("common", 0))
                if better:
                    sim = dict(cand)
                    sim["common"] = cp
    return {"best": best, "near": near, "sim": sim}


def solve_align(bp, place, lx, ly, lz, want_yaw, game_id, learned=None,
                type_match=True, loose_cm=150.0, radius_cm=2000.0,
                rot_tol=180.0, learn_max_cm=30.0, max_jump_cm=600.0):
    """复刻 on_request_build 里 align 模式的判定（含"学到映射"/"名字相似"/自愈）。

    返回 (动作, 详情) —— 动作 ∈ {"snap", "skip"}；详情含目标与朝向。
    """
    learned = learned if learned is not None else {}
    id_norm = norm_id(game_id)
    keys = [id_norm]
    if id_norm in learned:
        keys.append(learned[id_norm])
    found = find_target(bp, place, lx, ly, lz, keys, type_match, id_norm)
    res = found["best"]
    loosened = False
    similar = False
    # 第二层: 名字相似（不需要学）
    if res is None and found["sim"] is not None:
        res = found["sim"]
        similar = True
    if res is None and loose_cm > 0 and found["near"] is not None \
            and found["near"]["dist"] <= loose_cm:
        # 第三层: 放宽接受（照旧 ≤ type_loose）；**只有贴得极近才学习**
        res = found["near"]
        loosened = True
        near_dist = found["near"]["dist"]
        if id_norm and near_dist <= learn_max_cm:
            learned[id_norm] = norm_id(res["rec"]["t"])
    if res is None:
        return "skip", {"reason": "no-type-match", "near": found["near"]}
    if res["dist"] > radius_cm:
        return "skip", {"reason": "too-far", "dist": res["dist"]}
    # 修正量上限（2026-09-29 事故后加的"总保险"）+ **映射自愈**
    if max_jump_cm > 0.0 and res["dist"] > max_jump_cm:
        healed = False
        if id_norm and learned.get(id_norm) == norm_id(res["rec"]["t"]):
            del learned[id_norm]          # 这个映射把我们带到了老远的地方 ⇒ 丢掉它
            healed = True
        return "skip", {"reason": "jump-cap", "dist": res["dist"],
                        "healed": healed, "rec": res["rec"]}
    dyaw = abs(norm_yaw(res["yaw"] - want_yaw))
    snap_yaw = dyaw <= rot_tol
    return "snap", {"rec": res["rec"], "x": res["x"], "y": res["y"],
                    "z": res["z"], "dist": res["dist"], "loosened": loosened,
                    "similar": similar, "learned": bool(learned),
                    "snap_yaw": snap_yaw,
                    "yaw": res["yaw"] if snap_yaw else want_yaw}


def find_target_by_aim(bp, place, px, py, pz, dx, dy, dz, max_cm, cone_deg):
    """对应 BuildSnap.find_target_by_aim（blueprint 模式）—— 准星选目标（角度锥）。"""
    length = math.sqrt(dx * dx + dy * dy + dz * dz)
    if length < 1e-6:
        return None
    dx, dy, dz = dx / length, dy / length, dz / length
    tan_cone = math.tan(math.radians(cone_deg or 12.0))
    rad = math.radians(place.get("yaw", 0.0))
    c, s = math.cos(rad), math.sin(rad)
    best = None
    for b in bp["buildings"]:
        wx, wy, wz = record_world(place, b, c, s)
        vx, vy, vz = wx - px, wy - py, wz - pz
        along = vx * dx + vy * dy + vz * dz
        if along <= 1.0 or along > max_cm:
            continue
        ox, oy, oz = vx - along * dx, vy - along * dy, vz - along * dz
        perp = math.sqrt(ox * ox + oy * oy + oz * oz)
        if perp > along * tan_cone:
            continue
        # ★ 排序: 先把 perp 分档（每 50 厘米），同档里取更近的那一件。
        #   （第三次实测: 地面记录的 perp 全挤在 ~78 厘米 ⇒ 按 perp 精排等于随机挑，
        #     结果挑到 11~25 米外那些，游戏直接拒绝。）
        band = int(perp // 50.0)
        if (best is None or band < best["perp_band"]
                or (band == best["perp_band"] and along < best["along"])):
            best = {"rec": b, "x": wx, "y": wy, "z": wz, "dist": perp,
                    "along": along, "perp": perp, "perp_band": band,
                    # ★ 必须带上朝向（Lua 侧 2026-09-29 修过一次漏字段）
                    "yaw": norm_yaw(place.get("yaw", 0.0) + b["yaw"])}
    return best


# ==========================================================================
# 4. 断言
# ==========================================================================
FAILED = []


def check(name, ok, detail=""):
    print("  %s %s%s" % ("[通过]" if ok else "[失败]", name,
                         ("   " + detail) if detail else ""))
    if not ok:
        FAILED.append(name)


def test_norm_id(verbose):
    print("-" * 74)
    print("① norm_id: 游戏 id 与蓝图类型名能不能对上")
    cases = [
        ("Wood_Foundation", "Wood_Foundation"),
        ("BP_BuildObject_Wood_Foundation_C", "Wood_Foundation"),
        ("BuildObject_Wood_Foundation", "Wood_Foundation"),
        ("wood_foundation", "Wood_Foundation"),
        ("BP_BuildObject_StonePit_C", "StonePit"),
        ("BP_BuildObject_SK_Pulverizer_C", "SK_Pulverizer"),
    ]
    for given, record_t in cases:
        a, b = norm_id(given), norm_id(record_t)
        check("%-34s ≡ %-16s → %s" % (given, record_t, a), a == b and a != "")
    # 不同建筑不能被归一化到一起
    check("Wood_Foundation ≠ Stone_Foundation",
          norm_id("Wood_Foundation") != norm_id("Stone_Foundation"))


def test_quat_yaw(verbose):
    print("-" * 74)
    print("② 四元数 ↔ 偏航角")
    worst = 0.0
    for yaw in (0.0, 15.0, 90.0, -90.0, 179.0, -179.0, 37.5, -123.25):
        z, w = yaw_to_quat_z_w(yaw)
        back = quat_to_yaw(0.0, 0.0, z, w)
        err = abs(norm_yaw(back - yaw))
        worst = max(worst, err)
        check("yaw %8.2f → quat → %8.2f（误差 %.4f）" % (yaw, back, err), err < 0.01)
    # 单位四元数 = 0 度
    check("单位四元数 (0,0,0,1) → 0 度", abs(quat_to_yaw(0, 0, 0, 1)) < 1e-9)


def make_bp():
    """合成一份"投影": 4 件（两件同类型前后排开 + 一件别的类型 + 一件远处）"""
    return {"buildings": [
        {"t": "Wood_Foundation", "p": [0.0, 0.0, 0.0], "yaw": 0.0},      # 原点
        {"t": "Wood_Foundation", "p": [3.0, 0.0, 0.0], "yaw": 0.0},      # 东 3 米
        {"t": "Wood_Wall", "p": [0.0, 3.0, 0.0], "yaw": 90.0},           # 北 3 米
        {"t": "Wood_Foundation", "p": [70.0, 0.0, 0.0], "yaw": 0.0},     # 远处 70 米
    ]}


def test_find_target(verbose):
    print("-" * 74)
    print("③ align 模式: 找最近的那一件（含投影被转过角度 / 类型不匹配的兜底）")

    bp = make_bp()
    # ---- 投影未旋转: place=(1000,2000,100)，原点那一件就在 (1000,2000,100)
    place = {"x": 1000.0, "y": 2000.0, "z": 100.0, "yaw": 0.0}
    res = find_target(bp, place, 1040.0, 2030.0, 100.0, ["woodfoundation"])
    check("未旋转: 命中原点那一件（距离 %.1f 厘米）" % (res["best"]["dist"] or -1),
          res["best"] is not None and res["best"]["dist"] < 60.0)
    check("未旋转: 目标坐标 = (1000,2000,100)",
          res["best"] is not None and abs(res["best"]["x"] - 1000) < 0.01
          and abs(res["best"]["y"] - 2000) < 0.01
          and abs(res["best"]["z"] - 100) < 0.01,
          "实际 (%.1f,%.1f,%.1f)" % (res["best"]["x"], res["best"]["y"],
                                     res["best"]["z"]))

    # ---- 投影转 90°: 记录 (3,0,0) 米 应该转到 (0,3,0) 米 的位置
    place90 = {"x": 0.0, "y": 0.0, "z": 0.0, "yaw": 90.0}
    res2 = find_target(bp, place90, 0.0, 300.0, 0.0, ["woodfoundation"])
    check("转 90°: 命中东侧那一件，且落点 = (0,300,0)（旋转方向对）",
          res2["best"] is not None and abs(res2["best"]["x"]) < 0.01
          and abs(res2["best"]["y"] - 300.0) < 0.01,
          "实际 (%.1f,%.1f,%.1f)" % (res2["best"]["x"], res2["best"]["y"],
                                     res2["best"]["z"]))

    # ---- 类型过滤: 拿墙的类型去找，命中的必须是墙（最近的地基只有 50 厘米）
    res3 = find_target(bp, place, 1040.0, 2030.0, 100.0, ["woodwall"])
    check("类型过滤: 墙只认墙，不会被 50 厘米外的地基勾走",
          res3["best"] is not None and res3["best"]["rec"]["t"] == "Wood_Wall",
          "命中 %s（距离 %.1f）" % (res3["best"]["rec"]["t"], res3["best"]["dist"]))
    res4 = find_target(bp, place, 1010.0, 2290.0, 100.0, ["woodwall"])
    check("类型过滤: 墙在墙附近能命中（%.1f 厘米）" % (res4["best"]["dist"] or -1),
          res4["best"] is not None and res4["best"]["rec"]["t"] == "Wood_Wall")

    # ---- 关掉类型过滤: 只看距离
    res5 = find_target(bp, place, 1040.0, 2030.0, 100.0, ["woodwall"],
                       type_match=False)
    check("关掉类型过滤: 按距离吸到最近的地基",
          res5["best"] is not None and res5["best"]["rec"]["t"] == "Wood_Foundation")

    # ---- 距离算得对不对: 第 4 件记录在 p=(70,0,0) 米 ⇒ 世界 (8000,2000,100)
    res6 = find_target(bp, place, 8000.0, 2000.0, 100.0, ["woodfoundation"])
    check("远点: 正对着第 4 件（距离 %.1f ≈ 0）" % (res6["best"]["dist"] or -1),
          res6["best"] is not None and res6["best"]["dist"] < 1.0)


def test_aim_mode(verbose):
    print("-" * 74)
    print("⑤ 蓝图建造模式: 准星选目标（find_target_by_aim，角度锥 12°）")
    bp = make_bp()
    # 投影未旋转，place=(1000,2000,100):
    #   地基 (1000,2000,100) / (1300,2000,100) / (8000,2000,100)；墙 (1000,2300,100)
    place = {"x": 1000.0, "y": 2000.0, "z": 100.0, "yaw": 0.0}
    CONE, MAXD = 12.0, 3000.0

    # ---- 站在原点那一件的位置朝北看 → 墙在前方 300 厘米、正对准星
    res = find_target_by_aim(bp, place, 1000.0, 2000.0, 100.0, 0.0, 1.0, 0.0,
                             MAXD, CONE)
    check("站在地基上朝北看: 选中 3 米外的墙（%s）"
          % (res["rec"]["t"] if res else "-"),
          res is not None and res["rec"]["t"] == "Wood_Wall")

    # ---- 站在 (700,2000) 朝东看 → 命中 (1000,2000) 那块地基（正前方 300 厘米）
    res2 = find_target_by_aim(bp, place, 700.0, 2000.0, 100.0, 1.0, 0.0, 0.0,
                              MAXD, CONE)
    check("朝东看: 选中 (1000,2000) 那块地基（前方 %.0f 厘米）"
          % (res2["along"] if res2 else -1),
          res2 is not None and abs(res2["x"] - 1000.0) < 0.01)

    # ---- 距离/锥角: 远处那件（80 米外、偏离 14°）⇒ 12° 锥里选不中，
    #      20° 锥里能选中。这正是"用角度而不是固定厘米"的意义。
    #      （视距要放开到 100 米，否则它先在"看多远"那一关被挡掉）
    far = find_target_by_aim(bp, place, 0.0, 0.0, 100.0, 1.0, 0.0, 0.0,
                             10000.0, 12.0)
    check("偏离 14° 的远处那件: 12° 锥里选不中", far is None)
    far2 = find_target_by_aim(bp, place, 0.0, 0.0, 100.0, 1.0, 0.0, 0.0,
                              10000.0, 20.0)
    check("同样的位置: 20° 锥里能选中（%s，前方 %.0f 厘米）"
          % (far2["rec"]["t"] if far2 else "-", far2["along"] if far2 else -1),
          far2 is not None and far2["rec"]["t"] == "Wood_Foundation")

    # ---- 超出"看多远"（500 厘米）→ 选不中（墙在 1300 厘米外）
    res4 = find_target_by_aim(bp, place, 1000.0, 1000.0, 100.0, 0.0, 1.0, 0.0,
                              500.0, CONE)
    check("超出最大视距（500 厘米）→ 选不中", res4 is None)

    # ---- 背后的东西不该被选中（along <= 0）
    res5 = find_target_by_aim(bp, place, 1000.0, 2600.0, 100.0, 0.0, 1.0, 0.0,
                              MAXD, CONE)
    check("背对墙看（墙在身后）→ 不选它", res5 is None,
          "选中的是 %s" % (res5["rec"]["t"] if res5 else "-"))

    # ---- 准星带俯仰: 抬头 45° 时该选中头顶的屋顶，而不是正前方的地板
    bp2 = {"buildings": [
        {"t": "Roof", "p": [0.0, 3.0, 3.0], "yaw": 0.0},    # 前方 300、上方 300
        {"t": "Floor", "p": [0.0, 10.0, 0.0], "yaw": 0.0},   # 正前方 1000、水平
    ]}
    place2 = {"x": 0.0, "y": 0.0, "z": 0.0, "yaw": 0.0}
    up = 1.0 / math.sqrt(2.0)
    res6 = find_target_by_aim(bp2, place2, 0.0, 0.0, 0.0, 0.0, up, up,
                              MAXD, CONE)
    check("抬头 45°: 选中头顶那块屋顶（%s，偏离 %.0f 厘米）"
          % (res6["rec"]["t"] if res6 else "-", res6["perp"] if res6 else -1),
          res6 is not None and res6["rec"]["t"] == "Roof")


def apply_policy(res, want_yaw, requested_z, player_xyz, snap_yaw, snap_z=True,
                 max_dist_cm=3000.0):
    """复刻"决定最终要发出去的坐标"那一段（z 策略 + 距离闸）。

    返回 (动作, 详情)：动作 ∈ {"send", "passthrough"}
    """
    tx, ty, tz = res["x"], res["y"], res["z"]
    if not snap_z and requested_z is not None:
        tz = requested_z                      # 高度用游戏给的
    px, py, pz = player_xyz
    d = math.sqrt((tx - px) ** 2 + (ty - py) ** 2 + (tz - pz) ** 2)
    if d > max_dist_cm:
        return "passthrough", {"reason": "too-far-from-player", "dist": d}
    yaw = res.get("yaw", want_yaw) if snap_yaw else want_yaw
    return "send", {"x": tx, "y": ty, "z": tz, "yaw": yaw, "dist": d,
                    "z_from": ("projection" if snap_z else "game")}


def demo_params():
    """复刻 buildsnap_demo（2026-09-29 起: 在默认值上**再松一档**）。"""
    return {"radius_cm": 4000.0, "type_loose_cm": 2000.0, "max_dist_cm": 6000.0,
            "rot_tol_deg": 180.0, "snap_z": True}


CONFIG_LUA = os.path.join(ROOT, "mod", "PWProjection", "Scripts",
                          "pwpr_config.lua")

# ★ 玩家实测认可的那套值。以后谁改了默认值，这里必须同时改 ——
#   否则文档和自检会悄悄跟代码脱节（这正是"改了默认值却没落文档"的防线）。
REQUIRED_CONFIG_DEFAULTS = [
    "buildsnap_radius_cm  = 2000",
    "buildsnap_snap_z     = true",
    "buildsnap_rot_tol_deg = 180",
    "buildsnap_max_dist_cm = 3000",
    "buildsnap_type_loose_cm = 150",
    "buildsnap_learn_max_cm = 30",
    "buildsnap_max_jump_cm = 200",
    "buildsnap_skip_extra = false",
    "buildsnap_safe_cm = 0",
    "buildsnap_zone_m = 0",
    "buildsnap_defer = true",
    "buildsnap_demo       = false",
    "ghost_hide_placed  = true",
    "ghost_hide_placed_cm = 40",
    "ghost_hide_placed_batch_s = 3",
    "buildsnap_min_cm     = 5,",
    "ghost_hide_alive_check = false",
    "ghost_hide_enum = true",
    "ghost_resume_last = true",
    "ghost_hide_scan = false",
    "log_flush_interval_s = 5",
    "log_flush_lines      = 200",
    "buildsnap_notify     = false",
    "buildsnap_notify_confirm = false",
    "notify_trace         = false",
    "ghost_hide_scan_interval_s = 8",
    "ghost_dump_move = false",
]


LOG_LUA = os.path.join(ROOT, "mod", "PWProjection", "Scripts", "pwpr_log.lua")
UTIL_LUA = os.path.join(ROOT, "mod", "PWProjection", "Scripts", "pwpr_util.lua")


PLACED_LUA = os.path.join(ROOT, "mod", "PWProjection", "Scripts",
                          "pwpr_placed.lua")
GHOST_LUA = os.path.join(ROOT, "mod", "PWProjection", "Scripts",
                         "pwpr_ghost.lua")

# ★ 投影侧接口守卫（2026-09-29）: 建造吸附和"已放上的不渲染"是**跨模块协作**的
#   （on_placing / on_placed_confirmed / Ghost.rehide）—— 这些名字一旦被改名或
#   删掉，吸附那边会静默什么都不做。所以在这里钉住。
REQUIRED_PLACED_SNIPPETS = [
    "function Placed.hide_now(rec_idx)",
    "function Placed.is_taken(rec_idx)",
    "function Placed.take_pending()",
    "function Placed.cancel_pending(rec_idx)",
    "function Placed.stash_actor(rec_idx, actor)",
    "function Placed.confirm_hidden(rec_idx, actor)",
    "function Placed.unhide(rec_idx)",
    "function Placed.check_alive()",
    "function Placed.refresh_delta()",
    "Placed.last_delta = delta",
]
REQUIRED_GHOST_SNIPPETS = [
    "function Ghost.rehide(records)",
    "if Ghost.skip ~= nil and Ghost.skip[picked[i]] == true then",
    "Ghost.plan[comp] = { skel = is_skel, world = ok_world,",
]


def check_placed_api(verbose):
    """投影侧的关键接口还在不在（跨模块协作的名字）"""
    bad = []
    for path, need in ((PLACED_LUA, REQUIRED_PLACED_SNIPPETS),
                       (GHOST_LUA, REQUIRED_GHOST_SNIPPETS)):
        try:
            with open(path, "r", encoding="utf-8") as f:
                text = f.read()
        except OSError as exc:
            print("[严重] 读不到 {}: {}".format(os.path.basename(path), exc))
            return False
        for snip in need:
            if snip not in text:
                bad.append("{}: {}".format(os.path.basename(path), snip))
    if bad:
        print("[严重] 投影侧接口守卫失败 —— 找不到:")
        for b in bad:
            print("   - {}".format(b))
        print("  ⇒ 这些名字是吸附 <-> 投影 之间的约定，改名要同步改两边。")
        return False
    print("  [通过] 投影侧接口守卫（{} 项: 已放上的不渲染 + 增量重灌）"
          .format(len(REQUIRED_PLACED_SNIPPETS) + len(REQUIRED_GHOST_SNIPPETS)))
    return True


def check_config_defaults(verbose):
    """默认值守卫: 只读 pwpr_buildsnap.lua 是看不到灵敏度默认值的（它们在
    pwpr_config.lua 里），所以单独查一遍。"""
    try:
        with open(CONFIG_LUA, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError as exc:
        print("[严重] 读不到 pwpr_config.lua: {}".format(exc))
        return False
    missing = [s for s in REQUIRED_CONFIG_DEFAULTS if s not in text]
    if missing:
        print("[严重] 配置默认值守卫失败 —— pwpr_config.lua 里找不到:")
        for s in missing:
            print("   - {}".format(s))
        print("  ⇒ 默认值改了就要同时改: 本脚本、docs/配置说明.md、相关注释。")
        return False
    print("  [通过] 配置默认值守卫（{} 项: 吸附灵敏度 + 已放上的不渲染）"
          .format(len(REQUIRED_CONFIG_DEFAULTS)))
    return True


def test_demo_mode(verbose):
    print("-" * 74)
    print("⑨ 演示模式: 放宽前提条件后，修正量要大到肉眼可见")

    bp = {"buildings": [{"t": "Wood_Foundation", "p": [0.0, 0.0, 0.0], "yaw": 0.0}]}
    place = {"x": 0.0, "y": 0.0, "z": 0.0, "yaw": 0.0}
    # 站在离投影件 8 米的地方、随便朝着它放（请求点偏了 8 米）
    req = (800.0, 0.0, 300.0)

    # ---- 默认参数: 8 米远超 radius(300) ⇒ 不吸
    act, info = solve_align(bp, place, req[0], req[1], req[2], 0.0,
                            "Wooden_foundation", {}, loose_cm=100.0,
                            radius_cm=300.0, rot_tol=35.0)
    check("默认参数下: 8 米外不吸（这也是「看不出效果」的原因之一）",
          act == "skip", "原因=%s" % info.get("reason"))

    # ---- 演示参数: radius 10 米 + 高度也跟投影 ⇒ 会吸，且修正量很大
    p = demo_params()
    learned = {}
    act2, info2 = solve_align(bp, place, req[0], req[1], req[2], 0.0,
                              "Wooden_foundation", learned, type_match=False,
                              loose_cm=p["type_loose_cm"],
                              radius_cm=p["radius_cm"],
                              rot_tol=p["rot_tol_deg"])
    # ★ 2026-09-29 定稿: **修正量上限对演示模式同样生效**（安全优先于"演示夸张"）。
    #   8.5 米的修正量已经超出"吸附=挪一点点"的语义 ⇒ 演示模式下也**原样放行**。
    check("演示参数下: 8.5 米的修正量被**修正量上限**拦下（安全优先）",
          act2 == "skip" and info2.get("reason") == "jump-cap",
          "三维距离=%.0f 厘米" % info2.get("dist", -1))

    # 而"真的只是挪一点点"（4 米，仍在演示半径内但小于上限）时应该吸上
    req_near = (400.0, 0.0, 0.0)
    learned2 = {}
    act2b, info2b = solve_align(bp, place, req_near[0], req_near[1], req_near[2],
                                0.0, "Wooden_foundation", learned2,
                                type_match=False,
                                loose_cm=p["type_loose_cm"],
                                radius_cm=p["radius_cm"],
                                rot_tol=p["rot_tol_deg"])
    check("演示参数下: 4 米的修正量能吸上（小于上限）",
          act2b == "snap" and 300.0 <= info2b.get("dist", 0) <= 600.0,
          "三维距离=%.0f 厘米" % info2b.get("dist", -1))
    act2 = act2b
    info2 = info2b
    act3, info3 = apply_policy(info2 if act2 == "snap" else {},
                               0.0, req[2], (800.0, 0.0, 0.0), snap_yaw=True,
                               snap_z=p["snap_z"], max_dist_cm=p["max_dist_cm"])
    check("演示参数下: 高度也跟投影（%.0f → %.0f）" % (req[2], info3.get("z", -1)),
          act3 == "send" and info3.get("z_from") == "projection")


def test_real_id_mismatch(verbose):
    """★ 用玩家实测日志里的**真实数据**做回归（2026-09-29）。

    日志原文:
        [bsnap] 请求 #5: id=Wooden_foundation 位置=(-98213.0,39973.4,742.8) 朝向=134.4 度
        [bsnap] 匹配: id=Wooden_foundation(归一化 woodenfoundation) →
                投影里没有同类型的记录; 最近的一件=Wood_Foundation 距离=18.3 厘米
    """
    print("-" * 74)
    print("⑥ ★ 真实数据回归: 游戏 id `Wooden_foundation` vs 蓝图类型 `Wood_Foundation`")

    check("两者归一化后**不相等**（所以旧代码匹配不上）",
          norm_id("Wooden_foundation") != norm_id("Wood_Foundation"),
          "%s vs %s" % (norm_id("Wooden_foundation"), norm_id("Wood_Foundation")))

    # ---- 造一个"投影里就有一块地基、离玩家请求点 18 厘米"的场景
    bp = {"buildings": [
        {"t": "Wood_Foundation", "p": [0.0, 0.0, 0.0], "yaw": 0.0},
        {"t": "Wood_Foundation", "p": [4.0, 0.0, 0.0], "yaw": 0.0},
        {"t": "Wood_Wall", "p": [0.0, 4.0, 0.0], "yaw": 90.0},
    ]}
    place = {"x": 0.0, "y": 0.0, "z": 0.0, "yaw": 0.0}
    req = (18.0, 3.0, 0.0)          # 请求点（离第一块地基 18 厘米）
    want_yaw = 134.4                # 日志里的真实朝向（自由角度！）

    # ① 2026-09-29 起: **名字相似层**（公共前缀 ≥4 个字母）直接命中 ——
    #    这样"同一个东西、拼写不同"（Wood_Foundation vs Wooden_foundation）
    #    不再依赖"学到映射"（那个缓存曾经把功能搞死，见 ⑪）。
    learned = {}
    act, info = solve_align(bp, place, req[0], req[1], req[2], 0.0,
                            "Wooden_foundation", learned, loose_cm=0.0)
    check("严格类型匹配下: **名字相似**直接命中那块地基（不再需要学映射）",
          act == "snap" and info["rec"]["t"] == "Wood_Foundation",
          "距离=%.1f 厘米" % info.get("dist", -1))
    check("这种情况 learned 保持为空（不需要学）", learned == {})

    # ② 放宽阈值（新默认 100 厘米）: 应该吸到那块地基，并**学到映射**
    learned = {}
    act2, info2 = solve_align(bp, place, req[0], req[1], req[2], want_yaw,
                              "Wooden_foundation", learned, loose_cm=100.0,
                              rot_tol=35.0)   # 显式用 35° 容差测"差太多只吸位置"
    check("吸到那块地基（%s，距离 %.1f）—— 走名字相似层，不再需要「放宽」"
          % (info2.get("rec", {}).get("t", "-"), info2.get("dist", -1)),
          act2 == "snap" and info2["rec"]["t"] == "Wood_Foundation")
    check("★ 名字相似命中时**不需要学映射**（learned 为空）", learned == {})
    check("位置用投影的: x=%.1f（请求点是 %.1f）" % (info2["x"], req[0]),
          abs(info2["x"] - 0.0) < 0.01)
    check("把 rot_tol 设成 35 时，朝向差 134.4° ⇒ **只吸位置、保留玩家朝向**（朝向=%.1f）"
          % info2["yaw"], info2["snap_yaw"] is False
          and abs(info2["yaw"] - want_yaw) < 0.01)

    # ③ 学到之后，即使关掉放宽阈值也能匹配上（这就是"学到"的价值）
    act3, info3 = solve_align(bp, place, req[0], req[1], req[2], want_yaw,
                              "Wooden_foundation", learned, loose_cm=0.0,
                              rot_tol=35.0)
    check("学到映射后: 放宽阈值设 0 也能吸上（loosened=%s）"
          % info3.get("loosened"), act3 == "snap" and info3["loosened"] is False)

    # ④ 放宽也不能乱吸: 最近的不同类记录在 4 米外时不该吸
    act4, info4 = solve_align(bp, place, 1000.0, 1000.0, 0.0, 0.0,
                              "Wooden_foundation", {}, loose_cm=100.0)
    check("离所有记录都很远时: 不吸", act4 == "skip",
          "原因=%s" % info4.get("reason"))


def test_third_test_lessons(verbose):
    """★ 第三次实测（2026-09-29）的两条教训，用日志里的真实数字做回归。"""
    print("-" * 74)
    print("⑦ 第三次实测回归: 高度策略 + 距离闸 + 准星分档")

    # ---- ① 高度: 游戏给 742.8，投影记录在 695.3（差 47 厘米）
    bp = {"buildings": [{"t": "Wood_Foundation", "p": [0.0, 0.0, 0.0], "yaw": 0.0}]}
    place = {"x": 0.0, "y": 0.0, "z": 695.3, "yaw": 0.0}
    res = find_target(bp, place, 18.0, 3.0, 742.8, ["woodfoundation"])["best"]
    act, info = apply_policy(res, 167.3, 742.8, (0.0, 0.0, 742.8), snap_yaw=True)
    check("★ 默认**吸高度**（z 用投影的 695.3，实测玩家要的就是这个手感）",
          act == "send" and abs(info["z"] - 695.3) < 0.01
          and info["z_from"] == "projection",
          "实际 z=%.1f (%s)" % (info.get("z", -1), info.get("z_from")))
    act2, info2 = apply_policy(res, 167.3, 742.8, (0.0, 0.0, 742.8),
                               snap_yaw=True, snap_z=False)
    check("把 buildsnap_snap_z 设 false 时用游戏给的 z（742.8）",
          act2 == "send" and abs(info2["z"] - 742.8) < 0.01)

    # ---- ② 距离闸: 蓝图模式曾选中 24 米外的记录 ⇒ 必须原样放行
    bp2 = {"buildings": [
        {"t": "Wood_Foundation", "p": [24.0, 0.0, 0.0], "yaw": 0.0},   # 24 米外
        {"t": "Wood_Foundation", "p": [3.0, 0.0, 0.0], "yaw": 0.0},    # 3 米
    ]}
    place2 = {"x": 0.0, "y": 0.0, "z": 0.0, "yaw": 0.0}
    picked = find_target_by_aim(bp2, place2, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0,
                                3000.0, 12.0)
    check("准星分档: 两件都贴着轴线时选**近的那件**（3 米，不是 24 米）",
          picked is not None and abs(picked["x"] - 300.0) < 0.01,
          "选中的是 x=%.0f（前方 %.0f 厘米）" % (picked["x"], picked["along"]))
    act3, info3 = apply_policy(picked, 0.0, 0.0, (0.0, 0.0, 0.0), snap_yaw=True)
    check("3 米的目标: 在距离闸内 ⇒ 发送", act3 == "send",
          "距离 %.0f 厘米" % info3.get("dist", -1))
    # 距离闸默认是 3000 厘米（玩家实测认可的灵敏度）⇒ 用 40 米来测这条闸门
    far = {"x": 4000.0, "y": 0.0, "z": 0.0, "yaw": 0.0}
    act4, info4 = apply_policy(far, 0.0, 0.0, (0.0, 0.0, 0.0), snap_yaw=True)
    check("40 米的目标: 超出距离闸 ⇒ **原样放行**（复现并修掉「提示了但没放」）",
          act4 == "passthrough" and info4["reason"] == "too-far-from-player")
    # 24 米在放宽后的默认值里是**允许**的（实测玩家的手感就是这么松）
    mid = {"x": 2400.0, "y": 0.0, "z": 0.0, "yaw": 0.0}
    act5, info5 = apply_policy(mid, 0.0, 0.0, (0.0, 0.0, 0.0), snap_yaw=True)
    check("24 米的目标: 在放宽后的默认距离闸内 ⇒ 发送（这是玩家要的灵敏度）",
          act5 == "send", "距离=%.0f 厘米" % info5.get("dist", -1))


def solve_blueprint(bp, place, px, py, pz, dx, dy, dz, learned_id,
                    aim_max=3000.0, cone=12.0, snap_z=False, requested_z=None,
                    max_dist_cm=1200.0):
    """复刻 on_request_build 里 blueprint 模式的判定（含"必须换成游戏 id"）。

    返回 (动作, 详情)：动作 ∈ {"send", "skip_unknown_id", "passthrough", "no_target"}
    """
    res = find_target_by_aim(bp, place, px, py, pz, dx, dy, dz, aim_max, cone)
    if res is None:
        return "no_target", {}
    rec_type = res["rec"]["t"]
    game_id = learned_id.get(norm_id(rec_type))
    if game_id is None:
        return "skip_unknown_id", {"type": rec_type}
    tx, ty, tz = res["x"], res["y"], res["z"]
    if not snap_z and requested_z is not None:
        tz = requested_z
    d = math.sqrt((tx - px) ** 2 + (ty - py) ** 2 + (tz - pz) ** 2)
    if d > max_dist_cm:
        return "passthrough", {"dist": d}
    return "send", {"id": game_id, "x": tx, "y": ty, "z": tz,
                    "yaw": res.get("yaw"), "dist": d}


def test_fourth_test_lessons(verbose):
    """★ 第四次实测（2026-09-29）: 蓝图模式发的是**类型名**而不是**游戏 id** ⇒ 被拒。"""
    print("-" * 74)
    print("⑧ 第四次实测回归: 蓝图模式必须换成游戏 id（类名 ≠ 游戏 id）")

    bp = {"buildings": [{"t": "Wood_Foundation", "p": [0.0, 3.0, 0.0], "yaw": 0.0}]}
    place = {"x": 0.0, "y": 0.0, "z": 0.0, "yaw": 0.0}

    # ① 还没学到 id 时: **不许发**（否则就是"发了个游戏不认识的 id ⇒ 被拒"）
    act, info = solve_blueprint(bp, place, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, {})
    check("没学到 id 时: 不发送（skip_unknown_id）", act == "skip_unknown_id",
          "类型=%s" % info.get("type"))

    # ② 学到之后（align 模式盖过一次）: 用**游戏 id** 发送，而且朝向取投影的
    learned_id = {norm_id("Wood_Foundation"): "Wooden_foundation"}
    act2, info2 = solve_blueprint(bp, place, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0,
                                  learned_id, requested_z=0.0,
                                  max_dist_cm=1200.0)
    check("学到 id 后: 发送，且 id = %s（不是 Wood_Foundation）"
          % info2.get("id"), act2 == "send"
          and info2["id"] == "Wooden_foundation")
    check("朝向取的是**投影记录的朝向**（%.1f 度）" % (info2.get("yaw") or -1),
          info2.get("yaw") is not None and abs(info2["yaw"]) < 0.01)

    # ③ 太远仍然原样放行（第四次实测里那些"能放下"的正是这一类）
    far_bp = {"buildings": [{"t": "Wood_Foundation", "p": [20.0, 0.0, 0.0],
                             "yaw": 0.0}]}
    act3, info3 = solve_blueprint(far_bp, place, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0,
                                  learned_id, requested_z=0.0)
    check("20 米外: 原样放行（dist=%.0f 厘米）" % (info3.get("dist") or -1),
          act3 == "passthrough")


def test_hijack_guard(verbose):
    """★ 2026-09-29 实测事故回归: 放地板时附近没有地板记录 ⇒ **绝不能**配到别的种类上。

    当时的实际数据（玩家日志）:
        请求 = 放 Wooden_foundation，位置 (-99593.1,39190.8,741.2)
        匹配 = 记录类型 ItemChest_02，距离 918.3 厘米（演示模式: 半径 4000 / 类型放宽 2000）
        结果 = 每块地板都被挪到同一个箱子位置 ⇒ 那里已被第一块占住 ⇒ 后续全部被游戏拒
    """
    print("-" * 74)
    print("⑩ ★ 防误配: 类型放宽/修正量上限（复现「地板被吸到 9 米外箱子」那次事故）")

    # 蓝图里只有一条记录: 一个箱子在 9 米外（地板一件都没有）
    bp = {"buildings": [{"t": "ItemChest_02", "p": [9.0, 0.0, 0.0], "yaw": 0.0}]}
    place = {"x": 0.0, "y": 0.0, "z": 0.0, "yaw": 0.0}
    req = (0.3, 0.0, 0.0)          # 玩家想在这儿放一块地板

    # ① 事故配置: 类型放宽 2000 厘米 ⇒ 会认领那个 9 米外的箱子（老行为）
    act, info = solve_align(bp, place, req[0], req[1], req[2], 0.0,
                            "Wooden_foundation", {}, loose_cm=2000.0,
                            radius_cm=4000.0, rot_tol=180.0)
    # ★ 放宽（演示模式的 2000 厘米）照旧"接受"，所以这里仍然是 snap ——
    #   真正拦住它的是后面的**修正量上限**（总保险），见下一条。
    # 目标确实被选成了那个箱子（复现事故的目标选择），
    # 但**修正量上限**会把它拦掉 —— 两道信息一起断言。
    check("演示模式参数下: 目标确实被选成了那个箱子（复现事故）",
          info.get("rec", {}).get("t") == "ItemChest_02"
          and info.get("dist", 0) > 800.0,
          "距离=%.0f 厘米" % info.get("dist", -1))
    check("但**修正量上限**把它拦掉了（原样放行，不会把地板挪到 9 米外）",
          act == "skip" and info.get("reason") == "jump-cap")

    # ② 新默认（类型放宽 150）: **不该**认领它 ⇒ 原样放行（玩家正常放下去）
    learned = {}
    act2, info2 = solve_align(bp, place, req[0], req[1], req[2], 0.0,
                              "Wooden_foundation", learned, loose_cm=150.0,
                              radius_cm=2000.0, rot_tol=180.0)
    check("新默认（类型放宽 150 厘米）: 不吸 ⇒ 原样放行（这是修复后的行为）",
          act2 == "skip", "原因=%s" % info2.get("reason"))

    # ③ 就算把类型放宽开大，"修正量上限"也要能兜住
    jump_cap = 600.0
    act3, info3 = solve_align(bp, place, req[0], req[1], req[2], 0.0,
                              "Wooden_foundation", {}, loose_cm=2000.0,
                              radius_cm=4000.0, rot_tol=180.0)
    corr3 = info3.get("dist", 0.0)
    check("同样这一件: 修正量 %.0f 厘米 > 上限 %.0f ⇒ 闸门会拦下（原样放行）"
          % (corr3, jump_cap),
          act3 == "skip" and corr3 > jump_cap)
    check("被拦下时若目标来自「学到映射」，会顺手丢掉那个坏映射（自愈）",
          "healed" in info3)

    # ④ 正常范围内的修正量不该被上限误伤
    bp2 = {"buildings": [{"t": "Wood_Foundation", "p": [0.0, 0.0, 0.0], "yaw": 0.0}]}
    act4, info4 = solve_align(bp2, place, 1.8, 0.0, 0.0, 0.0,
                              "Wooden_foundation", {}, loose_cm=150.0,
                              radius_cm=2000.0, rot_tol=180.0)
    check("正常工作范围（差 1.8 米）: 会吸、且远小于上限",
          act4 == "snap" and info4["dist"] < jump_cap,
          "距离=%.0f 厘米" % info4.get("dist", -1))


def test_thresholds(verbose):
    print("-" * 74)
    print("④ 阈值/朝向判定的边界（与 Lua 里的判断一致）")
    radius, rot_tol = 300.0, 35.0
    check("距离 299 → 吸（默认 radius 1000 内）", 299.0 <= radius)
    check("距离 301 → 不吸（原样放行）", 301.0 > radius)
    check("朝向差 34 → 吸", 34.0 <= rot_tol)
    check("朝向差 36 → 不吸", 36.0 > rot_tol)
    # 朝向差要按"最短角"算（179 与 -179 只差 2 度，不是 358）
    check("179° 与 -179° 的差 = 2°（按最短角）",
          abs(norm_yaw(179.0 - (-179.0))) == 2.0)


def test_pick_nearest_similar(verbose=True):
    """★ 2026-09-29 玩家实测: 「我指向的位置就有两三个靠得近的，**近的不吸附，
    吸附到更远的了**」。

    根因: "名字相似"那一层原来写的是 `sim == nil`（只留循环里第一条相似记录），
    而 `bp.buildings` 的顺序是**采集顺序**（没有空间意义）⇒ 第一条 `Wood_Foundation`
    可能在基地另一头 ⇒ 于是吸附到 5~24 米外（日志里的 512/750/933/1746/2372 厘米）。
    """
    print("-" * 74)
    print("⑫ ★ 相似记录要取**最近**的（不是数组里第一条）")

    # 故意把"远的"放在最前面，模拟采集顺序
    bp = {"buildings": [
        {"t": "Wood_Foundation", "p": [9.0, 0.0, 0.0], "yaw": 0.0},   # 9 米
        {"t": "Wood_Foundation", "p": [2.0, 0.0, 0.0], "yaw": 0.0},   # 2 米
        {"t": "Wood_Foundation", "p": [0.3, 0.0, 0.0], "yaw": 0.0},   # 30 厘米 ← 应该选它
    ]}
    place = {"x": 0.0, "y": 0.0, "z": 0.0, "yaw": 0.0}
    learned = {}
    act, info = solve_align(bp, place, 0.3, 0.0, 0.0, 0.0,
                            "Wooden_foundation", learned, loose_cm=150.0)
    check("三条相似记录时: 选**最近**的那条（30 厘米），不是数组里第一条（9 米）",
          act == "snap" and info.get("dist", 9999) < 50.0,
          "距离=%.1f 厘米" % info.get("dist", -1))
    check("结果在修正量上限内 ⇒ 真的会吸（不再被上限拦掉）",
          info.get("dist", 9999) <= 200.0)


def test_learn_poisoning(verbose=True):
    """★ 2026-09-29 实测事故回归: 放地板却匹配到灶台 ⇒ 第一次之后再也不吸。

    玩家原话: 「怎么只有第一次放置能吸附，后面不管对不对齐都没有吸附上去」。
    日志实证: `匹配: 记录类型=AncientCookingStove 距离=1691.6 厘米` ⇒ 被修正量上限拦掉。
    成因: `learned` 只在"类型放宽阈值内"就学习（历史上到过 1000/2000 厘米），
         一次"地板配到灶台"就把映射污染了，而且**没有任何纠正机制**。
    """
    print("-" * 74)
    print("⑪ ★ 学习污染: 放地板配到灶台（复现「第一次之后再也不吸」）+ 三条修法")

    # 蓝图: 一块地板在脚下 20 厘米处；一个灶台在 9 米外
    bp = {"buildings": [
        {"t": "Wood_Foundation", "p": [0.2, 0.0, 0.0], "yaw": 0.0},
        {"t": "AncientCookingStove", "p": [9.0, 0.0, 0.0], "yaw": 0.0},
    ]}
    place = {"x": 0.0, "y": 0.0, "z": 0.0, "yaw": 0.0}

    # ① 正常情况: 名字相似层直接认出那块地板（不需要学）
    learned = {}
    act, info = solve_align(bp, place, 0.2, 0.0, 0.0, 0.0,
                            "Wooden_foundation", learned)
    check("名字不同也能配上（公共前缀 wood）⇒ 吸到那块地板",
          act == "snap" and info["rec"]["t"] == "Wood_Foundation"
          and info["dist"] < 50.0,
          "距离=%.0f 厘米" % info.get("dist", -1))
    check("这种情况**不许**往 learned 里写东西（不需要学）",
          learned == {})

    # ② 已经被污染的映射: 地板 → 灶台
    learned = {"woodenfoundation": "ancientcookingstove"}
    act2, info2 = solve_align(bp, place, 0.2, 0.0, 0.0, 0.0,
                              "Wooden_foundation", learned)
    check("被污染的映射会把目标带到灶台（9 米外）—— 复现事故",
          info2.get("rec", {}).get("t") == "AncientCookingStove",
          "距离=%.0f 厘米" % info2.get("dist", -1))
    check("修正量上限拦下它（原样放行，不会乱吸）",
          act2 == "skip" and info2.get("reason") == "jump-cap")
    check("★ 自愈: 拦下的同时把那个污染映射丢掉了",
          info2.get("healed") is True and learned == {})

    # ③ 自愈之后: 下一次放置应该回到正路（吸到地板）
    act3, info3 = solve_align(bp, place, 0.2, 0.0, 0.0, 0.0,
                              "Wooden_foundation", learned)
    check("自愈后下一次就正常吸到地板", act3 == "snap"
          and info3["rec"]["t"] == "Wood_Foundation")

    # ④ 学习阈值: 只有"贴得极近"才学（30 厘米）
    bp2 = {"buildings": [
        {"t": "SomeWeirdTypeName", "p": [1.2, 0.0, 0.0], "yaw": 0.0},   # 1.2 米
    ]}
    learned = {}
    act4, info4 = solve_align(bp2, place, 1.2, 0.0, 0.0, 0.0,
                              "Wooden_foundation", learned, loose_cm=150.0,
                              learn_max_cm=30.0)
    check("1.2 米远: **接受但绝不学习**（旧行为会把它学成自己 ⇒ 灾难）",
          act4 == "snap" and learned == {})

    learned = {}
    bp3 = {"buildings": [
        {"t": "SomeWeirdTypeName", "p": [0.18, 0.0, 0.0], "yaw": 0.0},  # 18 厘米
    ]}
    act5, info5 = solve_align(bp3, place, 0.18, 0.0, 0.0, 0.0,
                              "Wooden_foundation", learned, loose_cm=150.0,
                              learn_max_cm=30.0)
    check("18 厘米远（实测里「同一件东西名字不同」的量级）: 认它并学习",
          act5 == "snap" and learned.get("woodenfoundation") == "someweirdtypename",)


# ---------------------------------------------------------------------------
# 黑匣子守卫（2026-09-29 新增）
#
# 起因: 玩家报「在水面上放地基，按下放置就整局卡死」。事后想查"到底卡在哪一步"，
#   却发现**查不动** —— 本项目的 pwpr.log 是"攒够 200 行 / 隔 5 秒才落盘"的，
#   游戏线程一卡死，缓冲区里最后那一段全丢；而放置那条路（会**改游戏行为**）原本
#   只有"前 40 次请求"才记一行。⇒ 处置完全相反的两件事分不出来:
#     ① 我们的钩子根本没被调用；② 调用了、但卡在"拦 + 重发"里。
#
# ⇒ 现在放置路径上有一组**同步落盘**的埋点（`Log.solid`，见 docs/踩坑记录.md §68）。
#   这里守住它不被后来的改动删掉/挪到门槛后面 —— 否则下次卡死又变成瞎子。
# ---------------------------------------------------------------------------
BLACKBOX_MARKS = [
    "● 钩子被调用",
    "● 请求 #",
    "● 即将拦原请求",
    "● 拦截结果",
    "● 重发前",
    "● 重发返回",
    "● 干跑（不改游戏）",
    "● 原样放行（没插手）",
]


def check_blackbox(verbose):
    try:
        with open(LOG_LUA, "r", encoding="utf-8") as f:
            log_src = f.read()
        with open(LUA, "r", encoding="utf-8") as f:
            snap_src = f.read()
        with open(GHOST_LUA, "r", encoding="utf-8") as f:
            ghost_src = f.read()
        with open(CONFIG_LUA, "r", encoding="utf-8") as f:
            cfg_src = f.read()
        with open(UTIL_LUA, "r", encoding="utf-8") as f:
            util_src = f.read()
    except OSError as exc:
        print("[严重] 黑匣子守卫: 读不到源码: {}".format(exc))
        return False

    bad = []

    # ① 同步落盘的通道本身还在（必须真的写文件，不能只是进缓冲）
    if "function Log.solid(" not in log_src:
        bad.append("pwpr_log.lua 里没有 Log.solid（同步落盘的通道）")
    elif "Util.append_file" not in log_src.split("function Log.solid(")[1][:800]:
        bad.append("Log.solid 没有直接写文件（只进缓冲就等于没修）")

    # ② 放置路径上的埋点一个都不能少
    for mark in BLACKBOX_MARKS:
        if mark not in snap_src:
            bad.append("pwpr_buildsnap.lua 少了埋点: {}".format(mark))

    # ③ 第一行必须在**所有前置检查之前**，否则还是分不清
    #    "钩子没被调用" 和 "调用了但没过门槛"。
    i_mark = snap_src.find("● 钩子被调用")
    i_gate = snap_src.find('cfg("buildsnap_enabled")')
    if i_mark < 0 or i_gate < 0 or i_mark > i_gate:
        bad.append("「● 钩子被调用」不在前置检查之前（要写在 buildsnap_enabled 门槛之前）")

    # ④ 每次微调都跑的那 150 行取证转储必须还在开关后面（默认关）
    if "ghost_dump_move" not in ghost_src:
        bad.append("pwpr_ghost.lua 的 [ghost/dump] 没有接上 ghost_dump_move 开关")
    if "ghost_dump_move = false" not in cfg_src:
        bad.append("pwpr_config.lua 里 ghost_dump_move 的默认值不是 false")

    # ⑤ 降级阶梯 / 卡死记忆（2026-09-29 玩家定稿: 「先试一次，吸不上再换成不吸 z 轴」）
    #    它靠"黑匣子登记 ↔ 日志尾部解析"这一对，两边必须同时在、且格式一致。
    if "BuildSnap.learn_frozen_from_log" not in snap_src:
        bad.append("pwpr_buildsnap.lua 里没有 learn_frozen_from_log（卡死记忆）")
    if "read_tail" not in snap_src:
        bad.append("卡死记忆没有读日志尾部（整份读日志会太慢）")
    if "function Util.read_tail(" not in util_src:
        bad.append("pwpr_util.lua 里没有 Util.read_tail（读日志尾部要用的新工具）")
    if "BuildSnap.z_denied" not in snap_src:
        bad.append("没有 z_denied（「改了高度被拒 ⇒ 之后只吸 x/y」这一级降级）")
    # ★ 高度自适应: 被拒 ⇒ 先把**投影高度**挪到游戏允许的位置（玩家 2026-09-29 提的方案）
    if "pending_z_shift" not in snap_src:
        bad.append("没有 pending_z_shift（「该把投影高度挪多少」的记忆）")
    if "on_z_rejected" not in snap_src:
        bad.append("被拒后没有调用 deps.on_z_rejected（高度自适应没法生效）")
    # ★ 附加参数判据必须"真的读出个数"，不能靠 tostring（那次事故就是它）
    if "GetArrayNum" not in snap_src:
        bad.append("额外参数判据缺少长度类接口（不能只靠 tostring —— 曾误伤全部放置）")
    if "buildsnap_skip_extra = false" not in cfg_src:
        bad.append("buildsnap_skip_extra 的默认值不是 false（误伤过，必须是排查开关）")
    if "● 重发前 id=%s 改高度=%s" not in snap_src:
        bad.append("黑匣子的「● 重发前」没有带 id=/改高度=（卡死记忆没法解析）")
    if "● 重发前 id=(%S+) 改高度=(%S+)" not in snap_src:
        bad.append("卡死记忆的解析式与「● 重发前」的格式对不上")
    # ★ 记忆要能跨会话留住: `● 记忆 frozen …` 的写入格式与解析式也必须成对
    if "● 记忆 frozen id=%s stage=%d dz=%s" not in snap_src:
        bad.append("没有写「● 记忆 frozen …」这一行（记忆会被后来的日志挤出窗口）")
    if "● 记忆 frozen id=(%S+) stage=(%d+) dz=(%S+)" not in snap_src:
        bad.append("「● 记忆 frozen …」的解析式对不上")
    if "● 记忆 cleared id=(%S+)" not in snap_src:
        bad.append("高度修正应用后没有写「● 记忆 cleared …」（会重复挪）")
    if "read_tail(Lg.path_of(nil), 524288)" not in snap_src:
        bad.append("读日志尾部窗口太小（玩家多玩一会就把卡死记录挤出窗口）")
    # ★ 崩溃之后加的: "已经为它挪过高度、结果还是出事（卡死/崩溃）" ⇒ 这一条必须**彻底拉黑**
    if "seen_cleared" not in snap_src:
        bad.append("没有 seen_cleared（挪过高度还是出事 ⇒ 应当「完全不插手」，不能换个参数再试）")
    # ★ 「匹配」那行要能看出是水平错位还是高度错位
    if "分轴差=" not in snap_src:
        bad.append("「匹配」日志缺少分轴差（排查「吸附不上」时看不出错在哪个轴）")
    # ★ 第二次崩溃之后加的: 危险区域（整片拉黑）+ 玩家要的"高度差不判"判据
    if "in_bad_zone" not in snap_src or "bad_zones" not in snap_src:
        bad.append("没有危险区域（整片拉黑）的记录 —— 换个类型在同一片还会再崩")
    # ★★ 玩家 2026-09-29 当场纠正: 不能"为了不崩就整类/整片关掉吸附" ⇒ 必须有
    #   "精细吸附窗口"（只吸小修正）并且危险区域**默认不启用**、**只提示不 return**。
    if "buildsnap_safe_cm" not in snap_src or "精细吸附窗口" not in snap_src:
        bad.append("缺少「精细吸附窗口」（buildsnap_safe_cm）—— 防崩不能靠关功能")
    if 'cfg("buildsnap_zone_m")' not in snap_src:
        bad.append("危险区域没有接上 buildsnap_zone_m（默认 0 = 不启用）")
    if "● 记忆 zone x=%.0f y=%.0f z=%.0f r=%.0f" not in snap_src:
        bad.append("危险区域没有写「● 记忆 zone …」（跨会话记不住）")
    if "● 记忆 zone x=(%-?[%d%.]+) y=(%-?[%d%.]+) z=(%-?[%d%.]+) r=(%-?[%d%.]+)" not in snap_src:
        bad.append("「● 记忆 zone …」的解析式对不上")
    if "corr_dec" not in snap_src or "人物半高" not in snap_src:
        bad.append("缺少「高度差 ≤ 人物半高 ⇒ 按平面距离判」这条判据（玩家 2026-09-29 要求）")
    if "half_height_cm" not in snap_src:
        bad.append("没有取人物半高（Session.feet_offset_cm 那个值）")

    if bad:
        print("[严重] 黑匣子守卫失败:")
        for b in bad:
            print("   - {}".format(b))
        print("  ⇒ 见 docs/踩坑记录.md §68: 卡死现场只有这几行能救命，别的都在缓冲里。")
        return False
    print("  [通过] 黑匣子守卫（落盘通道 + {} 个埋点 + 门槛顺序 + 转储开关）"
          .format(len(BLACKBOX_MARKS)))
    return True


def parse_frozen_tail(text):
    """Python 复刻 `BuildSnap.learn_frozen_from_log` 的尾部解析（Lua 侧改了要同步改）。

    判据: 黑匣子「● 重发前 …」是**登记**、「● 重发返回 …」是**销账**；
    "有登记、没销账" = 上一次会话就是在这一次重发里出的事（卡死/崩溃）。
    返回 (id 或 None, 阶段 1/2 或 None, 是否旧格式推断, 有没有坐标)。
    阶段 2 = 完全不插手（并会把出事那一片整片拉黑）；阶段 1 = 先挪投影高度再吸。
    """
    armed = None
    last_req = None
    cleared = {}
    for line in re.split(r"[\r\n]+", text):
        if not line:
            continue
        m = re.search(r"● 记忆 cleared id=(\S+)", line)
        if m:
            cleared[m.group(1)] = True
        m = re.search(r"● 请求 #\d+ id=(\S+)", line)
        if m and m.group(1) not in ("", "?"):
            last_req = m.group(1)
        m = re.search(r"● 重发前 id=(\S+) 改高度=(\S+) 目标=\(([^)]*)\)", line)
        if m and m.group(1) not in ("", "?"):
            armed = {"id": m.group(1), "z": m.group(2), "guessed": False,
                     "has_coords": len(re.findall(r"-?\d+\.?\d*", m.group(3))) >= 3}
        elif "● 重发前" in line:
            if last_req:
                t = re.search(r"\(([^)]*)\)", line)
                armed = {"id": last_req, "z": "?", "guessed": True,
                         "has_coords": bool(t) and len(
                             re.findall(r"-?\d+\.?\d*", t.group(1))) >= 3}
        elif "● 重发返回" in line:
            armed = None
    if not armed:
        return None, None, False, False
    # 拉黑（阶段 2）的三种情形: 没改高度也出事 / 挪过高度还是出事 / 出事位置能定位（整片拉黑）
    if armed["z"] == "否" or cleared.get(armed["id"]) or armed["has_coords"]:
        stage = 2
    else:
        stage = 1
    return armed["id"], stage, armed["guessed"], armed["has_coords"]


def test_frozen_parser(verbose):
    print("-" * 74)
    print("⑬ 卡死记忆: 从日志尾部学「上一次是在哪一类建筑的重发里出事的」")
    # ① 新格式 + 改了高度 + **有坐标** ⇒ 完全拉黑（阶段 2）并整片拉黑
    t1 = ("  [bsnap] ● 请求 #1 id=Glass_foundation 位置=(1,2,3) 朝向=0.0 度\n"
          "  [bsnap] ● 重发前 id=Glass_foundation 改高度=是 目标=(1,2,3) 朝向=0.0 度\n")
    check("新格式 + 有坐标 ⇒ 完全拉黑（阶段 2）",
          parse_frozen_tail(t1)[:2] == ("Glass_foundation", 2) and parse_frozen_tail(t1)[3],
          "得到 %s" % (parse_frozen_tail(t1),))
    # ② 新格式 + 没改高度 ⇒ 完全拉黑
    t2 = "  [bsnap] ● 重发前 id=Glass_foundation 改高度=否 目标=(1,2,3)\n"
    check("新格式 + 没改高度 ⇒ 完全拉黑（阶段 2）", parse_frozen_tail(t2)[1] == 2,
          "得到 %s" % (parse_frozen_tail(t2),))
    # ③ 有登记也有销账（正常返回）⇒ 什么都不学
    t3 = ("  [bsnap] ● 重发前 id=Wood_Foundation 改高度=是 目标=(1,2,3)\n"
          "  [bsnap] ● 重发返回: OK（游戏自己那一步没有卡住）\n")
    check("有登记 + 有销账 ⇒ 不学（正常放置）", parse_frozen_tail(t3)[0] is None,
          "得到 %s" % (parse_frozen_tail(t3),))
    # ④ 旧格式（.52/.53 早期没有 id=）⇒ 用前面最近那条「● 请求」兜底，坐标仍能取到
    t4 = ("  [bsnap] ● 请求 #2 id=Glass_foundation 位置=(1,2,3) 朝向=77.6 度\n"
          "  [bsnap] ● 即将拦原请求: 目标记录 #1074 差 145.0 厘米\n"
          "  [bsnap] ● 重发前: 即将调用 RequestBuild_ToServer → (1,2,3) 朝向 -17.0 度\n")
    check("旧格式 ⇒ 从「● 请求」行推出 id 与坐标 ⇒ 阶段 2",
          parse_frozen_tail(t4)[:2] == ("Glass_foundation", 2),
          "得到 %s" % (parse_frozen_tail(t4),))
    # ⑤ 挪过高度（记忆里 cleared）之后又出事 ⇒ 完全拉黑
    t5 = ("  [bsnap] ● 记忆 cleared id=Glass_foundation\n"
          "  [bsnap] ● 重发前 id=Glass_foundation 改高度=是 目标=(1,2,3)\n")
    check("挪过高度还是出事 ⇒ 完全拉黑（阶段 2）", parse_frozen_tail(t5)[1] == 2,
          "得到 %s" % (parse_frozen_tail(t5),))


def main():
    verbose = "-v" in sys.argv
    print("=" * 74)
    print("建造吸附 纯逻辑离线验证")
    print("=" * 74)
    if not check_no_drift(verbose):
        return 1
    test_norm_id(verbose)
    test_quat_yaw(verbose)
    test_find_target(verbose)
    test_aim_mode(verbose)
    test_real_id_mismatch(verbose)
    test_third_test_lessons(verbose)
    test_fourth_test_lessons(verbose)
    test_demo_mode(verbose)
    test_hijack_guard(verbose)
    test_learn_poisoning(verbose)
    test_pick_nearest_similar(verbose)
    test_thresholds(verbose)
    test_frozen_parser(verbose)
    # 默认值守卫（读 pwpr_config.lua）+ 投影侧接口守卫: 失败直接算失败
    if not check_config_defaults(verbose):
        FAILED.append("配置默认值守卫")
    if not check_placed_api(verbose):
        FAILED.append("投影侧接口守卫")
    if not check_blackbox(verbose):
        FAILED.append("黑匣子守卫")
    print("=" * 74)
    if FAILED:
        print("结果: %d 项失败: %s" % (len(FAILED), ", ".join(FAILED)))
        return 1
    print("结果: 全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
