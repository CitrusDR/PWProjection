# Simple Building Blueprints 架构分析（只读设计参考）

> ## 🔴🔴 勘误（2026-09-29，**玩家直接去问了 SBB 作者**，作者本人更正）
>
> 本文档下面有几处**对 SBB 实现的推断是错的**（我只读了模块名/函数名/日志文本就去猜流程）。
> 作者本人的更正：
>
> 1. **"锚点复用: 借一件已放置建筑当宿主、把幽灵组件挂上去"** —— ❌ **不是它的做法**。
>    作者的**创建（放置）过程**是**直接改"对应 actor"的材质**，不是往某个建筑上挂幽灵组件。
>    另外我这句话还把**两件事混在了一起**: 蓝图**采集**（数据读取）与**放置时的幽灵渲染**。
>    > 更早的一次勘误见 `交接笔记.md` 第 40~47 行 / `踩坑记录.md` §（"anchor 是数据概念"）——
>    > 那次纠正的是"anchor"这个词的含义，**没有**纠正"挂幽灵组件"这个更根本的误判。
> 2. **"左下角那条进度提示是它自己的 UMG 控件画的，不是游戏接口"** —— ❌ **错**。
>    作者是**调用游戏自己反射出来的消息显示接口**（**左下角滚动消息 + 顶部警告消息**两类）。
>
> ⇒ 本文档中凡涉及这两点的段落（§三"锚点复用"、§一 的加粗结论）**只当"我当时的错误推断"看**。
> **我们自己的实现**已经单独成文: [`实现方式.md`](实现方式.md)（里面**不含**任何 SBB 内容）；
> 与"我一开始以为的 SBB 做法"的对照表见下面的 **§零**（那份表只为记住"错在哪"）。
>
> 分析对象：Nexus mod **4073 Simple Building Blueprints v0.16.1**（2026-09-20）
> 分析日期：2026-09-26
> 分析方式：**只读模块划分、文件命名、函数签名、配置项、常量路径与日志文本**
>
> ## ⚠️ 版权声明
>
> 该 mod 作者在 Nexus 上明确要求：
> **修改需授权 / 使用资产需授权 / 禁止转载到其它站点 / 禁止用于收费 mod**
>
> 所以本文档**只记录设计思路与架构事实**，用于指导我们自己的实现。
> **不复制、不摘录其代码实现**。任何代码都必须我们独立编写。
> 本文档中出现的少量片段属于"接口契约与常量"，用于说明设计取舍，
> 不是可运行的实现逻辑。

---

## 零、★ 我们自己实现 vs"我一开始以为的 SBB 做法"（对照表）

> ⚠️ **先读这句**: 下面左列是**我们自己的实现**（2026-09-29 对代码逐条核过，是事实）；
> 右列那句"我一开始以为 SBB 怎么做"**已经证明是错的**（作者本人更正，见顶部勘误块）——
> 留在这里**只为了记住"当时错在哪"**，不要当 SBB 的事实用。
>
> **我们自己的完整总结文档是 [`实现方式.md`](实现方式.md)，那份里不含任何 SBB 内容。**

