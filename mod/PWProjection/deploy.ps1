#Requires -Version 5.1
<#
  deploy.ps1 -- 部署 PWProjection 到 Palworld 的 UE4SS

  做 4 件事:
    1. 复制 mod\PWProjection\Scripts\*.lua  ->  <游戏>\Mods\NativeMods\UE4SS\Mods\PWProjection\Scripts\
    2. 在 mods.txt 里启用 PWProjection（幂等）
    3. 顺手清理废弃的 PWRecon / PWKeyTest（目录 + mods.txt 条目）
    4. 打开 EnableHotReloadSystem

  为什么脚本要能重复跑:
    Palworld 官方的 mod 部署器会重置 mods.txt。所以每次官方那边动过之后，
    重新跑一遍本脚本就能恢复。

  用法（会写游戏目录，所以需要你手动执行）:
    powershell -ExecutionPolicy Bypass -File deploy.ps1
    powershell -ExecutionPolicy Bypass -File deploy.ps1 -DryRun
    powershell -ExecutionPolicy Bypass -File deploy.ps1 -Rollback
    powershell -ExecutionPolicy Bypass -File deploy.ps1 -GameRoot "D:\Steam\steamapps\common\Palworld"

  部署完记得: 重启游戏 -> 完整读档 -> 站进世界 -> 按 F7 看帮助。
#>

param(
    [switch]$DryRun,
    [switch]$Rollback,
    [switch]$Disable,
    [string]$GameRoot = ""
)

$ErrorActionPreference = "Stop"

