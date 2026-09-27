#Requires -Version 5.1
<#
  cleanup.ps1 -- 从游戏里彻底移除 PWRecon mod，让 UE4SS 回到干净状态

  为什么要清理
  ------------
  PWRecon 是阶段 0/1 的侦察与导出工具，已完成使命：
    * 建筑类名 / 坐标 / 朝向 都已确认并写进 docs/踩坑记录.md
    * 蓝图导出功能已被 Simple Building Blueprints 覆盖

  继续留着它的代价：
    * 它注册了 Y/U/H/J/K/L/N/F7/F8 等热键，会和别的 mod 抢键
    * 其中的侦察函数做过引擎探测（曾导致 3 次游戏崩溃）

  所以现在把它从游戏里摘掉。工作区里的源码保留，将来需要可以再装回来。

  做四件事：
    1. 从 mods.txt 移除 PWRecon 行
    2. 删除游戏侧的 Mods\PWRecon 目录
    3. 顺带清理 PWKeyTest 残留（如果还有）
    4. 报告清理结果，并列出还剩下哪些 mod

  用法（Windows 自带 PowerShell 5.1 即可）:
    powershell -ExecutionPolicy Bypass -File cleanup.ps1
    powershell -ExecutionPolicy Bypass -File cleanup.ps1 -DryRun
    powershell -ExecutionPolicy Bypass -File cleanup.ps1 -GameRoot "D:\Steam\steamapps\common\Palworld"
#>

param(
    [switch]$DryRun,
    [string]$GameRoot = ""
)

$ErrorActionPreference = "Continue"

function Ok($m)   { Write-Host "  [完成] $m" -ForegroundColor Green }
function Did($m)  { Write-Host "  [已改] $m" -ForegroundColor Cyan }
function Warn2($m){ Write-Host "  [注意] $m" -ForegroundColor Yellow }
function Bad($m)  { Write-Host "  [错误] $m" -ForegroundColor Red }
function Info($m) { Write-Host "  $m" }
function Head($m) { Write-Host ""; Write-Host $m -ForegroundColor White }

# 要移除的 mod 名（PWKeyTest 是早期探测用的，可能还有残留）
$targets = @("PWRecon", "PWKeyTest")

# ---------------------------------------------------------------- 定位游戏
if (-not $GameRoot) {
    foreach ($c in @(
        "D:\Steam\steamapps\common\Palworld",
        "C:\Program Files (x86)\Steam\steamapps\common\Palworld",
        "D:\SteamLibrary\steamapps\common\Palworld"
    )) { if (Test-Path (Join-Path $c "Palworld.exe")) { $GameRoot = $c; break } }
}
if (-not $GameRoot -or -not (Test-Path $GameRoot)) {
    Bad "找不到游戏目录，用 -GameRoot 指定"
    exit 1
}

$modsDir = Join-Path $GameRoot "Mods\NativeMods\UE4SS\Mods"
$modsTxt = Join-Path $modsDir "mods.txt"

Write-Host ""
Write-Host "PWRecon 清理" -ForegroundColor White
Write-Host "游戏目录: $GameRoot"
if ($DryRun) { Write-Host "*** 干跑模式：不修改任何文件 ***" -ForegroundColor Yellow }

# ---------------------------------------------------------------- 前置检查
Head "[0] 前置检查"
if (-not (Test-Path $modsDir)) {
    Bad "找不到 UE4SS Mods 目录: $modsDir"
    exit 1
}
Ok "找到 UE4SS Mods 目录"

$proc = Get-Process -Name "Palworld-Win64-Shipping" -ErrorAction SilentlyContinue
if ($proc -and -not $DryRun) {
    Write-Host ""
    Bad "游戏正在运行 (PID $($proc.Id))，文件被占用，无法清理。"
    Write-Host "  请先完全退出游戏，再重新运行本脚本。"
    exit 1
}
if ($proc) { Warn2 "游戏正在运行（干跑模式不写文件，可继续）" } else { Ok "游戏未在运行" }

# ---------------------------------------------------------------- 1. mods.txt
Head "[1] 从 mods.txt 移除注册"
if (-not (Test-Path $modsTxt)) {
    Warn2 "找不到 mods.txt，跳过"
} else {
    $content = [System.IO.File]::ReadAllText($modsTxt)
    $new = $content
    foreach ($name in $targets) {
        $pat = "(?m)^\s*" + [regex]::Escape($name) + "\s*:\s*([01])\s*$"
        if ([regex]::IsMatch($new, $pat)) {
            $new = [regex]::Replace($new, $pat + "\r?\n?", "")
            Did "从 mods.txt 移除 $name"
        } else {
            Info "$name 本就不在 mods.txt"
        }
    }
    # 收掉可能留下的多余空行
    $new = $new -replace "(\r?\n){3,}", "`r`n`r`n"
    if ($new -ne $content) {
        if (-not $DryRun) { [System.IO.File]::WriteAllText($modsTxt, $new) }
    }
}

# ---------------------------------------------------------------- 2. 删目录
Head "[2] 删除 mod 目录"
foreach ($name in $targets) {
    $dir = Join-Path $modsDir $name
    if (Test-Path $dir) {
        $size = (Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue |
                 Measure-Object Length -Sum).Sum
        if ($DryRun) {
            Did "会删除 $name（$('{0:N0}' -f $size) B）"
        } else {
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $dir) { Bad "$name 删除失败（可能被占用）" }
            else { Did "已删除 $name（$('{0:N0}' -f $size) B）" }
        }
    } else {
        Info "$name 目录不存在（无需删除）"
    }
}

# ---------------------------------------------------------------- 3. 结果
Head "[3] 清理后的 mods.txt"
if (Test-Path $modsTxt) {
    Get-Content $modsTxt | Where-Object { $_.Trim() -ne "" } | ForEach-Object {
        Info $_
    }
}

Head "[4] 当前 UE4SS Mods 目录内容"
Get-ChildItem $modsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    Info ("[目录] " + $_.Name)
}

Write-Host ""
Write-Host ("=" * 62) -ForegroundColor Cyan
if ($DryRun) {
    Write-Host "干跑完成。去掉 -DryRun 才会真正修改。" -ForegroundColor Yellow
} else {
    Write-Host "清理完成。" -ForegroundColor Green
    Write-Host ""
    Write-Host "确认无误后可以启动游戏，试装 Simple Building Blueprints。" -ForegroundColor White
    Write-Host ""
    Write-Host "若要恢复 PWRecon（工作区源码仍在），重跑：" -ForegroundColor Gray
    Write-Host "  powershell -ExecutionPolicy Bypass -File ..\..\mod\PWRecon\deploy-all.ps1" -ForegroundColor Gray
}
Write-Host ("=" * 62) -ForegroundColor Cyan
Write-Host ""
Write-Host "提醒：工作区里的 PWRecon 源码没有被删除，只是从游戏里摘掉了。" -ForegroundColor Gray
