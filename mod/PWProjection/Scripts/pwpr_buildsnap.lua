--[[ ===========================================================================
  PWPR · buildsnap  ——  ★ 建造吸附 / 蓝图建造模式
                        手拿建筑放下时，把它落到投影对应的那一件上

  ============================================================================
  两种模式（配置 buildsnap_mode 选一个）
  ============================================================================
  ① `align`（默认）—— **吸附**: 你自己在建造菜单里选好那一块、对着投影摆过去，
     放下时如果它与投影里**同类型**的某一件对得上（距离/朝向在阈值内），
     就把它落到那一件的精确位置与朝向上。
  ② `blueprint` —— **蓝图建造**: 你手里拿什么都无所谓，**准星指向投影里的哪一件
     就建哪一件**（类型也跟着投影走）。像"照着投影点一下就盖好"。

  两种模式**共用**同一条链路（见下），只是"目标记录怎么选"不同。

  ============================================================================
  原理（接口事实来自只读参考 SBB，未复用其代码）
  ============================================================================
  游戏放一块建筑的链路:
      建造菜单/预览  ->  PalNetworkPlayerComponent:RequestBuild_ToServer(
                            buildObjectId(FName), location(FVector),
                            rotation(FQuat), extraParams, debugParam )
  ⇒ 挂这个函数的 **pre-hook**（执行之前触发），就能拿到"这次放置的坐标与类型"。

  ★★ 我们**只改这一件事**: 把这次请求的目标换成投影里那一件。
     具体三步（全部只用**在同一环境里已被验证过**的原语）:
       1. 解开参数包装读出来（`RemoteUnrealParam`/`LocalUnrealParam` 必须先 unwrap）；
       2. 用 `idParam:set(FName("None"))` **拦住原请求**，并**回读确认**拦住了；
       3. 用吸附后的坐标**自己再发一次**请求（普通 Lua 表 + `FName(...)`）。
     拦不住就不发 ⇒ **宁可没吸上，也绝不重复放一块**。

  ★ 为什么不是"就地改写 location/rotation":
     2026-09-29 实测（玩家日志）`location`/`rotation` 是 `LocalUnrealParam`，
     结构体参数的**写法在本机没验证过**（参考实现里只改过 FName 参数）。
     而"拦原请求 + 自己重发"这条路用的都是已验证的原语，风险更低、也更好排查。

  ============================================================================
  安全规矩（这个功能动的是"游戏自己的放置"，比投影渲染更需要克制）
  ============================================================================
  1. **任何异常都只记日志、绝不阻断放置** —— 整个回调 + 每次引擎调用都 pcall；
  2. **每一步都回读校验**（读参数、拦请求），读不回来就当没成功；
  3. 对不上、超阈值、朝向差太多 ⇒ **原样放行**（宁可没吸上，也不能放错地方）；
  4. `buildsnap_dry_run = true` 时只写日志、一个字节都不改；
  5. 只在"投影正显示着、且加载了蓝图"时才工作；
  6. 钩子只注册一次（F8 重载配置不重复注册）。

  ============================================================================
  排查怎么看日志（每次放置都会留痕，前 40 次打全）
  ============================================================================
    [bsnap] 请求 #12: id=Wood_Foundation 位置=(...) 朝向=90.0 度 ...
    [bsnap] 匹配: 记录类型=Wood_Foundation 距离=34.2 厘米（阈值 300）
    [bsnap] 结果: 已改发到投影位置 / 未改写(原因) / 拦住失败(原样放行)
=========================================================================== ]]

local Util = require("pwpr_util")
local Log = require("pwpr_log")

local BuildSnap = {}

-- --------------------------------------------------------------------------
-- 常量 / 状态
-- --------------------------------------------------------------------------

--- 游戏的"客户端请求放置" RPC。参数里带着最终放置坐标与类型。
BuildSnap.HOOK_PATH =
    "/Script/Pal.PalNetworkPlayerComponent:RequestBuild_ToServer"

BuildSnap.installed = false
BuildSnap.fired = 0        -- 回调被调用次数（= 钩子到底生效没有）
BuildSnap.applied = 0      -- 真的改发了请求
BuildSnap.would_apply = 0  -- 干跑模式下"本来会改发"的次数
BuildSnap.skipped = 0      -- 看过了但没动（原因见日志）
BuildSnap.block_fail = 0   -- 想拦原请求但没拦住（原样放行）
BuildSnap.requeue_fail = 0 -- 拦住了、但自己重发失败（这一次等于没放上）
BuildSnap.last = nil       -- 最近一次的结果（F7 显示用）
BuildSnap.busy = false     -- 重入闸（我们自己重发的请求会再次进回调）
BuildSnap.ids_seen = {}    -- 见过的 build id（诊断: id 与蓝图类型对不对得上）
BuildSnap.trace_left = 40  -- 前 N 次请求打全（第一次实测要看细节）

--- 依赖（由 main.lua 注入，避免模块之间互相 require 成环）
BuildSnap.deps = {
    get = nil,          -- function(key) -> 配置值
    context = nil,      -- function() -> bp, place（投影没显示时返回 nil）
    player_aim = nil,   -- function() -> px,py,pz, dirx,diry,dirz（蓝图模式用）
    notify = nil,       -- function(cn, en)
}

-- --------------------------------------------------------------------------
-- 小工具: 字符串归一化 / 数学
-- --------------------------------------------------------------------------

--- 把建筑 id 归一化，好和蓝图里的类型名比对。
---
--- 为什么需要: 游戏给的 id 可能是 `Wood_Foundation`，也可能带前缀后缀
--- （`BP_BuildObject_Wood_Foundation_C` / `BuildObject_Wood_Foundation`），
--- 而蓝图里存的是我们采集时从类名剥出来的短名（`Wood_Foundation`）。
--- 两边都归一化再比，就能覆盖这些写法差异。
---
--- ★★★ 顺序很重要（2026-09-29 被 tools/buildsnap_sim.py 当场抓出来的 bug）:
---   "先 lower 再去前缀"会让 `bp_buildobject_x` 里的下划线挡住前缀匹配
---   ⇒ 结果永远对不上、功能一次都不生效。正确顺序见下。
--- 归一化（★ 实现已统一到 `Util.norm_id` —— 投影侧"已放上的不渲染"
--- 也用同一套规则，两边必须完全一致，否则会出现"吸附认为同类、
--- 隐藏认为不同类"的自相矛盾行为。这里保留一个薄壳给离线自检用。）
function BuildSnap.norm_id(s)
    return Util.norm_id(s)
end

--- 四元数 -> 偏航角（度）。UE 的 FQuat 是 (X,Y,Z,W)，只取绕 Z 的分量。
function BuildSnap.quat_to_yaw(x, y, z, w)
    if x == nil or y == nil or z == nil or w == nil then return nil end
    local siny = 2.0 * (w * z + x * y)
    local cosy = 1.0 - 2.0 * (y * y + z * z)
    return Util.norm_yaw(math.deg(math.atan(siny, cosy)))
end

--- 偏航角（度）-> 四元数分量 z,w（纯 yaw 时 x=y=0）
function BuildSnap.yaw_to_quat(z_w, yaw_deg)
    local h = math.rad(yaw_deg or 0.0) * 0.5
    z_w[1] = math.sin(h)
    z_w[2] = math.cos(h)
    return z_w
end

-- --------------------------------------------------------------------------
-- 读 / 写 hook 参数
--
-- ★★★ 2026-09-29 玩家实测日志给出的硬事实:
--     `id形式=userdata RemoteUnrealParam: 0x...`
--     `参数形式=userdata LocalUnrealParam: 0x...`（location / rotation）
--   这两种都是**包装对象**，直接读 `.X` **读不到**（返回 nil）⇒
--   必须先 `:get()` 解开（UE4SS 的 unwrap 就是干这个的）。
--   同一天里"直接读字段"的写法让功能**一次都没生效**，而日志只说"读不到"。
-- --------------------------------------------------------------------------

--- 解开一个参数包装对象。返回 解开后的值, 是否解开过
local function unwrap_param(p)
    if p == nil then return nil, false end
    local ok, v = pcall(function() return p:get() end)
    if ok and v ~= nil then return v, true end
    return p, false
end

--- 取一个字段（大写优先，兼容小写）。
--- ★ 参数名不要叫 `lower`（会和 `s:lower()` 那种方法名的检查撞上）。
local function field(p, upper, lower_key)
    local ok, v = pcall(function() return p[upper] end)
    if ok and type(v) == "number" then return v end
    if lower_key ~= nil then
        local ok2, v2 = pcall(function() return p[lower_key] end)
        if ok2 and type(v2) == "number" then return v2 end
    end
    return nil
end

--- 读 3 个分量。返回 x,y,z（读不到返回 nil）
--- ★ 先试解开后的对象，再试包装对象本身（不同 UE4SS 版本代理方式不同）
function BuildSnap.read_vec3(p)
    if p == nil then return nil end
    local v = unwrap_param(p)
    local x, y, z = field(v, "X", "x"), field(v, "Y", "y"), field(v, "Z", "z")
    if x == nil or y == nil or z == nil then
        x, y, z = field(p, "X", "x"), field(p, "Y", "y"), field(p, "Z", "z")
    end
    if x == nil or y == nil or z == nil then return nil end
    return x, y, z
end

--- 读四元数。返回 x,y,z,w
function BuildSnap.read_quat(p)
    if p == nil then return nil end
    local v = unwrap_param(p)
    local x, y, z, w = field(v, "X", "x"), field(v, "Y", "y"),
        field(v, "Z", "z"), field(v, "W", "w")
    if x == nil or y == nil or z == nil or w == nil then
        x, y, z, w = field(p, "X", "x"), field(p, "Y", "y"),
            field(p, "Z", "z"), field(p, "W", "w")
    end
    if x == nil or y == nil or z == nil or w == nil then return nil end
    return x, y, z, w
end

--- 读一个 FName / 字符串参数的**字符串形式**。
--- 依次试: 解开后 ToString → 包装对象 ToString → tostring 兜底
function BuildSnap.read_name_string(p)
    if p == nil then return nil end
    local v = unwrap_param(p)
    local candidates = { v, p }
    for i = 1, #candidates do
        local c = candidates[i]
        if c ~= nil then
            local ok, s = pcall(function() return c:ToString() end)
            if ok and type(s) == "string" and s ~= "" then return s end
            local ok2, s2 = pcall(function() return c:GetName() end)
            if ok2 and type(s2) == "string" and s2 ~= "" then return s2 end
            if type(c) == "string" then return c end
        end
    end
    local ok3, s3 = pcall(function() return tostring(p) end)
    if ok3 and type(s3) == "string" and s3:find("UnrealParam") == nil then
        return s3
    end
    return nil
end

