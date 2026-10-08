--[[ ===========================================================================
  PWPR · keys  ——  按键绑定（**纯 Lua**，只有一个职责: 把"配置"变成"生效的键位"）

  ============================================================================
  为什么要有这个模块（2026-10-06 玩家要求）
  ============================================================================
  以前所有按键都**写死**在 `main.lua` 的 `try_bind("H=resnap", "H", ...)` 里 ——
  玩家想改键就得**改代码**。现在:
    · 每个动作一个配置键（`key_capture` / `key_resnap` / …），默认值 = 现在用的键；
    · 玩家在 `pwpr_config.json` 里改；**改完要重启游戏**（见下面的"限制"）。

  ============================================================================
  三条必须记住的限制（都是实测/查证过的）
  ============================================================================
  1. **UE4SS 只在启动时注册按键** ⇒ 改键**必须重启游戏**；按 `F8` 只重载配置、
     **不会**重新绑定（`snap_key` 一直就是这么写的，这里原样继承）。
  2. **不要用"修饰键组合"**（`Ctrl+H` 之类）: UE4SS 的 `RegisterKeyBindAsync(key, {}, fn)`
     **按住修饰键也照样触发**（本项目实测，`踩坑记录.md` §13）⇒ 一次按键会跑两个回调。
  3. **不能占用游戏自己的键**（规矩 4c）: 目前实测确认的只有 **`B`（建造模式入口）**，
     写在 `Keys.RESERVED` 里；以后玩家遇到再补。

  ============================================================================
  校验规则（`Keys.resolve`，任何一条不过就**回退到内置默认值**并记一行说明）
  ============================================================================
    · 配置值不是字符串 / 空 ⇒ 用默认（**不记日志**，因为"没配"是常态）
    · 键名在 `Key` 枚举里不存在（打错字）⇒ 用默认 + 记一行
    · 键名是"游戏自己占用"的（`Keys.RESERVED`）⇒ 用默认 + 记一行
    · 和**前面已经生效的动作**撞键 ⇒ 用默认 + 记一行；默认也撞 ⇒ **这个动作不绑**
      （宁可不绑，也不能抢别人的键）
    · 默认键在本机枚举里也不存在（换 UE4SS 版本可能）⇒ 试 `alt` 列表，再不行就不绑

  ============================================================================
  提示文本里的键名怎么保持同步（`Keys.translate`）
  ============================================================================
  全项目有 100+ 处字符串写着 `按 H` / `[F7]` 这种**默认键名**。逐个改成查表成本很高、
  而且容易漏。做法: **在输出层统一翻译** —— `Log.set_translator()`（见 `pwpr_log.lua`）
  与 `Notify.show` 会把"默认键名"替换成**玩家实际绑的键**，只在"确实改过键"时才做
  （没改键 ⇒ `rebound_count == 0` ⇒ 直接原样返回，**零开销、行为完全不变**）。
  ⇒ 以后新写的提示照样可以写 `按 H`（默认键名），**不需要**手动查表。
  ★ 但**黑匣子（`Log.solid`）不翻译** —— 那是给排查用的原始证据，必须逐字稳定。
=========================================================================== ]]

local Config = require("pwpr_config")
local Util = require("pwpr_util")
local Json = require("pwpr_json")

local Keys = {}

-- --------------------------------------------------------------------------
-- ★★★ 按键**单独一个文件**: `Scripts\pwpr_keys.json`（2026-10-06 玩家要求 B 方案）
-- --------------------------------------------------------------------------
-- 为什么单独放:
--   · 玩家要"一眼能找到改键的地方" —— 混在 100+ 键的总配置里不好找；
--   · 这个文件**只放按键**，不容易误改到别的设置。
-- 规则:
--   · **文件不存在 ⇒ 自动生成一份**（全部 11 个动作 + `_readme` 说明），
--     所以玩家不需要背键名，打开就能改；
--   · 优先级: `pwpr_keys.json` >（兼容）`pwpr_config.json` 里的同名 `key_*` > 内置默认值；
--   · 生成时**逐个键按顺序写**（见 `render_file`）—— Lua 的 table 无序，
--     用 `Json.encode` 出来顺序会乱，玩家看着难受；
--   · `keys_version` 用于**以后改默认键时迁移**（只动玩家没改过的键）。
Keys.FILE_NAME = "pwpr_keys.json"
Keys.VERSION = 1
Keys.file_path = nil       -- 完整路径
Keys.file_values = nil     -- 文件里读到的键值表（nil = 没读到）
Keys.file_created = false  -- 这次是不是**新建**的
Keys.file_error = nil      -- 读/解析失败时的说明（失败 ⇒ 全用默认值，不影响启动）
Keys.file_version = 0

