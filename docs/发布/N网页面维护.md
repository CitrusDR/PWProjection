# N 网页面维护笔记（PWProjection）

> 记录 2026-10-08 首次发布（<https://www.nexusmods.com/palworld/mods/5899>）时踩到的坑与固定做法。
> 下次更新版本时照这份走即可。

## 1. 🔴 格式：N 网是 **Markdown/WYSIWYG**，工坊是 **BBCode**，两边不能混用

| 平台 | 描述格式 | 注意事项 |
|---|---|---|
| **Steam 创意工坊** | **BBCode** | `[b]` `[list]` `[size=4]` `[code]` `[url=]` —— 文案见 `页面文案.md` 的工坊段 |
| **Nexus Mods** | **Markdown**（富文本编辑器）| `**粗体**` `### 标题` `- 列表` `[文字](链接)` |

**实测踩到的两个坑:**

1. 把 BBCode 粘进 N 网 ⇒ **`[list]` `[b]` `[size=4]` `[code]` 全部原样显示**，页面看起来很乱 ✗；
   而且 N 网的向导会把 `[code]` 块**抠成一个个独立输入框**（"Add this line to"那种）✗
2. **行内反引号 `` ` `` 会被渲染成独立的灰色代码块** ⇒ 安装说明里的路径被切碎
   （例："（里面要有" 和 "）。" 被拆到两个灰框里）✗✗

**⇒ 结论:** N 网的粘贴文案 **不要用行内反引号** —— 路径写成**纯文本**或**加粗**。
粘贴版文案: **`N网描述_粘贴版_v2.md`**（英文 + 中文合一，无反引号，实测渲染正常 ✓）

## 2. 页面字段清单（首次发布时已确认）

- **Title** = `PWProjection - Blueprint Projection (Litematica style)`
- **Summary** ≤350 字符（我们用的那句 = 287 字符；**会显示在列表页和页面"About this mod"里**）
- **Category** = `Gameplay`；**Tags** = `Gameplay` / `Utilities for Players` / `Chinese` / `AI-Generated Content`
- **Requirements** = `UE4SS (RE-UE4SS)` + `Mod Options Framework (optional)`
  （"Mod requirements (legacy)" 那条路靠 N 网搜索接口，会报
  `Something went wrong. Please try again.` ⇒ 改用 **`External resources`** 填名称 + URL 更稳）
- **Permissions**：目前是**偏保守**的一套（上传=禁止任何站点转载 / 修改=必须先问我 /
  素材=需向作者申请）。注意这与 **MIT** 略有出入（MIT 本身就允许转载与修改，署名即可）；
  想一致就把"修改/上传"放宽成"需先询问"或"带署名即可" —— 不影响使用。
- **File credits**：已写明两个 SDK 文件来自 Mod Options Framework（MIT）+ 仓库与许可链接 ✓
- **Files**：1 个主文件 `PWProjection 1.0.5`（353 KB，Virus scan = Safe to use ✓）

## 3. 以后更新版本的流程

1. 改代码 → 跑检查器 → 改 `mod\PWProjection\workshop\Info.json` 的 `Version`
2. `powershell -NoProfile -ExecutionPolicy Bypass -File D:\dsh-workspace\palworld-litematica\tools\make_release.ps1`
   （同名版本要重打就加 `-Force`）
3. **工坊**：Palworld Mod Uploader → `Upload To Steam`（同一个条目）+ 填 Change Notes
4. **N 网**：`Manage files` → `Upload new version` → 填版本号 + changelog → 勾 **Archive existing file**
5. 两边都跟 `docs\发布\更新日志.md`（N 网包里叫 `CHANGELOG.md`）保持同一套说明

## 4. 已知问题（已写进描述与更新日志）

**改键之后不要快速连点保存**：每次保存都会重载本模组，改键这条路会让设置框架反复重载
（实测约 0.44 秒一轮），几十轮后游戏可能卡死。改完点一次、等生效再改下一项；
不改内容时随便点（不会重载）。卡住就结束进程重开，**配置/键位/进度都不会丢**（已实测验证）。
彻底避开：`Scripts\pwpr_config.json` 里加 `"options_apply_mode": "game_restart"`。

## 5. N 网权限（Permissions）各项建议值（2026-10-08 定稿）

> 这些字段约束的是**别的作者**能拿我们的文件做什么，**跟玩家使用完全无关**（玩家照常下载安装）。
> 我们的 `LICENSE` 是 **MIT** ⇒ 严格说"转载/修改/使用都允许（署名即可）"；
> 但 N 网上常见做法是保留一部分控制权。下面这套是"**与 MIT 一致 + 保留一点控制权**"的折中。

| 字段 | 建议值 | 理由 |
|---|---|---|
| **Re-upload**（别人转到其它站点）| `Ask me`（或 `Allowed (Credit required)`）| MIT 本来就允许转载；选 Ask me 保留控制权也不违反 MIT |
| **Conversion (other games)** | `Not allowed` | 本模组是帕鲁专用，移植到别的游戏没实际意义 |
| **Modification**（别人改我们的文件）| `Ask me`（或 `Allowed (Credit required)`）| MIT 允许修改；Ask me 是常见折中 |
| **Asset use**（别人用我们文件里的素材/代码）| **`Allowed (Credit required)`** ✅ | 我们的代码是 MIT；包内两个 SDK 文件也是 **Elvlin 的 MIT**（File credits 已署名）⇒ 带署名允许最贴合事实 |
| **Earning donation points (using assets)** | `Not allowed`（保守，可留默认）| 与上一条配套；对玩家无影响 |
| **Monetisation (third-party)** | `Not allowed` | 与"商用 = 否"的既有决定一致 ✓ |

**页面上的三个模式**: `Use recommended settings`（N 网推荐预设 = 上表里除 Asset use 外基本一致）、
**`Pick your own`**（我们用的）、`Write your own (custom)`（自己写一套）。
右上还有 **`Import permissions`**：可以把你在**别的 mod** 上设过的权限一键套过来。

**改完记得点底部 `Save`**；页面已发布（`✓ Published`）时，Save 会立刻生效，不需要重新发布。

## 6. 描述里的语言顺序（2026-10-08 调整）

**建议英文在前、中文在后**（页面首屏是英文）：
* N 网用户以英文为主，首屏英文更友好；
* 纯中文/中文在前的页面对审核与浏览都不利。
⇒ 直接**整段替换**成 `N网描述_粘贴版_v2.md`（该文件本身就是"英文段 + 分隔线 + 中文段"的顺序）✓
