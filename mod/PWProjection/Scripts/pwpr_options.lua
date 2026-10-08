--[[ ===========================================================================
  PWPR · options  ——  Mod Options Framework 接入（游戏内设置 / 改键）

  ============================================================================
  设计（2026-10-08 玩家定稿）
  ============================================================================
    · **最上面一行: 「本模组快捷键总开关」**（boolean）
        关掉 ⇒ **本模组所有快捷键都不生效**（保存后重载本模组，随即生效）。
    · **核心 4 个**（一直启用，只有按键行）: 采集 / 加载蓝图 / 投影放收 / 分层
    · **可选 8 个**: **默认不绑**（默认值就是"不绑"）——
        想让某个生效 ⇒ 在 UI 里给它设一个键；
        想解绑 ⇒ 点框架自带的 **恢复默认值**（默认 = 不绑）✓
        ⇒ 因此**不再需要**给每个动作配"启用"开关 ✓
    · **`F10` 额外一行 `enum`（多选一）**: 方向键默认模式 移动/旋转/材质
        （语义: 只是"启动/Apply 时的默认模式"；游戏内按切换键仍可循环切换，
          框架没有"mod 回写 UI 显示值"的接口 ⇒ 那行显示不会跟着变 —— 已写进中文说明）

  ============================================================================
  值怎么生效（2026-10-08 修好了"要保存两次才生效"）
  ============================================================================
    ★ 框架的注册回调是**异步**的，而我们的按键**在 Mod 启动时就注册完了**。
    ⇒ 现在**启动早期就自己同步读框架的设置文件**（它文档给的路径:
      `PalModOptions\Scripts\config\<id>.ini`，每行一个 JSON 编码的值），
      作为最高优先级覆盖交给 `pwpr_keys.lua` ⇒ **改一次保存就生效** ✓
    ⇒ 回调到达后再写回 `pwpr_keys.json`（备份 `pwpr_keys.bak.json`）作为第二重保险 ✓
=========================================================================== ]]

local Util   = require("pwpr_util")
local Log    = require("pwpr_log")

local Options = {}

Options.client     = nil
Options.available  = false
Options.registered = false
Options.last_error = nil
Options.values     = nil
Options.master_on  = nil     -- 总开关（nil = 未知/框架未装 ⇒ 视为开）
Options.arrow_mode = nil     -- UI 里选的方向键默认模式
Options.num_overrides = {}   -- ★ UI-3: UI 里的数值（`Config.load` 之后由 main.lua 套用）

local function solid(msg)
    pcall(function() Log.solid("[options] " .. tostring(msg)) end)
end

