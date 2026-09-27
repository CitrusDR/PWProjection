# PWRecon —— Palworld 建筑系统侦察 Mod（阶段 0）

## 为什么改用这条路

你的存档头是 `PlM1`：

```
新存档(1.0):  u32@0=32297896  u32@4=2208234  magic=PlM1
老存档(0.1.4): magic=PlZ2  ← zlib，可直接解
```

`PlM` = **Oodle 压缩**，不是 zlib。而且 1.0 还把地图对象数据换成了带 pickup guard
的新格式（PalworldSavePal v1.4.3 的更新日志专门修了这个 `PalMapConcreteModel` 解析错误）。

这意味着离线解析存档的链路变成：**Oodle 解压器 → GVAS 解析 → 自定义新格式解析器**，
三段都可能出问题，而且 `pip install ooz` 在 PyPI 上根本不存在这个包。

**而我发现你游戏里 UE4SS 已经装好并且跑通了**（`UE4SS.log` 里有
`Starting Lua mod 'FirstPerson'`）。所以直接把侦察改成读运行中的游戏内存：

| | 离线存档解析 | 在线 UE4SS 读取 |
|---|---|---|
| 链路长度 | Oodle + GVAS + 新格式，3 段 | 1 步反射 |
| 失败点 | 3 个 | 1 个 |
| 能否拿到渲染需要的实时数据 | 不能 | **能** |
| 你已具备的条件 | 缺 Oodle 解压器 | **已装好** |

结论：**离线导出不是主路径，降级为可选**。真正的路径是 UE4SS。

---

## 你的环境现状（已探明）

