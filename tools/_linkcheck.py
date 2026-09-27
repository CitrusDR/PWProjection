"""检查所有 md 文档里的相对链接是否有效。一次性脚本。"""
import os
import re

bad = 0
n = 0
for root, dirs, fs in os.walk("."):
    if (".git" in root.split(os.sep)) or ("backups" in root.split(os.sep)) or ("out" in root.split(os.sep)):
        continue
    for f in fs:
        if not f.endswith(".md"):
            continue
        p = os.path.join(root, f)
        n += 1
        text = open(p, encoding="utf-8").read()
        for m in re.finditer(r"\]\((\.\.?/[^)#]+)", text):
            tgt = os.path.normpath(os.path.join(os.path.dirname(p), m.group(1)))
            if not os.path.exists(tgt):
                print("  断链 %s -> %s" % (p, m.group(1)))
                bad += 1
print("  检查 %d 个 md，断链 %d 条" % (n, bad))
