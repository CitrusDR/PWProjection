#!/usr/bin/env python3
"""仓库脚本的"杀软误报"自查 —— 防止 Windows Defender 把我们当成恶意脚本。

## 为什么有这个检查器（2026-09-29 玩家报告）

> 「刚才在你生成过程中，有东西被 Windows 安全中心拦下来了，提示的是
>   **Trojan:Win32/PowhidSubExec.B**，此前也出现过一次，注意后面不要再出现这种东西。」

`PowhidSubExec` ≈ **PowerShell + Hidden + Sub-Execution**：杀软对
"**一个 PowerShell 进程悄悄再起一个 PowerShell 子进程**"这种形状最敏感 ——
这正是恶意脚本最常用的起手式（隐藏窗口 + 绕过执行策略 + 再拉一个子进程）。

### 本项目的定位（排查结论）

仓库里的 `.ps1` **没有**任何隐藏子进程写法（没有 `Start-Process`、
没有 `-WindowStyle Hidden`、没有 base64/`Invoke-Expression`/下载执行）——
出现的 `powershell -ExecutionPolicy Bypass -File xxx.ps1` 全都是**帮助文本里的用法示例**。

真正踩到启发式的是**开发时（AI）的调用方式**：
在一个已经隐藏着的 `pwsh` 里，又用
`powershell -NoProfile -ExecutionPolicy Bypass -File tools\\make_snapshot.ps1`
**起了一个子 PowerShell** —— 形状与"隐藏子进程执行"一致 ⇒ 被拦。
（隐藏是因为自动化环境本来就无窗口，不是因为脚本写了 `-WindowStyle Hidden`。）

### 规矩（写进 `docs/踩坑记录.md` §66）

1. **AI 不要嵌套起 PowerShell**：直接 `& .\\tools\\xxx.ps1` 在**当前进程**里执行脚本
   （同进程、无子进程、不用 `-ExecutionPolicy` 参数）；
2. 脚本里**永远不要**写 `-WindowStyle Hidden` / `Start-Process -WindowStyle Hidden` /
   `-EncodedCommand` / `FromBase64String` / `Invoke-Expression` / 下载执行；
3. 玩家自己手动跑脚本时用
   `powershell -NoProfile -ExecutionPolicy Bypass -File .\\mod\\PWProjection\\deploy.ps1`
   是正常的（**外层**进程、有窗口），保持文档里的写法即可。

## 这个检查器查什么

* 扫仓库里所有 `.ps1 / .cmd / .bat`（跳过 `backups/`、`archive/`）；
* 命中以下任一即**失败**：`-WindowStyle Hidden`、`-NoNewWindow`、`CreateNoWindow`、
  `Start-Process`、`EncodedCommand`、`FromBase64String`、`Invoke-Expression`/`iex`、
  `DownloadString`/`DownloadFile`/`WebClient`、`WScript.Shell`、`schtasks`、
  `vssadmin`、`bitsadmin`、`Add-MpPreference`（改杀软设置）；
* **例外**（不算命中）：整行注释（`#` 开头）、以及只是**打印用法示例**的行
  （同一行里有 `Write-Host` / `Write-Output` / `'` `"` 引号包着）。
  这类行只是文本，不会真的起子进程。

用法: python tools/check_ps_safety.py [仓库根]
退出码: 0 = 通过, 1 = 发现问题
"""
import os
import re
import sys

SKIP_DIRS = {"backups", ".git", "__pycache__", "node_modules"}   # archive 也要扫（它还在仓库里）

# 高信号（等于"隐藏/间接执行"的形状）。用完即弃的正则。
PATTERNS = [
    (r"-WindowStyle\s+Hidden|\bWindowStyle\s*=\s*['\"]?Hidden",
     "隐藏窗口（PowhidSubExec 的核心特征）"),
    (r"-NoNewWindow", "不新开窗口（同样是隐藏形状）"),
    (r"CreateNoWindow", "CreateNoWindow"),
    (r"\bStart-Process\b", "Start-Process（起子进程；脚本里不需要）"),
    (r"-EncodedCommand|-enc\s+[A-Za-z0-9+/=]{40,}", "base64 编码命令"),
    (r"FromBase64String", "base64 解码执行"),
    (r"\bInvoke-Expression\b|\biex\b", "Invoke-Expression/iex（动态执行）"),
    (r"DownloadString|DownloadFile|\bWebClient\b|Invoke-WebRequest|curl\s+http|wget\s+http",
     "从网上下载并执行"),
    (r"WScript\.Shell", "WScript.Shell（典型恶意外壳）"),
    (r"\bschtasks\b", "schtasks（计划任务持久化）"),
    (r"\bvssadmin\b|\bbitsadmin\b", "系统工具滥用"),
    (r"Add-MpPreference|Set-MpPreference", "改杀软设置"),
]

# "只是打印出来给人看"的行 —— 不算命中
PRINT_HINT = re.compile(r"Write-Host|Write-Output|Write-Warning|Write-Verbose")


def is_print_only(line: str) -> bool:
    """这一行是不是只把文本打出来（帮助/用法示例）？"""
    stripped = line.strip()
    if stripped.startswith("#"):
        return True
    if PRINT_HINT.search(line):
        return True
    return False


def scan_file(path: str):
    hits = []
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for n, line in enumerate(fh, 1):
                if is_print_only(line):
                    continue
                for rx, why in PATTERNS:
                    if re.search(rx, line):
                        hits.append((n, why, line.strip()[:110]))
                        break
    except OSError as exc:
        hits.append((0, "读不到文件: %s" % exc, ""))
    return hits


def main() -> int:
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(
        os.path.dirname(os.path.abspath(__file__)))
    exts = (".ps1", ".cmd", ".bat", ".psm1")
    bad, files = 0, 0
    print('脚本"杀软误报"自查: 扫 %s 下的 .ps1/.cmd/.bat' % root)
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in sorted(filenames):
            if not name.lower().endswith(exts):
                continue
            files += 1
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, root)
            hits = scan_file(path)
            if hits:
                bad += len(hits)
                print("  [失败] %s" % rel)
                for n, why, text in hits:
                    print("        行 %-5d %s" % (n, why))
                    if text:
                        print("                  %s" % text)
            else:
                print("  [通过] %s" % rel)
    print()
    if bad:
        print("结果: %d 处问题（见上面）—— 这些形状会被杀软当成恶意脚本，请改掉" % bad)
        return 1
    print("结果: 全部通过（%d 个脚本，没有隐藏/间接执行的形状）" % files)
    return 0


if __name__ == "__main__":
    sys.exit(main())
