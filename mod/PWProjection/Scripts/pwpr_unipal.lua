--[[ ===========================================================================
  PWPR · unipal  ——  UniPalUI 接入探针【阶段 A: 只读探测】

  ============================================================================
  这是什么 / 为什么需要
  ============================================================================
  待办 5 的"方案②"想让玩家**在游戏里用 UI 改键**，候选框架是 UniPalUI（Nexus 1894）。
  它的 API 是**蓝图函数库**（`/Game/Mods/UniPalUI/UPI_FunctionLibrary` + pak），
  我们（纯 Lua mod）到底能不能**调用**它、能不能**收到它的回调** —— 这一点
  **必须实机取证**，不能猜（玩家 2026-10-06 明确要求: 先做最小验证探针）。

  ============================================================================
  阶段划分（**只做安全的事**）
  ============================================================================
    · **阶段 A（本文件 = 现在做的）**: **只读**探测 ——
        ① UniPalUI 装没装/跑没跑（类、CDO、世界里的实例）；
        ② 它的 API 函数存在吗、**参数个数**是多少（`NumParms`）；
        ③ 结果写日志与 `F7`。
      ⇒ 全程 `StaticFindObject` / 读属性，**不调用任何 UniPalUI 函数** ⇒ 零风险。
    · **阶段 B（开关控制，默认关）**: 调一次 `UPI_SendNotif`（屏幕上应当出现它的通知）
      ⇒ 证明"调用链通"。用 `unipal_call_notif = true` 打开。
      ⚠️ 参数类型我们只能从 `NumParms` 推（先按字符串传）⇒ **可能崩**，
        所以默认关、而且只在函数存在且参数个数 1~2 时才尝试。
    · **阶段 C（还没做）**: `UPI_RegisterInput` + 收回调 —— 难点是它的回调走
      **蓝图接口 `UPI_InterfaceFunctions`**（纯 Lua 没有实现者），见
      `docs\UniPalUI接入探索.md` 里的分析与待验证项。

  ============================================================================
  为什么要"延迟到游戏线程跑"
  ============================================================================
  启动期是**最不该做额外动作**的时候（项目里为此吃过亏）。所以本探针由
  `main.lua` 用 `Sched.game_thread(..., 2500)` **排到启动后 2.5 秒**、
  在游戏线程上跑，并且整体 `pcall`。任何一步失败都只是"报告不全"，不影响别的功能。
=========================================================================== ]]

local Util = require("pwpr_util")
local Log  = require("pwpr_log")
local Config = require("pwpr_config")
local Sched  = require("pwpr_sched")

local Unipal = {}

--- ★★ 2026-10-07 **崩溃教训（规矩 3b-6 / 阶段 A "只读"被我自己破坏了）**:
---   上一版我把"逐成员问参数个数"放进了**阶段 A**，而问的办法是**故意 0 参调它** ——
---   对**参数个数为 0** 的函数（SDK 里 `UPI_ExitMenu` / `UPI_ForceBack` 就是 0 参），
---   这不是"问个数"而是**真的执行了那个 BP 函数**，而且宿主是 **CDO/类对象**（不是活的世界对象）
---   ⇒ 游戏**崩在 UE4SS 内部**（`EXCEPTION_ACCESS_VIOLATION reading 0x70`，调用栈 30 层全在 UE4SS；
---   UE4SS 日志最后一行正是阶段 A 的头部，之后 1 秒内崩）。
---   ⇒ **v11 的两条硬规矩**:
---     ① **阶段 A 绝对不调用任何函数**（只 `FindAllOf` + 读成员）；
---     ② **要调就调"参数个数已知"的**（查下面 `Unipal.ARITY`，来自 SDK 文档；查不到的**不调**），
---        并且**0 参函数一律不调**（`Unipal.NO_CALL`）。
--- ★★★ **实测签名**（2026-10-07，玩家用 UE4SS 控制台的 dumpers 导出 `UE4SS_ObjectDump.txt`
---   → "Generate BP SDK" 得到的 `UFunction` 属性表，**这是最权威的来源**）
---
--- 读法: 每个属性的 `[o: N]` 是内存偏移，**按偏移排序 = 参数顺序**；
---   ★ **UE4SS 的"参数个数"把输出参数也算进去** ⇒ 调用时必须**连输出位一起传**（输出位给 `nil`）。
---   这解释了为什么 `UPI_RegisterMod` 报 "expected 7"（SDK 文档只列 5 个输入）✓
Unipal.SIG = {
    -- callObject, ModName, ModCreator, RegisterMenu, EnterPage  + 输出 Valid, ErrorOutput
    UPI_RegisterMod = { n = 7, in_n = 5 },
    -- callObject, Message(Text), CallerName  —— **没有输出、没有未知参数** ⇒ 可以直接调 ✓
    UPI_SendNotif = { n = 3, in_n = 3 },
    -- callObject, InputName, InputDesc, InputActive, InputKey(Key 结构), Shift, Control, Alt,
    -- InputState, TillHold, HoldInterval  + 输出 Valid, Active, ErrorOutput
    UPI_RegisterInput = { n = 14, in_n = 11 },
    -- callObject, InputName, InputActive + 输出 Valid, ErrorOutput
    UPI_SetInputActive = { n = 5, in_n = 3 },
    -- callObject, EnterInputState + 输出 Valid, ErrorOutput
    UPI_EnterInputState = { n = 4, in_n = 2 },
    UPI_ExitInputState = { n = 4, in_n = 2 },
}
-- `SCML_CPP_NewObject`: **`Outer:Object, Class:Class`** + 返回 `NewObject`（3 槽）
--   ⚠️ 顺序是 `(Outer, Class)` —— 2026-10-07 我传反过（报 "Tried storing reference…"，安全失败）
Unipal.NEWOBJECT_N = 3

--- 旧的"文档值"表（**只用于 F7 显示参数个数，不再用于调用**）——
--- ⚠️ 2026-10-07 教训: 这份来自 SDK v0.01.09 文档的个数**是错的**（`UPI_RegisterMod` 文档 5 / 实测 7），
---   而且它**不含输出参数** ⇒ 拿它当调用依据会崩。调用一律用上面的 `Unipal.SIG`。
Unipal.ARITY = {
    -- 来自 SDK `UPI_SDK - ReadMe.md` 的 API 文档（**不靠试探**，试探就是调它）
    UPI_RegisterMod = 5, UPI_RegisterInput = 12, UPI_SetInputActive = 3,
    UPI_EnterInputState = 2, UPI_ExitInputState = 2,
    UPI_SendNotif = 2, UPI_OpenMenu = 3, UPI_CloseMenu = 1,
    UPI_AddMenuOption = 3, UPI_UpdateMenuOption = 3, UPI_UpdateDescBox = 3,
    UPI_ResetMenu = 1,
    -- 实测确认（玩家 `.72` 日志: `SCML_CPP_SendToUE4SSLog(2)` + 调用成功）
    SCML_CPP_SendToUE4SSLog = 2,
}
Unipal.NO_CALL = {
    -- **0 参**（SDK 文档里没有参数）⇒ 调它 = 直接执行 ⇒ 一律不调
    UPI_ExitMenu = true, UPI_ForceBack = true,
}

--- 同步黑匣子（崩了也能在磁盘上留下"最后走到哪一步"）
function Unipal.solid(msg)
    pcall(function() Log.solid("[unipal] " .. tostring(msg)) end)
end