| 环节 | **我们的做法（事实）** | 我一开始以为 SBB 怎么做（❌ 错） |
|---|---|---|
| **蓝图采集**（按 `Y`）| **纯只读 + 写 JSON**；不创建、不修改任何引擎对象（该文件里 `SpawnActor`/`SetMaterial` 出现 **0** 次）。枚举 `World.PersistentLevel.Actors` 全表（按类链筛 `PalBuildObject`），逐件读 `K2_GetActorLocation` / `K2_GetActorRotation` / `GetClass():GetFullName()`；结构件网格由 `pwpr_meshmap.lua` 世界 ISM 反查 | 以为"采集"是"借一个已有建筑当锚点、把幽灵组件挂上去" |
| **投影渲染**（按 `K`）| **自己新建空宿主 Actor** + **自己的实例化组件**（唯一会创建/修改引擎对象的模块，双重门禁）。每个**网格资产**一个 `InstancedStaticMeshComponent`（60~80 个/基地）+ `SK_*` 用 SkeletalMesh；实例用局部坐标、组件承载放置变换；材质 = 游戏自带的 `BuildingSurfaceMaterialSet.Highlight` **设到我们自己组件上**；碰撞关 | 以为它是"借锚点挂幽灵组件、画完再恢复"（**实际是直接改对应 actor 的材质**）|
| **"已放上"不画** | 这些记录的实例**干脆不加**（`Ghost.skip` / `Ghost.rehide`），不是改材质、也不是隐藏 actor | —— |
| **唯一"借用已有建筑"的地方** | **只当坐标参照**（只读位置/类名/朝向）算**投影整体偏移**或认领"已放上"（`pwpr_snap.lua` 投票 / `pwpr_placed.lua` 一对一贪心，只减不增）；**故意不读网格组件**（老存档里被删的网格 = 野指针）| 把"借建筑"理解成了"借**宿主**" |
| **放置落位** | **改游戏的放置请求**: 钩 `PalNetworkPlayerComponent:RequestBuild_ToServer` → 把 id 参数改成 `None` 拦掉 → 用投影坐标**重发**（**排到下一帧**，`buildsnap_defer`）→ `NotifyOnNewObject` 做落地确认。**全程不碰材质** | —— |
| **屏幕提示** | **自建浮层控件**（拿游戏自带控件类 `WBP_Warning_LowMemory_C` 实例化一份自己用 + `TextBlock:SetText`）或**控制台兜底**；`ClientMessage` 实测**调用即闪退**⇒ 永久禁用；通道按 `O` 探测后选中（未探测 = 控制台）| 以为"它左下角进度提示是它自己的 UMG 控件画的"（**实际是调游戏反射出来的消息接口**）|

---

## 一、总体结论（对我们的价值）

**这个 mod 已经验证了"纯 Lua + UE4SS 实现半透明建筑投影"是可行的。**

而且它的实现方式比我们设想的更聪明：

> ⚠️（下面这句是我当时的**错误推断**，作者本人已更正 —— 见顶部勘误）：
> **不是"为每件建筑创建一个 actor"，而是"借用一个已有建筑当锚点，
> 把幽灵组件挂上去，画完再恢复"。**

这解决了我们一直担心的"650 个 actor 会拖垮帧率"的问题。

---

## 二、整体规模与模块地图

| 指标 | 数值 |
|---|---|
| Lua 文件 | **91 个** |
| Lua 总量 | **约 2.4 MB**（入口 `main.lua` 就有 527 KB） |
| 原生 DLL | 1 个（141 KB） |
| 蓝图 pak | 1 个（110 KB） |

### 模块划分（按职责归类）

**核心渲染**
| 模块 | 大小 | 职责 |
|---|---|---|
| `BlueprintGhostRenderer.lua` | 110 KB | ★ 半透明幽灵渲染（主投影实现） |
| `BlueprintWaveGhostRenderer.lua` | 27 KB | 分批渲染（大蓝图分波次） |
| `BlueprintThumbnailRenderer.lua` | 63 KB | 蓝图缩略图 |
| `BlueprintPreviewMesh.lua` | 3 KB | ★ 预览网格（小模块，但是核心抽象） |
| `BlueprintBlockerVisual.lua` | 12 KB | "被挡住"的视觉提示 |
| `BlueprintPlanFailureVisual.lua` | 5 KB | 失败件的视觉 |
| `BlueprintRegionPreview.lua` | 8 KB | 区域预览 |

