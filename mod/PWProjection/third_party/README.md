# third_party —— 第三方文件（只放我们真正需要的）

## Mod Options Framework

| 项 | 内容 |
|---|---|
| 用途 | 本模组的**游戏内设置面板 / 改键**（Esc → 模组选项 → PWProjection）|
| 上游 | <https://github.com/Elvlin/Mod-Options-Framework> |
| 作者 | Elvlin（许可里面写的“Elv原则”） |
| 许可证 | **MIT**（原文见 `LICENSE-Mod-Options-Framework.txt`，逐字保留、未改动）|
| 我们分发的文件 | `Scripts\PalModOptionsClient.lua`、`Scripts\pmo_json.lua` |
| 依据 | 上游 `DEVELOPER_API.md` 第 2 节：*"Copy these two files from `DeveloperSDK` into the consumer's `Scripts` folder"* |

**集成方式**

* 这两个文件**原样使用、不做修改**；升级框架时按上游说明重新拷贝即可。
* 框架是**可选依赖**：没装 / 注册失败都**不影响本模组任何功能**（会自动退回
  `pwpr_keys.json` + `pwpr_config.json`）。
* 我们只放这两个 SDK 文件，**不打包**上游的整套 mod（那个由玩家自己从
  Nexus / 创意工坊安装）。
