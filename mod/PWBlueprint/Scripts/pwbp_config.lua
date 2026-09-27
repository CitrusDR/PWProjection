--[[ ===========================================================================
  PWBP · config  ——  配置读写（纯 Lua）

  配置放在 Mods\PWBlueprint\Scripts\pwbp_config.json。
  每次启动读一次；热键改配置后立刻回写，不需要重启游戏。

  重要安全项:
    ghost_enabled   默认 false。投影渲染会"创建对象"，在能力探测（S3）
                    证明每个原语可用之前，这个开关即使打开也不会生效。
                    这是本 mod 唯一的破坏性功能，默认锁死。
=========================================================================== ]]

local Util = require("pwbp_util")
local Json = require("pwbp_json")

local Config = {}

Config.path = nil
Config.values = {}
Config.loaded_ok = false
Config.load_error = nil
Config.migrated = nil      -- 本次读取是否做了默认值迁移

--- 配置结构版本。
--- ★ 为什么需要: 老配置里已经写进了旧默认值（比如 ghost_material = "highlight"），
---   光改 DEFAULTS 是没用的 —— 文件里的值会把新默认值压掉。
---   所以改默认值时必须能识别"这份文件是旧版本"，并做一次迁移。
---   1 -> 2: ghost_material 默认从 highlight（灰白格子）改成 building（蓝）
---   2 -> 3: hud_enabled 默认从 false 改成 true（屏幕提示）。
---          理由: 屏幕提示的兜底通道是"控制台 print"，**零风险、不会崩**，
---          所以没有理由默认关着。高风险的游戏内通道各有自己的开关
---          （notify_try_client_message / notify_allow_named_1arg），默认仍然是关。
---          ★ 注意: 老版本 Config.save() 会把【全部】已知键写进文件，
---            所以老文件里一定有 hud_enabled = false —— 光改 DEFAULTS 是压不过它的，
---            必须迁移，否则玩家按了键屏幕上一行都不会出现。
---   3 -> 4: notify_try_client_message 默认从 false 改成 true。
---          ★★ 这次我【又犯了一遍同样的错】:
---            我把 DEFAULTS 改成 true，却没做迁移 ——
---            玩家的 pwbp_config.json 里早就写死了 false，
---            Config.get 读的是文件值 → 门禁仍然是关的 →
---            那一整轮"按 O 测试"里 **ClientMessage 根本没被调用过**，
---            于是"没有英文提示"看起来像"ClientMessage 无效"，其实是没测。
---          （教训: 凡是要改某个配置项的【默认值】，就必须同时写迁移。）
---   4 -> 5: notify_try_client_message **改回 false**。---          ★★ 原因: 它在 4 版里被我打开，而实测调用它会**让游戏闪退**
---            （EXCEPTION_ACCESS_VIOLATION reading 0x70）。
---          更根本的教训: `Util.usable=true`（GetFullName 能调通）
---            只能说明"这个名字对应一个真的 UFunction"，
---            **完全不能说明"UE4SS 用这几个参数调它是安全的"**。
---            这已经是第三次被"反射里存在"误导（IsValid / ForEachProperty / 这次）。
---          现在这个通道被标成 never_call —— 连探测都不会去调它。
---   5 -> 6: 把两个"玩家文件里被钉住的旧默认值"拉回新默认值:
---            notify_autohide            false -> true （提示会自动消失）
---            notify_widget_class_name   WBP_Warning_LowMemory_C -> WBP_IngameSmesTop_C
---            notify_widget_text_child   Text_Warning -> BPPalTextBlock_Smes_01
---            notify_widget_class_path   旧的 WBP_Notice 路径 -> ""
---          ★ 这与"只写非默认值"的 save 改动是配套的:
---            以后改默认值就不用再写迁移了（文件里没写 = 跟着默认值走）。
---          迁移只改"值恰好等于旧默认值"的那些 —— 玩家自己改过的不动。
---   6 -> 7: hud_seconds 4 -> 10 秒（玩家反馈 4 秒太短，采集卡一下就没时间看了）。
local CONFIG_VERSION = 7

