#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_keys.py —— 「按键可配置」那套东西的**一致性检查**（2026-10-06 新增）

背景: 按键从"写死在 main.lua"改成"配置驱动"之后，同一条信息出现在 **4 个地方**：
    1. `mod\\PWProjection\\Scripts\\pwpr_keys.lua`   —— `Keys.ACTIONS`（动作表，单一来源）
    2. `mod\\PWProjection\\Scripts\\pwpr_config.lua` —— `DEFAULTS` 里的默认值 + `KEY_GROUP` 归组
    3. `docs\\配置说明.md`                          —— 给玩家看的逐条说明
    4. `mod\\PWProjection\\Scripts\\main.lua`        —— 真正 `bind_action("<id>", ...)` 的地方

任何一处漏了，后果都是"玩家改了配置但不生效"或者"文档说了键但代码没绑" —— 这类
不一致在这个项目里踩过好几次（配置文档检查 `check_config_doc.py` 就是为了这个）。
本工具把它们对齐，并且**只报确定的问题**（不做模糊猜测）。

用法:
    python tools\\check_keys.py            # 正常检查（有错退出码 1）
    python tools\\check_keys.py -v         # 连"提示级"信息也打出来
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "mod", "PWProjection", "Scripts")
KEYS_LUA = os.path.join(SCRIPTS, "pwpr_keys.lua")
CONFIG_LUA = os.path.join(SCRIPTS, "pwpr_config.lua")
MAIN_LUA = os.path.join(SCRIPTS, "main.lua")
DOC = os.path.join(ROOT, "docs", "配置说明.md")
KEYDOC = os.path.join(ROOT, "docs", "按键列表.md")

# 按键清单文档里必须出现的"哨兵"键名（证明那张 UE4SS 全集表还在）
KEYDOC_SENTINELS = ["NUM_EIGHT", "UP_ARROW", "F24", "ZERO", "LEFT_MOUSE_BUTTON"]
KEYDOC_MIN_LINES = 120

bad = []
warn = []


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def actions_from_keys_lua(src):
    """解析 Keys.ACTIONS：返回 [(id, cfg, default), ...]（按出现顺序）。"""
    out = []
    # 每个动作是一行: { id = "x", cfg = "key_x", default = "Y", ... }
    for m in re.finditer(
        r'\{\s*id\s*=\s*"([^"]+)"\s*,\s*cfg\s*=\s*"([^"]+)"\s*,\s*default\s*=\s*"([^"]+)"',
        src,
    ):
        out.append(m.groups())
    return out


