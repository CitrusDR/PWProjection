#Requires -Version 5.1
<#
  deploy-all.ps1 -- 一键部署：PWKeyTest(热键API探测) + PWRecon(侦察) + 注册

  背景
  ----
  1. UE4SS 的 mods.txt 会被 Palworld 官方 mod 系统重置 —— 所以注册必须能重复执行
  2. PWRecon 之前热键注册失败，需要先探测这个 UE4SS 版本正确的 API —— 所以先装 PWKeyTest

  本脚本做 4 件事:
    1. 复制 PWKeyTest 和 PWRecon 的 Scripts/main.lua 到 UE4SS\Mods\
    2. 在 mods.txt 里启用两者（幂等）
    3. 打开 EnableHotReloadSystem
    4. 可选: 尝试把 PWRecon 登记到官方 mod 体系（-TryManagedMod）

  用法（在工作区里跑，会写游戏目录，所以需要你手动执行）:
    powershell -ExecutionPolicy Bypass -File deploy-all.ps1
    powershell -ExecutionPolicy Bypass -File deploy-all.ps1 -DryRun
    powershell -ExecutionPolicy Bypass -File deploy-all.ps1 -TryManagedMod
    powershell -ExecutionPolicy Bypass -File deploy-all.ps1 -Rollback
#>

param(
    [switch]$DryRun,
    [switch]$TryManagedMod,
    [switch]$Rollback,
    [string]$GameRoot = ""
)

$ErrorActionPreference = "Stop"

function Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Did($m)  { Write-Host "  [已改] $m" -ForegroundColor Cyan }
function Warn2($m){ Write-Host "  [注意] $m" -ForegroundColor Yellow }
function Bad($m)  { Write-Host "  [错误] $m" -ForegroundColor Red }
function Info($m) { Write-Host "  $m" }
function Head($m) { Write-Host ""; Write-Host $m -ForegroundColor White }

# ---------------------------------------------------------------- 定位
if (-not $GameRoot) {
    foreach ($c in @(
        "D:\Steam\steamapps\common\Palworld",
        "C:\Program Files (x86)\Steam\steamapps\common\Palworld",
        "D:\SteamLibrary\steamapps\common\Palworld"
    )) { if (Test-Path (Join-Path $c "Palworld.exe")) { $GameRoot = $c; break } }
}
if (-not $GameRoot -or -not (Test-Path $GameRoot)) { Bad "找不到游戏目录，用 -GameRoot 指定"; exit 1 }

$ue4ss    = Join-Path $GameRoot "Mods\NativeMods\UE4SS"
$modsDir  = Join-Path $ue4ss "Mods"
$modsTxt  = Join-Path $modsDir "mods.txt"
$settings = Join-Path $ue4ss "UE4SS-settings.ini"
$managed  = Join-Path $GameRoot "Mods\ManagedMods"
$palIni   = Join-Path $GameRoot "Mods\PalModSettings.ini"
$here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$srcRoot  = Split-Path -Parent $here     # palworld-litematica\mod

$mods = @(
    @{ Name = "PWRecon";   Src = Join-Path $here    "Scripts\main.lua" }
)

# PWKeyTest 已完成使命（探明了热键 API 的正确签名），不再部署。
# 如果之前装过，这里顺手清理掉，避免它继续占用 mods.txt。
$obsolete = @("PWKeyTest")

Write-Host ""
Write-Host "Palworld 侦察套件部署" -ForegroundColor White
Write-Host "游戏目录: $GameRoot"
if ($DryRun) { Write-Host "*** 干跑模式：不修改任何文件 ***" -ForegroundColor Yellow }

if (-not (Test-Path $modsTxt)) { Bad "找不到 $modsTxt"; exit 1 }

