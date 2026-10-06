--[[ ===========================================================================
  PWPR · hud —— 屏幕文字【通道层】（把一行字送到画面上）

  这一层只干一件事: 把一行文字送到游戏画面上。
  它不管"什么时候提示、提示什么、要不要节流" —— 那是 pwpr_notify.lua（策略层）。

  ============================================================================
  为什么不是 PrintString（2026-09-26 实测，永久禁用）
  ============================================================================
  KismetSystemLibrary:PrintString 在 Shipping 构建里【会崩游戏】。
  原因: UE 把"画到屏幕上"那段代码用 #if !(UE_BUILD_SHIPPING...) 编译掉了，
  函数体没了但反射信息还在 -> UE4SS 按反射去调它 -> 访问违例。
  所以"屏幕上显示文字"必须换别的通道，不能靠 PrintString。

  ============================================================================
  ★ 2026-09-27 查到的事实（证据都在本机，不是猜的）
  ============================================================================
  证据文件（本机 UE4SS 目录，可直接打开核对）:
    Mods\FirstPerson\Scripts\main.lua              179 KB，实机在用的 Palworld Lua mod
    Mods\ConsoleCommandsMod\Scripts\dump_object.lua   UE4SS 官方控制台命令
    UE4SS.dll（字符串扫描）                         确认 API 到底存不存在

  1. **FText 可用**: `FText("中文")` 是 UE4SS 暴露的全局构造函数。
     FirstPerson 里就是 `TextBlock:SetText(FText("第一人称"))` —— 中文能进去、能显示。
  2. **反射枚举可用**: UClass 上有 `ForEachFunction` / `ForEachProperty` /
     `GetSuperStruct`（UE4SS.dll 里都有）。
     ⇒ 我们**不需要猜类名** —— 可以先把游戏里真实的函数名连同**参数签名**枚举出来。
     （`dump_object.lua` 用的就是这套。）这是本项目"不要猜类名"教训的正解。
  3. **静态函数库的 CDO 能这样拿**:
     `StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")` -> `lib:Create(...)`
  4. ⚠️ **坑: hook `TextBlock:SetText` 会崩游戏**（FirstPerson 注释里记了两次崩溃 dump，
     它因此把那个 hook 删掉了）。但**直接调用 SetText 是正常的**，它现在就在用。
     区别: hook = 游戏每次调用都进我们的代码（含销毁中的控件）-> 危险；
           直接调用 = 我们自己发起、对象由我们挑 -> 安全。
     **本 mod 只做后者。永远不要 hook UI。**
  5. ⚠️ **GraphicsAPI**: 本机 `UE4SS-settings.ini` 是 `GraphicsAPI = opengl`。
     opengl 后端把调试 GUI 渲染到**独立窗口**（imgui.ini 里的 `Backend_Window`），
     不盖在游戏画面上。想让 print 的文字出现在游戏画面上，
     要改成 `dx11`（且游戏本身跑 DX11）。**这是设置项，不是代码问题。**

  ============================================================================
  通道（channel）
  ============================================================================
  一个"通道" = 一种把文字送到画面上的具体做法。每个通道有 probe（能不能用）和 send。
  ★ 纪律: **send 只在 probe 证明可用之后才会被调用。**
    未经验证的引擎调用 = PrintString 那种崩法，绝不允许直接进渲染路径。

  风险分级（risk）:
    low  = 纯 Lua/print，不可能崩
    mid  = 已确认存在、参数个数已知的标准接口
    high = 参数个数/语义没验证过的调用 -> 必须用配置显式打开（gate）

  兜底: 控制台通道永远可用（print 永远不会崩）。所以"没有任何通道"这个状态不存在。
=========================================================================== ]]

local Util = require("pwpr_util")
local Config = require("pwpr_config")
local Sched = require("pwpr_sched")
-- ★ 2026-09-27: 这个模块以前**没有** require Log ——
--   于是我加的 `if Log ~= nil` 标记全部是空转（日志里一条 [ns] 都没有）。
--   排查"崩在通知路径里"时发现: 标记没生效 = 白等一轮。补上。
local Log = require("pwpr_log")

local Hud = {}

-- 由 main 从配置同步（hud_enabled）。默认 true（见 pwpr_config 的说明）。
Hud.enabled = true
Hud.duration = 4.0

Hud.active = nil            -- 当前通道名（nil = 还没探测过，只有控制台可用）
Hud.probed = false          -- 本次会话是否探测过（探测只在 S9 / 按 O 里做）
Hud.tb_cache = nil          -- 文本控件扫描缓存（见 tb_scan，避免每次按键扫 5000+ 个对象）
Hud.available = false       -- 有没有【游戏内】通道（不含控制台）
Hud.sent = 0
Hud.errors = 0
Hud.last_error = nil
Hud.recent = {}             -- 最近发出的文字（环形，给 F7 看）
Hud.recent_limit = 16
Hud.results = {}            -- 通道名 -> { ok, detail }
Hud.ctx = nil               -- { pc = <PlayerController> }
Hud.PREFIX = "[PWPR] "

-- --------------------------------------------------------------------------
-- FText: Lua 字符串 -> UE 文本对象
-- --------------------------------------------------------------------------

--- 把 Lua 字符串变成 FText。返回 ftext, nil   或   nil, 原因
---
--- 两条路线（第一条是 FirstPerson 实机验证过的，第二条是标准引擎函数兜底）:
---   1) 全局 FText(s)              —— UE4SS 暴露的构造函数
---   2) KismetTextLibrary:Conv_StringToText(s)
---      ★ 这是纯转换函数，**不是** PrintString 那条崩掉的路。
function Hud.ftext(s)
    s = tostring(s or "")
    if FText ~= nil then
        local ok, res = pcall(FText, s)
        if ok and res ~= nil then return res, nil end
    end
    local ok2, res2 = pcall(function()
        return require("UEHelpers").GetKismetTextLibrary():Conv_StringToText(s)
    end)
    if ok2 and res2 ~= nil then return res2, nil end
    return nil, "FText 两条构造路线都不可用（全局 FText / KismetTextLibrary）"
end

--- FText -> Lua 字符串（只用于回读/诊断）。
--- ★ 注意: 这条路是"FText 到底装进去了什么"的硬证据，和材质回读一个思路。
function Hud.ftext_to_string(ft)
    if ft == nil then return nil end
    local ok, s = pcall(function() return ft:ToString() end)
    if ok and type(s) == "string" then return s end
    local ok2, s2 = pcall(function()
        return require("UEHelpers").GetKismetTextLibrary():Conv_TextToString(ft)
    end)
    if ok2 and type(s2) == "string" then return s2 end
    return nil
end

-- --------------------------------------------------------------------------
-- PlayerController
-- --------------------------------------------------------------------------

--- 找本地 PlayerController。拿不到返回 nil。
--- 两种写法都是项目里验证过的: UEHelpers 优先，FindAllOf 兜底。
function Hud.find_pc()
    -- ★★ 顺序很重要（2026-09-28 崩溃根因的连带修复）:
    --   UEHelpers.GetPlayerController() 内部用 `IsValid()` 过滤，
    --   而 IsValid() 在**已销毁的对象**上也可能返回 true ——
    --   于是一个"上个世界的废 PlayerController"会被当成好的返回，
    --   之后拿它 CreateWidget / GetWorld() 就是访问违例。
    --   ⇒ 实现放在 Util.find_pc_strict()（FindAllOf + Util.valid 严格判据，
    --     UEHelpers 只当兜底），这样"世界世代标记"和"发提示"用的是同一套查找，
    --     不会出现两处判据不一致的情况。
    return Util.find_pc_strict()
end

--- 确保 ctx.pc 有值（懒加载: 第一次真的要发文字时才碰引擎）
local function ensure_ctx()
    if Hud.ctx == nil then Hud.ctx = {} end
    if Hud.ctx.pc == nil then
        Hud.ctx.pc = Hud.find_pc()
    end
    return Hud.ctx
end

--- 取对象上的方法，并判断它【大概能不能调用】。
---
--- ★★ 判据在 2026-09-27 被实测纠正了两次，这里是最终版:
---
---   第一版以为「名字不存在时返回 nil」→ 错: 返回的是 userdata。
---   第二版以为「userdata 就是占位对象、不可调用」→ **也错**:
---       对照组 `GetControlRotation`（我们每帧都在用、百分百可用）
---       同样报 `type=userdata`！
---   实测结论（pwpr_ui.txt 第二次）:
---       GetControlRotation  type=userdata   ← 可用，但 type 是 userdata
---       GetWorld            type=function   ← 可用，type 是 function
---   ⇒ **`type()` 分辨不出"可用"和"占位"**。
---
---   所以现在**不做真假判断，只收集信号**，并把判断权交给"对照组":
---     信号 1: type(v)            （function 最明确）
---     信号 2: getmetatable(v).__call 是否存在（userdata 靠 __call 才能被调用）
---     信号 3: Util.usable(v)     （GetFullName 能不能调通）
---   本函数返回这些信号；判读逻辑在 pwpr_probe.lua 的 s9_candidates 里，
---   用「已知可用的方法」当基准来定标。
---
--- 返回 信号表 { type=, has_call=bool, usable=bool, name=string } 或 nil
function Hud.method_signals(obj, name)
    if obj == nil or type(name) ~= "string" or name == "" then return nil end
    local v = nil
    pcall(function() v = obj[name] end)
    if v == nil then
        return { type = "nil", has_call = false, usable = false, name = name }
    end
    local t = "?"
    pcall(function() t = type(v) end)
    local has_call = false
    pcall(function()
        local mt = getmetatable(v)
        has_call = (type(mt) == "table") and (mt.__call ~= nil)
    end)
    local usable = false
    pcall(function() usable = Util.usable(v) end)
    return { type = tostring(t), has_call = has_call, usable = usable, name = name }
