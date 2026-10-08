<#
  make_release.ps1 —— 一键打出两个发布物（Steam 创意工坊包 + N 网压缩包）

  为什么需要它:
    发布 / 每次更新都要**按平台的格式重新打包**，手工会漏（少一个 .lua、把用户数据打进去、
    把 Nexus 的 zip 结构弄成双层……）。这个脚本把"打什么、打成什么样"固定下来。

  两个产物（默认写到 ..\..\backups\PWProjection\发布\<版本>\）:
    ① 创意工坊包（文件夹，直接拖进 Palworld Mod Uploader 的包目录）
         Info.json + thumbnail.png + Scripts\*.lua + Scripts\pwpr_meshmap.default.json
       ★ **不放** 用户数据（pwpr_config.json / pwpr_keys.json / pwpr_placements.json /
         pwpr_meshmap.json / pwpr.log）、**不放** deploy.ps1、**不放** enabled.txt / mods.txt
    ② N 网压缩包（zip，解压只多一层 PWProjection\）
         PWProjection\Scripts\*.lua + pwpr_meshmap.default.json + mods.txt 说明文件 + README/LICENSE

  用法:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\make_release.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\make_release.ps1 -Version 1.0.1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\make_release.ps1 -Force      # 覆盖同版本目录
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\make_release.ps1 -OutDir "D:\some\where"

  ★ 路径写成**绝对路径**也完全可以（脚本用 `$PSScriptRoot` 定位仓库，**不需要先 cd**）:
    powershell -NoProfile -ExecutionPolicy Bypass -File D:\dsh-workspace\palworld-litematica\tools\make_release.ps1
  ★ 别把两条命令粘成一行（`cd <目录> powershell ...` 会被当成 cd 的参数 —— 实测踩过）。
#>
param(
    [string]$Version = "",                     # 留空 = 从 workshop\Info.json 的 Version 读
    [string]$OutDir  = "",
    [switch]$SkipChecks,
    [switch]$Force                             # 允许覆盖已存在的同版本目录（默认拒绝）
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot                 # 仓库根
$ModDir   = Join-Path $RepoRoot "mod\PWProjection"
$SrcDir   = Join-Path $ModDir "Scripts"
$WsDir    = Join-Path $ModDir "workshop"
$InfoPath = Join-Path $WsDir "Info.json"

function Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Bad($m)  { Write-Host "  [错误] $m" -ForegroundColor Red }
function Info($m) { Write-Host "  $m" }

if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $RepoRoot) "backups\PWProjection\发布" }

# ------------------------------------------------------------------ 静态检查
if (-not $SkipChecks) {
    $checker = Join-Path $PSScriptRoot "luacheck.py"
    if (Test-Path $checker) {
        Write-Host "--- 发布前静态检查 (luacheck) ---"
        & python $checker $SrcDir
        if ($LASTEXITCODE -ne 0) { Bad "静态检查没通过 —— 已中止打包"; exit 1 }
        Write-Host ""
    } else {
        Info "没找到 tools\luacheck.py（跳过静态检查）"
    }
}

if (-not (Test-Path $InfoPath)) { Bad "找不到 $InfoPath"; exit 1 }
$info = Get-Content $InfoPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $Version) { $Version = [string]$info.Version }
if ($Version -notmatch '^[a-zA-Z0-9.\-]+$') { Bad "版本号只能含字母数字与 . - ：$Version"; exit 1 }

# ★ 用户数据 / 非发布文件（**绝不进包**）
$ExcludeNames = @(
    "pwpr_config.json", "pwpr_config.bak.json", "pwpr_keys.json", "pwpr_keys.bak.json",
    "pwpr_keys.bad.json", "pwpr_placements.json", "pwpr_meshmap.json",
    "pwpr.log", "pwpr.log.old.log", "pwpr_ghost_host.txt", "pwpr_meshes.txt",
    "pwpr_probe.txt", "pwpr_ui.txt", "pwpr_capabilities.json"
)