-- --------------------------------------------------------------------------
-- 设置页定义（**单一来源**）
-- --------------------------------------------------------------------------
local CORE = {
    { id = "capture", key = "k_capture", label = "采集（生成蓝图）", desc = "采集当前建筑并生成蓝图。", def = "Y" },
    { id = "library", key = "k_library", label = "加载蓝图",       desc = "加载蓝图库里的下一张蓝图。", def = "J" },
    { id = "ghost",   key = "k_ghost",   label = "投影 放/收",     desc = "放下或收起投影。", def = "K" },
    { id = "layer",   key = "k_layer",   label = "投影 分层",      desc = "切换投影分层。", def = "L" },
}
-- ★★ 非核心动作（**默认不生效**; 玩家 2026-10-08 定的）
--   ⚠️ 2026-10-08 实测: 框架**不接受** `default = "none"`（报 `k_resnap has an invalid default`）
--      ⇒ `keybind` 的默认值**必须是它认识的键名** ✓
--   ⇒ 折中做法: 默认值给**一个合法键**（下面 `def`），但**我们的模组把"值 == 默认值"当作"未启用"**
--      ⇒ 效果上就是"默认不绑" ✓；想让某个生效 ⇒ 在 UI 里给它设一个**别的**键 ✓；
--      ⇒ 想解绑 ⇒ 点「恢复默认值」（回到"未启用"状态）✓
-- ★★ 统一"未启用"标记（玩家 2026-10-08；2026-10-08 晚换成 `F24`）:
--   默认值**一律给 `F24`**，**值等于它 ⇒ 我们的模组当"未启用"**（不绑键）✓
--   ★ 为什么不用短横线: UE4SS/框架里
--       · 主键盘的 `-` 是 `HYPHEN` —— **框架的 keybind 不支持**（玩家实测: 按了没反应 ✗）
--       · 小键盘的 `-` 是 `SUBTRACT` —— 框架认，但**显示成 `Numpad-`**，
--         而玩家的键盘是 84 键**没有小键盘** ⇒ 又看不懂、又按不到 ✗
--     ⇒ 用 **`F24`**: 框架支持（F1–F24 ✓）、显示清楚、**任何常用键盘都按不到**（不会误触）✓
--   想启用 ⇒ 在 UI 里改成别的键；想解绑 ⇒ 点「恢复默认值」（回到 `F24`）✓
--   ★ 顺序按玩家要求: 常用（**方向键两条必须相邻**）→ 诊断/次要 → 最后才是"重载配置、帮助"
--   `grp` = 页面分组（1 常用 / 2 诊断 / 3 其他）
--   ★★ `bound_default = true`（2026-10-09 晚新增，构建 .112）: **值等于默认值也照常绑定**。
--      只给「渲染能力探测」用 —— 它是"投影能不能用"的第一道门，**必须开箱可用**，不能默认解绑 ✗
local OPTIONAL = {
    -- ★★★ `.112` 玩家定稿（发布前的首次上手阻塞点）:
    --   投影的解锁流程是「先按 N 跑能力探测（通过后自动写 ghost_enabled = true）」，
    --   而装了框架的用户**可选键默认不绑（F24）** ⇒ 新用户按 N 没反应、按 K 只看到
    --   「投影没解锁」⇒ 装完像是坏的 ✗
    --   ⇒ 把「渲染能力探测」挪到**「常用」第一条**、默认值 **`N`**，并用 `bound_default`
    --     跳出"值 == 默认值 ⇒ 当作未启用"那条规则（其余 7 个可选键**仍然默认不启用**）✓
    --   ※ 框架**没有 button 类型**（只有 boolean/integer/number/text/enum/keybind/section，
    --     见 `PalModOptionsClient.lua` 的类型校验），所以"做成按钮单击触发"这条路走不通。
    { id = "probe",        key = "k_probe",        label = "渲染能力探测（★ 首次必跑）", desc = "第一次用投影前跑一次；通过后自动解锁投影（写入 ghost_enabled = true）。", def = "N", grp = 1, bound_default = true },
    { id = "resnap",       key = "k_resnap",       label = "重新定位到脚下", desc = "把投影重新定位到你脚下（记成新的一处位置）。", def = "F24", grp = 1 },
    { id = "site_cycle",   key = "k_site_cycle",   label = "换一处记录",     desc = "在同一张蓝图的多处放置记录之间切换。",       def = "F24", grp = 1 },
    { id = "mode",         key = "k_mode",         label = "方向键模式切换", desc = "循环切换方向键模式（移动/旋转/材质）。",      def = "F24", grp = 1 },
    { id = "notify_probe", key = "k_notify_probe", label = "屏幕提示探测",   desc = "诊断用: 探测屏幕提示通道。",                 def = "F24", grp = 2 },
    { id = "snap_key",     key = "k_snap_key",     label = "投影对齐(建筑)", desc = "把投影对齐到附近已建好的建筑。",               def = "F24", grp = 2 },
    { id = "reload",       key = "k_reload",       label = "重载配置",       desc = "重新读取 pwpr_config.json（不重绑按键）。",  def = "F24", grp = 3 },
    { id = "help",         key = "k_help",         label = "帮助/状态",      desc = "把按键表与当前状态写进日志。",               def = "F24", grp = 3 },
}

--- ★★ UI-3（玩家 2026-10-09）: 进 UI 的**数值类**配置（只留这 4 个，按玩家给的顺序）
---   `type = "integer"` = 框架的**数字输入框**（可键盘输入、也有步进）✓
---   ⚠️ 它们的真实来源仍是 `pwpr_config.json` ⇒ 我们启动时把 UI 值写回那个文件（见 `write_back`）✓
local NUMERIC = {
    { key = "capture_radius_m", label = "蓝图采集范围（米；0 = 采全部）",
      desc = "采集建筑时以你为中心的半径，单位米；0 = 采全部。", def = 150, min = 0, max = 1000, step = 1 },
    { key = "nudge_step_cm", label = "投影微调步长（厘米）",
      desc = "方向键 / 小键盘微调投影时每次移动的距离，单位厘米。", def = 100, min = 1, max = 5000, step = 1 },
    { key = "rotate_step_deg", label = "旋转角度（度）",
      desc = "每次旋转投影的角度，单位度。", def = 15, min = 1, max = 90, step = 1 },
    { key = "layer_gap_cm", label = "分层显示高度间距（厘米）",
      desc = "投影分层之间的高度差，单位厘米。", def = 200, min = 1, max = 5000, step = 1 },
}

