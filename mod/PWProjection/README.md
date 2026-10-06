# PWProjection — Palworld 蓝图投影 mod

> 给 Palworld 加一个 **Litematica 式**的蓝图/投影功能：
> 把基地存成蓝图、在任意位置以半透明幽灵形式投影出来、随时挪动、**一层一层看**。

- 运行在 **UE4SS**（Lua），不需要改 pak、不需要编译、不需要 UE 编辑器
- 面向 **单人 / 自建服务器存档**
- 参考了 Simple Building Blueprints 的**架构思路**，但**代码是独立写的**，不复用其源码
- 当前状态（**2026-09-29 定稿，构建 `2026-09-29.59`**）：**采集 / 投影 / 微调 / 分层 / 材质 / 骨骼网格 / 屏幕提示 / 建造吸附 / 已放上的不再投影 / 位置进度记忆** —— **全部实机验证可用** ✓
  - ★ **水上建筑（在水面放地基）也可用**：建造吸附的"拦下原请求 → 按投影坐标重发"已从
    "在钩子回调里嵌套调用"改成 **`buildsnap_defer`（重发排到下一帧）** ⇒ 实测 **3/3 成功、不再卡死/崩溃**
    （四次事故的完整取证与修法见 `docs\踩坑记录.md` §68-10 ~ §68-14）
  - ★ **自动高度自适应**：如果"吸附后的高度游戏不认"（比如水面地基），它会**自动把整份投影的高度挪到游戏允许的位置**（弹提示告诉你，并记进位置记忆）⇒ 再放一次就用修正后的高度、**高度继续跟投影**（不是关掉高度吸附）。机制见 `docs\当前行为总览.md` §5b 与 `docs\建造吸附.md` §3.6
  - 想快速知道「现在这一版到底是什么行为」 ⇒ 看 **`docs\当前行为总览.md`**
  - 参数逐条解释 ⇒ `docs\配置说明.md`；为什么这么写 ⇒ `docs\踩坑记录.md`；不能画的 ⇒ `已知限制.md`

---

## 目录