$gameProc = Get-Process -Name "Palworld-Win64-Shipping" -ErrorAction SilentlyContinue
if ($gameProc -and -not $DryRun) {
    Write-Host ""
    Bad "游戏正在运行 (PID $($gameProc.Id))，lua 文件被占用，无法部署。"
    Write-Host ""
    Write-Host "  请先【完全退出游戏】（任务管理器确认没有 Palworld-Win64-Shipping.exe），"
    Write-Host "  然后重新运行本脚本。"
    Write-Host ""
    Write-Host "  原因: UE4SS 只在启动时读 mods.txt 并加载 lua；运行中文件被锁定，复制会失败。"
    exit 1
}
if ($gameProc) { Warn2 "游戏正在运行 — 干跑模式不写文件，可继续" }

# ---------------------------------------------------------------- 1. 部署文件
Head "[1] 部署 mod 文件"
foreach ($m in $mods) {
    if (-not (Test-Path $m.Src)) { Bad "源文件缺失: $($m.Src)"; continue }
    $dst = Join-Path (Join-Path $modsDir $m.Name) "Scripts\main.lua"
    $dstDir = Split-Path -Parent $dst
    if ($DryRun) {
        Did "会复制 $($m.Name)\Scripts\main.lua  ($('{0:N0}' -f (Get-Item $m.Src).Length) bytes)"
    } else {
        New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
        Copy-Item $m.Src $dst -Force
        Did "$($m.Name)\Scripts\main.lua  ($('{0:N0}' -f (Get-Item $m.Src).Length) bytes)"
    }
}

# ---------------------------------------------------------------- 2. 注册
Head "[2] mods.txt 注册"
$content = [System.IO.File]::ReadAllText($modsTxt)
$new = $content
foreach ($m in $mods) {
    $pat = "(?m)^\s*" + [regex]::Escape($m.Name) + "\s*:\s*([01])\s*$"
    $hit = [regex]::Match($new, $pat)
    if ($Rollback) {
        if ($hit.Success) {
            $new = [regex]::Replace($new, $pat + "\r?\n?", "")
            Did "移除 $($m.Name)"
        } else { Ok "$($m.Name) 本就不在 mods.txt" }
    } elseif ($hit.Success) {
        if ($hit.Groups[1].Value -eq "1") { Ok "$($m.Name) 已启用" }
        else {
            $new = [regex]::Replace($new, $pat, "$($m.Name) : 1")
            Did "$($m.Name) 由禁用改为启用"
        }
    } else {
        if (-not $new.EndsWith("`n")) { $new += "`r`n" }
        $new += "`r`n$($m.Name) : 1`r`n"
        Did "追加 $($m.Name) : 1"
    }
}

# 清理已废弃的 mod（PWKeyTest 已完成使命）
foreach ($name in $obsolete) {
    $pat = "(?m)^\s*" + [regex]::Escape($name) + "\s*:\s*([01])\s*$"
    if ([regex]::IsMatch($new, $pat)) {
        $new = [regex]::Replace($new, $pat + "\r?\n?", "")
        Did "从 mods.txt 移除已废弃的 $name"
    }
    $dir = Join-Path $modsDir $name
    if (Test-Path $dir) {
        if (-not $DryRun) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
        Did "删除已废弃的目录 $name"
    }
}
if ($new -ne $content -and -not $DryRun) { [System.IO.File]::WriteAllText($modsTxt, $new) }
if (-not $DryRun) {
    Info "当前 mods.txt 启用项:"
    [System.IO.File]::ReadAllLines($modsTxt) | Where-Object { $_ -match ":\s*1\s*$" } |
        ForEach-Object { Info ("    " + $_.Trim()) }
}

# ---------------------------------------------------------------- 3. 热重载
Head "[3] 热重载开关"
if (Test-Path $settings) {
    $s = [System.IO.File]::ReadAllText($settings)
    if ($s -match "(?m)^\s*EnableHotReloadSystem\s*=\s*1\s*$") { Ok "已是 1" }
    else {
        $s2 = [regex]::Replace($s, "(?m)^(\s*EnableHotReloadSystem\s*=\s*)0\s*$", '${1}1')
        if ($s2 -ne $s -and -not $DryRun) { [System.IO.File]::WriteAllText($settings, $s2) }
        Did "EnableHotReloadSystem: 0 -> 1"
    }
} else { Warn2 "找不到 UE4SS-settings.ini" }