local function build_schema()
    local opts = {
        {
            key = "master_keys", type = "boolean",
            label = "Mod hotkeys enabled",
            labels = { ["zh-Hans"] = "★ 本模组快捷键总开关（关掉 = 所有快捷键都不生效）" },
            description = "Turn off to disable ALL PWProjection hotkeys.",
            descriptions = { ["zh-Hans"] = "关掉 = 本模组**所有快捷键都不生效**"
                .. "（保存后会重载本模组，随即生效）。" },
            default = true,
        },
        { key = "sec_core", type = "section", label = "Core keys",
          labels = { ["zh-Hans"] = "核心按键（一直启用）" } },
    }
    for i = 1, #CORE do
        local r = CORE[i]
        opts[#opts + 1] = {
            key = r.key, type = "keybind", label = r.label,
            labels = { ["zh-Hans"] = r.label },
            description = r.desc, descriptions = { ["zh-Hans"] = r.desc },
            default = r.def,
        }
    end
    opts[#opts + 1] = { key = "sec_opt_placeholder", type = "section", label = "Optional keys",
        labels = { ["zh-Hans"] = "（下面按分组排列）" } }
    -- ★ 按 `grp` 分三段（玩家要求: 常用 → 诊断 → 其他），**方向键两条必须相邻**
    local SEC = {
        [1] = "可选按键（常用）—— ★ 「渲染能力探测」默认 `N`（**首次必跑**，一直可用）；"
            .. "其余各项默认值 F24 表示**不启用**，改成别的键才生效，想解绑点「恢复默认值」",
        [2] = "可选按键（诊断 / 次要）—— 同上，默认不启用",
        [3] = "其他（重载配置、帮助）—— 同上，默认不启用",    }
    local done_sec = {}
    for i = 1, #OPTIONAL do
        local r = OPTIONAL[i]
        if done_sec[r.grp] ~= true then
            done_sec[r.grp] = true
            -- ★★★ 2026-10-09 修正: **数值栏要排在"其他"标题之前** ——
            --   上一版把 `sec_opt3`（其他）先加进去、再加 `sec_num`（数值设置）
            --   ⇒ 玩家看到"其他（重载配置、帮助）"的描述**挂在了新栏上** ✗
            if r.grp == 3 then
                opts[#opts + 1] = { key = "sec_num", type = "section", label = "Numbers",
                    labels = { ["zh-Hans"] = "数值设置（可直接输入数字，也可用步进）" } }
                for k = 1, #NUMERIC do
                    local n = NUMERIC[k]
                    -- ★★ 2026-10-09 晚: 从 `integer` 改成 **`text`** ——
                    --   原因: 玩家实测崩溃，而框架日志里紧跟着 4 行
                    --   `Could not apply default black input text for <这些键>`
                    --   ⇒ 它给数字控件的输入框上色失败 ⇒ 很可能撞到它数字控件的脆弱路径 ✗
                    --   `text` 行**同样是键盘输入**（例: 输入 `150`），我们自己 `tonumber` + 校验范围 ✓
                    opts[#opts + 1] = {
                        key = n.key, type = "text",
                        label = n.label .. string.format("（%d–%d）", n.min, n.max),
                        labels = { ["zh-Hans"] = n.label
                            .. string.format("（%d–%d，直接输入数字）", n.min, n.max) },
                        description = n.desc .. string.format(" Range %d-%d.", n.min, n.max),
                        descriptions = { ["zh-Hans"] = n.desc
                            .. string.format("范围 %d–%d；直接输入数字即可 ✓", n.min, n.max) },
                        default = tostring(n.def), max_length = 8,
                        hint = string.format("%d-%d", n.min, n.max),
                    }
                end
            end
            opts[#opts + 1] = { key = "sec_opt" .. r.grp, type = "section",
                label = "Optional keys " .. r.grp,
                labels = { ["zh-Hans"] = SEC[r.grp] } }
        end
        opts[#opts + 1] = {
            key = r.key, type = "keybind", label = r.label,
            labels = { ["zh-Hans"] = r.label },
            description = r.desc .. (r.bound_default == true and (" (default " .. r.def .. ")")
                or (" (unbound while it is " .. r.def .. ")")),
            descriptions = { ["zh-Hans"] = r.desc .. (r.bound_default == true
                and ("（**默认就能用**: `" .. r.def .. "`；想换成别的键直接在这里改）")
                or "（**值 = F24 时不启用**）") },
            default = r.def,
        }
        -- ★ 方向键那两条紧挨着（玩家 2026-10-08 要求）
        if r.id == "mode" then
            local mode_desc = "启动/应用时的默认方向键模式"
                .. "（游戏内按切换键仍可随时循环切换；这一行的显示不会跟着变）。"
            opts[#opts + 1] = {
                key = "arrow_mode", type = "enum", label = "方向键默认模式",
                labels = { ["zh-Hans"] = "方向键默认模式" },
                description = mode_desc, descriptions = { ["zh-Hans"] = mode_desc },
                default = "move",
                choices = {
                    { value = "move",     label = "Move",     labels = { ["zh-Hans"] = "移动" } },
                    { value = "rotate",   label = "Rotate",   labels = { ["zh-Hans"] = "旋转" } },
                    { value = "material", label = "Material", labels = { ["zh-Hans"] = "材质" } },
                },
            }
        end
    end
    return {
        id = "PWProjection",
        mod_folder = "PWProjection",
        title = "PWProjection",
        description = "Palworld blueprint projection mod (Litematica style).",
        version = 3,
        apply_mode = ((Options.apply_mode == "game_restart" or Options.apply_mode == "event")
            and Options.apply_mode or "restart_mod"),   -- ★ `.117`: main.lua 从配置塞进来
        options = opts,
    }
