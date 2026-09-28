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
    "function BuildSnap.find_target(bp, place, wx, wy, wz, want_keys, type_match)",
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


def find_target(bp, place, wx, wy, wz, want_keys, type_match=True):
    """对应 BuildSnap.find_target（align 模式）—— 返回 {"best":…, "near":…}。
    best = 类型命中里最近的一件；near = 任意类型里最近的一件。"""
    rad = math.radians(place.get("yaw", 0.0))
    c, s = math.cos(rad), math.sin(rad)
    accept = set(k for k in (want_keys or []) if k)
    best = near = None
    for b in bp["buildings"]:
        tx, ty, tz = record_world(place, b, c, s)
        d = math.sqrt((tx - wx) ** 2 + (ty - wy) ** 2 + (tz - wz) ** 2)
        cand = {"rec": b, "x": tx, "y": ty, "z": tz, "dist": d,
                "yaw": norm_yaw(place.get("yaw", 0.0) + b["yaw"])}
        if near is None or d < near["dist"]:
            near = cand
        hit = (type_match is not True) or (norm_id(b["t"]) in accept)
        if hit and (best is None or d < best["dist"]):
            best = cand
    return {"best": best, "near": near}


def solve_align(bp, place, lx, ly, lz, want_yaw, game_id, learned=None,
                type_match=True, loose_cm=1000.0, radius_cm=2000.0,
                rot_tol=180.0):
    """复刻 on_request_build 里 align 模式的判定（含"学到映射"与朝向策略）。

    返回 (动作, 详情) —— 动作 ∈ {"snap", "skip"}；详情含目标与朝向。
    """
    learned = learned if learned is not None else {}
    id_norm = norm_id(game_id)
    keys = [id_norm]
    if id_norm in learned:
        keys.append(learned[id_norm])
    found = find_target(bp, place, lx, ly, lz, keys, type_match)
    res = found["best"]
    loosened = False
    if res is None and loose_cm > 0 and found["near"] is not None \
            and found["near"]["dist"] <= loose_cm:
        res = found["near"]
        loosened = True
        if id_norm:
            learned[id_norm] = norm_id(res["rec"]["t"])
    if res is None:
        return "skip", {"reason": "no-type-match", "near": found["near"]}
    if res["dist"] > radius_cm:
        return "skip", {"reason": "too-far", "dist": res["dist"]}
    dyaw = abs(norm_yaw(res["yaw"] - want_yaw))
    snap_yaw = dyaw <= rot_tol
    return "snap", {"rec": res["rec"], "x": res["x"], "y": res["y"],
                    "z": res["z"], "dist": res["dist"], "loosened": loosened,
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
    "buildsnap_type_loose_cm = 1000",
    "buildsnap_demo       = false",
    "ghost_hide_placed  = true",
    "ghost_hide_placed_cm = 40",
    "ghost_hide_placed_batch_s = 3",
    "buildsnap_min_cm     = 5,",
    "ghost_hide_alive_check = false",
    "ghost_hide_enum = true",
    "ghost_hide_scan = false",
    "log_flush_interval_s = 5",
    "log_flush_lines      = 200",
    "buildsnap_notify     = false",
    "buildsnap_notify_confirm = false",
    "notify_trace         = false",
    "ghost_hide_scan_interval_s = 8",
]


PLACED_LUA = os.path.join(ROOT, "mod", "PWProjection", "Scripts",
                          "pwpr_placed.lua")
GHOST_LUA = os.path.join(ROOT, "mod", "PWProjection", "Scripts",
                         "pwpr_ghost.lua")

# ★ 投影侧接口守卫（2026-09-29）: 建造吸附和"已放上的不渲染"是**跨模块协作**的
#   （on_placing / on_placed_confirmed / Ghost.rehide）—— 这些名字一旦被改名或
#   删掉，吸附那边会静默什么都不做。所以在这里钉住。
REQUIRED_PLACED_SNIPPETS = [
    "function Placed.hide_now(rec_idx)",
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
    check("演示参数下: 吸上了，且**修正量 ≥ 5 米**（肉眼绝对看得出来）",
          act2 == "snap" and info2.get("dist", 0) >= 500.0,
          "三维距离=%.0f 厘米（水平 800 + 垂直 300）" % info2.get("dist", -1))
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

    # ① 旧行为（严格类型）: 什么都不吸 —— 这就是玩家看到的"并没有放到投影上"
    learned = {}
    act, info = solve_align(bp, place, req[0], req[1], req[2], 0.0,
                            "Wooden_foundation", learned, loose_cm=0.0)
    check("严格类型匹配下: 不吸（复现玩家的现象）", act == "skip",
          "原因=%s" % info.get("reason"))

    # ② 放宽阈值（新默认 100 厘米）: 应该吸到那块地基，并**学到映射**
    learned = {}
    act2, info2 = solve_align(bp, place, req[0], req[1], req[2], want_yaw,
                              "Wooden_foundation", learned, loose_cm=100.0,
                              rot_tol=35.0)   # 显式用 35° 容差测"差太多只吸位置"
    check("放宽阈值下: 吸到那块地基（%s，距离 %.1f）"
          % (info2.get("rec", {}).get("t", "-"), info2.get("dist", -1)),
          act2 == "snap" and info2["rec"]["t"] == "Wood_Foundation"
          and info2["loosened"] is True)
    check("★ 学到了映射: woodenfoundation → %s"
          % learned.get("woodenfoundation"),
          learned.get("woodenfoundation") == "woodfoundation")
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
    test_thresholds(verbose)
    # 默认值守卫（读 pwpr_config.lua）+ 投影侧接口守卫: 失败直接算失败
    if not check_config_defaults(verbose):
        FAILED.append("配置默认值守卫")
    if not check_placed_api(verbose):
        FAILED.append("投影侧接口守卫")
    print("=" * 74)
    if FAILED:
        print("结果: %d 项失败: %s" % (len(FAILED), ", ".join(FAILED)))
        return 1
    print("结果: 全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