--- 动作配置键 → 内置默认值
local function defaults_of_actions()
    local t = {}
    for i = 1, #Keys.ACTIONS do
        t[Keys.ACTIONS[i].cfg] = Keys.ACTIONS[i].default
    end
    return t
end

--- 生成 `pwpr_keys.json` 的文本（**手写**，为了顺序固定 + 带说明）
---
--- ⚠️⚠️ 2026-10-06 踩的坑（构建 `.62` 的真实 bug，玩家实测发现）:
---   第一版把每一行直接拼成字符串 ⇒ **前四行（`_readme`/`_values`/`_rules`/`_actions`）
---   忘了写逗号** ⇒ 生成出来的文件**根本不是合法 JSON** ⇒ 解析失败 ⇒
---   玩家改的键**全部退回默认值**（"`key_resnap` 改成 G 了还是只能按 H"）。
--- ⇒ 现在改成"**先收集成条目、再用 `table.concat(entries, ",")` 拼**" ——
---   这样逗号**结构上不可能漏**（漏了这个 bug 类别就消失了）。
--- ⇒ 再加一道保险: 写完之后**立刻把内容解析一遍自检**（`Keys.gen_check`），
---   万一还是写坏，日志里会有一行 `★ 生成的按键文件自检失败` 而不是静默失效。
---
--- ⚠️ 另外 **不能写 `//` 注释**（JSON 标准不允许注释，我们自己的解析器也不支持）——
---   说明统一写在 `_readme` / `_values` / `_rules` / `_actions` 这几个**下划线键**里。
local function render_file()
    local entries = {}
    entries[#entries + 1] = '  "_readme": "PWProjection 按键绑定（只有这个文件管按键）。'
        .. '改完必须【重启游戏】才生效 —— 按 F8 只重载 pwpr_config.json，不会重绑按键。"'
    entries[#entries + 1] = '  "_values": "值要写 UE4SS Key 枚举里的名字: \\"Y\\" \\"F9\\" '
        .. '\\"NUM_EIGHT\\" \\"UP_ARROW\\" …（可用名字的完整清单见 docs\\\\按键列表.md）"'
    entries[#entries + 1] = '  "_rules": "① 不要写修饰键组合（像 Ctrl+H）—— UE4SS 按住修饰键也会触发裸键；'
        .. '② 不要占用游戏自己的键（B = 建造模式入口，写了会被拒绝并回退默认值）；'
        .. '③ 两个动作不能绑同一个键（后一个自动回退）；④ 删掉某一行 = 用内置默认值。"'
    entries[#entries + 1] = '  "_actions": "capture=采集 · library=下一张蓝图 · ghost=投影放/收 · '
        .. 'layer=切分层 · site_cycle=换一处记录 · resnap=投影回脚下 · mode=方向键模式 · '
        .. 'probe=渲染能力探测 · notify_probe=提示通道探测 · help=帮助 · reload=重载配置"'
    for i = 1, #Keys.ACTIONS do
        local a = Keys.ACTIONS[i]
        entries[#entries + 1] = string.format('  "%s": "%s"', a.cfg, a.default)
    end
    entries[#entries + 1] = string.format('  "keys_version": %d', Keys.VERSION)
    return "{\r\n" .. table.concat(entries, ",\r\n") .. "\r\n}"
end

--- 读（没有就生成）按键文件。必须在 `Keys.resolve()` 之前调用。
--- `script_dir` 一般传 `Util.script_dir`（放 `pwpr_keys.json` 的位置）。
function Keys.load_file(script_dir)
    local dir = script_dir
    if type(dir) ~= "string" or dir == "" then dir = Util.script_dir end
    local path = Util.join(dir, Keys.FILE_NAME)
    Keys.file_path = path

    local text = Util.read_file(path)
    if text ~= nil then
        local obj = nil
        local ok = pcall(function() obj = Json.decode(text) end)
        if ok and type(obj) == "table" then
            Keys.file_values = obj
            Keys.file_version = tonumber(obj.keys_version) or 0
            return true, "已读取"
        end
        -- ★ 文件坏了（格式不对）⇒ **把原文备份一份**，然后重新生成一份默认的。
        --   为什么自愈而不是直接放弃: 玩家手工改 JSON 很容易漏逗号/多逗号，
        --   而"改完没生效"是最难自查的失败方式（2026-10-06 就是我自己生成的
        --   文件少逗号，害玩家以为是功能坏了）⇒ 备份 + 重建 + 大声说明。
        pcall(function()
            Util.write_file(Util.join(dir, "pwpr_keys.bad.json"), text, true)
        end)
        Keys.file_error = string.format(
            "格式不对（JSON 解析失败）⇒ 原文已备份成 pwpr_keys.bad.json，"
            .. "并重新生成了一份默认的（你的改动请看着备份重做一次）")
        text = nil
        -- 落到下面的"生成"分支
    end

    -- 文件不存在（或刚判定为坏）⇒ 生成一份（含全部键 + 说明）
    Keys.file_values = defaults_of_actions()
    Keys.file_version = Keys.VERSION
    local body = render_file()
    -- ★ 写之前自检: 生成的内容必须能解析回来（防止再把"非法 JSON"写进磁盘）
    local check_ok = false
    pcall(function()
        local probe = Json.decode(body)
        check_ok = type(probe) == "table" and type(probe.keys_version) == "number"
    end)
    if not check_ok then
        Keys.gen_check = false
        Keys.file_error = "生成的按键文件**自检失败**（这是我的 bug）⇒ 这次用内置默认键，请把这一行发给开发者"
        return false, Keys.file_error
    end
    Keys.gen_check = true

    local werr = nil
    local wok = false
    pcall(function() wok, werr = Util.write_file(path, body .. "\r\n", true) end)
    if wok then
        Keys.file_created = true
        return true, (Keys.file_error ~= nil) and "已重建" or "已生成"
    end
    Keys.file_error = "生成失败（" .. tostring(werr) .. "）⇒ 用内置默认键"
    return false, Keys.file_error
end

--- 一行状态（给日志 / F7）
function Keys.file_line()
    if Keys.file_path == nil then return "按键文件: (未加载)" end
    local name = Keys.FILE_NAME
    if Keys.file_error ~= nil then
        return string.format("按键文件: %s —— ★ %s", name, tostring(Keys.file_error))
    end
    if Keys.file_created then
        return string.format("按键文件: %s —— ★ 这次**新建/重建**了一份（全部默认键，可直接改）",
            name)
    end
    return string.format("按键文件: %s（改完重启游戏生效；可用键名见 docs\\按键列表.md）", name)
end

--- 一个动作的"原始配置值"（还没校验）。
--- 优先级: `pwpr_keys.json` →（兼容）`pwpr_config.json` 的 `key_*` → nil（用默认）
--- 返回: value, 来源（"keys-file" / "config-file"）；没有就是 nil, nil
---
--- ⚠️ 判断"是不是旧位置配的"必须看 `Config.file_keys`（**文件里真的写了**的键），
---    不能只看 `Config.get` 有没有值 —— 那个值可能就是 DEFAULTS 里的默认值，
---    会把"默认"误报成"你在 pwpr_config.json 里配了"（2026-10-06 踩过，日志里
---    刷了一片"建议搬到 pwpr_keys.json"的假提示）。
local function raw_value(a)
    -- ★★★ 2026-10-07: **游戏内设置面板（Mod Options Framework）的值优先**。
    --   框架的注册回调是**异步**的（`register_when_ready`），所以它的值在这里通常
    --   "下一次启动/重载"才会参与解析 —— 而 `restart_mod` 正好会重载我们的 Mod ✓。
    --   值写法: 键名（如 `"G"`）或 **`"none"` = 有意不绑定** ✓
    if type(Keys.override) == "table" and Keys.override[a.id] ~= nil then
        return Keys.override[a.id], "options-framework"
    end
    if type(Keys.file_values) == "table" then
        local v = Keys.file_values[a.cfg]
        if v ~= nil then return v, "keys-file" end
    end
    local from_file = (type(Config.file_keys) == "table") and (Config.file_keys[a.cfg] == true)
    if from_file then
        return Config.get(a.cfg), "config-file"
    end
    return nil, nil
end

--- ★ **"有意不绑定"** 的写法（大小写不敏感）: `none` / `unbound` / `未绑` / `false`
local function is_unbound_value(v)
    if v == false then return true end
    if type(v) ~= "string" then return false end
    local s = string.lower(v)
    return s == "none" or s == "unbound" or s == "off" or v == "未绑"
end

--- ★★★ 2026-10-07: **游戏内设置面板（Mod Options Framework）给的值**（按动作 id 存）。
---   例: `Keys.override = { capture = "G", probe = "none" }`
---   优先级: **框架 > `pwpr_keys.json` > `pwpr_config.json` 的旧位置 > 内置默认** ✓
Keys.override = {}    -- 由 `pwpr_options.lua` 在"下一次启动/重载"前填好

-- --------------------------------------------------------------------------
-- 已知"游戏自己占用"的键（规矩 4c: 一律不碰）
-- --------------------------------------------------------------------------
-- ★ 目前只有 `B` 是**实测确认**的（玩家原话:「B 键是游戏自用的，建筑模式入口」）。
--   其它键（WASD/空格/Tab/Esc/数字 1~4/鼠标……）显然也被游戏用，但没逐条实测过 ⇒
--   不在这里"猜着列"（猜错会把玩家可用的空键误判成不可用）。
--   玩家遇到新冲突时往这里加一条即可，**并写进 `docs\新会话提示词.md` 的键位表**。
Keys.RESERVED = {
    B = "游戏自己的建造模式入口",
}

-- --------------------------------------------------------------------------
-- 动作表（**单一来源**：配置键、默认键、说明都在这儿）
-- --------------------------------------------------------------------------
-- id      : 内部名字（日志/翻译/查表用，不要改）
-- cfg     : `pwpr_config.json` 里的配置键
-- default : 默认键名（必须存在于 UE4SS 的 `Key` 枚举里）
-- alt     : 可选。默认键在本机不存在时的候选
-- cn / en : 给 `F7` 的按键表用的说明（`pwpr_notify.lua` 按 id 取）
Keys.ACTIONS = {
    { id = "capture",      cfg = "key_capture",      default = "Y",
      cn = "采集（半径见 capture_radius_m；设 0 = 采全部）", en = "capture" },
    { id = "library",      cfg = "key_library",      default = "J",
      cn = "蓝图库: 下一张并加载", en = "library: next" },
    { id = "ghost",        cfg = "key_ghost",        default = "K",
      cn = "投影: 放 / 收（放下时自动对齐、并沿用上次位置与进度）", en = "ghost: show/hide" },
    { id = "layer",        cfg = "key_layer",        default = "L",
      cn = "投影: 切分层", en = "ghost: cycle layer" },
    { id = "site_cycle",   cfg = "key_site_cycle",   default = "U",
      cn = "★ 投影: 换一处记录（同一张蓝图的多处放置记录之间切换）",
      en = "ghost: next recorded site" },
    { id = "resnap",       cfg = "key_resnap",       default = "H",
      cn = "投影: 重新定位到你脚下（记成新的一处位置）", en = "ghost: move to player" },
    { id = "mode",         cfg = "key_mode",         default = "F9", alt = { "F10" },
      cn = "切换方向键模式: 移动 / 旋转 / 材质", en = "cycle arrow mode" },
    { id = "probe",        cfg = "key_probe",        default = "N",
      cn = "渲染能力探测（S3）", en = "capability probe" },
    { id = "notify_probe", cfg = "key_notify_probe", default = "O",
      cn = "屏幕提示通道探测（S9）", en = "notify probe" },
    { id = "help",         cfg = "key_help",         default = "F7",
      cn = "帮助 / 当前状态（含这张按键表）", en = "help / status" },
    { id = "reload",       cfg = "key_reload",       default = "F8",
      cn = "重载 pwpr_config.json（★ 不会重新绑定按键）", en = "reload config" },
}

Keys.map = nil            -- resolve 之后: id -> 生效键名
Keys.notes = {}           -- resolve 过程中给玩家看的说明（一行一条）
Keys.rebound_count = 0    -- 有几个动作的键位**和默认不同**（0 ⇒ 翻译层直接跳过）
Keys.unbound = {}         -- 没能绑上的 id（默认键/配置键都不可用时）
Keys.source = {}          -- id -> "default" / "config" / "fallback"（给 F7 用）

-- --------------------------------------------------------------------------
-- 工具
-- --------------------------------------------------------------------------

--- 键名在本机的 `Key` 枚举里存在吗（UE4SS 全局 `Key`）
--- ★ 写成 `function Keys.key_exists` 而不是"别名赋值" —— 项目的跨模块检查
---   （`tools\luacheck.py` 的 "Mod.func(...) 是否真的存在"）只认这个形式；
---   别名赋值会让它误报"pwpr_keys 里没有定义"（2026-10-06 被它抓到一次）。
function Keys.key_exists(name)
    if type(name) ~= "string" or name == "" then return false end
    local k = nil
    pcall(function() k = Key[name] end)
    return k ~= nil
end

function Keys.by_id(id)
    for i = 1, #Keys.ACTIONS do
        if Keys.ACTIONS[i].id == id then return Keys.ACTIONS[i] end
    end
    return nil
end

--- 生效键名（给提示文本用）。没绑 ⇒ 返回 ""
--- ★★ 2026-10-08 **键名美化**（只用于**显示**，不影响绑定）——
---   玩家实测反馈: 把「加载蓝图」绑到数字 9 后，提示里写的是 `NINE`（UE4SS 的原始名字）
---   ⇒ 显示层统一走这里: `NINE → 9`、`NUM_NINE → 小键盘 9`、`UP_ARROW → ↑` …
local PRETTY = {
    ZERO = "0", ONE = "1", TWO = "2", THREE = "3", FOUR = "4",
    FIVE = "5", SIX = "6", SEVEN = "7", EIGHT = "8", NINE = "9",
    UP_ARROW = "↑", DOWN_ARROW = "↓", LEFT_ARROW = "←", RIGHT_ARROW = "→",
    SPACE_BAR = "空格", TAB = "Tab", ENTER = "回车", BACK_SPACE = "退格",
    LEFT_SHIFT = "左Shift", RIGHT_SHIFT = "右Shift",
    LEFT_CONTROL = "左Ctrl", RIGHT_CONTROL = "右Ctrl",
    LEFT_ALT = "左Alt", RIGHT_ALT = "右Alt",
    LEFT_MOUSE_BUTTON = "鼠标左键", RIGHT_MOUSE_BUTTON = "鼠标右键",
    MIDDLE_MOUSE_BUTTON = "鼠标中键", MOUSE_WHEEL_UP = "滚轮上", MOUSE_WHEEL_DOWN = "滚轮下",
    ADD = "+", SUBTRACT = "-", MULTIPLY = "*", DIVIDE = "/", DECIMAL = ".",
}
function Keys.pretty(name)
    if type(name) ~= "string" or name == "" then return "未绑" end
    local up = string.upper(name)
    if PRETTY[up] ~= nil then return PRETTY[up] end
    local num = up:match("^NUM_([A-Z]+)$")
    if num ~= nil then
        if PRETTY[num] ~= nil then return "小键盘 " .. PRETTY[num] end
        return "小键盘 " .. num
    end
    return name
end

function Keys.label(id)
    if type(Keys.map) ~= "table" then return "" end
    return tostring(Keys.map[id] or "")
end

--- 描述（`F7` 的按键表用）
function Keys.desc(id)
    local a = Keys.by_id(id)
    if a == nil then return nil, nil end
    return a.cn, a.en
end

-- --------------------------------------------------------------------------
-- 解析（配置 → 生效键位）
-- --------------------------------------------------------------------------

--- @param deps table|nil 可选 { is_registered = function(keyname) -> bool }
---        `is_registered` 用来**只报告**"这个键可能已被别的 mod 注册"（不阻止绑定）
function Keys.resolve(deps)
    deps = deps or {}
    local map, notes, used = {}, {}, {}
    local rebound, unbound = 0, {}
    local n_pre_taken = 0   -- 「绑定前已经是注册状态」的键数（重载后常见，收尾处写一行汇总）

    for i = 1, #Keys.ACTIONS do
        local a = Keys.ACTIONS[i]
        local raw, from = raw_value(a)
        local want, src, why = a.default, "default", nil

        if raw ~= nil then
            if is_unbound_value(raw) then
                -- ★★★ 2026-10-07: **有意不绑定** —— 不进 map、**不回退默认**（玩家在 UI 里解绑 = 真的不绑）
                map[a.id] = nil
                unbound[#unbound + 1] = a.id
                notes[#notes + 1] = string.format(
                    "%s = %s ⇒ **有意不绑定**（不会回退到默认 %s）",
                    a.cfg, tostring(raw), a.default)
                goto continue_action
            end
            if type(raw) ~= "string" then
                why = string.format("%s 不是字符串（%s）⇒ 用默认 %s",
                    a.cfg, tostring(raw), a.default)
                src = "fallback"
            elseif raw == "" then
                src = "default"          -- 空串 = 显式清空 ⇒ 用默认（不算错）
            else
                want = string.upper(raw)
                -- 兼容旧位置（`pwpr_config.json` 里的 `key_*`）: 能用，但建议搬到 pwpr_keys.json
                src = (from == "config-file") and "config-legacy" or "config"
            end
        end

        -- ① 键名合法吗
        if not Keys.key_exists(want) then
            if src == "config" then
                why = string.format("配置 %s = \"%s\" 在 Key 枚举里不存在 ⇒ 用默认 %s",
                    a.cfg, tostring(raw), a.default)
            else
                why = string.format("默认键 %s 在本机的 Key 枚举里不存在", tostring(want))
            end
            want, src = a.default, "fallback"
            if not Keys.key_exists(want) and type(a.alt) == "table" then
                for j = 1, #a.alt do
                    if Keys.key_exists(a.alt[j]) then
                        want = a.alt[j]
                        why = (why or "") .. string.format("；改用备选 %s", want)
                        break
                    end
                end
            end
        end

        -- ② 是不是游戏自己占用的键
        if Keys.key_exists(want) and Keys.RESERVED[want] ~= nil then
            local bad = want
            want, src = a.default, "fallback"
            if Keys.RESERVED[want] ~= nil then want = nil end
            why = string.format("%s 是游戏自己占用的键（%s）⇒ %s", tostring(bad),
                tostring(Keys.RESERVED[bad]),
                want and ("改用默认 " .. want) or "这个动作**不绑键**")
        end

        -- ③ 和前面生效的动作撞键吗
        if want ~= nil and used[want] ~= nil then
            local other = used[want]
            local bad = want
            want, src = a.default, "fallback"
            if used[want] ~= nil then want = nil end
            why = string.format("%s 已经用于「%s」⇒ %s", tostring(bad), tostring(other),
                want and ("改用默认 " .. want) or "这个动作**不绑键**")
        end

        if want ~= nil and Keys.key_exists(want) then
            used[want] = a.id
            map[a.id] = want
            Keys.source[a.id] = src
            if src == "config" and want ~= a.default then
                rebound = rebound + 1
            elseif src == "config-legacy" then
                notes[#notes + 1] = string.format(
                    "提示: %s 是在 `pwpr_config.json` 里配的（旧位置）—— 建议搬到 %s（那个文件只管按键，更好找）",
                    a.cfg, Keys.FILE_NAME)
                if want ~= a.default then rebound = rebound + 1 end
            end
            -- ④ 汇总"这些键在绑定前已经是注册状态"（不阻止绑定）
            --   ★★ 2026-10-08 玩家实测: 原来**每个键一行**提示，而"UI 里点保存会重载我们的 Mod"
            --     ⇒ 重载后**我们自己上一轮注册的键**也返回 true ⇒ 会刷一片"可能被别的 mod 占用"
            --     的**误报** ✗ ⇒ 改成**一行汇总**（并写清这两种可能）✓
            if deps.is_registered ~= nil then
                local taken = false
                pcall(function() taken = deps.is_registered(want) == true end)
                if taken == true then
                    n_pre_taken = n_pre_taken + 1
                end
            end
        else
            Keys.source[a.id] = "none"
            unbound[#unbound + 1] = a.id
        end

        if why ~= nil then
            notes[#notes + 1] = string.format("按键 %s: %s", tostring(a.id), why)
        end
        ::continue_action::
    end

    if n_pre_taken > 0 then
        -- ★★★ 2026-10-08 晚（`.113` 先写成"这些键不会生效"，`.114` **修正措辞**）:
        --   实测（玩家）: 按键**在游戏里一直能用**（改键后按一次就生效）⇒ 这句不能断言"失效" ✗
        --   真实机制: 框架（Mod Options Framework）启动时会先装 **94 个按键捕获绑定**
        --   （UE4SS.log: `[PalModOptions] Installed 94 event-driven key-capture bindings`），
        --   我们的键几乎都在里面 ⇒ `IsKeyBindRegistered` 自然返回 true。
        --   UE4SS 允许多个回调挂同一个键，所以**我们的回调照样会响** ✓
        --   ⇒ 这行只是"存在同名键的占用"提示，**不能当故障结论**（真凶见 §75-2 的 CaptureActive）。
        notes[#notes + 1] = string.format(
            "提示: 有 %d 个键在绑定前**已经是注册状态** —— 最常见的是**设置框架自己的按键捕获绑定**"
            .. "（它一次注册 ~94 个键），也可能是本次重载前我们自己注册的；"
            .. "UE4SS 允许多个回调共存，**这一行不代表按键失效** ✗", n_pre_taken)
        Keys.n_pre_taken = n_pre_taken
    end
    Keys.map = map
    Keys.notes = notes
    Keys.rebound_count = rebound
    Keys.unbound = unbound
    return map, notes
end

--- 这个动作是**有意不绑定**吗（UI 里关掉了 / 配置里写了 `none`）
function Keys.is_unbound(id)
    if type(Keys.unbound) ~= "table" then return false end
    for i = 1, #Keys.unbound do
        if Keys.unbound[i] == id then return true end
    end
    return false
end

-- --------------------------------------------------------------------------
-- 提示文本翻译（默认键名 → 玩家实际绑的键）
-- --------------------------------------------------------------------------
-- 只在"确实改过键"时才工作（`rebound_count == 0` ⇒ 原样返回，零开销）。
-- 替换的形态**刻意收窄**（只认这些明显是"提示键位"的写法），避免误伤正文:
--   `按 H` / `H 键` / `[F7]` / `H=`
--   `（H 移到` / `；U 换一处` / `: L  ` / ` H ` —— ★ 2026-10-06 玩家实测发现这一族**没被翻译**:
--       「投影已放置: 374 件 … （**H** 移到脚下；**U** 换一处记录，共 4 处）」而玩家已把 resnap 改成 G。
--   ★ 但**跳过"量词"**（`N 个` / `N 件` 这种是我们文本里的**变量**，不是键名）。
local QUANT_AFTER = {
    ["个"] = true, ["次"] = true, ["件"] = true, ["条"] = true, ["张"] = true,
    ["处"] = true, ["米"] = true, ["秒"] = true, ["分"] = true, ["种"] = true,
    ["号"] = true, ["行"] = true, ["字"] = true,
}

--- 把"被标记包围的单键名"替换掉（`mark_pat` = 标记的捕获模式）；遇到量词就原样返回
local function sub_marked(text, mark_pat, def, now)
    local pat = "(" .. mark_pat .. ")" .. def .. " (%S)"
    return (text:gsub(pat, function(mark, nxt)
        if QUANT_AFTER[nxt] then
            return mark .. def .. " " .. nxt
        end
        return mark .. now .. " " .. nxt
    end))
end

function Keys.translate(text)
    if type(text) ~= "string" or text == "" then return text end
    if Keys.map == nil or (Keys.rebound_count or 0) == 0 then return text end
    for i = 1, #Keys.ACTIONS do
        local a = Keys.ACTIONS[i]
        local now = Keys.map[a.id]
        if now ~= nil and now ~= a.default then
            local def = a.default
            -- ★★ 2026-10-08 玩家实测 #3: 提示文本里显示的是 UE4SS 原始键名（`ZERO`）
            --   ⇒ **翻译层也要走美化**（`ZERO → 0`、`NUM_* → 小键盘 *` …）✓
            local nowp = Keys.pretty(now)
            text = text:gsub("按 " .. def .. "(%f[%A])", "按 " .. nowp)
            text = text:gsub("(%f[%A])" .. def .. " 键", "%1" .. nowp .. " 键")
            text = text:gsub("%[" .. def .. "%]", "[" .. nowp .. "]")
            text = text:gsub("(%f[%A])" .. def .. "=", "%1" .. nowp .. "=")
            text = sub_marked(text, "[（(【]", def, nowp)
            text = sub_marked(text, "[；;：:]%s?", def, nowp)
            text = sub_marked(text, "%s", def, nowp)
        end
    end
    return text
end

-- --------------------------------------------------------------------------
-- 状态（给日志 / F7）
-- --------------------------------------------------------------------------

--- 一行摘要: `按键: 11 个动作（默认）/ 3 个改过`
function Keys.status_line()
    if Keys.map == nil then return "按键: (未解析)" end
    local n = #Keys.ACTIONS
    local parts = { string.format("按键: %d 个动作", n) }
    if (Keys.rebound_count or 0) > 0 then
        parts[#parts + 1] = string.format("其中 %d 个改过（配置）", Keys.rebound_count)
    else
        parts[#parts + 1] = "全部用默认"
    end
    if #(Keys.unbound or {}) > 0 then
        parts[#parts + 1] = string.format("★ 未绑 %d 个: %s",
            #Keys.unbound, table.concat(Keys.unbound, ","))
    end
    return table.concat(parts, "   ")
end

--- 逐条明细（给 F7；改过键/出错时才值得看）
function Keys.status_lines(limit)
    local out = { Keys.status_line() }
    local n = 0
    for i = 1, #(Keys.notes or {}) do
        if n >= (limit or 12) then
            out[#out + 1] = string.format("  … 还有 %d 条", #Keys.notes - n)
            break
        end
        out[#out + 1] = "  " .. Keys.notes[i]
        n = n + 1
    end
    return out
end

--- 生效的键位表（给日志: 一眼看出"哪个动作现在绑在哪个键上"）
function Keys.bind_lines()
    local out = {}
    local src_label = {
        ["config"] = "按键文件",
        ["config-legacy"] = "旧位置",
        ["default"] = "默认",
        ["fallback"] = "回退默认",
        ["none"] = "未绑",
    }
    for i = 1, #Keys.ACTIONS do
        local a = Keys.ACTIONS[i]
        local k = Keys.label(a.id)
        out[#out + 1] = string.format("  %-13s %-8s %s", a.id,
            (k ~= "" and k or "(未绑)"),
            src_label[Keys.source[a.id]] or "默认")
    end
    return out
end

return Keys
