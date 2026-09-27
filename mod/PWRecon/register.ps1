#Requires -Version 5.1
<#
  register.ps1 -- 把 PWRecon 注册进 UE4SS 的 mods.txt，并打开热重载

  为什么需要这个脚本
  ------------------
  UE4SS 的 mods.txt 是【唯一】的 mod 注册处，只加载里面列出的 mod。
  但 Palworld 官方 mod 系统会把 mods.txt 当作受管文件，
  每次你更新/启用创意工坊 mod 时都会把它重置回默认内容。

  结果: install.ps1 写进去的 "PWRecon : 1" 会被冲掉，
        文件夹还在、但 UE4SS 不会加载它。

  所以: 每次游戏更新、或你在游戏里动过 mod 开关之后，重跑本脚本即可。
        本脚本是幂等的，重复跑不会出问题。

  用法:
    powershell -ExecutionPolicy Bypass -File register.ps1
    powershell -ExecutionPolicy Bypass -File register.ps1 -DryRun     # 只显示会改什么
    powershell -ExecutionPolicy Bypass -File register.ps1 -Unregister
#>

param(
    [switch]$DryRun,
    [switch]$Unregister,
    [string]$GameRoot = "",
    [string]$ModName = "PWRecon"
)

$ErrorActionPreference = "Stop"

function Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Did($m)  { Write-Host "  [已改] $m" -ForegroundColor Cyan }
function Warn2($m){ Write-Host "  [注意] $m" -ForegroundColor Yellow }
function Bad($m)  { Write-Host "  [错误] $m" -ForegroundColor Red }
function Info($m) { Write-Host "  $m" }

# ---------------------------------------------------------------- 定位
if (-not $GameRoot) {
    foreach ($c in @(
        "D:\Steam\steamapps\common\Palworld",
        "C:\Program Files (x86)\Steam\steamapps\common\Palworld",
        "D:\SteamLibrary\steamapps\common\Palworld"
    )) { if (Test-Path (Join-Path $c "Palworld.exe")) { $GameRoot = $c; break } }
}
if (-not $GameRoot -or -not (Test-Path $GameRoot)) {
    Bad "找不到游戏目录，用 -GameRoot 指定"; exit 1
}

$ue4ss   = Join-Path $GameRoot "Mods\NativeMods\UE4SS"
$modsDir = Join-Path $ue4ss "Mods"
$modsTxt = Join-Path $modsDir "mods.txt"
$settings= Join-Path $ue4ss "UE4SS-settings.ini"
$modDir  = Join-Path $modsDir $ModName
$mainLua = Join-Path $modDir "Scripts\main.lua"

Write-Host ""
Write-Host "PWRecon 注册修复" -ForegroundColor White
Write-Host "游戏目录: $GameRoot"
if ($DryRun) { Write-Host "*** 干跑模式：不会修改任何文件 ***" -ForegroundColor Yellow }
Write-Host ""

$changed = $false

# ---------------------------------------------------------------- 0. 前置检查
Write-Host "[0] 前置检查"

$gameProc = Get-Process -Name "Palworld-Win64-Shipping" -ErrorAction SilentlyContinue
if ($gameProc) {
    Warn2 "游戏正在运行 (PID $($gameProc.Id))"
    Warn2 "UE4SS 只在启动时读 mods.txt，改了也必须重启游戏才生效"
} else {
    Ok "游戏未在运行（可以安全修改）"
}

if (-not (Test-Path $modsTxt)) { Bad "找不到 mods.txt: $modsTxt"; exit 1 }
Ok "mods.txt 存在"

if (-not (Test-Path $mainLua)) {
    Bad "找不到 mod 脚本: $mainLua"
    Bad "请先跑 install.ps1 把脚本装进去，再跑本脚本。"
    exit 1
}
$luaSize = (Get-Item $mainLua).Length
Ok "mod 脚本存在 ($luaSize bytes)"

$ue4ssDll = Join-Path $ue4ss "UE4SS.dll"
if (Test-Path $ue4ssDll) {
    $v = (Get-Item $ue4ssDll)
    Info "UE4SS.dll: $('{0:N0}' -f $v.Length) bytes  $($v.LastWriteTime)"
}
Write-Host ""

# ---------------------------------------------------------------- 1. mods.txt
Write-Host "[1] mods.txt 注册"

$content = [System.IO.File]::ReadAllText($modsTxt)
$pattern = "(?m)^\s*" + [regex]::Escape($ModName) + "\s*:\s*([01])\s*$"
$m = [regex]::Match($content, $pattern)