end

--- 取对象上的方法（兼容旧调用处）。返回 值, 类型字符串
local function find_callable(obj, name)
    if obj == nil or type(name) ~= "string" or name == "" then return nil, "nil" end
    local v = nil
    pcall(function() v = obj[name] end)
    if v == nil then return nil, "nil" end
    local t = "?"
    pcall(function() t = type(v) end)
    -- ★ 不再要求 type == "function"（那会误杀 GetControlRotation 这类真方法）
    --   只排除 nil。是否真的可调用，由 send 里的 pcall 兜底 ——
    --   未绑定的名字会抛可捕获的 Lua 错误，不会崩游戏。
    return v, tostring(t)
end

-- --------------------------------------------------------------------------
-- 找活着的 UI 控件（找 TextBlock 就靠它）
-- --------------------------------------------------------------------------

--- ★★ 这个对象是"运行时的活实例"，还是"资产/类默认对象（CDO）"？
---
--- 判据来自 2026-09-27 的探测报告（pwpr_ui.txt），是实测对比出来的：
---
---   CDO（设计期控件，不在画面上）:
---     /Game/Pal/Blueprint/UI/.../WBP_Notice.WBP_Notice_C:WidgetTree.BP_PalTextBlock_C_84
---     ↑ 资产路径 + ":WidgetTree." —— 这是"类默认对象里的预览控件"
---   活实例（真的在画面上）:
---     /Engine/Transient.PalGameEngine_2147482588:...WBP_PlayerUI_C_2147443706
---       .WidgetTree_2147443705.WBP_Ingame_PlayerGauge_Separated...Text_MaxHP
---     ↑ 在 /Engine/Transient 下面，带实例编号（WidgetTree_<数字>）
---
--- ★ 第一版就是没分清这两者：往 CDO 上 SetText 明明"成功"（是合法对象、
---   也不会报错），但**那个控件根本不在画面上** —— 这正是
---   "已发=8 失败=0 却一个字都看不见"的原因。
function Hud.is_live(v)
    local fn = Util.full_name(v)
    if type(fn) ~= "string" then return false end
    return fn:find("/Engine/Transient", 1, true) ~= nil
end

--- ★★★ 2026-10-08 **启动清扫: 上次会话残留的提示控件**
---
--- 背景（玩家实测）: 在「模组选项」里点保存 ⇒ `restart_mod` 重载我们的 Mod
---   ⇒ Lua 里那些控件引用（`Hud.styles[...].widget`）全丢了，但控件**还挂在视口上**
---   ⇒ 现象: "屏幕提示语永远不消失" ✗
--- 做法: 用配置里的控件类名找活实例（`FindAllOf`）→ **只处理"在视口里"的那些** →
---   `SetVisibility(Collapsed)` + `RemoveFromParent` ✓
--- ⚠️ 那个类**是游戏自己的类**（我们借用），启动瞬间同类实例里可能混着游戏自己的一条消息
---   ⇒ 会连带把它收掉（不崩，只是少一条提示）—— 所以日志里会写真收掉了几个。
--- 返回: 收回数量
function Hud.cleanup_leftovers()
    local cls = nil
    pcall(function() cls = Config.get("notify_widget_class_name") end)
    if type(cls) ~= "string" or cls == "" then return 0 end
    local lst = nil
    pcall(function() lst = Hud.find_widgets(cls) end)
    if type(lst) ~= "table" then return 0 end
    local n = 0
    for i = 1, #lst do
        local w = lst[i]
        if w ~= nil and Hud.in_viewport(w) then
            pcall(function() w:SetVisibility(Hud.VIS_COLLAPSED) end)
            pcall(function() w:RemoveFromParent() end)
            n = n + 1
        end
    end
    pcall(function()
        local kinds = { "normal", "error" }
        for i = 1, #kinds do
            local st = Hud.styles[kinds[i]]
            if st ~= nil then st.widget, st.textblocks = nil, nil end
        end
    end)
    return n
end

--- 找某个类的存活实例。返回 列表, 原因
function Hud.find_widgets(class_name)
    if type(class_name) ~= "string" or class_name == "" then
        return nil, "类名为空"
    end
    local ok, lst = pcall(function() return FindAllOf(class_name) end)
    if not ok then return nil, "FindAllOf 抛错" end
    if type(lst) ~= "table" then
        return nil, "没有存活实例（FindAllOf 返回 " .. type(lst) .. "）"
    end
    return lst, nil
end

--- 读一个文本控件当前的文字（FText -> Lua 字符串）。读不到返回 nil。
---
--- ★ 有了它才能回答两个关键问题:
---   1) 这个控件现在显示的是什么（挑目标时要知道自己在覆盖什么）
---   2) 我们写进去的字到底有没有真的进去（回读 = 硬证据，同材质回读思路）
function Hud.widget_text(w)
    if w == nil then return nil end
    local t = nil
    pcall(function() t = w:GetText() end)
    if t == nil then return nil end
    return Hud.ftext_to_string(t)
end