end

-- --------------------------------------------------------------------------
-- ★ 同步读取框架已保存的值（修"要保存两次才生效"的关键）
-- --------------------------------------------------------------------------
local function apply_values(vals, source)
    local Keys = nil
    pcall(function() Keys = require("pwpr_keys") end)
    if Keys == nil then return 0 end
    local n = 0
    for i = 1, #CORE do
        local r = CORE[i]
        if vals[r.key] ~= nil then Keys.override[r.id] = vals[r.key]; n = n + 1 end
    end
    for i = 1, #OPTIONAL do
        local r = OPTIONAL[i]
        local v = vals[r.key]
        if v ~= nil then
            -- ★ 2026-10-08: **值 == 默认值 ⇒ 当作"未启用"（解绑）** —— 这就是"默认不绑"的实现
            --   （框架不接受 `default = "none"`，所以用"等于默认"来表达"没被启用"）
            -- ★★ 2026-10-09 晚（`.112`）: 带 `bound_default = true` 的行**跳出**这条规则 ——
            --   它的默认值就是"真的绑那个键"（「渲染能力探测」= `N`，首次上手必须能用）✓
            if tostring(v) == tostring(r.def) and r.bound_default ~= true then
                Keys.override[r.id] = "none"
            else
                Keys.override[r.id] = v
            end
            n = n + 1
        end
    end
    if vals.master_keys ~= nil then
        Options.master_on = (vals.master_keys == true or vals.master_keys == "true")
    end
    if vals.arrow_mode ~= nil then Options.arrow_mode = vals.arrow_mode end
    -- ★ UI-3: 数值类（进 UI 的 4 个）—— 先存着，等 `Config.load` 之后由 main.lua 套上去 ✓
    local n_num = 0
    for i = 1, #NUMERIC do
        local num = NUMERIC[i]
        local v = tonumber(vals[num.key])
        if v ~= nil then
            Options.num_overrides[num.key] = v
            n_num = n_num + 1
        end
    end
    if n_num > 0 then
        solid(string.format("收下 %d 个数值（等 Config 载入后套用）", n_num))
    end
    if n > 0 then solid(string.format("应用框架值 %d 项（来源 %s）", n, tostring(source))) end
    return n
end

--- ★ UI-3: 把 UI 里的数值套到已载入的 `Config.values` 上（`main.lua` 在 `Config.load` 之后调用）
--- 返回: 套上去的个数
function Options.apply_numeric_overrides()
    local n = 0
    local ok, Config = pcall(require, "pwpr_config")
    if not ok or Config == nil or type(Config.values) ~= "table" then return 0 end
    for k, v in pairs(Options.num_overrides) do
        if type(v) == "number" then
            -- ★ `text` 行给的是字符串 ⇒ 这里已经 `tonumber` 过 ✓；再**按范围夹一下**（越界就用默认）
            local lo, hi, def = nil, nil, nil
            for i = 1, #NUMERIC do
                if NUMERIC[i].key == k then
                    lo, hi, def = NUMERIC[i].min, NUMERIC[i].max, NUMERIC[i].def
                    break
                end
            end
            local val = v
            if lo ~= nil and (val < lo or val > hi) then
                Log.emit(string.format("UI 数值 %s = %s 超出范围 %d–%d ⇒ 用默认 %s",
                    tostring(k), tostring(val), lo, hi, tostring(def)))
                val = def
            end
            Config.values[k] = val
            n = n + 1
        end
    end
    return n