if ($Unregister) {
    if ($m.Success) {
        $new = [regex]::Replace($content, $pattern + "\r?\n?", "")
        $new = $new -replace "(\r?\n){3,}", "`r`n`r`n"
        if (-not $DryRun) { [System.IO.File]::WriteAllText($modsTxt, $new) }
        Did "已从 mods.txt 移除 $ModName"
        $changed = $true
    } else {
        Ok "$ModName 本来就不在 mods.txt 里"
    }
}
elseif ($m.Success) {
    if ($m.Groups[1].Value -eq "1") {
        Ok "$ModName 已在 mods.txt 中启用（无需修改）"
    } else {
        $new = [regex]::Replace($content, $pattern, "$ModName : 1")
        if (-not $DryRun) { [System.IO.File]::WriteAllText($modsTxt, $new) }
        Did "$ModName 存在但被禁用 -> 已改为启用"
        $changed = $true
    }
} else {
    $new = $content
    if (-not $new.EndsWith("`n")) { $new += "`r`n" }
    $new += "`r`n$ModName : 1`r`n"
    if (-not $DryRun) { [System.IO.File]::WriteAllText($modsTxt, $new) }
    Did "已在 mods.txt 末尾追加: $ModName : 1"
    $changed = $true
}

if (-not $DryRun) {
    Write-Host ""
    Info "当前 mods.txt 里已启用的 mod:"
    [System.IO.File]::ReadAllLines($modsTxt) | Where-Object { $_ -match ":\s*1\s*$" } | ForEach-Object { Info ("    " + $_.Trim()) }
}
Write-Host ""

# ---------------------------------------------------------------- 2. 热重载
Write-Host "[2] 热重载开关（改 lua 免重启）"

if (-not (Test-Path $settings)) {
    Warn2 "找不到 UE4SS-settings.ini，跳过"
} else {
    $s = [System.IO.File]::ReadAllText($settings)
    if ($s -match "(?m)^\s*EnableHotReloadSystem\s*=\s*1\s*$") {
        Ok "EnableHotReloadSystem 已经是 1"
    } else {
        $s2 = [regex]::Replace($s, "(?m)^(\s*EnableHotReloadSystem\s*=\s*)0\s*$", '${1}1')
        if ($s2 -ne $s) {
            if (-not $DryRun) { [System.IO.File]::WriteAllText($settings, $s2) }
            Did "EnableHotReloadSystem: 0 -> 1"
            # 确认设置文件属于这个 UE4SS 实例
            if (-not $DryRun) {
                $after = [System.IO.File]::ReadAllText($settings)
                if ($after -match "(?m)^\s*EnableHotReloadSystem\s*=\s*1\s*$") { Ok "已确认写入生效" }
                else { Bad "写入似乎没生效，请手动检查 $settings" }
            }
            $changed = $true
        } else {
            Warn2 "没找到可替换的 EnableHotReloadSystem 行，请手动检查 $settings"
        }
    }
}
Write-Host ""

# ---------------------------------------------------------------- 3. 注入代理
Write-Host "[3] 注入代理检查（UE4SS 是否真的在跑）"
$win64 = Join-Path $GameRoot "Pal\Binaries\Win64"
$proxyFound = $false
foreach ($p in @("dwmapi.dll","winmm.dll","xinput1_3.dll","dsound.dll","version.dll")) {
    $f = Join-Path $win64 $p
    if (Test-Path $f) { Ok "找到注入代理: $p"; $proxyFound = $true }
}
if (-not $proxyFound) {
    Warn2 "Win64 里没找到注入代理 dll。若 F6(FirstPerson) 能用则忽略此项，"
    Warn2 "说明这个版本的 UE4SS 用了别的注入方式。"
}
Write-Host ""

# ---------------------------------------------------------------- 总结
Write-Host ("=" * 60) -ForegroundColor Cyan
if ($DryRun) {
    Write-Host "干跑完成。去掉 -DryRun 才会真正修改文件。" -ForegroundColor Yellow
} elseif ($Unregister) {
    Write-Host "已取消注册。重启游戏后 $ModName 不再加载。" -ForegroundColor Green
} elseif ($changed) {
    Write-Host "修复完成。现在【重启游戏】，进世界后按 F7。" -ForegroundColor Green
} else {
    Write-Host "无需修改，注册状态本来就是正确的。" -ForegroundColor Green
    Write-Host "如果 F7 仍然无效，看日志:" -ForegroundColor Yellow
    Write-Host "  $ue4ss\UE4SS.log"
    Write-Host "  搜 'Starting Lua mod' 看有没有 PWRecon" -ForegroundColor Yellow
}
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host ""
Write-Host "提醒: 每次你在游戏里动过 mod 开关、或创意工坊 mod 更新后，"
Write-Host "      mods.txt 都可能被重置，届时重跑本脚本即可。"