--- 扫描全部文本控件（★ 带缓存）。
---
--- 为什么要缓存: 全场景有 5000+ 个文本控件（CDO 也算），
--- 每扫一次就是 5000+ 次 GetFullName —— 踩坑记录 10-7 记过
--- "在游戏主线程上做几万次 GetFullName() 会卡住游戏"。
--- 而发送提示是按一次键来一次的，不缓存就会**每按一次卡一下**。
--- 缓存有效期见配置 notify_textblock_cache_s（默认 5 秒）。
---
--- 返回 entries = { { obj=控件, name=全名, live=是否活实例 }, ... }
local function tb_scan()
    local now = os.clock()
    local secs = tonumber(Config.get("notify_textblock_cache_s")) or 5
    if Hud.tb_cache ~= nil and (now - Hud.tb_cache.t) < secs then
        return Hud.tb_cache.entries
    end

    local entries = {}
    local seen = {}
    local total, lives = 0, 0
    -- FindAllOf 按【继承】匹配（查 "TextBlock" 会连 BP_PalTextBlock_C 一起返回），
    -- 所以只查一次 + 按全名去重，别查多个类名（会拿到重复对象）。
    local lst = Hud.find_widgets("TextBlock")
    if lst ~= nil then
        for k = 1, #lst do
            local w = lst[k]
            total = total + 1
            local fn = Util.full_name(w)
            if type(fn) == "string" and seen[fn] ~= true then
                seen[fn] = true
                local live = fn:find("/Engine/Transient", 1, true) ~= nil
                if live then lives = lives + 1 end
                entries[#entries + 1] = { obj = w, name = fn, live = live }
            end
        end
    end
    Hud.textblock_total, Hud.textblock_live = total, lives
    Hud.tb_cache = { t = now, entries = entries }
    return entries
end

--- 找文本控件。
---   filter    : 非空时只保留【全名里包含 filter】的
---   only_live : true = 只要【活实例】（★ 默认就该这样，见 is_live 的说明）
---
--- 副作用: Hud.textblock_total / Hud.textblock_live 记下总数与活实例数（给探测报告用）
function Hud.find_textblocks(filter, only_live)
    local entries = tb_scan()
    local out = {}
    for i = 1, #entries do
        local e = entries[i]
        if (only_live ~= true or e.live)
            and (filter == nil or filter == "" or e.name:find(filter, 1, true) ~= nil) then
            out[#out + 1] = e.obj
        end
    end
    return out, nil
end

--- 让文本控件缓存失效（我们自己新建了控件之后必须调，否则新控件不在缓存里）
function Hud.invalidate_textblocks()
    Hud.tb_cache = nil
end

--- 读一个控件"能不能被看见"的三个硬指标（诊断"写了字但看不见"必须靠它们）
function Hud.in_viewport(w)
    if w == nil then return nil end
    local r = nil
    pcall(function() r = w:IsInViewport() end)
    return r
end

function Hud.widget_visibility(w)
    if w == nil then return nil end
    local v = nil
    pcall(function() v = w:GetVisibility() end)
    return v
end

function Hud.desired_size(w)
    if w == nil then return nil end
    local s = nil
    pcall(function() s = w:GetDesiredSize() end)
    if s == nil then return nil end
    local x, y = Util.num(s, "X"), Util.num(s, "Y")
    if x == nil or y == nil then return tostring(s) end
    return string.format("%.0fx%.0f", x, y)
end

--- 渲染不透明度。★ "可视性=0(Visible) 但仍然看不见" 的头号嫌疑就是它是 0
--- （WBP 的动画初始姿态常常把透明度设成 0，等 PlayAnimation("Show") 才显示；
---   我们是凭空 Create 的实例，没人给它播动画，所以停在初始姿态）。
function Hud.render_opacity(w)
    if w == nil then return nil end
    local o = nil
    pcall(function() o = w:GetRenderOpacity() end)
    return o
end

--- ESlateVisibility 枚举（UMG 的"可见性"有 5 档，其中 3/4 是"能看见但不吃输入"）
Hud.VIS_VISIBLE                   = 0   -- 渲染 + 吃鼠标/键盘
Hud.VIS_COLLAPSED                 = 1   -- 不渲染、不占布局
Hud.VIS_HIDDEN                    = 2   -- 不渲染、占布局
Hud.VIS_HIT_TEST_INVISIBLE        = 3   -- ★ 渲染，但【不吃输入】
Hud.VIS_SELF_HIT_TEST_INVISIBLE   = 4   -- ★ 渲染，自身不吃输入（子控件可以）

--- 取 UUserWidget 的【根控件】。
---
--- ★ 为什么需要它: 2026-09-27 的关键怀疑 ——
---   UMG 里"外层可见"**不等于**"里面可见"。UUserWidget 是一个壳，
---   真正画东西的是它内部的根控件（`WidgetTree.RootWidget`）。
---   设计师为了"默认隐藏、需要时再显示"，经常把**根控件**设成
---   Collapsed，然后靠代码/动画去切它。
---   我们是凭空 Create 的实例，**没有任何代码去切它** → 整棵树都不渲染，
---   而外层的 `IsInViewport`/`GetVisibility`/`GetDesiredSize` 全都是"正常"的。
---   这正好解释了"什么都对，就是看不见"。
function Hud.root_widget(w)
    if w == nil then return nil end
    local r = nil
    pcall(function() r = w:GetRootWidget() end)
    if r == nil then
        local tree = nil
        pcall(function() tree = w.WidgetTree end)
        if tree ~= nil then
            pcall(function() r = tree.RootWidget end)
        end
    end
    return r
end

--- ★★ 把控件弄成"能看见，但绝对不吃输入"。
---
--- ============================================================================
--- 🔴 2026-09-27 事故（这条注释是给以后的自己看的）
--- ============================================================================
--- 第一版这里写的是 `SetVisibility(0)`（= Visible）—— 结果我们那个控件
--- 挂在 z-order 1000、尺寸铺满屏幕，**把游戏 Esc 菜单的鼠标点击全吃掉了**：
--- 菜单按钮点不动，连"返回标题"都点不了，玩家只能 Alt+F4 强制退。
---
--- 根因是没分清 UMG 里**"渲染"和"吃输入"是两件独立的事**：
---     0 = Visible              → 渲染 + 吃输入   ← 浮层绝对不能用这个
---     3 = HitTestInvisible     → 渲染 + 不吃输入 ← 只显示文字的浮层就该用这个
---     4 = SelfHitTestInvisible → 渲染 + 自己不吃（子控件仍可交互）
--- **给"只显示一行字"的浮层，永远用 3（或 4），永远不要用 0。**
---
--- 顺带: 还要 SetIsFocusable(false)，否则它会抢走键盘焦点。
function Hud.force_display(w)
    if w == nil then return false end
    pcall(function() w:SetVisibility(Hud.VIS_HIT_TEST_INVISIBLE) end)
    pcall(function() w:SetRenderOpacity(1.0) end)
    pcall(function() w:SetIsFocusable(false) end)
    -- ★ 连【根控件】一起弄可见 —— 光设外层不够（见 root_widget 的说明）
    local rw = Hud.root_widget(w)
    if rw ~= nil then
        pcall(function() rw:SetVisibility(Hud.VIS_HIT_TEST_INVISIBLE) end)
        pcall(function() rw:SetRenderOpacity(1.0) end)
    end
    return true
end

--- ★ 沿父链把它【整条链】都点亮。
---
--- 为什么需要: 有些自带浮层的**内容容器默认是折起的**（外层控件看得见，
---   但里面那层是 Collapsed），只设控件本身不够 —— 于是"文字写进去了、
---   回读也对，屏幕上却没有"。把从文本框到根控件这条链上的每一层都设成
---   3（HitTestInvisible: 渲染但不吃输入）就能解决。
function Hud.force_display_chain(w)
    if w == nil then return 0 end
    local n = 0
    local cur = w
    for _ = 1, 12 do
        if cur == nil then break end
        Hud.force_display(cur)
        n = n + 1
        local up = nil
        pcall(function() up = cur:GetParent() end)
        up = Util.unwrap(up)
        if up == nil or not Util.usable(up) then break end
        cur = up
    end
    return n
end

--- 立刻把我们自己加的屏幕提示收起来（手动清理用）。
--- ★ 玩家要求: "加个方法手动把左上角我们加的提示关掉"。
---   即使自动消失没生效、或者想看干净画面，按一下就能清掉。
---   只碰【我们自己的控件】，不动游戏 UI。
function Hud.hide_now()
    local n = 0
    local kinds = { "normal", "error" }
    for i = 1, #kinds do
        local st = Hud.styles[kinds[i]]
        if st ~= nil and st.widget ~= nil then
            pcall(function() st.widget:SetVisibility(Hud.VIS_COLLAPSED) end)
            n = n + 1
        end
    end
    return n
end

--- 【只丢引用，绝不碰引擎】—— 换地图 / 回标题时由 **LoadMapPre 钩子**调用。
---
--- ★★ 为什么必须"只丢引用"（2026-09-28 的方案修正）:
---   上个世界的控件已经被引擎销毁。此时:
---     · 调 `RemoveFromParent` / `RemoveFromRoot` / `SetVisibility` → 在废对象上操作 → 访问违例；
---     · 连 `Util.usable()` / `IsValid()` 去"确认它还活着"都不行 —— 这两个会**撒谎**
---       （在已销毁对象上返回 true）。
---   所以唯一安全的动作就是: **把引用清掉，什么都不碰**。
---   新世界需要提示时，`ensure_own_widget` 会重新建一个。
---
--- 与"轮询世代标记"的分工:
---   · **钩子 = 权威信号**（真的换了地图才会触发）→ 负责"丢引用"；
---   · **轮询 = 只诊断**（标记可能抖动）→ 只打印一行警告、**绝不销毁任何东西**。
function Hud.drop_world_refs(reason)
    local n = 0
    local kinds = { "normal", "error" }
    for i = 1, #kinds do
        local st = Hud.styles[kinds[i]]
        if st ~= nil then
            if st.widget ~= nil then n = n + 1 end
            st.widget, st.textblocks, st.found_by = nil, nil, nil
            -- ★ 注意: 这里**不调用** RemoveFromRoot/RemoveFromParent（那是碰引擎）
            st.rooted = false
            st.world_name = nil
            st.failed_until = nil      -- 新世界重新给这个样式一次机会
            st.fresh, st.child_error = 0, nil
        end
    end
    Hud.own_widget, Hud.own_textblock, Hud.own_textblocks = nil, nil, nil
    Hud.invalidate_textblocks()        -- 扫描缓存里全是上个世界的对象，整份作废
    Hud.pending = nil                  -- 还没补发的那条也作废（它属于上一个世界）
    Hud.hide_gen = (Hud.hide_gen or 0) + 1   -- 让所有排队中的"自动隐藏"定时器失效
    if Hud.ctx ~= nil then Hud.ctx.pc = nil end
    if Log ~= nil then
        Log.line(string.format(
            "[hud] 已丢弃跨世界引用（不触碰引擎）: %s（丢掉 %d 个控件）",
            tostring(reason), n))
    end
    return n
end

--- 彻底收回我们自己造的控件（两种样式都收）
function Hud.destroy_own_widget()
    local any = false
    local kinds = { "normal", "error" }
    for i = 1, #kinds do
        local st = Hud.styles[kinds[i]]
        local w = st and st.widget or nil
        st.widget, st.textblocks = nil, nil
        if w ~= nil then
            any = true
            pcall(function() w:SetVisibility(Hud.VIS_COLLAPSED) end)
            pcall(function() w:RemoveFromParent() end)
            -- ★ 配对的 RemoveFromRoot（见 ensure_own_widget 里的说明）
            if st.rooted == true then
                pcall(function() w:RemoveFromRoot() end)
                st.rooted = false
            end
        end
    end
    Hud.own_widget, Hud.own_textblock, Hud.own_textblocks = nil, nil, nil
    Hud.invalidate_textblocks()
    return any
end

--- 一次发送的可读摘要（诊断用: 走了哪条路、控件叫什么、可见性如何、回读到了什么）
function Hud.set_detail(s)
    Hud.last_detail = tostring(s or "")
end

--- 取文本控件扫描结果（含全名与是否活实例），供"按内容找控件"这类用途。
--- 返回 { {obj=, name=, live=}, ... }
function Hud.textblock_entries(only_live)
    local scan = tb_scan()
    local out = {}
    for i = 1, #scan do
        if only_live ~= true or scan[i].live then
            out[#out + 1] = scan[i]
        end
    end
    return out
end

--- 把文本控件扫描结果按"所属界面"分组。
---
--- ★★ 为什么需要它（2026-09-27 标记测试的第二次教训）:
---   那一轮按"文字长度"挑了 3 个目标，结果全是**设置/警告界面**里的字
---   （「目前语言：简体中文」「PCの空きメモリ…」「不满足最低配置要求…」）——
---   而它们的"自身 + 父链可视性"看起来都是正常的！
---   原因: Palworld 的 UI **把大量控件一直保留在内存里**，
---   放在 WidgetSwitcher 的非活动页 / 折叠面板里时，
---   这些控件的 Visibility 属性**仍然是 Visible** —— 属性完全问不出"在不在屏幕上"。
---   ⇒ 那就别挑了: **按不同界面分组，每组各写一个带编号的标记**，
---     哪一组真的在屏幕上，玩家就会看到对应编号 —— 由玩家的眼睛当判据。
---
--- 分组键: 取全名里 WidgetTree_<数字> 前面那一段（= 所属控件名）
function Hud.textblock_groups(max_groups)
    max_groups = tonumber(max_groups) or 12
    local scan = tb_scan()
    local groups = {}
    local order = {}
    for i = 1, #scan do
        local e = scan[i]
        if e.live then
            local before = e.name:match("^(.*)%.[%w_]+$") or e.name
            local key = before:match("([%w_]+)%.WidgetTree_%d+$") or before
            if groups[key] == nil then
                groups[key] = e
                order[#order + 1] = key
            end
        end
    end
    local out = {}
    for i = 1, #order do
        if #out >= max_groups then break end
        out[#out + 1] = { key = order[i], obj = groups[order[i]].obj,
                          name = groups[order[i]].name }
    end
    return out
end

--- 找"挂在某个控件下面"的所有文本控件（按全名包含判断）。
--- 用途: 判断"我们刚 Create 出来的控件里到底有没有文本框" ——
---   如果连一个都没有，说明**控件树没有被复制出来**（那 GetWidgetFromName 取不到就正常了）。
function Hud.textblocks_under(w)
    if w == nil then return nil end
    local wn = Util.full_name(w)
    if type(wn) ~= "string" then return nil end
    local list = Hud.find_textblocks("", true)
    local out = {}
    for i = 1, #list do
        local fn = Util.full_name(list[i])
        if type(fn) == "string" and fn:find(wn, 1, true) ~= nil then
            out[#out + 1] = list[i]
        end
    end
    return out
end

--- 当前世界的"标签"（一个字符串）。
--- ★ 用途: 自动隐藏的定时器到点时，要先确认"世界还是原来那个"。
---   回标题 / 换存档 / 退出世界时，引擎会把 UI 控件销毁掉，
---   这时我们手里那个控件就是**野指针** —— 再去 SetVisibility 就是访问违例
---   （玩家反馈: 操作完回标题直接闪退，就是这个）。
---   比较**字符串**是安全的: 不需要碰那个可能已经销毁的控件。
function Hud.world_tag()
    -- ★ 直接委托给 Util.world_tag(): 它用 FindFirstOf("World") + 对象地址，
    --   不经过 UEHelpers.GetWorld() 那层会撒谎的 IsValid 过滤
    --   （2026-09-28 崩溃的根因，详见 Util.world_tag 的注释）。
    return Util.world_tag()
end

--- 按名字取 UUserWidget 里的子控件。
---
--- 来源（只读参考 SBB，未复用其代码）: SBB 的取法是**两步**，顺序很重要 ——
---   ① 先直接读属性: `instance.Text_Warning`
---      （UMG 会把设计器里命名的子控件**暴露成同名属性**，这是最直接的一条）
---   ② 不行再 `instance:GetWidgetFromName(FName(name))`
--- 2026-09-27 实测: 我只用了第 ② 步，三个控件全部返回 nil；
---   而且 SBB 的注释也显示他们把属性读取放在前面。所以这里照它的顺序来。
---
--- 返回 子控件, 取到的方式（property / GetWidgetFromName） 或 nil, 失败说明
function Hud.widget_child(w, child_name)
    if w == nil or type(child_name) ~= "string" or child_name == "" then
        return nil, "参数不足"
    end
    -- ① 直接读属性
    local direct, direct_type = nil, "nil"
    pcall(function() direct = w[child_name] end)
    if direct ~= nil then
        pcall(function() direct_type = type(direct) end)
    end
    direct = Util.unwrap(direct)
    if Util.usable(direct) then
        return direct, "property"
    end
    -- ② 按名字查控件树
    local named = nil
    pcall(function()
        named = w:GetWidgetFromName(require("UEHelpers").FindOrAddFName(child_name))
    end)
    named = Util.unwrap(named)
    if Util.usable(named) then
        return named, "GetWidgetFromName"
    end
    return nil, string.format("property=%s(type=%s) GetWidgetFromName=nil",
        tostring(direct ~= nil), tostring(direct_type))
end

--- 这个控件"真的会被画出来"吗？—— 沿父链一路检查。
---
--- ★★ 为什么必须查父链（2026-09-27 标记测试的教训）:
---   那一轮往 3 个"长文本"写了 PWPR#1/2/3，全都没出现。
---   它们的**自身**可视性都是 3/4（"在渲染"），但父控件很可能是 Collapsed ——
---   父控件 Collapsed 时整棵子树都不画，子控件的 visible 毫无意义。
---   那 3 个恰好都是"按需出现"的 UI（物品说明 / 内存告警 / 钓鱼提示）。
---   ⇒ 判断"能不能看见"必须**从自己一路查到根**。
---
--- 返回 会显示吗(bool), 链描述(string)
function Hud.chain_visible(w)
    if w == nil then return false, "nil" end
    local cur = w
    local depth = 0
    local chain = {}
    while cur ~= nil and depth < 16 do
        local v = Hud.widget_visibility(cur)
        local o = Hud.render_opacity(cur)
        chain[#chain + 1] = string.format("%s(vis=%s,op=%s)",
            tostring(Util.short_name(cur)), tostring(v), tostring(o))
        if v == Hud.VIS_COLLAPSED or v == Hud.VIS_HIDDEN then
            return false, table.concat(chain, " < ")
        end
        if type(o) == "number" and o <= 0.001 then
            return false, table.concat(chain, " < ")
        end
        local p = nil
        pcall(function() p = cur:GetParent() end)
        if p == nil then break end
        cur = p
        depth = depth + 1
    end
    return true, table.concat(chain, " < ")
end

--- 找出"长文本"控件 —— 用来定位通知/提示那种整句话的控件。
---
--- ★ 为什么要按长度找: 玩家的截图给了决定性线索 ——
---   左下角通知区显示的是**整句话**（「灵曦笼打倒企丸丸了！」「水栖帕鲁的黏液x1」），
---   而 HUD 上绝大多数文本框是很短的标签/数字（「据点等级」「8」「SAN」）。
---   所以"文字长"本身就是一个很强的特征: 不用知道控件叫什么名字也能把它捞出来。
---
--- 返回 entries = { {obj=, name=, text=, vis=}, ... }（按文字长度降序）
function Hud.long_text_blocks(min_len, max_n)
    min_len = tonumber(min_len) or 6
    max_n = tonumber(max_n) or 25
    local scan = tb_scan()
    local out = {}
    for i = 1, #scan do
        local e = scan[i]
        if e.live then
            local t = Hud.widget_text(e.obj)
            if type(t) == "string" and #t >= min_len then
                out[#out + 1] = {
                    obj = e.obj, name = e.name, text = t,
                    vis = Hud.widget_visibility(e.obj),
                }
            end
        end
    end
    table.sort(out, function(a, b) return #a.text > #b.text end)
    while #out > max_n do table.remove(out) end
    return out
end

-- --------------------------------------------------------------------------
-- 自己造一个通知控件
--
-- ★★★ 2026-09-27: 读了 SBB（只读参考，未复用代码）之后，方案按它的做法改了。
--
-- SBB 左下角那条「正在准备蓝图预览：%d/%d（%d%%）」**不是游戏提供的接口**，
-- 而是它自己用 UMG 控件画出来的:
--     CreateWidget(自己的控件类)  ->  AddToPlayerScreen(50)
--     -> GetWidgetFromName("Info_BP_PalTextBlock_C_100")  ->  SetText(FText(...))
--     -> SetVisibility(0)
-- 关键在于它复制的是**自己设计的浮层控件**（有锚点、有尺寸、本来就该独立显示）。
--
-- 我们之前复制的是 WBP_Notice —— 那是**通知列表里的一项**，
-- 单独拿出来时它的布局是空的 ⇒ **属性全对（在视口里/不透明/有期望尺寸）却什么都看不见**。
--
-- ⇒ 改法: 换一个"**本来就是独立浮层**"的**游戏自带**控件类
--   （不需要自己打 pak）。配置项:
--     notify_widget_class_name = 类名（用 FindAllOf 找活实例，再取它的类）
--     notify_widget_text_child = 里面那个文本框的子控件名（GetWidgetFromName）
-- --------------------------------------------------------------------------

Hud.own_widget = nil
Hud.own_textblock = nil
Hud.own_textblocks = nil
Hud.own_error = nil

--- 两种样式的状态（正常 = 中性/蓝；出错 = 红）。
--- 每个样式各自缓存一个我们自己的控件实例。
Hud.styles = {
    normal = { widget = nil, textblocks = nil, attach = nil, found_by = nil,
               error = nil, fresh = 0 },
    error  = { widget = nil, textblocks = nil, attach = nil, found_by = nil,
               error = nil, fresh = 0 },
}

--- 取某个样式的状态（未知样式退回 normal）
---
--- ★★ 2026-09-27: 如果**没有配置**"出错样式"，就让 error 复用 normal ——
---   同一条提示条、同一个控件实例。
---   理由: 颜色没法自定义（颜色构造函数没暴露），两种样式的唯一区别只是
---   "用哪个控件"；而同时存在两套控件会带来"旧文字一直挂在屏幕上"这类问题。
---   一套控件、一套样式，简单可靠。
function Hud.style_state(kind)
    local k = (kind == "error") and "error" or "normal"
    if k == "error" then
        -- 【探索期遗留·已放弃】第二套『出错样式』控件（notify_error_class_name/text_child，默认空）—— 颜色没法自定义，不值得维护两套。
        local cn = Config.get("notify_error_class_name")
        if type(cn) ~= "string" or cn == "" then
            return Hud.styles.normal, "normal"
        end
    end
    return Hud.styles[k], k
end

--- 某个样式对应的配置键
local function style_cfg(kind)
    if kind == "error" then
        return Config.get("notify_error_class_name"),
               Config.get("notify_error_text_child")
    end
    return Config.get("notify_widget_class_name"),
           Config.get("notify_widget_text_child")
end

--- 拿到（必要时创建）某个样式的控件。返回 控件, nil 或 nil, 原因
function Hud.ensure_own_widget(ctx, kind)
    local st, k = Hud.style_state(kind)

    -- ★★★ 第一步必须是"世界有没有换" —— 而且**只能用字符串比较**。
    --
    -- 2026-09-27 实测踩到的顺序错误（崩溃复盘）:
    --   这一段原来是写在"旧控件还能用吗"的检查**后面**的:
    --       if st.widget ~= nil and Util.usable(st.widget) ... then return st.widget end
    --       local wt = Hud.world_tag()   -- 世界检查在这里，太晚了
    --   于是"回标题 → 重进世界 → 按 Y"时:
    --     Util.usable(旧控件) 在**已销毁的对象**上竟然返回 true（内存还没被复用），
    --     函数就从那儿 return 了旧控件 → 接着 SetText 一个上个世界的文本框 →
    --     EXCEPTION_ACCESS_VIOLATION（日志里 [ns] 正好停在"找文本框"之后）。
    --   ⇒ 结论: 一切"摸旧对象"的动作（连 usable/is_live 都算）都必须排在世界检查之后。
    --
    -- ★★ 这里**不做**"世界标记"检查（2026-09-28 实测后去掉）。
    --
    -- 演进（三段，都要记住）:
    --   ① 完全不检查 → "回标题→重进世界→按 Y"复用废控件 → 崩（§23）；
    --   ② 加检查、不符就丢引用重建 → 标记抖动 ⇒ 每次提示都重建、旧提示堆屏（§24）；
    --   ③ 改成"不符就跳过本次" → 标记抖动 ⇒ **只有第一条提示能显示**，
    --      后面全被拒（玩家日志: `世界标记已变，跳过屏幕提示`，
    --      而标记本身 `AActor: ...FAF8 -> ...5758 -> ...0B58` 每次都在变）。
    --   ⇒ 结论: **这个标记不可信，不能用它做任何行为判断**；
    --     跨世界的清理**只由 LoadMapPre 钩子负责**（日志证明它每次都正确触发）。
    local wt = Hud.world_tag()

    if st.widget ~= nil and Util.usable(st.widget) and Hud.is_live(st.widget) then
        return st.widget, nil
    end
    -- ★★ 失败后【一段时间内不再重试】。
    --   2026-09-27 崩溃后的主要嫌疑: 蓝色样式每次都创建失败，
    --   而失败的那个半成品控件**被留在视口里** —— 每次按键都造一个新的坏控件，
    --   引擎每帧都要处理它们 → 后续在别的操作上崩掉（rotate 那次）。
    --   所以: 失败就"拉黑"一段时间，不再反复创建。
    local retry_s = tonumber(Config.get("notify_style_retry_s")) or 60
    if st.failed_until ~= nil and os.clock() < st.failed_until then
        return nil, tostring(st.error or "样式暂时禁用（上次创建失败）")
    end
    st.widget, st.textblocks, st.found_by, st.error = nil, nil, nil, nil

    -- ★ 拿一个"现在这个世界的" PlayerController。
    --   不要直接用缓存里的 ctx.pc: 回标题再进世界后它是**上个世界的对象**，
    --   传给 CreateWidget 就是野指针（和上面那个顺序错误同一类问题）。
    --   ★ 用 Hud.find_pc()（FindAllOf + Util.valid 严格判据），
    --     不要用 UEHelpers.GetPlayerController()（它的 IsValid 过滤会漏过废对象）。
    local pc = Hud.find_pc()
    if pc == nil then pc = ctx and ctx.pc or nil end
    if pc == nil then return nil, "拿不到 PlayerController" end

    local cls_name, child_name = style_cfg(k)

    -- 1) 控件类: 优先从"配置指定的类的活实例"上取它的类
    local cls = nil
    if type(cls_name) == "string" and cls_name ~= "" then
        local insts = Hud.find_widgets(cls_name)
        if insts ~= nil and #insts > 0 then
            pcall(function() cls = insts[1]:GetClass() end)
        end
    end
    -- 2) 出错样式退回"正常样式"的类名（配置没填时）
    if cls == nil and k == "error" then
        local normal_name = Config.get("notify_widget_class_name")
        if type(normal_name) == "string" and normal_name ~= "" then
            local insts = Hud.find_widgets(normal_name)
            if insts ~= nil and #insts > 0 then
                pcall(function() cls = insts[1]:GetClass() end)
            end
        end
    end
    -- 3) 再退一步: 按资产路径加载类
    if cls == nil then
        local path = Config.get("notify_widget_class_path")
        if type(path) == "string" and path ~= "" then
            local ok, res = pcall(function() return LoadAsset(path) end)
            if ok then cls = Util.unwrap(res) end
        end
    end
    if cls == nil then
        st.error = "拿不到控件类（" .. tostring(cls_name) .. " 没有活实例）"
        return nil, st.error
    end

    -- 3) Create Widget（UMG 静态库）
    local lib = nil
    pcall(function()
        lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    end)
    if not Util.usable(lib) then return nil, "拿不到 UMG 函数库" end

    -- ★ 建之前先记一份"现有活文本控件全名" —— 建完之后多出来的就是我们的。
    --   为什么需要: 按"控件全名前缀"匹配文字控件并不可靠（实例名可能变），
    --   而 before/after 差集是**推断不出错**的: 新出现的那些必然来自我们这次创建。
    local before = {}
    do
        local list = Hud.find_textblocks("", true)
        for i = 1, #list do
            local fn = Util.full_name(list[i])
            if type(fn) == "string" then before[fn] = true end
        end
    end

    local w = nil
    local okc = pcall(function() w = lib:Create(pc, cls, pc) end)
    if not okc or w == nil then return nil, "Create 失败" end

    -- 4) 塞进画面。★ 按 SBB 的顺序: 先试 AddToPlayerScreen，再退 AddToViewport。
    --    z-order 给 50（SBB 用的也是 50）—— 够高，又不像 1000 那样夸张。
    local ok_ps = pcall(function() w:AddToPlayerScreen(50) end)
    if ok_ps then
        st.attach = "AddToPlayerScreen"
    else
        local ok_vp = pcall(function() w:AddToViewport(50) end)
        if not ok_vp then
            st.error = "AddToPlayerScreen 和 AddToViewport 都失败"
            return nil, st.error
        end
        st.attach = "AddToViewport"
    end

    st.widget = w
    st.world_name = wt          -- ★ 记下"这个世界"的标签，定时器/下次发送要和它比
    if k == "normal" then Hud.own_widget = w end   -- 兼容旧字段

    -- ★★★ 防 GC: 我们自己 Create 出来的 UObject，Lua 持有的引用**不是 UPROPERTY**，
    --   引擎的垃圾回收看不到它 —— 它可能在任意时刻被回收，
    --   之后 Lua 手里就是一个野指针，再调用（SetText/SetVisibility）→
    --   EXCEPTION_ACCESS_VIOLATION（垃圾地址）。
    --   这与实测吻合: 提示一开始能用，过几秒/几次操作后突然崩在"发提示"里面。
    --   AddToRoot() 是 UE 的标准做法: 把它加进 GC 根集合，永不被自动回收。
    --   清理时会 RemoveFromRoot（见 destroy_own_widget）。
    st.rooted = false
    pcall(function()
        w:AddToRoot()
        st.rooted = true
    end)

    -- 5) 找里面的文本框。★ 用 SBB 的两步法: 先读属性，再 GetWidgetFromName
    local named, how = Hud.widget_child(w, child_name)
    if named ~= nil then
        st.textblocks = { named }
        st.found_by = tostring(how) .. "(" .. tostring(child_name) .. ")"
        if k == "normal" then
            Hud.own_textblock = named
            Hud.own_textblocks = st.textblocks
            Hud.own_found_by = st.found_by
        end
        Hud.invalidate_textblocks()
        return w, nil
    end
    st.child_error = tostring(how)

    -- 6) 退一步: 用 before/after 差集找"新建出来的文本控件"
    --    （配置里没填子控件名、或者那个名字不对时走这条）
    Hud.invalidate_textblocks()
    local wn = Util.full_name(w)
    local fresh, matched = {}, {}
    local after = Hud.find_textblocks("", true)
    for i = 1, #after do
        local fn = Util.full_name(after[i])
        if type(fn) == "string" and before[fn] ~= true then
            fresh[#fresh + 1] = after[i]
            if type(wn) == "string" and fn:find(wn, 1, true) ~= nil then
                matched[#matched + 1] = after[i]
            end
        end
    end
    st.textblocks = (#matched > 0) and matched or fresh
    st.fresh = #fresh
    st.found_by = "扫描差集（新建文本控件 " .. #fresh .. " 个）"

    -- ★★ 关键修复: 取不到文本框 ⇒ 这是个"半成品控件"，必须【从画面上撤掉】。
    --   留着它 = 每帧让引擎处理一个坏掉的控件 + 每次按键再堆一个 → 后续崩溃。
    if st.textblocks == nil or #st.textblocks == 0 then
        pcall(function() w:SetVisibility(Hud.VIS_COLLAPSED) end)
        pcall(function() w:RemoveFromParent() end)
        -- ★ 别忘了撤掉 GC 根，否则这个"废控件"永远不会被回收（内存泄漏）
        if st.rooted == true then
            pcall(function() w:RemoveFromRoot() end)
            st.rooted = false
        end
        st.widget = nil
        st.error = "创建成功但取不到文本控件，已从画面移除（" .. tostring(st.child_error or "") .. "）"
        st.failed_until = os.clock() + retry_s
        Hud.invalidate_textblocks()
        return nil, st.error
    end

    if k == "normal" then
        Hud.own_textblock = st.textblocks[1]
        Hud.own_textblocks = st.textblocks
        Hud.own_fresh_count = #fresh
        Hud.own_found_by = st.found_by
    end
    Hud.invalidate_textblocks()
    return w, nil
end

--- 找"我们自己那个控件"里**所有**文本控件。
---
--- ★ 为什么是复数: 报告显示 Create 一个通知控件会带出 **11 个**文本控件
--- （通知控件里有标题/正文/时间等好几个）。第一版只挑一个（按名字前缀匹配到的第一个），
--- 结果写进去的那个**可能根本不是显示正文的那个** —— 字写对了、回读也对，
--- 但屏幕上就是不显示。既然分不清哪个是"正文"，那就**全写**。
---
--- ★★ 2026-09-27 第三次加固（针对"崩在发提示里面"）:
---   **发一次提示，绝不去遍历全局对象表**。
---
--- 为什么: 老实现每次发送都要遍历 ~2400 个缓存的文本控件对象、
---   对每一个调 GetFullName。缓存里的对象最长留 5 秒，
---   而这 5 秒内游戏会销毁/重建大量 UI 文本 ——
---   一旦碰到一个已经被销毁的对象，就是野指针 → 访问违例（垃圾地址）。
---   这与实测完全吻合: 崩点**总在通知路径里**、**时好时坏**、
---   操作次数越多越容易碰上。
---
--- 现在的顺序（都很便宜，且不碰全局表）:
---   ① 按配置的子控件名现场取（属性 / GetWidgetFromName）—— 最准
---   ② 用创建时缓存下来的文本框对象（它是【我们自己控件】的子控件）
-- 【探索期遗留·诊断】发送时遍历全局文本控件表兜底（notify_scan_in_send，默认关）—— 老实现每次发提示遍历约 2400 个对象，会摸到已销毁对象。
---   ③ 只有配置显式打开 notify_scan_in_send 时才走全局扫描（排查用）
function Hud.find_own_textblocks(kind)
    local st = Hud.style_state(kind)
    local w = st.widget
    if w == nil then return nil end

    -- ① 现场取
    local cn = Config.get(kind == "error" and "notify_error_text_child"
        or "notify_widget_text_child")
    local direct = Hud.widget_child(w, cn)
    if direct ~= nil then return { direct } end

    -- ② 创建时缓存下来的（不遍历全局表）
    if st.textblocks ~= nil and #st.textblocks > 0 then
        return st.textblocks
    end

    -- ③ 兜底: 全局扫描（默认关，只在排查时打开）
    if Config.get("notify_scan_in_send") ~= true then
        return nil
    end
    local under = Hud.textblocks_under(w)
    if under ~= nil and #under > 0 then return under end
    return nil
end

--- 单个版本（保留给只关心"有没有"的调用方）
function Hud.find_own_textblock()
    local list = Hud.find_own_textblocks()
    if list == nil or #list == 0 then return nil end
    return list[1]
end

-- --------------------------------------------------------------------------
-- 通道表
-- --------------------------------------------------------------------------

--- 每个通道:
---   name/title/risk/in_game
---   gate    = 配置键名；必须为 true 才允许 probe/send（高风险通道默认关）
---   probe(ctx) -> ok, detail
---   send(text, ascii, ctx) -> ok[, 原因]
Hud.CHANNELS = {
    {
        name = "console",
        title = "UE4SS 调试窗口（ASCII；想盖在游戏上要 GraphicsAPI=dx11）",
        risk = "low",
        in_game = false,
        gate = nil,
        probe = function()
            return true, "print 永远可用（能不能看见取决于 UE4SS 的 GraphicsAPI 设置）"
        end,
        send = function(text, ascii)
            print(Util.TAG .. " > " .. (ascii or Util.ascii(text)))
            return true
        end,
    },

    {
        name = "client_message",
        title = "★ PlayerController:ClientMessage —— 【已知会崩，永久禁用】",
        risk = "high",
        in_game = true,
        -- ★★ never_call: 连探测的"真发一行测试文字"都不许调它。
        --   2026-09-27 实测: 调用它 → EXCEPTION_ACCESS_VIOLATION reading 0x70 → 闪退。
        --   和 PrintString 同一类: **名字能解析（usable=true）不代表能安全调用**。
        never_call = true,
        gate = "notify_try_client_message",
        probe = function(ctx)
            ctx = ctx
            local pc = Hud.ctx and Hud.ctx.pc or nil
            return false, "已知会崩（2026-09-27 实测 EXCEPTION_ACCESS_VIOLATION），"
                .. "永久禁用；本条只为留档" .. tostring(pc ~= nil and "" or "")
        end,
        send = function(text, ascii, ctx)
            ctx = ctx
            text = text
            ascii = ascii
            return false, "ClientMessage 已知会崩游戏，已永久禁用（见 docs\\踩坑记录.md 第 21 节）"
        end,
    },

    {
        name = "notice_text",
        title = "Palworld 通知控件（TextBlock:SetText）—— ★ 中文能显示的就靠它",
        risk = "mid",
        in_game = true,
        gate = "notify_try_notice_text",
        probe = function(ctx)
            ctx = ctx
            -- 1) 能不能拿到控件类（活实例优先，其次 LoadAsset 路径）
            local cls = nil
            local insts = Hud.find_widgets("WBP_Notice_C")
            if insts ~= nil and #insts > 0 then
                pcall(function() cls = insts[1]:GetClass() end)
            end
            local cls_src = "活着的 WBP_Notice_C"
            if cls == nil then
                local path = Config.get("notify_widget_class_path")
                if type(path) == "string" and path ~= "" then
                    local ok, res = pcall(function() return LoadAsset(path) end)
                    if ok then cls = Util.unwrap(res) end
                    cls_src = "LoadAsset(" .. tostring(path) .. ")"
                end
            end
            if cls == nil then
                return false, "拿不到控件类（活实例和 LoadAsset 都没成功）"
            end
            -- 2) 借用路线的候选: 全名带 filter 的【活】文本控件
            local filter = Config.get("notify_textblock_filter")
            local live = Hud.find_textblocks(filter, true)
            return true, string.format(
                "类来自 %s；活文本控件 %d 个（全部 %d），带「%s」的活控件 %d 个",
                cls_src, tonumber(Hud.textblock_live) or 0,
                tonumber(Hud.textblock_total) or 0, tostring(filter),
                (live ~= nil) and #live or 0)
        end,
        send = function(text, _ascii, ctx, kind)
            local rep = {}
            local function note(s) rep[#rep + 1] = tostring(s) end
            -- ★★ 细粒度标记（当初排查"崩在发提示里面"用）。
            --
            -- ⚠️ 2026-09-29 性能修复: 原来 `mark` **每一步都同步写一次盘**
            --   （7 步 ⇒ 每条提示 7 次文件写入），而放置时一次会发两条提示
            --   （吸附结果 + 落地确认）⇒ 放一块地板写盘十几次 ——
            --   这就是玩家说的"还是卡"的真凶（文件 I/O 在 UE4SS 的 Lua 里很贵）。
            --   ⇒ 现在: ① 默认**关掉**（`notify_trace = true` 才记）；
            --           ② 开着时也只进缓冲，由结尾**节流**写一次盘。
            --   崩溃取证: 需要时把 `notify_trace` 改成 true 就能恢复原来的行为。
            local trace_on = false
            pcall(function()
                trace_on = (require("pwpr_config").get("notify_trace") == true)
            end)
            local function mark(s)
                if not trace_on then return end
                if Log ~= nil and Log.emit ~= nil then
                    pcall(Log.emit, "[ns] " .. s)
                end
            end
            mark("开始")
            -- ★ 代次 +1: 让"上一条提示排下的自动隐藏定时器"作废。
            --   （必须在任何可能 return 的分支之前加，否则这条提示不生效）
            Hud.hide_gen = (Hud.hide_gen or 0) + 1

            local ft, ferr = Hud.ftext(text)
            if ft == nil then
                Hud.set_detail("FText 构造失败: " .. tostring(ferr))
                return false, Hud.last_detail
            end
            note("文字=「" .. tostring(text) .. "」")
            mark("FText 好了")

            -- ★★ 样式: normal = 正常提示（中性/蓝）；error = 出错（红）。
            --   玩家要求的分工。实测两种都已经有落点。
            local want = (kind == "error") and "error" or "normal"
            note("样式=" .. want)
            -- ★ 记录"实际用的是哪一套样式"（自动隐藏要用它，
            --   否则会把另一套样式的控件藏起来 = 看起来像没生效）
            local used_kind = nil

            local used = nil
            local tried = {}
            local order = (want == "error") and { "error", "normal" } or { "normal", "error" }

            if Config.get("notify_own_widget") == true then
              for oi = 1, #order do
                local k = order[oi]
                if used == nil then
                    -- ★ 用 style_state 解析后的样式名（k_res），不要用循环里的原始 k ——
                    --   因为"没配出错样式"时 error 会被解析成 normal；
                    --   若还用原始 k，下面"收起另一套样式"就会把**刚写好的那个**控件藏起来。
                    local st, k_res = Hud.style_state(k)
                    mark("取控件[" .. k .. "]")
                    local w, werr = Hud.ensure_own_widget(ctx or Hud.ctx, k)
                    mark("取控件[" .. k .. "] 结束: " .. (w ~= nil and "有" or tostring(werr)))
                    if w == nil then
                        note("自建控件[" .. k .. "]: 失败 -> " .. tostring(werr))
                        tried[#tried + 1] = k .. ":no-widget"
                    else
                        note("自建控件[" .. k .. "]=" .. tostring(Util.full_name(w)))
                        -- ★ 遥测（在视口里 / 期望尺寸 / 根控件 …）默认**不发**。
                        --   它们是排查期的诊断信息，每次提示要多调 ~10 次引擎接口。
                        --   既然通道已经工作，就把发送路径压到最小:
                        --   找文本框 -> SetText -> force_display。
                        -- 【探索期遗留·诊断】发送路径的额外引擎调用（notify_send_telemetry，默认关）—— 只在排查崩溃/性能时打开。
                        --   要看这些信息: 打开 notify_send_telemetry，或用 O 探测。
                        if Config.get("notify_send_telemetry") == true then
                            local rw = Hud.root_widget(w)
                            note("  挂载=" .. tostring(st.attach)
                                .. " 在视口里=" .. tostring(Hud.in_viewport(w))
                                .. " 可视性=" .. tostring(Hud.widget_visibility(w))
                                .. " 不透明度=" .. tostring(Hud.render_opacity(w))
                                .. " 期望尺寸=" .. tostring(Hud.desired_size(w))
                                .. " 新建文本控件=" .. tostring(st.fresh))
                            note("  ★根控件=" .. tostring(Util.full_name(rw))
                                .. " 可视性=" .. tostring(Hud.widget_visibility(rw))
                                .. " 不透明度=" .. tostring(Hud.render_opacity(rw))
                                .. " 期望尺寸=" .. tostring(Hud.desired_size(rw)))
                        end
                        local tbs = Hud.find_own_textblocks(k)
                        mark("找文本框[" .. k .. "]: " .. tostring(tbs ~= nil and #tbs or 0) .. " 个")
                        if tbs == nil or #tbs == 0 then
                            note("  ★ 找不到它里面的文本控件")
                            tried[#tried + 1] = k .. ":no-textblock"
                        else
                            local n_ok = 0
                            for i = 1, #tbs do
                                if pcall(function() tbs[i]:SetText(ft) end) then
                                    n_ok = n_ok + 1
                                end
                            end
                            mark("SetText 完成: " .. n_ok .. "/" .. #tbs)
                            -- ★ 用 3（HitTestInvisible）—— 渲染但绝不吃输入。
                            --   用 0 会把游戏菜单的鼠标点击吃掉（2026-09-27 事故）
                            Hud.force_display(w)
                            -- ★★ 连【父链】一起点亮: 有些浮层的内容容器默认是折起的，
                            --    只设控件本身不够（写进去了、回读也对，屏幕上却没有）。
                            local chain_n = Hud.force_display_chain(tbs[1])
                            for i = 1, #tbs do Hud.force_display(tbs[i]) end
                            mark("force_display 完成（父链 " .. chain_n .. " 层）")
                            note("  文本控件 " .. #tbs .. " 个（全部写入，成功 " .. n_ok .. "）")
                            note("  第一个=" .. tostring(Util.full_name(tbs[1])))
                            note("  回读=「" .. tostring(Hud.widget_text(tbs[1])) .. "」"
                                .. " 可视性=" .. tostring(Hud.widget_visibility(tbs[1]))
                                .. " 不透明度=" .. tostring(Hud.render_opacity(tbs[1])))
                            if n_ok > 0 then
                                used = "own"
                                used_kind = k_res
                                -- ★★ 把【另一种样式】的控件收起来。
                                --   否则它上面残留的旧文字会一直挂在屏幕上 ——
                                --   玩家反馈"这条提示一直在，其他提示出来了它还在"就是这个。
                                --   注意用 k_res（解析后的样式名）: 单样式模式下
                                --   error 会被解析成 normal，用原始 k 会误藏自己。
                                local other = (k_res == "error") and "normal" or "error"
                                local ost = Hud.styles[other]
                                if ost ~= nil and ost.widget ~= nil and ost ~= st then
                                    pcall(function()
                                        ost.widget:SetVisibility(Hud.VIS_COLLAPSED)
                                    end)
                                    note("  已收起另一套样式[" .. other .. "]")
                                end
                            end
                    end        -- C: tbs 为空/非空
                end            -- B: w 为 nil/非 nil
            end                -- G: used == nil（否则已经成功，不用再试下一种样式）
          end                  -- F: 样式循环（normal -> error 或相反）
        end                    -- A: notify_own_widget

            -- ★ 只在最后**节流**写一次盘（原来每一步都写，见上面 mark 的说明）。
            --   用 throttled_flush: 一秒内最多写一次，既不丢内容也不拖慢放置。
            if Log ~= nil and Log.throttled_flush ~= nil then
                pcall(Log.throttled_flush, 1.0)
            end

-- 【探索期遗留·已放弃】『借用游戏自己文本框』的路线（notify_allow_borrow，默认关）—— 自建控件已走通，这条路不再用；配套键 notify_textblock_filter 也废弃。

            -- ---- 路线 B（兜底）: 借用游戏【活着的】文本控件 ----
            -- ★ 默认关闭（notify_allow_borrow = false）:
            --   这条会**临时改写游戏自己的 UI 文本**（延时还原），属于侵入性操作。
            --   既然自建控件那条路已经实测能显示，就不该再去动游戏原有的提示。
            if used == nil then
                if Config.get("notify_allow_borrow") ~= true then
                    note("借用路线: 已禁用（notify_allow_borrow=false，不动游戏自己的 UI）")
                else
                    local filter = Config.get("notify_textblock_filter")
                    local list = Hud.find_textblocks(filter, true)   -- ★ only_live
                    if list == nil or #list == 0 then
                        note("借用: 没有匹配「" .. tostring(filter) .. "」的活控件")
                    else
                        local tb = list[1]
                        note("借用=" .. tostring(Util.full_name(tb))
                            .. " 可视性=" .. tostring(Hud.widget_visibility(tb))
                            .. " 原本显示=「" .. tostring(Hud.widget_text(tb)) .. "」")
                        local okc = pcall(function() tb:SetText(ft) end)
                        note("  SetText=" .. tostring(okc)
                            .. " 回读=「" .. tostring(Hud.widget_text(tb)) .. "」")
                        if okc then used = "borrow" end
                    end
                end
            end

            note("采用路线=" .. tostring(used))
            Hud.set_detail(table.concat(rep, " | "))

            if used == nil then
                return false, Hud.last_detail
            end

            -- ---- 几秒后把自己那个控件收起来 ----
            -- ★ 2026-09-27 默认【开】: 通道已经验证可用，
            --   而玩家反馈"提示会一直停在屏幕上" —— 那才是更烦的问题。
            --   秒数可配（hud_seconds），也可以按 F8 重载配置即时生效。
            --
            -- ★★ 两个必须的守卫（玩家反馈的两个 bug）:
            --   ① 代次（hide_gen）: 定时器是发提示时排下的，
            --      如果之后又发过新提示，旧定时器必须**作废** ——
            --      否则新提示会被旧计时提前收走（"先按 F9，3 秒后按方向键，
            --      新提示只显示 1 秒就消失"）。
            --   ② 世界标签: 回标题/换存档后控件已被销毁，这时去碰它就是野指针
            --      （"操作完回标题直接闪退"）。
            if used == "own" and Config.get("notify_autohide") == true then
                local st_used = Hud.style_state(used_kind or "normal")
                local w = st_used.widget
                local secs = tonumber(Config.get("hud_seconds")) or 4.0
                -- 【已废弃】轮询『世代守卫』（world_guard_enabled）—— 会把刚建好的投影丢掉（见 docs\踩坑记录.md §25）；现在换地图只用 LoadMapPre 钩子。
                if w ~= nil and secs > 0 then
                    local my_gen = Hud.hide_gen
                    local my_world = st_used.world_name
                    local guard_on = false
                    pcall(function()
                        guard_on = Config.get("world_guard_enabled") == true
                    end)
                    Sched.game_thread(function()
                        if Hud.hide_gen ~= my_gen then return end
                        -- ★ 世界守卫（默认关，见 config 的说明）:
                        --   它是为了防"回标题后定时器去碰废控件"，
                        --   但标记不稳定时会误跳过正常的自动隐藏 ⇒ 默认不启用。
                        if guard_on and Hud.world_tag() ~= my_world then return end
                        pcall(function() w:SetVisibility(Hud.VIS_COLLAPSED) end)
                    end, math.floor(secs * 1000))
                end
            end
            return true
        end,
    },

    {
        name = "named_call",
        title = "调用探测里发现的函数（名字来自配置 notify_func，只给 1 个字符串参数）",
        risk = "high",
        in_game = true,
        gate = "notify_allow_named_1arg",
        probe = function(ctx)
            local pc = ctx and ctx.pc or nil
            if pc == nil then return false, "拿不到 PlayerController" end
            local name = Config.get("notify_func")
            if type(name) ~= "string" or name == "" then
                return false, "配置 notify_func 还没填（先按 O 探测，看 pwpr_ui.txt 里的候选结果）"
            end
            local fn, tv = find_callable(pc, name)
            if fn == nil then
                return false, "PlayerController 上没有 " .. name .. "（拿到 nil）"
            end
            return true, "有 " .. name .. "（type=" .. tostring(tv) .. "）"
        end,
        send = function(text, _ascii, ctx)
            local pc = ctx and ctx.pc or nil
            if pc == nil then return false, "拿不到 PlayerController" end
            local name = Config.get("notify_func")
            if type(name) ~= "string" or name == "" then return false, "notify_func 为空" end
            -- ★★ 必须写 pc[name](pc, text)，不能写 pc[name](text)。
            --   UE4SS 把 UFUNCTION 绑成"第一个参数就是对象自己"的函数
            --   （所以 obj:Func() 能用）。用点号只传 text 的话，
            --   引擎会把 text 当成 self —— 那就是野指针，直接访问违例。
            pc[name](pc, text)
            return true
        end,
    },
}

--- 按名字取通道定义。找不到返回 nil。
function Hud.channel_by_name(name)
    if type(name) ~= "string" then return nil end
    for i = 1, #Hud.CHANNELS do
        if Hud.CHANNELS[i].name == name then return Hud.CHANNELS[i] end
    end
    return nil
end

-- --------------------------------------------------------------------------
-- 探测 / 选通道
-- --------------------------------------------------------------------------

--- 逐个通道 probe，选出一个"游戏内"通道（没有就退回控制台）。
--- 返回 选中的通道名, 说明
---
--- ★ 这个函数会被按键触发（不是启动时），所以引擎调用都发生在"世界里已经站稳"之后。
function Hud.probe(ctx)
    local c = ctx or ensure_ctx()
    if c.pc == nil then c.pc = Hud.find_pc() end

    Hud.results = {}
    local best = nil
    for i = 1, #Hud.CHANNELS do
        local ch = Hud.CHANNELS[i]
        local ok, detail
        if ch.gate ~= nil and Config.get(ch.gate) ~= true then
            -- ★ 注意措辞（2026-09-28）: 这些高风险开关的默认值是 false，
            --   而配置文件**只写和默认值不同的键** ⇒ 文件里本来就没有这一行，
            --   所以只能说"自己加一行"，不能说"改成 true"（玩家找不到那个键）。
            ok, detail = false, "高风险通道默认关；要用就在 pwpr_config.json 里自己加一行 \""
                .. tostring(ch.gate) .. "\": true（该键默认不存在）"
        else
            local pok, r1, r2 = pcall(ch.probe, c)
            if not pok then
                ok, detail = false, "probe 抛 Lua 错误: " .. tostring(r1)
            else
                ok, detail = (r1 == true), tostring(r2 or "")
            end
        end
        Hud.results[ch.name] = { ok = ok, detail = detail }
        if ok and ch.in_game and best == nil then best = ch.name end
    end

    -- 配置可以强制指定一个通道（notify_channel）。指定的通道不可用就保持自动结果。
    local forced = Config.get("notify_channel")
    if type(forced) == "string" and forced ~= "" and forced ~= "auto" then
        local r = Hud.results[forced]
        if r ~= nil and r.ok then
            best = forced
        elseif r == nil then
            Hud.last_error = "配置 notify_channel = " .. forced .. " 不是已知通道名"
        end
    end

    Hud.active = best or "console"        -- 控制台永远是兜底
    Hud.probed = true
    Hud.available = (best ~= nil)
    Hud.ctx = c
    return Hud.active, Hud.channel_detail()
end

--- 当前通道的说明（用于日志/帮助）
function Hud.channel_detail()
    local ch = Hud.channel_by_name(Hud.active)
    if ch == nil then return "(没有通道)" end
    local r = Hud.results[Hud.active]
    return string.format("%s [%s]", ch.title, r and r.detail or "未探测")
end

-- --------------------------------------------------------------------------
-- 发文字
-- --------------------------------------------------------------------------

--- 请求一次探测（异步，丢到游戏线程）。
---
--- ★ 为什么要有它: 探测要读引擎，而调用 Hud.show 的地方有的是纯 Lua 的
---   按键处理器（on_direct）—— 在那里读引擎是早期崩溃的成因类别。
---   所以: **第一次要发提示时，把探测排到游戏线程上去**，
---   这一次先用控制台（零风险），下一次提示就能走游戏内通道了。
---   这样玩家不必"每次重启后按一次 O"。
function Hud.request_probe()
    if Hud.probed == true or Hud.probe_pending == true then return false end
    Hud.probe_pending = true
    local scheduled = Sched.game_thread(function()
        Hud.probe_pending = false
        pcall(function() Hud.probe(Hud.ctx) end)
        -- ★★ 探测完把"刚才没发出去的那一条"补发一次。
        --   为什么: 第一次提示时还没探测过 → 只能走控制台（屏幕上什么都没有），
        --   玩家反馈"进游戏后第一次按 Y 没有提示"就是这个原因。
        --   补发之后，第一次操作也能看见屏幕上的字。
        local p = Hud.pending
        Hud.pending = nil
        if p ~= nil and Hud.active ~= nil and Hud.active ~= "console" then
            pcall(function() Hud.show(p.text, p.ascii, p.kind) end)
        end
    end)
    if scheduled ~= true then Hud.probe_pending = false end
    return scheduled == true
end

--- 把一行文字送到画面。返回 ok[, 原因]
---   text  = 中文原文（给游戏内通道）
---   ascii = 控制台用的英文（不给就自动 ascii 化中文）
---   kind  = "normal"（正常提示，中性/蓝）| "error"（出错，红）—— 玩家要求的分工
---
--- ★★ 这个函数【绝对不碰引擎】。原因:
---   调用它的地方有好几个是 on_direct（纯 Lua / 文件 IO）的按键处理器，
---   比如 J（蓝图库）、F8（重载配置）、NUM_5（复位）。
---   如果这里偷偷去 FindAllOf 找 PlayerController，就等于在
---   "按键回调线程"上读引擎 —— 那是前几次崩溃的成因类别。
---   所以: 探测（要读引擎）只发生在按 O 的时候（走游戏线程）。
---   没探测过 -> 只有控制台通道可用（零风险，而且本来就能看见一行字）。
function Hud.show(text, ascii, kind)
    text = tostring(text or "")
    if text == "" then return false, "空文字" end

    -- 没探测过 -> 先排一次异步探测（游戏线程），本次退回控制台。
    -- 探测本身【不在本函数里同步做】—— 见 request_probe 的说明。
    -- ★ 把这一条记下来，探测完会补发（否则"进游戏后第一次操作"屏幕上看不见）。
    if Hud.probed ~= true and Hud.active == nil then
        Hud.pending = { text = text, ascii = ascii, kind = kind }
        Hud.request_probe()
    end

    -- 没探测过就用控制台兜底；探测过就用选中的通道
    local ch = Hud.channel_by_name(Hud.active or "console")
    if ch == nil then
        ch = Hud.channel_by_name("console")
    end
    if ch == nil then
        Hud.errors = Hud.errors + 1
        return false, "连控制台通道都没有（不该发生）"
    end

    -- 双保险: 非控制台通道必须【在本次会话里探测通过】才允许 send
    if ch.name ~= "console" then
        local r = Hud.results[ch.name]
        if r == nil then
            Hud.errors = Hud.errors + 1
            return false, "通道 " .. ch.name .. " 还没探测过（按一次 O）"
        end
        if r.ok ~= true then
            Hud.errors = Hud.errors + 1
            return false, "通道 " .. ch.name .. " 未通过探测: " .. tostring(r.detail)
        end
    end

    local pok, r1, r2 = pcall(ch.send, text, ascii, Hud.ctx, kind)
    if not pok then
        Hud.errors = Hud.errors + 1
        Hud.last_error = tostring(r1)
        return false, tostring(r1)
    end
    if r1 ~= true then
        Hud.errors = Hud.errors + 1
        Hud.last_error = tostring(r2 or "send 返回失败")
        -- ★ 游戏内通道失败了，至少退回控制台 —— 否则玩家"什么反馈都没有"。
        --   这也让"关掉自建控件（notify_own_widget=false）"变成一个可用的安全阀:
        --   屏幕不显示，但控制台/日志里还有。
        if ch.name ~= "console" then
            pcall(function()
                local cc = Hud.channel_by_name("console")
                if cc ~= nil and cc.send ~= nil then
                    cc.send(text, ascii, Hud.ctx, kind)
                end
            end)
        end
        return false, Hud.last_error
    end

    Hud.sent = Hud.sent + 1
    Hud.recent[#Hud.recent + 1] = text
    if #Hud.recent > Hud.recent_limit then table.remove(Hud.recent, 1) end
    return true
end

--- 最近发出的文字（给 F7 看"到底发出去了什么"）
function Hud.recent_lines()
    local out = {}
    for i = #Hud.recent, 1, -1 do
        out[#out + 1] = "   " .. Hud.recent[i]
    end
    if #out == 0 then out[1] = "   (还没发过)" end
    return out
end

--- 通道状态（多行，给 F7/日志用）
function Hud.status_lines()
    local out = {}
    out[#out + 1] = string.format(
        "屏幕提示: %s   通道=%s%s   已发=%d  失败=%d",
        Hud.enabled and "开" or "关",
        tostring(Hud.active),
        (Hud.probed == true) and "" or "（未探测）",
        Hud.sent, Hud.errors)
    for i = 1, #Hud.CHANNELS do
        local ch = Hud.CHANNELS[i]
        local r = Hud.results[ch.name]
        out[#out + 1] = string.format("   %-14s %-5s %s",
            ch.name,
            (r == nil and "?" or (r.ok and "可用" or "不可用")),
            tostring(r and r.detail or "未探测"))
    end
    if Hud.last_error ~= nil then
        out[#out + 1] = "   最近错误: " .. tostring(Hud.last_error)
    end
    if Hud.last_detail ~= nil and Hud.last_detail ~= "" then
        -- ★ 这里用「」不用英文双引号 —— 字符串里嵌英文引号是词法错误（踩坑记录 10-3）
        out[#out + 1] = "   最近一次发送的实况（诊断「写了字但看不见」靠这个）:"
        out[#out + 1] = "     " .. tostring(Hud.last_detail)
    end
    return out
end

--- 单行描述（main 的 F7 帮助里用）
function Hud.describe()
    local ch
    if Hud.probed ~= true then
        ch = "未探测（现在只有控制台；按 O 探测）"
    else
        ch = tostring(Hud.active)
    end
    return string.format("屏幕提示: %s（通道 %s，已发 %d 条）",
        Hud.enabled and "开" or "关", ch, Hud.sent)
end

return Hud