| 项目 | 状态 |
|---|---|
| Palworld | `D:\Steam\steamapps\common\Palworld` |
| UE4SS | ✅ 已修好：`v3.0.1 Beta #0 / SHA 2281fa31`，2026-09-26 重新部署 |
| UE4SS 是否跑通过 | ✅ 是，日志显示 `Starting Lua mod 'FirstPerson'`，F6 可用 |
| Mods 目录 | ✅ `...\UE4SS\Mods\` |
| 现有 Lua mod | FirstPerson、BPModLoaderMod 等 |
| Palworld 1.0 官方 Mod 体系 | ✅ `Mods\ManagedMods` + `Mods\NativeMods` + `PalModSettings.ini` |

**这说明第一阶段的技术选型已经被现实验证了** —— 不需要装 PMK、不需要 VS2022、
不需要 Wwise、不需要编译 C++。纯文本 Lua，改完重进游戏即生效。

---

## ⚠️ 一个必须知道的坑：`mods.txt` 会被官方部署重置

踩过一次，记下来避免重复浪费时间。

**现象**：跑完 `install.ps1`，进游戏按 F7 没反应，而且 mod 列表里看不到 PWRecon。

**原因**：UE4SS 只加载 `Mods\mods.txt` 里列出的 mod（这个版本没有 `enabled.txt`）。
但 Palworld 官方 mod 系统把 `mods.txt` 当作**受管文件**——
`Mods\ManagedMods\UE4SSExperimentalPW\InstallManifest.json` 的 `Files` 列表里就包含它。

所以每次你：

- 在游戏里动 mod 开关
- 创意工坊 mod 更新
- 游戏本体更新

官方系统都会把 `mods.txt` 重置回默认内容，**`PWRecon : 1` 那一行就被冲掉了**。
`UE4SS-settings.ini` 里的 `EnableHotReloadSystem` 同样会被重置回 `0`。

**解决**：重跑注册脚本（幂等，可以反复跑）：

```powershell
cd "D:\dsh-workspace\palworld-litematica\mod\PWRecon"
powershell -ExecutionPolicy Bypass -File register.ps1
```

先用 `-DryRun` 可以只看会改什么、不动文件：

```powershell
powershell -ExecutionPolicy Bypass -File register.ps1 -DryRun
```

**记住这个顺序**：

```
1. 先确认 UE4SS 活着（F6 能切第一人称）   ← 环境层
2. 再跑 install.ps1 + register.ps1        ← mod 层
3. 重启游戏，按 F7
```

第 1 步不成立时，折腾第 2 步是白费力气（这次就浪费了一轮）。

---

## 你要做的三步

### 第 1 步：打开热键支持（重要）

用记事本打开：

```
D:\Steam\steamapps\common\Palworld\Mods\NativeMods\UE4SS\UE4SS-settings.ini
```

把这一行改成 `1`（目前是 `0`）：

```ini
EnableHotReloadSystem = 1
```

> 改这个的好处：以后修改 `main.lua` 保存后**不用重启游戏**，UE4SS 会自动重新加载。
> 迭代速度从"每次几十秒"变成"每次一秒"，对后面开发投影渲染极其重要。

### 第 2 步：安装侦察 Mod

打开 **PowerShell**（Win+R 输入 `powershell`，不需要管理员），执行：

```powershell
cd "D:\dsh-workspace\palworld-litematica\mod\PWRecon"
powershell -ExecutionPolicy Bypass -File install.ps1
```

脚本会自己找到游戏目录、复制文件、在 `mods.txt` 里启用 PWRecon。

> 我无法替你执行这一步：DSH 的文件沙箱只允许写 `D:\dsh-workspace`，
> 写游戏目录会被拒绝（已实测确认）。

### 第 3 步：重启游戏 → 读档 → 按键

进入世界后依次按：

| 热键 | 作用 | 优先级 |
|---|---|---|
| **F7** | 扫描类统计，找出建筑相关的真实类名 | ⭐ 最重要，先按这个 |
| **F8** | 详细转储目标类（字段 + 数值） | 其次 |
| F9 | 列出所有基地 | 补充 |

看结果的两个地方：

```
1) 文件: D:\Steam\steamapps\common\Palworld\Mods\NativeMods\UE4SS\Mods\PWRecon\recon_*.txt
2) 日志: D:\Steam\steamapps\common\Palworld\Mods\NativeMods\UE4SS\UE4SS.log
```

**把 `recon_class_stats.txt` 和 `recon_details.txt` 发给我。**

---

## 这个脚本在找什么

它不猜任何类名，全靠运行时枚举 + 反射，目标是回答：

| # | 问题 | 为什么重要 |
|---|---|---|
| Q1 | 已放置的建筑挂在哪个类上？实例数多少？ | 决定投影渲染要遍历什么 |
| Q2 | 每个建筑实例有没有可读的 **Transform**？ | 没有它就无法定位投影 |
| Q3 | 建筑类型 ID 存在哪个字段？ | 决定蓝图格式怎么存 |
| Q4 | 基地和建筑怎么关联？ | 决定"按基地导出蓝图"能不能做 |
| Q5 | 静态网格资产路径能不能拿到？ | 决定投影用什么模型渲染 |

Q1、Q2 一旦确认，项目的最大未知数就消除了，可以开始写投影渲染原型。

---

## 故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| 按 F7 完全没反应 | 热键系统没开 | 回第 1 步改 `EnableHotReloadSystem = 1` |
| 按了没反应但 F6（FirstPerson）能用 | 游戏未进入世界 / 在读档界面 | 读档进入世界后再按 |
| `UE4SS.log` 里搜不到 `[PWRecon]` | Mod 没被加载 | 检查 `mods.txt` 里是否有 `PWRecon : 1` |
| 日志里 FMOD/`io.open` 报写文件失败 | 脚本目录不可写 | 直接看 `UE4SS.log`，结果也会打印到控制台 |
| `ForEachUObject` 报 nil | 该 API 在 experimental 版改名了 | 把日志发我，我换成 `FindAllOf` 逐类枚举 |
| 什么都没扫到 | 关键字不匹配 | 按 F8 试候选类，或把日志发我 |

---

## 回滚

```powershell
cd "D:\dsh-workspace\palworld-litematica\mod\PWRecon"
powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
```

`install.ps1` 会删除 mod 目录并清掉 `mods.txt` 里的 PWRecon 行。

---

## 关于那个 Nexus Mod（Simple Building Blueprints, mod 4073）

你下载的页面我读到了，关键信息：

- **功能**：`Copy, save, and place multiple structures at once.` —— 复制、保存、批量放置建筑
- **前置依赖**：`RE-UE4SS`（`Okaetsu/RE-UE4SS` 的 `experimental-palworld` 分支）
- **版本**：已经迭代到 **0.16.1**，支持 Palworld 1.0.4
- **权限**：修改需授权、使用资产需授权、禁止转载到其它站点

**它是纯 UE4SS Lua mod，和我们的技术栈完全同一条路。**

这有几个重要含义：

1. **技术路线被验证了** —— 纯 Lua 能做建筑相关的深度操作，不需要 C++/pak
2. **大幅降低了技术风险** —— 但**没有降低这个项目的核心工作量**，因为它的重心是
   "自动批量放置"，而你要的是"半透明投影 + 手动放置 + 分层展示"
3. **它的 changelog 里有大量可复用的知识**，例如：
   - 提到 `ghost`（幽灵预览）—— 说明游戏内有现成的幽灵预览机制可参考
   - 提到支撑/连接关系传播（`support propagation`）—— 这是建筑系统的真实规则
   - 提到 `MOF`（Mod Options Framework）—— 配置界面框架，你可以直接用
   - 提到 4096 个建筑的固定上限被移除 —— 对我们判断性能规模很有用
4. **它有一个蓝图分享社区**：https://www.reddit.com/r/PalworldSBB/
   如果它的蓝图格式公开，你的导入器可以直接兼容它，等于白送一个蓝图来源

⚠️ **许可提醒**：作者明确要求"修改需授权、使用资产需授权"。
所以**只借鉴思路和格式，不要复制它的代码或资产**。如果之后要发布，先联系作者。

**建议**：你可以考虑先用它一段时间，体会一下 Palworld 里"蓝图工作流"的实际手感
（哪些交互顺、哪些别扭），这些体感会直接决定你的投影模组该做成什么样。
这比看文档有用得多。

---

## 下一步

拿到 `recon_class_stats.txt` 后，我会：

1. 确认建筑类名和 Transform 字段
2. 写投影渲染原型（HISM + 半透明材质，先硬编码几十件建筑）
3. 这一步同样必须游戏实测，也是真正的硬骨头
