#Requires -Version 5.1
<#
  install.ps1 -- 把 PWRecon 侦察 Mod 装进 Palworld 的 UE4SS

  做三件事:
    1. 找到 UE4SS 的 Mods 目录
    2. 复制 PWRecon/Scripts/main.lua 过去
    3. 在 mods.txt 里启用 PWRecon

  用法（Windows 自带 PowerShell 5.1 即可，不需要 pwsh 7）:
    powershell -ExecutionPolicy Bypass -File install.ps1
    powershell -ExecutionPolicy Bypass -File install.ps1 -GameRoot "D:\Steam\steamapps\common\Palworld"
    powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
#>

param(
    [switch]$Uninstall,
    [string]$GameRoot = ""
)

$ErrorActionPreference = "Stop"

function Say($m) { Write-Host $m }
function Ok($m)  { Write-Host $m -ForegroundColor Green }
function Warn($m){ Write-Host $m -ForegroundColor Yellow }
function Bad($m) { Write-Host $m -ForegroundColor Red }

# ---------------------------------------------------------------- 定位游戏
if (-not $GameRoot) {
    $candidates = @(
        "D:\Steam\steamapps\common\Palworld",
        "C:\Program Files (x86)\Steam\steamapps\common\Palworld",
        "D:\SteamLibrary\steamapps\common\Palworld",
        "E:\SteamLibrary\steamapps\common\Palworld"
    )
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c "Palworld.exe")) { $GameRoot = $c; break }
    }
}
if (-not $GameRoot -or -not (Test-Path (Join-Path $GameRoot "Palworld.exe"))) {
    Bad "找不到 Palworld 安装目录。请用 -GameRoot 手动指定，例如:"
    Bad "  powershell -ExecutionPolicy Bypass -File install.ps1 -GameRoot D:\Steam\steamapps\common\Palworld"
    exit 1
}
Ok "游戏目录: $GameRoot"

$ue4ssMods = Join-Path $GameRoot "Mods\NativeMods\UE4SS\Mods"
if (-not (Test-Path $ue4ssMods)) {
    Bad "找不到 UE4SS Mods 目录: $ue4ssMods"
    Bad "说明这个游戏没有装 UE4SS，请先从 Steam 创意工坊订阅 UE4SS Experimental (Palworld)。"
    exit 1
}
Ok "UE4SS Mods: $ue4ssMods"

$dest      = Join-Path $ue4ssMods "PWRecon"
$modsTxt   = Join-Path $ue4ssMods "mods.txt"
$here      = Split-Path -Parent $MyInvocation.MyCommand.Path
$srcMain   = Join-Path $here "Scripts\main.lua"

# ---------------------------------------------------------------- 卸载
if ($Uninstall) {
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force; Ok "已删除 $dest" }
    if (Test-Path $modsTxt) {
        $c = Get-Content $modsTxt -Raw
        $c = $c -replace '(?m)^\s*PWRecon\s*:\s*[01]\s*\r?\n', ''
        Set-Content $modsTxt $c -NoNewline
        Ok "已从 mods.txt 移除 PWRecon"
    }
    Say ""
    Say "重启游戏后生效。"
    exit 0
}

# ---------------------------------------------------------------- 安装
if (-not (Test-Path $srcMain)) {
    Bad "找不到源文件: $srcMain"
    Bad "请在 palworld-litematica\mod\PWRecon 目录下运行本脚本。"
    exit 1
}

New-Item -ItemType Directory -Force -Path (Join-Path $dest "Scripts") | Out-Null
Copy-Item $srcMain (Join-Path $dest "Scripts\main.lua") -Force
Ok "已复制 main.lua 到: $($dest)\Scripts\main.lua"

# 官方 Mod 清单（可选，但保持和环境里其它 mod 一致）
$info = @'
{
  "ModName": "PWRecon (Palworld Build Recon)",
  "PackageName": "PWRecon",
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
'@
Set-Content (Join-Path $dest "Info.json") $info -Encoding UTF8
Ok "已写出 Info.json"

# ---------------------------------------------------------------- 启用
if (-not (Test-Path $modsTxt)) {
    Warn "mods.txt 不存在，创建它"
    "PWRecon : 1" | Set-Content $modsTxt -Encoding ASCII
    Ok "已创建 mods.txt 并启用 PWRecon"
} else {
    $content = Get-Content $modsTxt -Raw
    if ($content -match '(?m)^\s*PWRecon\s*:\s*1\s*$') {
        Ok "mods.txt 里已经启用了 PWRecon，跳过"
    } else {
        # 先删掉可能存在的禁用行，再追加
        $content = $content -replace '(?m)^\s*PWRecon\s*:\s*0\s*\r?\n', ''
        if (-not $content.EndsWith("`n")) { $content += "`r`n" }
        $content += "`r`nPWRecon : 1`r`n"
        Set-Content $modsTxt $content -NoNewline
        Ok "已在 mods.txt 末尾追加: PWRecon : 1"
    }
}

# ---------------------------------------------------------------- 提示
Say ""
Say "============================ 安装完成 ============================"
Say "关键动作: 必须修改 UE4SS 设置打开热键，否则 F7/F8/F9 没反应。"
Say ""
Say "  用记事本打开:"
Say "    $($GameRoot)\Mods\NativeMods\UE4SS\UE4SS-settings.ini"
Say "  找到并改成:"
Say "    EnableHotReloadSystem = 1     [强烈建议, 改 lua 不用重启游戏]"
Say ""
Say "然后【重启游戏】，读档进入世界，依次按:"
Say "  F7   扫描建筑相关类（最重要，先按这个）"
Say "  F8   详细转储目标类"
Say "  F9   列出基地"
Say ""
Say "结果在两个地方都能看到:"
Say "  1) 文件: $($dest)\recon_class_stats.txt"
Say "  2) 日志: $($GameRoot)\Mods\NativeMods\UE4SS\UE4SS.log"
Say ""
Say "把 recon_class_stats.txt 和 recon_details.txt 发我。"
Say "================================================================="