end

function Options.load_saved_overrides()
    local dir = tostring(Util.script_dir or "")
    if dir == "" then return 0, "没有 script_dir" end
    local path = dir .. "\\..\\..\\PalModOptions\\Scripts\\config\\PWProjection.ini"
    local f = io.open(path, "rb")
    if f == nil then return 0, "没找到框架的设置文件" end
    local txt = f:read("*a") or ""
    f:close()
    local okj, Json = pcall(require, "pwpr_json")
    local vals, n = {}, 0
    for line in tostring(txt):gmatch("[^\r\n]+") do
        local k, v = line:match("^%s*([%w_%.%-]+)%s*=%s*(.-)%s*$")
        if k ~= nil and v ~= nil and v ~= "" then
            k = k:match("([^%.]+)$") or k
            local raw = v
            if okj and Json ~= nil then
                pcall(function()
                    local d = Json.decode(v)
                    if type(d) == "string" or type(d) == "boolean" or type(d) == "number" then
                        raw = d
                    end
                end)
            else
                raw = v:gsub('^"', ""):gsub('"$', "")
            end
            vals[k] = raw
            n = n + 1
        end
    end
    local applied = apply_values(vals, "ini")
    return applied, string.format("读到 %d 行、应用 %d 项", n, applied)
end

-- --------------------------------------------------------------------------
-- 写回 `pwpr_keys.json`（第二重保险）
-- --------------------------------------------------------------------------
local function write_back(values)
    local okk, Keys = pcall(require, "pwpr_keys")
    if not okk or Keys == nil then return false, "拿不到 pwpr_keys" end
    local path = tostring(Util.script_dir or "") .. "\\" .. tostring(Keys.FILE_NAME)
    local okj, Json = pcall(require, "pwpr_json")
    if not okj or Json == nil then return false, "pwpr_json 不可用" end
    local data = {}
    pcall(function()
        local f = io.open(path, "rb")
        if f ~= nil then
            local txt = f:read("*a"); f:close()
            local d = Json.decode(txt)
            if type(d) == "table" then data = d end
        end
    end)
    local n_set, n_none = 0, 0
    local function put(id, v)
        if v == nil then return end
        if type(v) == "boolean" then v = v and "true" or "none" end
        data["key_" .. id] = v
        if v == "none" then n_none = n_none + 1 else n_set = n_set + 1 end
    end
    for i = 1, #CORE do put(CORE[i].id, values[CORE[i].key]) end
    for i = 1, #OPTIONAL do
        local r = OPTIONAL[i]
        local v = values[r.key]
        -- ★★★ 2026-10-08 晚（`.119`）**修无限重载循环** —— 原来这里**还按老规则**
        --   把"值 == 默认值"的行写成 `none`，而 `.112` 起的**读取**那侧已经把
        --   `bound_default = true`（默认值也算绑定，典型是 `probe = N`）当成"有效"。
        --   两边规则不一致 ⇒ 框架每轮都认为"值又变了" ⇒ **保存后无限重载**
        --   （实测: 改一个键，0.44 秒一轮、一轮一次重载，35 轮后游戏卡死 ✗✗；
        --    不改内容时框架认为"没变化"⇒不重载 ⇒ 连点二三十次都没事 ✓ 与玩家观察一致）
        --   ⇒ 现在与 `apply_values` **完全同规则**: `bound_default` 的行保留实际值 ✓
        --   （顺带修掉 `pwpr_keys.json` 里 `key_probe=none` 与 ini `k_probe="N"` 不一致）
        if v ~= nil and tostring(v) == tostring(r.def) and r.bound_default ~= true then
            v = "none"
        end
        put(r.id, v)
    end
    local enc = Json.encode(data)
    if type(enc) ~= "string" then return false, "encode 失败" end
    pcall(function()
        local old = io.open(path, "rb")
        if old ~= nil then
            local t = old:read("*a"); old:close()
            local bk = io.open(tostring(Util.script_dir) .. "\\pwpr_keys.bak.json", "wb")
            if bk ~= nil then bk:write(t); bk:close() end
        end
    end)
    local f = io.open(path, "wb")
    if f == nil then return false, "打不开 " .. path end
    f:write(enc)
    f:close()
    return true, string.format("已写回 %d 个键、%d 个解绑", n_set, n_none)
