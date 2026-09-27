<#
  PWProjection 快照打包脚本（可复用）

  做三件事:
    1. 核对【工作区里的源码】和【游戏目录里正在用的那份】是否逐字节一致
       —— 不一样就说明备份的不是"实测通过的那一版"，必须警告（可用 -SkipDeployCheck 跳过）。
    2. 把 mod + docs + tools 打成一个 zip（放进 backups\<标签>\）。
    3. 生成 SHA256 校验清单（覆盖"会被提交的所有文件"= git 跟踪的 + 未跟踪的）。

  用法:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\make_snapshot.ps1 -Label "2026-09-28_跨存档投影可用版"

  参数:
    -Label      快照目录名（必填），zip 名会用它
    -GameMod    游戏里 mod 目录（默认按 Steam 常见路径，找不到就自动跳过核对）
    -SkipDeployCheck  不做"工作区 vs 游戏目录"核对
#>
param(
    [Parameter(Mandatory = $true)][string]$Label,
    [string]$GameMod = "D:\Steam\steamapps\common\Palworld\Mods\NativeMods\UE4SS\Mods\PWProjection",
    [switch]$SkipDeployCheck,
    [switch]$Force            # 允许覆盖已存在的同名快照目录（默认拒绝）
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot          # 仓库根
$dest = Join-Path $root ("backups\" + $Label)
$stage = Join-Path $dest "_stage"
# zip 名: 固定前缀 PWProjection_；标签本身已经以它开头时不再重复加（免得出现 PWProjection_..._PWProjection_...）
$zipPrefix = "PWProjection_"
$zipLabel = if ($Label -like "*PWProjection*") { $Label } else { $zipPrefix + $Label }
$zip = Join-Path $dest ($zipLabel + ".zip")

Write-Host "== PWProjection 快照 ==" -ForegroundColor Cyan
Write-Host ("  仓库: " + $root)
Write-Host ("  目标: " + $dest)

# ---- 1. 工作区 vs 游戏目录 ------------------------------------------------
# 只比"部署脚本真的会复制过去"的那部分:
#   · mod 根下的 README.md / deploy.ps1 / 已知限制.md 本来就不进游戏目录
#   · Scripts\pwpr_meshmap.json 是【用户文件】，部署时**故意不覆盖** ⇒ 允许不同
$mismatch = @()
$userDiff = @()
if (-not $SkipDeployCheck -and (Test-Path $GameMod)) {
    $src = Join-Path $root "mod\PWProjection\Scripts"
    Get-ChildItem -Path $src -File | Where-Object {
        $_.Extension -eq ".lua" -or $_.Name -eq "pwpr_meshmap.default.json"
    } | ForEach-Object {
        $rel = "Scripts\" + $_.Name
        $other = Join-Path $GameMod $rel
        if (-not (Test-Path $other)) {
            $mismatch += "游戏里缺少: $rel"
        }
        else {
            $h1 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
            $h2 = (Get-FileHash $other -Algorithm SHA256).Hash
            if ($h1 -ne $h2) { $mismatch += "内容不同: $rel" }
        }
    }
    $userFile = Join-Path $src "pwpr_meshmap.json"
    $userInGame = Join-Path $GameMod "Scripts\pwpr_meshmap.json"
    if ((Test-Path $userFile) -and (Test-Path $userInGame)) {
        $h1 = (Get-FileHash $userFile -Algorithm SHA256).Hash
        $h2 = (Get-FileHash $userInGame -Algorithm SHA256).Hash
        if ($h1 -ne $h2) { $userDiff += "Scripts\pwpr_meshmap.json（用户文件，允许不同）" }
    }
    if ($mismatch.Count -eq 0) {
        Write-Host "  [OK] 部署过去的源码与游戏目录逐字节一致（备份的就是实测通过的那一版）" -ForegroundColor Green
    }
    else {
        Write-Host "  [!] 工作区与游戏目录不一致（共 $($mismatch.Count) 处）:" -ForegroundColor Yellow
        $mismatch | ForEach-Object { Write-Host ("      " + $_) -ForegroundColor Yellow }
        Write-Host "      ⇒ 备份的是【工作区】版本；如果游戏里那份才是实测版，先部署再打包。" -ForegroundColor Yellow
    }
    if ($userDiff.Count -gt 0) {
        Write-Host "  [i] 用户文件与游戏里那份不同（正常，部署不覆盖它）:" -ForegroundColor DarkGray
        $userDiff | ForEach-Object { Write-Host ("      " + $_) -ForegroundColor DarkGray }
    }
}
else {
    Write-Host "  [--] 跳过部署核对（未找到游戏目录或显式跳过）" -ForegroundColor DarkGray
}

# ---- 2. 打包 --------------------------------------------------------------
# ★ 防呆（2026-09-28 真的踩到过）: 目标目录已存在时**不要**默默覆盖 ——
#   上一次就是因为重用了旧标签，把改名前的快照目录整个删掉了
#   （那个 zip 没进 git，找不回来）。要覆盖得显式加 -Force。
if ((Test-Path $dest) -and (-not $Force)) {
    Write-Host ("  [!] 目标已存在: " + $dest) -ForegroundColor Yellow
    Write-Host "      ⇒ 换一个标签（推荐 日期_版本说明，例如 2026-09-28_跨存档投影可用版）；" -ForegroundColor Yellow
    Write-Host "        确实要覆盖就加 -Force。" -ForegroundColor Yellow
    exit 2
}
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
foreach ($part in @("mod\PWProjection", "docs", "tools")) {
    $p = Join-Path $root $part
    if (Test-Path $p) {
        $target = Join-Path $stage (Split-Path $part -Leaf)
        Copy-Item $p $target -Recurse -Force
    }
}
# 打包时排除运行期产物（本来就不该进快照）
$junkNames = @("pwpr.log", "pwpr_config.json", "pwpr_ui.txt", "pwpr_meshes.txt",
    "pwpr_probe.txt", "pwpr_capabilities.json", "*.pyc")
Get-ChildItem $stage -Recurse -File -Include $junkNames -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem $stage -Recurse -Directory -Filter "__pycache__" -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zip -Force
Remove-Item $stage -Recurse -Force
Write-Host ("  [OK] 压缩包: " + $zip + "  (" + [math]::Round((Get-Item $zip).Length / 1KB) + " KB)") -ForegroundColor Green

# ---- 3. 校验清单（覆盖"会被提交的所有文件"）-------------------------------
$list = Join-Path $dest "校验清单.txt"
$lines = @()
$lines += "# PWProjection 快照校验清单（SHA256）"
$lines += ("# 生成时间: " + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
$lines += "# 范围: 会被提交到 git 的所有文件（git 跟踪的 + 未跟踪的）+ 快照压缩包本身"
$lines += "# 说明: 文档里的 Windows 用户名与 SteamID64 已替换为 <用户名> / <SteamID64>"
$lines += ""
$files = @()
Push-Location $root
$tracked = & git ls-files
$untracked = (& git ls-files --others --exclude-standard)
Pop-Location
$files += $tracked
$files += $untracked
$files = $files | Where-Object { $_ -and (Test-Path (Join-Path $root $_)) } | Sort-Object -Unique

foreach ($f in $files) {
    $full = Join-Path $root $f
    $h = (Get-FileHash $full -Algorithm SHA256).Hash
    $size = (Get-Item $full).Length
    $lines += ("{0}  {1,8}  {2}" -f $h, $size, $f.Replace("/", "\"))
}
$lines += ("{0}  {1,8}  {2}" -f (Get-FileHash $zip -Algorithm SHA256).Hash,
    (Get-Item $zip).Length, ("backups\" + $Label + "\" + (Split-Path $zip -Leaf)))
$lines += ""
$lines += ("# 文件数: " + $files.Count + " (+ 压缩包 1)")
Set-Content -Path $list -Value $lines -Encoding UTF8
Write-Host ("  [OK] 校验清单: " + $list + "  (" + $files.Count + " 个文件)") -ForegroundColor Green

if ($mismatch.Count -gt 0) {
    Write-Host "  提醒: 本次快照与游戏目录不一致，记得在快照说明里写清楚。" -ForegroundColor Yellow
}
Write-Host "== 完成 ==" -ForegroundColor Cyan