local DEFAULTS = {
    config_version     = CONFIG_VERSION,
    -- ---- 采集 ----
    capture_radius_m   = 150,     -- 按 Y 采集"玩家附近"的半径（米）
    capture_max        = 6000,    -- 单次采集上限，防止把整个存档一次抓爆
    layer_gap_cm       = 200,     -- 层聚类阈值：相邻 Z 差超过它就分新层
    origin_snap_m      = 1.0,     -- 蓝图原点吸附到多少米的网格

    -- ---- 蓝图库 ----
    blueprint_dir      = "",      -- 留空 = <mod>\blueprints

    -- ---- 投影（默认关闭，受能力探测门禁）----
    ghost_enabled      = false,
    ghost_layer_mode   = "all",   -- all | single | range
    ghost_layer_index  = 0,
    ghost_max_instances = 6000,   -- 超过就拒绝渲染（保护帧率）
    ghost_show_on_top  = true,    -- 用游戏自带 Highlight 材质

    -- ---- 交互步长 ----
    nudge_step_cm      = 100,     -- 小键盘一次挪多少厘米
    rotate_step_deg    = 15,      -- 一次转多少度
    height_step_cm     = 100,

    -- ---- 投影外观/位置 ----
    -- 投影材质。循环里保留 4 档（游戏里 F9 进 material 模式，←/→ 切换）：
    --   building  = 蓝   MI_LooksPredicatorBuilding      ← 默认
    --   error     = 红   BuildingSurfaceMaterialSet.Error
    --   dismantle = 黄   MI_LooksPredicatorDismantle（建造即将完成）
    --   original  = 彩色 不覆盖材质，用网格自己的
    --
    -- 另外这几个填进来也能用（只是不进循环）：
    --   highlight = 灰白格子 MI_LooksPredicatorNormal
    --   building2 = 蓝色双面渲染版 MI_LooksPredicatorBuilding_TwoSided
    --   complete  = MI_BuildObjectComplete（建造完成态）
    --   beforefix = MI_LooksPredicatorBeforeFix
    ghost_material     = "building",

    -- 玩家"脚底"相对 Actor 原点的距离（厘米）。
    -- 0 = 自动（读角色胶囊体半高，读不到就用 90）
    -- 如果投影仍然浮空或陷入地面，直接改成具体数字微调。
    player_feet_offset_cm = 0,

    -- ---- 诊断 ----
    verbose            = true,
    probe_max_step     = 0,       -- 能力探测只跑到第 N 步（0 = 全部跑）

    -- ---- 屏幕提示（S9 / 待办 1）----
    --
    -- 默认 true: 兜底通道是控制台 print（零风险），没有理由关着。
    hud_enabled        = true,
    -- 提示停留几秒（玩家反馈 4 秒太短 → 默认 10）。
    -- ★ 采集/加载/渲染这类"会卡一下"的操作，卡住的时间也算在里面 ——
    --   所以代码那边还做了两件事: ① 每次发新提示会让旧定时器作废；
    --   ② 回标题/换世界时定时器不碰控件（防野指针崩溃）。
    hud_seconds        = 10.0,
    -- 走哪条通道。auto = 自动挑（游戏内通道优先，没有就控制台）
    notify_channel          = "auto",   -- auto | console | client_message | named_call
    -- 屏幕提示节流窗口（秒）。小键盘/方向键是按键重复速率触发的，不节流会刷屏。
    notify_min_interval     = 0.25,
    -- ---- ↓↓↓ 高风险通道（默认全关，必须显式打开）↓↓↓
    -- ★★ 2026-09-27 **永久改回 false** —— 这一项会让游戏闪退。
    --   实测: 调用 `pc:ClientMessage(...)` → EXCEPTION_ACCESS_VIOLATION reading 0x70。
    --   它和 PrintString 属于同一类: **名字能解析（Util.usable=true）
    --   不代表能安全调用**。这已经是本项目第三次被"反射里存在"误导。
    --   现在连探测的"真发一行测试文字"都会拒绝调用它（never_call）。
    notify_try_client_message = false,
    notify_allow_named_1arg   = false,  -- 允许尝试调用 notify_func 指定的函数（1 个字符串参数）
    notify_func               = "",     -- notify_allow_named_1arg 用的函数名（从 pwbp_ui.txt 里抄）
    -- ---- 游戏内中文提示（★ 默认开）----
    -- 走 Palworld 自己的通知控件: 找到活着的 TextBlock 后 SetText(FText("中文"))。
    -- 用的是 UMG 标准函数（SetText / SetVisibility，参数个数公开已知），
    -- 而且 FirstPerson 实机就在直接调用 SetText —— 所以风险等级是 mid 不是 high。
    -- 万一它把不该改的文本改了，把这里改成 false 就恢复"只走控制台"。
    notify_try_notice_text    = true,
    -- ★ 用【我们自己创建】的通知控件（Create Widget + AddToViewport），而不是
    --   往游戏现有的控件里写。为什么必须自己造:
    --   Palworld 的 WBP_Notice 平时只有 CDO（设计稿），活实例只在游戏要弹通知时才有。
    --   第一版没分清 CDO 和活实例，往 CDO 上 SetText —— 调用"成功"了（8 条 0 失败），
    --   但那个控件**根本不在画面上**，所以一个字都看不见。
    notify_own_widget         = true,
    -- 自己造控件时用的类（活着的实例拿不到时才用这个路径去 LoadAsset）
    notify_widget_class_path  = "",
    -- ★★★ 复制哪个控件类 —— 这是读了 SBB 之后改的关键一项。
    --   SBB 左下角那条进度提示是**它自己的 UMG 控件**画的；它复制的控件
    --   **天生就是"独立浮层"**（有锚点、有尺寸）。
    --   我们以前复制 WBP_Notice（**通知列表里的一项**）—— 单独拿出来布局是空的，
    --   所以"在视口里、不透明、有期望尺寸，却什么都看不见"。
    --   下面这个是游戏自带的**警告条** —— 实测**一直有效**的那个:
    --   屏幕上那些中文提示（红色条）就是它画的。
    --   ★ 2026-09-27 玩家反馈后的结论:
    --     WBP_IngameSmesTop_C 用"父链点亮"之后**确实能显示**了，
    --     但它长得像"升级提示"，观感不对 ⇒ 改回警告条。
    --     颜色目前没法自定义（_G.FLinearColor/_G.FSlateColor 都没暴露），
    --     所以"用哪个控件"就是唯一的颜色选择。
    notify_widget_class_name  = "WBP_Warning_LowMemory_C",
    -- 上面那个控件里，显示文字的子控件名（用 GetWidgetFromName 直接取 —— SBB 的姿势）
    notify_widget_text_child  = "Text_Warning",
    -- ★★ 出错样式留空 = **不单独维护第二套控件**，出错也走上面那一条。
    --   为什么这么定（2026-09-27 玩家反馈）:
    --     ① 颜色没法自定义 ⇒ 两种样式的唯一区别只是"用哪个控件"；
    --     ② 而另一套控件（SmesTop）长得像升级提示，观感不对；
    --     ③ 两套控件同时存在会带来"旧文字一直挂在屏幕上"这类问题。
    --   ⇒ 一套控件、一套样式，简单可靠。以后想分颜色再填这里即可。
    notify_error_class_name   = "",
    notify_error_text_child   = "",
    -- ★ 是否允许"借用路线": 往**游戏自己的**活文本框里写我们的字（写完延时还原）。
    --   默认 **false** —— 理由:
    --     ① 自建控件那条路已经走通（Create + AddToPlayerScreen 实测能显示），
    --        完全没必要再动游戏自己的 UI；
    --     ② "不改动游戏原有 UI" 本身就是一个应该守住的边界 ——
    --        玩家的通知/提示不该被我们的状态行挤掉。
    --   只在排查"自建控件为什么不行"时临时打开。
    notify_allow_borrow       = false,
    -- 某个样式创建失败后，多久之内不再重试（秒）。
    -- ★ 为什么需要: 失败的那个半成品控件如果反复创建，会堆在视口里 →
    --   引擎每帧都要处理它们 → 后续在别的操作上崩（2026-09-27 rotate 崩溃的嫌疑）。
    notify_style_retry_s      = 60,
    -- ★ 发送路径的"额外引擎调用"开关。
    --   默认 false: 发一次提示只做三件事（找文本框 -> SetText -> 让它可见）。
    --   以前每次都顺带查"在不在视口/期望尺寸/根控件"等约 10 次引擎接口，
    --   既是性能负担，也增加了"碰到已销毁对象"的机会（崩溃排查相关）。
    --   需要诊断信息时打开它，或用 O 探测（那里有完整遥测）。
    notify_send_telemetry     = false,
    -- ★ 发送时是否允许"遍历全局文本控件表"兜底（默认 false）。
    --   老实现每次发送都遍历 ~2400 个缓存对象逐个 GetFullName ——
    --   缓存里的对象可能已被游戏销毁 → 野指针 → 崩游戏。
    --   只在排查"文本框找不到"时临时打开。
    notify_scan_in_send       = false,
    -- ★ O 探测里的"浮层试用"（建 3 个游戏浮层控件各写一个 PG#n 标记）。
    --   默认 **false**: 它已经完成使命（证明了机制可行、挑出了可用的控件类），
    --   而每次按 O 都会弹出"睡眠中"那个大框 —— 太打扰了。
    --   以后想再试别的控件类，把它打开再按 O。
    probe_overlay_test        = false,
    -- ★ O 探测里的"标记测试"和"测试 B"（会真的改写**游戏自己的**文本框，延时还原）。
    --   默认 **false**: 它们的使命已经完成（证明了"控件属性问不出在不在屏幕上"、
    --   "同一段字可能有多份拷贝"），不该每次按 O 都去动游戏的 UI。
    probe_marker_test         = false,
    -- ★★★ 世代守卫（"回标题 → 重进世界"相关的保护）总开关。**默认关。**
    --
    -- 为什么默认关（2026-09-28 玩家反馈后的决定）:
    --   为了修"重进世界后第一次按键崩溃"，我加了一套"世界世代标记"守卫，
    --   结果标记本身不稳定 ⇒ 刚建好的投影被自己判成"换世界"整个丢掉
    --   （日志: `[ghost] 已丢弃引用: apply_transform: 世界已切换` → 组件=0 → "0 件"），
    --   通知控件也每次重建 ⇒ 旧提示堆在屏幕上。
    --   ⇒ 玩家要求**先退回原来能用的状态**，这个 bug 单独慢慢修。
    --
    -- 现在怎么用这个开关:
    --   · false（默认）= 完全按老行为走: 不比对世代、不自动丢引用 ⇒ 功能稳定；
    --     代价: "回标题 → 重进世界"后第一次发提示/放置仍可能崩（老 bug）。
    --   · true = 打开守卫（给"单独修这个 bug"时用: 打开后只需要复现重进场景，
    --     不影响其他功能）。
    --
    -- 彻底修好之前，建议的安全用法: 回标题后**重启游戏**再进世界；
    -- 或者把 notify_own_widget 改成 false（只走控制台、完全不碰 UI 控件）。
    world_guard_enabled       = false,
    -- 借用路线的筛选: 控件全名里包含这个字符串。
    -- ★ 只会匹配【活实例】（在 /Engine/Transient 下的），CDO 一律忽略。
    notify_textblock_filter   = "WBP_Notice",
    -- 文本控件扫描缓存有效期（秒）。全场景 5000+ 个文本控件，
    -- 每扫一次 = 5000+ 次 GetFullName（踩坑记录 10-7: 在游戏主线程做几万次会卡）。
    -- 发送提示是按一次键一次，没有这个缓存就会"每按一次卡一下"。
    notify_textblock_cache_s  = 5,
    -- ★ 按内容反查控件: 把【你此刻在屏幕上看到的那段文字】填进来（一部分就行），
    --   按 O 时会逐个回读所有活文本控件的当前文字，把命中的控件全名列出来。
    --   例: 屏幕上出现「默世鹿打到了企丸丸」时，这里填 "打到" ——
    --   报告里就会直接写出"是哪个控件在显示这行字"，不用再猜控件名。
    --   ★★ 第二个用途（更关键）: 测试 B 会把**这段文字的每一份拷贝全写上 GP#n**，
    --      用来判断"SetText 到底能不能进渲染"。
    --   留空也行 —— 探测程序内置了一个"玩家实测看得见"的候选字（目前语言），
    --   也可以填任何你在屏幕上看到的字。
    notify_probe_grep         = "",
    -- 自己的控件显示几秒后自动收起。
    -- ★ 2026-09-27 默认改成 true: 通道已经验证可用，而"提示一直挂在屏幕上"
    --   才是更烦的问题。秒数用 hud_seconds（默认 4 秒），改完按 F8 即时生效。
    notify_autohide           = true,

    -- ---- 启动期"额外动作"开关（默认全关）
    --
    -- 2026-09-26 18:02 有一次崩溃发生在【世界加载完成那一刻】，
    -- 崩溃栈在 UE4SS 的钩子分发路径里。我们的 Lua 那一次一行业务代码都没跑，
    -- 但"在世界加载时注册/触发任何额外钩子"本身是不必要的风险敞口 ——
    -- 现在投影还没解锁，这个钩子暂时没有任何收益。
    -- 所以默认关闭，等真正需要跨世界保持引用时再打开。
    hook_load_map_pre  = false,   -- LoadMapPre 时丢弃引用（换取"不碰引擎"）

    -- 启动时用 io.popen 扫蓝图目录 = 在游戏启动期 spawn 一个 cmd.exe。
    -- 没必要。索引文件由 Library.save 自动维护，默认不扫。
    library_scan_on_refresh = false,
}

