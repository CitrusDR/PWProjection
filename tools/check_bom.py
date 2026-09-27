#!/usr/bin/env python3
"""BOM 检查器：本项目所有 `.ps1` 必须是 **UTF-8 with BOM**。

为什么（今天栽了两次）:
    PowerShell 5.1 读 `.ps1` 时**没有 BOM 就按系统 ANSI（GBK）解码** ——
    文件里的中文会变成乱码，字符串提前结束，脚本直接语法崩：
        `字符串缺少终止符` / `语句块或定义中缺少右 }`
    而编辑器/工具写回时很容易把 BOM 丢掉（本次是 Python 与编辑器各丢了一次）。

用法:
    python tools/check_bom.py
退出码: 0 = 通过, 1 = 有 .ps1 缺 BOM
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BOM = b"\xef\xbb\xbf"
SKIP_DIRS = {"backups", "out", ".git", "__pycache__"}


def main():
    bad, ok = [], []
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in files:
            if not f.lower().endswith(".ps1"):
                continue
            full = os.path.join(base, f)
            rel = os.path.relpath(full, ROOT).replace("\\", "/")
            with open(full, "rb") as fh:
                head = fh.read(3)
            (ok if head == BOM else bad).append(rel)

    print("BOM 检查（所有 .ps1 必须 UTF-8 with BOM）")
    print("  有 BOM: %d 个" % len(ok))
    for f in sorted(ok):
        print("    ✔ %s" % f)
    if bad:
        print("  [严重] 缺 BOM（PS 5.1 会按 ANSI 读 ⇒ 中文乱码 ⇒ 语法崩）: %d 个" % len(bad))
        for f in sorted(bad):
            print("    ★ %s" % f)
        print("  ⇒ 修法: 用 UTF-8 **带 BOM** 重写这个文件（PowerShell: "
              "Set-Content -Encoding utf8BOM；Python: encoding='utf-8-sig'）")
        return 1
    print("  [通过] 全部 .ps1 都有 BOM")
    return 0


if __name__ == "__main__":
    sys.exit(main())