-- 【已废弃 v1 的探测方式，只留注释当教训】类路径清单（`StaticFindObject` 用）
-- ⚠️ 2026-10-06 实测证明它**不可靠**（不存在的路径也返回非 nil）⇒ v2 已不用它检测，
--    改成 `FindAllOf("..._C")`（可靠）。留着这段注释是为了后人别再走一遍。
--   /Game/Mods/UniPalUI/UPI_FunctionLibrary.UPI_FunctionLibrary_C
--   /Game/Mods/UniPalUI/UPI_WorldActor.UPI_WorldActor_C
--   /Game/Mods/UniPalUI/UPI_Handler.UPI_Handler_C
--   /Game/Mods/UniPalUI/UPI_MenuGenBox.UPI_MenuGenBox_C
--   /Game/Mods/UniPalUI/SCML_Core.SCML_Core_C

-- 它自己页面里列的 API（我们要探测"存不存在 + 几个参数"）
Unipal.API_NAMES = {
    "UPI_RegisterMod", "UPI_RegisterInput", "UPI_SetInputActive",
    "UPI_EnterInputState", "UPI_ExitInputState",
    "UPI_SendNotif", "UPI_OpenMenu", "UPI_CloseMenu",
    "UPI_AddMenuOption", "UPI_UpdateMenuOption", "UPI_UpdateDescBox",
    "UPI_ResetMenu", "UPI_ExitMenu",
}

-- 世界里可能存在的实例类名（`FindAllOf` 用类名，不是路径）
-- ★ 实测（2026-10-06 第二轮日志）: 装上 UniPalUI 后这四个各 1 个、没装时全是 0 ——
--   `FindAllOf` 是**可靠**的检测手段（而 `StaticFindObject("<路径>")` **不可靠**，
--   对不存在的路径也会返回非 nil ⇒ 已从检测逻辑里去掉）。
-- ★ 也把函数库的 CDO 类名放进来: 蓝图函数库没有"世界实例"，但它的 CDO 也能被
--   `FindAllOf` 枚举到（API 有可能只挂在函数库上，那样我们就得调它的 CDO）。
Unipal.INSTANCE_CLASS_NAMES = {
    "UPI_WorldActor_C", "UPI_Handler_C", "UPI_UICore_C", "SCML_WorldActor_C",
    "UPI_FunctionLibrary_C", "SCML_FunctionLibrary_C",
}

Unipal.result = nil      -- { detected=, classes={}, api={}, instances={}, funcs={}, notes={} }

-- --------------------------------------------------------------------------
-- ★ v3（2026-10-06 第二轮实测之后）: "怎么才能可靠地拿到它的函数"
-- --------------------------------------------------------------------------
-- v2 的实测结果: 检测对了（活实例 ×4），但 **`Children` 链枚举到 0 个函数** ⇒
--   说明 UE5 里 `UStruct.Children` 是**非反射**的 FField/UField 指针，UE4SS 的属性
--   访问够不着（`cls.Children` 读到 nil）。`ChildProperties` 同理（而且它只装属性，不装函数）。
--
-- ⇒ v3 同时试**三种**手段，并**逐个统计**（这样下一份日志能直接告诉我们哪种有效）:
--   ① `StaticFindObject("<类路径>:<函数名>")` + **严格校验**；
--   ② 活实例上的**成员读取**（`inst["UPI_SendNotif"]`）+ 严格校验；
--   ③ `Children/Next` 链（v2 已证无效，留着当对照）。
--   ★ **严格校验**（关键 —— v1 就是被 TrivialObject 骗了）:
--       · 不是 nil
--       · `tostring()` 里**没有** "TrivialObject"（UE4SS 对"不存在的成员"会给这个假对象）
--       · `NumParms` **读得出来**（真 `UFunction` 必有；假对象给 nil）
--       · `GetFullName()` 里**含**这个函数名
--     四条全过才算"真的存在"。
Unipal.LIB_CLASS_PATH =
    "/Game/Mods/UniPalUI/UPI_FunctionLibrary.UPI_FunctionLibrary_C"
-- ★ 2026-10-06 第四轮实测（玩家日志里"活实例的真实类"那行）修正:
--   `SCML_WorldActor` 在**另一个目录** `/Game/Mods/SCML/`（不是 UniPalUI 下）；
--   另外把实测确认的 Handler/UICore 也放进来当候选。
Unipal.WORLD_CLASS_PATHS = {
    "/Game/Mods/UniPalUI/UPI_WorldActor.UPI_WorldActor_C",
    "/Game/Mods/UniPalUI/UPI_Handler.UPI_Handler_C",
    "/Game/Mods/UniPalUI/UPI_UICore.UPI_UICore_C",
    "/Game/Mods/SCML/SCML_WorldActor.SCML_WorldActor_C",
}

--- 严格校验一个"函数对象"是不是真的（见上面四条）
---
--- ⚠️⚠️ 2026-10-06 第四轮实测发现 **v3/v4 的校验条件写错了**:
---   我要求"`NumParms` 读得出来"—— 但 UE 里 **`UFunction.NumParms` 不是反射属性**
---   （没有 `UPROPERTY`）⇒ UE4SS **按名字读不到** ⇒ **真函数也被判成假** ⇒
---   "三手段全 0"**不能说明名字不对**！⇒ v5 改成:
---     · 去掉 `NumParms` 这个**必要条件**（拿得到就报，拿不到就记 "?"）；
---     · 保留"非 nil + 不是 TrivialObject"作为**存在性**判据；
---     · 并且**把原始返回值报出来**（`type` + `tostring` 前 80 字），
---       这样"名字不对"和"被我误杀"一眼可分。
function Unipal.validate_func(v, want_name)
    v = Util.unwrap(v)
    if v == nil then return nil end
    local s = nil
    pcall(function() s = tostring(v) end)
    if type(s) ~= "string" then return nil end
    if s:find("TrivialObject", 1, true) ~= nil or s == "nil" then return nil end
    local parms = nil
    pcall(function() parms = v.NumParms end)
    parms = tonumber(parms)
    local fname = Util.full_name(v)
    -- 存在性判据: 名字对得上【或者】它本来就是个 Lua 函数（UE4SS 的成员读取会给这个）
    local by_name = (type(fname) == "string") and (want_name == nil)
        or ((type(fname) == "string") and fname:find(want_name, 1, true) ~= nil)
    if not by_name and type(v) ~= "function" then
        return nil
    end
    return { num_parms = parms, full_name = fname, raw_type = type(v), raw_text = s }
end

--- 只做"原始面貌"记录（给诊断用，不判真假）: 返回 "type=tostring" 短串
function Unipal.sample_of(v)
    if v == nil then return "nil" end
    local s, t = nil, nil
    pcall(function() s = tostring(v) end)
    pcall(function() t = type(v) end)
    s = tostring(s or "?")
    if #s > 70 then
        -- ★ 注意: 这里**不要**写成 `s = s:sub(1,70) .. "…" end`（同一行）
        --   —— `tools\luacheck.py` 的"保留字当字段名"规则会把 `.. end` 误判成 `.end`
        --   （2026-10-06 被它拦了一次）。多行写就没事。
        s = s:sub(1, 70) .. "…"
    end
    return string.format("%s=%s", tostring(t or "?"), s)
end

