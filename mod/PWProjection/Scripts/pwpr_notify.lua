--[[ ===========================================================================
  PWPR · notify —— 屏幕提示【策略层】

  分工:
    pwpr_hud.lua    通道层 —— "怎么把一行字送到画面上"（引擎调用都在那边）
    pwpr_notify.lua 策略层 —— "什么时候提示、提示什么、要不要节流"（本文件，纯 Lua）

  ============================================================================
  为什么要这一层
  ============================================================================
  玩家的诉求是: 采集 / 加载蓝图 / 放投影 / 切模式 / 切分层 ——
  **每次操作后屏幕上有一行字**，不用去翻日志。

  以前的即时反馈全走 UE4SS 控制台（print）。现在:
    · 屏幕上那一行 -> 交给通道层（最好是游戏内通道，退而求其次控制台）
    · 日志文件那一行 -> 本层顺手写，格式固定为 "> 中文"
      （前缀 ">" 让"玩家当时看到的那一行"在几百行诊断日志里能一眼找到）

  ============================================================================
  ★ 只发"一行"，而且要和诊断输出分开
  ============================================================================
  诊断输出（Log.emit 那一大堆）保持不变 —— 它是排查问题用的。
  屏幕提示是给玩家看的，必须短、必须一次只讲一件事。

  节流: 小键盘/方向键是按键重复速率触发的，一秒钟能来十几次。
  不节流的话屏幕上会刷屏。所以同一时间窗内只发第一条
  （窗口长度 = 配置 notify_min_interval，默认 0.25 秒）。

  开关: 统一用 pwpr_config.json 的 hud_enabled（默认 true）。
  ★ 控制台通道零风险，所以默认开；高风险的游戏内通道各有自己的 gate，默认关。
=========================================================================== ]]

local Log = require("pwpr_log")
local Hud = require("pwpr_hud")
local Config = require("pwpr_config")

local Notify = {}

Notify.count = 0            -- 累计发出条数
Notify.throttled = 0        -- 被节流丢掉的条数
Notify.last_text = nil
Notify.last_t = nil