**蓝图数据与库**
| 模块 | 大小 | 职责 |
|---|---|---|
| `BlueprintJsonSchema.lua` | 24 KB | ★ 蓝图 JSON 格式定义 |
| `BlueprintCodeCodec.lua` | 36 KB | 蓝图文本编码（**分享码**） |
| `BlueprintCompactBinary.lua` | 24 KB | 紧凑二进制编码 |
| `BlueprintDeflate.lua` | 11 KB | 压缩 |
| `BlueprintLibraryStore.lua` | 40 KB | 蓝图库存储 |
| `BlueprintLibraryFileSystem.lua` | 12 KB | 文件系统 |
| `BlueprintLibraryImporter.lua` | 8 KB | 导入 |
| `BlueprintLibraryManager.lua` | 13 KB | 库管理 |
| `BlueprintClipboard.lua` / `Transport.lua` | 8 KB ×2 | 剪贴板 / 传输 |

**选取与信息采集**
| 模块 | 大小 | 职责 |
|---|---|---|
| `BlueprintSelectionSession.lua` | 120 KB | ★ 选取会话（最大的模块之一） |
| `BlueprintSelectionData.lua` | 61 KB | 选取数据 |
| `BlueprintSelectionMode.lua` | 64 KB | 选取模式 |
| `BlueprintConnectedSelection.lua` | 12 KB | 连通结构选取（按 R 键） |
| `BlueprintRegionGeometry.lua` | 9 KB | 框选几何 |

**放置流程**
| 模块 | 大小 | 职责 |
|---|---|---|
| `BlueprintPlacementInput.lua` | 43 KB | 放置输入 |
| `BlueprintPlacementCamera.lua` | 19 KB | 放置相机模式 |
| `BlueprintPlacementAnchorProbe.lua` | 22 KB | ★ 锚点探测（anchor 概念） |
| `BlueprintPlacementSessionComponents.lua` | 11 KB | 放置会话组件 |
| `BlueprintWavePlanner.lua` | 33 KB | 分波规划 |
| `BlueprintConstructionCoordinator.lua` | 32 KB | 建造协调 |

**合法性校验（DLL 参与的部分）**
| 模块 | 大小 | 职责 |
|---|---|---|
| `BlueprintOverlapQuery.lua` | 46 KB | 重叠查询 |
| `BlueprintNativeOverlapGate.lua` | 46 KB | ★ 原生重叠校验门（调 DLL） |
| `BlueprintSupportGate.lua` | 45 KB | 支撑校验 |
| `BlueprintNativeSupportRoots.lua` | 20 KB | ★ 原生支撑根（调 DLL） |
| `BlueprintMaterialGate.lua` | 27 KB | 材质条件校验 |
| `BlueprintExternalSupportMatcher.lua` | 10 KB | 外部支撑匹配 |

**UI**
| 模块 | 大小 | 职责 |
|---|---|---|
| `BlueprintLibraryUI.lua` | 107 KB | 蓝图库界面 |
| `BlueprintModeUI.lua` | 61 KB | 模式界面 |
| `BlueprintLocalization.lua` | 74 KB | 多语言 |
| `BlueprintModOptionsAdapter.lua` | 33 KB | 配置界面（MOF） |

**基础设施**
| 模块 | 大小 | 职责 |
|---|---|---|
| `BlueprintRuntimeUtils.lua` | 9 KB | 运行时工具 |
| `BlueprintRuntimeBridge.lua` | 16 KB | ★ 原生桥接（与 DLL 通信） |
| `BlueprintCallbackScheduler.lua` | 7 KB | 帧预算调度 |
| `BlueprintWorldLifecycle.lua` | 2 KB | 世界生命周期 |
| `BlueprintLog.lua` | 5 KB | 日志 |
| `unpack` / `unwrap` / `safe_property` 等 | — | 安全访问原语 |

---

## 三、★ 核心设计一：锚点复用（不新建 Actor）

从 `BlueprintGhostRenderer.install(deps)` 依赖契约可读出这个设计：

```lua
deps.get_original_anchor_material   -- 读锚点的原材质
deps.restore_transform              -- 恢复锚点变换
deps.component_store                -- 组件存放处
```

配合日志文本：

```
blueprint preview native-call enter call=AddComponentByClass label=...
blueprint preview native-call enter call=ghost-component-setup index=...
blueprint preview native-call enter call=query-component-setup shape=...
```

### 推断出的工作流