--- ★★ **零副作用地问出这个函数要几个参数**（2026-10-06 从错误信息里学到的技巧）
---
--- 依据（玩家 `.70` 日志）: 我少传参数时，UE4SS 抛的是
---   `[UFunction::setup_metamethods -> __call] UFunction expected 2 parameters, received 1`
--- ⇒ ① 这句错误**直接给出了真实参数个数**；
---    ② 而且**校验发生在执行之前**（没跑进原生代码）⇒ **故意少传 = 零副作用**。
--- ⇒ 拿一个真 UFunction、故意用 0 个参数调一次、从错误里读 N，就能**安全地**知道
---   "该传几个"（这一步不执行任何东西）。
--- 返回: N(number) 或 nil（读不出来）
--- ★★ **危险·默认不要用**（2026-10-07 教训）: 故意 0 参调一次、从错误里读 `expected N`。
---   **对参数个数 >0 的函数**它是安全的（UE4SS 在"执行前"就报参数个数不符）；
---   **但对 0 参函数 = 真的执行那个函数** ⇒ 宿主不对（CDO/类）就会崩游戏。
---   ⇒ 现在**阶段 A 完全不用它**；要调函数一律查 `Unipal.ARITY`（SDK 文档值）。
function Unipal.probe_arity(fn_obj)
    fn_obj = Util.unwrap(fn_obj)
    if fn_obj == nil then return nil end
    local _, err = pcall(function() fn_obj() end)     -- 故意 0 个参数
    local s = tostring(err or "")
    local n = s:match("expected (%d+) parameters")
    return tonumber(n)
end

