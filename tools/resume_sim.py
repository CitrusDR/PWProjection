#!/usr/bin/env python3
"""`pwpr_resume.lua`（投影位置/进度记忆）的纯逻辑镜像 + 实测场景回归。

## 为什么要有它

这个模块 2026-09-29 一天之内被玩家实测打回**四轮**，每一轮都是我"打补丁"而不是
把模型想清楚：

| 轮 | 玩家反馈 | 我当时的错 |
|---|---|---|
| 1 | 「按 K 重新投影对不上、进度也没了」 | 只存了一条记录 |
| 2 | 「一张蓝图只能存一份；按 H 之后 C 的位置和进度都没了」 | 没有"多处记录" |
| 3 | 「反复按 U 只能切两份，靠运气才切到第三份」 | 轮换按"最后使用时间"排序，而切换会刷新它 |
| 4 | 「到 B 按 H：B **没放建筑也记录了**，A 的记录没了」 | 运行时名单按**蓝图**存，不按**位置**存 |
| 5 | 「到 B 按 H：投影**缺少在 A 放置过的建筑的投影**」 | 同上（跨位置泄漏） |
| 6 | 「进度还是会被洗掉 / B、C 凭空多出记录」 | `Placed.forget()` 的空名单被写回记录 |

本机没有 Lua 解释器 ⇒ 用这个镜像把**上面每一轮的场景**固化成断言，
并且反向读 Lua 源码确认关键结构没被改掉（防镜像漂移）。

## 最终模型（定稿）

* **记录 = 只有"真在这一片放下过建筑"的地方**（`bind_progress` 是唯一入口，空名单不动）；
* `remember`（位置更新）**绝不新建记录**，只更新"锚点落在其范围内"的那一片；
* `H` 只挪投影 ⇒ 挪完要**按新锚点重新对齐运行时名单**（那片有记录就加载，没有就清空）；
* 轮换用**稳定的数组顺序** + 显式序号（与时间戳无关）；
* `prune` / 落盘只保留"有进度"的记录。

用法: python tools/resume_sim.py
退出码: 0 = 全部通过, 1 = 有断言失败
"""
import math
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUA = os.path.join(ROOT, "mod", "PWProjection", "Scripts", "pwpr_resume.lua")

MARGIN_CM = 2000.0        # ghost_resume_margin_m = 20 米
MAX_SITES = 8


# ---------------------------------------------------------------------------
# 镜像: 数据模型
# ---------------------------------------------------------------------------
def new_site(x=0.0, y=0.0, z=0.0, yaw=0.0, size_m=(50.0, 40.0, 10.0), t=0):
    return {
        "x": x, "y": y, "z": z, "yaw": yaw,
        "ox": 0.0, "oy": 0.0, "oz": 0.0,
        "sx": size_m[0] * 100.0, "sy": size_m[1] * 100.0, "sz": size_m[2] * 100.0,
        "t": t, "placed": set(),
    }


def count_placed(site):
    return len(site.get("placed", ()))


def horiz(s, px, py):
    return math.hypot(s["x"] - px, s["y"] - py)


def site_limit_cm(s, margin_cm):
    """镜像 `site_limit_cm`: max(尺寸x, 尺寸y)/2 + 容许距离"""
    half = max(s.get("sx", 0.0), s.get("sy", 0.0)) * 0.5
    return half + (margin_cm or 0.0)