```
1. 找一件【已放置的建筑】当锚点（anchor）
2. 用 AddComponentByClass 往锚点 actor 上挂"幽灵组件"
   - ghost-component    → 透明外观
   - query-component    → 碰撞查询形状（供重叠检测）
3. 用一个循环把蓝图里所有建筑件的位置都画出来
4. 结束时: restore_transform 恢复锚点、恢复原材质
```

### 为什么这个设计好

| | 逐件 SpawnActor | **锚点 + 挂组件** |
|---|---|---|
| Actor 数量 | 650 个 | **1 个** |
| Tick / 网络复制 / GC 压力 | 极高 | **极低** |
| 建/销毁成本 | 每件一次 | **组件级** |

> **这正是我们该抄的设计思路**（不是代码）。
> 我们之前的设计是"按类型分组放进 HISM"，方向类似，
> 但"复用已有 actor 当宿主"比"创建新 renderer actor"更省。

---

## 四、★ 核心设计二：材质完全复用游戏现有资源

`BlueprintGhostRenderer.lua` 里出现的常量与读取路径：

```lua
-- 1) 游戏自带的"建造中"占位材质
local PLACEHOLDER_MATERIAL_PATH =
    "/Game/Pal/Material/MapObject/BuildObject/BuildingProcess/"

-- 2) 从管理器读"可放/不可放"材质集
local material_set    = safe_property(manager, "BuildingSurfaceMaterialSet")
local normal_material = unwrap(safe_property(material_set, "Highlight"))  -- 允许=浅蓝
local error_material  = unwrap(safe_property(material_set, "Error"))      -- 不允许=浅红
```

### 这解答了我们最初的核心疑问

我们在 `踩坑记录.md` 3f 节记录过用户观察：
**"允许放置=浅蓝、不允许=浅红、建造中=半透明"**。

**现在确认：这三套外观都是游戏自带的材质资产，可以直接按路径取用。**

- 路径规律：`/Game/Pal/Material/MapObject/BuildObject/BuildingProcess/`
- 运行时通过 `BuildingSurfaceMaterialSet.Highlight` / `.Error` 拿到
- **完全不需要自建 pak、不需要自创材质**

> 这条是我们整条渲染路线里最大的风险点，**现在被证明不存在**。

### 还有一个有用的事实

代码里出现了 `LoadAsset(path)` —— **可以按路径运行时加载资产**。
这意味着：即使某个材质/网格没被加载，也能按需加载。

---

## 五、核心设计三：蓝图格式含"连接关系"

`BlueprintJsonSchema.lua` 的字段名显示：

```
buildings, connections, x, y, z, w
```

以及 **16 种连接信息类型**：

```
FrontConnectInfo / BackConnectInfo / LeftConnectInfo / RightConnectInfo
UpConnectInfo / DownConnectInfo / AnyPlaceConnectInfo
DiagonalConnectInfo / DiagonalUp/Down/Left/RightConnectInfo
DiagonalBackConnectInfo
CornerFrontLeft/FrontRight/BackLeft/BackRightConnectInfo
```

以及建造状态：

```
complete / failed / pending / none
```

### 对我们的启示

**蓝图不能只存"坐标 + 朝向"，还要存建筑件之间的连接关系。**

这印证了存档侧的分析（`palworld-save-tools` 里 `Model.Connector`、
`FrontConnectInfo` 等 16 个连接字段）。

**影响**：
- 我们的蓝图格式 v1 只有 `t` / `p` / `yaw` / `mesh` / `layer`
- **够用于"视觉投影"**（按绝对位置摆出来就能看）
- **不够用于"结构校验 / 自动放置"**（那需要知道哪块墙连着哪个地基）

→ 结论：**如果只做投影，v1 格式够用；要做精确校验才需要扩展。**

### 交互模式（从内存优化角度推断）

`BlueprintDeflate` + `CompactBinary` + `CodeCodec` 三个模块说明它支持
**把蓝图压成可分享的文本码**。配合它们有 Reddit 分享社区（r/PalworldSBB）——
说明这套格式是**为分享设计的**。