| 节 | 内容 |
|---|---|
| **1** | [五分钟上手](#1-五分钟上手) —— **安装**（1.1）· 进游戏（1.2）· 第一次使用（1.3）· 验证（1.4）· **卸载/回滚（1.5）** |
| **2** | 按键（一页速查 + 方向键模式 + 材质对照表） |
| **3** | 文件位置 —— **模组必需文件清单（3.1）** · 运行时输出（3.2） |
| **4** | 安全设计（为什么这个 mod 崩不了游戏）—— **屏幕提示与探测（4.6）** |
| **5** | 配置 `pwpr_config.json` |
| **6** | 崩了怎么办（崩溃归因流程 + 症状速查表） |
| **7** | 蓝图格式 |
| **8** | 分层展示到底会分成什么样（重要预期管理） |
| **9** | 已知问题 |
| **10** | ★ **补充缺失建筑 / 修正朝向（操作指南）** —— 以后遇到问题主要看这节 |
| **11** | ★ **总体进度与下一步计划** |
| **12** | 授权 |

> **只想看三件事**：
> 装 → 第 1 节；用 → 第 2 节；**以后发现建筑缺失/异常 → 第 10 节**。
>
> **想知道"它是怎么做到的"（实现方式）** ⇒ [`docs\实现方式.md`](../../docs/实现方式.md)
> （**只写我们自己的做法**：每个功能用哪些引擎接口、什么数据结构、什么时候碰引擎、失败怎么退；
> 19 个模块的职责表也在那里）。
>
> **画不出来 / 画不对的建筑清单**：`已知限制.md`（单独一份，面向使用者）。
>
> **更深的设计文档**在工作区的 `docs\` 目录：
> `踩坑记录.md`（按症状查的坑库）· `蓝图格式.md` · `项目状态与路线图.md`
> （含 **5 条待办**）· `SBB架构分析.md` · `交接笔记.md`。
> **以本 README 为准**，`docs\` 是过程记录。

---

## 1. 五分钟上手

### 1.1 部署（安装）

```
powershell -ExecutionPolicy Bypass -File deploy.ps1 -DryRun    # 先看会改什么
powershell -ExecutionPolicy Bypass -File deploy.ps1            # 真正部署
```

部署脚本会：

1. 把 `Scripts\*.lua` 复制到 `<游戏>\Mods\NativeMods\UE4SS\Mods\PWProjection\Scripts\`
2. 在 `mods.txt` 里启用 `PWProjection`（幂等，可反复跑）
3. 顺手清理已废弃的 `PWRecon` / `PWKeyTest`
4. 打开 `EnableHotReloadSystem`

> 游戏必须**完全退出**再跑部署脚本（否则 lua 文件被锁）。

### 1.2 进游戏

1. 启动游戏，**完整读档**进入世界
2. 能自由走动、画面稳定后，按 **`F7`** —— 控制台应出现帮助

> ⚠️ **不要在载入画面或刚进世界的几秒内按键。** 前几次崩溃都是这个原因。

### 1.3 第一次使用（顺序很重要）

> ### ⚠️ 第 0 步：先把 UE4SS 调试窗口打开 —— 否则你什么都看不见
>
> `UE4SS-settings.ini` 里 `ConsoleEnabled` / `GuiConsoleEnabled` /
> `GuiConsoleVisible` 都设成 `1`（本机已经是 `1`）。
>
> **但还有第二个开关**：`GraphicsAPI`。本机是默认值 `opengl`，
> 它会把调试窗口渲染成**独立窗口，不盖在游戏画面上** ——
> 所以你会觉得"我得去翻日志"。改成 `dx11` 重启游戏才会盖在游戏上
> （前提：游戏本身跑 DX11）。**详见 4.6 最后一节。**
>
> 游戏的**所有即时反馈**都走这个窗口（`print`，纯 ASCII）。
> 游戏内的中文提示正在做（待办 1）：现在默认已开启**控制台通道**，
> 想要游戏内文字要按 `O` 探测一次，见 4.6。
>
> 不打开也能用，但你就只能事后去看 `Scripts\pwpr.log`（中文、完整）。

```
① 打开 UE4SS 调试窗口（见上）
② 站到基地里  →  按 Y        采集"玩家附近"的基地 → 生成蓝图
③             →  按 J        加载刚采集的蓝图
④             →  按 N        渲染能力探测（S3）
⑤  把 pwpr_config.json 里的 ghost_enabled 改成 true
⑥             →  按 F8       重载配置（不用重启游戏）
⑦             →  按 K        放投影

（可选，跟投影无关）
⑧             →  按 O        屏幕提示通道探测（S9）→ 想看游戏内文字就跑它
```

**第 ④ 步不能跳过。** 没有探测通过，第 ⑦ 步会拒绝执行（见第 4 节）。
第 ⑤ 步是**故意**做成手动的 —— 见 4.2 的双重门禁。
第 ⑧ 步和投影完全无关（`O` 只读，`N` 是门禁），随便什么时候跑。

### 1.4 当前验证状态（2026-09-27，投影部分全部实测通过 ✅）

| 环节 | 状态 | 实测数据 |
|---|---|---|
| 启动 / 热键绑定 | ✅ | 全部成功 |
| `N` 能力探测 第 1–27 步 | ✅ | 全通过（第 28 步 `PrintString` **崩游戏**，已永久移除，见 4.5） |
| `Y` 采集 | ✅ | 主基地 **371 件 / 72 类型 / 3 层** |
| **网格解析** | ✅ | **直接命中 64 / 覆盖表 8 / 名字匹配 0 / 未解析 0** |
| `J` 蓝图库切换 | ✅ | 多张循环 |
| `K` 投影放置 | ✅ | 355 件实例 |
| 方向键 + `F9` 三模式微调 | ✅ | 移动 / 旋转 / 材质 |
| `L` 分层展示 | ✅ | 实测 3 层（350 / 14 / 7） |
| 投影材质 | ✅ | 默认蓝色 `building`（4 档循环 + 4 档备用） |
| 骨骼网格建筑 | ✅ | 后期工厂 / 磨石 / 碎冰机 / 钻油机 / 古代发电机 |
| 多网格建筑 | ✅ | 简约门（3 件）、帕鲁装扮机（2 件） |
| **朝向正确性** | ✅ | 矿车方向已修（组件索引方案） |
| **网格映射** | ✅ | **80 条，与游戏自报数据零冲突** |
| **屏幕提示（策略层 + 控制台通道）** | ✅ **实测通过（2026-09-27）** | 一次游玩生成 **12 条** `> ` 提示（采集/加载/放置/换层/模式…），见 `pwpr.log` |
| 按键表单一来源 | ✅ **实测通过** | `F7` 的表由 `Notify.KEYS` 生成（待办 5 的一半） |
| `O` 屏幕提示通道探测（S9） | 🟡 **第 1 步通过；第 2 步曾崩，已修待重跑** | 第 1 步拿到真实控制器 `BP_PalPlayerController_C`；第 2 步（反射枚举）崩游戏 → **该接口已永久禁用并做成检查项**，见 4.6 |
| 屏幕提示（游戏内中文） | ⬜ **还没做** | 两条路：① `GraphicsAPI = dx11` 让调试窗口盖在游戏上（**今天就能用**）② 先按 `O` 探测出可用的游戏内通道 |

**最后修掉的两个 bug（2026-09-27 凌晨）**：

1. **朝向读不到** —— `obj.Mesh` 返回的是 UE4SS 的 `TrivialObject`（假对象），
   `unwrap` 也救不回来。改成**从世界里枚举组件建「宿主 Actor → 组件」索引**，
   采集时按名字取。副作用是 61 种类型的**网格名也一起读出来了**
   （`直接命中` 从 11 涨到 64）。
2. **多网格被压掉** —— 上面那个修复让"actor 优先"开始压掉映射表，
   而 actor 只给**一个**组件，于是简约门只剩门框、装扮机只剩底座。
   已加规则：**映射表里写数组的（人工确认过的完整构成）优先于 actor 单件**。

投影渲染需要的每个引擎原语都已实测可用：`World:SpawnActor` 造宿主 Actor、
`AddComponentByClass` 造组件、`SetStaticMesh` / `SetSkeletalMesh` /
`SetMaterial`、`K2_SetRelativeTransform`、`AddInstance(tf, false)`（局部空间）、
`ClearInstances`、`K2_DestroyActor`。完整记录见游戏目录下的 `Scripts\pwpr_probe.txt`。

### 1.5 卸载 / 回滚 / 临时停用

**三种力度，按需要选**（都要先**完全退出游戏**）：

| 你想做的事 | 命令 | 效果 |
|---|---|---|
| **临时停用**（崩溃归因用） | `deploy.ps1 -Disable` | **只把 `mods.txt` 里的 1 改成 0**，不动任何文件。再跑一次 `deploy.ps1` 就恢复 |
| **完全卸载** | `deploy.ps1 -Rollback` | 从 `mods.txt` 移除条目 + **删掉** `Mods\PWProjection\` 整个目录 |
| 先看会改什么 | `deploy.ps1 -DryRun` | 只打印，不落盘 |

```powershell
# 完全退出游戏后
powershell -ExecutionPolicy Bypass -File deploy.ps1 -Disable    # 临时停用
powershell -ExecutionPolicy Bypass -File deploy.ps1 -Rollback   # 完全卸载
```

> **卸载不会动存档。** 这个 mod 只在内存里生成投影用的临时 Actor，
> 收起投影（`K`）时就已销毁，**从不写入存档**。
> 卸载后残留的只有 `Mods\PWProjection\` 里的日志和蓝图 JSON ——
> `-Rollback` 会连目录一起删掉。

**手动卸载**（不想用脚本时）：

1. 删除 `<游戏>\Mods\NativeMods\UE4SS\Mods\PWProjection\` 整个目录
2. 编辑 `<游戏>\Mods\NativeMods\UE4SS\Mods\mods.txt`，删掉 `PWProjection : 1` 那一行
3. 完事 —— 没有别的残留（不改 pak、不改存档、不改 UE4SS 本体）

> **为什么可以放心删**：mod 是纯 UE4SS Lua，所有代码都在 `Mods\PWProjection\Scripts\`
> 下，配置和蓝图也在这个目录里。UE4SS 只按 `mods.txt` 加载，删了就不执行。

---

## 2. 按键

> ★★★ **2026-10-06 起，下面这些主键全部可以在 `Scripts\pwpr_keys.json` 里改**
> （**按键单独一个文件** —— 不存在会自动生成一份，11 个键都写着默认值）。
> **改完要重启游戏**（UE4SS 只在启动时注册按键；按 `F8` 只重载 `pwpr_config.json`、**不会**重绑）。
> **能写哪些键名** ⇒ 完整清单（165 个）见 **[`docs\按键列表.md`](../../docs/按键列表.md)**。
> `pwpr_config.json` 里的同名 `key_*` 仍然兼容（不推荐，启动时会提示搬过来）。
> 表里的键名是**默认值**；改了之后 `F7` 那张表会显示你**实际**的键。
>
> **本节和游戏里按 `F7` 看到的表**：说明文字来自 `pwpr_notify.lua` 的 `Notify.KEYS`，
> **键名**来自 `pwpr_keys.lua` 的 `Keys.ACTIONS`/`Keys.resolve()`（单一来源）。

### 一页速查

| 键 | 作用 |
|---|---|
| `F7` | 帮助 / 当前状态（**含当前材质档、方向键模式、屏幕提示通道**） |
| `F8` | 重载 `pwpr_config.json` |
| `F9` | **切换方向键模式**（`move` / `rotate` / `material`） |
| `Y` | 采集（**只有一个采集键**；半径见配置 `capture_radius_m`，设 `0` = 全部建筑） |
| `U` | ★ **投影对齐**（把**整个投影**挪到附近已有建筑上；叠图对比用。**不是**"建造吸附"） |
| `J` | 蓝图库：切下一张并加载 |
| `K` | 投影 放 / 收 |
| `L` | 投影 切换分层 |
| `H` | 投影 重新吸附到玩家位置（定位用：清掉偏移与旋转） |
| `U` | ★ **建筑吸附**（对齐用：把投影一步对齐到附近真实建筑；**放下投影 `K` 时会自动吸一次**；键名可在配置 `snap_key` 改，默认 `"U"`） |
| `N` | 渲染能力探测（第一次用投影前跑一次） |
| `O` | **屏幕提示通道探测**（想知道能不能在游戏里显示文字就跑它，见 4.6） |
| `↑↓←→` | **看当前模式**（见下表） |

| 模式 | `←` | `→` | `↑` | `↓` |
|---|---|---|---|---|
| **`move`**（默认） | 左 | 右 | 前 | 后 |
| **`rotate`** | 逆时针 15° | 顺时针 15° | 抬高 | 降低 |
| **`material`** | 上一种材质 | 下一种材质 | 换分层 | 换步长 |

---

### 主键（都是实测空着的键）

| 键 | 作用 |
|---|---|
| `F7` | 帮助 / 当前状态（会写进日志） |
| `F8` | **重载 `pwpr_config.json`**（改完配置不用重启游戏） |
| `Y` | 采集（半径见配置 `capture_radius_m`，默认 150 米；设 `0` = 采集全部建筑） |
| `U` | 投影对齐（把整个投影挪到附近已有建筑上；叠图对比用。**不是**"建造吸附"） |
| `J` | 蓝图库：切到下一张并加载 |
| `K` | 投影：**放 / 收**（收 = 彻底销毁宿主对象，不留残留） |
| `L` | 投影：**切分层**（全部层 → 第 0 层 → 第 1 层 → … → 全部层） |
| `H` | 投影：重新吸附到玩家当前位置（清掉偏移与旋转） |
| `NUM 7` | ★ **投影：建筑吸附** —— 把投影一步对齐到附近的真实建筑（改键: 配置 `snap_key`，默认 `"NUM_SEVEN"`，改完重启游戏） |
| `N` | 渲染能力探测（S3）—— 第一次用投影前必须跑一次 |
| `O` | 屏幕提示通道探测（S9）—— 查"能不能在游戏画面上显示文字"，结果写 `pwpr_ui.txt`（见 4.6） |

### 放置微调 —— **方向键 + 模式**（不需要任何修饰键组合）

> **为什么不用 `Shift+` / `Alt+` / `Ctrl+` 组合**（实测结论）：
> **UE4SS 的按键绑定不看修饰键** —— `RegisterKeyBindAsync(key, {}, fn)`
> 的语义就是"不检查修饰键"，所以 `Alt+↑` 会**同时**触发 `Alt+↑` 和 `↑`
> 两个回调，一次按键做了两件事（"Alt+方向键的同时也会移动或者旋转"）。
> 另外 `Ctrl` 是游戏自己的闪避键、`Shift` 是冲刺键，按住都会附带动作。
>
> 所以改成：**只有 5 个键**，方向键的含义由当前模式决定。

| 键 | 作用 |
|---|---|
| **`F9`** | **切换方向键模式**（`move` → `rotate` → `material` → `move`） |
| 其余全看模式 ↓ | |

| 模式 | `←` | `→` | `↑` | `↓` |
|---|---|---|---|---|
| **`move`**（默认） | 往左 | 往右 | 往前 | 往后 |
| **`rotate`** | 逆时针 15° | 顺时针 15° | 抬高 | 降低 |
| **`material`** | 换材质 | 换材质 | 换分层 | 换步长 |

- `move` / `rotate` 模式的平移是**沿你面朝的方向**
- 当前模式：按 `F9` 时日志会写一行，控制台也会打 `arrow mode = xxx`；
  按 `F7` 随时可看
- 换模式**不会**影响投影，只是改变方向键的含义

<details>
<summary>有小键盘的话，下面这套也仍然可用（和小键盘上的方块方向一致）</summary>

| 键 | 作用 |
|---|---|
| `NUM_8` / `NUM_2` | 前 / 后 |
| `NUM_4` / `NUM_6` | 左 / 右 |
| `NUM_9` / `NUM_3` | 抬高 / 降低 |
| `ADD` / `SUBTRACT` | 逆时针 / 顺时针旋转 |
| `NUM_5` | 清偏移与旋转 |
| **`NUM_7`** | ★ **建筑吸附**（= 主键 `U`；**没有小键盘的键盘按 `U`**） |
| `NUM_0` | 换步长 |
| **`NUM_1`** | ★ **紧急收回屏幕提示控件**（万一"菜单点不动"，按它，见 4.6 安全须知） |
| `*` | 换投影材质 |

</details>

### 投影材质对照表（4 档循环 + 4 档备用）

**怎么切**：按 `F9` 让方向键进入 `material` 模式 → 用 `←` / `→` 循环 → 选定后
**自动写回配置**，重启仍然生效。

| 顺序 | 模式名 | 观感 | 材质资产 | 怎么选 |
|---|---|---|---|---|
| **1（默认）** | **`building`** | **蓝色** | `MI_LooksPredicatorBuilding` | 默认就是它；或 `F9` 后按 `←`/`→` 转回来 |
| 2 | `error` | 红色 | `BuildingSurfaceMaterialSet.Error` | `F9` 进 material，按 `→` |
| 3 | `dismantle` | 黄色（建造即将完成） | `MI_LooksPredicatorDismantle` | `F9` 进 material，按 `→` |
| 4 | `original` | 原始彩色（不覆盖材质） | 网格自带材质 | `F9` 进 material，按 `→` |

**另外 4 档不在循环里**，但把名字写进 `pwpr_config.json` 的 `ghost_material`
再按 `F8` 就能用：

| 模式名 | 观感 | 材质资产 |
|---|---|---|
| `highlight` | 灰白格子 | `MI_LooksPredicatorNormal` |
| `building2` | 蓝色，双面渲染（薄墙更好看） | `MI_LooksPredicatorBuilding_TwoSided` |
| `complete` | 建造完成态 | `MI_BuildObjectComplete` |
| `beforefix` | 修复前态 | `MI_LooksPredicatorBeforeFix` |

> 这 8 个都不是猜的 —— 来自**游戏自己导出的材质清单**
> （`pwpr_meshes.txt` 第 4 节，按 `Y` 采集时重新导出，
> 那份清单共列出 15 个建筑相关材质）。

**怎么知道自己现在用的是哪档**：按 `F9` 时控制台会打一行纯 ASCII 的
`[PWPR] material = building  [BLUE   (default)]`（可读，不是 `?`）；
按 `F7` 也会列出当前档和完整候选表。

也可以直接改配置里的 `ghost_material`，然后按 `F8`（或按 `F9` 让方向键进入
`material` 模式，再用 `←` / `→` 换）。
**换材质会自动写回配置**，所以选定后重启游戏仍然生效。

> **关于蓝色**：4 种旧候选里确实没有蓝色。但**导出真实材质清单后发现了新候选** ——
> `MI_LooksPredicatorBuilding` 和玩家看到的 `Normal` 是两个不同材质，
> 现在已加进候选（按 `F9` 进 material 模式，用 `→` 翻到 `building` 试试）。
> 另外还有 `_TwoSided` 版本（薄墙双面渲染）和 `MI_BuildObjectComplete`。

---

## 3. 文件位置

### 3.1 模组本体：15 个文件，全部必需

`deploy.ps1` 会把这 **24** 个文件复制到游戏目录。它们**互相依赖，少一个就起不来**
（缺哪个，日志里会直接写 `require 失败: <名字>`）。

> ★★ **其中 2 个是第三方文件**（`PalModOptionsClient.lua`、`pmo_json.lua`）——
> 来自 **Mod Options Framework**（作者 Elv，**MIT**），用于"Esc → 模组选项"里的
> **游戏内设置面板 / 改键**。出处与许可证见 **`third_party\README.md`** ✓
> **框架本体没装也完全不影响本模组**（会自动退回 `pwpr_keys.json` + `pwpr_config.json`）✓

| 文件 | 作用 | 被谁依赖 |
|---|---|---|
| **`main.lua`** | 入口：按键绑定、流程编排 | 游戏加载它 |
| **`pwpr_unipal.lua`**（★ 2026-10-06 新增）| **UniPalUI 接入探针**（待办 5 方案②）: 阶段 A **只读**探测（类/实例/API 函数与参数个数）；阶段 B 可选用配置打开。**可选依赖，没装 UniPalUI 也完全正常** | 被 `main.lua`（启动后 2.5s 延迟跑 + `F7`）引用 |
| **`pwpr_keys.lua`**（★ 2026-10-06 新增）| **按键绑定**：配置 → 生效键名的解析/校验（`Keys.ACTIONS` 是动作的**单一来源**）+ 提示文本的键名翻译 | 被 `main.lua`（绑定/`F7`）与 `pwpr_notify.lua`（按键表）引用 |
| `pwpr_util.lua` | 基础设施：对象读取、变换、路径 | 被 10 处引用（最底层） |
| `pwpr_json.lua` | 手写 JSON 编解码 | 被 4 处引用 |
| `pwpr_log.lua` | 日志（UTF-8，中文正常） | 被 4 处引用 |
| `pwpr_config.lua` | 配置读写 + 默认值迁移 | 被 6 处引用 |
| `pwpr_sched.lua` | 游戏主线程调度 | 被 2 处引用 |
| **`pwpr_hud.lua`** | **屏幕文字【通道层】**：把一行字送到画面上。**只调用探测验证过的通道**（见 4.6） | 被 3 处引用 |
| **`pwpr_notify.lua`** | **屏幕提示【策略层】**：什么时候提示、提示什么、节流。**纯 Lua，不碰引擎**。也是按键表的**单一来源**（见 2.0） | 被 2 处引用 |
| `pwpr_bp.lua` | 蓝图数据模型：包围盒、相对坐标、分层 | 被 5 处引用 |
| `pwpr_capture.lua` | 扫描建筑 → 生成蓝图（`Y` / `U`） | `main` |
| `pwpr_library.lua` | 蓝图库（`J` 切换） | `main` |
| `pwpr_meshmap.lua` | 类型 → 网格资产解析 | 被 3 处引用 |
| `pwpr_ghost.lua` | 投影渲染（`K` / 微调 / 材质 / 分层） | `main` |
| `pwpr_session.lua` | 当前会话状态 | `main` |
| `pwpr_probe.lua` | 渲染能力探测（`N`）+ 屏幕提示通道探测（`O`）→ 生成门禁依据 | 被 2 处引用 |
| `pwpr_meshmap.default.json` | **内置映射表 80 条**（部署时被覆盖成最新） | `pwpr_meshmap.lua` |

**另外三个不复制进游戏目录的**：

| 文件 | 作用 |
|---|---|
| `deploy.ps1` | 部署/回滚/停用脚本（留在工作区） |
| `README.md` | 本文档（主手册） |
| **`已知限制.md`** | ★ **画不出来 / 只画出一部分 / 看起来一样但其实正常** 的建筑清单。**发现新问题就往这里加一行** |

**一个例外**：`pwpr_meshmap.json`（用户自己的映射表）**不在部署清单里**，
它由脚本在游戏目录**按需创建一次**，之后部署**绝不覆盖** —— 你手写的条目永远不会丢。

### 3.2 运行时输出

部署之后，所有输出都在：

```
<游戏>\Mods\NativeMods\UE4SS\Mods\PWProjection\Scripts\
    pwpr_config.json          配置（中文注释版在本文档第 5 节）
    pwpr.log                  运行日志（UTF-8，中文正常）
                              以 "> " 开头的那行 = 玩家当时在屏幕上看到的那一行
    pwpr_probe.txt            渲染能力探测（N）逐步骤记录
    pwpr_ui.txt               ★ 屏幕提示通道探测（O）报告：函数名 + 参数签名 + 类名枚举
    pwpr_capabilities.json    渲染能力探测结论（投影的门禁依据；O 绝不写这个文件）
    pwpr_meshes.txt           静态网格注册表 + 每个类型的匹配结果
    pwpr_meshmap.default.json 内置映射表（**80 条**，每次部署都会更新成最新）
    pwpr_meshmap.json         你自己的映射表（**部署时绝不覆盖**，优先级更高）
                              特殊值 `"-"` 表示"这个类型不要画"

<游戏>\Mods\NativeMods\UE4SS\Mods\PWProjection\blueprints\
    index.txt                 蓝图索引
    base_-1041_417.blueprint.json    采集出来的蓝图
    all_....blueprint.json
```

控制台输出在 `<游戏>\Mods\NativeMods\UE4SS\UE4SS.log`。

> 控制台只吃 ASCII，中文会变 `????`。**要看中文请打开 `pwpr.log`。**

---

## 4. 安全设计（为什么这个 mod 崩不了游戏）

这个项目在早期崩过 **3 次**游戏，所以架构是围绕"不许再崩"设计的。

### 4.1 分阶段激活

| 阶段 | 内容 | 风险 |
|---|---|---|
| **S0 加载** | 读配置、注册热键 | 不碰引擎 |
| **S1 采集** | `FindAllOf` + 读坐标/朝向 | **只读**，全是长期验证过的调用 |
| **S2 蓝图库** | 纯 Lua 文件读写 | 无 |
| **S3 探测** | 逐项验证渲染原语 | 前 16 步只读，之后才创建对象 |
| **S4 投影** | 唯一会创建引擎对象的功能 | **双重门禁** |

### 4.2 S4 的双重门禁

`pwpr_ghost` 只有在**两个条件同时满足**时才会执行任何创建操作：

1. `pwpr_config.json` 里 `ghost_enabled = true`（默认 `false`）
2. `pwpr_capabilities.json` 里 `spawn_host` / `add_ism_component` /
   `set_static_mesh` / `add_instance` / `get_world` 全部为 `ok: true`

**"没探测过就渲染"在结构上不可能发生。**

### 4.3 其它硬规则

| 规则 | 原因 |
|---|---|
| 所有引擎属性读取都过 `pcall` | 读不存在的属性会返回"占位对象"而不是 nil |
| 判定对象有效优先用"能不能调通 `GetFullName`" | **实测教训**：`IsValid()` 在建筑组件/网格资产上会把好对象误判为无效，导致网格覆盖率从 26/79 掉到 4/35 |
| 绝不写 `pcall(StaticFindObject, "路径")` | 这个写法实测触发过原生层崩溃，必须用闭包形式 |
| 所有热键回调外面套 `pcall` | 保证 Lua 错误不会跑出去 |
| 改引擎的操作走 `ExecuteInGameThread` | 不在游戏线程上创建对象 = 和引擎抢资源 |
| 换地图时**只丢引用，不碰引擎** | 在世界重载窗口去 `DestroyActor` 旧对象 = 访问违例 |
| `K` 收起时彻底销毁宿主 | 不在存档里留下残留 actor |
| **绝不调用 `PrintString`** | 实测会崩游戏，见 4.5 |

### 4.4 崩溃点定位：探测每一步都先落盘

能力探测每一步**执行前**先把 `STEP n START` 写进 `pwpr_probe.txt`。

> 如果游戏崩了，文件里**最后一条 START 就是崩溃点** —— 没有歧义。

**2026-09-26 18:15 正是靠它一次定位到崩溃点**：文件里 1–27 步全有结果，
第 28 步只有 START 没有结果 → 第 28 步就是崩溃点。

而且能力表现在**每一步之后**都会写一次 `pwpr_capabilities.json` ——
之前是全部跑完才写，结果第 28 步一崩，27 步的成果全丢了，白测一轮。

用 `probe_max_step`（配置项）可以只跑到第 N 步就停；
即使中途停下，只要已经创建过宿主，**销毁步骤仍然会补跑**。

### 4.5 为什么 `PrintString` 被永久禁用

Palworld 是 Shipping 构建，UE 把 `KismetSystemLibrary::PrintString` 里
"画到屏幕上"那一段用 `#if !(UE_BUILD_SHIPPING || UE_BUILD_TEST)` 编译掉了。
函数体没了、但反射信息还在，UE4SS 按反射去调 → 参数栈对不上 → **访问违例**。

这不是"可能不行"，是**实测必崩**（2026-09-26 18:15 第 28 步）。

**这条禁令只针对 `PrintString`（以及 `DrawDebug*` 那类同样被编译掉的函数），
不代表"屏幕上不能显示文字"。** 别的通道见 4.6 —— 但纪律不变：
**未经验证的引擎调用，绝不许进渲染路径。**

### 4.6 ★ 屏幕提示（待办 1）—— ✅ **已完成，实机可用**（2026-09-28 更新）

**要的效果**：采集 / 加载蓝图 / 放投影 / 切模式 / 切分层 ——
每次操作后**屏幕上一行中文**，不用去翻日志。

> ### ★ 现状（一句话）
>
> **游戏内左上角会显示一行中文提示，约 10 秒自动消失。** ✅
>
> 做法：复制一个游戏自带的**独立浮层**控件（默认 `WBP_Warning_LowMemory_C`，
> 就是玩家熟悉的"内存警告条"）→ `CreateWidget` → `AddToPlayerScreen(50)`
> → 写它里面的 `Text_Warning` → 到时间收起。
>
> * **完整说明（架构 / 配置项 / 排查手册 / 已知问题 / 时间线）见
>   [`docs\屏幕提示功能.md`](../../docs/屏幕提示功能.md)`** —— 那一份是权威文档。
> * 控制台通道仍然保留：它是**零风险兜底**（`notify_own_widget=false` 时只走它）。
>
> ⚠️ **一个已知未修**（详情见上面那份文档第八节）：
> "回标题 → 重进世界"后第一次操作可能闪退（上个世界的废对象 + `IsValid()` 撒谎）。
> 修它用的"世代守卫"因标记不稳定曾把正常**放置**搞坏（"0 件"），
> 现已做成开关 `world_guard_enabled` 并**默认关闭** ⇒ 功能恢复稳定。
> **绕法**：回标题后重启游戏；或 `notify_own_widget = false`。

#### 分层设计（为什么要拆成两个文件）

| 文件 | 层 | 职责 | 碰引擎吗 |
|---|---|---|---|
| `pwpr_notify.lua` | 策略层 | 提示什么、什么时候提示、节流、按键表 | **不碰**（纯 Lua） |
| `pwpr_hud.lua` | 通道层 | 把一行字真的送到画面上 | 只在探测通过后碰 |

`pwpr_hud.lua` 里**没有任何"偷偷试一下"的调用**：
非控制台通道必须**在本次会话里探测通过**才允许发送，
否则直接退回控制台。所以"屏幕提示"这个功能本身**不可能把游戏搞崩**。

#### 四条通道

| 通道 | 风险 | 默认 | 说明 |
|---|---|---|---|
| `console` | **零** | **开** | 就是 `print`，写进 UE4SS 调试窗口。永远可用，兜底 |
| **`notice_text`** | 中 | **开** | ★ **游戏内中文靠它**：`Create` 一个 Palworld 通知控件 + `AddToViewport`，再往它的 `TextBlock` 写 `FText("中文")` |
| `client_message` | 中 | 关 | `PlayerController:ClientMessage(文本, 类型, 秒)`，UE 标准接口（**显示位置存疑**） |
| `named_call` | 高 | 关 | 调用探测里发现的函数（名字填配置 `notify_func`），**只给 1 个字符串参数** |

> ### 🔴 安全须知：我们的提示控件是"浮层"，出过事故
>
> 2026-09-27 出过一次严重问题：自建提示控件用了 `SetVisibility(0)`（= **吃输入**），
> 又挂在 z-order 1000、铺满屏幕 —— 结果把游戏 `Esc` 菜单的**鼠标点击全吃掉**，
> 连"返回标题"都点不了，只能 `Alt+F4`。
>
> **已修**：浮层一律用 `SetVisibility(3)`（`HitTestInvisible` = **渲染但不吃输入**）
> + `SetIsFocusable(false)`。
>
> **两个逃生出口**（万一以后又出现"菜单点不动"）：
>
> | 做法 | 效果 |
> |---|---|
> | **小键盘 `1`** | ★ **立即收回提示控件**（从视口移除） |
> | 配置改 `notify_try_notice_text: false`（或 `notify_own_widget: false`）→ 按 `F8` | 自动收回，并从此不再创建 |
> | `Alt+F4` → 重进游戏 | 一定有效（浮层不写存档） |
>
> 详见 `docs\踩坑记录.md` 第 19-8 节。

> ### 🔴 `notice_text` 第一版为什么"成功但看不见"（值得记住）
>
> 第一版是**借用**游戏现有的 `WBP_Notice` 控件：按名字过滤出 `TextBlock` 再 `SetText`。
> 结果探测报告写着 **`已发=8 失败=0`**，可屏幕上**一个字都没有**。
>
> **错因：挑中的是 CDO（类默认对象）里的设计期控件，它根本不在画面上。**
> 两种全名长得完全不一样：
>
> | | 全名形态 | 在画面上吗 |
> |---|---|---|
> | CDO / 设计期控件 | `/Game/Pal/Blueprint/UI/.../WBP_Notice.WBP_Notice_C:WidgetTree.BP_PalTextBlock_C_84` | ❌ |
> | 活实例 | `/Engine/Transient.PalGameEngine_...:...WBP_PlayerUI_C_2147443706.WidgetTree_2147443705...Text_MaxHP` | ✅ |
>
> `SetText` 在 CDO 上**不会报错**（它是合法对象），但它**永远不可能显示**。
> 而 Palworld 平时**根本没有活的 `WBP_Notice` 实例** —— 只在要弹通知那一刻才创建。
>
> **修法**：① 只认 `/Engine/Transient` 下的**活实例**（`Hud.is_live`）；
> ② **不借游戏的了，自己造一个**（`Create` + `AddToViewport`，
> 等价于蓝图里的 "Create Widget" + "Add to Viewport"），`hud_seconds` 秒后自动收起。
> 详见 `docs\踩坑记录.md` 第 19 节。

> **为什么 `notice_text` 是"中"不是"高"**：它用的 `SetText` / `SetVisibility`
> 都是 **UMG 标准函数、参数个数公开已知**，而且本机 `FirstPerson`
> 实机就在直接调用 `SetText`（它只有 **hook** 才崩，直接调用没事）。
> 真正"高"风险的是**参数个数未知**的调用（`PrintString` 就是这么崩的）。
> 所以它**默认开**；万一改了不该改的文本，把 `notify_try_notice_text` 改成 `false` 即可。

高风险通道必须**在配置里显式打开**才允许被探测/调用：

| 配置 | 默认 | 作用 |
|---|---|---|
| `notify_try_notice_text` | **`true`** | 允许往 Palworld 的通知控件写文字（游戏内中文） |
| `notify_textblock_filter` | `"WBP_Notice"` | 挑哪个 `TextBlock`：**控件全名里包含这个字符串**的 |
| `notify_try_client_message` | `false` | 允许尝试 `ClientMessage` |
| `notify_allow_named_1arg` | `false` | 允许尝试 `notify_func` 指定的函数 |

> **不用每次重启后按 `O`**：第一次要发提示时，程序会**自动把探测排到游戏线程**
> （`Hud.request_probe`），这一次先用控制台，下一次起就走游戏内通道。
> `O` 仍然保留 —— 它是**诊断**用的，用来把结果写成文件。

#### ★ 怎么找到可用通道：按 `O`（S9 探测）

**文档里查不到**（`pwmodding.wiki` 的 Palworld Modding Kit / UE4SS 分类
**只有安装与配置指南，没有任何游戏内 UI / 通知的 API 参考**），所以只能实测。

> ### 🔴 先说一个已经踩过的坑：**反射枚举在这个构建里会把游戏打崩**
>
> 按 `O` 的第一版第 2 步做了"枚举 `PlayerController` 的函数名和参数签名"
> （`obj:ForEachFunction` + `obj:ForEachProperty`）——
> **一点就崩**（2026-09-27 16:19，崩溃栈 80 帧全在 UE4SS 里）。
>
> 更该批评的是：**本项目的 `docs\踩坑记录.md` 早就记过两次**
> （3c-3「属性枚举仍然失败」、3f-2「`ForEachProperty` 确认不可用」），
> 而我当时只凭"`UE4SS.dll` 里能扫到 `ForEachFunction` 这个字符串"
> 就以为能用 —— **"反射信息存在" ≠ "Lua 能安全调用"**，
> `PrintString` 也是同一个模式（函数体被 Shipping 编译掉，反射还在）。
>
> **现已永久禁用**，并且做成了检查项：
> `luacheck.py` 第 **11** 项会直接拦下 `ForEachProperty` / `ForEachFunction` /
> `ForEachUObject`（自检里配了正反样例）。
> 安全替代是**本项目用了几个月的**两种操作：
> **`FindAllOf("精确类名")`** 和 **`obj.方法名` 存在性查询**。

按 `O` 会跑一段探测（7 步），把结果写进 `pwpr_ui.txt`。
**步骤顺序 = 风险从低到高**（以前把最危险的放在第 2 步，结果后面全没跑到）：

| 步 | 干什么 | 风险 |
|---|---|---|
| `s9_player_controller` | 拿到本地 `PlayerController` | 零 |
| `s9_ftext` | 验证 `FText` 构造（ASCII + **中文**）+ 回读 | 零 |
| `s9_widgetlib` | UMG 函数库 CDO 在不在（自己也造提示控件才需要） | 零 |
| `s9_candidates` | ★ **候选名单存在性检查**：方法名 + 类名"存不存在/有几个"（含对照组） | 零 |
| `s9_notice_widget` | ★ 展开 Palworld 通知控件的**控件树**，找出那个 TextBlock 叫什么 | **最高**（边查边写盘） |
| `s9_channels` | 逐通道探测"有没有"，**不发任何文字**（会先自动重读配置） | 零 |
| `s9_send_test` | ★ 唯一会真的发字的步骤 | 高 → **只在开了高风险通道时才执行** |

> **按 `O` 会自动重读 `pwpr_config.json`** —— 不用先按 `F8` 了。
> （2026-09-27 实测踩到：改了配置直接按 `O`，探测里那条通道仍显示"默认关"。）

**`s9_candidates` 里的"候选名单"不是瞎猜**：

| 来源 | 内容 |
|---|---|
| 本机 `FirstPerson`（实机在用） | 拿控制器用 `FindFirstOf("BP_PalPlayerController_C")`；Palworld 的 UI 是蓝图控件，命名形如 `WBP_Graphic_Settings.WBP_Graphic_Settings_C`；文本控件属性形如 `BP_PalTextBlock_Name` |
| UE 官方 API 名 | `ClientMessage` / `AddOnScreenDebugMessage` … |

名单里带了**对照组**：`GetControlRotation` / `GetPawn` / `GetWorld`
（这些我们已经在用，一定可调用）。**对照组判读规则**：
如果它们都不是 `function` → 说明"方法名查询"这条路本身有问题，
此时所有"没有/占位"**都不可信** —— 别把工具的问题当成游戏的事实。

**方法论（这一节最重要的部分）**：**先确认存在，再调用。**
参数个数和类型没看清之前，**绝不去调那个函数** —— `PrintString` 就是这么崩的。

#### ★ 2026-09-27 实测结论（`O` 跑了两次，全部有据可查）

| 结论 | 证据 |
|---|---|
| ✅ **`FText` 中文完全可用** | `ASCII 构造: OK 回读 PWPR-TEST` / `中文构造: OK **回读: 蓝图投影**` —— 中文进得去也读得回来 |
| ✅ **UMG 库可用** | `/Script/UMG.Default__WidgetBlueprintLibrary: 可用`，`lib:Create 存在` |
| ✅ **`FindAllOf` 能查到 UMG 控件** | `WBP_Notice_C` → **1 个实例**，资产在 `/Game/Pal/Blueprint/UI/UserInterface/InGame/Notice/WBP_Notice` |
| ✓ **通知系统叫 `Notice`** | 就是本节 `notice_text` 通道的目标 |
| ⚠️ **我一度误判：`type=userdata` ≠ "方法不存在"** | 对照组 `GetControlRotation`（**每帧都在用**）也是 `type=userdata`！所以 `userdata` 既可能是真方法也可能是占位对象，**`type()` 分辨不出来**。详见 `docs\踩坑记录.md` 第 18 节 |
| ⚠️ `FindAllOf` 无匹配时**返回 nil**（不是空表） | 第一版把它误报成"查询失败" —— 已修 |
| ⚠️ UMG 控件**按需创建** | 设置页那几个 `WBP_*_Settings_C` 平时查不到 ⇒ **对照组必须是"此刻一定在"的东西** |
| ⚠️ `WidgetTree.AllWidgets` 读不通 | `GetArrayNum()` 失败。已改成**同时试 4 种读法**并报告哪种能用；另加一条更直接的路：`FindAllOf("TextBlock")` |

**判定方法的原则（这一节最重要的教训）**：
**判据不能写死，要用"已知能用的东西"当基准反推。**
两次实测分别推翻了"返回 nil"和"userdata 就是占位"两个想当然的判据 ——
所以现在 `s9_candidates` 会先量 `GetControlRotation` 等对照组，
用它们的信号**定标**，再拿这个标准去判候选。对照组不通过时，
报告会直接写"**结论本身就不可信**"，而不是硬给一个答案。

**由此得到的路线（游戏内中文提示怎么走）**：
Palworld 自己的通知系统叫 **`Notice`**，资产在
`/Game/Pal/Blueprint/UI/UserInterface/InGame/Notice/WBP_Notice`
（探测确认活着 1 个实例）。所以 `notice_text` 通道干的事就是：
`FindAllOf("TextBlock")` → 挑全名里带 `WBP_Notice` 的那个 →
`SetText(FText("中文"))` → 顺手 `SetVisibility(0)` 让通知控件显示。
**`FText` 中文已经被证明是通的**，所以缺的只是"挑对控件 + 让它可见"。

#### 这些结论的证据在哪（都不是猜的）

| 结论 | 证据（本机文件，可直接打开核对） |
|---|---|
| `FText("中文")` 能用 | `Mods\FirstPerson\Scripts\main.lua` 里 `TextBlock:SetText(FText("第一人称"))`，实机在用 |
| 反射枚举可用（`ForEachFunction` / `ForEachProperty` / `GetSuperStruct`） | `Mods\ConsoleCommandsMod\Scripts\dump_object.lua`（UE4SS 官方命令）用的就是这套；`UE4SS.dll` 字符串扫描也能扫到这些名字 |
| UMG 静态库这样拿 | `StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")` |
| ★ **`hook TextBlock:SetText` 会崩游戏** | `FirstPerson` 的注释里记了两次崩溃 dump，它因此**删掉了那个 hook**。但**直接调用 `SetText` 是正常的**（它现在就在用） |

> ⚠️ **本 mod 永远不 hook UI。** 区别是：hook = 游戏每次调用都进我们的代码
> （包括控件正在销毁的那一刻）；直接调用 = 我们自己发起、对象由我们挑。

#### ★★ 想让文字出现在**游戏画面上**：改 UE4SS 的一个设置（**今天就能用，零风险**）

> **这是目前唯一"确定可行"的屏幕文字方案。**
> 它不需要碰游戏自己的 UI，也不需要探测 —— 因为我们所有的 `print`
> 本来就写进了 UE4SS 的调试窗口，**只是那个窗口没盖在游戏上**。

本机 `UE4SS-settings.ini` 里是：

```ini
GraphicsAPI = opengl     ; 默认值
```

`opengl` 后端会把调试 GUI 渲染到**独立窗口**（`imgui.ini` 里的 `Backend_Window`），
**不会盖在游戏画面上** —— 所以你会觉得"我得去翻日志"。

```ini
; 有效值（不区分大小写）: dx11, d3d11, opengl
GraphicsAPI = dx11
```

改成 `dx11` 后**重启游戏**，调试窗口才会盖在游戏上（前提：游戏本身跑 DX11；
如果游戏里选的是 DirectX 12，把它切回 DirectX 11）。
**这是设置项，不是本 mod 的代码问题**，改之前建议备份那个 ini。

#### 顺带解决待办 5 的一半：按键表现在只有一个来源

按键表在 `pwpr_notify.lua` 的 `Notify.KEYS` 里**只写一份**，
按 `F7` 看到的表就是从它生成的（以前帮助文案里手抄一份、
控制台又抄一份，加个键得改三处，迟早不一致）。
"能在游戏里看到按键表"这一半已经完成；**改键**（配置 `keybinds`）还没做。

> ⚠️ 改键功能**不要提供"修饰键组合"选项** —— UE4SS 的按键绑定不看修饰键，
> `Alt+↑` 会同时触发两个回调（这个 bug 玩家实测报过）。

---

## 5. 配置（`pwpr_config.json`）

| 键 | 默认 | 说明 |
|---|---|---|
| `capture_radius_m` | `150` | 按 `Y` 采集的半径（米） |
| `capture_max` | `6000` | 单次采集上限，防止把整个存档一次抓爆 |
| `layer_gap_cm` | `200` | 分层阈值：相邻 Z 差超过它就分新层 |
| `origin_snap_m` | `1.0` | 蓝图原点吸附到多少米的网格 |
| `blueprint_dir` | `""` | 留空 = `<mod>\blueprints` |
| `ghost_enabled` | **`false`** | **投影总开关**。探测通过后改成 `true` |
| `ghost_layer_mode` | `"all"` | `all` / `single` / `range` |
| `ghost_max_instances` | `6000` | 超过就拒绝渲染（保护帧率） |
| `nudge_step_cm` | `100` | 小键盘一次挪多少厘米 |
| `rotate_step_deg` | `15` | 一次转多少度 |
| `snap_enabled` | **`true`** | 投影对齐总开关（只读世界、只算偏移，和"投影渲染"不是一回事） |
| `snap_on_place` | **`false`** | 按 `K` 放下投影时要不要自动对齐到附近已有建筑。**默认关**（玩家的用法是"把投影放空地照着盖"） |
| `snap_radius_cm` | `2000` | 吸附的配对阈值（厘米）：投影里的一件与真实建筑差多远以内才算"可能是同一件"。**站得离基地中心越远，需要的值越大** |
| `snap_verify_cm` | `150` | 复核容差（厘米）：判定"真的对上了"的距离上限。应明显小于建筑间距 |
| `snap_min_matches` | `3` | 至少对上几件才接受这次吸附（不够就一动不动，只报原因） |
| `snap_yaw_search` | `true` | 吸附时是否同时自动找朝向（`false` = 只平移） |
| `snap_key` | `"U"` | 投影对齐的触发键（UE4SS `Key` 表里的名字）。默认字母键 `U`（**玩家的键盘是 84 配列，没有小键盘**）；改完**重启游戏** |
| `buildsnap_enabled` | **`true`** | ★ **建造吸附总开关**（放建筑时落到投影上）。**出问题先改成 `false`**（`F8` 即时生效） |
| `buildsnap_mode` | `"align"` | **目前只有 `align` 可用**（`blueprint` = 未完成/暂不可用，设了会告警） |
| `buildsnap_dry_run` | `false` | 建造吸附**干跑**: 只写日志、不改任何东西（第一次实测建议先开） |
| `ghost_resume_last` | `true` | 按蓝图记住"投影上次放在哪 + 已经建到哪"（**一张蓝图可存多处**）；重进游戏后按 K 沿用位置 + 把已建好的那批不画；`H` 移到脚下会**新开一处**（不覆盖旧记录），`U` 在多处之间切换 |
| `ghost_resume_margin_m` | `20` | 蓝图包围盒之外额外放宽的距离（米）。判定"还在不在原地"按**蓝图范围**，不是"离锚点多远" |
| `resume_save_interval_s` | `10` | 位置记忆的批量落盘间隔（秒）——不是每次放置都写文件 |
| （附）删记录 | `pwpr_placements.json` 存着所有「位置 + 进度」；**先关游戏**，然后用 `tools\resume_tool.py list / drop-site / drop-progress / drop-blueprint / drop-all` |
| `ghost_hide_enum` | `true` | 按 K/L 放投影时扫一遍，把**已经放过的件**标成不显示（实测稳定） |
| `ghost_hide_scan` | `false` | 周期性扫描"被拆掉了"⇒ 自动恢复。**默认关**（拆完建筑后读 pending-kill 对象会崩）；拆掉后按 K 重放投影即可 |
| `ghost_hide_placed` | `true` | **已经放上去的那一件，投影就不再画**（避免实物和蓝色投影重合时互相闪烁）；拆掉会自动恢复 |
| `ghost_hide_placed_cm` | `40` |
| `log_flush_interval_s` | `5` | 日志落盘间隔（秒）；`log_flush_lines`=200 攒够行数也落。放置路径上本来就不写盘 |
| `buildsnap_min_cm` | `5` | 差得比这还准就完全不插手（省掉"游戏侧做两遍活"） |
| `buildsnap_notify` | `false` | 放置时是否弹屏幕提示（默认不弹 —— 弹提示是卡顿主因） |
| `notify_trace` | `false` | 诊断: 记录发提示的每一步（会明显变慢） |
| `ghost_hide_scan_interval_s` | `15` | 拆掉恢复的兜底全扫间隔（秒） |
| `ghost_hide_placed_batch_s` | `3` | 放置批量窗口（秒）: 连放时只记录，停下来 3 秒后一次性从投影里去掉（省性能、不漏件）。`0` = 立刻处理 | 判断"这一件已经放上了"的距离（厘米） |
| `buildsnap_radius_cm` | `1000` | **align 模式**：摆到多近以内才吸（玩家实测认可的手感） |
| `buildsnap_snap_z` | `true` | 高度**跟投影走**（默认；地面建时高度不固定）。★ 吸不上会自动降级: 被游戏拒 ⇒ 这类只吸 x/y（再放一次即可）；卡死过 ⇒ 下次启动读日志尾部学会（见 `docs\踩坑记录.md` §68）。重置记忆 = 删掉/移走 `pwpr.log` |
| `buildsnap_skip_extra` | `true` | 请求带"附加参数"（特殊建造路径: 水面/特殊套组）⇒ **原样放行不吸附**（游戏照原样放，不会卡死）。同上事件的第二道闸 |
| `buildsnap_max_dist_cm` | `1500` | 目标离玩家超过这个距离就不吸、原样放行（防"请求太远被游戏拒"） |
| `buildsnap_aim_max_cm` | `3000` | **blueprint 模式**：准星前方多远以内参与选择 |
| `buildsnap_aim_cone_deg` | `12` | **blueprint 模式**：偏离准星多少度以内算"指着它" |
| `buildsnap_type_match` | `true` | **align 模式**：是否只吸同类型的记录（推荐） |
| `buildsnap_learn_max_cm` | `30` | 「学到映射」的距离门槛（厘米）——只有贴得极近才学；学错了会被自动丢掉（自愈） |
| `buildsnap_type_loose_cm` | `100` | **align 模式**：类型对不上时的**放宽阈值**（厘米，`0`=关）。实测：游戏 id `Wooden_foundation` vs 蓝图 `Wood_Foundation`（差一个 "en"），而最近那件只差 7~21 厘米 ⇒ 放宽 + **自动学到映射** |
| `buildsnap_rot_tol_deg` | `35` | **align 模式**：朝向差在容差内 ⇒ 连朝向一起吸；超过 ⇒ **只吸位置、保留你的朝向** |
| `ghost_material` | `"building"` | 投影材质：循环 4 档 `building`(蓝,默认) / `error`(红) / `dismantle`(黄) / `original`(彩色)；另可填 `highlight` / `building2` / `complete` / `beforefix` |
| `player_feet_offset_cm` | `0` | 玩家脚底相对 Actor 原点的距离。**`0` = 自动读胶囊体半高**；投影浮空或陷地就填具体数字（例如 `90`） |
| `hud_enabled` | **`true`** | **屏幕提示总开关**。兜底通道是控制台（零风险）所以默认开；不想看就改 `false` |
| `hud_seconds` | `4.0` | 游戏内提示文字显示多久（只有游戏内通道用得到） |
| `notify_channel` | `"auto"` | `auto` / `console` / `client_message` / `named_call`，强制指定走哪条通道 |
| `notify_min_interval` | `0.25` | 提示节流窗口（秒）。方向键/小键盘是按键重复速率触发的，不节流会刷屏 |
| `notify_try_client_message` | `false` | ⚠️ **高风险**：允许尝试 `ClientMessage`（先按 `O` 看结果再决定） |
| `notify_try_notice_text` | **`true`** | 允许往通知控件写中文（`notice_text` 通道，**游戏内中文靠它**） |
| `notify_own_widget` | **`true`** | `true` = **自己 Create 一个控件**来显示（推荐）；`false` = 借游戏现有的活控件 |
| `notify_widget_class_path` | `".../InGame/Notice/WBP_Notice.WBP_Notice_C"` | 自己造控件时用的类（拿不到活实例时用它 `LoadAsset`） |
| `notify_textblock_filter` | `"WBP_Notice"` | 借用路线的筛选：控件全名里包含这个字符串（**只匹配活实例**） |
| `notify_textblock_cache_s` | `5` | 文本控件扫描缓存（秒）。全场景 5000+ 个控件，不缓存会**每按一次卡一下** |
| `notify_autohide` | **`false`** | 自己的控件是否几秒后自动收起。**排查阶段保持 `false`** —— 免得"刚好错过那 4 秒"；确认能看见后再改 `true` |
| `notify_probe_grep` | `""` | ★ 按内容反查控件：把屏幕上看到的一段文字填进来，按 `O` 会回读所有活文本控件并**指出是哪个控件在显示它** |
| `notify_allow_named_1arg` | `false` | ⚠️ **高风险**：允许调用 `notify_func` 指定的函数（只给 1 个字符串参数） |
| `notify_func` | `""` | `notify_allow_named_1arg` 用的函数名，从 `pwpr_ui.txt` 里抄 |
| `probe_max_step` | `0` | 探测只跑到第 N 步（`0` = 全部跑） |
| `hook_load_map_pre` | **`false`** | 换地图时丢弃引用（见下） |
| `library_scan_on_refresh` | **`false`** | 是否用 `io.popen` 扫蓝图目录（见下） |

### 两个默认关闭的"启动期额外动作"

这两个开关是**崩溃复盘后特意加上的减法**（详见
[`docs/踩坑记录.md`](../../docs/踩坑记录.md) 第 11 节）：

| 开关 | 打开它会做什么 | 为什么默认关 |
|---|---|---|
| `hook_load_map_pre` | 注册 `RegisterLoadMapPreHook`，换地图时丢弃宿主/会话引用 | 世界加载期是全局最脆弱的时间窗；目前投影还没解锁，这钩子收益为零 |
| `library_scan_on_refresh` | 启动/刷新时 `io.popen("dir ...")` 列出蓝图目录 | 那等于**在游戏启动过程中 spawn 一个 cmd.exe**。索引文件由 `Library.save` 自动维护，不需要扫 |

> 手动拷进来的蓝图想被 `J` 循环到，往 `blueprints\index.txt` 加一行
> `文件名.blueprint.json|显示名` 即可；或者临时把 `library_scan_on_refresh` 改成 `true`
> 再按 `F8`。

改完配置按 **`F8`** 重载，不用重启游戏。

---

## 6. 崩了怎么办（崩溃归因流程）

**先别改代码，按这个顺序读日志。**

### 步骤 1：确认"我们的代码到底跑了没有"

看 `<游戏>\Mods\NativeMods\UE4SS\UE4SS.log`，搜 `[PWPR]`：

- 只有启动那段（`bound: ...`）→ **一个热键都没被按到**
- 出现了 `>> capture-near` 但没有对应的 `<< capture-near`
  → 崩在**采集处理函数里面**（这时 `pwpr.log` 会告诉你扫到第几件）
- 出现了完整的 `>> ... << ...` → 那次按键**正常跑完了**，崩溃与它无关

> 这就是为什么每个热键都会打 `>> 名字`（在**按键那一刻**同步打印）
> 和 `<< 名字`（跑完打印）。不用再靠回忆"我到底按没按"。

### 步骤 2：看崩溃栈在谁的地盘

`C:\Users\<你>\AppData\Local\Pal\Saved\Crashes\UECC-...\CrashContext.runtime-xml`
里找 **`<PCallStack>`**（崩溃线程），**从下往上读**：

```
KERNEL32 → Palworld → UE4SS → Palworld×N → UE4SS  ← 崩在这
```

`UE4SS` 帧夹着一长串 `Palworld` 帧 = 崩在 **UE4SS 的钩子分发**里，不是 Lua 里。

### 步骤 3：一次实验定归属 —— 关掉我们的 mod 再试

```powershell
# 只改 mods.txt 的 1→0，不复制不删除任何文件（保证不引入新变量）
powershell -ExecutionPolicy Bypass -File deploy.ps1 -Disable
# 重启游戏，进世界，走动一下

# 测完开回来
powershell -ExecutionPolicy Bypass -File deploy.ps1
```

- **还是崩** → 不是我们。下一个嫌疑人是 SBB 的 pak
  （它只装了 `BlueprintResearch.pak`、没装配套 Lua，ModActor 仍在每个关卡生成）：
  把 `Pal\Content\Paks\LogicMods\BlueprintResearch.pak` 改名加 `.off` 再试。
  再下一个嫌疑人是 `FirstPerson`（每次崩溃前都有它的 `[FOV] ... world reload`）。
- **不崩了** → 是我们。把 `pwpr.log` + `UE4SS.log` + 崩溃目录发出来。

### 症状速查（看到什么 → 是什么问题）

| 症状 | 原因 | 看哪里 |
|---|---|---|
| 投影是**浅色黑白格子**（灰模） | 材质是设上了 —— 那是 `MI_LooksPredicatorNormal` 本身的样子 | 按小键盘 `*` 换材质，见第 8 节 |
| 投影**浮空**（整层悬在地面上方） | 玩家 Actor 原点在胶囊体中心，不是脚底 | `player_feet_offset_cm` 填 `90` 左右；日志里有 `脚底偏移:` 一行 |
| 某件建筑**形状不对**（张冠李戴） | 自动名字匹配给错了 —— 尤其当正确资产不在 `/Architecture/` 下时会必然出错 | 在 `pwpr_meshmap.json` 里写死正确路径，或写 `"-"` 不画。**帕鲁终端就是这样修好的**（正确资产在 `/Game/Pal/Model/Other/PalBox/SM_PalBox`） |
| 投影**只显示了一部分** | 那些类型没解析到网格资产 | `pwpr.log` 的 `缺网格=N`；`pwpr_meshes.txt` 第 3 节逐类型说明为什么 |
| `网格覆盖表: 覆盖表 N 条` 的 N 比预期小 | 覆盖表没更新成功 | 现在分两个文件，`内置表` 会每次部署更新；看日志里 `内置表/用户表` 两段 |
| 按键**完全没反应** | 键没绑上 / 没按到 | `UE4SS.log` 搜 `>> 名字`。连 `>>` 都没有 = 没按到 |
| 按了键、日志有 `>>` 但没有 `<<` | 崩在那个处理函数里面 | `pwpr_probe.txt` 最后一条 `START`（探测时） |
| 提示 `attempt to index a nil value (global X)` | Lua 的 `local` 声明写在了使用之后 | 日志会直接给文件:行号；见 `docs/踩坑记录.md` 第 13 节 |
| 游戏在读档/进世界时崩 | 与世界加载相关的既有问题，多半不是本 mod | 按上面步骤 3 用 `-Disable` 做一次隔离实验 |

---

## 7. 蓝图格式

与 [`docs/蓝图格式.md`](../../docs/蓝图格式.md) 的 v1 规范一致：

```json
{
  "$format": "palworld-blueprint",
  "version": 1,
  "meta": {
    "name": "base_-1041_417",
    "units": "meter",
    "origin": [-1041.0, 417.0, 685.0],
    "size": { "x": 61.581, "y": 61.137, "z": 3.267 },
    "total": 358, "typeCount": 64, "layerCount": 4,
    "layerGapCm": 200,
    "meshCoverage": { "withMesh": 210, "total": 358 }
  },
  "stats": { "types": {...}, "layers": {...} },
  "buildings": [
    { "t": "Wood_Foundation", "p": [-12.0, 8.5, 0.0], "yaw": -28.69, "layer": 0 }
  ]
}
```

要点：

- **`p` 是以包围盒中心为原点的偏移（米）**，范围是 `±size/2`，不是 `[0, size]`
- `meta.origin` 只作记录，导入时不依赖 —— 所以蓝图可以跨存档、跨据点使用
- `yaw` 只有偏航（Palworld 建筑只能用 Yaw）
- 每件建筑带 `layer`，这就是"分层展示"的数据基础

`tools/blueprint.py`（Python 侧工具链）也能读写同一格式，可以互相校验。

---

## 8. 分层展示到底会分成什么样（重要预期管理）

分层是按 **Z 高度聚类**做的：把所有建筑的 Z 排序，
相邻 Z 差超过 `layer_gap_cm`（默认 200 厘米）就分到新的一层。

**用真实存档数据实测的结果**（主基地 358 件）：

| Z 值 | 件数 | 是什么 |
|---|---|---|
| -1.17 ~ -1.15 | **349** | 地基 + 墙 + 设施 + 床（都在同一水平面上） |
| +2.10 | **9** | 屋顶（7 个）+ 放在屋顶上的箱子（2 个） |

→ 这个基地会分成 **2 层**：`第 0 层 = 地面`，`第 1 层 = 屋顶`。

**要注意的关键事实**：

> **Palworld 的墙和地基在同一个 Z 上** —— 墙不是"叠"在地基上面的，
> 它们共享同一个水平基准面。

所以分层**不会**给你"地基一层、墙一层、屋顶一层"那种 Minecraft 式的细分。
它给你的是：

- ✅ **把屋顶藏起来看内部**（这是最实用的用法）
- ✅ **多层建筑逐层检查**（每层楼高度差 3 米左右，会被正确切开）
- ❌ 不会把同一层里的地基/墙/设施分开

**如果你想要"按建筑类别过滤"而不是按高度**：那是另一个功能（按类型过滤），
目前没做。临时替代办法是分次采集 —— 站远一点只框住想看的区域。

**调整办法**：`layer_gap_cm` 调小会分得更细（比如设 `100`），
设得比建筑总高度还大就等于"不分层"。改完按 `F8` 重载配置再重新采集。

---

## 9. 已知问题

### 结构件的网格解析（2026-09-26 深夜：已用真实资产清单核对）

Palworld 为性能考虑，**结构件（地基/墙/屋顶…）在 `PalBuildObject` 上读不到 mesh** ——
它们由 `BP_PalStaticMeshImposterChunk` 的 HISM 批量绘制。

**从游戏里导出的真实资产清单**（`pwpr_meshes.txt`，2310 个网格，
其中 150 个在 `/Architecture/` 下）显示，结构件只有 8 个资产：

| 蓝图类型 | 真实资产 | 怎么来的 |
|---|---|---|
| `Wood_Foundation` | `SM_Floor_Wood` | **注意是 Floor 不是 Foundation！** |
| `Wood_Wall_V2` | `SM_Wall_Wood` | 自动匹配（同分取短名） |
| `Wood_WindowWall` | `SM_WallWindow_Wood` | 自动匹配 |
| `Wood_DoorWall` | `SM_Door_Wood` | **自动匹配做不到**（资产名里没有 wall），靠覆盖表 |
| `Wood_Roof` | `SM_Roof_Wood` | 自动匹配 |
| `Wood_Stair` | `SM_Stair_Wood` | 自动匹配 |
| `Stone_WallGate` | `SM_WallGate_Stone` | 自动匹配 |

**这 7 条已经写死在 `pwpr_meshmap.json` 里**，不依赖猜测。

三处关键修正（都是被真实数据教出来的）：

1. **加 `foundation -> floor` 同义词** —— 不加以外，351 块地基一块都画不出来。
2. **CamelCase 拆词** —— 类型名是 `Wood_WindowWall`，资产名是 `SM_WallWindow_Wood`，
   不拆永远匹配不上。
3. **匹配必须严格 + 只在 `/Architecture/` 里找 + 同分并列就放弃**。
   曾经加过"放宽一轮"，结果 `HatchingPalEgg -> SM_PalSpa`、
   `FarmBlockRecipe -> SM_IceBlock` —— **纯垃圾，已删除**。

> 验证方式：`tools/meshmatch_sim.py` 把匹配算法在 Python 里原样实现，
> 用 **79 种真实类型 + 2313 个真实网格**跑一遍，并拿"actor 上读得到的 26 种"
> 当标准答案算准确率。**改 Lua 之前先在这个模拟器上验证。**

### 怎么查"还有哪些类型画不出来"

```powershell
$bp = "<游戏>\Mods\NativeMods\UE4SS\Mods\PWProjection\blueprints"

# ① 审计：用【真实优先级链】(actor 网格 > 覆盖表 > 名字匹配) 逐类型列出最终画什么
python tools/meshmatch_sim.py --audit --mapdir mod\PWProjection\Scripts --blueprints $bp

# ② 对比：把"游戏自报的网格"和"我们的覆盖表"做 diff
#    会列出【新增】（还没映射的）和【冲突】（我们猜错的）
python tools/meshmatch_sim.py --emit-overrides --blueprints $bp --mapdir mod\PWProjection\Scripts

# ③ 孤儿资产：/Architecture/ 下没有任何类型用到的网格
#    用来判断"看不见的类型"到底是【缺映射】还是【根本缺资产】
python tools/meshmatch_sim.py --orphans --mapdir mod\PWProjection\Scripts --blueprints $bp
```

> `--mapdir` 必须指向**工作区**里的 `mod/PWProjection/Scripts`，
> 否则读的是游戏里那份旧拷贝，审计结果会不对（这个坑踩过）。
> `--blueprints` 指向游戏里真实采集出来的蓝图目录 ——
> 里面的 `stats.types[].mesh` 是**游戏自己报的**，是最权威的标准答案。

**当前结果**（主基地 358 件 / 64 类型 + 小基地 35 件 / 11 类型）：

| 指标 | 值 |
|---|---|
| 覆盖表条目 | **58** |
| 与游戏自报网格冲突 | **0** |
| 与游戏自报网格一致 | 39 |
| 仍然完全看不见的类型 | **13** |

那 13 种**不是缺映射，是缺资产** —— 用 `--orphans` 验证过：
`/Architecture/` 下只有 11 个"没有任何类型用到"的网格，
**没有一个是那 13 种的**。也就是说游戏里这些建筑没有可读的独立网格
（和结构件一样由 HISM 批量绘制，或者它们的网格在当前会话没被加载）。

完整名单：`OilPump02`、`AncientEnergyGenerator`、`BaseCampWorkerExtraStation`、
`AncientMultiProduct`、`WeaponFactory_Dirty_4`、`TableDresser01_Stone`、
`DisplayCharacter`、`Factory_Hard_4`、`AncientRelicRecycler`、`FlourMill`、
`CharacterSkinChange`、`IceCrusher`、`SphereFactory_Black_04`。

> 想补它们，唯一可靠的办法是**走到那些建筑旁边再按一次 `Y`**
> —— 让游戏自己把网格报出来。我已经试过所有能靠名字推的路子，都没有可辩护的候选。

### 农场为什么看起来都一样

**Palworld 所有作物农场共用同一个田垄网格 `SM_FarmGround`。**
品种差异体现在**作物**上，而作物不是挂在建筑 actor 上的（是单独的实例化网格）。

所以野果农场 / 小麦农场 / 番茄农场在投影里长得一样 —— **这是游戏设计，不是匹配错误**。
覆盖表里把 `FarmBlock*` 全部显式指向 `SM_FarmGround`，就是为了让它们行为一致。

### 其它

| 项 | 状态 |
|---|---|
| 分层展示 | ✅ 已实现（`L` 键循环） |
| 蓝图之间的连接关系 | ❌ 未做（只存位置+朝向，投影够用，结构校验不够） |
| 材料清单 | ❌ 未做（可从类型映射推出） |
| 蓝图分享码 | ❌ 未做（文件形式已够自用） |
| 屏幕 HUD | ⚠️ 需探测（Shipping 构建下 `PrintString` 可能不画） |
| `data/type_map.json` | ❌ 未做（短类型名 ↔ 存档 `MapObjectId`） |

---

## 10. ★ 补充缺失建筑 / 修正朝向（操作指南）

> 这一节就是为"以后又发现某栋楼没画出来"准备的。
> **不用等我也能自己修** —— 全过程不需要改代码、不需要重启游戏。

### 10.1 先分清是哪一种问题

| 现象 | 原因 | 怎么办 |
|---|---|---|
| **完全没投影** | 这个类型没解析到网格资产 | 见 10.2 |
| **投影了但方向偏了** | 美术给网格组件设了固定的相对旋转，`actor朝向 ≠ 网格朝向` | **本版已修**（改用网格朝向）。**重新按一次 `Y` 采集**即可 |
| **投影了但形状不对** | 映射到了错的资产（或游戏里共用同一个网格） | 见 10.2，用 `"-"` 可以干脆不画 |

### 10.2 三步补齐流程

**第 1 步：站在那栋建筑旁边，按 `Y` 重新采集**

采集会把两件东西写到 `Scripts\pwpr_meshes.txt`：
- 第 1 节：**当前会话加载的全部静态网格**（短名 + 完整路径）
- 第 2 / 3 节：每个类型的**匹配结果和读取诊断**

**第 2 步：找到那个类型的短名**

看 `pwpr.log` 里采集摘要的那一行：

```
网格解析: 直接命中 11 / 覆盖表 36 / 名字匹配 4 / 未解析 13
```

`未解析` 的那些就是画不出来的。具体是哪几个，看 `pwpr_meshes.txt` 第 2 节
（匹配到 `-` 的行）或第 3 节（有"说明"列告诉你为什么读不到）。

**第 3 步：找到它的网格资产路径，写进映射表**

在 `pwpr_meshes.txt` **第 1 节**里搜关键字（目录名往往就是建筑名）：

```
SM_PalCage      /Game/Pal/Model/Other/PalCage/SM_PalCage.SM_PalCage
SM_MatingStation /Game/Pal/Model/Prop/Architecture/PalMatingStation/SM_MatingStation...
```

然后编辑 `Scripts\pwpr_meshmap.json`（**用户表，部署时绝不覆盖**）：

```json
{
  "类型短名": "/Game/.../SM_某网格.SM_某网格"
}
```

按 **`F8`** 重载配置 → 再按 `K` 重建投影。**不用重启游戏。**

> 特殊值 `"-"` 表示"这个类型不要画"。用在"映射会给出错的东西、而游戏里
> 又确实没有对应资产"的情况 —— **画一个错的形状比不画更糟**。

### 10.3 "整个注册表里也搜不到"意味着什么

如果 `pwpr_meshes.txt` 第 1 节（全量注册表）里**搜不到**任何能对上的资产，
那就不是映射问题，而是**资产本身不可用**：这栋建筑在当前会话没有可读的
独立网格 —— 和结构件一样由 HISM 批量绘制，或者它的网格根本没被加载。

**目前已知的 7 种就是这种情况**（搜遍 2463 个网格、试了所有关键字，一个都没有）：

| 建筑 | 类型短名 | 备注 |
|---|---|---|
| 观赏笼 | `DisplayCharacter`（推测） | 候选：`/Game/Pal/Model/Other/PalCage/SM_PalCage`（**未验证**） |
| 冷却粉碎机 | `IceCrusher`（推测） | 注册表里无候选 |
| 磨粉机 | `FlourMill` | 注册表里无候选 |
| 古代文明物质生成器 | `AncientMultiProduct`（推测） | 注册表里无候选 |
| 高等文明作业工厂 | `Factory_Hard_4`（推测） | 注册表里无候选 |
| 高等文明帕鲁球工厂 | `SphereFactory_Black_04`（推测） | 注册表里无候选 |
| 高等文明武器工厂 | `WeaponFactory_Dirty_4`（推测） | 注册表里无候选 |

> 类型短名的"推测"两字很重要：中文名 ↔ 内部类型名是我对照出来的，
> 不保证一一对应。**准确做法是看 `pwpr.log` 的完整类型列表**（摘要里只显示前 10 个）。

**已经穷尽验证过**（2026-09-26 深夜）：把范围放宽到
`/Game/Pal/Model/Prop/` + `/Other/` 全部 126 个可建造相关网格，
用 `--orphans-all` 列出"注册表里有、但没有任何类型引用"的 66 个 ——
**里面没有任何一个能对应上面那 7 种**（没有 Crusher / Mill / Factory /
MultiProduct / Recycler / WeaponFactory / SphereFactory）。

所以结论是确定的：**这 7 种建筑在当前会话没有可读的独立静态网格**
（和结构件一样由 HISM 批量绘制，或者资产属于尚未加载的 pak）。

> **候选是有的，但我不自动启用。** 那 66 个孤儿里挑出几个"名字可能对得上"的，
> 全部记在 `pwpr_meshmap.json` 头部注释的 `_cand_*` 条目里（例如观赏笼 →
> `/Game/Pal/Model/Other/PalCage/SM_PalCage`）。
> **想试就把那一行改成真条目 → 按 `F8` → 看形状对不对，10 秒验证一条。**
>
> 为什么不直接启用：我已经因为"猜一个看起来像的"被纠正过**两次**
> （`FarmBlockRecipe`、`Farm_SkillFruits`），所以新候选一律只记录不启用。

**想补它们，唯一可靠的办法**：走到那些建筑旁边按 `Y`，然后看
`pwpr_meshes.txt` 第 3 节的"有网格"列 —— 如果游戏自己报出了网格名，
把完整路径填进映射表即可；如果还是 0，那就是真的没有独立网格。

### 10.4 用工具批量检查（可选，但更快）

```powershell
$bp = "<游戏>\Mods\NativeMods\UE4SS\Mods\PWProjection\blueprints"

# ⓪ 改完映射表先跑这个：查 JSON 语法错、重复键、路径形式错
python tools/check_meshmap.py mod\PWProjection\Scripts

# ① 哪些类型会完全看不见
python tools/meshmatch_sim.py --audit --mapdir mod\PWProjection\Scripts --blueprints $bp

# ② 游戏自报的网格 vs 我们的映射表：列出【新增】和【冲突】
python tools/meshmatch_sim.py --emit-overrides --blueprints $bp --mapdir mod\PWProjection\Scripts

# ③ 孤儿资产：注册表里有、但没有任何类型用到的网格
#    （用来判断"看不见"是缺映射还是缺资产）
python tools/meshmatch_sim.py --orphans --mapdir mod\PWProjection\Scripts --blueprints $bp
```

**② 最有用**：它直接告诉你"我们猜错了哪几条"。实测靠它抓到过 2 条错映射
（`FarmBlockRecipe`、`Farm_SkillFruits`）—— 那两条如果不去采集，永远不会知道是错的。

### 10.5 朝向问题的技术说明

```lua
-- 错的（旧版）: actor 朝向
local _, yaw, _ = Util.rot_of(obj)

-- 对的（本版）: 优先取【网格组件的世界旋转】
component:K2_GetComponentRotation()      -- 已经把 actor 旋转和相对旋转都算进去
-- 退回: actor 朝向 + 组件 RelativeRotation.Yaw
```

采集诊断表（`pwpr_meshes.txt` 第 3 节）有一列 **`朝向差`** = 网格朝向 − actor 朝向。
非 0 说明这类建筑的网格组件带固定相对旋转。

**2026-09-26 实测结果**（主基地 64 种类型）：

| 类型 | 朝向差 | 说明 |
|---|---|---|
| `BaseCampItemDispenser` | **90°** | 就是玩家报告的「道具存取机方向偏了」 |
| `DefenseWait` | **180°** | 防御设施之前是**完全反的** |
| 其余 9 种有网格的 | 0° | 不受影响 |

> 这一列的价值在于：**它把"方向偏了"从主观描述变成了一个可测量的数字**。
> 那两个类型如果不是改用网格朝向，会一直是歪的，而且很难说清歪了多少。

同样这一节还区分了两种"没有网格"（这一点很重要）：

```
共 64 种类型，其中 53 种一件都没读到网格
  · 53 种是【obj.Mesh 本身就是 nil】—— 游戏没给这些建筑 Mesh 组件
     （和结构件一样由 HISM 批量绘制）。这是游戏侧的事实，不是我们读不到。
  ·  0 种是【有组件但读失败】—— 这才可能是我们的问题，需要单独查。
```

**"游戏侧事实"和"我们读不到"是两件事** —— 上一版把它们混成一句话，
所以看不出到底该怪谁。现在分开统计。

### 10.6 ★★ 名字找不到时：反向取证（最强手段）

**原理**：一栋建筑既然**画得出来**，它的网格就**一定已经加载**，
也就**一定有个网格组件在画它**。而 UE4SS 给出的组件全名长这样：

```
StaticMeshComponent /Game/Pal/Maps/MainWorld_5/.../PL_MainWorld5
                   :PersistentLevel.BP_BuildObject_WeaponFactory_Dirty_4_C_2147482000.Mesh
                                  └──────────┬──────────────────────────┘
                                    宿主建筑的类型名就写在里面
```

所以**根本不用猜名字，也不用管 `obj.Mesh` 是不是 nil**：

> 枚举世界上所有网格组件 → 从组件全名里解析出 `BP_BuildObject_<类型>_C`
> → 读它用的 `StaticMesh` → **直接得到【类型 → 网格】对应关系**。

**怎么看**：`pwpr_meshes.txt` **第 5 节**（每次按 `Y` 采集时导出）。
最上面就是**可以直接抄的成品**：

```
=== ★★★ 查到了、但覆盖表里【还没有】的类型（照着填进 pwpr_meshmap.json）===
  "WeaponFactory_Dirty_4": "/Game/Pal/Model/Prop/Architecture/XXX/SM_XXX.SM_XXX",
```

把这几行直接粘贴进 `pwpr_meshmap.json` → 按 `F8` → 完成。

下面还有一张完整的【建筑类型 → 网格】表，以及一条关键的自检标记：

| 标记 | 含义 |
|---|---|
| 无标记 | 正常，这个网格也在第 1 节的全量清单里 |
| **`★不在第1节(枚举不全!)`** | 这个网格**被组件用着，却不在 `FindAllOf("StaticMesh")` 的结果里** —— 说明那个枚举**不全**，这才是我们真正的盲区 |

**第 6 节**是补充：列出所有 ISM / HISM 组件实际在用的网格
（结构件、作物是靠 HISM 批量画的，它们没有 actor 上的 Mesh 组件）。

> 两节都有上限保护（第 5 节 30000 个组件、第 6 节 20000 个），
> 基地太大时会注明"结果不完整"，避免把游戏主线程卡住。

**如果第 5 节里也查不到那件建筑** —— 才回到 10.3 的结论：
它在当前会话确实没有可读的独立静态网格。

---

## 11. 总体进度与下一步计划

> 截至 2026-09-26 深夜。**这条目会随开发更新**。

### 11.1 已完成（可正常使用）

| 能力 | 状态 | 备注 |
|---|---|---|
| 采集蓝图 `Y`（附近）/ `U`（全部） | ✅ | 主基地 371 件 / 72 类型一次采完 |
| 蓝图库 `J`（多张切换） | ✅ | `index.txt` + 逐张 JSON |
| 投影放置 `K`（放/收） | ✅ | 收起即销毁宿主，**不留残留** |
| 移动 / 旋转 / 高度 | ✅ | 方向键 + `F9` 三模式，**零修饰键组合** |
| 分层展示 `L` | ✅ | 实测 3 层 |
| 投影材质 | ✅ | 4 档循环（默认蓝色）+ 4 档备用 |
| **骨骼网格建筑** | ✅ | 后期工厂 / 磨石 / 碎冰机 / 钻油机 / 古代发电机 |
| **多网格建筑** | ✅ | 简约门（3 件）、帕鲁装扮机（2 件） |
| 朝向正确性 | ✅ | 用网格组件世界旋转，不用 actor 朝向 |
| **网格映射** | ✅ | **80 条；主基地 72 种类型「未解析 0」** |
| 崩溃安全 | ✅ | 探针分步落盘、门禁、永不用 `PrintString` |
| **屏幕提示（策略层 + 控制台通道）** | ✅ **实测通过（2026-09-27）** | 一次游玩生成 **12 条** `> ` 提示（采集/加载/放置/换层/模式…），见 `pwpr.log` |
| 按键表单一来源 | ✅ **实测通过** | `F7` 的表由 `Notify.KEYS` 生成（待办 5 的一半） |

### 11.2 当前能力边界（诚实说明，不是 bug）

| 限制 | 原因 |
|---|---|
| 分层通常只有 2–3 层 | **Palworld 的墙和地基是同一个 Z**，只有真正叠楼才有更多层（第 8 节） |
| 骨骼网格显示**静止姿态** | 没有动画驱动；对静止机器观感正常 |
| 所有作物农场看起来一样 | **游戏设计**：共用田垄网格 `SM_FarmGround`，作物是另外画的 |
| 三个"高等文明"工厂共用同一网格 | **游戏自己的组件数据就是这样**（`SK_PalSphereFactoryFuturistic`） |
| 帕鲁装扮机的雕像固定为粉猫 | 雕像那件可能是按当前帕鲁动态换的，我们取不到动态值 |

### 11.3 网格覆盖情况（2026-09-27 凌晨）

| 指标 | 值 |
|---|---|
| 内置映射条目 | **80**（78 单网格 + 2 多网格） |
| 主基地类型数 | 72 |
| 解析结果 | **直接命中 64 / 覆盖表 8 / 名字匹配 0 / 未解析 0** |
| 与游戏自报数据冲突 | **0** |

**"未解析 0" 的含义**：那 8 种走覆盖表的，是 actor 上没有可读网格组件的
（结构件由 HISM 批量绘制），靠映射表补上。

**⚠️ 三个需要留意的情况**（不是 bug，是"只拿到了建筑的一部分"）：

| 类型 | 实际画出来的 | 说明 |
|---|---|---|
| `DisplayCharacter`（观赏笼） | `SM_PalBox_Pillar`（柱子） | 游戏自己在这个 Actor 上挂的组件就是柱子；展示台本体可能在别处 |
| `SF_DoorWall_02`（简约门） | 门框 + 左门扇 + 右门扇 | ✅ 已用多网格映射（否则只剩门框） |
| `CharacterSkinChange`（装扮机） | 底座 + 帕鲁雕像 | ✅ 已用多网格映射（雕像固定为粉猫） |

### 11.4 下一步计划

> **发布方向已定**：先完善到能给大伙用，再迭代。
> 下面的顺序按"**对发版的价值**"排，不按技术难度。

#### 第 1 组 —— 发版前建议做完

| 顺序 | 项 | 状态 | 说明 |
|---|---|---|---|
| 1 | **状态切换时的屏幕文本提示** | 🟡 **控制台通道已实测通过；游戏内文字待做** | 策略层/通道层已写好，一次游玩生成 12 条提示（`pwpr.log` 里 `> ` 开头的行）。游戏内文字两条路：`GraphicsAPI=dx11`（今天可用）或按 `O` 探测游戏内通道（**第 2 步的反射枚举曾崩游戏，已永久禁用**）。见 4.6 |
| 2 | ★ **建造吸附 / 蓝图建造**（**玩家真正要的那个**） | 🟡 **已实现 + 纯逻辑离线自检通过；第一次实测"没起作用"已定位修好，等第二次实测** | 手拿建筑放下时落到投影上（`align` 模式）；或**准星指着投影哪件就建哪件**（`blueprint` 模式）。挂 `RequestBuild_ToServer` 钩子 → 拦原请求 + 按投影坐标重发。权威文档 [`docs\建造吸附.md`](../../docs/建造吸附.md)；自检 `tools\buildsnap_sim.py`；第一次失败的根因见 `docs\踩坑记录.md` §40。**不用按键** |
| 2b | 投影对齐（把整个投影挪到已有建筑上） | 🟡 已实现、离线 8/8；**自动吸默认关** | 按 `U` 触发（叠图对比用）。这是我一开始**理解错需求**做出来的东西，保留为可选工具 —— 见 `docs\踩坑记录.md` §38。**纯网格吸附**还没做 |
| 3 | **蓝图选择 / 导出 / 导入** | ⬜ 未开始 | 现在 `J` 只能顺序切；且抄别人的建筑不是一个存档。**已查证本 UE4SS 构建没给 Lua 开放 ImGui，所以第一版不做界面**：用"文件 + 编号选择"就够。见待办 4 |
| 4 | **按键一览 + 改键** | 🟡 一览已完成 | "在游戏里看到按键表"**已完成**（`F7`，来自 `Notify.KEYS` 单一来源）；**改键还没做**（配 `keybinds` 表 + `F8` 重载，无依赖）。见待办 5 |

#### 第 2 组 —— 发版后再说

| 项 | 说明 |
|---|---|
| **组件的相对变换（装配体建筑）** | 唯一会**动蓝图格式**的改动，兼容性要仔细想。做之前观赏笼只能不画。详见待办 3 |
| 用官方接口优化现有实现 | 依附于第 1 项一起调研 |
| 骨骼网格动画 | 目前静止姿态够用；需要 `AnimInstance`，风险中等 |
| 材质做半透明+描边 | 需要动态材质实例（DMI），参数名未知，风险中等 |
| 多层基地的分层算法改进 | 现在按 Z 聚类；可改成按"连通楼板"分 |

#### 持续维护（不是"计划"，是日常）

| 项 | 说明 |
|---|---|
| **映射表继续补** | 工具已齐备（反向取证 + 4 项校验）；发现新建筑走第 10 节流程 |
| **维护 `已知限制.md`** | 每次遇到"查不到 / 查到但不对"就加一行 |

### 11.5 维护方式（以后遇到问题看哪里）

| 遇到什么 | 去哪 |
|---|---|
| **建筑没投影 / 方向偏 / 形状不对** | **第 10 节**（三步流程 + 反向取证 + 校验命令） |
| 改了映射表 | 跑 3 个校验命令（10.4 节），再按 `F8` 生效（**不用重启游戏**） |
| 游戏崩溃 | **第 6 节**（归因流程） |
| 怀疑是我们导致的崩溃 | `deploy.ps1 -Disable` 关掉再试一次 |
| 想改按键 / 材质 / 步长 | **第 5 节**配置表 |

### 11.6 已知的技术债 / 脆弱点

| 项 | 说明 | 缓解 |
|---|---|---|
| 骨骼网格每件一个组件 | 不能实例化，实例多时组件数会涨 | `ghost_max_instances` 有上限 |
| 映射表靠人工维护 | 游戏资产名和类型名经常对不上（甚至有拼写错误） | 反向取证 + 校验工具已齐备 |
| UE4SS 的 `IsValid()` 不可信 | 会把好对象判为无效 | 统一用 `Util.usable()`，见第 4 节 |
| UE4SS 按键绑定不看修饰键 | 所以**不能**用修饰键组合做区分 | 已改成"模式键 + 纯方向键" |
| UE4SS 属性读取常返回**包装对象** | 不 `unwrap` 就调不通方法，而且静默失败 | 已修（矿车方向那个 bug 就是它） |
| **我们自己的静态检查器是"近似 Lua 语法"** | 它靠自写的词法器，不是真 Lua。所以它可能**漏报**真语法错 | 已补第 10 项检查（见下）；没有独立 Lua 解释器可跑，这是已知缺口 |
| **UE4SS 的反射枚举接口会崩游戏** | `ForEachFunction` / `ForEachProperty` 实测直接把游戏打崩（崩溃栈全在 UE4SS）。而 `UE4SS.dll` 里**能扫到这些字符串**，看起来"支持" | 已做成检查项（`luacheck` 第 **11** 项直接拦）；安全替代是 `FindAllOf("精确类名")` |
| **UE 函数用点号调用 = 崩溃** | `pc.Func(text)` 会把 `text` 当 `self` → 野指针 | 统一用 `obj:Func(...)`；动态名字必须写 `obj[name](obj, ...)` |

**★ 2026-09-27 的实例（值得记住）**：
`pwpr_notify.lua` 里写了 `function Notify.repeat()` ——
`repeat` 是 Lua 的**保留字**，所以 `t.repeat` 是**语法错误**，
整个文件都加载不了（症状本该是"mod 一行日志都不打、直接 init failed"）。

当时检查器先报的是 `块结构平衡: 结束时深度 = 1`（看着像少写 `end`），
追下去才发现是保留字当函数名。**因此给检查器加了第 10 项：
"没有拿保留字当字段名/方法名"**，并在 `luacheck_selftest.py` 里配了
正反两个样例（`keyword_as_field.lua` / `keyword_as_method.lua` /
`good_keyword_not_field.lua`）。

> 这条也说明了那个检查器为什么值得留：它抓不到的东西我们能知道，
> 但它抓到的东西**往往是真 bug**，而不是风格问题。

---

## 12. 授权

代码为本项目原创。参考了 Simple Building Blueprints 的**架构思路**
（哪些引擎调用可行、怎么省组件），但**没有复制其源代码**。
SBB 作者要求"修改需授权、资源不得再分发"，本项目不涉及这两件事。

Palworld 的资产路径、材质路径是游戏自带内容的**引用**，不随本 mod 分发。