$lua      = Get-ChildItem $SrcDir -Filter *.lua -File | Sort-Object Name
$meshDef  = Join-Path $SrcDir "pwpr_meshmap.default.json"
if ($lua.Count -eq 0) { Bad "源目录里没有 .lua"; exit 1 }
if (-not (Test-Path $meshDef)) { Bad "缺少 pwpr_meshmap.default.json"; exit 1 }

$verDir = Join-Path $OutDir $Version
if (Test-Path $verDir) {
    if (-not $Force) {
        Bad "目标已存在: $verDir"
        Info "要重打就往信息里改 Version（推荐），或加 -Force 覆盖它"
        exit 1
    }
    # ★ 删除前先核对路径: 必须真的在 $OutDir 下、且最后一段就是版本号（防手滑删错目录）
    $full = [System.IO.Path]::GetFullPath($verDir)
    $base = [System.IO.Path]::GetFullPath($OutDir)
    if (-not $full.StartsWith($base) -or (Split-Path $full -Leaf) -ne $Version) {
        Bad "拒绝删除（路径核对不过）: $full"; exit 1
    }
    Remove-Item -LiteralPath $full -Recurse -Force
    Info "已覆盖旧目录: $full"
}
New-Item -ItemType Directory -Force -Path $verDir | Out-Null

# ------------------------------------------------------------------ 缩略图（工坊硬性: < 1MB）
# ★★★ 2026-10-08 晚修: 原来只认 `thumbnail.png` —— 玩家把图换成 .jpg 并把 Info.json 的
#   `Thumbnail` 改成 `thumbnail.jpg` 之后，打出来的包里**根本没有那张图**
#   （工坊条目因此没有预览图 ✗，而且 InstallManifest 里也查不到它）。
#   现在: ① 按 Info.json 写的名字找；② 找不到就退而找 thumbnail.(png|jpg|jpeg|webp)；
#         ③ **自动把包内 Info.json 的 Thumbnail 改成实际文件名**（源文件不动）；
#         ④ 大小 ≥1MB 直接报错（Steam 会返回 k_EResultLimitExceeded ✗）。
$thumbName = [string]$info.Thumbnail
$thumbSrc = $null
if ($thumbName) { $c = Join-Path $WsDir $thumbName; if (Test-Path $c) { $thumbSrc = $c } }
if (-not $thumbSrc) {
    foreach ($ext in @(".png", ".jpg", ".jpeg", ".webp")) {
        $c = Join-Path $WsDir ("thumbnail" + $ext)
        if (Test-Path $c) { $thumbSrc = $c; break }
    }
}
if (-not $thumbSrc) { Bad "找不到缩略图 —— 放一张 workshop\thumbnail.png 或 .jpg"; exit 1 }
$thumbFile = Split-Path $thumbSrc -Leaf
if ((Get-Item $thumbSrc).Length -ge 1MB) {
    Bad ("缩略图 {0:N0} bytes ≥ 1MB —— Steam 会拒绝（k_EResultLimitExceeded）⇒ 先压到 1MB 以下" -f (Get-Item $thumbSrc).Length)
    exit 1
}

# ------------------------------------------------------------------ ① 创意工坊包
$wsPkg = Join-Path $verDir "workshop_package"
$wsScripts = Join-Path $wsPkg "Scripts"
New-Item -ItemType Directory -Force -Path $wsScripts | Out-Null
Copy-Item $ThumbSrc (Join-Path $wsPkg $thumbFile) -Force
if ($thumbName -and $thumbName -ne $thumbFile) {
    Info "[注意] Info.json 写的是 '$thumbName'，实际找到 '$thumbFile' ⇒ 包内已自动改成实际名字（源文件没动）"
    $fixed = Get-Content $InfoPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $fixed.Thumbnail = $thumbFile
    $fixed | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $wsPkg "Info.json") -Encoding UTF8
} else {
    Copy-Item $InfoPath (Join-Path $wsPkg "Info.json") -Force
}
Ok ("缩略图: {0}（{1:N0} bytes，< 1MB ✓）" -f $thumbFile, (Get-Item $thumbSrc).Length)
foreach ($f in $lua) { Copy-Item $f.FullName (Join-Path $wsScripts $f.Name) -Force }
Copy-Item $meshDef (Join-Path $wsScripts "pwpr_meshmap.default.json") -Force