--- 按键一览（★ 单一来源）
---
--- 为什么放在这里: F7 帮助、屏幕提示、以后"改键"都要用它。
--- 写死在两处迟早会不一致，所以只留一份。
--- ★ 硬约束: **不要提供修饰键组合** ——
---   UE4SS 的 RegisterKeyBindAsync(key, {}, fn) 在按住修饰键时照样触发，
---   所以 "Alt+↑" 会同时触发 "Alt+↑" 和 "↑" 两个回调（玩家实测报过这个 bug）。
Notify.KEYS = {
    -- ★ 2026-10-06: 带 `id` 的行 = **按键可配置**的动作 ⇒ 显示时从 `pwpr_keys.lua` 取
    --   玩家实际生效的键（`Keys.label(id)`），不再是写死的默认键；说明文字仍在这里。
    --   没带 `id` 的行是小键盘/方向键别名（不进配置，按 规矩 4c 只当"有的话顺便能用"）。
    { group = "main",   id = "help",        key = "F7",  cn = "帮助 / 当前状态",        en = "help / status" },
    { group = "main",   id = "reload",      key = "F8",  cn = "重载 pwpr_config.json（★ 不会重绑按键）", en = "reload config" },
    { group = "main",   id = "capture",     key = "Y",   cn = "采集（半径见 capture_radius_m；设 0 = 采全部）", en = "capture" },
    { group = "main",   id = "library",     key = "J",   cn = "蓝图库: 下一张并加载",    en = "library: next" },
    { group = "main",   id = "ghost",       key = "K",   cn = "投影: 放 / 收（放下时自动对齐、并沿用上次位置与进度）", en = "ghost: show/hide" },
    { group = "main",   id = "layer",       key = "L",   cn = "投影: 切分层",            en = "ghost: cycle layer" },
    { group = "main",   id = "site_cycle",  key = "U",   cn = "★ 投影: 换一处记录（同一张蓝图的多处放置记录之间切换）",
                                                                     en = "ghost: next recorded site" },
    { group = "main",   id = "resnap",      key = "H",   cn = "投影: 重新定位到你脚下（= 记成新的一处位置）",
                                                                     en = "ghost: move to player" },
    { group = "main",   id = "probe",       key = "N",   cn = "渲染能力探测（S3）",      en = "capability probe" },
    { group = "main",   id = "notify_probe",key = "O",   cn = "屏幕提示通道探测（S9）",  en = "notify probe" },
    { group = "main",   key = "snap_key", cn = "★ 投影对齐（默认不绑；要用的在配置里设 snap_key）",
                                                                     en = "snap (config snap_key)" },

    { group = "arrow",  id = "mode", key = "F9",  cn = "切换方向键模式: 移动/旋转/材质", en = "cycle arrow mode" },
    { group = "arrow",  key = "↑↓←→", cn = "按当前模式做事（见屏幕提示）", en = "do arrow action" },

    { group = "numpad", key = "NUM 8/2", cn = "前 / 后",             en = "forward / back" },
    { group = "numpad", key = "NUM 4/6", cn = "左 / 右",             en = "left / right" },
    { group = "numpad", key = "NUM 9/3", cn = "上 / 下",             en = "up / down" },
    { group = "numpad", key = "+ / -",   cn = "逆 / 顺时针旋转",     en = "rotate" },
    { group = "numpad", key = "NUM 5",   cn = "清掉偏移与旋转",      en = "reset offset", same_as = "resnap" },
    { group = "numpad", key = "NUM 7",   cn = "建筑吸附",            en = "snap-key action", same_as = "snap" },
    { group = "numpad", key = "NUM 0",   cn = "换微调步长",          en = "cycle step" },
    { group = "numpad", key = "NUM 1",   cn = "★ 紧急收回屏幕提示控件", en = "drop notify widget" },
    { group = "numpad", key = "*",       cn = "换投影材质",          en = "cycle material" },
}

--- 这一行**实际显示**的键: 有 `id` 就取玩家生效的键（改过键也如实显示），否则用写死的。
--- `same_as` = "这一行等价于某个主键动作" ⇒ 补一句"（= 主键 X，没有小键盘就用 X）"，
--- 而且那个 X 也要跟着玩家改的键走（2026-10-06: 以前写死 `H`/`U`，改了键就说不一致）。
local function display_key(k)
    if k.id == nil then return k.key end
    local ok, Keys = pcall(require, "pwpr_keys")
    if not ok or Keys == nil then return k.key end
    local got = nil
    pcall(function() got = Keys.label(k.id) end)
    if type(got) == "string" and got ~= "" then
        local p = nil
        pcall(function() p = Keys.pretty(got) end)   -- ★ 键名美化（NINE → 9 等）
        return p or got
    end
    -- 没绑上（配置非法且默认也不可用）⇒ 明说，别让玩家以为按这个键有用
    return "未绑"
end

local function cn_text(k)
    local cn = k.cn
    if k.same_as == nil then return cn end
    local ok, Keys = pcall(require, "pwpr_keys")
    local main_key = ""
    if ok and Keys ~= nil then
        pcall(function() main_key = Keys.label(k.same_as) end)
    end
    if type(main_key) ~= "string" or main_key == "" then
        return cn .. "（主键未绑）"
    end
    return string.format("%s（= 主键 %s，没有小键盘就用 %s）", cn, main_key, main_key)
end

