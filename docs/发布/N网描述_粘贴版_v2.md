## PWProjection — Blueprint Projection for Palworld

Capture your base into a blueprint, project it as a translucent blue hologram in any save, and
rebuild it piece by piece — every piece automatically snaps to its hologram position the moment you
place it, and placed pieces disappear from the hologram immediately.

### Features

- **Capture** — stand inside a base and press **Y**; buildings are saved into a plain-JSON blueprint you can back up, edit or share.
- **Project** — press **J** to load a blueprint, **K** to place / hide the blue hologram.
- **Build snap** — no extra key needed. Place a building normally and it lands exactly on the matching hologram position (position, rotation and height).
- **Height auto-fit** — on water or uneven terrain the projection moves itself to the height the game actually allows and calibrates once per site, so foundations can be stacked.
- **Layer view** — press **L** to inspect the blueprint layer by layer (handy for interiors and roofs).
- **Already-built pieces are hidden** — pieces you have already placed are automatically removed from the hologram, and they come back if you demolish them.
- **Placement memory** — the mod remembers, per blueprint, where each projection was placed and how far you got; re-open the blueprint near that site and it continues where you left off.
- **In-game settings page** (optional) — key bindings, capture radius, nudge step, rotation step and layer gap can be changed in **Esc → Mod Options** (requires the Mod Options Framework).

### Requirements

- **UE4SS** (RE-UE4SS / UE4SS Experimental) — this is a Lua script mod and will not load without it.
- Palworld 1.0.x (Steam). Multiplayer is untested.
- Optional: **Mod Options Framework** — adds the in-game settings page. Without it everything still works through Scripts\pwpr_config.json.

### Installation (manual)

1. Install UE4SS.
2. Extract the **PWProjection** folder from the archive into **<Palworld>\Mods\NativeMods\UE4SS\Mods\PWProjection\** — the folder must contain Scripts\main.lua.
3. Add this line to **<Palworld>\Mods\NativeMods\UE4SS\Mods\mods.txt** → **PWProjection : 1**
4. Restart the game, enter a world and press **N** once (capability probe — required the first time).

**Workshop / Vortex users:** subscribe (or let Vortex install it), then enable it in the game's own **Mod Management** menu — no manual file copying needed.

### Keys

- Always available: **N** probe · **Y** capture · **J** load blueprint · **K** projection on/off · **L** layer.
- Unbound by default (bind them in the in-game settings page): **H** re-center the projection, **U** cycle placement sites, **F9** arrow-key mode, **F7** help/status, **F8** reload config.
- Numpad 8/2/4/6/9/3 nudge, +/- rotate, 5 reset, 0 change step — optional aliases.

### Known issues

- **Do not spam Save right after rebinding a key.** Each Save reloads this mod, and rebinding can put the settings framework into a reload loop (measured ~0.44 s per round), which may freeze the game after a few dozen rounds. Save **once**, wait for it to apply, then edit the next entry. Saving with **no changes** is harmless (no reload happens). If it freezes, end the process and relaunch — your configuration, key bindings and build progress are never lost.
- To avoid it entirely, add **"options_apply_mode": "game_restart"** to Scripts\pwpr_config.json — Save then stops reloading the mod and simply asks you to restart the game.
- A rare crash has been observed (a dump is written to Mods\NativeMods\UE4SS\crash_*.dmp). If it happens to you, please report it with that dump plus Scripts\pwpr.log.

### Credits

- **UE4SS** — the Lua runtime this mod runs on (not bundled).
- **Mod Options Framework** by **Elvlin** (MIT) — the in-game settings page; two SDK files are redistributed under its MIT license (see the third_party folder in the archive).
- Architecture informed by **Simple Building Blueprints (SBB)** — read-only reference, no code or strings reused.

### Video