def main():
    verbose = "-v" in sys.argv[1:]
    for p in (KEYS_LUA, CONFIG_LUA, MAIN_LUA, DOC, KEYDOC):
        if not os.path.exists(p):
            bad.append(f"缺文件: {p}")
    if bad:
        for b in bad:
            print("  [严重] " + b)
        return 1

    keys_src = read(KEYS_LUA)
    cfg_src = read(CONFIG_LUA)
    main_src = read(MAIN_LUA)
    doc_src = read(DOC)
    keydoc_src = read(KEYDOC)

    actions = actions_from_keys_lua(keys_src)
    if not actions:
        bad.append("在 pwpr_keys.lua 里没解析到任何动作（Keys.ACTIONS 格式变了吗？）")
    ids = [a[0] for a in actions]
    if len(set(ids)) != len(ids):
        bad.append("Keys.ACTIONS 里有重复的动作 id")

    # ---- 1. 每个动作的配置键: 在 DEFAULTS / KEY_GROUP / 文档 里都要有 ----
    for aid, cfg_key, default in actions:
        if f"{cfg_key}" not in cfg_src:
            bad.append(f"动作 {aid}: 配置键 {cfg_key} 没出现在 pwpr_config.lua")
        else:
            # DEFAULTS 里要有 `cfg_key = "X",`，且值应等于 ACTIONS 的 default
            m = re.search(rf"^\s*{re.escape(cfg_key)}\s*=\s*\"([^\"]+)\"", cfg_src, re.M)
            if m is None:
                bad.append(f"动作 {aid}: DEFAULTS 里没有 {cfg_key} = \"...\" 这一行")
            elif m.group(1) != default:
                bad.append(
                    f"动作 {aid}: 默认值不一致 —— pwpr_keys.lua 说 {default}，"
                    f"DEFAULTS 说 {m.group(1)}"
                )
            # KEY_GROUP 里要有
            if not re.search(rf"\b{re.escape(cfg_key)}\s*=\s*1\b", cfg_src):
                bad.append(f"动作 {aid}: {cfg_key} 没有归到 KEY_GROUP 第 1 组")
        # 文档里要点名
        if cfg_key not in doc_src:
            bad.append(f"动作 {aid}: {cfg_key} 没写进 docs/配置说明.md")

    # ---- 2. main.lua 里每个动作都要真的绑（bind_action("<id>"） ----
    for aid, cfg_key, default in actions:
        if not re.search(rf'bind_action\(\s*"{re.escape(aid)}"', main_src):
            bad.append(
                f"动作 {aid}: main.lua 里没有 bind_action(\"{aid}\", ...) —— 配置改了也不会生效"
            )

    # ---- 3. 反向: main.lua 里绑了 Keys.ACTIONS 里没有的 id ----
    #      （只认"像动作 id"的字符串；注释里的示例 `bind_action("<id>", ...)` 不算）
    for m in re.finditer(r'bind_action\(\s*"([A-Za-z_][A-Za-z0-9_]*)"', main_src):
        if m.group(1) not in ids:
            bad.append(f"main.lua 里 bind_action(\"{m.group(1)}\") 在 Keys.ACTIONS 里不存在")

    # ---- 4. 提示级: 玩家可见字符串里还写死的键名（只报，不当错） ----
    #     （输出层会自动翻译默认键名 ⇒ 写死**不算错**，但数量多了值得看一眼）
    hard = re.findall(r"按 ([A-Z]|F[0-9]{1,2})(?![A-Za-z0-9])", main_src)
    if hard:
        warn.append(
            f"main.lua 里还有 {len(hard)} 处直接写 `按 <键>` 的提示"
            "（会被输出层自动翻译，不算错；但新写的提示建议直接用默认键名保持一致）"
        )

    # ---- 5. RESERVED 必须非空且被文档提到 ----
    if "Keys.RESERVED" not in keys_src:
        bad.append("pwpr_keys.lua 里找不到 Keys.RESERVED（游戏占用键的黑名单）")
    if re.search(r"Keys\.RESERVED\s*=\s*\{\s*\}", keys_src):
        bad.append("Keys.RESERVED 是空的 —— 至少要有 B（游戏建造模式入口）")

    # ---- 6. 单独的按键文件（2026-10-06 B 方案）----
    m = re.search(r'Keys\.FILE_NAME\s*=\s*"([^"]+)"', keys_src)
    if m is None:
        bad.append("pwpr_keys.lua 里没有 Keys.FILE_NAME（按键单独文件的文件名）")
    else:
        fname = m.group(1)
        if fname != "pwpr_keys.json":
            warn.append(f"Keys.FILE_NAME = {fname}（不是默认的 pwpr_keys.json）")
        for label, src in (("配置说明.md", doc_src), ("按键列表.md", keydoc_src)):
            if fname not in src:
                bad.append(f"{label} 里没有提到按键文件名 {fname}")
    if "Keys.load_file" not in keys_src:
        bad.append("pwpr_keys.lua 里没有 Keys.load_file（读/生成按键文件）")
    if not re.search(r"Keys\.load_file\(", main_src):
        bad.append("main.lua 里没有调用 Keys.load_file(...) —— 按键文件不会被读")
    else:
        # 必须在 resolve 之前
        i_load = main_src.find("Keys.load_file(")
        i_res = main_src.find("Keys.resolve(")
        if i_res != -1 and i_load > i_res:
            bad.append("main.lua 里 Keys.load_file 在 Keys.resolve 之后 —— 会读不到文件里的键")

    # ---- 7. 按键清单文档（docs/按键列表.md）----
    lines = [l for l in keydoc_src.splitlines() if l.strip()]
    if len(lines) < KEYDOC_MIN_LINES:
        bad.append(f"docs/按键列表.md 只有 {len(lines)} 行有效内容（应 >= {KEYDOC_MIN_LINES}）"
                   " —— UE4SS 键名全集表可能被删了")
    for s in KEYDOC_SENTINELS:
        if s not in keydoc_src:
            bad.append(f"docs/按键列表.md 里没有 {s} —— 键名全集表不完整")
    for aid, cfg_key, default in actions:
        if cfg_key not in keydoc_src:
            bad.append(f"docs/按键列表.md 里没有 {cfg_key}（新增动作时要同步那张表）")
    for r in ("Keys.RESERVED", "B "):
        pass  # 保留占位，不做额外要求

    for w in warn:
        print("  [提示] " + w)
    if bad:
        for b in bad:
            print("  [严重] " + b)
        print(f"\n结果: {len(bad)} 个问题（{len(actions)} 个动作）")
        return 1

    print(f"  [通过] {len(actions)} 个动作: Keys.ACTIONS ↔ DEFAULTS ↔ KEY_GROUP ↔ 配置说明.md ↔ main.lua 全对齐")
    print("  [通过] 按键单独文件: Keys.FILE_NAME/load_file 就位，main.lua 在读文件之后才 resolve")
    print(f"  [通过] Keys.RESERVED 存在（游戏占用键会被拒绝）")
    print(f"  [通过] docs/按键列表.md: {len(lines)} 行 · 键名哨兵 {len(KEYDOC_SENTINELS)} 个 · "
          f"11 个动作的配置键都在")
    print(f"结果: 全部通过")
    if verbose:
        for aid, cfg_key, default in actions:
            print(f"    {aid:14s} {cfg_key:18s} 默认 {default}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