--- 按键一览（每行一条，给 F7 和以后的界面用）
function Notify.key_lines()
    local out = {}
    for i = 1, #Notify.KEYS do
        local k = Notify.KEYS[i]
        if i == 1 or Notify.KEYS[i - 1].group ~= k.group then
            out[#out + 1] = ""
            out[#out + 1] = (k.group == "main" and "主键（★ 可在 pwpr_config.json 里改: key_*）"
                or (k.group == "arrow" and "方向键（配合模式键）" or "小键盘（放置微调）"))
        end
        out[#out + 1] = string.format("  %-11s %s     [%s]", display_key(k), cn_text(k), k.en)
    end
    return out
end

--- 一行短提示。cn = 中文（屏幕上要显示的），en = ASCII（控制台看的，可省）。
--- kind: "normal"（默认 = 正常提示/按键反馈，中性/蓝）| "error"（出错，红色样式）
--- 返回 是否真的发出去了（被节流/开关关掉时返回 false）
---
--- ★ 只写日志缓冲（Log.line），不写 Log.emit ——
---   因为控制台那一行由通道层负责打，写两次控制台会重复。
function Notify.show(cn, en, kind)
    cn = tostring(cn or "")
    if cn == "" then return false end
    en = (en ~= nil) and tostring(en) or nil
    if kind ~= "error" then kind = "normal" end

    -- ★ 2026-10-06: 屏幕上那一行也要跟着"改过的键位"走（日志那侧由 Log 的翻译层管）
    pcall(function()
        local Keys = require("pwpr_keys")
        cn = Keys.translate(cn)
        if en ~= nil then en = Keys.translate(en) end
    end)

    -- 日志文件: 固定前缀 ">"，让"玩家当时看到的那一行"可检索
    Log.line("> " .. cn .. (en and ("     [" .. en .. "]") or ""))

    Notify.count = Notify.count + 1

    -- 节流（同一时间窗内只发第一条）
    local win = tonumber(Config.get("notify_min_interval")) or 0.25
    local now = os.clock()
    if Notify.last_t ~= nil and win > 0 and (now - Notify.last_t) < win then
        Notify.throttled = Notify.throttled + 1
        return false
    end
    Notify.last_t = now
    Notify.last_text = cn

    if Hud.enabled ~= true then return false end

    local ok, err = Hud.show(cn, en, kind)
    if not ok then
        -- 屏幕那一行发不出去【不能影响功能】—— 只记一笔，绝不抛错
        Notify.last_error = tostring(err)
    end
    return ok == true
end

--- 把上一次提示再发一次（忽略节流）。给"按了键但什么都没发生"的情况用。
---
--- ★ 函数名原来叫 Notify.repeat —— 这是**语法错误**，整个文件都加载不了。
---   Lua 的 `t.xxx` 里 xxx 必须是标识符，**保留字不行**（repeat/end/do/if...）。
---   静态检查器把它报成了"块结构不平衡"（repeat 被当成块起始关键字），
---   才暴露出来。现在检查器里加了第 10 项专门查这个（见 tools/luacheck.py）。
function Notify.resend()
    if Notify.last_text == nil then return false end
    Notify.last_t = nil
    return Notify.show(Notify.last_text)
end

--- 强制发一条（忽略节流窗口）。
---
--- ★ 什么时候用: "这次操作的结果**必须**让玩家看到"，而它前面刚刚发过一条别的
---   （例: 放下投影先报"已放置"，紧接着吸附完成要报"对上 N/M 件"）。
---   两条落在同一个 0.25 秒窗口里时，后来的那条本来会被丢掉，
---   而"对上多少件"恰恰是玩家最需要看的那一句。
function Notify.show_force(cn, en, kind)
    Notify.last_t = nil
    return Notify.show(cn, en, kind)
end

--- 状态（多行）: 提示层 + 通道层
function Notify.status_lines()
    local out = {}
    out[#out + 1] = string.format(
        "提示层: 已发 %d 条，节流丢掉 %d 条（窗口 %.2f 秒）",
        Notify.count, Notify.throttled,
        tonumber(Config.get("notify_min_interval")) or 0.25)
    local hl = Hud.status_lines()
    for i = 1, #hl do out[#out + 1] = hl[i] end
    return out
end

--- 单行描述
function Notify.describe()
    return string.format("提示: %d 条（节流 %d）; %s",
        Notify.count, Notify.throttled, Hud.describe())
end

--- 探测并选通道（转发给通道层，顺便落一行日志）
function Notify.probe_channels()
    local name, detail = Hud.probe(nil)
    return name, detail
end

return Notify
