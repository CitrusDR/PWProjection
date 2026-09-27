# Palworld 蓝图投影模组

> ## 📌 新会话从这里开始
>
> **要把工作交给全新的 AI 会话？** 直接把
> **[docs/新会话提示词.md](docs/新会话提示词.md)** 整段复制给它即可。
>
> 自己读的话，按这个顺序：
>
> | 顺序 | 文件 | 作用 |
> |---|---|---|
> | 1 | **[docs/交接笔记.md](docs/交接笔记.md)** | **最该先读**：做到哪、下一步、未确认的点、文件清单 |
> | 2 | [docs/项目状态与路线图.md](docs/项目状态与路线图.md) | 目标、技术选型、进度、完整路线图、风险清单 |
> | 3 | [docs/踩坑记录.md](docs/踩坑记录.md) | **26 节实测结论与坑**（最重要的一份，46KB） |
> | 4 | [docs/蓝图格式.md](docs/蓝图格式.md) | 蓝图格式规范 v1 |
> | 5 | [tools/README.md](tools/README.md) | 工具用法 |
>
> **开工前先跑环境诊断**（5 秒）：
> ```
> powershell -ExecutionPolicy Bypass -File diag\diag-ue4ss.ps1
> ```
>
> **进度**：阶段 0（侦察）✅ · 阶段 1（蓝图格式+工具链）✅ ·
> **阶段 2（自研 mod）✅ 代码完成，等实机验证** ——
> `mod/PWBlueprint/` 已写好 14 个 Lua 模块，静态检查全绿（含 10 项 linter 自检）。
> **下一步：部署 → 按 N 跑能力探测 → 把 `pwbp.log` 发回来。**
>
> ⚠️ 已决定**自己写、不复用 Simple Building Blueprints 的代码**
> （SBB 只作架构参考），理由见 [docs/改造SBB可行性评估.md](docs/改造SBB可行性评估.md)。

---

## 目录结构

```
palworld-litematica/
├─ docs/                      文档（先读交接笔记）
│  ├─ 交接笔记.md             ← 新会话从这里开始
│  ├─ 项目状态与路线图.md
│  ├─ 踩坑记录.md             ← 26 节实测结论
│  └─ 蓝图格式.md
├─ tools/                     纯 Python 工具链（不依赖游戏）
│  ├─ blueprint.py            蓝图生成/校验/统计/筛选
│  ├─ selftest.py             自检 39 项断言
│  ├─ luacheck.py             ← Lua 静态检查（真词法器 + 块平衡）
│  ├─ luacheck_selftest.py    ← 验证 luacheck 真能抓到会崩游戏的写法（10/10）
│  ├─ cleanup.ps1             从游戏里清掉旧 mod
│  └─ README.md
├─ mod/PWBlueprint/            ★ 当前主线：蓝图投影 mod
│  ├─ Scripts/*.lua           14 个模块（含 pwbp_probe / pwbp_ghost）
│  ├─ deploy.ps1              一键部署（幂等，会顺手清理废弃 mod）
│  └─ README.md               ← 用法、按键、配置、安全设计
├─ mod/PWRecon/                （已退役，保留供追溯）
├─ diag/                      环境诊断
│  ├─ diag-ue4ss.ps1          ← 开工前先跑这个
│  └─ 修复说明.md
├─ data/                      从游戏导出的原始数据
│  ├─ recon_alltypes.txt      79 种类型清单（mesh 映射表基础）
│  ├─ buildings_raw.tsv       主基地 358 建筑
│  └─ buildings_raw_base2.tsv 第二据点 35 建筑
├─ out/                       生成的蓝图
└─ archive/                   已过时的工具（保留供追溯）
```

> 关于 SBB：`SimpleBuildingBlueprints 4073 .../` 是用户下载的第三方 mod，
> **只用于阅读架构**（分析结论见 [docs/SBB架构分析.md](docs/SBB架构分析.md) 和
> [docs/改造SBB可行性评估.md](docs/改造SBB可行性评估.md)），**代码不复用、不分发**。

---

## 这个项目在做什么

给 Palworld 做一个 **Litematica 式的建筑投影模组**：
把建筑蓝图以半透明形式投影到世界里，方便照着摆放方块。

| 功能 | 状态 |
|---|---|
| 添加/导出蓝图 | ✅ 已实现（**游戏内直接导出 JSON**，`mod/PWBlueprint` 按 Y/U） |
| 加载蓝图 | ✅ 已实现（蓝图库 + `J` 循环切换） |
| 半透明投影 | ✅ **代码完成**（`pwbp_ghost.lua`，受能力探测门禁保护） |
| 移动投影 | ✅ **代码完成**（小键盘前后左右/上下/旋转，见 mod README） |
| 分层展示 | ✅ **代码完成**（`L` 键循环，这是 SBB 没有的功能） |
| 自动建造 | ❌ 明确不做（那是 SBB 的功能，本 mod 只做投影） |

**技术路线**：UE4SS + Lua（不用 PMK/C++），因为 Lua 是纯文本、AI 可参与开发，
且游戏内已有可参考的先例（FirstPerson mod、Simple Building Blueprints）。

---

## 历史说明（已过时，保留供追溯）

> 早期尝试过"离线解析存档"这条路：实测 1.0 存档头部是 `PlM1`（**Oodle 压缩**，
> 不是 zlib），且地图对象换成了带 pickup guard 的新格式，链路太长太脆。
> **已放弃，改为 UE4SS 读运行时内存。**
>
> 相关工具已移到 `archive/`。