end

-- --------------------------------------------------------------------------
-- 对外接口
-- --------------------------------------------------------------------------

--- ★ 载入**之前**调用: 只做"同步读框架设置文件"（不注册任何东西）——
---   因为此时 `Config` 还没载入，判断不了 `options_framework` 开关 ✓
function Options.load_pre()
    pcall(function()
        local n, note = Options.load_saved_overrides()
        if n ~= nil and n > 0 then
            Log.emit(string.format("模组选项框架: 启动时同步读取它的设置（%s）", tostring(note)))
        end
    end)
end

function Options.init()
    pcall(function()
        local n, note = Options.load_saved_overrides()
        if n ~= nil and n > 0 then
            Log.emit(string.format("模组选项框架: 启动时同步读取它的设置（%s）", tostring(note)))
        end
    end)
    local ok, mod = pcall(require, "PalModOptionsClient")
    if not ok or mod == nil then
        Options.last_error = tostring(mod)
        Log.emit("Mod Options Framework: **不可用**（没找到 PalModOptionsClient.lua）"
            .. " ⇒ 继续用内置配置（pwpr_keys.json / pwpr_config.json）")
        return false
    end
    Options.client, Options.available = mod, true
    solid("已加载 PalModOptionsClient")
    local ok2, err = pcall(function()
        mod.register_when_ready(build_schema(), function(settings, registration_error)
            if settings == nil then
                Options.last_error = tostring(registration_error)
                solid("注册失败 " .. tostring(registration_error))
                Log.emit("Mod Options Framework: 注册失败 —— " .. tostring(registration_error))
                return
            end
            Options.registered, Options.values = true, settings
            solid("注册成功")
            Log.emit("Mod Options Framework: **已接入** ✓（Esc → 模组选项 → PWProjection）")
            pcall(function() apply_values(settings, "callback") end)
            pcall(function()
                local okw, note = write_back(settings)
                Log.emit("  UI 值 → pwpr_keys.json: " .. (okw and "成功" or "失败")
                    .. "（" .. tostring(note) .. "）")
            end)
        end)
    end)
    if not ok2 then
        Options.last_error = tostring(err)
        solid("register_when_ready 抛错 " .. tostring(err))
        Log.emit("Mod Options Framework: 注册调用抛错 —— " .. tostring(err))
        return false
    end
    solid("已发起 register_when_ready（设置页 v3）")
    return true
end

function Options.capture_active()
    if Options.available and Options.client ~= nil and Options.client.capture_active ~= nil then
        local ok, r = pcall(function() return Options.client.capture_active() end)
        if ok then return r == true end
    end
    return false
end

--- ★ 总开关: 关掉 ⇒ **所有快捷键都不生效**（`main.lua` 据此跳过所有 `bind_action`）
function Options.hotkeys_enabled()
    return Options.master_on ~= false
end

function Options.status_lines()
    local out = {}
    if Options.master_on == false then
        out[#out + 1] = "★ 快捷键总开关: **已关闭**（UI 里关的）⇒ 本模组所有快捷键都不生效"
    end
    if Options.arrow_mode ~= nil then
        out[#out + 1] = "  方向键默认模式(UI): " .. tostring(Options.arrow_mode)
    end
    if Options.available ~= true then
        out[#out + 1] = "模组选项框架: 未装（用内置配置 pwpr_keys.json / pwpr_config.json）"
        if Options.last_error ~= nil then
            out[#out + 1] = "  （加载失败原因: " .. tostring(Options.last_error):sub(1, 120) .. "）"
        end
        return out
    end
    if Options.registered == true then
        local n = 0
        pcall(function() for _ in pairs(Options.values or {}) do n = n + 1 end end)
        out[#out + 1] = string.format("模组选项框架: **已接入** ✓（Esc → 模组选项 → PWProjection，读到 %d 项）", n)
    else
        out[#out + 1] = "模组选项框架: 已加载、**注册未完成**"
        if Options.last_error ~= nil then
            out[#out + 1] = "  原因: " .. tostring(Options.last_error):sub(1, 140)
        end
    end
    return out
end

return Options
