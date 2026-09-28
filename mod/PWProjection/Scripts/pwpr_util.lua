--[[ ===========================================================================
  PWPR · util  ——  纯工具层（不主动调用任何"有副作用"的引擎函数）

  设计约束（来自 3 次真实崩溃的教训，见 docs/踩坑记录.md）:
    1. 读属性一律走 pcall —— 读不存在的属性在 UE4SS 上返回"占位对象"而非 nil，
       所以判定"对象有效"必须用 IsValid()，不能靠"读到了"。
    2. StaticFindObject 永远不能写成 pcall(StaticFindObject, "路径")。
       必须 pcall(function() return StaticFindObject("路径") end)。
    3. 本文件不做任何 Spawn / Set / Destroy —— 它只读。
=========================================================================== ]]

local Util = {}

Util.TAG = "[PWPR]"

--- ★ 统一的"类型/建筑 id 归一化"。
---
--- 为什么要放进 Util（2026-09-29）: 投影侧（判断"这一件是不是已经放上了"）
--- 和建造吸附侧都要拿它比类型名 —— 两处必须**完全同一套规则**，
--- 否则会出现"吸附认为同类、隐藏认为不同类"这种自相矛盾的行为。
--- 规则（顺序很重要，踩过坑见 `踩坑记录.md` §39）:
---   去容器前缀 → 去 `_C` 蓝图后缀 → 转小写 → 去掉所有非字母数字 → 再去 `bpbuildobject`/`buildobject` 前缀。
---   ⚠️ 一定要**先去掉 `_C` 再去分隔符**，否则 `BP_BuildObject_Wood_Foundation_C`
---      转小写后前缀匹配不上（下划线还在）。
function Util.norm_id(s)
    if s == nil then return "" end
    s = tostring(s)
    s = s:gsub("^.*[/%.]", "")
    s = s:gsub("_C$", "")
    s = s:lower()
    s = s:gsub("[^%w]", "")
    s = s:gsub("^bpbuildobject", "")
    s = s:gsub("^buildobject", "")
    return s
end

--- ★ 构建标记（每改一次"玩家看得见的行为"就 +1）。
---
--- 为什么要有它（2026-09-29 的教训）: 玩家实测反馈"还是老样子"，
--- 我读了日志才发现**部署的还是上一版**（工作区 44189 字节 / 游戏目录 35450 字节），
--- 白白浪费一轮。日志里没有"这是哪一版"的标记，就很容易误判成"功能没修好"。
--- ⇒ 现在启动时固定打一行 `构建标记: <日期.序号>`，F7 里也有；
---   看日志第一眼就能确认"跑的到底是哪一版"。
--- 规矩: **改了功能就把它 +1**（只改注释/文档不用动）。
Util.BUILD = "2026-09-29.51"

-- --------------------------------------------------------------------------
-- 路径
-- --------------------------------------------------------------------------

local function source_path()
    local info = debug.getinfo(1, "S")
    local src = (info and info.source) or ""
    return (src:gsub("^@", ""))
end

local SRC = source_path()

--- 本 mod 的 Scripts 目录（绝对路径，无尾部分隔符）
Util.script_dir = SRC:match("^(.*)[/\\][^/\\]*$") or "."

--- 本 mod 的根目录（Scripts 的上一级）
Util.mod_dir = Util.script_dir:match("^(.*)[/\\][^/\\]*$") or Util.script_dir

function Util.join(dir, name)
    if dir == nil or dir == "" then return tostring(name) end
    if dir:sub(-1) == "\\" or dir:sub(-1) == "/" then
        return dir .. tostring(name)
    end
    return dir .. "\\" .. tostring(name)
end