# ---------------------------------------------------------------- 4. 官方 mod 体系（可选实验）
Head "[4] 登记到官方 mod 体系（实验性，帮助它出现在游戏内 mod 菜单）"
if (-not $TryManagedMod) {
    Info "未启用。加 -TryManagedMod 参数可尝试。"
    Info "原理: 官方 mod 菜单读的是 Mods\ManagedMods\<PackageName>\Info.json。"
    Info "但这只是必要不充分条件 —— 菜单很可能只列创意工坊订阅过的 mod，"
    Info "所以这个实验可能无效。试之前会先备份 PalModSettings.ini。"
} else {
    $pkg = "PWRecon"
    $mmDir = Join-Path $managed $pkg
    $info = @"
{
  "ModName": "PWRecon (Build Recon)",
  "PackageName": "$pkg",
  "Thumbnail": "thumbnail.png",
  "Version": "0.1",
  "DebugMode": false,
  "MinRevision": 82182,
  "Author": "local",
  "Dependencies": [ "UE4SSExperimentalPW" ],
  "Tags": [ "UE4SS", "Utilities" ],
  "InstallRule": [
    { "Type": "Lua", "Targets": [ "./Scripts" ] }
  ]
}
"@
    if ($DryRun) {
        Did "会创建 $mmDir\Info.json"
    } else {
        New-Item -ItemType Directory -Force -Path $mmDir | Out-Null
        Set-Content (Join-Path $mmDir "Info.json") $info -Encoding UTF8
        Did "已创建 $mmDir\Info.json"
    }
    # 备份并尝试写入 ActiveModList
    if (Test-Path $palIni) {
        $bak = "$palIni.bak-before-pwrecon"
        if (-not (Test-Path $bak) -and -not $DryRun) { Copy-Item $palIni $bak -Force; Ok "已备份 -> $bak" }
        $p = [System.IO.File]::ReadAllText($palIni)
        if ($p -match [regex]::Escape($pkg)) {
            Ok "PalModSettings.ini 里已有 $pkg"
        } else {
            if (-not $p.EndsWith("`n")) { $p += "`r`n" }
            $p += "ActiveModList=$pkg`r`n"
            if (-not $DryRun) { [System.IO.File]::WriteAllText($palIni, $p) }
            Did "已追加 ActiveModList=$pkg"
        }
    } else { Warn2 "找不到 PalModSettings.ini，跳过" }
    Warn2 "这只是实验。若游戏内 mod 菜单仍看不到 PWRecon，属正常，"
    Warn2 "用手动 mods.txt 注册即可（本脚本第 2 步已经做了）。"
}

# ---------------------------------------------------------------- 总结
Write-Host ""
Write-Host ("=" * 62) -ForegroundColor Cyan
if ($DryRun) {
    Write-Host "干跑完成。去掉 -DryRun 才会真正修改。" -ForegroundColor Yellow
} elseif ($Rollback) {
    Write-Host "已回滚注册。重启游戏后这两个 mod 不再加载。" -ForegroundColor Green
} else {
    Write-Host "部署完成。下一步：" -ForegroundColor Green
    Write-Host ""
    Write-Host "  1) 重启游戏，读档进入世界" -ForegroundColor White
    Write-Host "  2) PWKeyTest 会在启动时自动探测，不需要按键" -ForegroundColor White
    Write-Host "  3) 退出游戏（或直接看日志文件）" -ForegroundColor White
    Write-Host "  4) 把日志里 [PWKeyTest] 开头的行发我" -ForegroundColor White
    Write-Host ""
    Write-Host "  日志位置: $ue4ss\UE4SS.log" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  快速提取命令（复制整行到 PowerShell 跑）:" -ForegroundColor White
    Write-Host "    Select-String -Path `"$ue4ss\UE4SS.log`" -Pattern 'PWKeyTest|PWRecon' | ForEach-Object { `$_.Line }" -ForegroundColor Gray
}
Write-Host ("=" * 62) -ForegroundColor Cyan