--- 阶段 A: 只读探测。返回结果表（同时存进 Unipal.result）
---
--- ★★ 2026-10-06 第一次实测（玩家两轮日志）的教训 —— **探针 v1 的检测是错的**:
---   未安装 UniPalUI 时它仍然报告 `类: 5/5 找到` + `API: 13/13 找到`，
---   而 `NumParms` 全是 `?`（读不到）⇒ 说明 `StaticFindObject("<类路径>")` 对
---   **不存在的路径也返回了非 nil**（不是真对象）。**唯一可靠的信号是 `FindAllOf`** ——
---   同两份日志里"活实例"从 `无` 变成 `UPI_WorldActor_C×1 …×4`，完全正确。
--- ⇒ **v2 的规矩**:
---   · **检测**只信 `FindAllOf`（活实例）与"从活实例拿到的类"；
---   · **函数**不再靠 `StaticFindObject` 猜路径，而是 `实例:GetClass()` → 沿
---     `Children/Next` 函数链**枚举真函数**（读 `GetName()` + `NumParms`）；
---   · `StaticFindObject` 的结果只在**都被证明可靠之后**才敢用来调用（见 `try_call_notif`）。
function Unipal.probe()
    -- ★ 黑匣子: 阶段 A 的每一步都留同步落盘的痕迹（崩了也知道走到哪）
    --   （2026-10-07 那次崩溃就是因为危险步骤没埋点、只能靠 UE4SS 日志反推）
    Unipal.solid("阶段A: 开始（FindAllOf 检测活实例）")
    local res = {
        detected = false, classes = {}, api = {}, instances = {}, notes = {},
    }

    -- ① **可靠的检测**: 世界里有没有它的活实例（`FindAllOf`）
    local live = {}
    for i = 1, #Unipal.INSTANCE_CLASS_NAMES do
        local cname = Unipal.INSTANCE_CLASS_NAMES[i]
        local objs = nil
        pcall(function() objs = FindAllOf(cname) end)
        local n, first = 0, nil
        if type(objs) == "table" then
            local ok, cnt = pcall(function() return #objs end)
            if ok and type(cnt) == "number" then
                n = cnt
                if n > 0 then
                    pcall(function() first = Util.unwrap(objs[1]) end)
                end
            end
        end
        res.instances[cname] = n
        if n > 0 then
            res.detected = true
            live[#live + 1] = { class_name = cname, obj = first, count = n }
        end
    end

    -- ② 从**活实例**拿类，再沿 `Children/Next` 链**枚举真函数**（拿 NumParms）
    --    —— 这是唯一能拿到"参数个数"的可靠办法（`ForEachFunction` 是本项目禁用接口）。
    res.funcs = {}
    for i = 1, #live do
        local inst = live[i]
        local cls = nil
        pcall(function() cls = inst.obj:GetClass() end)
        cls = Util.unwrap(cls)
        if cls ~= nil then
            local cls_name = nil
            pcall(function() cls_name = cls:GetFullName() end)
            res.classes[inst.class_name] = {
                found = true, class_name = tostring(cls_name), from_instance = true,
            }
            local list = {}
            Unipal.walk_functions(cls, list, 600)
            res.funcs[inst.class_name] = list
        end
    end

    -- ③ 汇总 API: 三策略依次尝试，**严格校验**之后才算数
    --    （统计各策略命中数 ⇒ 下一份日志能告诉我们哪种手段有效）
    res.strategy = { static_find = 0, member = 0, children = 0 }
    local seen = {}
    -- ③-a 策略①: StaticFindObject("<类路径>:<函数名>")
    local lib_paths = { Unipal.LIB_CLASS_PATH }
    for i = 1, #Unipal.WORLD_CLASS_PATHS do
        lib_paths[#lib_paths + 1] = Unipal.WORLD_CLASS_PATHS[i]
    end
    for i = 1, #Unipal.API_NAMES do
        local name = Unipal.API_NAMES[i]
        for j = 1, #lib_paths do
            local v = nil
            pcall(function() v = StaticFindObject(lib_paths[j] .. ":" .. name) end)
            local info = Unipal.validate_func(v, name)
            if info ~= nil and seen[name] == nil then
                seen[name] = {
                    found = true, num_parms = info.num_parms,
                    where = lib_paths[j], how = "StaticFindObject",
                }
                res.strategy.static_find = res.strategy.static_find + 1
            end
        end
    end
    -- ③-b 策略②: 活实例上的成员读取（`inst["UPI_SendNotif"]`）
    for i = 1, #live do
        local inst = live[i]
        for j = 1, #Unipal.API_NAMES do
            local name = Unipal.API_NAMES[j]
            if seen[name] == nil then
                local v = nil
                pcall(function() v = inst.obj[name] end)
                local info = Unipal.validate_func(v, name)
                if info ~= nil then
                    seen[name] = {
                        found = true, num_parms = info.num_parms,
                        where = inst.class_name, how = "member",
                    }
                    res.strategy.member = res.strategy.member + 1
                end
            end
        end
    end
    -- ③-c 策略③: Children/Next 链（v2 已证无效，留作对照）
    for cname, list in pairs(res.funcs or {}) do
        for k = 1, #list do
            local f = list[k]
            if seen[f.name] == nil then
                seen[f.name] = {
                    found = true, num_parms = f.num_parms, where = cname, how = "children",
                }
                res.strategy.children = res.strategy.children + 1
            end
        end
    end
    for i = 1, #Unipal.API_NAMES do
        local name = Unipal.API_NAMES[i]
        res.api[name] = seen[name] or { found = false }
    end

    -- ④ 记一笔统计（下一份日志据此判断"哪种手段有效"）
    res.notes[#res.notes + 1] = string.format(
        "函数枚举手段命中: StaticFindObject=%d / 活实例成员=%d / Children链=%d",
        res.strategy.static_find, res.strategy.member, res.strategy.children)

    -- ④ ★★ v4（2026-10-06 第三轮实测之后）: 三手段全 0 ⇒ 说明**那 13 个名字可能不对**
    --    （我们那份清单来自它 Nexus 页面的 "0.1DEV" 版本，而玩家装的是 "V0.01.10 TEST"，
    --      它的 Changelog 自己写了改名/破坏性变更）。所以改从**可以发现的地方**找真名:
    --    · **扫 Lua 全局**（`_G`）—— 它的 DLL 有 `on_lua_start`，DLL 字符串里也确实有
    --      `SCML_CPP_FindAllOf/FindFirstOf/NewObject/SendToUE4SSLog` ⇒ **它的 Lua API 很可能
    --      是"DLL 注册进 Lua 的全局函数"**，而不是蓝图函数。**这一步完全不碰引擎**（纯 Lua 表遍历）。
    --    · 顺便记下**每个活实例的真实类全名**（下一份日志就能看到正确的类路径）。
    do
        local lua_g = {}
        local g = nil
        pcall(function() g = _G end)
        if type(g) == "table" then
            local n = 0
            for k, v in pairs(g) do
                if type(k) == "string" and n < 4000 then
                    n = n + 1
                    local kl = string.lower(k)
                    if kl:find("unipal", 1, true) or kl:find("scml", 1, true)
                        or kl:find("^upi_") or kl:find("^upi") then
                        lua_g[#lua_g + 1] = string.format("%s(%s)", k, type(v))
                    end
                end
            end
        end
        table.sort(lua_g)
        res.lua_globals = lua_g
        res.notes[#res.notes + 1] = string.format(
            "Lua 全局里像 UniPalUI/SCML 的名字: %d 个%s", #lua_g,
            (#lua_g > 0) and (" → " .. table.concat(lua_g, " ")) or "")
    end
    do
        local cls_names = {}
        for cname, info in pairs(res.classes or {}) do
            cls_names[#cls_names + 1] = string.format("%s=%s", tostring(cname),
                tostring(info.class_name))
        end
        table.sort(cls_names)
        if #cls_names > 0 then
            res.notes[#res.notes + 1] = "活实例的真实类: " .. table.concat(cls_names, " · ")
        end
    end

    -- ④ ★ v5（2026-10-06 第四轮实测之后）: **把"原始返回值"报出来**
    --   v3/v4 的"三手段全 0"其实是**我的校验条件写错**造成的可能无法排除
    --   （`UFunction.NumParms` 不是反射属性 ⇒ 真函数也会被我判假）。
    --   ⇒ 这里对**每个名字**分别记录: StaticFindObject 返回了什么、活实例成员读到了什么
    --     （`type` + `tostring`），这样"名字不对"和"被我误杀"一眼可分。
    res.raw = { static_find = {}, member = {} }
    for i = 1, #Unipal.API_NAMES do
        local name = Unipal.API_NAMES[i]
        -- ① StaticFindObject（函数库 + 几个真实类）—— 记原始面貌
        local sv = nil
        pcall(function() sv = StaticFindObject(Unipal.LIB_CLASS_PATH .. ":" .. name) end)
        res.raw.static_find[name] = Unipal.sample_of(sv)
        -- ② 活实例成员读取 —— 记原始面貌（第一个活实例上试）
        local mv = nil
        if #live > 0 then
            pcall(function() mv = live[1].obj[name] end)
        end
        res.raw.member[name] = Unipal.sample_of(mv)
    end
    -- 汇总成两行短报告（只列"不是 nil"的，nil 的只报个数）
    local function summarize(tbl)
        local hits, n = {}, 0
        for i = 1, #Unipal.API_NAMES do
            local name = Unipal.API_NAMES[i]
            local s = tbl[name]
            if s ~= nil and s:sub(1, 3) ~= "nil" then
                hits[#hits + 1] = string.format("%s→%s", name, s)
            else
                n = n + 1
            end
        end
        return #hits, n, hits
    end
    local n1, miss1, h1 = summarize(res.raw.static_find)
    local n2, miss2, h2 = summarize(res.raw.member)
    res.notes[#res.notes + 1] = string.format(
        "原始返回(StaticFindObject): 非 nil %d / nil %d%s", n1, miss1,
        (#h1 > 0) and (" → " .. table.concat(h1, " · ")) or "")
    res.notes[#res.notes + 1] = string.format(
        "原始返回(活实例成员): 非 nil %d / nil %d%s", n2, miss2,
        (#h2 > 0) and (" → " .. table.concat(h2, " · ")) or "")

    Unipal.solid("阶段A: 完成（未调用任何函数）")
    Unipal.result = res
    return res
end

--- 沿 `UStruct.Children` / `UField.Next` 链枚举函数（**只读**、有上限、每步 pcall）。
--- `out` 里每项: `{ name=, num_parms= }`。拿不到 `Children` 就返回 0（不算错，记一笔）。
function Unipal.walk_functions(cls, out, max_n)
    if cls == nil or type(out) ~= "table" then return 0 end
    local maxn = tonumber(max_n) or 400
    local child = nil
    pcall(function() child = cls.Children end)
    child = Util.unwrap(child)
    if child == nil then return 0 end
    local n, guard = 0, 0
    while child ~= nil and n < maxn and guard < (maxn * 4) do
        guard = guard + 1
        local nm, parms, nxt = nil, nil, nil
        pcall(function() nm = child:GetName() end)
        pcall(function() parms = child.NumParms end)
        pcall(function() nxt = child.Next end)
        if nm ~= nil then
            out[#out + 1] = {
                name = tostring(nm),
                num_parms = tonumber(parms),
            }
            n = n + 1
        end
        child = Util.unwrap(nxt)
    end
    return n
end

--- 阶段 B（默认关，配置 `unipal_call_notif`）—— 2026-10-06 **拿到 SDK 之后重写成"三步真调"**
---
--- 依据（SDK `UPI_SDK - ReadMe.md` 里的 API 文档，签名都是**原文**）:
---   · `SCML_CPP_SendToUE4SSLog(Message)` —— **零副作用、可观察**（往 UE4SS 日志/控制台写一行）
---     ⇒ 用它回答根本问题: **"我们（纯 Lua）到底能不能调用它的蓝图函数库？"** ✓
---   · `UPI_RegisterMod(CallObject, ModName, ModCreator, RegisterMenu, EnterMenu)`
---     ⇒ 有返回值 `Valid` / `ErrorOutput` —— **让它的 API 自己告诉我们"这个 CallObject 行不行"** ✓
---   · `UPI_SendNotif(CallObject, Message)` —— 屏幕上出现通知 ⇒ 调用链通
---   ⚠️ **`CallObject` 必须是"实现了接口 `UPI_InterfaceFunctions` 的对象"**（纯 Lua 造不出来）——
---      所以这里按优先级试几个候选，并把它的返回码**原样报出来**（这一步就是在验证这条限制）。
--- 返回 (ok, 说明)
--- 阶段 B（默认关，配置 `unipal_call_notif`）—— 2026-10-06 **v7: 把错误原文说出来**
---
--- 依据（SDK `UPI_SDK - ReadMe.md` 的 API 文档，签名是原文）:
---   · `SCML_CPP_SendToUE4SSLog(Message)` —— 零副作用、可观察（往 UE4SS 日志写一行）
---   · `UPI_RegisterMod(CallObject, ModName, ModCreator, RegisterMenu, EnterMenu)` -> Valid/ErrorOutput
---   · `UPI_SendNotif(CallObject, Message)`
---
--- ⚠️⚠️ v6 实测（玩家 `.69` 日志）暴露的**我自己的问题**:
---   `① SCML 函数库调用: 失败（三条路径都没调通）` + `② Valid=nil ErrorOutput=nil` ——
---   但**报错原文被我 `pcall` 吞了**、返回值个数/类型也没记 ⇒ **只能猜**（是我路径错？方法不存在？
---   还是这个 UE4SS 版本不支持这样调？）。
--- ⇒ **v7 的规矩: 任何一次尝试都要留下三样东西**:
---     ① **方法在不在这对象上**（`obj.Func` 的原始面貌 —— 不需要真的调用就能判"名字/对象对不对"）；
---     ② `pcall` 的**错误原文**（截断）；
---     ③ 返回值的**个数与类型/值**（`select("#", …)` + 逐个 `type`/`tostring`）。
---   ★ 这三样一有，就能区分"路径错 / 方法不存在 / 调用方式不被支持 / 参数不对"。
--- 返回 (ok, 说明)
function Unipal.try_call_notif(text)
    local res = Unipal.result
    if res == nil then return false, "还没跑阶段 A" end
    local msg = tostring(text or "PWProjection 探针")
    local log = {}

    -- ★ v8（2026-10-06 玩家 `.70` 日志的教训）:
    --   · 之前②的候选对象选错了 —— **API 不在世界 actor 上**（那些成员读到的是 TrivialObject），
    --     而在**函数库**（`UPI_FunctionLibrary` / `SCML_FunctionLibrary`）的 CDO 上 ✓
    --     （同日志里 `SCML_FunctionLibrary.CDO` 的成员是**真 UFunction**）。
    --   · 而且**参数个数**可以从错误信息里安全地问出来（`probe_arity`）⇒ 先问再调。
    local libs = {
        { p = "/Game/Mods/UniPalUI/UPI_FunctionLibrary.Default__UPI_FunctionLibrary_C", n = "UPI_FunctionLibrary.CDO" },
        { p = "/Game/Mods/UniPalUI/UPI_FunctionLibrary.UPI_FunctionLibrary_C", n = "UPI_FunctionLibrary.C" },
        { p = "/Game/Mods/SCML/SCML_FunctionLibrary.Default__SCML_FunctionLibrary_C", n = "SCML_FunctionLibrary.CDO" },
    }
    local resolved = {}
    for i = 1, #libs do
        local obj = nil
        pcall(function() obj = StaticFindObject(libs[i].p) end)
        log[#log + 1] = string.format("① %s → %s", libs[i].n, Unipal.sample_of(obj))
        if obj ~= nil and Unipal.sample_of(obj):sub(1, 3) ~= "nil" then
            resolved[#resolved + 1] = { name = libs[i].n, obj = obj }
        end
    end

    -- ★ v10（2026-10-06 玩家 `.72` 日志 + pak 资产清单的线索）:
    --   · ✅ **重大结果**: `③ SCML write-log (string, UObject) (on SCML_Lib.C): **OK**`
    --     ⇒ **纯 Lua 确实能调用它的蓝图函数库**（参数顺序 `(字符串, UObject)`、2 个参数，已实测确定）
    --   · ❌ `② UPI_Lib.CDO / UPI_Lib.C: 真 UFunction **0** 个` —— 而且
    --     `① UPI_FunctionLibrary.C → userdata=**UObject**`（SCML 那边是 `UClass`）
    --     ⇒ **我给的 UPI 路径根本没指到一个类** ⇒ 那 13 个函数**不在** UPI_FunctionLibrary 上。
    --   · 线索（SDK 文档 + pak 资产清单）: 文档那组 `UPI_*` 挂在
    --     **「## UniPalUI —— The main UniPalUI Actor」** 下 ⇒ 它们应该在 **`UniPalUI` 这个 Actor 类**上；
    --     pak 里也确实有 `/Game/Mods/UniPalUI/UniPalUI`。
    --   ⇒ v10: **从类名入手**（`FindAllOf` 是实测可靠的手段），逐个类看
    --     "这个类上能读到的 `UPI_*` / `SCML_*` 真 UFunction 有几个"。
    local class_names = {
        "UniPalUI_C", "UPI_FunctionLibrary_C", "UPI_ModObject_C",
        "UPI_WorldActor_C", "UPI_Handler_C", "UPI_UICore_C",
        "SCML_FunctionLibrary_C", "SCML_UI_Core_C", "SCML_UI_ModObject_C",
        "SCML_UI_WorldActor_C", "SCML_UI_Handler_C",
    }
    local probes = { "SCML_CPP_SendToUE4SSLog" }
    for j = 1, #Unipal.API_NAMES do probes[#probes + 1] = Unipal.API_NAMES[j] end

    local found = {}
    local objs = {}
    for i = 1, #class_names do
        local cname = class_names[i]
        Unipal.solid("阶段A: 扫类 " .. cname)   -- 只读（FindAllOf + 读成员），但留个脚印
        local insts = nil
        pcall(function() insts = FindAllOf(cname) end)
        local n_inst = 0
        local one = nil
        if type(insts) == "table" then
            local ok, cnt = pcall(function() return #insts end)
            if ok and type(cnt) == "number" then
                n_inst = cnt
                if cnt > 0 then pcall(function() one = Util.unwrap(insts[1]) end) end
            end
        end
        if n_inst == 0 then
            log[#log + 1] = string.format("① %s: FindAllOf=0", cname)
        else
            -- 对象/类都当候选（函数库是静态函数 ⇒ 可能挂在 CDO 或类上）
            local cand = { one }
            local cls = nil
            pcall(function() cls = one:GetClass() end)
            cls = Util.unwrap(cls)
            if cls ~= nil and cls ~= one then cand[#cand + 1] = cls end
            local shown = {}
            for k = 1, #cand do
                local o = cand[k]
                objs[#objs + 1] = { name = string.format("%s[%d]", cname, k), obj = o }
                local hits = {}
                for j = 1, #probes do
                    local m = nil
                    pcall(function() m = o[probes[j]] end)
                    if Unipal.sample_of(m):find("UFunction", 1, true) ~= nil then
                        -- ★★ v11: **这里绝对不调用它**（原来用 `probe_arity` 故意 0 参调，
                        --   对 0 参函数就是真的执行 ⇒ 2026-10-07 崩游戏）。
                        --   参数个数一律查 SDK 表（`Unipal.ARITY`），查不到就记 "?"。
                        local ar = Unipal.ARITY[probes[j]]
                        local mark = Unipal.NO_CALL[probes[j]] and "【0参·禁调】" or ""
                        hits[#hits + 1] = string.format("%s(%s)%s", probes[j],
                            tostring(ar or "?"), mark)
                        if found[probes[j]] == nil and k == 1 then
                            -- ★ 只把**活实例**（k==1）登记成"可调用目标"；
                            --   类对象/CDO（k==2）只报告成员，**不当作调用宿主**
                            --   （2026-10-07 崩的那次就是在 CDO 上执行了 BP 函数 ⇒ null+0x70）
                            found[probes[j]] = {
                                obj = o, name = string.format("%s[%d]", cname, k),
                                fn = m, arity = ar,
                            }
                        end
                    end
                end
                shown[#shown + 1] = string.format("%d个%s", #hits,
                    (#hits > 0) and ("→ " .. table.concat(hits, " ")) or "")
            end
            log[#log + 1] = string.format("① %s: FindAllOf=%d, 成员: %s", cname, n_inst,
                table.concat(shown, " / "))
        end
    end

    -- ② SCML 那个"写一行日志"用两种参数顺序试调（它的报错曾告诉我们它要 UObject）
    local scml_called = false
    local scml = found.SCML_CPP_SendToUE4SSLog
    local any_uobject = nil
    for j = 1, #class_names do
        local cname = class_names[j]
        if (res.instances or {})[cname] ~= nil and (res.instances[cname] or 0) > 0 then
            local a = nil
            pcall(function() a = FindAllOf(cname) end)
            if type(a) == "table" then pcall(function() any_uobject = Util.unwrap(a[1]) end) end
        end
        if any_uobject ~= nil then break end
    end
    if any_uobject == nil and #objs > 0 then any_uobject = objs[1].obj end
    if scml ~= nil and scml.fn ~= nil then
        local n = tonumber(scml.arity) or 2
        local forms = {
            { label = "(string, UObject)", args = { msg .. " 【SCML order1】", any_uobject } },
            { label = "(UObject, string)", args = { any_uobject, msg .. " 【SCML order2】" } },
        }
        for i = 1, #forms do
            local args = forms[i].args
            while #args > n do table.remove(args) end
            while #args < n do args[#args + 1] = any_uobject end
            Unipal.solid(string.format("阶段B: 调 SCML 写日志（%s, %d 参, 宿主=%s）",
                forms[i].label, n, scml.name))
            local ok, err = pcall(function() scml.fn(scml.obj, table.unpack(args)) end)
            log[#log + 1] = string.format("② SCML write-log %s (on %s): %s%s",
                forms[i].label, scml.name, ok and "**OK**" or "FAIL",
                ok and "" or ("(" .. tostring(err):sub(1, 110) .. ")"))
            if ok then scml_called = true break end
        end
    else
        log[#log + 1] = "② SCML write-log: 这次没在任何类上读到它"
    end

    -- ③ ★★ **高危步骤: `UPI_RegisterMod`**（2026-10-07 `.75` 实测: **CallObject 不合格 ⇒ 崩游戏**）
    --    三重门才允许调: ① 配置 `unipal_try_register=true`；② 活实例上读到了这个函数；
    --    ③ **有合格的 CallObject** —— 只认"像 mod 回调对象"的类（类名含 `ModObject`）的实例。
    --    调法仍然是"先用文档值试 → 从 `expected N` 读真实个数 → 用真实个数重试"
    --    （★ 安全依据: 个数不符时 UE4SS **执行前**报错、函数没跑 —— 两次实测都这样）。
    local callobj, callobj_name = nil, nil
    -- ★ `callobj_src`: "scml" = 用**作者自己的代理**造出来的（唯一被允许拿去注册的）；
    --   "static" = 我们直接 StaticConstructObject 生造的 —— **2026-10-07 实测: 拿它去注册会崩游戏** ✗
    local callobj_src = nil
    -- ★★ **路①（2026-10-07 玩家选定）: 运行时造一个 `UPI_ModObject_C` 实例当 `CallObject`**
    --    依据: pak 里有 `UPI_ModObject`（`FindAllOf("UPI_ModObject_C")=1` ⇒ 这个类在跑），
    --    它的名字正是"mod 的（回调）对象"⇒ 应该是实现了接口 `UPI_InterfaceFunctions` 的模板。
    --    ⚠️ **这一步也可能崩**（BP 构造可能有副作用）⇒ 单独开关 `unipal_create_modobject`（默认 false）
    --      + 只有**真的尝试过**才写黑匣子（这样崩了我们也能知道"崩在创建对象"）。
    local cfg_create = nil
    pcall(function() cfg_create = Config.get("unipal_create_modobject") end)
    if cfg_create == true then
        local mod_cls = nil
        for i = 1, #objs do
            if tostring(objs[i].name or ""):find("UPI_ModObject_C", 1, true) ~= nil then
                pcall(function() mod_cls = objs[i].obj:GetClass() end)
                mod_cls = Util.unwrap(mod_cls)
                if mod_cls ~= nil then break end
            end
        end
        local outer = any_uobject
        Unipal.solid(string.format("路①: 尝试 StaticConstructObject(UPI_ModObject_C, outer=%s)",
            Unipal.sample_of(outer)))
        local made, how, err1 = nil, nil, nil
        if mod_cls ~= nil then
            -- 依次试 2 参 / 3 参（Lua 层的报错是安全的，pcall 能抓住）
            local ok2, v2 = pcall(function() return StaticConstructObject(mod_cls, outer) end)
            if ok2 and Util.unwrap(v2) ~= nil then
                made, how = Util.unwrap(v2), "2 参"
            else
                err1 = v2
                local ok3, v3 = pcall(function()
                    return StaticConstructObject(mod_cls, outer, "PWPR_ModObject")
                end)
                if ok3 and Util.unwrap(v3) ~= nil then
                    made, how = Util.unwrap(v3), "3 参"
                else
                    err1 = v3
                end
            end
        else
            err1 = "没找到 UPI_ModObject_C 的类对象"
        end
        if made ~= nil then
            callobj, callobj_name = made, "新建的 UPI_ModObject_C(" .. tostring(how) .. ")"
            callobj_src = "static"
            log[#log + 1] = string.format("⓪ 新建 CallObject: **成功**（%s）→ %s",
                tostring(how), Unipal.sample_of(made))
            Unipal.solid("路①: 新建成功 " .. Unipal.sample_of(made))
            -- ★★ 再用**作者自己提供的接口**试造一个: `SCML_CPP_NewObject`（changelog 说它是
            --   UE4SS `StaticConstructObject` 的代理、"返回给定类的对象"）——
            --   它可能替我们做了必要初始化（那正是"注册时崩"的可疑原因）。
            --   先问参数个数（**这个函数至少有 1 个参数（类），所以 0 参调用是安全的** —— 实测规律）。
            local a = nil
            pcall(function() a = FindAllOf("SCML_WorldActor_C") end)
            local scml_actor = nil
            if type(a) == "table" then pcall(function() scml_actor = Util.unwrap(a[1]) end) end
            if scml_actor ~= nil then
                local m = nil
                pcall(function() m = scml_actor.SCML_CPP_NewObject end)
                if Unipal.sample_of(m):find("UFunction", 1, true) ~= nil then
                    local n = Unipal.probe_arity(m)   -- ≥1 参 ⇒ 安全
                    Unipal.solid(string.format("路①b: SCML_CPP_NewObject 参数个数=%s", tostring(n)))
                    if n ~= nil and n >= 1 then
                        -- ★ 实测签名: `SCML_CPP_NewObject(Outer:Object, Class:Class)` + 返回槽
                        --   （2026-10-07 我原来传成 `(Class, Outer)` ⇒ 报 "Tried storing reference…"）
                        --   v18: **多形态尝试** —— ① 只传 2 个输入；② 显式带上返回槽（nil）；③ 返回槽给 false。
                        --   ★ 注意: UE4SS 日志里有 `[SCML] SCML_WorldActor : Register Timeout,
                        --     Some C++ functions may not be available` 时 ⇒ **它的 C++ 侧没注册**
                        --     （见 docs: UniPalUI 的 dlls 目录装在了惰性 UE4SS 树里）⇒ 这时它本来就不可靠。
                        -- ★ 先记下**每个参数到底是什么**（type + tostring）——
                        --   报错说 "Tried storing reference to a **Lua table**"，那就得知道是哪个参数成了表。
                        local arg_desc = string.format("Outer=%s | Class=%s | Outer是表?=%s Class是表?=%s",
                            Unipal.sample_of(outer), Unipal.sample_of(mod_cls),
                            tostring(type(outer) == "table"), tostring(type(mod_cls) == "table"))
                        Unipal.solid("路①b 参数: " .. arg_desc)
                        -- ★★★ 2026-10-07 **决定性发现（完整报错给的）**:
                        --   `Tried storing reference to a Lua table for an 'Out' parameter when calling
                        --    a UFunction but no table was on the stack`
                        --   ⇒ **UE4SS 调用 BP 函数时，每个"输出参数"都要传一个 Lua 表来接收**（不是 nil）。
                        --   这也解释了三次崩溃: 输出槽给 nil ⇒ 引擎往空指针写 ⇒ `reading 0x70` ✓
                        local variants = {
                            { label = "Outer,Class,{}", call = function(out)
                                return m(scml_actor, outer, mod_cls, out) end },
                            { label = "Outer,Class,nil", call = function()
                                return m(scml_actor, outer, mod_cls, nil) end },
                        }
                        for vi = 1, #variants do
                            -- ★★★ 2026-10-07: **出参表要传进去、也要读回来** —— `.85` 实测
                            --   `(Outer, Class, {})` **不再报错**（另两个变体仍报 Out 参数错），
                            --   但 `pcall` 的返回值是 nil ⇒ **对象应该是被写进了那个表里** ✓
                            local out = {}
                            local ok, v, v2 = pcall(function() return variants[vi].call(out) end)
                            local got = Util.unwrap(v) or Util.unwrap(v2)
                            -- 从表里找对象（出参可能按序号或按名字填）
                            local from_tbl = nil
                            pcall(function()
                                from_tbl = Util.unwrap(out[1]) or Util.unwrap(out.NewObject)
                                    or Util.unwrap(out["NewObject"])
                            end)
                            local keys = {}
                            pcall(function()
                                for k, val in pairs(out) do
                                    keys[#keys + 1] = string.format("%s=%s", tostring(k),
                                        Unipal.sample_of(val))
                                end
                            end)
                            log[#log + 1] = string.format(
                                "⓪b SCML_CPP_NewObject(%s): %s 返回①=%s 出参表{%s}",
                                variants[vi].label,
                                (ok and (got ~= nil or from_tbl ~= nil)) and "**成功**"
                                    or ("失败(" .. tostring(v):sub(1, 120) .. ")"),
                                Unipal.sample_of(got), table.concat(keys, " , "))
                            local obj = got or from_tbl
                            if obj ~= nil then
                                callobj = obj
                                callobj_name = "SCML_CPP_NewObject(" .. variants[vi].label .. ")"
                                callobj_src = "scml"
                                Unipal.solid("路①b: SCML_CPP_NewObject 成功（" .. variants[vi].label
                                    .. "）出参表{" .. table.concat(keys, " , ") .. "}")
                                break
                            end
                            Unipal.solid("路①b: SCML_CPP_NewObject 失败（" .. variants[vi].label
                                .. "）出参表{" .. table.concat(keys, " , ") .. "} err="
                                .. tostring(v):sub(1, 300))
                        end
                    end
                else
                    log[#log + 1] = "⓪b SCML_CPP_NewObject: 在 SCML_WorldActor 上读不到（跳过）"
                end
            end
        else
            log[#log + 1] = string.format("⓪ 新建 CallObject: 失败（%s）",
                tostring(err1):sub(1, 120))
            Unipal.solid("路①: 新建失败 " .. tostring(err1):sub(1, 120))
        end
    end
    for i = 1, #objs do
        local nm = tostring(objs[i].name or "")
        -- ★ **不要覆盖"路① 造出来的对象"**（`.77` 的 bug: 新建成功之后又被这里覆盖成
        --   扫描到的那一个 = UniPalUI 自己的 mod 对象 ⇒ 拿它再去注册一次，崩了 ✗）
        if callobj == nil and nm:find("ModObject", 1, true) ~= nil then
            callobj, callobj_name = objs[i].obj, nm
            break
        end
    end
    local cfg_register = nil
    pcall(function() cfg_register = Config.get("unipal_try_register") end)
    if cfg_register ~= true then
        log[#log + 1] = "③ UPI_RegisterMod: **跳过**（配置 unipal_try_register=false —— "
            .. "实测过: CallObject 不对会崩游戏）"
    elseif found.UPI_RegisterMod == nil or tonumber(found.UPI_RegisterMod.arity) == nil then
        log[#log + 1] = "③ UPI_RegisterMod: 跳过（没在活实例上读到它）"
    elseif callobj == nil then
        log[#log + 1] = "③ UPI_RegisterMod: **跳过**（没有合格 CallObject —— 只有"
            .. "『ModObject 类』的实例才算；实测普通对象会让它空指针崩）"
    elseif callobj_src ~= "scml" and Config.get("unipal_allow_static_callobj") ~= true then
        -- ★★ 2026-10-07: 默认只允许"作者代理造出来的对象"（`SCML_CPP_NewObject`）去注册 ——
        --    因为实测直接 `StaticConstructObject` 生造的对象会让它崩。
        --    ★ 但**C++ 侧起来之后**（`[SCML] Register Timeout` 消失）值得再试一次:
        --    把 `unipal_allow_static_callobj` 设 true 就会用 static 对象注册（**可能崩**）。
        log[#log + 1] = "③ UPI_RegisterMod: **跳过**（CallObject 来自 StaticConstructObject；"
            .. "实测拿它注册会崩。想再试一次就设 unipal_allow_static_callobj=true）"
        Unipal.solid("阶段B: 跳过注册（static 构造的 CallObject；未开 allow_static_callobj）")
    else
        -- ★★ 2026-10-07 **延时闸门**: 注册这一步**必须等世界准备好**。
        --   证据: UniPalUI 是在 `PL_Splash`/`PL_Login`/`PL_Title` 里创建的，而探针启动后 2.5 秒就跑
        --   ⇒ 很可能在标题/加载界面就调 `UPI_RegisterMod` ⇒ 它的 UI/世界上下文还没初始化 ⇒ 崩。
        --   做法: 记录模块首次运行时间；没到 `unipal_register_delay_s` 就**排一个稍后自动重试**
        --   （只排一次），到点才真正注册。
        if Unipal.started_at == nil then Unipal.started_at = os.time() end
        local delay_s = tonumber(Config.get("unipal_register_delay_s")) or 60
        if delay_s < 0 then delay_s = 0 end
        local elapsed = os.time() - Unipal.started_at
        if elapsed < delay_s then
            local wait_s = delay_s - elapsed
            if Unipal.retry_scheduled ~= true then
                Unipal.retry_scheduled = true
                Unipal.solid(string.format("阶段B: 延时闸门 —— 还差 %d 秒，稍后自动重试注册", wait_s))
                pcall(function()
                    Sched.game_thread(function()
                        pcall(function() Unipal.try_call_notif("延时到点，重试注册") end)
                    end, wait_s * 1000)
                end)
            end
            log[#log + 1] = string.format("③ UPI_RegisterMod: **延后**（还差 %d 秒到延时"
                .. " unipal_register_delay_s=%d；已排自动重试）", wait_s, delay_s)
            return false, table.concat(log, " | ")
        end
        local f = found.UPI_RegisterMod
        -- ★★ 参数**只按配置模板构造**（`unipal_register_args`）—— 没写模板就**绝不调**。
        -- ★★★ 2026-10-07: **改用实测签名**（dump 得到的 `Unipal.SIG`）——
        --   `UPI_RegisterMod(callObject, ModName, ModCreator, RegisterMenu, EnterPage, Valid, ErrorOutput)`
        --   5 个输入 + **2 个输出槽（传 nil）** = 7 ⇒ 这才是"expected 7"的正解。
        --   （配置 `unipal_register_args` 仍可覆盖: 写了模板就按模板来。）
        local tmpl = nil
        pcall(function() tmpl = Config.get("unipal_register_args") end)
        local args, how = nil, nil
        if type(tmpl) == "string" and tmpl ~= "" then
            local kinds = {}
            for k in tmpl:gmatch("[^,%s]+") do kinds[#kinds + 1] = k end
            local function val_of(kind)
                if kind == "obj" then return callobj end
                if kind == "wctx" then return any_uobject end
                if kind == "name" then return "PWProjection" end
                if kind == "creator" then return "CitrusDR" end
                if kind == "menu" or kind == "page" then return "" end
                if kind == "true" then return true end
                if kind == "false" then return false end
                if kind == "nil" then return nil end
                return ""
            end
            args, how = {}, "模板 " .. tmpl
            for i = 1, #kinds do args[i] = val_of(kinds[i]) end
            args.n = #kinds
        else
            -- ★★★ 2026-10-07 修正: **两个输出参数各给一个 Lua 表**（实测报错要求的写法）
            --   `UPI_RegisterMod(callObject, ModName, ModCreator, RegisterMenu, EnterPage,
            --                    Valid:Out{}, ErrorOutput:Out{})` = 7 槽 ✓
            --   ★ `EnterPage` 给 **"None"** 而不是空串 —— 它的 changelog 提过
            --     "Callback and BoxID not accepting 'None' as a valid parameter"（说明 None 是合法名字）
            args = { callobj, "PWProjection", "CitrusDR", true, "None", {}, {} }
            args.n = 7
            how = "实测签名(5 输入 + 2 个出参表, EnterPage=None)"
        end
        Unipal.solid(string.format("阶段B: 调 UPI_RegisterMod（%s → %d 参, CallObject=%s）",
            tostring(how), args.n, tostring(callobj_name)))
        local ok, e1, e2 = pcall(function()
            return f.fn(f.obj, table.unpack(args, 1, args.n))
        end)
        log[#log + 1] = string.format("③ UPI_RegisterMod(%s, %d 参): %s 返回①=%s 返回②=%s %s",
            tostring(how), args.n, ok and "**OK**" or "FAIL", tostring(e1), tostring(e2),
            ok and "" or ("[" .. tostring(e2):sub(1, 250) .. "]"))
        -- ★ 出参表里的内容也报出来（★ 2026-10-07 实测: 输出是**按名字**放进表的 ——
        --   例 `SCML_CPP_NewObject` 给的是 `out.NewObject` ⇒ 这里也先按名字读、再退回序号读）
        pcall(function()
            local t6, t7 = args[6] or {}, args[7] or {}
            log[#log + 1] = string.format(
                "③b 出参表: Valid(名)=%s [1]=%s | ErrorOutput(名)=%s [1]=%s",
                tostring(t6.Valid), tostring(t6[1]),
                tostring(t7.ErrorOutput), tostring(t7[1]))
        end)
        -- ★ 注册调用没抛错就顺手**发一条通知**（`UPI_SendNotif(callObject, Message:Text, CallerName)`
        --   = 3 个参数、**没有未知参数**）⇒ 屏幕上出现通知 = **调用链真正通了** ✓
        if ok and found.UPI_SendNotif ~= nil then
            local sf = found.UPI_SendNotif
            Unipal.solid("阶段B: 调 UPI_SendNotif（3 参：callObject, Message, CallerName）")
            local ok2, v2 = pcall(function()
                return sf.fn(sf.obj, callobj, "PWProjection 接入成功！", "PWProjection")
            end)
            log[#log + 1] = string.format("④ UPI_SendNotif(3 参): %s%s",
                ok2 and "**OK** —— 看屏幕左上角有没有通知" or "FAIL",
                ok2 and "" or ("[" .. tostring(v2):sub(1, 120) .. "]"))
        end
    end

    return scml_called, table.concat(log, " | ")
end

-- 报告（给日志 / F7）
-- --------------------------------------------------------------------------

function Unipal.status_lines(limit)
    local out = {}
    local res = Unipal.result
    if res == nil then
        out[#out + 1] = "UniPalUI 探针: (还没跑)"
        return out
    end
    out[#out + 1] = string.format("UniPalUI 探针(阶段A): %s",
        res.detected and "**检测到**" or "没检测到")
    -- 活实例（**这是可靠的检测依据** —— `FindAllOf`）
    local inst = {}
    for i = 1, #Unipal.INSTANCE_CLASS_NAMES do
        local c = Unipal.INSTANCE_CLASS_NAMES[i]
        local n = res.instances[c] or 0
        if n > 0 then inst[#inst + 1] = string.format("%s×%d", c, n) end
    end
    out[#out + 1] = "  活实例: " .. ((#inst > 0) and table.concat(inst, " ") or "无")
    -- 枚举到的函数（靠 Children/Next 链 —— 拿 NumParms 的唯一可靠办法）
    local n_cls, n_fn = 0, 0
    for _, list in pairs(res.funcs or {}) do
        n_cls = n_cls + 1
        n_fn = n_fn + #list
    end
    out[#out + 1] = string.format("  函数枚举: %d 个类 / %d 个函数（Children 链）", n_cls, n_fn)
    -- 三种手段各自的命中数（下一份日志据此判断"哪种手段有效"）
    local st = res.strategy or {}
    out[#out + 1] = string.format("  手段命中: StaticFindObject=%d · 活实例成员=%d · Children链=%d",
        tonumber(st.static_find) or 0, tonumber(st.member) or 0, tonumber(st.children) or 0)
    -- API 命中（只报**枚举到**的，不再拿 StaticFindObject 的结果充数）
    local api_list = {}
    for i = 1, #Unipal.API_NAMES do
        local name = Unipal.API_NAMES[i]
        local e = res.api[name]
        if e ~= nil and e.found then
            api_list[#api_list + 1] = string.format("%s(%s)", name,
                (e.num_parms ~= nil) and tostring(e.num_parms) or "?")
        end
    end
    out[#out + 1] = string.format("  API: %d/%d 枚举到 %s", #api_list, #Unipal.API_NAMES,
        (#api_list > 0) and ("→ " .. table.concat(api_list, " ")) or "")
    -- ★ v4: Lua 全局里像 UniPalUI/SCML 的名字（**它的 DLL 很可能就是往 Lua 注册 API 的**）
    if type(res.lua_globals) == "table" and #res.lua_globals > 0 then
        out[#out + 1] = string.format("  Lua 全局(UniPalUI/SCML): %d 个 → %s",
            #res.lua_globals, table.concat(res.lua_globals, " "))
    end
    for i = 1, math.min(#res.notes, limit or 4) do
        out[#out + 1] = "  " .. res.notes[i]
    end
    return out
end

--- 一行摘要（给别的模块引用）
function Unipal.status_line()
    local res = Unipal.result
    if res == nil then return "UniPalUI: 探针未跑" end
    return res.detected and "UniPalUI: 检测到（详见 F7/[unipal] 行）"
        or "UniPalUI: 没检测到"
end

return Unipal