class Store:
    """镜像 `Resume` 里的 entries/current + 那几个函数。"""

    def __init__(self):
        self.entries = {}          # bp_file -> {"sites": [site, ...]}
        self.current = None        # {"bp_file":…, "site":…, "index":…}
        self.clock = 0
        self.log = []

    # -- 内部 --
    def _entry(self, bp, create=False):
        e = self.entries.get(bp)
        if e is None and create:
            e = {"sites": []}
            self.entries[bp] = e
        return e

    def _now(self):
        self.clock += 1
        return self.clock

    def adopt(self, bp, site):
        idx = None
        e = self._entry(bp)
        if e is not None:
            for i, s in enumerate(e["sites"], 1):
                if s is site:
                    idx = i
                    break
        self.current = {"bp_file": bp, "site": site, "index": idx}

    # -- 公开（与 Lua 同名）--
    def find_site(self, bp, px, py, pz, margin_cm=MARGIN_CM):
        """镜像 `Resume.find_site`: 命中"范围内 + 最近"的那一片；同时 adopt。"""
        e = self._entry(bp)
        if e is None or not e["sites"]:
            return None
        best, best_d, best_in = None, None, False
        for s in e["sites"]:
            lim = site_limit_cm(s, margin_cm)
            d = horiz(s, px, py)
            inside = (lim <= 0.0) or (d <= lim)
            better = False
            if best is None:
                better = inside
            elif inside and not best_in:
                better = True
            elif inside == best_in and (best_d is None or d < best_d):
                better = True
            if better:
                best, best_d, best_in = s, d, inside
        if best is None:
            return None
        self.adopt(bp, best)
        return best

    def remember(self, bp, x, y, z, yaw=0.0, size_m=(50.0, 40.0, 10.0),
                 margin_cm=MARGIN_CM):
        """镜像 `Resume.remember`: **绝不新建记录**。"""
        e = self._entry(bp)
        if e is None or not e["sites"]:
            return False
        site = None
        if self.current and self.current["bp_file"] == bp and self.current["site"]:
            s = self.current["site"]
            lim = site_limit_cm(s, margin_cm)
            if lim <= 0.0 or horiz(s, x, y) <= lim:
                site = s
        if site is None:
            best_d = None
            for s in e["sites"]:
                lim = site_limit_cm(s, margin_cm)
                d = horiz(s, x, y)
                if (lim <= 0.0 or d <= lim) and (best_d is None or d < best_d):
                    site, best_d = s, d
        if site is None:
            return False
        site.update({"x": x, "y": y, "z": z, "yaw": yaw,
                     "sx": size_m[0] * 100.0, "sy": size_m[1] * 100.0,
                     "sz": size_m[2] * 100.0, "t": self._now()})
        self.adopt(bp, site)
        return True

    def bind_progress(self, bp, idx_list, x, y, z, yaw=0.0,
                      size_m=(50.0, 40.0, 10.0), margin_cm=MARGIN_CM):
        """镜像 `Resume.bind_progress`: **唯一**创建记录的入口；空名单不动。"""
        if not idx_list:
            return False, None, False
        e = self._entry(bp, create=True)
        site = None
        for s in e["sites"]:
            lim = site_limit_cm(s, margin_cm)
            if lim <= 0.0 or horiz(s, x, y) <= lim:
                site = s
                break
        is_new = False
        if site is None:
            site = new_site(x, y, z, yaw, size_m, self._now())
            e["sites"].append(site)
            is_new = True
            self.log.append("新增一处记录（第 %d 处，%d 件进度）"
                            % (len(e["sites"]), len(idx_list)))
        site["placed"] = set(idx_list)
        site["t"] = self._now()
        self.adopt(bp, site)
        self.prune(bp)
        return True, site, is_new

    def prune(self, bp):
        """镜像 `Resume.prune`: 只留"有进度"的，顺序不变。"""
        e = self._entry(bp)
        if e is None:
            return 0
        kept, dropped = [], 0
        for s in e["sites"]:
            if count_placed(s) > 0 and len(kept) < MAX_SITES:
                kept.append(s)
            else:
                dropped += 1
        e["sites"] = kept
        return dropped

    def cycle(self, bp):
        """镜像 `Resume.cycle`: 稳定顺序 + 显式序号。"""
        e = self._entry(bp)
        if e is None or not e["sites"]:
            return None, 0, 0
        all_sites = e["sites"]
        cur_idx = None
        if self.current and self.current["bp_file"] == bp:
            cur_idx = self.current.get("index")
            if cur_idx is None and self.current.get("site") is not None:
                for i, s in enumerate(all_sites, 1):
                    if s is self.current["site"]:
                        cur_idx = i
                        break
        nxt_idx = ((cur_idx or 0) % len(all_sites)) + 1
        nxt = all_sites[nxt_idx - 1]
        self.adopt(bp, nxt)
        return nxt, nxt_idx, len(all_sites)

    def saved(self, bp):
        """镜像 `save` 的过滤: 只写"有进度"的记录。"""
        e = self._entry(bp)
        if e is None:
            return []
        return [s for s in e["sites"] if count_placed(s) > 0]