local function deep_copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

function Config.defaults()
    return deep_copy(DEFAULTS)
end

function Config.get(key)
    local v = Config.values[key]
    if v == nil then return DEFAULTS[key] end
    return v
end

function Config.set(key, value)
    Config.values[key] = value
end

--- 把外部读进来的表合并进 values，只接受已知键，且做类型校验
local function merge_known(raw)
    local n_ok, n_bad = 0, 0
    if type(raw) ~= "table" then return n_ok, n_bad end
    for k, v in pairs(raw) do
        local d = DEFAULTS[k]
        if d == nil then
            n_bad = n_bad + 1
        elseif type(v) == type(d) then
            Config.values[k] = v
            n_ok = n_ok + 1
        else
            n_bad = n_bad + 1
        end
    end
    return n_ok, n_bad
end

--- 返回 配置表, 状态字符串
function Config.load(script_dir)
    Config.path = Util.join(script_dir, "pwbp_config.json")
    Config.values = {}
    Config.loaded_ok = false
    Config.load_error = nil

    if not Util.file_exists(Config.path) then
        Config.load_error = "配置文件不存在，已生成默认配置"
        Config.save()
        return Config.values, Config.load_error
    end

    local text, err = Util.read_file(Config.path)
    if text == nil then
        Config.load_error = "读配置失败: " .. tostring(err)
        return Config.values, Config.load_error
    end

    local parsed, perr = Json.decode(text)
    if parsed == nil then
        Config.load_error = "配置 JSON 解析失败，已用默认值: " .. tostring(perr)
        return Config.values, Config.load_error
    end

    local n_ok, n_bad = merge_known(parsed)
    Config.loaded_ok = true
    Config.load_error = nil

    -- ---- 默认值迁移 ------------------------------------------------------
    local ver = tonumber(Config.values.config_version) or 0
    if ver < CONFIG_VERSION then
        local notes = {}
        -- v1 的 4 档是"探索期"的候选，玩家把它们挨个翻过一遍来找蓝色，
        -- 所以文件里存下来的多半是测试留下的值，不代表偏好。
        -- 现在蓝色已确定为默认，于是把这一组整体迁到新默认。
        -- （会明确打日志，而且改回来只需按一次 F9 -> → ）
        local OLD_SET = {
            highlight = true, error = true,
            dismantle = true, original = true,
        }
        local cur = Config.values.ghost_material
        if ver < 2 and type(cur) == "string" and OLD_SET[cur] then
            Config.values.ghost_material = DEFAULTS.ghost_material
            notes[#notes + 1] = string.format(
                "ghost_material: %s -> %s（新默认=蓝色；想改回按 F9）",
                cur, tostring(DEFAULTS.ghost_material))
        end
        -- v2 -> v3: 屏幕提示默认打开（兜底通道是控制台，零风险）
        if ver < 3 and Config.values.hud_enabled ~= true then
            local old_hud = Config.values.hud_enabled
            Config.values.hud_enabled = DEFAULTS.hud_enabled
            notes[#notes + 1] = string.format(
                "hud_enabled: %s -> %s（屏幕提示默认开；不想看就改回 false）",
                tostring(old_hud), tostring(DEFAULTS.hud_enabled))
        end
        -- v3 -> v4: ClientMessage 默认打开（实测证明它是真方法，见 CONFIG_VERSION 注释）
        if ver < 4 and Config.values.notify_try_client_message ~= true then
            local old_cm = Config.values.notify_try_client_message
            Config.values.notify_try_client_message = DEFAULTS.notify_try_client_message
            notes[#notes + 1] = string.format(
                "notify_try_client_message: %s -> %s（实测它是真方法，默认开；不想用改回 false）",
                tostring(old_cm), tostring(DEFAULTS.notify_try_client_message))
        end
        -- v4 -> v5: ClientMessage 改回 false（调用它会闪退，实测）
        if ver < 5 and Config.values.notify_try_client_message ~= false then
            local old_cm = Config.values.notify_try_client_message
            Config.values.notify_try_client_message = false
            notes[#notes + 1] = string.format(
                "notify_try_client_message: %s -> false（★实测会闪退，已禁用）",
                tostring(old_cm))
        end
        -- v5 -> v6: 把被旧默认值钉住的几项拉回新默认值
        --   判据: 值**恰好等于旧默认值** ⇒ 几乎肯定是"当年保存下来的默认值"，
        --   而不是玩家有意选择（有意选的话一般会选个别的值）。
        if ver < 6 then
            local fix = {
                { key = "notify_autohide",          old = false, new = true },
                { key = "notify_widget_class_name", old = "WBP_Warning_LowMemory_C",
                  new = DEFAULTS.notify_widget_class_name },
                { key = "notify_widget_text_child", old = "Text_Warning",
                  new = DEFAULTS.notify_widget_text_child },
                { key = "notify_widget_class_path",
                  old = "/Game/Pal/Blueprint/UI/UserInterface/InGame/Notice/WBP_Notice.WBP_Notice_C",
                  new = "" },
            }
            for i = 1, #fix do
                local f = fix[i]
                if Config.values[f.key] == f.old then
                    Config.values[f.key] = f.new
                    notes[#notes + 1] = string.format("%s: %s -> %s（旧默认值，已随新版更新）",
                        f.key, tostring(f.old), tostring(f.new))
                end
            end
        end
        -- v6 -> v7: 提示停留时长 4 秒 -> 10 秒（玩家反馈 4 秒太短）
        --   ★ 注意: 有了"只写非默认值"的 save 之后，**没动过**这一项的玩家
        --     文件里根本没有这个键，自动就是新默认值 —— 这段迁移只为
        --     "文件里还残留着 4" 的情况兜底。
        if ver < 7 and (Config.values.hud_seconds == 4 or Config.values.hud_seconds == 4.0) then
            Config.values.hud_seconds = DEFAULTS.hud_seconds
            notes[#notes + 1] = string.format("hud_seconds: 4 -> %s（4 秒太短，已加长）",
                tostring(DEFAULTS.hud_seconds))
        end
        Config.values.config_version = CONFIG_VERSION
        Config.migrated = table.concat(notes, "; ")
        pcall(Config.save)
        return Config.values, string.format(
            "配置: %d 项生效, %d 项忽略; 已从 v%d 迁移到 v%d%s",
            n_ok, n_bad, ver, CONFIG_VERSION,
            Config.migrated ~= "" and ("（" .. Config.migrated .. "）") or "")
    end

    return Config.values, string.format("配置: %d 项生效, %d 项忽略", n_ok, n_bad)
