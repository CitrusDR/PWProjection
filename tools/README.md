# tools/ —— 蓝图工具链

纯 Python，**不依赖游戏、不依赖 UE4SS**。可以在任何地方跑。

---

## 文件

| 文件 | 作用 |
|---|---|
| `blueprint.py` | **主力**：蓝图格式实现 —— 生成 / 校验 / 统计 |
| `selftest.py` | 自检：用合成数据验证工具链（39 项断言） |
| `luacheck.py` | **Lua 静态检查** —— 真词法器 + 块结构平衡 + 未定义调用 + **10 项专项检查** + 跨模块接口校验 |
| `luacheck_selftest.py` | 验证 luacheck 真能抓到"会崩游戏"的写法（**22/22 通过**） |
| `check_meshmap.py` | 网格覆盖表校验（含重复键、多网格、路径合法性） |
| `check_config_doc.py` | **配置说明文档检查** —— 每个 `DEFAULTS` 配置键都必须写在 `docs\配置说明.md` 里（防文档过期、防重复造开关） |
| `check_bom.py` | **BOM 检查** —— 所有 `.ps1` 必须 UTF-8 **with BOM**（PS 5.1 按 ANSI 读会让中文乱码、脚本语法崩；一天栽过两次） |
| `snap_sim.py` | **投影对齐算法验证**（合成基地 8 个场景）—— 本机没有 Lua 解释器，所以它是 `pwpr_snap.lua` 的 Python 复刻，并且会**反向读 Lua 源码**校验常量与关键结构（改了 Lua 不同步就报错）。第一版算法就是被它抓出"格状对称会把投票骗走"的（见 `docs\踩坑记录.md` §35） |
| `buildsnap_sim.py` | **建造吸附纯逻辑验证** —— `pwpr_buildsnap.lua` 的复刻（id 归一化 / 四元数↔yaw / **两种选目标方式（按距离、按准星角度锥）** / **类型对不上时的放宽 + 学到映射** / 阈值边界），同样反向读 Lua 源码防漂移。抓出过"id 归一化顺序错 ⇒ 类型永远匹配不上 ⇒ 功能完全不生效"（§39），并且**把玩家实测日志里的真实数据固化成回归用例**（§40: 游戏 id `Wooden_foundation` vs 蓝图 `Wood_Foundation`） |；**另含两道守卫**: `check_config_defaults`（读 `pwpr_config.lua` 校验吸附灵敏度/隐藏开关的默认值 —— 改了默认值没同步就红）与 `check_placed_api`（钉住 `Placed.hide_now` / `Ghost.rehide` 这些跨模块约定名） |
| `make_snapshot.ps1` | **发版快照**：核对"工作区源码 == 游戏里正在跑的那份"，打包 mod+docs+tools，并生成 SHA256 清单<br>`powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\make_snapshot.ps1 -Label "2026-09-28_跨存档投影可用版"` |
| `cleanup.ps1` | 从游戏里清掉旧 mod（PWRecon 等） |
| `pw_recon.py` | 【已过时】旧的存档解析工具，只对 0.1.4 存档有效 |
| `pw_sav_probe.py` | 【已过时】同上，零依赖结构探测 |

> `pw_*.py` 两个文件保留作历史参考。1.0 存档是 Oodle 压缩，
> 且地图对象换了新格式，这条路已被放弃（见 `docs/踩坑记录.md` 第 5 节）。

---

## Lua 静态检查（部署 mod 前必跑）

AI 无法执行 Lua，所以用静态检查代替。这不是"锦上添花"——
2026-09-26 有一次**漏检直接导致游戏崩溃**（`playerPawn` 定义被误删但调用还在）。