--- 只保留可打印 ASCII（写控制台用；中文会变成 ?）
function Util.ascii(s)
    s = tostring(s)
    local out = {}
    for i = 1, #s do
        local c = s:byte(i)
        if c >= 32 and c <= 126 then
            out[#out + 1] = string.char(c)
        elseif c >= 128 then
            out[#out + 1] = "?"
        end
    end
    return table.concat(out)
end

-- --------------------------------------------------------------------------
-- 引擎对象访问（全部 pcall 包裹）
-- --------------------------------------------------------------------------

--- UE4SS 有时把 UObject 包在 userdata 里，需要 :get() 取出真对象
function Util.unwrap(v)
    if v == nil then return nil end
    local ok, r = pcall(function() return v:get() end)
    if ok and r ~= nil then return r end
    return v
end

--- 唯一可靠的"对象有效"判据
function Util.valid(v)
    v = Util.unwrap(v)
    if v == nil then return false end
    local ok, r = pcall(function() return v:IsValid() end)
    return ok and r == true
end

--- 读属性。返回 nil 表示读取抛错；注意【返回非 nil 不代表属性存在】
function Util.prop(v, key)
    v = Util.unwrap(v)
    if v == nil then return nil end
    local ok, r = pcall(function() return v[key] end)
    if ok then return r end
    return nil
end

function Util.full_name(v)
    v = Util.unwrap(v)
    if v == nil then return nil end
    local ok, r = pcall(function() return v:GetFullName() end)
    if ok and type(r) == "string" and r ~= "" then return r end
    return nil
end

--- 取路径最后一段，例如 "SM_WoodFoundation"
function Util.short_name(v)
    local f = Util.full_name(v)
    if f == nil then return nil end
    return (f:match("([^%.]+)$") or f)
end

--- UClass 对象上 IsValid() 有时返回 false，但反射仍可用（SBB 同款处理）
function Util.usable_class(v)
    v = Util.unwrap(v)
    if v == nil then return false end
    if Util.valid(v) then return true end
    local f = Util.full_name(v)
    if type(f) ~= "string" then return false end
    return f:find("Class", 1, true) ~= nil
end

--- ★ "能用"判据（比 IsValid 宽松，比 nil 检查严格）
---
--- 为什么需要它: **实测反复证明 `IsValid()` 在这个游戏的组件/资产/材质上
--- 会把好对象判为无效。** 已经因此踩过两次:
---   1. 网格覆盖率从 26/79 掉到 4/35（建筑 Mesh 组件被判无效）
---   2. 投影画出来是 UE 的 WorldGridMaterial 灰白格子（Highlight 材质被判无效，
---      于是 SetMaterial 被静默跳过）
---
--- 判据: IsValid() 通过 【或者】 GetFullName() 能调通 —— 后者是 PWRecon
--- 长期验证过的、更贴近"这个对象真的存在"的判据。
---
--- ⚠️ 但【生命周期】判断必须用 Util.valid，不能用这个：
---   一个已经被销毁的 Actor，GetFullName() 有时仍然能调通，
---   拿它去调方法就是野指针 -> 访问违例。
---   所以:
---     · "这个 Actor 还活着吗"       -> Util.valid    （严格）
---     · "这个资产/组件/材质能用吗" -> Util.usable   （宽松）
function Util.usable(v)
    v = Util.unwrap(v)
    if v == nil then return false end
    if Util.valid(v) then return true end
    return Util.full_name(v) ~= nil
end

--- 找当前的 UWorld —— ★ **不用 UEHelpers.GetWorld()**。
---
--- 为什么（2026-09-28 崩溃的根因，证据是 UEHelpers.lua 源码本身）:
---   UEHelpers.GetWorld() 的实现是:
---       local PC = UEHelpers.GetPlayerController()   -- 内部用 IsValid() 过滤
---       if PC:IsValid() then return PC:GetWorld() end
---   而 **IsValid() 在"已被销毁的对象"上也会返回 true**（本项目记过的老坑）——
---   于是"回标题 → 重进世界"之后，它会拿**上个世界的废 PlayerController**
---   去调 GetWorld() → EXCEPTION_ACCESS_VIOLATION（垃圾地址）。
---   ⇒ 改成 FindFirstOf("World"): UE4SS 自己遍历对象表，不经过那层 IsValid 过滤。
function Util.find_world()
    -- ★ 首选: 从【严格校验过的 PlayerController】取世界。
    --   为什么比 FindFirstOf("World") 好:
    --     ① 它一定是**游戏世界**（PlayerController 就在里面），
    --        而 FindFirstOf("World") 在存在多个 World 时挑哪个不确定；
    --     ② PC 先过 Util.valid（严格判据）⇒ 不会在废对象上调方法。
    --   （UEHelpers 自己的实现也是 PC:GetWorld()，只是它用会撒谎的 IsValid 过滤 PC。）
    local pc = Util.find_pc_strict()
    if pc ~= nil then
        local w = nil
        pcall(function() w = pc:GetWorld() end)
        w = Util.unwrap(w)
        if Util.valid(w) then return w end
    end

    -- 兜底: UE4SS 自己遍历对象表找第一个 World（不经过那层 IsValid 过滤）
    local w2 = nil
    pcall(function() w2 = FindFirstOf("World") end)
    w2 = Util.unwrap(w2)
    if Util.valid(w2) then return w2 end

    -- 最后手段: 退回 UEHelpers（可能给到废对象，所以只当兜底）
    local ok, res = pcall(function() return require("UEHelpers").GetWorld() end)
    if ok then
        res = Util.unwrap(res)
        if Util.valid(res) then return res end
    end
    return nil
end

--- 严格地找一个 PlayerController（不依赖会撒谎的 IsValid）。
--- 先用 FindAllOf + Util.valid（本项目的严格判据），UEHelpers 只当兜底。
function Util.find_pc_strict()
    -- ★★ 实测（2026-09-28 玩家日志）: 世界里存在**多个** PlayerController，
    --   `FindAllOf("PlayerController")` 的返回顺序不定，而且
    --   `IsLocalPlayerController` 在 UE4SS 里**取不到**（调不通）——
    --   所以"取第一个"会每次拿到不同的那个。
    --   ⇒ 判据换成**"这个 PC 有没有 Pawn"**（只有玩家自己的那个才有），
    --     并按全名排序做确定性兜底。这个函数只用于"拿一个能用的 PC / 它所在的世界"，
    --     **不要**用它派生"世代标记"（那已经被证明不可靠，见 pwpr_ghost.stale_world）。
    local best, best_name = nil, nil
    local ok, list = pcall(function() return FindAllOf("PlayerController") end)
    if ok and type(list) == "table" then
        for i = 1, #list do
            local v = Util.unwrap(list[i])
            if Util.valid(v) then
                local has_pawn = false
                pcall(function()
                    local pawn = v.Pawn
                    has_pawn = (pawn ~= nil) and Util.valid(Util.unwrap(pawn))
                end)
                local local_ok = false
                pcall(function()
                    if v.IsLocalPlayerController ~= nil then
                        local_ok = v:IsLocalPlayerController() == true
                    end
                end)
                local fn = Util.full_name(v)
                if type(fn) ~= "string" then fn = tostring(v) end
                local rank = 0
                if has_pawn then rank = 2 elseif local_ok then rank = 1 end
                if best == nil then
                    best, best_name = v, fn
                elseif rank > 0 then
                    -- 有 Pawn / 被判定为本机 PC 的优先；同档按名字取最小的（确定性）
                    local best_rank = 0
                    pcall(function()
                        local bp = best.Pawn
                        if (bp ~= nil) and Util.valid(Util.unwrap(bp)) then best_rank = 2 end
                    end)
                    if rank > best_rank or (rank == best_rank and fn < best_name) then
                        best, best_name = v, fn
                    end
                end
            end
        end
    end
    if best ~= nil then return best end

    local ok2, pc = pcall(function()
        return require("UEHelpers").GetPlayerController()
    end)
    pc = ok2 and Util.unwrap(pc) or nil
    if Util.valid(pc) then return pc end
    return nil
end

--- 当前世界的"标签"（一个字符串）。
---
--- ★★ 为什么需要它（2026-09-27 崩溃换来的教训）:
---   回标题 / 换存档之后，上个世界的对象**已经被引擎销毁**。
---   而 `Util.usable()` 在那种已销毁的对象上**可能返回 true**
---   （内存还没被复用）—— 代码会以为旧控件还好好的 → SetText → 访问违例。
---   ⇒ 判断"对象是否还有效"的唯一安全办法: **不碰对象**，
---     改成比较"世界标签"这个**字符串**。
---
--- ★★★ 2026-09-28 第二次教训（"每次都 0 件"的事故）:
---   第一版我用了 `FindFirstOf("World")` —— **它每次返回的对象可能不一样**
---   （对象表里有多个 World 时不稳定），于是连续两次取标签就不相等:
---     · 刚建好的投影在 apply_transform 里被判"换世界"→ 整个丢掉 → "0 件"；
---     · 通知控件每次都以为是新世界 → 重建 → 旧的堆在屏幕上。
---   ⇒ 改成用 **PlayerController 的地址**:
---     ① 每个世界都会新建一个 PC ⇒ 世界一换，地址必变（正是要的世代信号）；
---     ② 同一个世界内稳定不变 ⇒ 不会自己跟自己不相等；
---     ③ `tostring()` 读的是 Lua 侧 userdata 里的地址，**完全不碰引擎** ⇒
---        对已销毁对象也安全（这是关键，用 GetFullName 就可能崩）。
function Util.world_tag()
    local pc = Util.find_pc_strict()
    if pc ~= nil then return tostring(pc) end
    local w = Util.find_world()
    if w ~= nil then return tostring(w) end
    return "no-tag"
end

--- 安全取数字字段（K2_GetActorLocation 返回的是"带键的表"，#v == 0）
function Util.num(v, key)
    v = Util.unwrap(v)
    if v == nil then return nil end
    local ok, r = pcall(function() return v[key] end)
    if ok and type(r) == "number" then return r end
    return nil
end

function Util.loc_of(obj)
    if obj == nil then return nil end
    local ok, loc = pcall(function() return obj:K2_GetActorLocation() end)
    if not ok or loc == nil then return nil end
    local x = Util.num(loc, "X")
    if x == nil then return nil end
    return x, Util.num(loc, "Y") or 0.0, Util.num(loc, "Z") or 0.0
end

function Util.rot_of(obj)
    if obj == nil then return 0.0, 0.0, 0.0 end
    local ok, rot = pcall(function() return obj:K2_GetActorRotation() end)
    if not ok or rot == nil then return 0.0, 0.0, 0.0 end
    return Util.num(rot, "Pitch") or 0.0,
           Util.num(rot, "Yaw") or 0.0,
           Util.num(rot, "Roll") or 0.0
end

function Util.yaw_of(obj)
    local _, yaw, _ = Util.rot_of(obj)
    return yaw
end

-- --------------------------------------------------------------------------
-- 建筑类型名
-- --------------------------------------------------------------------------

--- BlueprintGeneratedClass /Game/.../BP_BuildObject_Wood_Foundation.BP_BuildObject_Wood_Foundation_C
---   -> Wood_Foundation
function Util.type_from_class_full(cls_full)
    if type(cls_full) ~= "string" then return nil end
    local last = cls_full:match("([^%.]+)$") or cls_full
    last = last:gsub("_C$", "")
    last = last:gsub("^BP_BuildObject_", "")
    if last == "" then return nil end
    return last
end

function Util.type_of(obj)
    local ok, cls = pcall(function() return obj:GetClass() end)
    if not ok or cls == nil then return nil end
    local cls_full = Util.full_name(cls)
    if cls_full == nil then return nil end
    return Util.type_from_class_full(cls_full), cls_full
end

--- 反向：短类型名 -> 蓝图类对象路径（不含 _C 后缀，StaticFindObject 两种都试）
function Util.class_path_candidates(short_type)
    local base = "/Game/Pal/Blueprint/MapObject/BuildObject/BP_BuildObject_"
        .. tostring(short_type)
    return {
        base .. "." .. tostring(short_type):gsub("^.*%.", "") .. "_C",
        base .. ".BP_BuildObject_" .. tostring(short_type) .. "_C",
    }
end

-- --------------------------------------------------------------------------
-- 变换（FTransform 用普通表表示 —— 实测可用，见 SBB 的 IDENTITY_TRANSFORM）
-- --------------------------------------------------------------------------

function Util.identity_transform()
    return {
        Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
        Translation = { X = 0.0, Y = 0.0, Z = 0.0 },
        Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
    }
end

function Util.quat_yaw(deg)
    local h = math.rad(deg or 0.0) * 0.5
    return { X = 0.0, Y = 0.0, Z = math.sin(h), W = math.cos(h) }
end

function Util.transform_at(x, y, z, yaw_deg, scale)
    local s = scale or 1.0
    return {
        Rotation = Util.quat_yaw(yaw_deg),
        Translation = { X = x or 0.0, Y = y or 0.0, Z = z or 0.0 },
        Scale3D = { X = s, Y = s, Z = s },
    }
end

-- --------------------------------------------------------------------------
-- 数字 / 字符串
-- --------------------------------------------------------------------------

function Util.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function Util.round(v, digits)
    local m = 10 ^ (digits or 0)
    if v >= 0 then return math.floor(v * m + 0.5) / m end
    return -math.floor(-v * m + 0.5) / m
end

--- 归一化到 -180..180
function Util.norm_yaw(d)
    d = (d or 0.0) % 360.0
    if d > 180.0 then d = d - 360.0 end
    return d
end

--- 文件名安全化（ASCII，仅保留字母数字与 _ -）
function Util.slug(s, max_len)
    s = tostring(s or "")
    s = s:gsub("[^%w%-_]", "_")
    s = s:gsub("_+", "_")
    s = s:gsub("^_+", ""):gsub("_+$", "")
    if s == "" then s = "blueprint" end
    max_len = max_len or 60
    if #s > max_len then s = s:sub(1, max_len) end
    return s
end

-- --------------------------------------------------------------------------
-- 时间
-- --------------------------------------------------------------------------

function Util.now_iso()
    local ok, s = pcall(function() return os.date("!%Y-%m-%dT%H:%M:%SZ") end)
    if ok and type(s) == "string" then return s end
    return "unknown"
end

function Util.now_stamp()
    local ok, s = pcall(function() return os.date("!%Y%m%d-%H%M%S") end)
    if ok and type(s) == "string" then return s end
    local ok2, t = pcall(function() return os.time() end)
    if ok2 and type(t) == "number" then return tostring(t) end
    return "0"
end

-- --------------------------------------------------------------------------
-- 文件 IO（io.open 是本 UE4SS 版本已验证可用的，PWRecon 长期在用）
-- --------------------------------------------------------------------------

function Util.file_exists(path)
    local f = io.open(path, "rb")
    if f == nil then return false end
    f:close()
    return true
end

--- 返回 内容 或 nil, 错误
function Util.read_file(path)
    local f, err = io.open(path, "rb")
    if f == nil then return nil, tostring(err) end
    local data = f:read("*a")
    f:close()
    if data == nil then return nil, "read returned nil" end
    data = data:gsub("^\239\187\191", "")   -- 去 UTF-8 BOM
    return data
end

--- with_bom 默认 true —— 带中文的 JSON 用记事本打开才不乱码
function Util.write_file(path, text, with_bom)
    local f, err = io.open(path, "wb")
    if f == nil then return false, tostring(err) end
    if with_bom ~= false then f:write("\239\187\191") end
    f:write(text)
    f:close()
    return true
end

function Util.append_file(path, text)
    local f, err = io.open(path, "ab")
    if f == nil then return false, tostring(err) end
    f:write(text)
    f:close()
    return true
end

function Util.remove_file(path)
    local ok = pcall(function() os.remove(path) end)
    return ok
end

--- 建目录。Lua 标准库没有 mkdir，用 os.execute（SBB 同款做法）。
--- mkdir 在"目录已存在"时返回非 0，所以这里不把返回值当失败，
--- 真正的判据是随后的写探针（Util.dir_writable）。
function Util.mkdir(path)
    if path == nil or path == "" then return false, "empty path" end
    if path:find('"', 1, true) or path:find("[\r\n]") then
        return false, "unsafe path"
    end
    pcall(function() os.execute('mkdir "' .. path .. '" >nul 2>nul') end)
    local probe = Util.join(path, ".__pwpr_write_probe")
    local ok, err = Util.write_file(probe, "probe", false)
    if not ok then return false, tostring(err) end
    Util.remove_file(probe)
    return true
end

--- 目录是否可写（写探针，用完删掉）
function Util.dir_writable(path)
    if path == nil or path == "" then return false end
    local probe = Util.join(path, ".__pwpr_write_probe")
    local ok = Util.write_file(probe, "probe", false)
    if not ok then return false end
    Util.remove_file(probe)
    return true
end

return Util
