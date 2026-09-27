#!/usr/bin/env python3
"""配置说明文档检查器。

目的（玩家 2026-09-28 要求）:
    配置开关必须有落脚点，避免以后"重复造相同或类似的功能"。
    所以这里强制检查两件事:
      ① **每一个写在 pwbp_config.lua 的 DEFAULTS 里的键，
         都必须在 docs/配置说明.md 里出现过**（漏了就报错，防止文档悄悄过期）；
      ② **每一个"配置文件"（代码里真正会读写的那些 .json）
         都必须在文档里被点名**（玩家反馈: 翻到好几个命名很像的配置文件，
         文档却只说参数、不说文件 ⇒ 现在就按文件分标题，并在这里强制）。

用法:
    python tools/check_config_doc.py
退出码: 0 = 通过, 1 = 有问题
"""
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SCRIPTS = os.path.join(ROOT, "mod", "PWBlueprint", "Scripts")
CONFIG = os.path.join(SCRIPTS, "pwbp_config.lua")
DOC = os.path.join(ROOT, "docs", "配置说明.md")

# 这些 .json 是"配置文件"（代码会读写），必须在文档里点名。
# 报告类（pwbp.log / pwbp_meshes.txt / pwbp_ui.txt / pwbp_probe.txt）不算配置。
CONFIG_FILES = [
    "pwbp_config.json",
    "pwbp_meshmap.default.json",
    "pwbp_meshmap.json",
    "pwbp_capabilities.json",
]


def defaults_keys(path):
    src = open(path, encoding="utf-8").read()
    i = src.find("local DEFAULTS")
    if i < 0:
        raise SystemExit("在 %s 里找不到 local DEFAULTS" % path)
    j = src.find("\n}", i)
    body = src[i:j]
    keys = []
    for ln in body.split("\n"):
        s = ln.strip()
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=", s)
        if m and not s.startswith("--"):
            keys.append(m.group(1))
    return keys


def main():
    if not os.path.exists(CONFIG):
        print("找不到配置文件:", CONFIG)
        return 1
    if not os.path.exists(DOC):
        print("找不到配置说明文档:", DOC)
        return 1

    keys = defaults_keys(CONFIG)
    doc = open(DOC, encoding="utf-8").read()

    missing = [k for k in keys if ("`%s`" % k) not in doc]
    print("配置说明检查")
    print("  DEFAULTS 键数: %d" % len(keys))
    print("  文档: %s" % os.path.relpath(DOC, ROOT))
    if missing:
        print("  [严重] 以下配置键没有写进文档（共 %d 个）:" % len(missing))
        for k in missing:
            print("    - %s" % k)
        print("  ⇒ 请在 docs/配置说明.md 里补上（带一句「什么时候该改」）")
        return 1

    # 反向检查: 文档里写了 `xxx` 但 DEFAULTS 里没有 —— 多半是删了键没更新文档
    doc_keys = set(re.findall(r"`([a-z][a-z0-9_]{2,})`", doc))
    extra = sorted(k for k in doc_keys if k not in keys and "_" in k)
    if extra:
        print("  [提示] 文档里提到、但 DEFAULTS 里没有的键（可能是旧键名/示例）:")
        for k in extra:
            print("    - %s" % k)

    # ② 每个"配置文件"都要被文档点名（玩家 2026-09-28 反馈: 文件太多分不清）
    missing_files = [f for f in CONFIG_FILES if f not in doc]
    # 代码里真的会读写的 .json 文件名，和上面的清单核对（防止代码新增文件却漏登记）
    code_files = set()
    for p in glob.glob(os.path.join(SCRIPTS, "*.lua")):
        text = open(p, encoding="utf-8").read()
        for m in re.finditer(r'"([A-Za-z0-9_\.]+\.json)"', text):
            code_files.add(m.group(1))
    unregistered = sorted(f for f in code_files
                          if f not in CONFIG_FILES
                          and not f.endswith(".blueprint.json")
                          and f != "package.json")
    if missing_files:
        print("  [严重] 以下配置文件没有在文档里出现（共 %d 个）:" % len(missing_files))
        for f in missing_files:
            print("    - %s" % f)
        return 1
    if unregistered:
        print("  [严重] 代码里读写、但检查器清单里没登记的配置文件（共 %d 个）:" % len(unregistered))
        for f in unregistered:
            print("    - %s  ⇒ 加进 tools/check_config_doc.py 的 CONFIG_FILES 并写进文档" % f)
        return 1
    print("  配置文件点名检查: %d 个文件都在文档里" % len(CONFIG_FILES))

    print("  [通过] 每个配置键都在文档里有说明")
    return 0


if __name__ == "__main__":
    sys.exit(main())
