# PWProjection — Installation & Usage (English)

> Palworld blueprint **projection** mod (Litematica-style): **capture** a base into a blueprint,
> **project** it as a translucent blue hologram in any save, build it back piece by piece —
> and each piece **auto-snaps to the matching hologram position** the moment you place it
> (placed pieces disappear from the hologram immediately).
>
> Made by **CitrusDR** (bilibili: **柑橘味快乐水**) · Source / issues:
> <https://github.com/CitrusDR/PWProjection> · Demo video (Chinese):
> <https://www.bilibili.com/video/BV1PHHy6pEnz/>

---

## 1. Requirements

| | |
|---|---|
| Game | **Palworld 1.0.x** (Steam) |
| Required | **UE4SS** (this mod runs inside UE4SS's Lua environment) |
| Recommended | **Mod Options Framework** — adds an in-game settings page (Esc → Mod Options) for rebinding keys and editing numbers |

> This mod does **not** bundle UE4SS or any other mod.

## 2. Installation

### A. Steam Workshop (easiest)

1. Subscribe to **UE4SS Experimental (Palworld)** (declared dependency, usually installed together).
2. Subscribe to **PWProjection**.
3. In game: **Options → Mod Management → Enable Mod = ON**, tick the mods, **Save** (game restarts).
4. In-world, press **`N`** once to run the capability probe — **required the first time**; it unlocks projection automatically.

### B. Manual (zip from Nexus / GitHub)

1. Install UE4SS first.
2. Put the **`PWProjection`** folder here:

   ```
   <Palworld>\Mods\NativeMods\UE4SS\Mods\PWProjection\
   ```

   (i.e. `...\Mods\PWProjection\Scripts\main.lua` must exist)
3. Add this line to **`<Palworld>\Mods\NativeMods\UE4SS\Mods\mods.txt`** (name must match the folder):

   ```
   PWProjection : 1
   ```
4. Restart the game, enter a world, press **`N`** once.

> 🧹 **Uninstall**: remove that `mods.txt` line (or set it to `0`) and delete the `Mods\PWProjection` folder.
> Keep `Scripts\pwpr_config.json` / `pwpr_keys.json` / `pwpr_placements.json` if you want your settings and build progress.

## 3. First run (order matters)

```
1. Get in-world and able to walk around (do NOT press anything during loading screens)
2. Press N       -> capability probe; on success projection is unlocked automatically
3. Stand in your base, press Y   -> capture buildings into a blueprint
4. Press J       -> load a blueprint (press again to cycle)
5. Press K       -> place / hide the projection (translucent blue)
6. Enter build mode and place pieces normally -> they snap to the hologram on placement
```

**Always-available keys**: `N` probe · `Y` capture · `J` load blueprint · `K` projection on/off · `L` layer

**Other actions are unbound by default** (`H` re-center the projection, `U` cycle placement sites,
`F9` arrow-key mode, `F7` help/status …). Bind the ones you want in
**Esc → Mod Options → PWProjection** (requires Mod Options Framework) and click Save.
Without the framework those actions use the defaults from `pwpr_config.json`
(`H` / `U` / `F9` / `F7` / `F8` work out of the box).

Key/config changes: a **game restart is recommended** after rebinding or saving settings (clicking Save in the panel only *reloads the mod*; the framework's own key-capture bindings may then sit on our keys and nothing responds). `F8` reloads only `pwpr_config.json`.
Saving settings also clears the loaded blueprint and the placed projection — press `J` + `K` again
(build progress for that site resumes automatically).

⚠️ **Known issue — after rebinding a key, rapidly clicking Save can freeze the game.**
Each Save *reloads this mod*, and the rebind path makes the settings framework re-apply values
repeatedly ⇒ a reload loop (measured ~0.44 s per round; the game froze after a few dozen rounds).
* **Safe usage**: save **once** after a rebind, wait for it to apply before editing the next entry.
  Saving with **no changes** is harmless (no reload happens — 20–30 clicks in a row are fine).
* **If it freezes**: kill the process and relaunch. `pwpr_config.json` / `pwpr_keys.json` /
  `pwpr_placements.json` / `pwpr_meshmap.json` are **never lost** (verified on a real Workshop update).
* **To avoid it entirely**: add `"options_apply_mode": "game_restart"` to
  `Scripts\pwpr_config.json` ⇒ Save no longer reloads the mod, it just asks you to restart the game
  (all features still work; changes apply after a restart).

## 4. Troubleshooting

| Symptom | Fix |
|---|---|
| Pressing `K` says projection is locked | Press **`N`** once (probe unlocks it); make sure `ghost_enabled` was not manually set to false |
| `N` / `H` / `U` do nothing | They may be **unbound**: bind them in **Esc → Mod Options → PWProjection** (`N` is bound by default, `H`/`U` are not) |
| No snapping when placing | Check `Scripts\pwpr.log` for `[bsnap]` lines — they state the reason (too far / type mismatch / gate / rejected by game). Most common: the projection itself is mis-placed ⇒ press `H` |
| Placed piece is still flickering with the hologram | Press `F7` for status; tune `ghost_hide_placed_cm` |
| Which build am I running? | First line of `pwpr.log` (`构建标记:`) |
| Where is the log? | `<Palworld>\Mods\NativeMods\UE4SS\Mods\PWProjection\Scripts\pwpr.log` — **attach it when reporting issues** |
| Reset remembered positions/progress | Close the game, delete `Scripts\pwpr_placements.json` (all) or use `tools\resume_tool.py` (per blueprint / per site) |

## 5. Known limitations (by design, not bugs)

* The game's own translucent **preview** does not snap — only the **actually placed** piece is snapped
  (the engine preview cannot be driven from Lua);
* **Removing a building does not restore its hologram** (that auto-scan crashed the game in testing; disabled by default)
  ⇒ press `K` twice to re-place the projection;
* **Multi-part assemblies render as their main part only** (logging camp, quarry, …);
* **`blueprint` mode is unfinished** (config warns if enabled) ⇒ use the default `align`;
* **Multiplayer is untested**.

## 6. License & credits

* This mod: **MIT** (see `LICENSE`).
* **UE4SS** — provides the Lua runtime (not bundled).
* **Mod Options Framework** by **Elvlin** (MIT) — in-game settings page; two SDK files
  (`PalModOptionsClient.lua`, `pmo_json.lua`) are redistributed as documented in `third_party\`.
* Architecture was informed by **Simple Building Blueprints (SBB)** — **read-only reference, no code or strings reused**.