```powershell
$env:PYTHONIOENCODING="utf-8"

# 检查整个 mod（16 个文件，必须 0 个有问题）
python tools\luacheck.py mod\PWProjection\Scripts

# 检查工具本身有没有退化（22/22 必须通过）
python tools\luacheck_selftest.py

# 建筑吸附算法（合成数据，8/8 必须通过）—— 改了 pwpr_snap.lua 就要跑
python tools\snap_sim.py

# 建造吸附纯逻辑（id 归一化 / 四元数↔yaw / 找目标）—— 改了 pwpr_buildsnap.lua 就要跑
python tools\buildsnap_sim.py
```

**它检查什么**（详见 `docs/踩坑记录.md` 第 10、16、17 节）：

| 检查 | 为什么 |
|---|---|
| 词法分析（短字符串跨行 / 代码区非 ASCII 字符） | 抓"字符串里嵌了引号"这类引号配平查不出来的错误 |
| 块结构平衡（`function`/`if`/`for`/`while`/`do`/`repeat` ↔ `end`/`until`） | 抓少写 `end` |
| 未定义的被调用标识符 | 抓那次真实崩溃的成因 |
| 重名函数定义 | 后定义的会静默遮蔽前面的 |
| `pcall(StaticFindObject, …)` | 这个写法实测触发过原生层崩溃 |
| `local` 声明顺序 | local 只对声明之后的代码可见（真实踩过） |
| `[%w]` 紧接 `_` | `%w` 不含下划线，带下划线的名字会被**静默漏掉** |
| ★ **保留字当字段名/方法名** | `t.repeat` / `obj:end` 是**语法错误**，整个文件加载不了（真实踩过，见第 16 节） |
| ★ **禁用的反射枚举** | `ForEachProperty` / `ForEachFunction` 实测**把游戏打崩**；改用 `FindAllOf("精确类名")`（真实踩过，见第 17 节） |
| ★ **同名 local 遮蔽外层**（第 12 项，2026-09-29 新增） | `local res` 在外层已有、内层又 `local res` ⇒ 内层赋值不影响外层。**合法 Lua、不报错**，真实后果是"算完了却没生效、整个功能静默什么都不做"（见第 43 节）。正反样例在 `luacheck_selftest.py` |
| 裸 `unpack(` | Lua 5.4 里不存在，要用 `table.unpack` |
| `print()` 里有中文 | 控制台会乱码 |
| 跨模块接口（`Mod.func(...)` 是否存在） | 每个文件自己合法、连起来才错的拼写问题 |

**规矩**：改完任何 `.lua`，**先跑 luacheck 再部署**。
加了新的"真实踩过的坑"时，**同时**在 `luacheck_selftest.py` 里加正反两个样例 ——
否则检查器本身会静默退化（见 `踩坑记录.md` 10-4）。


---

## 快速验证

```powershell
$py = "C:\Users\<用户名>\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"

# 自检（20 项断言，应全部通过）
& $py tools\selftest.py

# 用真实 recon 数据生成蓝图（按基地拆分）
& $py tools\blueprint.py samples data\recon_alltypes.txt --split --outdir out\bases

# 校验
& $py tools\blueprint.py check out\bases\base_1_-1041_417.blueprint.json

# 看统计（类型分布 + 分层）
& $py tools\blueprint.py stats out\bases\base_1_-1041_417.blueprint.json
```

> **编码**：PowerShell 5.1 控制台默认不是 UTF-8，中文会乱码。
> 先执行 `[Console]::OutputEncoding=[System.Text.Encoding]::UTF8`
> 和 `$env:PYTHONIOENCODING="utf-8"`，或直接看输出文件。

---

## 三种数据入口

### 1. `raw` — 从 PWRecon 逐实例导出（**主力，A2 已完成**）

游戏内 PWRecon v0.6 的 **F8** 导出 `buildings_raw.tsv`（Tab 分隔文本）：

```
#PWBUILD|version=1|units=cm|total=649|mode=near|center=-104100.0,41700.0,68500.0|radius=150|time=...
#type	x	y	z	yaw	mesh	baseCampId	groupId	ownerId
Wood_Foundation	-161481.00	-63697.72	-942.94	-28.69	-	-	-	PalMapObjectModel_2147432823
```

