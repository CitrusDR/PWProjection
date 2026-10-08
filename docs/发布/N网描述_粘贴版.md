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
- Optional: **Mod Options Framework** — adds the in-game settings page. Without it everything still works through `Scripts\pwpr_config.json`.

### Installation (manual)

1. Install UE4SS.
2. Extract the **PWProjection** folder from the archive into `<Palworld>\Mods\NativeMods\UE4SS\Mods\PWProjection\` — the folder must contain `Scripts\main.lua`.
3. Add this line to `<Palworld>\Mods\NativeMods\UE4SS\Mods\mods.txt`: `PWProjection : 1`
4. Restart the game, enter a world and press **N** once (capability probe — required the first time).

**Workshop / Vortex users:** subscribe (or let Vortex install it), then enable it in the game's own **Mod Management** menu — no manual file copying needed.

### Keys

- Always available: **N** probe · **Y** capture · **J** load blueprint · **K** projection on/off · **L** layer.
- Unbound by default (bind them in the in-game settings page): **H** re-center the projection, **U** cycle placement sites, **F9** arrow-key mode, **F7** help/status, **F8** reload config.
- Numpad 8/2/4/6/9/3 nudge, +/- rotate, 5 reset, 0 change step — optional aliases.

### Known issues

- **Do not spam Save right after rebinding a key.** Each Save reloads this mod, and rebinding can put the settings framework into a reload loop (measured ~0.44 s per round), which may freeze the game after a few dozen rounds. Save **once**, wait for it to apply, then edit the next entry. Saving with **no changes** is harmless (no reload happens). If it freezes, end the process and relaunch — your configuration, key bindings and build progress are never lost.
- To avoid it entirely, add `"options_apply_mode": "game_restart"` to `Scripts\pwpr_config.json`: Save then stops reloading the mod and simply asks you to restart the game.
- A rare crash has been observed (a dump is written to `Mods\NativeMods\UE4SS\crash_*.dmp`). If it happens to you, please report it with that dump plus `Scripts\pwpr.log`.

### Credits

- **UE4SS** — the Lua runtime this mod runs on (not bundled).
- **Mod Options Framework** by **Elvlin** (MIT) — the in-game settings page; two SDK files are redistributed under its MIT license (see `third_party\` in the archive).
- Architecture informed by **Simple Building Blueprints (SBB)** — read-only reference, no code or strings reused.

### Video

- Demo (Chinese, bilibili): [【幻兽帕鲁】建筑投影模组（PWProjection）功能演示](https://www.bilibili.com/video/BV1PHHy6pEnz/)

### Source and license

- Author: **CitrusDR** (bilibili: **柑橘味快乐水**) — source: [github.com/CitrusDR/PWProjection](https://github.com/CitrusDR/PWProjection)
- License: **MIT** — free to use, modify and redistribute with attribution.
