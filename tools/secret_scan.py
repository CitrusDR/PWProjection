"""密钥 / 凭据审计（提交前跑一遍）。

用法:
    python tools/secret_scan.py                # 扫当前仓库
    python tools/secret_scan.py <仓库根目录>

它会扫四个地方:
  1. **git 跟踪的文件** —— 这些才是会真正被上传的内容（最重要）
  2. 未跟踪、也没被 .gitignore 忽略的文件（将来可能被 add 进去）
  3. 被 .gitignore 忽略的文件（不会被上传，只列数量）
  4. **git 历史**（所有提交的完整内容）—— 提交过、后来删掉的也留在这里

检查项: OpenAI/DeepSeek/Anthropic/Google 的 key、AWS Access Key、GitHub/Slack token、
私钥文件内容、JWT、`api_key=` 之类赋值、Bearer 头、URL 内嵌凭据，以及邮箱地址。

⚠️ 它只是**辅助**，不能替代判断:
   命中不等于泄露（SHA256 校验值也会被"32+ 位十六进制"规则命中）；
   没命中也不等于安全（新格式的密钥不在模式里）。
"""
import os
import re
import subprocess
import sys

repo = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
os.chdir(repo)

PATTERNS = [
    ("OpenAI/DeepSeek 风格 key", r"\bsk-[A-Za-z0-9_\-]{16,}"),
    ("Anthropic key", r"\bsk-ant-[A-Za-z0-9_\-]{16,}"),
    ("Google API key", r"\bAIza[0-9A-Za-z_\-]{30,}"),
    ("AWS Access Key", r"\bAKIA[0-9A-Z]{16}\b"),
    ("GitHub token", r"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}"),
    ("Slack token", r"\bxox[baprs]-[A-Za-z0-9\-]{10,}"),
    ("私钥内容", r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    ("JWT", r"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"),
    ("凭据赋值", r"(?i)\b(api[_\-]?key|apikey|access[_\-]?token|auth[_\-]?token|"
                 r"client[_\-]?secret|secret[_\-]?key|password|passwd|pwd)\b"
                 r"\s*[:=]\s*[\"']?[A-Za-z0-9_\-\./+=]{8,}"),
    ("Bearer 头", r"(?i)authorization\s*[:=]\s*[\"']?bearer\s+[A-Za-z0-9_\-\.=]{10,}"),
    ("URL 内嵌凭据", r"(?i)[a-z]+://[^/\s:]+:[^/\s@]+@"),
    ("疑似 32+ 位十六进制串", r"\b[0-9a-fA-F]{32,}\b"),
]

# 与"密钥"无关但值得知道的：邮箱（会公开个人身份）
EMAIL = (r"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b", "邮箱地址")


def scan_files(files, label, extra=()):
    hits = {}
    for f in files:
        try:
            text = open(f, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for name, pat in list(PATTERNS) + list(extra):
            for m in re.finditer(pat, text):
                line = text[:m.start()].count("\n") + 1
                hits.setdefault(name, []).append(
                    (f, line, m.group(0)[:100].replace("\n", " ")))
    print("\n=== %s（%d 个文件）===" % (label, len(files)))
    found = False
    for name, _ in list(PATTERNS) + list(extra):
        h = hits.get(name)
        if not h:
            continue
        found = True
        print("\n[!] %s —— %d 处" % (name, len(h)))
        seen = set()
        for f, ln, s in h:
            if (f, ln) in seen:
                continue
            seen.add((f, ln))
            print("    %s:%d  %s" % (f, ln, s))
    if not found:
        print("    没有命中任何模式 ✔")
    return found


tracked = [l for l in subprocess.run(
    ["git", "ls-files"], capture_output=True, text=True,
    encoding="utf-8").stdout.split("\n") if l.strip()]
scan_files(tracked, "会被上传的文件（git 跟踪）", extra=[EMAIL])

# 仓库内但被忽略 / 未跟踪的文件（不会被上传，但值得看一眼）
un = [l for l in subprocess.run(
    ["git", "ls-files", "--others", "--exclude-standard"], capture_output=True,
    text=True, encoding="utf-8").stdout.split("\n") if l.strip()]
ign = [l for l in subprocess.run(
    ["git", "ls-files", "--others", "--ignored", "--exclude-standard"],
    capture_output=True, text=True, encoding="utf-8").stdout.split("\n") if l.strip()]
if un:
    scan_files(un, "未跟踪、且没有被 .gitignore 忽略（将来可能被 add 进去）")
if ign:
    print("\n=== 被 .gitignore 忽略的文件（不会上传）: %d 个 ===" % len(ign))
    for f in ign[:12]:
        print("    " + f)
    if len(ign) > 12:
        print("    ... 还有 %d 个" % (len(ign) - 12))

# git 历史里的内容（提交对象）也扫一遍
print("\n=== git 历史（所有提交的完整内容）===")
hist = subprocess.run(["git", "log", "-p", "--all"], capture_output=True,
                      text=True, encoding="utf-8", errors="replace").stdout
for name, pat in list(PATTERNS) + [EMAIL]:
    ms = list(re.finditer(pat, hist))
    if ms:
        print("[!] 历史命中 %s —— %d 处；例: %s" % (
            name, len(ms), ms[0].group(0)[:80].replace("\n", " ")))
print("    历史扫描完成")