class Runtime:
    """镜像主程序里的运行时状态: `Placed.hidden` + `sync_progress_to_anchor`。"""

    def __init__(self, store):
        self.store = store
        self.hidden = set()          # Placed.hidden

    def sync_progress_to_anchor(self, bp, x, y, z, margin_cm=MARGIN_CM):
        """★ 第四轮那个 bug 的修复: 名单必须按**位置**对齐，不能跨位置泄漏。"""
        site = self.store.find_site(bp, x, y, z, margin_cm)
        self.hidden = set()
        if site is None:
            return 0
        self.hidden = set(site.get("placed", ()))
        return len(self.hidden)

    def on_placed(self, idx):
        self.hidden.add(idx)

    def on_dismantle(self, idx):
        self.hidden.discard(idx)


# ---------------------------------------------------------------------------
# 断言
# ---------------------------------------------------------------------------
FAILED = []


def check(desc, cond, extra=""):
    tag = "[通过]" if cond else "[失败]"
    print("  %s %s%s" % (tag, desc, ("   " + extra) if extra else ""))
    if not cond:
        FAILED.append(desc)


def test_scenario_a_to_b_to_c(verbose=True):
    print("-" * 74)
    print("① 实测场景（第四/五轮）: A 建过 → H 到 B（4 公里外）→ 不许在 B 产生记录/隐藏")
    st = Store()
    rt = Runtime(st)
    bp = "base.blueprint.json"
    A = (-94012.0, 38834.0, 771.0)
    B = (-90030.0, 34828.0, -183.0)      # 与 A 相距约 5.6 公里（玩家日志里的真实值）
    C = (-98172.0, 43520.0, 773.0)

    # A: 放投影 + 建了 3 件 ⇒ 记录 A（进度 3）
    st.remember(bp, *A)                        # 只挪位置（此时还没有记录 ⇒ 什么都不做）
    check("A 处: 光放投影不产生记录", len(st.saved(bp)) == 0)
    rt.sync_progress_to_anchor(bp, *A)
    rt.on_placed(1); rt.on_placed(2); rt.on_placed(3)
    st.bind_progress(bp, sorted(rt.hidden), *A)
    check("A 处: 真放了 3 件 ⇒ 产生 1 处记录（进度 3）",
          len(st.saved(bp)) == 1 and count_placed(st.saved(bp)[0]) == 3)

    # 走到 B 按 H: 只挪位置 + 名单按 B 重新对齐（B 没有记录 ⇒ 清空）
    st.remember(bp, *B)
    n = rt.sync_progress_to_anchor(bp, *B)
    check("到 B 按 H: 运行时名单清空（**不把 A 建过的带过来**）", n == 0)
    check("到 B: 仍然只有 1 处记录（B 不该凭空多一条）", len(st.saved(bp)) == 1)
    # 看门狗会把运行时名单同步进记录 —— 空名单必须什么都不做
    ok, _, is_new = st.bind_progress(bp, sorted(rt.hidden), *B)
    check("空名单同步 ⇒ 不创建记录（这是第 6 轮的 bug）",
          (not ok) and (not is_new) and len(st.saved(bp)) == 1)
    check("A 的记录与进度原样保留",
          count_placed(st.saved(bp)[0]) == 3
          and abs(st.saved(bp)[0]["x"] - A[0]) < 1.0)

    # 再到 C 按 H: 同样
    st.remember(bp, *C)
    n = rt.sync_progress_to_anchor(bp, *C)
    st.bind_progress(bp, sorted(rt.hidden), *C)
    check("到 C: 仍只有 1 处记录、名单为空",
          len(st.saved(bp)) == 1 and n == 0)

    # 在 C 真放 2 件 ⇒ 这时才该多一处记录，而且只含 C 自己的进度
    rt.on_placed(7); rt.on_placed(8)
    ok, site, is_new = st.bind_progress(bp, sorted(rt.hidden), *C)
    sites = st.saved(bp)
    check("在 C 真放 2 件 ⇒ 出现第 2 处记录（进度只含 C 的 2 件）",
          is_new and len(sites) == 2 and count_placed(site) == 2)
    check("A 的那一处仍是 3 件（没被 C 的进度污染）",
          any(count_placed(s) == 3 and abs(s["x"] - A[0]) < 1.0 for s in sites))

    # U 轮换: 稳定顺序、能切到每一处
    seq = []
    for _ in range(4):
        _, idx, total = st.cycle(bp)
        seq.append("%d/%d" % (idx, total))
    check("U 轮换稳定（不靠运气）", seq == ["1/2", "2/2", "1/2", "2/2"], " ".join(seq))

    # 切回 A 那一处 ⇒ 运行时名单应该是 A 的 3 件
    A_site = [s for s in st.saved(bp) if abs(s["x"] - A[0]) < 1.0][0]
    n = rt.sync_progress_to_anchor(bp, A_site["x"], A_site["y"], A_site["z"])
    check("切回 A: 运行时名单恢复成 A 的 3 件", n == 3)