> **为什么用 TSV 而不是 JSON**：从 Lua 手写 JSON 容易因转义出错且难以排查，
> TSV 简单、健壮、可以直接 `grep` / 在 Excel 里看。Python 侧负责转成正式 JSON 蓝图。

### 2. `samples` — 从 recon_alltypes.txt（旧，每类型一个样本）

只用于**验证工具链**，不是真实蓝图（`Wood_Foundation` 实际有 351 个，这里只有 1 个）。

---

## 按据点 / 坐标范围导出

这是**核心功能**——全地图建筑跨度几千米、多个据点相距几十公里，
全导出没有参考价值。

### 游戏侧：字母键（v0.7 起）

**实测 Y U H J K L 未被游戏占用**，所以每个功能有独立键，不再需要连按循环：

| 键 | 作用 |
|---|---|
| **Y** | 设定/更新**框选中心**（站到据点里按） |
| **K** / **L** | 框选半径 **+25** / **-25** 米 |
| **J** | 导出**框选框内**建筑 ← **推荐用法** |
| **H** | 导出**玩家附近**（半径 = 当前框选半径） |
| **U** | 导出**全部**建筑（649 个，范围很大） |
| `F7` | 帮助 |

**推荐流程**：站到据点中心 → 按 `Y` → 按 `K`/`L` 调半径 → 按 `J` 导出

> ⚠️ `baseCampId` / `groupId` **实测读不到**（全是 `-`），
> 所以**无法按据点精确导出**，只能靠坐标聚类或玩家位置筛选。
> 详见 `docs/踩坑记录.md` 3h 节。

### 工具侧：对已有数据做精确筛选

筛选参数**按顺序生效**：`--camp → --match → --box → --radius → --limit`

```powershell
$py = "C:\Users\<用户名>\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
$raw = "data\buildings_raw.tsv"

# 1) 看数据概况（baseCampId 若为空会提示改用坐标筛选）
& $py tools\blueprint.py camps $raw

# 2) 按坐标范围（米）—— 注意负数必须用 --box= 形式！
& $py tools\blueprint.py raw $raw --box=-106000,41000,600,-100000,45000,800 -o out\area.json

# 3) 按半径（围绕某点）
& $py tools\blueprint.py raw $raw --center -104100,41700,685 --radius 120 -o out\near.json

# 4) 只要最近的 N 个
& $py tools\blueprint.py raw $raw --limit 50 -o out\small.json

# 5) 按位置聚类自动拆成多个据点（baseCampId 不可用时的主力方案）
& $py tools\blueprint.py raw $raw --split --by cluster --threshold 60 --outdir out\clusters

# 6) 先筛再拆
& $py tools\blueprint.py raw $raw --limit 500 --split --by cluster --outdir out\sub
```

> ⚠️ **已知限制**：坐标是负数时，`--box -106000,...` 会被 argparse 当成选项名而报错。
> **必须写成 `--box=-106000,...`**（带等号）。自检里专门有一条断言记录这个行为。

---

## 子命令一览

| 子命令 | 作用 |
|---|---|
| `raw <输入>` | 从 TSV/JSON 生成蓝图（**支持全部筛选参数**） |
| `camps <输入>` | 列出数据里包含的据点及各自建筑数/范围 |
| `samples <输入>` | 从 recon_alltypes.txt 生成（仅工具链验证） |
| `check <蓝图>` | 校验蓝图 |
| `stats <蓝图>` | 打印统计（类型分布 + 分层） |



---

## 自检覆盖了什么

`selftest.py` 用合成数据（默认 800 实例 / 60 类型 / 3 基地）验证 **39 项断言**：