$wsFiles = Get-ChildItem $wsPkg -Recurse -File
$wsBytes = ($wsFiles | Measure-Object Length -Sum).Sum
Ok ("创意工坊包: {0} 个文件 / {1:N0} bytes  ->  {2}" -f $wsFiles.Count, $wsBytes, $wsPkg)

# 自检: 包里不能有用户数据 / 不能有 enabled.txt
$bad = $wsFiles | Where-Object { $ExcludeNames -contains $_.Name -or $_.Name -eq "enabled.txt" -or $_.Name -eq "mods.txt" }
if ($bad) { Bad ("工坊包里混进了不该有的文件: " + (($bad | ForEach-Object Name) -join ", ")); exit 1 }

# ------------------------------------------------------------------ ② N 网压缩包
$nxRoot = Join-Path $verDir "nexus_zip"
$nxMod  = Join-Path $nxRoot "PWProjection"
$nxScripts = Join-Path $nxMod "Scripts"
New-Item -ItemType Directory -Force -Path $nxScripts | Out-Null
foreach ($f in $lua) { Copy-Item $f.FullName (Join-Path $nxScripts $f.Name) -Force }
Copy-Item $meshDef (Join-Path $nxScripts "pwpr_meshmap.default.json") -Force

$docSrc = Join-Path $RepoRoot "docs\发布"
foreach ($d in @(@{S = "安装与使用.md";           D = "安装与使用.md" },
                 @{ S = "INSTALL_EN.md";           D = "INSTALL_EN.md" },
                 @{ S = "更新日志.md";             D = "CHANGELOG.md" })) {
    $p = Join-Path $docSrc $d.S
    if (Test-Path $p) { Copy-Item $p (Join-Path $nxMod $d.D) -Force }
    else { Info "[注意] 缺 docs\发布\$($d.S)（N 网包里就没有它）" }
}
Copy-Item (Join-Path $RepoRoot "LICENSE") (Join-Path $nxMod "LICENSE") -Force

$nxZip = Join-Path $verDir "PWProjection-$Version.zip"
Compress-Archive -Path (Join-Path $nxRoot "*") -DestinationPath $nxZip -Force
Ok ("N 网压缩包: {0:N0} bytes  ->  {1}" -f (Get-Item $nxZip).Length, $nxZip)

# ------------------------------------------------------------------ 校验清单
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# PWProjection 发布物 $Version —— SHA256 校验清单")
$lines.Add("# 工坊包 = $wsPkg")
$lines.Add("# N 网包 = $nxZip")
$lines.Add("")
foreach ($f in (Get-ChildItem $verDir -Recurse -File | Where-Object { $_.Name -ne "校验清单.txt" } | Sort-Object FullName)) {
    $rel = $f.FullName.Substring($verDir.Length + 1)
    $lines.Add(("{0}  {1}" -f (Get-FileHash $f.FullName -Algorithm SHA256).Hash, $rel))
}
[System.IO.File]::WriteAllLines((Join-Path $verDir "校验清单.txt"), $lines,
    (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "== 完成 ==" -ForegroundColor White
Info "版本: $Version"
Info "工坊包（拖进 Palworld Mod Uploader）: $wsPkg"
Info "N 网包（上传这个 zip）            : $nxZip"
Info "★ 发布前记得: 看一眼 docs\发布\发布准备.md 的清单（尤其 ④ 的两个问题）"