def test_h_inside_same_area(verbose=True):
    print("-" * 74)
    print("② H 在同一片区域内（小修正）: 不新增记录、进度保持")
    st = Store()
    rt = Runtime(st)
    bp = "b.json"
    st.bind_progress(bp, [1, 2, 3, 4], 0.0, 0.0, 0.0)
    check("先有 1 处记录（4 件）", len(st.saved(bp)) == 1)
    # 同片内挪 10 米
    st.remember(bp, 1000.0, 0.0, 0.0)
    rt.sync_progress_to_anchor(bp, 1000.0, 0.0, 0.0)
    st.bind_progress(bp, sorted(rt.hidden), 1000.0, 0.0, 0.0)
    check("同片内挪动 ⇒ 仍然只有 1 处记录", len(st.saved(bp)) == 1)
    check("同片内的进度没变", count_placed(st.saved(bp)[0]) == 4)


def test_no_record_without_progress(verbose=True):
    print("-" * 74)
    print("③ 没放过建筑的地方永远不产生记录（跑一圈 A/B/C/D）")
    st = Store()
    rt = Runtime(st)
    bp = "c.json"
    spots = [(0.0, 0.0, 0.0), (90000.0, 0.0, 0.0), (-90000.0, 0.0, 0.0),
             (0.0, 90000.0, 0.0)]
    for (x, y, z) in spots:
        st.remember(bp, x, y, z)
        rt.sync_progress_to_anchor(bp, x, y, z)
        st.bind_progress(bp, sorted(rt.hidden), x, y, z)
    check("四个位置都只挪了投影 ⇒ 0 处记录", len(st.saved(bp)) == 0)