function Ok($m)    { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Did($m)   { Write-Host "  [已改] $m" -ForegroundColor Cyan }
function Warn2($m) { Write-Host "  [注意] $m" -ForegroundColor Yellow }
function Bad($m)   { Write-Host "  [错误] $m" -ForegroundColor Red }
function Info($m)  { Write-Host "  $m" }
function Head($m)  { Write-Host ""; Write-Host $m -ForegroundColor White }

$ModName    = "PWProjection"
$ObsoleteMods = @("PWRecon", "PWKeyTest")

# ------------------------------------------------------------------ 定位
if (-not $GameRoot) {
    foreach ($c in @(
        "D:\Steam\steamapps\common\Palworld",
        "C:\Program Files (x86)\Steam\steamapps\common\Palworld",
        "D:\SteamLibrary\steamapps\common\Palworld",
        "E:\SteamLibrary\steamapps\common\Palworld"
    )) {
        if (Test-Path (Join-Path $c "Palworld.exe")) { $GameRoot = $c; break }
    }
}
if (-not $GameRoot -or -not (Test-Path $GameRoot)) {
    Bad "找不到游戏目录，用 -GameRoot 指定"; exit 1
}

$ue4ss   = Join-Path $GameRoot "Mods\NativeMods\UE4SS"
$modsDir = Join-Path $ue4ss "Mods"
$modsTxt = Join-Path $modsDir "mods.txt"
$settings = Join-Path $ue4ss "UE4SS-settings.ini"

$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$srcDir  = Join-Path $here "Scripts"
$dstDir  = Join-Path (Join-Path $modsDir $ModName) "Scripts"

Write-Host ""
Write-Host "PWProjection 部署" -ForegroundColor White
Write-Host "游戏目录: $GameRoot"
Write-Host "源:       $srcDir"
Write-Host "目标:     $dstDir"
if ($DryRun) { Write-Host "*** 干跑模式：不修改任何文件 ***" -ForegroundColor Yellow }

if (-not (Test-Path $modsTxt)) { Bad "找不到 $modsTxt"; exit 1 }
if (-not (Test-Path $srcDir))  { Bad "找不到源目录 $srcDir"; exit 1 }

$gameProc = Get-Process -Name "Palworld-Win64-Shipping" -ErrorAction SilentlyContinue
if ($gameProc -and -not $DryRun) {
    Write-Host ""
    Bad "游戏正在运行 (PID $($gameProc.Id))，lua 文件被锁定，无法部署。"
    Write-Host ""
    Write-Host "  请先【完全退出游戏】（任务管理器确认没有 Palworld-Win64-Shipping.exe），"
    Write-Host "  然后重新运行本脚本。"
    exit 1
}
if ($gameProc) { Warn2 "游戏正在运行 — 干跑模式不写文件，可继续" }

# ------------------------------------------------------------------ -Disable
# 崩溃归因用的【最小操作】：只把 mods.txt 里的 1 改成 0，不复制、不删除任何文件。
# 这样"关掉 -> 测 -> 开回来"三件事互不影响，不会因为部署动作本身引入新变量。
if ($Disable) {
    Head "[启停] 关闭 PWProjection（只改 mods.txt，不动任何文件）"
    $content = [System.IO.File]::ReadAllText($modsTxt)
    $pat = "(?m)^\s*" + [regex]::Escape($ModName) + "\s*:\s*([01])\s*$"
    if ([regex]::IsMatch($content, $pat)) {
        $new = [regex]::Replace($content, $pat, "$ModName : 0")
        if (-not $DryRun) { [System.IO.File]::WriteAllText($modsTxt, $new) }
        Did "$ModName : 0  (下次启动不再加载，文件仍然保留)"
    } else {
        Warn2 "$ModName 不在 mods.txt 里，无需关闭"
    }
    Write-Host ""
    Write-Host "接下来：" -ForegroundColor Yellow
    Write-Host "  1) 重启游戏，进世界，走动、跳一下" -ForegroundColor White
    Write-Host "  2) 如果【还是】在进世界那一刻崩 -> 与我们无关（问题在别的 mod）" -ForegroundColor White
    Write-Host "  3) 如果不崩了 -> 再跑一次本脚本（不带参数）打开回来，继续测" -ForegroundColor White
    Write-Host ""
    Write-Host "  若关掉后仍崩，下一个嫌疑人是 SBB 的 pak（它只装了 pak、没装 Lua）：" -ForegroundColor Gray
    Write-Host "    把 Pal\Content\Paks\LogicMods\BlueprintResearch.pak 改名加 .off 再试" -ForegroundColor Gray
    exit 0
}

# ------------------------------------------------------------------ 1. 复制
Head "[1] 复制 mod 文件"
$srcFiles = Get-ChildItem -Path $srcDir -Filter "*.lua" -File
if ($srcFiles.Count -eq 0) { Bad "源目录里没有 .lua 文件"; exit 1 }

$totalBytes = ($srcFiles | Measure-Object -Property Length -Sum).Sum
if ($DryRun) {
    foreach ($f in $srcFiles) {
        Did ("会复制 {0,-22} {1,8:N0} bytes" -f $f.Name, $f.Length)
    }
    Info ("共 {0} 个文件, {1:N0} bytes" -f $srcFiles.Count, $totalBytes)
} else {
    New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
    # 清掉目标里已经不存在的旧 lua，避免删了源文件后游戏还在 require 它
    $srcNames = $srcFiles.Name
    Get-ChildItem -Path $dstDir -Filter "*.lua" -File | ForEach-Object {
        if ($srcNames -notcontains $_.Name) {
            Remove-Item $_.FullName -Force
            Did "删除已移除的模块 $($_.Name)"
        }
    }
    foreach ($f in $srcFiles) {
        Copy-Item $f.FullName (Join-Path $dstDir $f.Name) -Force
    }
    Did ("复制 {0} 个文件, {1:N0} bytes" -f $srcFiles.Count, $totalBytes)

    # 网格覆盖表分两个文件:
    #   pwpr_meshmap.default.json —— 随 mod 更新（每次部署覆盖成最新）
    #   pwpr_meshmap.json         —— 用户自己的（只在不存在时创建）
    # ★ 原来只有一个文件，为了"保护用户修改"就只在不存在时复制。
    #   结果我把条目从 7 条扩到 33 条之后，游戏里还是旧的 7 条 ——
    #   部署"成功"了却完全没生效（日志里表现为「覆盖表 7 条」）。
    #   分两个文件才能既更新默认值又保护用户修改。
    foreach ($pair in @(
        @{ Src = "pwpr_meshmap.default.json"; Always = $true;
           What = "内置映射表（每次部署更新）" },
        @{ Src = "pwpr_meshmap.json";         Always = $false;
           What = "用户映射表（保留修改）" }
    )) {
        $msrc = Join-Path $srcDir $pair.Src
        $mdst = Join-Path $dstDir $pair.Src
        if (-not (Test-Path $msrc)) { continue }
        if ($pair.Always) {
            Copy-Item $msrc $mdst -Force
            Did ("{0}  {1}" -f $pair.Src, $pair.What)
        } elseif (Test-Path $mdst) {
            Ok ("{0} 已存在，保留你的修改（不覆盖）" -f $pair.Src)
        } else {
            Copy-Item $msrc $mdst -Force
            Did ("{0} 首次创建  {1}" -f $pair.Src, $pair.What)
        }
    }
}

# ------------------------------------------------------------------ 2. 注册
Head "[2] mods.txt 注册"
$content = [System.IO.File]::ReadAllText($modsTxt)
$new = $content

$pat = "(?m)^\s*" + [regex]::Escape($ModName) + "\s*:\s*([01])\s*$"
$hit = [regex]::Match($new, $pat)
if ($Rollback) {
    if ($hit.Success) {
        $new = [regex]::Replace($new, $pat + "\r?\n?", "")
        Did "移除 $ModName"
    } else { Ok "$ModName 本就不在 mods.txt" }
} elseif ($hit.Success) {
    if ($hit.Groups[1].Value -eq "1") { Ok "$ModName 已启用" }
    else {
        $new = [regex]::Replace($new, $pat, "$ModName : 1")
        Did "$ModName 由禁用改为启用"
    }
} else {
    if (-not $new.EndsWith("`n")) { $new += "`r`n" }
    $new += "`r`n$ModName : 1`r`n"
    Did "追加 $ModName : 1"
}

foreach ($name in $ObsoleteMods) {
    $p = "(?m)^\s*" + [regex]::Escape($name) + "\s*:\s*([01])\s*$"
    if ([regex]::IsMatch($new, $p)) {
        $new = [regex]::Replace($new, $p + "\r?\n?", "")
        Did "从 mods.txt 移除已废弃的 $name"
    }
    $dir = Join-Path $modsDir $name
    if (Test-Path $dir) {
        $sz = (Get-ChildItem $dir -Recurse -File |
               Measure-Object -Property Length -Sum).Sum
        if (-not $DryRun) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
        Did ("删除已废弃目录 {0}  ({1:N0} bytes)" -f $name, $sz)
    }
}

# ---- 改名后的旧目录（PWBlueprint -> PWProjection, 2026-09-28）------------
# ★ 这里**故意不自动删除**：旧目录里可能有玩家的【蓝图】和【用户网格覆盖表】，
#   删掉就是数据丢失。所以只把 mods.txt 里的旧条目**停用**（1 -> 0），并提示怎么迁移。
$oldName = "PWBlueprint"
$oldDir = Join-Path $modsDir $oldName
# ① 不管旧目录还在不在，只要 mods.txt 里还留着旧条目，就把它停用（1 -> 0）。
#    为什么: 玩家可能先把旧目录删掉了，但 mods.txt 里的 `PWBlueprint : 1` 还在
#    —— UE4SS 会去找一个不存在的 mod，日志里一堆警告。
$pOld = "(?m)^\s*" + [regex]::Escape($oldName) + "\s*:\s*([01])\s*$"
if ([regex]::IsMatch($new, $pOld)) {
    $new = [regex]::Replace($new, $pOld, "$oldName : 0")
    Did "把 mods.txt 里的旧条目 $oldName 停用（改成 0）"
}
# ② 旧目录还在的话，提示怎么迁移数据（**不自动删**）
if (Test-Path $oldDir) {
    Warn2 "检测到旧目录 $oldName\（改名前的本体，里面可能有你的蓝图与用户覆盖表）"
    Write-Host "    迁移建议（按需）:" -ForegroundColor Gray
    Write-Host "      · 蓝图:       把 $oldName\blueprints\*.blueprint.json 复制到 $ModName\blueprints\" -ForegroundColor Gray
    Write-Host "      · 用户覆盖表: 把 $oldName\Scripts\pwbp_meshmap.json 改名成 pwpr_meshmap.json 后放进 $ModName\Scripts\" -ForegroundColor Gray
    Write-Host "      · 旧配置:     一般不用带（新版本会自动生成 pwpr_config.json）" -ForegroundColor Gray
    Write-Host "    确认不需要之后，可以自己删除 $oldName\ 目录。" -ForegroundColor Gray
}

if ($new -ne $content -and -not $DryRun) {
    [System.IO.File]::WriteAllText($modsTxt, $new)
}
if (-not $DryRun) {
    Info "当前 mods.txt 启用项:"
    [System.IO.File]::ReadAllLines($modsTxt) |
        Where-Object { $_ -match ":\s*1\s*$" } |
        ForEach-Object { Info ("    " + $_.Trim()) }
}

# ------------------------------------------------------------------ 3. 热重载
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

# ------------------------------------------------------------------ 总结
Write-Host ""
Write-Host ("=" * 66) -ForegroundColor Cyan
if ($DryRun) {
    Write-Host "干跑完成。去掉 -DryRun 才会真正修改。" -ForegroundColor Yellow
} elseif ($Rollback) {
    Write-Host "已回滚。重启游戏后 PWProjection 不再加载。" -ForegroundColor Green
} else {
    Write-Host "部署完成。接下来：" -ForegroundColor Green
    Write-Host ""
    Write-Host "  1) 重启游戏，【完整读档】进入世界" -ForegroundColor White
    Write-Host "  2) 能自由走动、画面稳定后，按 F7 —— 应看到帮助" -ForegroundColor White
    Write-Host "  3) 站在基地里按 Y 采集一个蓝图" -ForegroundColor White
    Write-Host "  4) 按 J 加载，按 N 做能力探测，按 K 放投影" -ForegroundColor White
    Write-Host "  5) (可选) 按 O 探测屏幕提示通道 —— 想看游戏内中文提示就跑它" -ForegroundColor White
    Write-Host ""
    Write-Host "  日志:" -ForegroundColor Gray
    Write-Host "    $dstDir\pwpr.log           (中文, 完整; '> ' 开头的行 = 屏幕上那一行)" -ForegroundColor Gray
    Write-Host "    $dstDir\pwpr_probe.txt     (渲染能力探测 N)" -ForegroundColor Gray
    Write-Host "    $dstDir\pwpr_ui.txt        (屏幕提示通道探测 O)" -ForegroundColor Gray
    Write-Host "    $ue4ss\UE4SS.log           (控制台输出)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  快速看日志（复制整行到 PowerShell）:" -ForegroundColor White
    Write-Host "    Get-Content `"$dstDir\pwpr.log`" -Tail 60" -ForegroundColor Gray
}
Write-Host ("=" * 66) -ForegroundColor Cyan