- Demo (Chinese, bilibili): [【幻兽帕鲁】建筑投影模组（PWProjection）功能演示](https://www.bilibili.com/video/BV1PHHy6pEnz/)

### Source and license

- Author: **CitrusDR** (bilibili: **柑橘味快乐水**) — source: [github.com/CitrusDR/PWProjection](https://github.com/CitrusDR/PWProjection)
- License: **MIT** — free to use, modify and redistribute with attribution.

---

## PWProjection —— 建筑投影（Litematica 风格）中文说明

把基地采集成蓝图，在任何存档里以半透明蓝色全息投影显示出来，然后一件一件重建 ——
你放下建筑的那一刻，它会自动吸附到投影对应的位置；已经放好的那一件会立刻从投影里消失。

### 功能

- **采集 → 蓝图**：站进基地按 **Y**，把建筑存成纯 JSON 蓝图，可备份、可编辑、可分享。
- **投影**：按 **J** 加载蓝图，按 **K** 放下 / 收起蓝色投影。
- **建造吸附**：不需要额外按键。正常放置就行，位置 / 朝向 / 高度都会对到投影上。
- **高度自适应**：水面或特殊地形上，投影会自动挪到游戏允许的高度，并按"处"校准一次，所以叠在地基上的建筑也放得下去。
- **分层显示**：按 **L** 一层一层看蓝图（做室内、屋顶很方便）。
- **已放好的不再画**：已经建好的部分自动从投影里去掉；拆掉它会自动恢复显示。
- **位置与进度记忆**：按蓝图记住"上次投影放在哪、已经建到哪"；在附近重新打开蓝图会自动接着上次的进度。
- **游戏内设置页**（可选，需 Mod Options Framework）：改键、采集半径、微调步长、旋转步长、分层间距都能在 **Esc → 模组选项** 里改。

### 前置要求

- **UE4SS**（RE-UE4SS / UE4SS Experimental）—— 本模组是 Lua 脚本，没有它不会加载。
- 幻兽帕鲁 1.0.x（Steam 版）。联机未验证。
- 可选：**Mod Options Framework** —— 提供游戏内设置页；没装也能用，改 Scripts\pwpr_config.json 即可。

### 安装（手动）

1. 先装好 UE4SS。
2. 把压缩包里的 **PWProjection** 文件夹放到 **<帕鲁目录>\Mods\NativeMods\UE4SS\Mods\PWProjection\**（里面要有 Scripts\main.lua）。
3. 在 **<帕鲁目录>\Mods\NativeMods\UE4SS\Mods\mods.txt** 里加一行：**PWProjection : 1**
4. 重启游戏 → 进世界 → **按一次 N**（渲染能力探测，第一次必须跑）。

**创意工坊 / Vortex 用户**：订阅（或让 Vortex 装）之后，在游戏自带的模组管理里启用即可，不用手动拷文件。

### 按键

- 始终可用：**N** 探测 · **Y** 采集 · **J** 加载蓝图 · **K** 投影开/关 · **L** 分层。
- 默认不绑定（想用就在设置页里设）：**H** 重新定位到脚下 · **U** 换一处放置记录 · **F9** 方向键模式 · **F7** 帮助/状态 · **F8** 重载配置。
- 小键盘 8/2/4/6/9/3 微调、+/- 旋转、5 复位、0 换步长 —— 可选别名，没有小键盘也不影响。

### 已知问题

- **改键之后不要快速连点"保存"**：每次保存都会重载本模组，而改键这条路会让设置框架反复重载（实测约 0.44 秒一轮），几十轮后游戏可能卡死。改完点一次保存、等它生效再改下一项；不改内容时随便点（不会重载）。万一卡住：结束进程重开即可 —— 配置、键位、建造进度都不会丢。
- 想彻底避开：在 Scripts\pwpr_config.json 里加 **"options_apply_mode": "game_restart"** —— 保存不再重载，只提示"请重启游戏"。
- 偶发崩溃：如果游戏崩了，请把 Mods\NativeMods\UE4SS\crash_*.dmp 和 Scripts\pwpr.log 一起反馈，仍在排查。

### 致谢

- **UE4SS** —— 本模组运行的 Lua 运行时（未随包分发）。
- **Mod Options Framework**（作者 **Elvlin**，MIT）—— 提供游戏内设置页；按它的 MIT 许可，包内 third_party 文件夹里转发了两个 SDK 文件。
- 架构参考了 **Simple Building Blueprints (SBB)** —— 只读参考，没有复用任何代码或字符串。

### 视频演示

- bilibili：[【幻兽帕鲁】建筑投影模组（PWProjection）功能演示](https://www.bilibili.com/video/BV1PHHy6pEnz/)

### 源码与许可

- 作者：**CitrusDR**（bilibili：**柑橘味快乐水**）— 源码：[github.com/CitrusDR/PWProjection](https://github.com/CitrusDR/PWProjection)
- 许可：**MIT** —— 可自由使用、修改、转载，保留署名即可。

---

<!-- ↓↓↓ 下面两段是 2026-10-08 补的（N 网版缺这两节，工坊版有）↓↓↓
     粘贴时把它们插到各自语言的 “Keys / 按键” 一节之后，并删掉本注释行 -->

### Known limitations (by design)

- The hologram does **not** follow you while building — it stays where you placed it (press `H` to re-center it under your feet).
- Demolished pieces come back into the hologram automatically, but they are **not** removed from the build-progress record automatically in every case — re-open the projection to resync.
- For assembled structures (generators, production machines) only the main body is drawn.
- The `blueprint` capture mode for whole bases is not finished yet; use the normal capture.
- Multiplayer is untested.

### Troubleshooting

- **A key does nothing** — it may be unbound: bind it in **Esc → Mod Options → PWProjection** (`N` is bound by default; `H`/`U`/`F7`/`F9` are not). After rebinding, save **once** and restart the game if keys stop responding.
- **Placement does not snap** — check `Scripts\pwpr.log` for `[bsnap]` lines; they state the reason (too far / type mismatch / rejected by the game). Most common: the projection itself is mis-placed ⇒ press `H`.
- **The projection disappeared after saving settings** — saving reloads the mod; press `J` + `K` again. Build progress for that site is restored automatically.
- Full diagnostics go to `Scripts\pwpr.log` (every line is timestamped and in Chinese/English mixed). Attach it when reporting a bug.