| 类别 | 断言 |
|---|---|
| 生成 | 退出码、文件产出 |
| 数量守恒 | 实例数守恒、`meta.total` 一致、**类型分布守恒** |
| 坐标 | 往返误差 ≤ 2cm、包围盒尺寸一致、**中心化**（±size/2） |
| 分层 | 层数合理、层号与高度单调 |
| Yaw | 全部在 -180..180 |
| 校验器（正向） | 完整蓝图通过 |
| 校验器（负向） | **能发现** total 不符 / 坐标缺失 / 单位错误 / stats 不符 / format 错误 |
| 拆分 | 多基地拆分且每个子蓝图都通过校验 |
| **TSV 解析** | 实例数守恒、厘米→米换算、生成的蓝图通过校验 |
| **筛选** | `camps` 列据点、`--camp` 精确性+紧凑性、`--box` 边界、`--radius` 尺寸受控、`--limit`、`--by camp` 拆分后**总数守恒** |

**负向测试很重要**：它证明校验器不是"永远返回通过"。

压测：

```powershell
& $py tools\selftest.py --instances 5000 --types 120 --bases 6
```


---

## 输出目录

```
out/
├─ sample-all.blueprint.json           # 全类型样本（79 条）
├─ bases/
│  ├─ base_1_-1041_417.blueprint.json  # 主基地，59 种类型，61×61×3 米
│  ├─ base_2_-1612_-612.blueprint.json # 9 种
│  ├─ base_3_-3463_2630.blueprint.json # 6 种
│  ├─ base_4_-2767_2060.blueprint.json # 4 种
│  └─ base_5_-6334_-3020.blueprint.json# 1 种（孤立建筑）
└─ selftest-tmp/                       # 自检临时文件
```

**基地是靠位置聚类自动分出来的**（单链聚类，阈值 60 米）——
因为目前没有可靠的"建筑属于哪个基地"字段。
实测结果很干净：主基地内 59 种类型挤在 61×61 米内，彼此间隔远超阈值。

---

## `secret_scan.py` —— 提交前的密钥 / 凭据审计

```powershell
python tools\secret_scan.py            # 在仓库根目录跑
```

**为什么有它**：仓库以后可能公开，而"密钥被提交"这种事**一旦推送就很难收回**
（历史里的对象还会被克隆走）。所以提交前扫一遍。

**它扫四个地方**：

| # | 范围 | 说明 |
|---|---|---|
| 1 | **git 跟踪的文件** | 这些才是会真正被上传的内容（最重要） |
| 2 | 未跟踪、也没被 `.gitignore` 忽略的文件 | 将来可能被 `git add` 进去 |
| 3 | 被 `.gitignore` 忽略的文件 | 不会上传，只列数量 |
| 4 | **git 历史**（所有提交的完整内容） | 提交过、后来删掉的也会留在这里 |

**检查项**：OpenAI/DeepSeek 风格 key（`sk-…`）、Anthropic、Google API key、
AWS Access Key、GitHub/Slack token、私钥文件内容（`BEGIN … PRIVATE KEY`）、JWT、
`api_key = …` 之类赋值、`Bearer` 头、URL 内嵌凭据、邮箱地址、
"32+ 位十六进制串"（**这条会误报**：SHA256 校验值也会命中）。

**怎么读结果**：

- `32+ 位十六进制串` 命中 `backups\...\校验清单.txt` 或 `docs\踩坑记录.md`
  → 那是**校验值 / 存档目录 GUID**，不是密钥，可以忽略；
- `邮箱地址` **只在"git 历史"那一节**命中 → 那是 **commit 的作者信息**
  （`Author: 名字 <邮箱>`），不是文件内容；要处理得改 `git config user.email`
  并重写提交，而不是改文件；
- 其它任何命中 → **当成真泄露处理**：先从工作区删掉，再把文件名加进 `.gitignore`。

> ⚠️ 它只是**辅助**：命中不等于泄露，没命中也不等于安全（新格式的密钥不在模式里）。

---

## 相关文档

- [蓝图格式规范](../docs/蓝图格式.md) —— 字段定义、坐标系约定、校验规则
- [屏幕提示功能](../docs/屏幕提示功能.md) —— 游戏内提示的实现、配置与排查
- [项目状态与路线图](../docs/项目状态与路线图.md)
- [踩坑记录](../docs/踩坑记录.md)
