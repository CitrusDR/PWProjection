#Requires -Version 5.1
<#
  diag-ue4ss.ps1 -- UE4SS 加载诊断（只读，不修改任何文件）

  为什么按 F7/F8/F9/F6 全都没反应
  ---------------------------------
  UE4SS 根本没有被注入到游戏进程里。本脚本列出全部证据。

  用法（普通 PowerShell 即可）:
    powershell -ExecutionPolicy Bypass -File diag-ue4ss.ps1
    powershell -ExecutionPolicy Bypass -File diag-ue4ss.ps1 -GameRoot "D:\Steam\steamapps\common\Palworld"
#>

param(
    [string]$GameRoot = "",
    [string]$WorkshopId = "3623730"
)

$ErrorActionPreference = "Continue"

function Head($t) { Write-Host ""; Write-Host ("=" * 66) -ForegroundColor Cyan; Write-Host $t -ForegroundColor Cyan; Write-Host ("=" * 66) -ForegroundColor Cyan }
function Ok($t)   { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Warn2($t){ Write-Host "  [警告] $t" -ForegroundColor Yellow }
function Bad($t)  { Write-Host "  [问题] $t" -ForegroundColor Red }
function Info($t) { Write-Host "  $t" }

# ---------------------------------------------------------------- 定位
if (-not $GameRoot) {
    foreach ($c in @(
        "D:\Steam\steamapps\common\Palworld",
        "C:\Program Files (x86)\Steam\steamapps\common\Palworld",
        "D:\SteamLibrary\steamapps\common\Palworld"
    )) { if (Test-Path (Join-Path $c "Palworld.exe")) { $GameRoot = $c; break } }
}
if (-not $GameRoot -or -not (Test-Path $GameRoot)) { Bad "找不到游戏目录，用 -GameRoot 指定"; exit 1 }

$ue4ssDir  = Join-Path $GameRoot "Mods\NativeMods\UE4SS"
$win64     = Join-Path $GameRoot "Pal\Binaries\Win64"
$logPath   = Join-Path $ue4ssDir "UE4SS.log"
$palIni    = Join-Path $GameRoot "Mods\PalModSettings.ini"
$wsRoot    = "D:\Steam\steamapps\workshop\content\1623730"

Write-Host ""
Write-Host "Palworld UE4SS 加载诊断" -ForegroundColor White
Write-Host "游戏目录: $GameRoot"

# ---------------------------------------------------------------- 1. 游戏进程
Head "1. 游戏是否在运行"
$proc = Get-Process -Name "Palworld-Win64-Shipping" -ErrorAction SilentlyContinue
if ($proc) {
    Warn2 "游戏正在运行 (PID $($proc.Id)) — 修改 mod 文件前请先完全退出游戏"
    $mods = $proc.Modules | Where-Object { $_.ModuleName -match "UE4SS|dwmapi" }
    if ($mods) {
        Ok "游戏进程里已加载 UE4SS 相关模块:"
        $mods | ForEach-Object { Info ("    " + $_.ModuleName + "  <-  " + $_.FileName) }
    } else {
        Bad "游戏进程里【没有】UE4SS / dwmapi 模块 → UE4SS 未被注入（这就是热键全失效的原因）"
    }
} else {
    Info "游戏未在运行"
}

# ---------------------------------------------------------------- 2. 注入代理
Head "2. 注入代理 DLL（UE4SS 靠它挂进游戏进程）"
$proxies = @("dwmapi.dll", "winmm.dll", "xinput1_3.dll", "dsound.dll", "version.dll")
$anyProxy = $false
foreach ($p in $proxies) {
    $f = Join-Path $win64 $p
    if (Test-Path $f) {
        $fi = Get-Item $f
        Ok ("$p  存在  {0:N0} bytes  {1}" -f $fi.Length, $fi.LastWriteTime)
        $anyProxy = $true
    }
}
if (-not $anyProxy) {
    Bad "Win64 目录里【没有任何】注入代理 DLL"
    Info "  → 这意味着无论 mods.txt 怎么写，UE4SS 都不会被加载"
    Info "  → 正常应由 Palworld 官方 mod 系统从创意工坊部署，或手动放 dwmapi.dll"
}

# ---------------------------------------------------------------- 3. 本地 UE4SS 完整性
Head "3. 本地 UE4SS 安装完整性"
if (-not (Test-Path $ue4ssDir)) {
    Bad "本地根本没有 $ue4ssDir"
} else {
    foreach ($f in @("UE4SS.dll", "UE4SS-settings.ini", "UE4SS_SDK_Backends", "MemberVariableLayout.ini")) {
        $p = Join-Path $ue4ssDir $f
        if (Test-Path $p) {
            $fi = Get-Item $p
            if ($fi.PSIsContainer) { Ok "$f  (目录)" }
            else { Ok ("{0}  {1:N0} bytes  {2}" -f $f, $fi.Length, $fi.LastWriteTime) }
        } else {
            Bad "$f  缺失"
        }
    }
    $info = Join-Path $ue4ssDir "Info.json"
    if (Test-Path $info) {
        $v = (Get-Content $info -Raw | ConvertFrom-Json).Version
        Info "本地版本号: $v"
    }
}

# ---------------------------------------------------------------- 4. 创意工坊版
Head "4. Steam 创意工坊里的 UE4SS"
if (-not (Test-Path $wsRoot)) {
    Warn2 "找不到创意工坊目录 $wsRoot（可能不在 D 盘 Steam 库）"
} else {
    $ws = Get-ChildItem $wsRoot -Directory -ErrorAction SilentlyContinue
    foreach ($d in $ws) {
        $ij = Join-Path $d.FullName "Info.json"
        if (Test-Path $ij) {
            $j = Get-Content $ij -Raw | ConvertFrom-Json
            $dll = Join-Path $d.FullName "UE4SS.dll"
            $dllInfo = if (Test-Path $dll) { $fi = Get-Item $dll; "UE4SS.dll {0:N0}B {1}" -f $fi.Length, $fi.LastWriteTime } else { "无 UE4SS.dll" }
            Info ("[{0}]  {1}" -f $d.Name, $j.ModName)
            Info ("         version={0}   {1}" -f $j.Version, $dllInfo)
        }
    }
}

# ---------------------------------------------------------------- 5. 版本对比
Head "5. 关键对比：本地 vs 创意工坊"
$wsUe4ss = Join-Path $wsRoot "3623730"
if (Test-Path $wsUe4ss) { $wsUe4ss = Join-Path $wsRoot "3623730" }
$cands = @()
if (Test-Path $wsRoot) {
    $cands = Get-ChildItem $wsRoot -Directory | Where-Object { Test-Path (Join-Path $_.FullName "UE4SS.dll") }
}
$localDll = Join-Path $ue4ssDir "UE4SS.dll"
if ((Test-Path $localDll) -and $cands.Count -gt 0) {
    $l = Get-Item $localDll
    $w = Get-Item (Join-Path $cands[0].FullName "UE4SS.dll")
    Info ("本地:     {0,12:N0} bytes   {1}" -f $l.Length, $l.LastWriteTime)
    Info ("创意工坊: {0,12:N0} bytes   {1}" -f $w.Length, $w.LastWriteTime)
    $lh = (Get-FileHash $localDll -Algorithm SHA256).Hash.Substring(0,12)
    $wh = (Get-FileHash (Join-Path $cands[0].FullName "UE4SS.dll") -Algorithm SHA256).Hash.Substring(0,12)
    Info ("本地 sha256:     $lh")
    Info ("创意工坊 sha256: $wh")
    if ($lh -ne $wh) {
        Bad "两边 DLL 不一致 → 本地是旧版/残缺版"
        Info "  → 旧版 UE4SS 有 FText 崩溃 bug，且新版游戏二进制布局变了会导致注入失败"
    } else {
        Ok "两边 DLL 一致"
    }
}

# ---------------------------------------------------------------- 6. 官方 mod 开关
Head "6. Palworld 官方 mod 系统开关"
if (Test-Path $palIni) {
    $ini = Get-Content $palIni -Raw
    Info $ini.Trim()
    if ($ini -match "bGlobalEnableMod\s*=\s*True") { Ok "bGlobalEnableMod = True（全局已开启）" }
    else { Bad "bGlobalEnableMod 不是 True → 官方 mod 系统被关了，UE4SS 不会被部署" }
    if ($ini -match "ActiveModList") {
        Ok "ActiveModList 里有条目"
    } else {
        Bad "ActiveModList 为空 → 创意工坊的 mod 没被启用"
        Info "  → 这是关键！需要在【游戏内】把 UE4SS 和 FirstPerson 启用"
        Info "  → 位置：主菜单 → 设置/游戏设置 里的 mod 管理（Palworld 1.0 新增的官方 mod 菜单）"
    }
} else {
    Bad "找不到 PalModSettings.ini"
}

# ---------------------------------------------------------------- 7. 日志证据
Head "7. UE4SS 日志（最后一次真正运行的时间）"
if (Test-Path $logPath) {
    $fi = Get-Item $logPath
    Info ("UE4SS.log 最后写入: {0}   大小 {1:N0}B" -f $fi.LastWriteTime, $fi.Length)
    $age = (Get-Date) - $fi.LastWriteTime
    if ($age.TotalDays -gt 1) {
        Bad ("日志已停更 {0:N1} 天 → UE4SS 从那时起就没再启动过" -f $age.TotalDays)
    } else {
        Ok "日志是最近的"
    }
    Info ""
    Info "日志尾部 5 行:"
    Get-Content $logPath -Tail 5 | ForEach-Object { Info ("    " + $_) }
    $pw = Select-String -Path $logPath -Pattern "PWRecon" -SimpleMatch
    if ($pw) { Ok "日志里出现了 PWRecon" } else { Bad "日志里没有 PWRecon（因为 UE4SS 压根没启动）" }
} else {
    Bad "找不到 UE4SS.log"
}

# ---------------------------------------------------------------- 8. 游戏本体更新时间
Head "8. 游戏本体更新时间（版本脱节判断）"
$exe = Join-Path $win64 "Palworld-Win64-Shipping.exe"
if (Test-Path $exe) {
    $fi = Get-Item $exe
    Info ("Palworld-Win64-Shipping.exe  {0:N0} bytes   {1}" -f $fi.Length, $fi.LastWriteTime)
}
$acf = "D:\Steam\steamapps\appmanifest_1623730.acf"
if (Test-Path $acf) {
    $lu = (Get-Content $acf | Select-String -Pattern "LastUpdated").Line -replace '\D',''
    if ($lu) { Info ("Steam 记录的最后更新时间: " + [DateTimeOffset]::FromUnixTimeSeconds([int64]$lu).LocalDateTime) }
    $bid = (Get-Content $acf | Select-String -Pattern '"buildid"').Line.Trim()
    Info ("Steam buildid: $bid")
}

# ---------------------------------------------------------------- 结论
Head "诊断结论与修复方案"
Write-Host @"
本脚本只做诊断，没有修改任何文件。

按顺序执行以下修复（前 4 步都不需要装任何东西）:

  [1] 完全退出游戏
      任务管理器确认没有 Palworld-Win64-Shipping.exe

  [2] 确认 Steam 创意工坊订阅了 UE4SS 且已更新
      Steam → 库 → 幻兽帕鲁 → 创意工坊 → 已订阅项目
      找到 "UE4SS Experimental (Palworld)"，若有更新按钮就点更新

  [3] 删除本地那份【旧且残缺】的 UE4SS，让官方 mod 系统重新部署
      把整个文件夹改名即可（不要直接删，留个后悔的余地）:
        $ue4ssDir
      改名为:
        $ue4ssDir.old

  [4] 启动游戏，在【游戏内】把 mod 启用
      主菜单进设置，找 mod / 模组管理，把 "UE4SS Experimental (Palworld)" 打开
      （PalModSettings.ini 的 ActiveModList 目前是空的，必须在这里启用）

  [5] 进游戏后按 F7。若仍无效，重新跑本脚本，看第 1、2、7 节

关键判据: 修好后 $logPath 的修改时间会变成"刚刚"。
"@
Write-Host ""