---

## 六、DLL 的职责边界（很重要）

我们之前误以为 DLL 参与渲染。**实际不是。**

从 DLL 内的字符串：

```
required UE4SS exports: find / getAllActors / getProperty / processEvent /
                        getWorld / spawn / destroy / getLocation / getRotation /
                        setTransform / setLocation / setRotation
?SpawnActor@UWorld@Unreal@RC@@...      ← 直接调 UWorld::SpawnActor
CheckerEvaluate
native overlap checker ready / native support checker ready
PalBuildObjectInstallStrategy*          （20+ 个安装策略类）
Steam build 24181527 / 24370881 (1.0.2) / 25094871 (1.0.4)
```

### 职责判断

| DLL 做的事 | 为什么 Lua 做不了 |
|---|---|
| **原生重叠校验**（`CheckerEvaluate`） | 需要精确调用游戏 C++ 的建造校验函数 |
| **原生支撑根**（support roots） | 同上 |
| **安装策略分派**（20+ `InstallStrategy`） | 这些是游戏内部 C++ 类，Lua 反射到不了 |
| **游戏版本适配** | 硬编码了 1.0.2 / 1.0.4 的符号偏移 |

### 关键结论

> **渲染部分完全在 Lua 里**（`world:SpawnActor` / `AddComponentByClass` /
> `StaticConstructObject` 都是 Lua 直接调用）。
>
> **DLL 只负责"建造合法性校验"这一块** —— 那是**精度要求最高、
> 且依赖游戏内部 C++ 类型**的部分。

**对我们项目的意义**：

| 功能 | 需要 DLL 吗 |
|---|---|
| 半透明投影渲染 | ❌ **不需要** |
| 移动/旋转投影 | ❌ 不需要 |
| 分层展示 | ❌ 不需要 |
| 蓝图导入导出 | ❌ 不需要 |
| **精确的"可放/不可放"判定** | ⚠️ 精简版可不用（用简单包围盒重叠判断），精确版才需要 |

→ **我们要做的核心功能，纯 Lua 都够。** DLL 只在追求"校验和游戏完全一致"时才需要。

---

## 七、它没有做的（我们的机会）

在 91 个模块里**没有看到"分层展示"相关模块**。

- 有 `BlueprintPlacementFilter.lua`（放置过滤，19 处 filter 引用）
- 但**没有 layer / 逐层显示 / 按高度切片**的功能

**这正是用户最初明确要求的功能之一**（分层展示），也是 Litematica 的核心体验。

**所以我们的差异化定位是清楚的**：

| 功能 | SBB 已有 | 我们可做 |
|---|---|---|
| 蓝图导出/导入 | ✅ 很完善 | 兼容即可 |
| 半透明投影 | ✅ | 借鉴其锚点方案 |
| 自动批量建造 | ✅ 核心卖点 | **不需要**（我们只要投影，手动放） |
| **分层/逐层显示** | ❌ | ★ **我们的差异化** |
| **按类别过滤** | ❌ | ★ |
| 精确建造校验 | ✅（DLL） | 不做 |

---

## 八、对我们的具体行动建议

### 1. 先装它用一段时间（用户侧）

它的投影体验、吸附手感、蓝图管理，都值得**实际体验**再决定我们做什么。
很可能你会发现"它其实够用了"。

### 2. 我们的渲染原型应该这样做（结合上面的认知）

```lua
-- 伪代码：我们自己的投影实现思路（独立编写）
1. FindAllOf("PalBuildObject") 找一件已放置的建筑当【锚点宿主】
   （或找到任何有 Mesh 组件的 actor）
2. 读游戏材质:
   material_set = manager.BuildingSurfaceMaterialSet
   translucent  = material_set.Highlight      -- 半透明白/蓝
   error_mat    = material_set.Error          -- 半透明红
3. 只用【已验证安全】的 Lua API:
   - world:SpawnActor(ghost_class, {}, {})     -- 需要时创建 1 个宿主
   - host:AddComponentByClass(mesh_component_class, ...)
   - component.StaticMesh = <按类型映射的网格资产>
   - component:SetMaterial(0, translucent)
   - component:K2_SetWorldLocationAndRotation(pos, rot)
4. 按蓝图数据循环设置每个组件
5. 关闭投影时: destroy / 隐藏 / 恢复
```