end

function Config.save()
    if Config.path == nil then return false, "path not initialised" end
    -- ★★★ 2026-09-27 **结构性修改**: 只写"和默认值不同"的键（= 用户真的动过的），
    --   外加 config_version。
    --
    -- 为什么必须这么改（这个坑咬了四次）:
    --   老实现把**全部默认值**都写进文件。于是以后我们**改默认值**时，
    --   老玩家文件里那份旧值永远压过新默认值 —— 代码改了、玩家没生效，
    --   现象是"功能明明实现了却不出效果"，而且极难想到原因。
    --   中招记录: hud_enabled / notify_try_client_message / notify_probe_grep /
    --   notify_autohide + notify_widget_class_name（颜色和自动消失都不生效）。
    --
    -- 新行为: 文件里**没有**的键 = 用代码里的默认值。
    --   我们改默认值 → 玩家自动跟着变；玩家自己改过的键 → 仍然写进文件、永远保留。
    local out = {}
    for k, v in pairs(Config.values) do
        if k ~= "config_version" then
            local d = DEFAULTS[k]
            if d ~= nil and v ~= d then
                out[k] = v
            end
        end
    end
    out.config_version = CONFIG_VERSION
    local text = Json.encode(out, true)
    return Util.write_file(Config.path, text .. "\n", true)
end

--- 供帮助界面显示
function Config.brief_lines()
    return {
        string.format("  capture_radius_m   = %s", tostring(Config.get("capture_radius_m"))),
        string.format("  layer_gap_cm       = %s", tostring(Config.get("layer_gap_cm"))),
        string.format("  ghost_enabled      = %s", tostring(Config.get("ghost_enabled"))),
        string.format("  ghost_layer_mode   = %s", tostring(Config.get("ghost_layer_mode"))),
        string.format("  nudge_step_cm      = %s", tostring(Config.get("nudge_step_cm"))),
        string.format("  rotate_step_deg    = %s", tostring(Config.get("rotate_step_deg"))),
        string.format("  hud_enabled        = %s", tostring(Config.get("hud_enabled"))),
        string.format("  notify_channel     = %s", tostring(Config.get("notify_channel"))),
    }
end

return Config
