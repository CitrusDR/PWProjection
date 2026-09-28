#Requires -Version 5.1
<#
  check_ps_syntax.ps1 -- 用 PowerShell 自己的解析器检查仓库里所有 .ps1 的语法

  为什么需要（2026-09-29 真实事故）:
    我给 deploy.ps1 加"部署前静态检查"时，把那段代码插到了 **param(...) 之前** ✗
    ⇒ PowerShell 报 `无法将值"System.String"转换为类型"SwitchParameter"`（行 47 `[switch]$DryRun`）
    ⇒ **部署脚本自己跑不起来** ⇒ 玩家以为"改了没效果"，其实**根本没部署** ✗✗
    （白白浪费一轮实测；而 luacheck 只查 Lua，完全管不到 .ps1 ✗）

  规则（写进 AGENTS.md）: **改了任何 .ps1，必须跑一遍本脚本**。
  PowerShell 要求 `param` 是脚本的第一条语句 —— 只有 `#Requires` 和注释可以放在它前面。

  用法:
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\check_ps_syntax.ps1
  退出码: 0 = 全部通过
#>

$root = Split-Path -Parent $PSScriptRoot
$files = Get-ChildItem -Path $root -Recurse -Filter *.ps1 -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\\.git\\' }

$bad = 0
foreach ($f in $files) {
    $errs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $f.FullName, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) {
        $bad++
        Write-Host ("[严重] {0} —— {1} 个解析错误" -f $f.Name, $errs.Count) -ForegroundColor Red
        foreach ($e in $errs | Select-Object -First 3) {
            Write-Host ("        行 {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message)
        }
    }
}
Write-Host ""
if ($bad -gt 0) {
    Write-Host ("PowerShell 语法检查: {0} / {1} 个文件有问题" -f $bad, $files.Count) -ForegroundColor Red
    Write-Host "（常见原因: 把代码插到了 param(...) 之前 —— param 必须是第一条语句）"
    exit 1
}
Write-Host ("PowerShell 语法检查: {0} 个文件全部通过" -f $files.Count) -ForegroundColor Green
exit 0
