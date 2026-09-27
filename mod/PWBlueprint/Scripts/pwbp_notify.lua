--[[ ===========================================================================
  PWBP · notify —— 屏幕提示【策略层】

  分工:
    pwbp_hud.lua    通道层 —— "怎么把一行字送到画面上"（引擎调用都在那边）
    pwbp_notify.lua 策略层 —— "什么时候提示、提示什么、要不要节流"（本文件，纯 Lua）

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

  开关: 统一用 pwbp_config.json 的 hud_enabled（默认 true）。
  ★ 控制台通道零风险，所以默认开；高风险的游戏内通道各有自己的 gate，默认关。
=========================================================================== ]]

local Log = require("pwbp_log")
local Hud = require("pwbp_hud")
local Config = require("pwbp_config")

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
    { group = "main",   key = "F7",  cn = "帮助 / 当前状态",        en = "help / status" },
    { group = "main",   key = "F8",  cn = "重载 pwbp_config.json",  en = "reload config" },
    { group = "main",   key = "Y",   cn = "采集: 玩家附近",          en = "capture: near" },
    { group = "main",   key = "U",   cn = "采集: 全部建筑",          en = "capture: all" },
    { group = "main",   key = "J",   cn = "蓝图库: 下一张并加载",    en = "library: next" },
    { group = "main",   key = "K",   cn = "投影: 放 / 收",           en = "ghost: show/hide" },
    { group = "main",   key = "L",   cn = "投影: 切分层",            en = "ghost: cycle layer" },
    { group = "main",   key = "H",   cn = "投影: 重新吸附到玩家",    en = "ghost: re-snap" },
    { group = "main",   key = "N",   cn = "渲染能力探测（S3）",      en = "capability probe" },
    { group = "main",   key = "O",   cn = "屏幕提示通道探测（S9）",  en = "notify probe" },

    { group = "arrow",  key = "F9",  cn = "切换方向键模式: 移动/旋转/材质", en = "cycle arrow mode" },
    { group = "arrow",  key = "↑↓←→", cn = "按当前模式做事（见屏幕提示）", en = "do arrow action" },

    { group = "numpad", key = "NUM 8/2", cn = "前 / 后",             en = "forward / back" },
    { group = "numpad", key = "NUM 4/6", cn = "左 / 右",             en = "left / right" },
    { group = "numpad", key = "NUM 9/3", cn = "上 / 下",             en = "up / down" },
    { group = "numpad", key = "+ / -",   cn = "逆 / 顺时针旋转",     en = "rotate" },
    { group = "numpad", key = "NUM 5",   cn = "清掉偏移与旋转",      en = "reset offset" },
    { group = "numpad", key = "NUM 0",   cn = "换微调步长",          en = "cycle step" },
    { group = "numpad", key = "NUM 1",   cn = "★ 紧急收回屏幕提示控件", en = "drop notify widget" },
    { group = "numpad", key = "*",       cn = "换投影材质",          en = "cycle material" },
}

--- 按键一览（每行一条，给 F7 和以后的界面用）
function Notify.key_lines()
    local out = {}
    for i = 1, #Notify.KEYS do
        local k = Notify.KEYS[i]
        if i == 1 or Notify.KEYS[i - 1].group ~= k.group then
            out[#out + 1] = ""
            out[#out + 1] = (k.group == "main" and "主键"
                or (k.group == "arrow" and "方向键（配合 F9 的模式）" or "小键盘（放置微调）"))
        end
        out[#out + 1] = string.format("  %-11s %s     [%s]", k.key, k.cn, k.en)
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