--- 参数长什么样（只用于日志）
function BuildSnap.describe_param(p)
    if p == nil then return "nil" end
    local out = { type(p) }
    local ok, s = pcall(function() return tostring(p) end)
    if ok and type(s) == "string" and #s <= 48 then out[#out + 1] = s end
    local v, unwrapped = unwrap_param(p)
    if unwrapped then
        local ok2, s2 = pcall(function() return tostring(v) end)
        out[#out + 1] = "解开=" .. ((ok2 and type(s2) == "string") and s2 or "?")
    end
    return table.concat(out, " ")
end

--- ★★ 第 4 个参数（`extra_parameter_archives` / 附加参数）到底是空的还是有内容？
---
--- ⚠️⚠️ 2026-09-29 实测教训（**这一条我判断错过一次，代价是"吸附全废"**）:
---   原来用 `tostring(v)` 当判据 ⇒ 而**普通手放的请求里这个参数也永远存在**
---   （一个 `TArray` 对象，`tostring` 出来是 `TArray: 00000250B71EAD98` 这种地址）
---   ⇒ 每一次放置都被判成"带了附加参数" ⇒ 全部**原样放行** ⇒ 玩家实测:
---   「第一块吸附放置之后，后面的怎么都吸附不上了」。
---   ⇒ 现在: **必须真的读出"元素个数 > 0"才算有内容**；读不出来一律当"空"（不拦）。
---     读法依次试 `#v` / `v:Num()` / `v:GetArrayNum()` / `v:Length()`（都是 pcall）。
---
--- 返回: true = 空/读不出（**不拦**）, false = **确实有元素**, nil = 保留（不再用于拦截）
function BuildSnap.extra_state(p)
    if p == nil then return true, "nil" end
    local v, unwrapped = unwrap_param(p)
    if not unwrapped or v == nil then return true, "读不出内容（当空处理，不拦）" end
    if type(v) == "table" then
        local n = 0
        for _ in pairs(v) do n = n + 1 end
        if n == 0 then return true, "空表" end
        return false, string.format("表里有 %d 项", n)
    end
    -- ★ 先试"长度类"接口（TArray / 容器）；任何一个能读出数字就以它为准
    local n = nil
    pcall(function() local x = #v; if type(x) == "number" then n = x end end)
    for _, m in ipairs({ "Num", "GetArrayNum", "Length", "GetNum" }) do
        if n == nil then
            pcall(function()
                if v[m] ~= nil then
                    local x = v[m](v)          -- 同时兼容 方法调用 与 属性函数
                    if type(x) == "number" then n = x end
                end
            end)
            if n == nil then
                pcall(function()
                    if v[m] ~= nil then
                        local x = v[m]
                        if type(x) == "number" then n = x end
                    end
                end)
            end
        end
    end
    if type(n) == "number" then
        if n <= 0 then return true, string.format("空（%d 项）", n) end
        return false, string.format("有 %d 项", n)
    end
    -- 读不出个数 ⇒ **不拦**（宁可吸错一点，也不能把整个吸附静默关掉）
    return true, "读不出个数（当空处理，不拦）"
end

--- ★ 拦住原请求: 把 buildObjectId 设成 "None"（参考实现用过的写法），并回读确认。
--- 返回 ok, 回读到的值
function BuildSnap.block_request(id_param)
    if id_param == nil then return false, "参数是 nil" end
    local name_none = nil
    local okf, ferr = pcall(function() name_none = FName("None") end)
    if not okf or name_none == nil then
        return false, "FName 不可用: " .. tostring(ferr)
    end
    local okset, serr = pcall(function() id_param:set(name_none) end)
    local readback = BuildSnap.read_name_string(id_param)
    if not okset then
        return false, string.format("set 抛错(%s) 回读=%s",
            tostring(serr), tostring(readback))
    end
    if tostring(readback) ~= "None" then
        return false, "回读不是 None（实际 " .. tostring(readback) .. "）"
    end
    return true, tostring(readback)
end

-- --------------------------------------------------------------------------
-- 找目标记录 ①: 吸附模式 —— 离"这次请求的坐标"最近的**同类型**记录
--
-- ★★★ 2026-09-29 第二次实测的硬事实（玩家日志）:
--     游戏给的 id 是 **`Wooden_foundation`**，而蓝图里的类型是 **`Wood_Foundation`**
--     —— 只差一个 "en"！于是"同类型"永远匹配不上，
--     但**最近的那一件只有 7~21 厘米远**（说明投影和游戏的网格其实对得很准）。
--   ⇒ 对策两条（都在这一版里）:
--     ① **学到映射**: 当"没有同类型记录、但最近的任意类型记录贴得很近"时，
--        就把 这个 id ↔ 那个类型 记下来（`BuildSnap.learned`），下次直接用；
--     ② **放宽阈值**: `buildsnap_type_loose_cm`（默认 100 厘米）——
--        没有同类型记录时，允许吸到最近的任意类型记录（只要它近到这个程度）。
-- --------------------------------------------------------------------------

--- 已学到的 "游戏 id 归一化 → 蓝图类型归一化" 映射（运行时，不落盘）
BuildSnap.learned = {}

--- ★ 反向映射: 蓝图类型归一化 → **游戏的原始 id 字符串**（蓝图模式要用它）。
---
--- 为什么必须有（2026-09-29 第四次实测的根因）:
---   蓝图里的类型是从**类名**剥出来的（`BP_BuildObject_Wood_Foundation_C` → `Wood_Foundation`），
---   而游戏真正认的 id 是 **`Wooden_foundation`** —— 两者不是一回事！
---   `blueprint` 模式原来直接拿 `res.rec.t` 去 `FName(...)` 建，
---   等于发了一个**游戏不认识的建筑 id** ⇒ 服务端查不到 ⇒ 拒绝
---   （玩家看到的 `zh-hans text` 就是那条"未知 id"的错误提示缺翻译）。
---   ⇒ 只有**学到过**的类型（在 align 模式下正常盖过一次）才拿得到游戏 id；
---     学不到就**不吸**，并明确告诉玩家"先用 align 盖一件同类的"。
BuildSnap.learned_id = {}

-- --------------------------------------------------------------------------
-- ★★ 降级阶梯 / 卡死记忆（2026-09-29，玩家定稿: 「先试一次，吸附不上再换成不吸 z 轴」）
--
-- 为什么需要"记得住":
--   玩家明确要"高度也跟投影"（地面建时高度不固定，必须吸）—— 那就不能一刀切把
--   高度关掉。但水面那次实测证明"改了高度再重发"有可能让游戏**整局卡死**
--   （`.52` 黑匣子铁证，见 `docs\踩坑记录.md` §68）。⇒ 做法是**逐级退让**:
--
--   ① `BuildSnap.z_denied[id@处]` —— **这一处投影**上"改了高度"的那次放置被游戏**拒了**
--      （1.2 秒内没有新建筑出现）⇒ 这一处同类 id **只吸 x/y**。玩家马上再放一次即可。
--      ★ `.111` 起键里带"处"（蓝图 + 锚点）⇒ **换一处 / 换一张蓝图会自动恢复**，
--        不再是"整局一次"（那个"整局一次"正是 `.110` 实测的 bug，见下面表的说明）。
--   ② `BuildSnap.frozen[id]` —— 上一次会话**卡死**在某类 id 的重发里:
--      · 1 = 那次**改了高度** ⇒ 之后这类只吸 x/y（原样放行高度）；
--      · 2 = 那次**已经没改高度**还是卡 ⇒ 之后这类**完全不插手**（绝不重发）。
--      卡死现场写不了任何东西，但黑匣子在**卡死之前**已同步落盘 ⇒ 下次启动读
--      日志尾部就能学出来（有「● 重发前」登记、没有「● 重发返回」）。
--   ③ 重置这份记忆: **删掉/移走 `pwpr.log`**（记忆就存在它里面，不额外建文件）。
-- --------------------------------------------------------------------------
BuildSnap.frozen = {}        -- [归一化 id] = 1 / 2，见上
-- ★★★ 2026-10-09（`.111`）: 下面这几份"降级/高度"记忆的键从**归一化 id** 改成
--   **归一化 id + "这一处投影"**（`BuildSnap.z_key()`，键形如 `glass_foundation|蓝图@x,y`）。
--
-- 起因（玩家实测 `.110`，日志见 `docs\踩坑记录.md` §74）:
--   ① 在 A 处给 `Glass_Foundation` 挪过一次投影高度（`z_shifted[id]` 置 true）；
--   ② 换到 B 处 / 换一张蓝图，**第一次**放置又被拒（投影比游戏允许的高度低 59 厘米）
--      ⇒ 旧代码只看 id 的记忆 ⇒ 直接落到"这类只吸 x/y"那一级，**投影再也不跟着挪**
--      ⇒ 地基上的建筑全都放不下去（玩家原话:「**投影不会移动**」✗）。
--   ⇒ 现在**换一处 = 新情况**（新键）⇒ 会重新走一次"把投影高度挪到游戏允许的位置"；
--     而**同一处**里挪过还是被拒 ⇒ 照旧降级（防"反复挪"把整份投影挪飞）。
BuildSnap.z_denied = {}      -- [z_key] = true: 这一处这一类"只吸 x/y"，见上
BuildSnap.z_shifted = {}     -- [z_key] = true: 这一处已经为它"自动调过投影高度"
BuildSnap.z_learned = {}     -- [z_key] = true: 这一处已经为它"按游戏实际高度校准过"

--- ★★★ 2026-10-09（`.111`）新增: 降级 / 高度记忆的**键** = 归一化 id + "这一处投影"。
---   "处" = `deps.site_key()`（main.lua 给: **蓝图文件 + 投影锚点 x/y**）。
---   取不到就退回"只有 id"（= 旧行为: 整局一份）—— 退化了也不会报错/不放行错。
function BuildSnap.z_key(idn)
    local site = ""
    if BuildSnap.deps.site_key ~= nil then
        local ok, s = pcall(BuildSnap.deps.site_key)
        if ok and type(s) == "string" and s ~= "" then site = s end
    end
    return tostring(idn or "") .. "|" .. site
end

--- [归一化 id] = dz（**游戏允许的高度 − 投影记录的高度**）
---   —— 卡死那一局的日志里两个数都在，所以能算出来；下次一按放置就先把投影挪过去。
BuildSnap.pending_z_shift = {}
--- ★★★ **危险区域**（2026-09-29 第二次崩溃之后加的）:
---   `{ {x=,y=,z=,r=}, … }` —— 出过"卡死/崩溃"的那一片。
--- 为什么需要（实测教训）: 第一次给 `Glass_foundation` 拉黑之后，**换一个类型
---   `SF_foundation` 在同一片水面又崩了一次** ⇒ 说明**出问题的不是某一种建筑，
---   而是"在这一片改坐标重发"这件事**（游戏自己的原样放置完全没事）。
---   ⇒ 出过事的位置**整片拉黑**（半径 `ZONE_R_CM`），这一片以后一律原样放行。
BuildSnap.bad_zones = {}
BuildSnap.ZONE_R_CM = 2500.0     -- 25 米（一张蓝图的一角 ~ 一个基地的范围）

--- 请求位置是不是落在"出过事的区域"里（只比水平距离）
--- 半径: 优先用配置 `buildsnap_zone_m`（米）；没配就用记忆里存的那个（默认 25 米）。
function BuildSnap.in_bad_zone(x, y)
    if type(x) ~= "number" or type(y) ~= "number" then return nil end
    local cfgm = 0.0
    if BuildSnap.deps.get ~= nil then
        pcall(function() cfgm = tonumber(BuildSnap.deps.get("buildsnap_zone_m")) or 0.0 end)
    end
    for i = 1, #BuildSnap.bad_zones do
        local z = BuildSnap.bad_zones[i]
        local r = (cfgm > 0.0) and (cfgm * 100.0) or (z.r or BuildSnap.ZONE_R_CM)
        local dx, dy = x - z.x, y - z.y
        if math.sqrt(dx * dx + dy * dy) <= r then
            return z
        end
    end
    return nil
end

--- 从一个小括号坐标串 `"x,y,z"` 里取第 3 个数（高度）。取不到返回 nil。
local function third_of_vec(s)
    if type(s) ~= "string" then return nil end
    local vals = {}
    for num in s:gmatch("(-?%d+%.?%d*)") do vals[#vals + 1] = tonumber(num) end
    if #vals >= 3 then return vals[3] end
    return nil
end
BuildSnap.third_of_vec = third_of_vec

--- 同上，但返回三个数（x, y, z）。取不到返回 nil。
local function vec_of(s)
    if type(s) ~= "string" then return nil end
    local vals = {}
    for num in s:gmatch("(-?%d+%.?%d*)") do vals[#vals + 1] = tonumber(num) end
    if #vals >= 3 then return vals[1], vals[2], vals[3] end
    return nil
end
BuildSnap.vec_of = vec_of

--- 从日志尾部学"上一次会话卡死在哪一类建筑的重发上"，并**顺手把"高度该挪多少"算出来**。
---
--- 记忆怎么"跨会话留住"（2026-09-29 改进）:
---   ① 卡死现场: 黑匣子 `● 重发前`（登记）没有配对的 `● 重发返回`（销账）
---      ⇒ 读日志尾部就学到了；
---   ② **学到之后立刻写一行 `● 记忆 frozen …` 回日志**，而且以后每次启动都
---      **重新登记**这行 ⇒ 它永远待在尾部窗口里，不会被后来的正常日志挤出去
---      （原来只靠窗口，玩家多玩一会就把记录挤没了 —— 我自己用真日志验证时发现的）；
---   ③ 高度偏差被应用之后写 `● 记忆 cleared id=…` ⇒ 下次启动不会重复挪。
---   重置: **删掉/移走 `pwpr.log`**（记忆就在它里面）。
function BuildSnap.learn_frozen_from_log()
    if BuildSnap.frozen_learned == true then return BuildSnap.frozen end
    BuildSnap.frozen_learned = true
    local U, Lg = nil, nil
    pcall(function() U = require("pwpr_util") end)
    pcall(function() Lg = require("pwpr_log") end)
    if U == nil or Lg == nil or U.read_tail == nil or Lg.path_of == nil then
        return BuildSnap.frozen
    end
    local text = nil
    -- ★ 512 KB: 要能盖住"卡死之后又玩了一局"的量（64 KB 会被挤掉）
    pcall(function() text = U.read_tail(Lg.path_of(nil), 524288) end)
    if type(text) ~= "string" or text == "" then return BuildSnap.frozen end
    local function norm_of(id) return BuildSnap.norm_id(id) end

    -- 顺序扫描:
    --   · `● 记忆 frozen …` / `● 记忆 cleared …` —— 跨会话的正式记忆（见上面的说明）
    --   · `● 重发前 …`（登记） / `● 重发返回 …`（销账） —— 卡死现场
    --   · ★ 兼容**旧格式**: `.52/.53` 早期写的是 `● 重发前: 即将调用 …`（没有 id=）
    --     ⇒ 用**前面最近那条「● 请求 #N id=…」**兜底拿 id，坐标也从那一行里取。
    local armed, last_id, last_gz, learned = nil, nil, nil, false
    local seen_cleared = {}     -- [归一化 id] = true: 日志里出现过"已为它挪过高度"
    for line in text:gmatch("[^\r\n]+") do
        local mid, mstage, mdz = line:match("● 记忆 frozen id=(%S+) stage=(%d+) dz=(%S+)")
        if mid ~= nil then
            local n = norm_of(mid)
            if type(n) == "string" and n ~= "" then
                BuildSnap.frozen[n] = tonumber(mstage) or 1
                local z = tonumber(mdz)
                if z ~= nil then BuildSnap.pending_z_shift[n] = z end
            end
        elseif line:find("● 记忆 cleared id=", 1, true) ~= nil then
            local cid = line:match("● 记忆 cleared id=(%S+)")
            local n = norm_of(cid)
            if type(n) == "string" and n ~= "" then
                BuildSnap.frozen[n] = nil
                BuildSnap.pending_z_shift[n] = nil
                seen_cleared[n] = true
            end
        end
        -- ★ 危险区域（整片拉黑）—— 也是"每次启动重新登记"的正式记忆
        local zx, zy, zz, zr = line:match(
            "● 记忆 zone x=(%-?[%d%.]+) y=(%-?[%d%.]+) z=(%-?[%d%.]+) r=(%-?[%d%.]+)")
        if zx ~= nil then
            BuildSnap.bad_zones[#BuildSnap.bad_zones + 1] = {
                x = tonumber(zx), y = tonumber(zy), z = tonumber(zz),
                r = tonumber(zr) or BuildSnap.ZONE_R_CM }
        end
        local rid, gvec = line:match("● 请求 #%d+ id=(%S+) 位置=%(([^%)]*)%)")
        if rid ~= nil and rid ~= "" and rid ~= "?" then
            last_id = rid
            last_gz = third_of_vec(gvec)
        end
        local id, dz, tvec = line:match("● 重发前 id=(%S+) 改高度=(%S+) 目标=%(([^%)]*)%)")
        local ax, ay, az = nil, nil, nil
        if id ~= nil and id ~= "" and id ~= "?" then
            ax, ay, az = vec_of(tvec)
            armed = { id = id, z = dz, gz = last_gz, tx = ax, ty = ay, tz = az }
        elseif line:find("● 重发前", 1, true) ~= nil then
            if last_id ~= nil then
                -- 旧格式: 坐标仍在行里（`… → (x,y,z) …`）⇒ 取第一个括号坐标当目标
                local tvec2 = line:match("%(([^%)]*)%)")
                ax, ay, az = vec_of(tvec2)
                armed = { id = last_id, z = "?", guessed = true, gz = last_gz,
                          tx = ax, ty = ay, tz = az }
            end
        elseif line:find("● 重发返回", 1, true) ~= nil then
            armed = nil
        end
    end
    if armed == nil then return BuildSnap.frozen end
    local norm = norm_of(armed.id)
    if type(norm) ~= "string" or norm == "" then return BuildSnap.frozen end
    -- 高度差: 游戏允许的高度 − 我们（按投影）发过去的高度
    local dz = nil
    if type(armed.gz) == "number" and type(armed.tz) == "number" then
        dz = armed.gz - armed.tz
    end
    local usable = (dz ~= nil) and (math.abs(dz) >= 5.0) and (math.abs(dz) <= 500.0)
    local has_coords = (type(armed.tx) == "number" and type(armed.ty) == "number")
    if armed.z == "否" then
        BuildSnap.frozen[norm] = 2                    -- 没改高度还是卡 ⇒ 完全不插手
    elseif seen_cleared[norm] == true then
        -- ★★ 2026-09-29 **崩溃之后加的**: 上一局已经为它"挪过投影高度"了，结果**还是**
        --   出了事（又一次卡死，或者**直接崩了** —— 崩溃栈上 UE4SS 帧反复重复
        --   = 在我们那次嵌套重发里崩的）⇒ 说明**重发这个请求本身**要命 ⇒ 完全不插手。
        BuildSnap.frozen[norm] = 2
    elseif has_coords then
        -- ★★★ 2026-09-29 **第二次崩溃之后加的**: 出事的位置能定位 ⇒ **整片拉黑**
        --   （见下面的 zone）。实测: 给 `Glass_foundation` 拉黑之后，换 `SF_foundation`
        --   在**同一片水面**又崩 ⇒ 问题在"这一片改坐标重发"，不在某一种建筑上。
        --   ⇒ 这一类也直接完全不插手（不必再拿它试高度）。
        BuildSnap.frozen[norm] = 2
    elseif usable then
        -- 定位不了（日志里没有坐标）、但知道高度差 ⇒ 唯一还值得一试的路: 先挪投影高度
        BuildSnap.frozen[norm] = 1
        BuildSnap.pending_z_shift[norm] = dz
    else
        -- 也算不出高度差 ⇒ **不冒险重发**（宁可这一整类不吸附，也不能再崩一次）
        BuildSnap.frozen[norm] = 2
    end
    learned = true

    if Lg.emit ~= nil then
        local how = "**完全不插手**（原样放行）"
        if BuildSnap.frozen[norm] == 1 then
            how = string.format("先把**投影高度挪 %+.0f 厘米**（下次按放置时自动做），之后照常吸高度", dz)
        elseif has_coords then
            how = "**完全不插手**，并且把出事那一片**整片拉黑**（这一片以后都不重发）"
        end
        Lg.emit(string.format(
            "  [bsnap] ★ 卡死记忆: 上一次会话在「重发 %s」（改高度=%s%s）时出事 ⇒ 这一类建筑%s"
            .. "（重置办法: 删掉/移走 pwpr.log）",
            tostring(armed.id), tostring(armed.z),
            armed.guessed and "，按旧格式从『请求』行推断" or "", how))
    end
    -- ★★ 把记忆**写回日志**（并且以后每次启动都会重新登记一遍）⇒ 不会被后来的日志挤出窗口
    if learned and Log ~= nil and Log.solid ~= nil then
        pcall(Log.solid, string.format("  [bsnap] ● 记忆 frozen id=%s stage=%d dz=%s",
            tostring(armed.id), BuildSnap.frozen[norm],
            (BuildSnap.pending_z_shift[norm] ~= nil)
                and string.format("%.1f", BuildSnap.pending_z_shift[norm]) or "none"))
    end
    -- ★★ 危险区域（整片拉黑）: 拿"出事那一次的目标坐标"当圆心，半径 25 米
    --   （玩家第二次崩溃实测: 换个类型在同一片水面又崩 ⇒ 问题在"这一片"）
    if learned and type(armed.tx) == "number" and type(armed.ty) == "number" then
        if BuildSnap.in_bad_zone(armed.tx, armed.ty) == nil then
            BuildSnap.bad_zones[#BuildSnap.bad_zones + 1] = {
                x = armed.tx, y = armed.ty, z = armed.tz, r = BuildSnap.ZONE_R_CM }
            if Log ~= nil and Log.solid ~= nil then
                pcall(Log.solid, string.format(
                    "  [bsnap] ● 记忆 zone x=%.0f y=%.0f z=%.0f r=%.0f",
                    armed.tx, armed.ty, armed.tz or 0.0, BuildSnap.ZONE_R_CM))
                pcall(Log.solid, string.format(
                    "  [bsnap] ★ 危险区域: 上一次会话在这一片（%.0f,%.0f 半径 %.0f 米）"
                    .. "重发时崩/卡过 ⇒ 这一片以后**一律不重发**（游戏原样放）",
                    armed.tx, armed.ty, BuildSnap.ZONE_R_CM / 100.0))
            end
        end
    end
    return BuildSnap.frozen
end

--- 返回 { best=候选, near=候选 }。两个候选都是 { rec=, x=, y=, z=, dist=, yaw= } 或 nil
---   best = 类型命中（含学到的映射）里最近的一件
---   near = **任意类型**里最近的一件（用于放宽阈值 + 日志）
--- want_keys: 归一化后的可接受类型集合（数组）；nil/空 = 不按类型过滤
function BuildSnap.find_target(bp, place, wx, wy, wz, want_keys, type_match,
                                     want_id_norm)
    if type(bp) ~= "table" or type(bp.buildings) ~= "table" then return nil end
    local yaw = place.yaw or 0.0
    local rad = math.rad(yaw)
    local c, s = math.cos(rad), math.sin(rad)
    local accept = {}
    if type(want_keys) == "table" then
        for i = 1, #want_keys do
            local k = want_keys[i]
            if type(k) == "string" and k ~= "" then accept[k] = true end
        end
    end

    -- ★★★ 2026-09-29 玩家实测抓到的"再也不吸"事故:
    --   某次"地板"在极近处配到了一条**灶台**记录 ⇒ 学到映射
    --   `Wooden_foundation → AncientCookingStove` ⇒ 之后每次放地板都去找灶台
    --   （7~18 米外）⇒ 被"修正量上限"拦掉 ⇒ **第一次之后再也不吸** ✗
    --   ⇒ 两条对策:
    --     ① 学到的映射**要能自愈**（见调用方: 被上限拦掉时就丢掉它）；
    --     ② 再加一层**名字相似**配对: 蓝图里是 `Wood_Foundation`、游戏里是
    --        `Wooden_foundation`（同一个东西、拼写不同）⇒ 归一化后**公共前缀 ≥ 4**
    --        就认 ⇒ 这种系统性差异**根本不需要"学"**，
    --        而 `woodenfoundation` vs `ancientcookingstove` 公共前缀是 0 ⇒ 永远不会误配 ✓
    local best, near, sim = nil, nil, nil
    local bs = bp.buildings
    for i = 1, #bs do
        local b = bs[i]
        if type(b) == "table" and type(b.p) == "table" then
            local rx = (tonumber(b.p[1]) or 0.0) * 100.0
            local ry = (tonumber(b.p[2]) or 0.0) * 100.0
            local rz = (tonumber(b.p[3]) or 0.0) * 100.0
            local tx = place.x + (rx * c - ry * s)
            local ty = place.y + (rx * s + ry * c)
            local tz = place.z + rz
            local dx, dy, dz = tx - wx, ty - wy, tz - wz
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            -- ★ `idx` = 这条记录在 bp.buildings 里的序号 —— 投影侧要靠它
            --   "精确地把这一条藏起来"（不用重扫整个世界，见 Ghost.rehide）
            local cand = { rec = b, idx = i, x = tx, y = ty, z = tz, dist = d,
                           yaw = Util.norm_yaw(yaw + (tonumber(b.yaw) or 0.0)) }
            if near == nil or d < near.dist then near = cand end
            local bnorm = BuildSnap.norm_id(b.t)
            local hit = (type_match ~= true) or accept[bnorm] == true
            if hit and (best == nil or d < best.dist) then best = cand end
            -- 名字相似（只在前两层都没命中时才会被用到）
            --
            -- ★★★ 2026-09-29 玩家实测抓到的**关键 bug**（他原话:
            --   「那块唯一放下的，在我指向的位置就有两三个靠得近的，
            --     **近的不吸附，吸附到更远的了**」）:
            --   这里原来写的是 `and sim == nil` ⇒ **只保留循环里遇到的第一条**
            --   相似记录，**完全不比距离** ✗✗
            --   而 `bp.buildings` 的顺序是采集顺序（没有空间意义）⇒
            --   第一条 `Wood_Foundation` 可能在基地另一头 ⇒ 于是"近的不吸、吸远的"，
            --   日志里就表现为 `距离 512 / 750 / 933 / 1746 / 2372 厘米`。
            --   ⇒ 现在和 `best` 一样: **取最近的那一条**（距离打平时再比公共前缀长度）。
            if type(want_id_norm) == "string" and want_id_norm ~= ""
                and bnorm ~= "" then
                local common = 0
                local n_min = math.min(#want_id_norm, #bnorm)
                while common < n_min
                    and string.byte(want_id_norm, common + 1)
                        == string.byte(bnorm, common + 1) do
                    common = common + 1
                end
                if common >= 4 then
                    local better = (sim == nil) or (d < sim.dist - 0.001)
                        or (math.abs(d - sim.dist) <= 0.001
                            and common > (sim.common or 0))
                    if better then
                        sim = cand
                        sim.common = common
                    end
                end
            end
        end
    end
    return { best = best, near = near, sim = sim }
end

--- 一条记录在当前投影下的世界坐标。返回 x,y,z（无效返回 nil）
function BuildSnap.record_world(place, b, c, s)
    if type(b.p) ~= "table" then return nil end
    local rx = (tonumber(b.p[1]) or 0.0) * 100.0
    local ry = (tonumber(b.p[2]) or 0.0) * 100.0
    local rz = (tonumber(b.p[3]) or 0.0) * 100.0
    if c == nil or s == nil then
        local rad = math.rad(place.yaw or 0.0)
        c, s = math.cos(rad), math.sin(rad)
    end
    return place.x + (rx * c - ry * s), place.y + (rx * s + ry * c), place.z + rz
end

-- --------------------------------------------------------------------------
-- 找目标记录 ②: 蓝图建造模式 —— 准星指着的**那一件**（不限类型）
-- --------------------------------------------------------------------------

--- 【探索期遗留 · 只服务未完成的 `blueprint` 模式（2026-09-29 定稿）】
--- 用"准星射线"选目标: 取"在锥角里、且离得最近"的那一件。
---
--- 判据（世界厘米）:
---   along = 记录中心在视线方向上的投影距离（必须 > 0 = 在身前，且 <= max_cm）
---   角度  = atan(perp / along)，perp = 记录中心到视线的垂直距离
---           —— 必须落在 cone_deg 的锥角里
---   排序  = 先把 perp 分档（每 50 厘米一档），**同档取更近（along 小）的那一件**
---
--- ★ 为什么锥角用"角度"而不是"固定厘米":
---   固定厘米在远处会变得极难瞄准（10 米外偏 30 厘米就选不中）；
---   角度锥对远近一视同仁（默认 12° 时: 3 米外允许 ±64 厘米、10 米外 ±2.1 米）。
--- ★ 为什么排序要分档（2026-09-29 第三次实测的教训）:
---   投影记录都在地面上，而玩家视线多半是水平的 ⇒ 它们的 perp 全都挤在
---   ~78 厘米（只差零点几厘米的噪声）⇒ 按 perp 精排等于**近似随机挑一件**，
---   实测挑到了 11~25 米外的记录（游戏直接拒绝，什么都没建出来）。
---   分档后: 瞄准差不多的几件之间比距离 ⇒ 选最近的；瞄准明显更好的一件仍优先。
function BuildSnap.find_target_by_aim(bp, place, px, py, pz, dx, dy, dz,
                                      max_cm, cone_deg)
    if type(bp) ~= "table" or type(bp.buildings) ~= "table" then return nil end
    if dx == nil or dy == nil or dz == nil then return nil end
    local len = math.sqrt(dx * dx + dy * dy + dz * dz)
    if len < 1e-6 then return nil end
    dx, dy, dz = dx / len, dy / len, dz / len
    local tan_cone = math.tan(math.rad(cone_deg or 12.0))

    local yaw = place.yaw or 0.0
    local rad = math.rad(yaw)
    local c, s = math.cos(rad), math.sin(rad)

    local best = nil
    local bs = bp.buildings
    for i = 1, #bs do
        local b = bs[i]
        if type(b) == "table" and type(b.p) == "table" then
            local wx, wy, wz = BuildSnap.record_world(place, b, c, s)
            if wx ~= nil then
                local vx, vy, vz = wx - px, wy - py, wz - pz
                local along = vx * dx + vy * dy + vz * dz
                if along > 1.0 and along <= max_cm then
                    local ox, oy, oz = vx - along * dx, vy - along * dy,
                        vz - along * dz
                    local perp = math.sqrt(ox * ox + oy * oy + oz * oz)
                    if perp <= along * tan_cone then
                        -- ★ 排序: 先把"垂直偏差"分档（每 50 厘米一档），
                        --   同一档里取更近的那一件。
                        --   为什么不全按 perp 排（2026-09-29 第三次实测）:
                        --   投影记录都在地面上，而视线多半是水平的 ⇒ 它们的
                        --   perp 全都在 78~79 厘米（只差几十厘米的噪声）⇒
                        --   按 perp 排等于**近似随机挑一件**，结果挑到了 11~25 米外
                        --   的远处记录（游戏直接拒绝，什么都没建出来）。
                        --   分档之后: "瞄准得差不多"的件之间比距离 ⇒ 选最近的那件，
                        --   而瞄准明显更好的一件仍然优先。
                        local perp_band = math.floor(perp / 50.0)
                        if best == nil or perp_band < best.perp_band
                            or (perp_band == best.perp_band
                                and along < best.along) then
                            best = { rec = b, idx = i, x = wx, y = wy, z = wz,
                                     dist = perp, along = along, perp = perp,
                                     perp_band = perp_band,
                                     -- ★ 必须带上朝向（2026-09-29 修: 原来漏了它，
                                     --   于是蓝图模式一直用玩家自己的朝向，
                                     --   等于"位置吸了、朝向没吸"）
                                     yaw = Util.norm_yaw(yaw
                                         + (tonumber(b.yaw) or 0.0)) }
                        end
                    end
                end
            end
        end
    end
    return best
end

-- --------------------------------------------------------------------------
-- ★★ 钩子回调: 整个游戏的放置请求都会经过这里
-- --------------------------------------------------------------------------

--- 参数顺序（来自只读参考 SBB 的钩子签名）:
---   self, build_object_id, location, rotation, extra_parameter_archives, debug_parameter
function BuildSnap.on_request_build(self, build_object_id, location, rotation,
                                    extra_params)
    BuildSnap.fired = BuildSnap.fired + 1

    -- ★★ 2026-09-29 **黑匣子第 0 行: "钩子被调用了"这件事本身就要留痕** ——
    --   必须写在**所有前置检查之前**（包括"没投影/没蓝图就原样放行"那几条），
    --   否则我们仍然分不清"钩子根本没被调用"和"调用了但没走到写日志那一步"。
    --   起因与判读表见 `docs\踩坑记录.md` §68（玩家报"水面上按放置就卡住"）。
    if Log ~= nil and Log.solid ~= nil then
        pcall(Log.solid, string.format(
            "  [bsnap] ● 钩子被调用（第 %d 次请求）", BuildSnap.fired))
    end

    local trace = (BuildSnap.trace_left > 0)
    if trace then BuildSnap.trace_left = BuildSnap.trace_left - 1 end

    -- ---- 前置条件: 必须在"投影正在显示 + 有蓝图"时才工作
    --   ★ 局部变量名不要叫 `get`（会和 `:get()` 方法名的检查撞上）
    local cfg = BuildSnap.deps.get
    if cfg == nil or cfg("buildsnap_enabled") ~= true then return end
    local mode = cfg("buildsnap_mode")
    if mode ~= "align" and mode ~= "blueprint" then mode = "align" end
    -- ★★ 2026-09-29 定稿: `blueprint` 模式**没做完**（见 pwpr_config.lua 的说明）
    --   ⇒ 玩家一旦设了它，就在日志/屏幕上明确说一次，别让他以为"应该能用"。
    if mode == "blueprint" and BuildSnap.blueprint_warned ~= true then
        BuildSnap.blueprint_warned = true
        Log.emit("  [bsnap] !! 你设的是 buildsnap_mode = \"blueprint\"，但**这个模式"
            .. "没做完**（需要先学到各类型的游戏 id；材料还按投影那件算）。"
            .. "建议改回 \"align\"。现在仍然按 blueprint 的规则尝试，"
            .. "吸不上时日志会写明原因")
        if BuildSnap.deps.notify ~= nil then
            BuildSnap.deps.notify("blueprint 模式未完成，建议改回 align（见 F7/日志）",
                "blueprint mode is unfinished; use align")
        end
        Log.flush()
    end
    local ctx = BuildSnap.deps.context
    local bp, place = nil, nil
    if ctx ~= nil then
        local ok, a, b = pcall(ctx)
        if ok then bp, place = a, b end
    end
    if bp == nil or place == nil then return end

    -- ---- 读参数（★ 必须先 unwrap，见文件头那段实测记录）
    local id_str = BuildSnap.read_name_string(build_object_id)
    local lx, ly, lz = BuildSnap.read_vec3(location)
    local qx, qy, qz, qw = BuildSnap.read_quat(rotation)
    local want_yaw = BuildSnap.quat_to_yaw(qx, qy, qz, qw)

    if id_str ~= nil then
        BuildSnap.ids_seen[id_str] = (BuildSnap.ids_seen[id_str] or 0) + 1
    end

    -- ★★ 附加参数（第 4 个参数）的状态 —— 判据见 `BuildSnap.extra_state` 的说明。
    --   它是"这次请求是不是特殊建造路径"的唯一外部线索（水面地基那次的嫌疑人）。
    local extra_empty, extra_why = BuildSnap.extra_state(extra_params)

    -- ★★ 2026-09-29 **黑匣子（每次请求都写，且立刻落盘）** —— 见 pwpr_log.Log.solid。
    --
    -- 起因（玩家报「在水面上按放地基就卡住」）: 那次日志里**一行建造请求都没有**，
    --   于是有两种完全相反的解释，而当时的日志分不出是哪一种:
    --     ① 我们的钩子**根本没被调用**（那卡死与我们无关 —— 水面上那种建筑可能
    --        走的不是 `RequestBuild_ToServer` 这条路）；
    --     ② 调用了、日志写进了内存缓冲，但游戏线程随即卡死（死循环/死锁）
    --        ⇒ 缓冲里那些行**全丢了**（本项目日志是攒批落盘的，见 pwpr_log）。
    --   ⇒ 这一行**同步写盘**:
    --        · 它出现 = 钩子确实被调用过；
    --        · 再配合后面「● 即将拦原请求」「● 重发前/返回」看**走到哪一步**，
    --          缺哪一行就说明卡在哪一步。
    --   ※ 原来只有 `trace_left`（每局前 40 次）才记请求 —— 40 次之后就成了瞎子。
    if Log ~= nil and Log.solid ~= nil then
        pcall(Log.solid, string.format(
            "  [bsnap] ● 请求 #%d id=%s 位置=%s 朝向=%s 附加参数=%s",
            BuildSnap.fired, tostring(id_str),
            (lx ~= nil) and string.format("(%.0f,%.0f,%.0f)", lx, ly, lz) or "(读不到)",
            (want_yaw ~= nil) and string.format("%.1f 度", want_yaw) or "(读不到)",
            string.format("%s（%s）", tostring(extra_empty), tostring(extra_why))))
    end

    if trace or lx == nil then
        Log.line(string.format(
            "  [bsnap] 请求 #%d: id=%s 位置=%s 朝向=%s | 参数形式 id=%s loc=%s rot=%s",
            BuildSnap.fired, tostring(id_str),
            (lx ~= nil) and string.format("(%.1f,%.1f,%.1f)", lx, ly, lz) or "(读不到)",
            (want_yaw ~= nil) and string.format("%.1f 度", want_yaw) or "(读不到)",
            BuildSnap.describe_param(build_object_id),
            BuildSnap.describe_param(location),
            BuildSnap.describe_param(rotation)))
    end

    -- ---- 选目标
    local radius = tonumber(cfg("buildsnap_radius_cm")) or 300.0
    local rot_tol = tonumber(cfg("buildsnap_rot_tol_deg")) or 35.0
    local dry = (cfg("buildsnap_dry_run") == true)
    local type_loose = tonumber(cfg("buildsnap_type_loose_cm")) or 100.0
    local max_dist = tonumber(cfg("buildsnap_max_dist_cm")) or 1200.0
    local snap_z = (cfg("buildsnap_snap_z") == true)

    -- ---- ★★★ 卡死/崩溃的记忆: **只用来"少改一点"，不再用来"完全不干"** ----
    --
    -- ⚠️⚠️ 2026-09-29 玩家当场纠正（很重要）:
    --   「为了不崩把吸附功能改得几乎没用了吗，不能这么处理啊 …… 我现在放了好几个
    --     几乎贴上去的都不吸附了。」
    --   ⇒ 我上一版把"出过事的类型"和"出事那一片（25 米）"**整块拉黑**，
    --     结果玩家整片基地都吸不上 —— 那是**拿功能换安全**，方向错了。
    --   ⇒ 现在的原则:
    --     · 记忆**不再阻止吸附**，只做两件"少改一点"的事:
    --       ① 出过事的类型 ⇒ **不动高度**（x/y 照吸）；
    --       ② 出事那一片（默认半径见 `buildsnap_zone_m`，**默认 0 = 不启用**）⇒ 只提示；
    --     · 真正防崩的是下面那道**"精细吸附窗口"**（`buildsnap_safe_cm`）:
    --       实测三次事故的修正量分别是 **93 / 110 / 143 厘米**，而"贴上去"的都在几十厘米内
    --       ⇒ 只吸"小修正"，大搬运一律原样放行并**明确告诉玩家**（还给了调大的开关）。
    local id_norm_now = BuildSnap.norm_id(id_str)
    if type(id_norm_now) ~= "string" then id_norm_now = "" end
    -- ★ `.111`: 降级/高度记忆的键 = 这一类 id + **这一处投影**（见 `BuildSnap.z_key`）。
    --   在这里算一次、随请求一路带下去（读和写必须用同一个键）。
    local zkey = BuildSnap.z_key(id_norm_now)
    local frozen = BuildSnap.frozen[id_norm_now]
    local z_why = ""
    if frozen == 1 and BuildSnap.pending_z_shift[id_norm_now] ~= nil then
        local dz = BuildSnap.pending_z_shift[id_norm_now]
        local moved = false
        if BuildSnap.deps.on_z_rejected ~= nil then
            pcall(function()
                moved = BuildSnap.deps.on_z_rejected(id_str, dz,
                    "上一次会话卡死在这个高度上（已按游戏允许的高度修正）") == true
            end)
        end
        if moved == true then
            BuildSnap.pending_z_shift[id_norm_now] = nil
            BuildSnap.frozen[id_norm_now] = nil
            BuildSnap.z_shifted[zkey] = true
            frozen = nil
            if Log ~= nil and Log.solid ~= nil then
                pcall(Log.solid, string.format(
                    "  [bsnap] ● 高度自适应: %s 上次卡死在该高度 ⇒ 已把投影高度挪 %+.0f 厘米"
                    .. "（这次就用修正后的高度吸）", tostring(id_str), dz))
                -- ★ 正式记忆改写成"已清除"，免得下次启动又挪一遍
                pcall(Log.solid, string.format("  [bsnap] ● 记忆 cleared id=%s",
                    tostring(id_str)))
            end
        end
    end
    local snap_z_eff = snap_z
    if snap_z == true and frozen ~= nil then
        -- ★★★ 2026-09-29 玩家再次定调「不要再因为害怕游戏崩掉而把功能屏蔽」:
        --   记忆**不再改变任何行为**（原来"出事过的类型 ⇒ 不动高度"也是一种屏蔽）。
        --   它现在只做两件事: ① 启动时把学到的内容写进日志/F7；② 若记忆里带"高度差"
        --   且定位不到区域，才在下面那次"挪投影高度"里用一次。
        --   ⇒ 防崩全靠**机制**（`buildsnap_defer`: 重发排到下一帧），不靠少吸。
        z_why = "（记忆里有这一类出过事的记录，但本版**不因此少吸**）"
    end
    if snap_z == true and BuildSnap.z_denied[zkey] == true then
        snap_z_eff = false
        z_why = "（**这一处**上一次\"改高度\"被游戏拒了 ⇒ 这一类只吸 x/y —— "
            .. "这是「被拒」信号，不是「崩」；换一处 / 换一张蓝图会自动恢复）"
    end

    -- ---- ★★★ 危险区域（整片拉黑）: 这一片出过"卡死/崩溃" ⇒ **一律不重发**
    --   实测教训（2026-09-29 第二次崩溃）: 给 `Glass_foundation` 拉黑之后，
    --   换个类型 `SF_foundation` 在**同一片水面**又崩了一次 ⇒ 问题在"这一片改坐标重发"，
    --   不在某一种建筑上。⇒ 这一片以后一律原样放行（游戏自己的放置完全安全）。
    do
        local hz = 88.0
        if BuildSnap.deps.half_height_cm ~= nil then
            pcall(function()
                local v = BuildSnap.deps.half_height_cm()
                if type(v) == "number" and v > 10 and v < 500 then hz = v end
            end)
        end
        local zone = nil
        if type(lx) == "number" and type(ly) == "number" then
            pcall(function() zone = BuildSnap.in_bad_zone(lx, ly) end)
        end
        -- ★★ 2026-09-29 玩家当场纠正: **默认不再因为"出过事"就整片关掉吸附**
        --   （`buildsnap_zone_m` 默认 0 = 不启用；想用就把米数填上）。
        --   现在这里只写一行日志提示，**不 return**，后面照样按"精细吸附窗口"决定。
        if zone ~= nil and (tonumber(cfg("buildsnap_zone_m")) or 0.0) > 0.0 then
            if BuildSnap.zone_notified ~= true then
                BuildSnap.zone_notified = true
                Log.emit(string.format(
                    "  [bsnap] 提示: 这一片（%.0f,%.0f 半径 %.0f 米）之前重发时崩/卡过 —— "
                    .. "**只吸小修正**（精细吸附窗口 %.0f 厘米内），大搬运一律原样放行。"
                    .. "（想整片不吸就把 buildsnap_zone_m 设大、想更激进就调 buildsnap_safe_cm）",
                    zone.x, zone.y, (zone.r or 2500.0) / 100.0,
                    tonumber(cfg("buildsnap_safe_cm")) or 80.0))
            end
        end
    end

    -- ---- ★★ 演示模式: 在**当前默认已经很松**的基础上再松一档
    --   （默认值本身已经是"玩家实测认可"的灵敏度了，见 pwpr_config.lua）
    if cfg("buildsnap_demo") == true then
        radius = 4000.0
        type_loose = 300.0
        max_dist = 6000.0
        rot_tol = 180.0
        -- ★ 演示模式**不再强行打开高度** —— 否则"卡死记忆/被拒"的降级会被它顶掉
        if frozen ~= 1 and BuildSnap.z_denied[zkey] ~= true then
            snap_z = true
            snap_z_eff = true
        end
        if BuildSnap.demo_logged ~= true then
            BuildSnap.demo_logged = true
            Log.emit("  [bsnap] ★ 演示模式（buildsnap_demo = true）:"
                .. " 半径 40 米 / 最远 60 米 / 类型放宽 3 米 /"
                .. " 朝向与高度总是跟投影 —— 用来排查「怎么都吸不上」或做演示")
            Log.flush()
        end
    end

    local target_id, res, why = nil, nil, nil
    -- ★ 朝向要不要跟着投影走（align 模式: 差在容差内才跟；blueprint 模式: 总是跟）
    local snap_yaw = true
    -- ★★ "高度差 ≤ 人物半高就按平面距离判" 用到的四个值（在 align 分支里算，见下）
    local half_h, dz_abs, ignore_z, corr_dec = 88.0, nil, false, nil

    if mode == "blueprint" then
        -- 蓝图建造: 用准星选（类型也跟着投影走，所以不看玩家选的类型）
        local aim = BuildSnap.deps.player_aim
        local px, py, pz, dx, dy, dz = nil, nil, nil, nil, nil, nil
        if aim ~= nil then
            local ok, a, b, c2, d, e, f = pcall(aim)
            if ok then px, py, pz, dx, dy, dz = a, b, c2, d, e, f end
        end
        if px == nil then
            BuildSnap.skipped = BuildSnap.skipped + 1
            if trace then
                Log.line("  [bsnap] 蓝图模式: 拿不到玩家位置/朝向（看不了准星）→ 原样放行")
            end
            return
        end
        local aim_max = tonumber(cfg("buildsnap_aim_max_cm")) or 3000.0
        local cone = tonumber(cfg("buildsnap_aim_cone_deg")) or 12.0
        res = BuildSnap.find_target_by_aim(bp, place, px, py, pz, dx, dy, dz,
            aim_max, cone)
        if res == nil then
            BuildSnap.skipped = BuildSnap.skipped + 1
            if trace then
                Log.line(string.format(
                    "  [bsnap] 蓝图模式: 准星 %.0f 米内、锥角 %.0f° 里没有投影记录 → 原样放行",
                    aim_max / 100.0, cone))
            end
            return
        end
        target_id = res.rec.t
        -- ★★★ 2026-09-29 第四次实测的根因修复:
        --   蓝图里的类型是从**类名**剥出来的，**不是游戏认的 id**
        --   （`Wood_Foundation` ≠ `Wooden_foundation`）。
        --   直接拿它去 `FName(...)` 建 = 发一个游戏不认识的 id ⇒ 服务端拒绝
        --   （玩家看到的 `zh-hans text` 就是那条错误提示缺翻译）。
        --   ⇒ 必须换成"学到过的游戏原始 id"；学不到就不吸（并说明怎么学）。
        local game_id = BuildSnap.learned_id[BuildSnap.norm_id(res.rec.t)]
        if game_id == nil then
            BuildSnap.skipped = BuildSnap.skipped + 1
            Log.emit(string.format(
                "  [bsnap] !! 蓝图模式: 类型 %s 还**不知道游戏 id** ⇒ 原样放行"
                .. "（直接拿类型名去建会被游戏拒绝）。"
                .. "办法: 先用 align 模式（默认）在投影附近正常盖一件%s，"
                .. "它就会学到 id（日志里会出现「★ 学到映射」），之后蓝图模式就能建它了",
                tostring(res.rec.t), tostring(res.rec.t)))
            -- ★ 也要让**屏幕上**看到 —— 否则玩家的体感就是"蓝图模式什么都没做"
            --   （2026-09-29 玩家反馈: "blueprint 也能放置，但跟投影没啥关系，也是直接放的"）
            if BuildSnap.deps.notify ~= nil then
                BuildSnap.deps.notify(string.format(
                    "蓝图模式: %s 还没学到游戏 id（先用 align 盖一件同类的）",
                    tostring(res.rec.t)), "blueprint: unknown game id")
            end
            if Log.throttled_flush ~= nil then
                Log.throttled_flush(1.0)
            else
                Log.flush()
            end
            return
        end
        target_id = game_id
        if trace then
            Log.line(string.format(
                "  [bsnap] 蓝图模式: 准星选中 %s（前方 %.0f 厘米，偏离准星 %.0f 厘米）"
                .. " → 用游戏 id %s",
                tostring(res.rec.t), res.along, res.perp, tostring(game_id)))
        end
    else
        -- 吸附模式: 需要在"这次请求的坐标"附近找同类型的记录 ⇒ 坐标必须读得到
        if lx == nil or want_yaw == nil then
            BuildSnap.skipped = BuildSnap.skipped + 1
            if BuildSnap.fired <= 5 then
                Log.emit("  [bsnap] !! 读不到放置坐标/朝向 —— 把这几行发给开发者")
                Log.flush()
            end
            return
        end
        local type_match = (cfg("buildsnap_type_match") == true)
        local loose = type_loose      -- ★ 用外层那个（演示模式会改它）
        local id_norm = BuildSnap.norm_id(id_str)
        local learned_norm = BuildSnap.learned[id_norm]
        local keys = { id_norm }
        if learned_norm ~= nil then keys[#keys + 1] = learned_norm end
        local found = BuildSnap.find_target(bp, place, lx, ly, lz, keys,
            type_match, id_norm)
        -- ★★★ 这里**绝对不能**写 `local res = ...`！
        --   2026-09-29 第三次实测的教训: 上一条重构里我在这个分支里写了
        --   `local res = nil`，于是它**遮蔽了外层那个 res**，
        --   分支里算得好好的结果全写进了内层变量 ⇒ 出分支后
        --   `if res == nil then return end` 直接返回 ⇒ **align 模式什么都不做**。
        --   症状: 日志里看到"★ 学到映射"（说明匹配成功了）却没有任何"结果"行，
        --   玩家那边就是"没反应"。⇒ 一律写到外层 res。
        if found ~= nil then
            res = found.best
            -- ★★ 玩家定稿的判据（见下面 corr_dec 那段说明）: 高度差 ≤ 人物半高时**不判高度**。
            --   这里**先算好**，好让"半径闸"和"修正量上限"都用它（否则闸门已经按三维距离
            --   拦掉了，后面再改就晚了 —— 实测: `距离=387 厘米` 就是这么被拦的）。
            do
                local hh = 88.0
                if BuildSnap.deps.half_height_cm ~= nil then
                    pcall(function()
                        local v = BuildSnap.deps.half_height_cm()
                        if type(v) == "number" and v > 10 and v < 500 then hh = v end
                    end)
                end
                half_h = hh
                if res ~= nil and type(lz) == "number" and type(lx) == "number"
                    and type(res.z) == "number" then
                    dz_abs = math.abs(res.z - lz)
                    if dz_abs <= hh then
                        ignore_z = true
                        local hx, hy = res.x - lx, res.y - ly
                        corr_dec = math.sqrt(hx * hx + hy * hy)
                    end
                end
            end
            -- ★★ 第二层: **名字相似**（同一个东西、拼写不同）—— 不再依赖"学到映射"
            if res == nil and found.sim ~= nil then
                res = found.sim
                found.similar = true
                Log.emit(string.format(
                    "  [bsnap] 用「名字相似」配对: 游戏 id %s ↔ 蓝图类型 %s"
                    .. "（公共前缀 %d 个字母，距离 %.1f 厘米）",
                    tostring(id_str), tostring(res.rec.t),
                    tonumber(res.common) or 0, res.dist))
                if Log.throttled_flush ~= nil then Log.throttled_flush(1.0) end
            end
            if res == nil and loose > 0.0 and found.near ~= nil
                and found.near.dist <= loose then
                -- ★ 放宽: 没有同类型记录，但最近的那一件贴得极近 ⇒ 就认它，
                --   并把这次观察记成"学到映射"（下次就按同类型处理）。
                res = found.near
                found.loosen = true
                -- ★★★ 2026-09-29 事故修复: **"放宽接受"和"学习映射"是两件事**。
                --   · 放宽接受: 照旧 —— 距离 ≤ `buildsnap_type_loose_cm`（默认 150 厘米）
                --     就认它（这样"名字完全不同但确实贴在一起"的怪情况也能吸上）；
                --   · 学习映射: **只有贴得极近**（≤ `buildsnap_learn_max_cm`，默认 30 厘米）
                --     才记下来 —— 实测"同一个东西名字不同"是 7~21 厘米，
                --     而"别的种类"贴这么近基本不可能。
                --   事故: 学习条件原来只要求"在放宽阈值内"（历史上到过 1000/2000 厘米）
                --   ⇒ 放**地板**时把 9 米外的**箱子/灶台**学成了自己
                --   ⇒ 之后每次都去找灶台（十几米外）⇒ 被修正量上限拦掉
                --   ⇒ 玩家体感: **第一次之后再也不吸** ✗
                local learn_max = tonumber(cfg("buildsnap_learn_max_cm")) or 30.0
                if learn_max > 0.0 and res.dist > learn_max then
                    Log.emit(string.format(
                        "  [bsnap] 这次按「放宽」认了（%.1f 厘米 ≤ 放宽 %.1f）"
                        .. "但**不学映射**（超过学习阈值 %.0f 厘米）",
                        res.dist, loose, learn_max))
                elseif id_norm ~= "" then
                    local learned = BuildSnap.norm_id(res.rec.t)
                    if learned ~= "" and BuildSnap.learned[id_norm] ~= learned then
                        BuildSnap.learned[id_norm] = learned
                        -- ★ 同时记住【反向】: 这个蓝图类型对应的**游戏原始 id**，
                        --   蓝图模式要靠它才能发对 id（见 learned_id 的注释）。
                        BuildSnap.learned_id[learned] = id_str
                        Log.emit(string.format(
                            "  [bsnap] ★ 学到映射: 游戏 id %s → 蓝图类型 %s"
                            .. "（距离仅 %.1f 厘米，基本可以确定是同一个东西）",
                            tostring(id_str), tostring(res.rec.t), res.dist))
                        if Log.throttled_flush ~= nil then
                            Log.throttled_flush(1.0)
                        else
                            Log.flush()
                        end
                    end
                end
            end
        end
        if res == nil then
            BuildSnap.skipped = BuildSnap.skipped + 1
            if trace then
                local near = (found ~= nil) and found.near or nil
                Log.line(string.format(
                    "  [bsnap] 匹配: id=%s(归一化 %s) → 投影里没有同类型的记录; "
                    .. "最近的一件=%s 距离=%s 厘米（放宽阈值 %.0f）朝向差=%s",
                    tostring(id_str), id_norm,
                    near and tostring(near.rec.t) or "-",
                    near and string.format("%.1f", near.dist) or "-",
                    loose,
                    (near ~= nil and want_yaw ~= nil)
                        and string.format("%.1f 度",
                            math.abs(Util.norm_yaw(near.yaw - want_yaw))) or "-"))
                local sample = {}
                for i = 1, math.min(#bp.buildings, 6) do
                    sample[#sample + 1] = tostring(bp.buildings[i].t)
                end
                Log.line("      蓝图类型样本: " .. table.concat(sample, ", "))
            end
            return
        end
        target_id = id_str            -- 类型保持玩家选的那个（我们只挪位置）
        if target_id == nil or target_id == "" then
            BuildSnap.skipped = BuildSnap.skipped + 1
            Log.line("  [bsnap] 匹配上了，但读不到建筑 id 的字符串 → 原样放行")
            return
        end
        local dyaw = math.abs(Util.norm_yaw(res.yaw - want_yaw))
        if trace then
            -- ★ 2026-09-29 补: 把**目标坐标和分轴差值**也写出来 —— 只写"距离 387 厘米"
            --   看不出"是水平错位还是高度错位"（排查"为什么吸附不上"全靠这一行）。
            local ddx = (lx ~= nil) and (res.x - lx) or nil
            local ddy = (ly ~= nil) and (res.y - ly) or nil
            local ddz = (lz ~= nil) and (res.z - lz) or nil
            Log.line(string.format(
                "  [bsnap] 匹配: 记录#%s 类型=%s%s 距离=%.1f 厘米（阈值 %.0f）"
                .. " 目标=(%.0f,%.0f,%.0f) 请求=(%s) 分轴差=(%s,%s,%s)"
                .. " 记录朝向=%.1f 请求朝向=%.1f 差=%.1f 度（容差 %.0f）",
                tostring(res.idx), tostring(res.rec.t),
                (found.loosen == true) and "（放宽命中）" or "",
                res.dist, radius, res.x, res.y, res.z,
                (lx ~= nil) and string.format("%.0f,%.0f,%.0f", lx, ly, lz) or "读不到",
                ddx and string.format("%.0f", ddx) or "-",
                ddy and string.format("%.0f", ddy) or "-",
                ddz and string.format("%.0f", ddz) or "-",
                res.yaw, want_yaw, dyaw, rot_tol))
        end
        if (corr_dec or res.dist) > radius then
            BuildSnap.skipped = BuildSnap.skipped + 1
            if trace then
                Log.line(string.format("  [bsnap] 结果: 太远（%.1f > %.0f 厘米%s）→ 原样放行",
                    corr_dec or res.dist, radius,
                    ignore_z and "（按平面距离判，因为高度差在人物半高内）" or ""))
            end
            return
        end
        -- ★ 朝向: 差在容差内就**连朝向一起吸**；差太多就**只吸位置、保留你的朝向**
        --   （2026-09-29 第二次实测的日志里请求朝向是 134.4° / 53.0° / -42.7° 这种
        --    自由角度 —— 说明玩家是随手转的。以前"差太多就整个不吸"会让功能看起来
        --    完全没反应；现在改成"位置一定吸，朝向看情况"，更符合玩家要的
        --    「自动将位置吸附到投影的对应位置」。）
        snap_yaw = (dyaw <= rot_tol)
        if not snap_yaw then
            Log.line(string.format(
                "  [bsnap] 朝向差 %.1f 度 > 容差 %.0f ⇒ **只吸位置、保留你当前的朝向**"
                .. "（想让朝向也跟投影走: 把 buildsnap_rot_tol_deg 调大）", dyaw, rot_tol))
        end
    end

    if res == nil or res.rec == nil then return end

    -- ---- 「高度差 ≤ 人物半高 ⇒ 不判高度」的判据在 align 分支里已经算好（见 `corr_dec`）。
    --   这里只做兜底与日志（blueprint 分支/算不出来时 `corr_dec` 仍是 nil ⇒ 用三维距离）。
    if ignore_z == true and trace then
        Log.line(string.format(
            "  [bsnap] 高度差 %.1f 厘米 ≤ 人物半高 %.0f ⇒ **不判高度**，"
            .. "按平面距离 %.1f 厘米决定（三维距离 %.1f）",
            tonumber(dz_abs) or 0.0, half_h, corr_dec or res.dist, res.dist))
    end

    -- ---- 目标坐标
    --
    -- ★★ 高度（z）: 默认**跟投影走**（`buildsnap_snap_z = true`，玩家 2026-09-29 定稿:
    --   「地面建的时候高度是不固定的」）。"吸不上"由**降级阶梯**兜底 ——
    --   被游戏拒过、或上次因它卡死过 ⇒ 这一类自动只吸 x/y（见 `snap_z_eff` 的来源）。
    --   （旧注释里"默认不用投影的 z、逐块跟地形"是 2026-09-29 早先的结论，
    --     后来被玩家的实测手感推翻，保留在此只为解释历史。）
    local tx, ty, tz = res.x, res.y, res.z
    -- ★ 用 `snap_z_eff`（= 配置值 再叠上"降级阶梯"）: `false` 时保留游戏算出的高度
    if not snap_z_eff and lz ~= nil then
        tz = lz                     -- 保留游戏算出的高度
    end
    local dz_note = string.format("高度用%s%s",
        snap_z_eff and "投影的" or "游戏给的", z_why)

    local target_yaw = res.yaw
    if target_yaw == nil then
        target_yaw = (mode == "blueprint" or snap_yaw) and want_yaw or 0.0
    end
    if mode ~= "blueprint" and not snap_yaw and want_yaw ~= nil then
        target_yaw = want_yaw
    end

    -- ---- ★ 距离闸: 目标离玩家太远时游戏不会认可（第三次实测: 蓝图模式选中了
    --      11~25 米外的记录 ⇒ 请求发出去、游戏拒绝了、什么都没建出来）。
    --      超了就**原样放行**，让游戏按它自己的位置放 —— 宁可没吸上，也不能吞掉这一下。
    local aim = BuildSnap.deps.player_aim
    local px2, py2, pz2 = nil, nil, nil
    if aim ~= nil then
        local ok, a, b, c2 = pcall(aim)
        if ok then px2, py2, pz2 = a, b, c2 end
    end
    if px2 ~= nil then
        local ddx, ddy, ddz = tx - px2, ty - py2, tz - pz2
        local pdist = math.sqrt(ddx * ddx + ddy * ddy + ddz * ddz)
        if pdist > max_dist then
            BuildSnap.skipped = BuildSnap.skipped + 1
            Log.emit(string.format(
                "  [bsnap] !! 目标离你 %.0f 米（上限 %.0f 米）—— 游戏不会认可这么远的放置，"
                .. "**原样放行**（没吸上，但也没吞掉这一下）",
                pdist / 100.0, max_dist / 100.0))
            Log.flush()
            return
        end
    end

    local zq = {}
    BuildSnap.yaw_to_quat(zq, target_yaw)

    -- ---------------------------------------------------------------------
    -- ★★★ 三道"防误配"闸（2026-09-29 一次实测事故后加的）
    --
    -- 事故经过: 玩家开着演示模式（半径 40 米 / 类型放宽 20 米）放**地板**，
    --   而附近没有地板记录 ⇒ 吸附把目标选到 **9 米外的箱子**；
    --   于是**每一块地板都被挪到那一个位置** ⇒ 那位置已被第一块占住
    --   ⇒ 后面每一块都被游戏拒绝（玩家感受: "只能放下第一块，一直提示不让放"）。
    -- ⇒ 教训: 吸附的本意是"**挪一点点**帮你对齐"，不是"把这块搬到别处去"。
    --   所以下面三件事任意一条成立，就**原样放行**（宁可不吸，也绝不乱吸）。
    -- ---------------------------------------------------------------------

    local corr = corr_dec or res.dist or res.along or 0.0

    -- 闸 ①: 修正量上限（最有效的总保险）
    local max_jump = tonumber(cfg("buildsnap_max_jump_cm")) or 600.0
    if max_jump > 0.0 and corr > max_jump then
        BuildSnap.skipped = BuildSnap.skipped + 1
        -- ★★ 自愈: 如果这条目标来自"学到映射"，说明那个映射是错的（把我们带到了
        --   老远的别的种类）⇒ **丢掉它**，下次就回到"名字相似/精确类型"的正路上。
        local idn = BuildSnap.norm_id(id_str)
        if idn ~= "" and BuildSnap.learned[idn] ~= nil
            and BuildSnap.learned[idn] == BuildSnap.norm_id(res.rec.t) then
            Log.emit(string.format(
                "  [bsnap] !! 丢掉被污染的映射: %s → %s（它把目标带到了 %.0f 厘米外）",
                tostring(id_str), tostring(res.rec.t), corr))
            BuildSnap.learned[idn] = nil
        end
        -- ★★ 2026-09-29: 玩家反馈"怎么又都识别不上了" —— 其实日志里一直写着
        --   "要挪 751 厘米 ⇒ 原样放行"。**光说"放行"他看不出问题在哪**，
        --   所以这里直接把"最近的投影件有多远"写出来，一眼就能判断:
        --     · 几十厘米 ~ 2 米 ⇒ 正常，只是这次摆得偏了；
        --     · 5 米以上 ⇒ **投影和你的实际建造位置对不上**（要重新定位投影，
        --       或者用"投影对齐"把整个投影挪到已有建筑上）。
        local near_txt = ""
        if found ~= nil and found.near ~= nil then
            near_txt = string.format("；最近的投影件（%s）在 %.1f 米外",
                tostring(found.near.rec and found.near.rec.t or "?"),
                (found.near.dist or 0.0) / 100.0)
        end
        Log.emit(string.format(
            "  [bsnap] !! 这次要挪 %.1f 米（超过上限 %.1f 米）⇒ **原样放行**%s。"
            .. " 吸附只做「挪一点点帮你对齐」，不做远程搬运；"
            .. "如果最近的投影件本来就在好几米外，说明**投影本身没摆对位置**"
            .. "（按 H 站到正确的位置重放，或用投影对齐把整个投影挪到已有建筑上）",
            corr / 100.0, max_jump / 100.0, near_txt))
        Log.flush()
        return
    end

    -- 闸 ②: 那一条记录**已经放上过了**（投影里已经把它藏起来/正在待处理队列里）
    --   ⇒ 玩家这次大概率是想在别处放，别把他按回同一个位置（那位置已经被占了）。
    if BuildSnap.deps.record_taken ~= nil then
        local taken = false
        pcall(function() taken = BuildSnap.deps.record_taken(res.idx) == true end)
        if taken then
            BuildSnap.skipped = BuildSnap.skipped + 1
            Log.emit(string.format(
                "  [bsnap] !! 记录 #%s（%s）**已经放上过了** ⇒ 原样放行"
                .. "（不再往那个已经占住的位置上吸）",
                tostring(res.idx), tostring(res.rec.t)))
            Log.flush()
            return
        end
    end

    -- 闸 ③: 这一条**刚被游戏拒绝过**（1.2 秒确认失败）⇒ 短时间内不要再试它，
    --   否则会出现"每一次点击都撞同一堵墙"的死循环。
    if res.idx ~= nil and BuildSnap.rejected ~= nil then
        local t0 = BuildSnap.rejected[res.idx]
        if t0 ~= nil then
            local age = os.clock() - t0
            if age < (BuildSnap.REJECT_MEMORY_S or 8.0) then
                BuildSnap.skipped = BuildSnap.skipped + 1
                Log.emit(string.format(
                    "  [bsnap] !! 记录 #%s（%s）%.1f 秒前刚被游戏拒绝过 ⇒ 暂时不吸它"
                    .. "（%.0f 秒后才会再考虑）→ 原样放行",
                    tostring(res.idx), tostring(res.rec.t), age,
                    BuildSnap.REJECT_MEMORY_S or 8.0))
                Log.flush()
                return
            end
        end
    end

    -- ---- ★★ **已经够准就不插手**（2026-09-29 加的，为削掉"放置瞬间那一下"）
    --
    -- 为什么: 我们改写的代价是"拦下原请求 + 自己重发一次" ⇒ 游戏侧等于做**两遍活**
    --   （一遍被我们作废、一遍是真的），这个开销就发生在玩家点下去的那一瞬间。
    --   而实测里"摆得已经很准"是常态（游戏自己也有地板吸附）⇒ 差得比这个阈值还小时，
    --   干脆**完全不动它**（既不拦也不重发）。
    --   副作用: 差几厘米时朝向/高度也不再跟着投影微调 —— 这几厘米本来就在
    --   游戏的网格容差内，值得换来"点下去不卡"。想恢复旧行为就设成 0。
    local min_cm = tonumber(cfg("buildsnap_min_cm")) or 5.0
    if corr <= min_cm then
        BuildSnap.already_ok = (BuildSnap.already_ok or 0) + 1
        -- ★ 黑匣子: 这一步**不动游戏的请求**（不拦、不改）—— 明确写下来，
        --   这样"卡死发生在原样放行之后"就能一眼看出与我们无关。
        if Log ~= nil and Log.solid ~= nil then
            pcall(Log.solid, string.format(
                "  [bsnap] ● 已经够准（差 %.1f 厘米）⇒ **不动这次请求**（原样放行）", corr))
        end
        -- ★★★ 2026-09-29 实测踩到的坑: 这个"提前 return"最初把**记账也一起跳过了**
        --   —— 而"这一条记录已经放上了"跟"我们要不要改写坐标"**毫无关系**。
        --   后果（玩家实测）: 摆得准的那些件永远不进待处理队列 ⇒ 停下来之后
        --   投影**一直不更新**（十几秒都没反应，也没有提示）。
        --   ⇒ 这里必须照样通知投影侧。
        if BuildSnap.deps.on_placing ~= nil then
            pcall(BuildSnap.deps.on_placing, res.idx)
        end
        -- ★★★ 第二个后果（同一轮实测）: 这条分支原来**不排落地确认** ⇒
        --   我们拿不到那个新建 actor 的句柄 ⇒ 拆掉检测那条快路径**没东西可查**
        --   ⇒ 玩家拆掉之后 2.5 秒的恢复不触发（只能等十几秒的兜底全扫）。
        --   ⇒ 所以这里照样排一次确认（它同时给我们"游戏真的建出来了"和 actor 句柄）。
        BuildSnap.schedule_confirm(string.format("%s @ 已经够准", tostring(res.rec.t)),
            1200, string.format("已按原位建出（差 %.0f 厘米，未改写）", corr), res.idx,
            { id = id_str, id_norm = id_norm_now, z_changed = false,
              game_z = lz, target_z = tz, proj_z = res.z, z_key = zkey })
        if trace then
            Log.line(string.format(
                "  [bsnap] 已经够准（差 %.1f 厘米 ≤ %.1f）⇒ **不改坐标**"
                .. "（省掉一次放置开销），但仍记账 + 排落地确认（拿 actor 句柄，"
                .. "拆掉恢复才快）", corr, min_cm))
        end
        return
    end

    BuildSnap.last = {
        id = id_str, t = res.rec.t, mode = mode,
        dist = res.dist or res.along,
        dx = tx - (lx or tx), dy = ty - (ly or ty), dz = tz - (lz or tz),
    }

    if dry then
        BuildSnap.would_apply = BuildSnap.would_apply + 1
        Log.emit(string.format(
            "  [bsnap] 干跑（%s）: 本来会把这次放置改发到 %s 的位置 "
            .. "(%.1f,%.1f,%.1f) 朝向 %.1f 度（%s）—— 现在什么都不改",
            mode, tostring(res.rec.t), tx, ty, tz, target_yaw, dz_note))
        -- ★ 黑匣子: 干跑也要留一行（它**不会**改游戏，所以是"零风险抓现场"的手段）
        if Log ~= nil and Log.solid ~= nil then
            pcall(Log.solid, string.format(
                "  [bsnap] ● 干跑（不改游戏）: 本来要改发到 (%s,%s,%s) 朝向 %.1f 度；"
                .. "游戏原位置=(%.0f,%.0f,%.0f) 差 %.1f 厘米；附加参数=%s（%s）",
                tostring(tx), tostring(ty), tostring(tz), target_yaw,
                (lx or 0), (ly or 0), (lz or 0), corr,
                tostring(extra_empty), tostring(extra_why)))
        end
        Log.flush()
        return
    end

    -- ---------------------------------------------------------------------
    -- ★★ 闸 ④（2026-09-29 新增，**默认开**）: 请求带着"附加参数"时**不插手**。
    --
    -- 依据（`.52` 黑匣子的实测日志，`docs\踩坑记录.md` §68）:
    --   水面地基那次，卡死点被钉在"我们拦下原请求、按吸附坐标**重发**"的那一次
    --   调用里（`● 重发前` 之后再没有 `● 重发返回`，整个游戏冻结）。
    --   而"带附加参数"是**特殊建造路径**（水面 / 特殊套组 / 蓝图类操作）最明显的
    --   外部特征 —— 我们的重发是把它**原样透传**的，从来没读过它的内容。
    -- ⇒ 规矩 3b「不满足条件就原样放行（宁可没吸上，也不能改错）」:
    --   看不懂的请求**不动它** —— 游戏会照原样放好（只是不吸附），不会卡死。
    --   `buildsnap_skip_extra = false` 可恢复旧行为（排查用）。
    -- ---------------------------------------------------------------------
    if cfg("buildsnap_skip_extra") == true and extra_empty == false then
        BuildSnap.skipped = BuildSnap.skipped + 1
        if Log ~= nil and Log.solid ~= nil then
            pcall(Log.solid, string.format(
                "  [bsnap] ● 原样放行（没插手）: 这次请求带了附加参数（%s）⇒ "
                .. "不动它（怕像水面地基那样把游戏卡死）", tostring(extra_why)))
        end
        Log.emit(string.format(
            "  [bsnap] 原样放行: 请求带了附加参数（%s，本次 id=%s）⇒ **不拦不改**。"
            .. "这类是特殊建造路径（水面/特殊套组），我们的重发看不懂它；"
            .. "游戏会按你指的位置原样建造。想强行吸附（有卡死风险）就把 "
            .. "buildsnap_skip_extra 设成 false", tostring(extra_why), tostring(id_str)))
        Log.flush()
        return
    end

    -- ---- ★ 应用: ① 拦住原请求 ② 自己按吸附后的坐标重发一次
    --
    -- ★ 顺序不能反: 先拦住、确认拦住了，再重发。
    --   反过来（先重发再拦）万一没拦住就是**一次点击放两块**（玩家得拆、还白费材料）；
    --   而"拦住了但重发失败"的代价只是"这一次没放上"，玩家再点一下即可。
    local net = Util.unwrap(self)
    if net == nil then
        BuildSnap.skipped = BuildSnap.skipped + 1
        Log.line("  [bsnap] 拿不到网络组件（hook 的 self）→ 原样放行")
        return
    end
    local name_target = nil
    local okf, ferr = pcall(function() name_target = FName(tostring(target_id)) end)
    if not okf or name_target == nil then
        BuildSnap.skipped = BuildSnap.skipped + 1
        Log.line("  [bsnap] FName 构造失败（" .. tostring(ferr) .. "）→ 原样放行")
        return
    end

    -- ---------------------------------------------------------------------
    -- 精细吸附窗口（`buildsnap_safe_cm`，**默认 0 = 不限制**）
    --
    -- ⚠️ 2026-09-29 实测把"窗口能防崩"这个假设推翻了: 一次崩溃的修正量只有 **44.9 厘米**
    --   （在 80 厘米窗口内、也被放行 ⇒ 照样崩）⇒ **修正量大小不是触发条件**。
    --   按玩家的话「不要再因为害怕游戏崩掉而把功能屏蔽」⇒ **默认不限制**，
    --   这个键只留给"想保守一点"的人（填了米数就只吸窗口内的）。
    -- ---------------------------------------------------------------------
    local safe_cm = tonumber(cfg("buildsnap_safe_cm")) or 0.0
    if safe_cm > 0.0 and corr > safe_cm then
        BuildSnap.skipped = BuildSnap.skipped + 1
        if Log ~= nil and Log.solid ~= nil then
            pcall(Log.solid, string.format(
                "  [bsnap] ● 原样放行（没插手）: 这次要挪 %.0f 厘米 > 精细吸附窗口 %.0f 厘米"
                .. " ⇒ 没吸（游戏按你指的位置放）", corr, safe_cm))
        end
        Log.emit(string.format(
            "  [bsnap] 原样放行: 这次要挪 **%.0f 厘米**（精细吸附窗口 %.0f 厘米）⇒ 没吸。"
            .. " ① 摆得离投影那件更近（几十厘米内）再放；② 或按 H 重新对齐投影；"
            .. " ③ 想强行让它吸就把 `buildsnap_safe_cm` 调大（例 200）——"
            .. " 注意: 实测三次「重发把游戏搞崩」都发生在 **93 厘米以上**的搬运",
            corr, safe_cm))
        Log.flush()
        return
    end

    -- ★ 黑匣子: 这是"我们**开始改游戏行为**"的那一步 —— 必须留痕（规矩 3b）。
    if Log ~= nil and Log.solid ~= nil then
        pcall(Log.solid, string.format(
            "  [bsnap] ● 即将拦原请求: 目标记录 #%s 差 %.1f 厘米 → 把请求里的 id 改成 None",
            tostring(res.idx), res.dist or res.along or 0.0))
    end
    local blocked, block_how = BuildSnap.block_request(build_object_id)
    if Log ~= nil and Log.solid ~= nil then
        pcall(Log.solid, string.format("  [bsnap] ● 拦截结果: %s（%s）",
            blocked and "拦住了" or "没拦住", tostring(block_how)))
    end
    if not blocked then
        BuildSnap.block_fail = BuildSnap.block_fail + 1
        Log.emit(string.format(
            "  [bsnap] !! 没能拦住原请求（%s）→ **原样放行**（不会重复放置，但这次没吸上）",
            tostring(block_how)))
        Log.flush()
        return
    end

    -- ★★ 黑匣子（最关键的两行）: 重发这一行必须**先落盘**。
    --   ★ 它同时是"出事记忆"的**登记**: 正常返回会紧跟一行「● 重发返回」销账；
    --     下次启动读日志尾部，"有登记、没返回"就是"上一次就是在这一次重发里出事的"。
    --     ⇒ **改这一行的格式要同步改 learn_frozen_from_log 的解析**。
    local note = string.format("位置修正 %.0f 厘米%s",
        res.dist or res.along or 0.0,
        (snap_z_eff and lz ~= nil) and "（含高度）" or "")
    local job = {
        net = net, id = name_target, x = tx, y = ty, z = tz,
        qz = zq[1], qw = zq[2],
        rec_idx = res.idx, rec_t = res.rec.t, id_str = id_str,
        id_norm = id_norm_now, snap_z_eff = snap_z_eff,
        game_z = lz, target_z = tz, corr = res.dist or res.along or 0.0,
        -- ★ `.111`: `proj_z` = **投影里这一件的 z**（= res.z），跟"这次请求发的是谁的高度"
        --   无关 —— 「落地确认」的高度学习必须拿它当基准，否则"只吸 x/y"那一级
        --   （请求里带的是游戏自己的高度）留下的高度差永远看不出来 ✗
        proj_z = res.z, z_key = zkey,
        note = note,
    }

    -- ★★★ 2026-09-29 **机制改动: 重发排到下一帧**（`buildsnap_defer`，默认开）
    --
    -- 为什么（四次事故的共同点）: 卡死 1 次 + 崩 3 次，崩溃栈的最内层都是
    --   **UE4SS 的帧反复重复 = 深递归** —— 也就是"**在游戏的钩子回调里再回调游戏自己**"。
    --   而"修正量大小"已经被证明**不是**触发条件（44.9 厘米也崩）。
    --   ⇒ 钩子里**只负责拦下原请求**，把"按吸附坐标发一次"排到**下一帧**
    --     （那时原始调用已完全返回、调用栈是干净的）⇒ 从结构上消掉这个递归。
    --
    -- 风险（说清楚，别藏）:
    --   ① `extra_parameter_archives` 是**外层调用栈上的对象**，延后就不能再用 ⇒
    --      只在这个参数**确实是空的**时候延后（实测普通手放都是"空（0 项）"），
    --      非空 ⇒ 原样放行（不懂的请求不动它）；
    --   ② 延后意味着游戏会先把"被拦下那次请求"走完（屏幕可能闪一下提示）——
    --      这是这条路上唯一"看得见"的副作用；
    --   ③ 拿不到调度器时自动落回"立刻重发"（旧行为）。
    if (cfg("buildsnap_defer") ~= false) and (extra_empty == true) then
        local Sched = nil
        pcall(function() Sched = require("pwpr_sched") end)
        -- ★ 必须确认调度器**真的能把工作丢回游戏线程** —— 否则 `Sched.game_thread`
        --   会"直接执行"（inline），那就等于还是在钩子里嵌套调用，白改。
        if Sched ~= nil and Sched.game_thread ~= nil
            and (Sched.has_game_thread == true or Sched.has_game_thread_delay == true) then
            if Log ~= nil and Log.solid ~= nil then
                pcall(Log.solid, string.format(
                    "  [bsnap] ● 重发前 id=%s 改高度=%s 目标=(%.0f,%.0f,%.0f) "
                    .. "朝向 %.1f 度（**延后到下一帧发**；若之后没有「● 重发返回」"
                    .. "⇒ 就出事在这一次延后重发里）",
                    tostring(id_str), snap_z_eff and "是" or "否", tx, ty, tz, target_yaw))
            end
            BuildSnap.applied = BuildSnap.applied + 1
            Log.hot(string.format(
                "  [bsnap] 结果: 已**排好延后重发**（%s 模式，%s，差 %.1f 厘米，%s）"
                .. " → (%.1f,%.1f,%.1f) 朝向 %.1f 度",
                mode, tostring(res.rec.t), job.corr, dz_note, tx, ty, tz, target_yaw))
            local ok_sched = false
            pcall(function()
                Sched.game_thread(function() BuildSnap.run_deferred(job) end, 0)
                ok_sched = true
            end)
            if ok_sched then
                Log.flush()
                return
            end
            Log.emit("  [bsnap] !! 排延后重发失败 ⇒ 落回立刻重发（旧路）")
        end
    end

    if Log ~= nil and Log.solid ~= nil then
        pcall(Log.solid, string.format(
            "  [bsnap] ● 重发前 id=%s 改高度=%s 目标=(%.0f,%.0f,%.0f) "
            .. "朝向 %.1f 度（若后面没有「● 重发返回」⇒ **就卡在这一次重发里**）",
            tostring(id_str), snap_z_eff and "是" or "否", tx, ty, tz, target_yaw))
    end
    -- ★ 重发: 用普通 Lua 表 + FName（这两件事在同一环境里已被验证可用）
    --   ※ 我们自己发出去的这一次会再次进回调 —— 由 BuildSnap.busy 挡住。
    local okr, rerr = pcall(function()
        net:RequestBuild_ToServer(
            name_target,
            { X = tx, Y = ty, Z = tz },
            { X = 0.0, Y = 0.0, Z = zq[1], W = zq[2] },
            extra_params,
            { bNotConsumeMaterials = false })
    end)
    if Log ~= nil and Log.solid ~= nil then
        pcall(Log.solid, okr
            and "  [bsnap] ● 重发返回: OK（游戏自己那一步没有卡住）"
            or ("  [bsnap] ● 重发返回: 失败 " .. tostring(rerr)))
    end
    if okr then
        BuildSnap.applied = BuildSnap.applied + 1
        -- ★ 给玩家看的一句"这次到底改了多少"（反馈看不出来时，数字最直观）
        -- （`note` 在上面的 job 里已经算好，这里直接用）
        -- ★ 用 Log.hot（只进缓冲、不写控制台）—— 这是**每次都发生**的一行，
        --   而控制台 print 在 UE4SS 里是"窗口 + 另一份日志"的双重 I/O。
        Log.hot(string.format(
            "  [bsnap] 结果: 已改发到投影位置（%s 模式，%s，差 %.1f 厘米，%s）"
            .. " → (%.1f,%.1f,%.1f) 朝向 %.1f 度",
            mode, tostring(res.rec.t),
            (res.dist or res.along or 0.0), dz_note, tx, ty, tz, target_yaw))
        -- ★ 安排落地确认（1.2 秒后看有没有新建筑出现）
        -- ★ 同时告诉投影侧"这一条我正准备放上去" —— 投影侧会**立刻**把它
        --   从投影里藏起来（这样 1.2 秒的确认窗口里也不会闪）；万一游戏拒了，
        --   确认失败的回调会撤销这次隐藏。
        if BuildSnap.deps.on_placing ~= nil then
            pcall(BuildSnap.deps.on_placing, res.idx)
        end
        BuildSnap.schedule_confirm(string.format("%s @ (%.0f,%.0f,%.0f)",
            tostring(res.rec.t), tx, ty, tz), 1200, note, res.idx,
            { id = id_str, id_norm = id_norm_now, z_changed = snap_z_eff,
              game_z = lz, target_z = tz, proj_z = res.z, z_key = zkey })
        -- ★ 默认**不弹**（`buildsnap_notify`，2026-09-29 性能修复）:
        --   一次放置两条提示（这条 + 落地确认）都要在引擎侧"找控件/写文本/
        --   沿父链显示"，而且原来每步还写一次盘 ⇒ 和游戏自己的放置叠在一起就是卡。
        --   想要的每件反馈就把 buildsnap_notify 改成 true。
        if BuildSnap.deps.notify ~= nil
            and BuildSnap.deps.get ~= nil
            and BuildSnap.deps.get("buildsnap_notify") == true then
            BuildSnap.deps.notify(string.format("建造吸附: %s", note),
                string.format("build snap: corrected %.0f cm",
                    res.dist or res.along or 0.0))
        end
    else
        BuildSnap.requeue_fail = BuildSnap.requeue_fail + 1
        Log.emit("  [bsnap] !! 拦住成功但**重发失败** —— 这一次没放上（再点一下即可）: "
            .. tostring(rerr))
        Log.emit("  ★ 把这几行发给开发者")
    end
    Log.flush()
end

-- --------------------------------------------------------------------------
-- ★★★ 延后重发（2026-09-29 为"别再崩"做的**机制改动**，不是关功能）
--
-- 为什么: 四次事故（卡死 1 + 崩 3）的崩溃栈最内层都是 **UE4SS 的帧反复重复 = 深递归**
--   —— 也就是"在游戏的钩子回调里再回调游戏自己"。而"修正量大小"已被实测推翻
--   （44.9 厘米那次照样崩）⇒ 只改**结构**: 钩子只拦原请求，重发排到**下一帧**。
--
-- 这个函数在**干净的调用栈**上执行（原始请求早已返回），因此:
--   · 不会再有"钩子套钩子"的递归；
--   · 代价: `extra_parameter_archives`（外层栈上的对象）不能再用 ⇒ 传**空的**（`{}`）。
--     实测普通手放该参数本来就是"空（0 项）"，所以语义等价。
-- 自己发出去的这一次会**再次进钩子** ⇒ 用 `BuildSnap.busy` 挡住（和旧路一样）。
-- --------------------------------------------------------------------------
function BuildSnap.run_deferred(job)
    if type(job) ~= "table" then return end
    if Log ~= nil and Log.solid ~= nil then
        pcall(Log.solid, "  [bsnap] ● 延后重发: 开始执行（下一帧、干净栈）")
    end
    local ok_send, err = false, nil
    pcall(function()
        if not Util.valid(job.net) then
            err = "网络组件已失效"
            return
        end
        BuildSnap.busy = true          -- 挡住我们自己这一次调用再次进钩子
        local ok2, e2 = pcall(function()
            job.net:RequestBuild_ToServer(
                job.id,
                { X = job.x, Y = job.y, Z = job.z },
                { X = 0.0, Y = 0.0, Z = job.qz, W = job.qw },
                {},
                { bNotConsumeMaterials = false })
        end)
        BuildSnap.busy = false
        ok_send, err = ok2, e2
    end)
    if Log ~= nil and Log.solid ~= nil then
        pcall(Log.solid, ok_send
            and "  [bsnap] ● 重发返回: OK（延后重发没有出事）"
            or ("  [bsnap] ● 重发返回: 失败 " .. tostring(err)))
    end
    if not ok_send then
        BuildSnap.requeue_fail = BuildSnap.requeue_fail + 1
        BuildSnap.applied = math.max((BuildSnap.applied or 1) - 1, 0)
        Log.emit("  [bsnap] !! 延后重发失败 —— 这一次没放上（再点一下即可）: "
            .. tostring(err))
        Log.flush()
        return
    end
    -- 记账 + 通知投影侧 + 排落地确认（和旧路一致）
    Log.hot(string.format(
        "  [bsnap] 结果: 已改发到投影位置（延后重发，差 %.1f 厘米，%s）→ (%.1f,%.1f,%.1f)",
        job.corr, job.snap_z_eff and "含高度" or "不含高度", job.x, job.y, job.z))
    if BuildSnap.deps.on_placing ~= nil then
        pcall(BuildSnap.deps.on_placing, job.rec_idx)
    end
    BuildSnap.schedule_confirm(string.format("%s @ (%.0f,%.0f,%.0f)",
        tostring(job.rec_t), job.x, job.y, job.z), 1200, job.note, job.rec_idx,
        { id = job.id_str, id_norm = job.id_norm, z_changed = job.snap_z_eff,
          game_z = job.game_z, target_z = job.target_z,
          proj_z = job.proj_z, z_key = job.z_key })
    if BuildSnap.deps.notify ~= nil and BuildSnap.deps.get ~= nil
        and BuildSnap.deps.get("buildsnap_notify") == true then
        BuildSnap.deps.notify(string.format("建造吸附: %s", job.note),
            string.format("build snap: corrected %.0f cm", job.corr))
    end
    Log.flush()
end

-- --------------------------------------------------------------------------
-- ★ 落地确认: "游戏到底有没有真的把这块建出来"
--
-- 为什么必须做（2026-09-29 第三次实测的教训）:
--   我们的日志写"已改发到投影位置"，屏幕也提示了，**但实际上什么都没建出来** ——
--   因为游戏（服务端）把这次请求拒了（位置不合法/太远），而我们从 Lua 侧
--   只看到"调用没报错"，就以为成功了。这种"假成功"最误导人。
--   ⇒ 用 UE4SS 的 `NotifyOnNewObject` 监听新出现的 PalBuildObject:
--     收到 ⇒ 真的建出来了；1.2 秒内没收到 ⇒ 大概率被拒（写日志 + 提示玩家）。
-- --------------------------------------------------------------------------

BuildSnap.new_object_ok = 0      -- 收到过多少次"新建 PalBuildObject"
BuildSnap.confirmed = 0          -- 其中确认属于我们改发的次数
BuildSnap.lost = 0               -- 改发后没等到新建筑的次数（= 很可能被游戏拒了）

--- 注册"新建建筑"通知（没有这个 API 就跳过，只是少一层确认）
function BuildSnap.install_confirm()
    if BuildSnap.confirm_installed then return true, "已注册过" end
    if type(NotifyOnNewObject) ~= "function" then
        return false, "本 UE4SS 版本没有 NotifyOnNewObject（不做落地确认）"
    end
    local ok, err = pcall(function()
        NotifyOnNewObject("/Script/Pal.PalBuildObject", function(obj)
            pcall(function()
                BuildSnap.new_object_ok = BuildSnap.new_object_ok + 1
                -- ★★ 2026-09-29: 改成**先进先出**认领（原来只有一个槽位）。
                --   为什么: 放得快的时候（玩家"每隔一秒放一块"），新的会**覆盖**旧的，
                --   被覆盖那一次的确认永远不会跑 ⇒ 偶尔有一块没被处理。
                --   通知本身不知道是哪一次放置造成的，但**放置是有顺序的**
                --   ⇒ 认领"最早那个还没确认的"。
                local claimed = nil
                local list = BuildSnap.pending_confirms
                if list ~= nil then
                    for i = 1, #list do
                        local e = list[i]
                        if e.done ~= true then
                            e.done = true
                            -- ★ 把 actor 句柄留着（给"拆掉检测"用）。注意: 这一刻它的
                            --   位置/类型还没填好（§49），但**对象身份本身**是可靠的。
                            e.actor = obj
                            claimed = e
                            break
                        end
                    end
                end
                if Log ~= nil then
                    Log.line(string.format(
                        "  [bsnap] ← 新建筑出现（第 %d 次通知）%s%s",
                        BuildSnap.new_object_ok,
                        claimed ~= nil and claimed.target or "",
                        (claimed == nil and list ~= nil and #list > 0)
                            and "（没有待确认的了，可能是别的来源建的）" or ""))
                end
            end)
            -- ★ 投影侧: 我们**已经知道**这一次是往哪一条记录放的
            --   ⇒ 立刻把它藏起来（投影侧收到 on_placing 时做的），不用重扫。
            --   这里只把"通知真的来了"这件事交给投影侧（可选）。
            if BuildSnap.deps.on_new_object ~= nil then
                pcall(BuildSnap.deps.on_new_object, obj)
            end
        end)
    end)
    if not ok then
        return false, "注册失败: " .. tostring(err)
    end
    BuildSnap.confirm_installed = true
    return true, "已注册（会报告「到底建出来没有」）"
end

--- 安排一次"1.2 秒后检查"（改发成功之后调用）
--- extra_note: 给玩家看的一句话（例: 「位置修正 48 厘米（含高度）」）
--- rec_idx: 这次改发瞄准的是**哪一条投影记录**（投影侧要靠它精确隐藏那一件）
--- info: 可选表 `{ id=游戏给的建筑 id, id_norm=归一化 id, z_changed=这次有没有改高度,
---                   proj_z=投影里这一件的 z, z_key=降级记忆的键（id+这一处） }`
---   —— "被游戏拒了就降级"的阶梯要用它（见 `BuildSnap.z_denied` 的说明）
function BuildSnap.schedule_confirm(target_desc, delay_ms, extra_note, rec_idx, info)
    if BuildSnap.confirm_installed ~= true then return end
    -- ★ 先进先出队列（放得快时不会互相覆盖 —— 这是"偶尔漏一块"的根因之一）
    if BuildSnap.pending_confirms == nil then BuildSnap.pending_confirms = {} end
    local pc = { done = false, target = target_desc,
                 note = extra_note, rec_idx = rec_idx }
    if type(info) == "table" then
        pc.id = info.id
        pc.id_norm = info.id_norm
        pc.z_changed = (info.z_changed == true)
        pc.game_z = info.game_z
        pc.target_z = info.target_z
        pc.proj_z = info.proj_z
        pc.z_key = info.z_key
    end
    local list = BuildSnap.pending_confirms
    list[#list + 1] = pc
    local Sched = nil
    pcall(function() Sched = require("pwpr_sched") end)
    local function check()
        pcall(function()
            -- 从队列里摘掉自己（可能已经被别的确认流程摘掉了）
            if BuildSnap.pending_confirms ~= nil then
                local q = BuildSnap.pending_confirms
                for i = #q, 1, -1 do
                    if q[i] == pc then table.remove(q, i) end
                end
                if #q > 40 then table.remove(q, 1) end   -- 防御: 队列不无限长
            end
            if pc.done == true then
                BuildSnap.confirmed = BuildSnap.confirmed + 1
                Log.emit("  [bsnap] ✓ 落地确认: 游戏真的建出来了（"
                    .. tostring(pc.target) .. "）")
                -- ★ 投影侧: "这一条已经放上了 ⇒ 不再画"（精确到记录序号，不用重扫）
                if BuildSnap.deps.on_placed_confirmed ~= nil then
                    pcall(BuildSnap.deps.on_placed_confirmed, pc.rec_idx,
                        pc.actor)
                end
                -- ★★★ 2026-10-09 新增: **高度学习**（玩家实测: 投影低于海平面、游戏建到合法高度，
                --   而投影没跟着挪 ⇒ 上面建筑放不下去）。
                --   做法: 拿**游戏实际建出来的 z** 与**投影里这一件的 z**（`pc.proj_z`）比 ——
                --   差 ≥5cm 说明游戏把高度改了 ⇒ 走已有的"挪投影高度"那条路
                --   （`on_z_rejected`）把整份投影抬上去 ✓
                --   ★ `.111` 起基准从"我们请求的 z"改成"**投影里这一件的 z**" —— 因为
                --     "只吸 x/y"那一级请求里带的是**游戏自己**的高度，两者一比永远相等
                --     ⇒ 高度学习在最需要它的那条路上**从来不生效**（玩家 `.110` 实测 ✗）。
                --   ★ 一处 + 一类只学一次（`z_learned`）: 否则"每放一件都挪一点"会累积漂移。
                --   开关: `buildsnap_learn_z`（默认 true）；上限仍受 `buildsnap_z_max_cm` 约束 ✓
                pcall(function()
                    local learn = true
                    if BuildSnap.deps.get ~= nil then
                        local v = BuildSnap.deps.get("buildsnap_learn_z")
                        if v == false then learn = false end
                    end
                    local ref = pc.proj_z
                    if type(ref) ~= "number" then ref = pc.target_z end
                    if learn and pc.actor ~= nil and type(ref) == "number" then
                        local loc = nil
                        pcall(function() loc = pc.actor:K2_GetActorLocation() end)
                        local az = nil
                        pcall(function()
                            if loc ~= nil then az = tonumber(loc.Z) or tonumber(loc.z) end
                        end)
                        if az ~= nil then
                            local dz = az - ref
                            if math.abs(dz) >= 5.0 then
                                local lk = tostring(pc.z_key or pc.id_norm or "")
                                if BuildSnap.z_learned[lk] == true then
                                    Log.emit(string.format(
                                        "  [bsnap] 高度学习: 投影 z=%.1f 游戏实际 z=%.1f"
                                        .. " 差 %+.1f 厘米（这一处已经学过 ⇒ **不再挪**，避免累积漂移）",
                                        ref, az, dz))
                                else
                                    BuildSnap.z_learned[lk] = true
                                    Log.emit(string.format(
                                        "  [bsnap] 高度学习: 投影 z=%.1f 游戏实际 z=%.1f 差 %+.1f 厘米"
                                        .. " ⇒ 把投影高度挪过去", ref, az, dz))
                                    if BuildSnap.deps.on_z_rejected ~= nil then
                                        pcall(BuildSnap.deps.on_z_rejected,
                                            tostring(pc.id or ""), dz,
                                            "按游戏实际建出的高度学习")
                                    end
                                end
                            end
                        end
                    end
                end)
                -- ★ 也给屏幕一行 —— 玩家 2026-09-29 反馈"看不出来到底有没有生效"，
                --   所以把"游戏确认建出 + 这次修正了多少"直接摆到屏幕上。
                -- ★ 同样默认不弹（见 buildsnap_notify_confirm 的注释）
                if BuildSnap.deps.notify ~= nil
                    and BuildSnap.deps.get ~= nil
                    and BuildSnap.deps.get("buildsnap_notify_confirm") == true then
                    BuildSnap.deps.notify(string.format("✓ 已建出：%s",
                        tostring(pc.note or "已按投影落位")), "build confirmed")
                end
            else
                BuildSnap.lost = BuildSnap.lost + 1
                Log.emit(string.format(
                    "  [bsnap] !! 改发之后 1.2 秒内**没有**新建筑出现 ⇒ 游戏拒绝了"
                    .. "这次放置（%s）。常见原因: ① **素材不足**（游戏左下角会自己提示；"
                    .. "蓝图模式建的是【投影里那一件】的类型，指着箱子/工厂就会要它们的料）"
                    .. " ② 位置不合法（悬空/重叠/太远）。这一下等于没放上 —— "
                    .. "手里有对应材料、位置也合适时再试", tostring(pc.target)))
                if BuildSnap.deps.notify ~= nil then
                    BuildSnap.deps.notify("吸附后的位置游戏不认可（这次没放上）",
                        "build placed position rejected by game")
                end
                -- ★★ 高度自适应 / 降级阶梯（玩家 2026-09-29 定稿）:
                --   这次**改了高度**还是被游戏拒了 ⇒ **先试着把投影高度挪到游戏允许的位置**
                --   （`deps.on_z_rejected` = 改偏移 + 重画投影 + 弹提示），挪成功就
                --   **不降级**（下次照常吸高度，只是高度基准被修正了）；
                --   挪不了 / **这一处**已经挪过一次还是被拒 ⇒ 退到"这一类只吸 x/y"（`z_denied`）。
                --   ★ 前两级都**故意不设**"这条记录刚被拒"的闸（闸 ③）—— 让玩家马上
                --     再放一次就能用上修正后的策略；等到"不改高度"也被拒了才落回闸 ③。
                --   ★★ `.111` 起记忆的键是 `pc.z_key`（**这一类 + 这一处投影**）——
                --     旧代码只按 id 记 ⇒ 换一处之后第一次放置就被判"挪过了"⇒ 直接降级
                --     ⇒ **投影再也不跟着挪**（玩家 `.110` 实测，见 `pwpr_buildsnap.lua` 顶部说明）。
                if pc.rec_idx ~= nil then
                    local idn = pc.id_norm
                    local zk = tostring(pc.z_key or idn or "")
                    local zcase = (pc.z_changed == true) and type(idn) == "string"
                        and idn ~= ""
                    if zcase and BuildSnap.z_shifted[zk] ~= true then
                        local dz = nil
                        if type(pc.game_z) == "number" and type(pc.target_z) == "number" then
                            dz = pc.game_z - pc.target_z
                        end
                        local moved = false
                        if dz ~= nil and BuildSnap.deps.on_z_rejected ~= nil then
                            pcall(function()
                                moved = BuildSnap.deps.on_z_rejected(pc.id, dz,
                                    "吸附后的高度游戏不认（这次没放上）") == true
                            end)
                        end
                        if moved == true then
                            BuildSnap.z_shifted[zk] = true
                            Log.emit(string.format(
                                "  [bsnap] ★ 高度自适应: %s 吸附的高度被拒 ⇒ 已把**投影高度"
                                .. "挪 %+.0f 厘米**（对齐到游戏允许的高度）⇒ **再放一次**即可"
                                .. "（高度继续跟投影）", tostring(pc.id), dz))
                        else
                            BuildSnap.z_denied[zk] = true
                            Log.emit(string.format(
                                "  [bsnap] 这次「改了高度」被游戏拒了，而且**挪不了投影高度**"
                                .. "（%s；若上面那行写了「超过上限」就是差得太多）"
                                .. "⇒ **这一处**的 %s 之后只吸 x/y。**马上再放一次**"
                                .. "就是降级后的策略；想恢复吸高度: **换一处 / 换一张蓝图会自动"
                                .. "恢复**（或删掉/移走 pwpr.log 后重启）",
                                (dz == nil) and "读不到高度差" or "回调没挪成",
                                tostring(pc.id)))
                        end
                    elseif zcase then
                        BuildSnap.z_denied[zk] = true
                        Log.emit(string.format(
                            "  [bsnap] **这一处**已经为 %s 挪过一次投影高度、这次还是被拒"
                            .. " ⇒ **这一处**的 %s 之后只吸 x/y（高度改由「高度学习」"
                            .. "在真正放上去之后自动校准）；**换一处 / 换一张蓝图会自动恢复**",
                            tostring(pc.id), tostring(pc.id)))
                    else
                        -- ★ 记住"这一条刚被游戏拒绝过"（闸 ③ 用: 短时间内不再吸它）
                        if BuildSnap.rejected == nil then BuildSnap.rejected = {} end
                        BuildSnap.rejected[pc.rec_idx] = os.clock()
                    end
                end
                -- ★ 投影侧: 刚才是"先按预测藏起来"的 —— 游戏没建出来就得**撤销**
                if BuildSnap.deps.on_placed_failed ~= nil then
                    pcall(BuildSnap.deps.on_placed_failed, pc.rec_idx)
                end
                Log.flush()
            end
        end)
    end
    if Sched ~= nil and Sched.game_thread ~= nil then
        -- 排到稍后执行（不阻塞这次放置）
        pcall(function() Sched.game_thread(check, delay_ms or 1200) end)
    else
        pcall(check)
    end
end

-- --------------------------------------------------------------------------
-- 注册 / 状态
-- --------------------------------------------------------------------------

--- 注册钩子。返回 ok, 说明
function BuildSnap.install()
    if BuildSnap.installed then
        return true, "已注册过（跳过）"
    end
    if type(RegisterHook) ~= "function" then
        return false, "这个 UE4SS 版本没有 RegisterHook"
    end
    local ok, pre_id, post_id = pcall(function()
        return RegisterHook(BuildSnap.HOOK_PATH, function(...)
            -- ★ 重入闸: 我们"拦原请求 + 自己重发"里的那次重发会再次进到这里
            --   ⇒ 必须挡住，否则会无限递归。
            if BuildSnap.busy then return end
            BuildSnap.busy = true
            -- ★ 回调里再包一层 pcall: 任何异常都只记日志，绝不影响放置
            local ok2, err = pcall(BuildSnap.on_request_build, ...)
            BuildSnap.busy = false
            if not ok2 then
                BuildSnap.skipped = BuildSnap.skipped + 1
                Log.emit("  [bsnap] !! 回调内部出错（已忽略，放置照常）: "
                    .. tostring(err))
                Log.flush()
            end
        end)
    end)
    if not ok then
        return false, "RegisterHook 抛错: " .. tostring(pre_id)
    end
    BuildSnap.installed = true
    BuildSnap.hook_ids = { pre_id, post_id }
    -- ★ 顺带学一次"上一次会话卡死在哪一类建筑的重发上"（卡死记忆，见上方说明）
    pcall(BuildSnap.learn_frozen_from_log)
    -- 顺带注册"新建建筑"通知（落地确认用；没有这个 API 就只少一层确认）
    local okc, whyc = BuildSnap.install_confirm()
    return true, string.format("pre_id=%s post_id=%s; 落地确认: %s",
        tostring(pre_id), tostring(post_id),
        okc and "已注册" or tostring(whyc))
end

--- 状态行（F7 用）
function BuildSnap.status_lines()
    local out = {}
    local mode = "?"
    if BuildSnap.deps.get ~= nil then
        mode = tostring(BuildSnap.deps.get("buildsnap_mode"))
    end
    out[#out + 1] = string.format(
        "建造吸附: %s | 模式=%s | 钩子=%s | 请求 %d 次"
        .. "（改发 %d / 够准不插手 %d / 干跑 %d / 放过 %d / 拦不住 %d / 重发失败 %d）",
        BuildSnap.deps.get and tostring(BuildSnap.deps.get("buildsnap_enabled")) or "?",
        mode, BuildSnap.installed and "已注册" or "未注册",
        BuildSnap.fired, BuildSnap.applied, BuildSnap.already_ok or 0,
        BuildSnap.would_apply, BuildSnap.skipped, BuildSnap.block_fail,
        BuildSnap.requeue_fail)
    -- ★ 降级阶梯 / 卡死记忆的状态（F7 一眼能看到"哪一类被降级了"）
    do
        local frz, zdn = {}, {}
        for k, v in pairs(BuildSnap.frozen or {}) do
            frz[#frz + 1] = string.format("%s=%s", tostring(k),
                (v == 2) and "不插手" or "只吸x/y")
        end
        for k in pairs(BuildSnap.z_denied or {}) do
            -- ★ `.111` 起键是 `id|蓝图@x,y` —— 这里只显示 id（不然一行太长）
            zdn[#zdn + 1] = tostring(k):gsub("|.*$", "")
        end
        if #frz > 0 or #zdn > 0 then
            out[#out + 1] = string.format(
                "建造吸附降级: 卡死记忆[%s] 这一处被拒后降级[%s]（换一处/换蓝图自动恢复；重置: 删掉 pwpr.log）",
                (#frz > 0) and table.concat(frz, ", ") or "无",
                (#zdn > 0) and table.concat(zdn, ", ") or "无")
        end
    end
    if BuildSnap.confirm_installed == true then
        out[#out + 1] = string.format(
            "  落地确认: 收到新建通知 %d 次（改发后确认成功 %d / 没等到 %d）",
            BuildSnap.new_object_ok, BuildSnap.confirmed, BuildSnap.lost)
    else
        out[#out + 1] = "  落地确认: 不可用（本 UE4SS 版本没有 NotifyOnNewObject）"
    end
    if BuildSnap.last ~= nil then
        out[#out + 1] = string.format(
            "  最近一次: id=%s → 记录 %s（%s 模式），差 %.1f 厘米",
            tostring(BuildSnap.last.id), tostring(BuildSnap.last.t),
            tostring(BuildSnap.last.mode), BuildSnap.last.dist or 0.0)
    end
    local ids = {}
    for k, n in pairs(BuildSnap.ids_seen) do ids[#ids + 1] = { k = k, n = n } end
    if #ids > 0 then
        table.sort(ids, function(a, b)
            if a.n ~= b.n then return a.n > b.n end
            return a.k < b.k
        end)
        local seg = {}
        for i = 1, math.min(#ids, 6) do
            seg[#seg + 1] = string.format("%s×%d", ids[i].k, ids[i].n)
        end
        out[#out + 1] = "  见过的建筑 id: " .. table.concat(seg, "  ")
    end
    return out
end

function BuildSnap.describe()
    return string.format("建造吸附: %s（钩子 %s，请求 %d 次，改发 %d）",
        BuildSnap.installed and "开启" or "未注册",
        BuildSnap.installed and "ok" or "-", BuildSnap.fired, BuildSnap.applied)
end

return BuildSnap