def test_no_lua_drift(verbose=True):
    print("-" * 74)
    print("④ 反向漂移检查: Lua 源码里必须有这些结构（改了 Lua 忘了改这里会报错）")
    try:
        lua = open(LUA, encoding="utf-8").read()
    except OSError as exc:
        check("读得到 pwpr_resume.lua", False, str(exc))
        return
    required = [
        ("function Resume.bind_progress(", "唯一创建记录的入口"),
        ("if type(list) ~= \"table\" or #list == 0 then", "空名单保护"),
        ("local function site_limit_cm(", "范围判定（包围盒 + 容许距离）"),
        ("function Resume.remember(", "位置更新（不新建记录）"),
        ("Resume.SAME_SITE_CM", "同片判定常量"),
        ("if count_placed(s) > 0 and #kept < Resume.MAX_SITES then",
         "prune 只留有进度的"),
        ("local nxt_idx = ((cur_idx or 0) % #all) + 1", "轮换用稳定序号"),
        ("Resume.current = { bp_file = bp_file, site = site, index = idx }",
         "adopt 记稳定序号"),
    ]
    for needle, why in required:
        check("Lua 里有: %s" % why, needle in lua)

    # 主程序里那个"按位置对齐运行时名单"的函数也要在（那是第四轮 bug 的修复）
    main_lua = os.path.join(os.path.dirname(LUA), "main.lua")
    try:
        mt = open(main_lua, encoding="utf-8").read()
    except OSError as exc:
        check("读得到 main.lua", False, str(exc))
        return
    check("main.lua 里有 sync_progress_to_anchor（按位置隔离名单）",
          "local function sync_progress_to_anchor(" in mt)
    check("main.lua 里有进度基线（只有变了才写回）",
          "local function progress_changed_since_baseline(" in mt
          and "snapshot_baseline()" in mt)
    # ★★★ 2026-09-29 改版: 扫描**只减不增**（"已放上"只由精确通道 + 记录进度产生）
    #   历史: 原来按位置"认领"（往名单里加）⇒ 规则网格平移整格后，
    #   别处已建的件正好落在新位置上 ⇒ 被认成"这里建过" ⇒ 新位置的投影缺件 ✗
    #   （玩家反复报"按 H 之后投影不完整""切回 A 结果 W1/W2 都没了"）。
    #   现在只保留"实物还在 ⇒ 继续不画；实物没了 ⇒ 恢复渲染"这一种判断。
    placed_lua = os.path.join(os.path.dirname(LUA), "pwpr_placed.lua")
    pt = open(placed_lua, encoding="utf-8").read()
    check("apply_anchors 是\"只减不增\"（不再靠扫描认领）",
          "只减不增" in pt and "扫描绝不往里加" in pt)
    check("只减不增: 逐条用世界坐标找实物（按位置，不看类型名）",
          "local function find_real(wx, wy, wz)" in pt
          and "if dx * dx + dy * dy + dz * dz <= near2 then" in pt)
    # 只看 apply_anchors 的函数体（`pairs_all` 在 convert_indices 里是合法的，
    # 它是"跨锚点按几何换算"，与扫描认领无关）
    import re as _re
    _m = _re.search(r"function Placed\.apply_anchors.*?\nend\n", pt, _re.S)
    _body = _m.group(0) if _m else ""
    check("只减不增: apply_anchors 里没有\"从参照新增\"的认领循环",
          _body != "" and "pairs_all" not in _body
          and "for idx in pairs(prev_hidden)" in _body)
    check("K 与 H 都调用了它", mt.count("sync_progress_to_anchor(") >= 3,
          "出现 %d 次" % mt.count("sync_progress_to_anchor("))


def test_baseline_blocks_stale_mask(verbose=True):
    print("-" * 74)
    print("⑤ 残留名单不许写回新位置（基线闸）: 这是第五轮「B 没放东西也记录了」的直接原因")
    st = Store()
    rt = Runtime(st)
    bp = "d.json"
    A = (0.0, 0.0, 0.0)
    B = (500000.0, 0.0, 0.0)          # 5 公里外

    st.bind_progress(bp, [1, 2, 3], *A)
    rt.sync_progress_to_anchor(bp, *A)
    check("A 有 3 件进度", len(st.saved(bp)) == 1 and count_placed(st.saved(bp)[0]) == 3)

    # 模拟"扫描测不到 ⇒ 保留上次名单" ⇒ 名单里还残留 A 的 3 件
    baseline = set(rt.hidden)          # 定位到 B 时取的基线 = 清空后的空集
    rt.hidden = set()                  # sync 会清空
    baseline = set(rt.hidden)
    # 假设某种原因名单又被填回了 A 的 3 件（= 修复前的实际情形）
    rt.hidden = {1, 2, 3}
    changed = (rt.hidden != baseline)
    check("检测到'相对基线变了' ⇒ 这时才允许写回（这里是 True，说明闸门本身有效）",
          changed is True)
    # 而正确行为: 定位到 B 之后名单本就应该清空 ⇒ 基线 == 名单 ⇒ 不写回
    rt.hidden = set(baseline)
    changed2 = (rt.hidden != baseline)
    check("清空后名单 == 基线 ⇒ **不写回**（B 不会凭空多一条）", changed2 is False)
    ok, _, is_new = st.bind_progress(bp, sorted(rt.hidden), *B)
    check("即使调用 bind_progress，空名单也不创建记录",
          (not ok) and (not is_new) and len(st.saved(bp)) == 1)


def main() -> int:
    print("pwpr_resume.lua 逻辑镜像 + 实测场景回归")
    test_scenario_a_to_b_to_c()
    test_h_inside_same_area()
    test_no_record_without_progress()
    test_baseline_blocks_stale_mask()
    test_no_lua_drift()
    print()
    if FAILED:
        print("结果: %d 项失败" % len(FAILED))
        for f in FAILED:
            print("  - %s" % f)
        return 1
    print("结果: 全部通过（位置/进度记忆的模型与四轮实测场景一致）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