**关键技术点**：
- 网格资产来自类型映射表（`SM_<部件>_<材质>`，从 ImposterChunk 的 HISM 里能采到）
- 材质直接用游戏的 `Highlight` / `Error`
- **不新建 650 个 actor** —— 用少数宿主 + 多组件

### 3. 崩溃教训必须保持

上一阶段我因为裸调 `pcall(StaticFindObject, ...)` 和在**世界重载窗口**操作，
崩了用户 3 次游戏。所以：

- 一律 `pcall(function() ... end)` 闭包包裹
- 部署前必跑 `tools/luacheck.py`（全绿才行）
- **绝不在读档/重载期间操作**
- 每次只加一个新 API 调用，验证通过再加下一个

---

## 九、参考信息（不含代码）

| 项目 | 值 |
|---|---|
| Nexus mod ID | 4073 |
| 版本 | 0.16.1（2026-09-20） |
| 依赖 | `Okaetsu/RE-UE4SS` 的 `experimental-palworld` 分支 |
| 我们的 UE4SS | `v3.0.1 Beta #0 / SHA 2281fa31` — **同一个编译版** |
| 蓝图库存放 | `%LOCALAPPDATA%\SimpleBuildingBlueprints` |
| 分享社区 | https://www.reddit.com/r/PalworldSBB/ |
| 安装方式 | 解压后覆盖到游戏根目录（含 `Pal\Content\Paks\LogicMods\*.pak`） |

**安装路径结构**（从下载包实际结构读出）：

```
<下载包根>\
├─ Pal\Binaries\Win64\ue4ss\Mods\BlueprintResearch\
│  ├─ enabled.txt                        （内容只有 "enabled"）
│  ├─ BlueprintResearch.modconfig.json   （61 个配置项）
│  ├─ dlls\main.dll                      （141 KB 原生校验桥）
│  └─ Scripts\*.lua                      （91 个模块，2.4 MB）
└─ Pal\Content\Paks\LogicMods\BlueprintResearch.pak   （110 KB）
```

**包里没有自带 UE4SS**（没有 `UE4SS.dll`、没有 `dwmapi.dll`），
也没有 readme / 安装说明 —— 说明它假设你已经装好 UE4SS。

### ⚠️ 一个需要实测确认的安装疑问

下载包用的是 **`Pal\Binaries\Win64\ue4ss\`** 这个路径，
但你机器上 **UE4SS 实际在 `Mods\NativeMods\UE4SS\`**（Palworld 1.0 官方 mod 系统的部署位置）。

**这两条路径不一致。** 有两种可能：

1. 这个 mod 自带一套"UE4SS 从游戏 exe 同目录读取 mods"的约定，
   需要额外把 UE4SS 放到 `Pal\Binaries\Win64\` 下
2. 或者作者只是用了旧式打包路径，实际安装时**应该把
   `BlueprintResearch` 整个目录放到 `Mods\NativeMods\UE4SS\Mods\` 下**

**这一条我没有把握，需要你安装时验证**。建议：

- 先按 mod 页面的**安装说明**（如果 Nexus 页面上有）来
- 若只给文件不给说明，**先试方案 2**（放进现有 UE4SS 的 Mods 目录），
  因为那与你已装的 UE4SS 结构一致
- 装好后看 `UE4SS.log` 里有没有 `Starting Lua mod 'BlueprintResearch'`
  —— 有就说明路径对了
- `.pak` 文件按路径放到 `Pal\Content\Paks\LogicMods\`（这个路径应该是确定的）

> 我已经在文档里标明这是**待验证项**，不是结论。
> 之前吃过"凭推测当结论"的亏，这次明确区分开。

