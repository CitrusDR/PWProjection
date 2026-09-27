--[[ ===========================================================================
  PWBP · meshmap  ——  建筑类型 -> 静态网格资产

  问题:
    实测 79 种建筑类型里只有 26 种能从 actor 上直接读到 StaticMesh。
    剩下的是【结构件】（地基/墙/屋顶…）—— Palworld 为了性能把它们
    交给 BP_PalStaticMeshImposterChunk 的 HISM 批量绘制，所以单个
    PalBuildObject 上没有 Mesh 组件。

  做法（不写死猜测，尽量靠运行时事实）:
    1. 运行时把已加载的 UStaticMesh 建成注册表（FindAllOf("StaticMesh")）
       —— 这些网格在你有基地的时候必然已经加载，所以注册表是"真的"。
    2. 蓝图里 mesh 字段（短名）能直接命中注册表 -> 用它。
    3. 结构件走【名字匹配】: 类型名 Wood_Foundation 拆成 wood + foundation，
       在注册表里找同时包含这两个词、且位于 Architecture 目录下的网格。
       规范化后比较（去掉 _ 和大小写），所以 SM_WoodFoundation 也能匹配。
    4. 用户可以在 pwbp_meshmap.json 里写死映射，优先于自动匹配。
    5. 探测键会把注册表整个导出成 pwbp_meshes.txt，方便把匹配结果
       固化成静态表（下一版就不用每次靠猜）。

  注意: 本文件只做 FindAllOf + GetFullName（只读）。LoadAsset 只在
        真正要渲染时才会被调用。
=========================================================================== ]]

local Util = require("pwbp_util")
local Json = require("pwbp_json")

local MeshMap = {}

MeshMap.registry_ready = false
MeshMap.by_short = {}        -- 短名(小写) -> 完整 "Package.Object" 路径
MeshMap.entries = {}         -- { {short=, path=, norm=, folder=}, ... }
MeshMap.overrides = {}       -- 用户手写映射: type -> path
MeshMap.cache = {}           -- type -> path（解析结果缓存）
MeshMap.resolve_stats = { hit_actor = 0, hit_override = 0, hit_name = 0, miss = 0 }
MeshMap.last_build_error = nil

-- --------------------------------------------------------------------------
-- 名字处理
-- --------------------------------------------------------------------------

--- "StaticMesh /Game/A/B.SM_X" -> "/Game/A/B.SM_X"
function MeshMap.asset_path_from_full(full)
    if type(full) ~= "string" then return nil end
    local p = full:match("(/[%w_/%.%-]+%.[%w_%-%.]+)$")
    if p == nil then
        p = full:match("(/[%w_/%.%-]+)$")
    end
    if p == nil then return nil end
    p = p:gsub("%s+$", "")
    return p
end

local function normalize(s)
    return tostring(s):lower():gsub("[^%a%d]", "")
end

-- --------------------------------------------------------------------------
-- ★ 注意声明顺序！
--
--   Lua 的 local 只对【出现位置之后】的代码可见。
--   如果把 VERSION_TOKEN / SYNONYMS 写在 type_keywords 后面，
--   type_keywords 里的 SYNONYMS 就会解析成【全局变量】= nil，
--   运行时才炸 "attempt to index a nil value (global 'SYNONYMS')"。
--
--   2026-09-26 22:14 真实踩过这个坑。所以这两个表必须放在使用它们的
--   type_keywords 之前。
-- --------------------------------------------------------------------------

--- 版本号/序号词：出现在类型名末尾，但不属于"部件名"，匹配时要丢掉
local VERSION_TOKEN = { v2 = true, v3 = true, v4 = true, v5 = true,
                        ["01"] = true, ["02"] = true, ["03"] = true,
                        ["04"] = true, ["05"] = true, ["06"] = true }

--- 语义同义词：蓝图类型名的用词和资产名不一样，必须人工补。
--- ★ 这是从真实资产清单里看出来的（见 tools/meshmatch_sim.py 的验证）：
---   Palworld 的"地基"资产叫 SM_Floor_Wood，不叫 Foundation。
---   不补这一条，351 块地基一块都画不出来。
local SYNONYMS = {
    foundation = "floor",     -- Wood_Foundation -> SM_Floor_Wood
    doorwall   = "door",      -- Wood_DoorWall   -> SM_Door_Wood
    wallgate   = "gate",      -- 兜底（camel 拆分已能处理）
}

--- 把 CamelCase 拆成小词: WindowWall -> {"window","wall"}
--- 为什么要拆: 蓝图类型名是 CamelCase（Wood_WindowWall），
--- 而资产名是下划线分隔（SM_WallWindow_Wood）。不拆就永远匹配不上。
local SEP = "\1"

local function camel_split(word)
    local s = tostring(word)
    s = s:gsub("(%l)(%u)", "%1" .. SEP .. "%2")      -- aB -> a|B
    s = s:gsub("(%u)(%u%l)", "%1" .. SEP .. "%2")    -- ABc -> A|Bc
    local out = {}
    for w in s:gmatch("[^" .. SEP .. "]+") do
        if w ~= "" then out[#out + 1] = w:lower() end
    end
    if #out == 0 then out[1] = s:lower() end
    return out
end

--- 类型名 -> (材料词, 关键词列表)
local function type_keywords(type_name)
    local words = {}
    for chunk in tostring(type_name):gmatch("[^_]+") do
        local parts = camel_split(chunk)
        for i = 1, #parts do words[#words + 1] = parts[i] end
    end
    if #words == 0 then return nil, {} end

    local material = SYNONYMS[words[1]] or words[1]
    local parts = {}
    for i = 2, #words do
        local w = words[i]
        if not VERSION_TOKEN[w] and not w:match("^v?%d+$") then
            w = SYNONYMS[w] or w
            if #w >= 3 then parts[#parts + 1] = w end
        end
    end
    if #parts == 0 then
        -- 关键词全是版本号（Spa_2 / ItemChest_03），或本来就是单词类型（CampFire）
        parts = { material }
    end
    return material, parts
end

-- --------------------------------------------------------------------------
-- 注册表
-- --------------------------------------------------------------------------

--- 建/重建注册表。只读操作。返回 条目数 或 nil, 错误
function MeshMap.build_registry(force)
    if MeshMap.registry_ready and not force then
        return #MeshMap.entries
    end
    MeshMap.by_short = {}
    MeshMap.skeletal_by_short = {}
    MeshMap.entries = {}

    -- ★★ 2026-09-26 深夜: 这里原来只枚举 StaticMesh。
    --   结果【所有用骨骼网格的建筑都从注册表里消失了】——
    --   后期工厂 / 磨粉机 / 碎冰机 / 石油钻机 / 古代发电机……
    --   它们的资产是 SK_ 开头的 SkeletalMesh，我们从来没枚举过，
    --   所以按名字永远匹配不到，看起来像"这些建筑没有网格资产"。
    --   玩家实测证据: 低级工厂(Factory_Hard_02)用 SM_WorkBenchModern（静态），
    --   后期工厂用 SK_PalSphereFactoryFuturistic（骨骼）—— 确实有差异。
    local CLASSES = { "StaticMesh", "SkeletalMesh" }
    local n = 0
    local n_skel = 0
    for ci = 1, #CLASSES do
        local ok, objs = pcall(function() return FindAllOf(CLASSES[ci]) end)
        if ok and type(objs) == "table" then
            for i = 1, #objs do
                local full = Util.full_name(objs[i])
                if full ~= nil then
                    local path = MeshMap.asset_path_from_full(full)
                    if path ~= nil and path:find("/Game/", 1, true) then
                        local short = path:match("([^%.]+)$") or path
                        local folder = path:match("^(.*)/[^/]+$") or ""
                        local e = {
                            short = short,
                            path = path,
                            norm = normalize(short),
                            folder = folder,
                            skeletal = (CLASSES[ci] == "SkeletalMesh"),
                        }
                        MeshMap.entries[#MeshMap.entries + 1] = e
                        local k = short:lower()
                        if MeshMap.by_short[k] == nil then
                            MeshMap.by_short[k] = path
                        end
                        if e.skeletal then
                            MeshMap.skeletal_by_short[k] = true
                        end
                        n = n + 1
                        if e.skeletal then n_skel = n_skel + 1 end
                    end
                end
            end
        else
            MeshMap.last_build_error = "FindAllOf(\""
                .. CLASSES[ci] .. "\") 失败"
        end
    end
    MeshMap.n_skeletal = n_skel

    MeshMap.registry_ready = true
    MeshMap.cache = {}
    MeshMap.buckets = {}
    MeshMap.resolve_stats = { hit_actor = 0, hit_override = 0, hit_name = 0, miss = 0 }
    return n
end

--- 这个网格路径是不是骨骼网格（SkeletalMesh）？
---
--- ★ 为什么需要: 骨骼网格【不能实例化】（ISM 只吃 StaticMesh），
---   渲染方式完全不同，所以 Ghost 必须提前知道走哪条路。
---   判断依据是注册表里记录的资产类型，不是名字前缀 ——
---   名字前缀（SK_）是约定不是保证，靠约定判断会静默出错。
function MeshMap.is_skeletal(path)
    if path == nil then return false end
    local s = tostring(path)
    local short = s:match("([^%.]+)$") or s
    if MeshMap.skeletal_by_short == nil then return false end
    return MeshMap.skeletal_by_short[short:lower()] == true
end

--- 按"材料词"分桶（惰性建立）。
--- 为什么需要: 注册表动辄几万个网格，而 match_by_name 要为每个建筑类型
--- 扫一遍。79 个类型 × 3 万条 = 数百万次字符串查找，会把游戏主线程卡住几秒。
--- 先按第一个词（材料）分桶，之后每次只需扫几百条。
function MeshMap.bucket(material)
    if MeshMap.buckets == nil then MeshMap.buckets = {} end
    local b = MeshMap.buckets[material]
    if b ~= nil then return b end
    b = {}
    for i = 1, #MeshMap.entries do
        local e = MeshMap.entries[i]
        if e.norm:find(material, 1, true) then
            b[#b + 1] = e
        end
    end
    MeshMap.buckets[material] = b
    return b
end

function MeshMap.lookup_short(short_name)
    if type(short_name) ~= "string" or short_name == "" then return nil end
    if not MeshMap.registry_ready then
        local ok = pcall(MeshMap.build_registry)
        if not ok then return nil end
    end
    return MeshMap.by_short[short_name:lower()]
end

-- --------------------------------------------------------------------------
-- 覆盖表
--
-- 分成两个文件，各管各的:
--   pwbp_meshmap.default.json  —— 随 mod 分发，每次部署都会覆盖成最新版
--   pwbp_meshmap.json          —— 用户自己的，部署时【绝不覆盖】
-- 合并规则: 先读 default，再读用户表，用户表覆盖 default。
--
-- ★ 为什么改成分两个文件（2026-09-26 深夜踩的坑）:
--   原来只有一个 pwbp_meshmap.json，部署脚本为了"保护用户修改"就
--   只在文件不存在时复制。结果我把条目从 7 条扩到 33 条之后，
--   游戏里那份还是旧的 7 条 —— 部署"成功"了，功能却没更新。
--   日志里露出来的证据是 `网格覆盖表: 覆盖表 7 条`（应该是 33 条）。
-- --------------------------------------------------------------------------

function MeshMap.override_path(script_dir)
    return Util.join(script_dir, "pwbp_meshmap.json")
end

function MeshMap.default_path(script_dir)
    return Util.join(script_dir, "pwbp_meshmap.default.json")
end

--- 读一个映射文件并并进 MeshMap.overrides。返回 加载条数, 说明
local function load_map_file(path, label)
    if not Util.file_exists(path) then
        return 0, label .. ": 不存在"
    end
    local text, err = Util.read_file(path)
    if text == nil then return 0, label .. ": 读失败 " .. tostring(err) end
    local parsed, perr = Json.decode(text)
    if type(parsed) ~= "table" then
        return 0, label .. ": 解析失败 " .. tostring(perr)
    end
    local n = 0
    for k, v in pairs(parsed) do
        -- 下划线开头的键是给人看的注释，不参与映射
        if type(k) == "string" and k:sub(1, 1) ~= "_" then
            -- ★ 值可以是【字符串】也可以是【字符串数组】。
            --   数组的意义: 有些建筑由多个网格拼成（实测「简约门」=
            --   门框 SM_DoorBase_SF + 左门扇 SM_Door_L_SF + 右门扇 SM_Door_R_SF），
            --   只写一个会画出半扇门。这是玩家反馈后加的。
            local list = nil
            if type(v) == "string" and v ~= "" then
                list = { v }
            elseif type(v) == "table" then
                list = {}
                for i = 1, #v do
                    if type(v[i]) == "string" and v[i] ~= "" then
                        list[#list + 1] = v[i]
                    end
                end
                if #list == 0 then list = nil end
            end
            if list ~= nil then
                MeshMap.overrides[k] = list
                n = n + 1
            end
        end
    end
    return n, string.format("%s: %d 条", label, n)
end

function MeshMap.load_overrides(script_dir)
    MeshMap.overrides = {}
    MeshMap.cache = {}
    -- 先 default（可能被用户表覆盖），再用户表
    local _, note_a = load_map_file(MeshMap.default_path(script_dir), "内置表")
    local _, note_b = load_map_file(MeshMap.override_path(script_dir), "用户表")
    local total = 0
    for _ in pairs(MeshMap.overrides) do total = total + 1 end
    return total, string.format("%s / %s -> 合计 %d 条",
        tostring(note_a), tostring(note_b), total)
end

-- --------------------------------------------------------------------------
-- 名字匹配（结构件用）
-- --------------------------------------------------------------------------

--- 导出已加载的材质清单（挑投影材质用）。
---
--- 为什么需要: 实测证明我们拿到的 MI_LooksPredicatorNormal **确实设上去了**
--- （有回读证据），但玩家看到的不是期望的半透明轮廓。
--- 那就得换材质 —— 而"有哪些材质可选"只有游戏自己知道。
--- 所以顺手把候选列出来，不用再靠猜名字。
function MeshMap.material_dump_lines(max_lines)
    local out = {}
    out[#out + 1] = "## 4. 已加载的材质（挑投影材质用）"
    out[#out + 1] = ""

    local kinds = { "MaterialInstanceConstant", "MaterialInstance", "Material" }
    local seen, n_total = {}, 0
    for k = 1, #kinds do
        local ok, objs = pcall(function() return FindAllOf(kinds[k]) end)
        if ok and type(objs) == "table" then
            for i = 1, #objs do
                local full = Util.full_name(objs[i])
                if full ~= nil then
                    local path = full:match("(/[%w_/%.%-]+%.[%w_%-%.]+)$")
                    if path ~= nil and not seen[path] then
                        seen[path] = true
                        n_total = n_total + 1
                    end
                end
            end
        end
    end

    local wanted = {}
    for p in pairs(seen) do
        if p:find("/BuildingProcess/", 1, true)
            or p:find("Predicator", 1, true)
            or p:find("/BuildObject/", 1, true) then
            wanted[#wanted + 1] = p
        end
    end
    table.sort(wanted)

    out[#out + 1] = string.format(
        "已加载材质总数 %d，其中与建筑/预览相关的 %d 个:", n_total, #wanted)
    out[#out + 1] = ""
    local lim = math.min(#wanted, max_lines or 200)
    for i = 1, lim do out[#out + 1] = "  " .. wanted[i] end
    if #wanted > lim then
        out[#out + 1] = string.format("  ... 还有 %d 个", #wanted - lim)
    end
    return out
end

--- ★★ 从【网格组件反查宿主建筑类型】—— 找缺失建筑资产的终极手段。
---
--- 背景（2026-09-26 更深夜，玩家问"缺失资产还有办法拿出来吗"）:
---   有些建筑 `obj.Mesh` 是 nil、名字又猜不到，看起来无从下手。
---   但是: **建筑画得出来 ⇒ 一定有个网格组件在画它 ⇒ 那个组件一定存在**。
---   而且 UE4SS 给的组件全名长这样:
---       StaticMeshComponent /Game/.../PL_MainWorld5.PL_MainWorld5:PersistentLevel
---                          .BP_BuildObject_WeaponFactory_Dirty_4_C_2147482000.Mesh
---   —— 宿主建筑的类型名就写在里面！
---
---   所以反过来做: 枚举世界上所有网格组件，从每个组件的全名里解析出
---   `BP_BuildObject_<类型>_C`，再读它的 StaticMesh —— 直接得到
---   【类型 -> 网格】的对应关系。**完全不需要猜名字。**
---
--- 只读。组件多的时候会慢几秒（有上限保护）。
function MeshMap.component_mesh_lines(max_lines)
    local out = {}
    out[#out + 1] = "## 5. 从网格组件反查【建筑类型 -> 网格】（找缺失资产用）"
    out[#out + 1] = ""
    out[#out + 1] = "做法: 枚举世界上所有网格组件，从组件全名里解析出宿主建筑的类型名"
    out[#out + 1] = "（BP_BuildObject_<类型>_C），再读它用的 StaticMesh。"
    out[#out + 1] = "这条路【不依赖】PalBuildObject.Mesh，也不靠猜名字 —— "
    out[#out + 1] = "只要建筑画得出来，就一定能查出来。"
    out[#out + 1] = ""

    -- 组件类名要多试几个: FindAllOf 是按类名精确匹配的
    local classes = {
        "StaticMeshComponent",
        "InstancedStaticMeshComponent",
        "HierarchicalInstancedStaticMeshComponent",
        "SkeletalMeshComponent",
    }

    -- 第 1 节的注册表集合，用来判断"组件在用的网格是否被枚举到了"
    -- （字段名是 MeshMap.entries，不是 registry —— 写错会静默返回空表，
    --   那样"枚举不全"的检测就永远报不出来。这里用 _G 风格的自检避免静默失败。）
    local in_registry = {}
    local n_reg = 0
    if type(MeshMap.entries) == "table" then
        for i = 1, #MeshMap.entries do
            local e = MeshMap.entries[i]
            if e and e.path then
                in_registry[e.path] = true
                n_reg = n_reg + 1
            end
        end
    end

    -- 类型 -> { 网格路径 -> 组件数 }
    local by_type, type_order = {}, {}
    -- 非建筑的宿主（关卡物体、特效……）: 宿主类名 -> 组件数
    local other = { n = 0, meshes = {}, classes = {} }
    local n_comp, n_mesh, capped = 0, 0, false
    -- 带骨骼的组件也要统计（有些机器是动画的，用 SkeletalMesh 而不是 StaticMesh）
    local n_skeletal = 0
    local CAP = 30000

    for k = 1, #classes do
        local ok, objs = pcall(function() return FindAllOf(classes[k]) end)
        if ok and type(objs) == "table" then
            for i = 1, #objs do
                if n_comp >= CAP then capped = true break end
                local comp = Util.unwrap(objs[i])
                if Util.usable(comp) then
                    n_comp = n_comp + 1
                    -- ★ 同时读 StaticMesh 和 SkeletalMesh。
                    --   原来只读 StaticMesh，于是【动画的机器】（例如带运转部件的
                    --   生产设备）会因为用的是 SkeletalMesh 而被整个跳过 ——
                    --   表现得像"这台机器没有网格组件"。
                    local mesh = Util.unwrap(Util.prop(comp, "StaticMesh"))
                    local mpath = Util.full_name(mesh)
                    if mpath == nil then
                        mesh = Util.unwrap(Util.prop(comp, "SkeletalMesh"))
                        mpath = Util.full_name(mesh)
                        if mpath ~= nil then n_skeletal = n_skeletal + 1 end
                    end
                    if mpath ~= nil then
                        n_mesh = n_mesh + 1
                        local cfull = Util.full_name(comp) or ""
                        -- ★★ 2026-09-26 修复的真 bug:
                        --   这里原来写的是 "BP_BuildObject_([%w]+)_C"，
                        --   而 **Lua 的 %w 不包含下划线**！
                        --   所以这个模式只能匹配【没有下划线】的类型名，
                        --   带下划线的（WeaponFactory_Dirty_4、
                        --   SphereFactory_Black_04、Factory_Hard_4、
                        --   TableDresser01_Stone……）全部漏掉，
                        --   而且不报错 —— 表现得像"这些建筑没有网格组件"。
                        --   正是这一类"静默漏掉"最难发现。
                        --   改成先按 _C_<数字> 精确定位，再退回宽松匹配。
                        local t = cfull:match("BP_BuildObject_([%w_]-)_C_%d+")
                        if t == nil then
                            t = cfull:match("BP_BuildObject_([%w_]+)_C")
                        end
                        if t ~= nil then
                            local e = by_type[t]
                            if e == nil then
                                e = {}
                                by_type[t] = e
                                type_order[#type_order + 1] = t
                            end
                            e[mpath] = (e[mpath] or 0) + 1
                        else
                            other.n = other.n + 1
                            other.meshes[mpath] = (other.meshes[mpath] or 0) + 1
                            -- 记下宿主类名，用来找"没按 BP_BuildObject_ 命名"的建筑
                            local actor = cfull:match("PersistentLevel%.([^%.]+)%.")
                            if actor ~= nil then
                                local cls = actor:gsub("_%d+$", "")
                                other.classes[cls] = (other.classes[cls] or 0) + 1
                            end
                        end
                    end
                end
            end
        end
    end

    table.sort(type_order)
    out[#out + 1] = string.format(
        "扫了网格组件 %d 个（其中能读到网格的 %d 个）%s", n_comp, n_mesh,
        capped and ("  ★ 已达上限 " .. tostring(CAP) .. "，结果不完整") or "")
    out[#out + 1] = string.format(
        "第 1 节注册表里有 %d 个网格可用来对照", n_reg)
    out[#out + 1] = string.format(
        "解析出宿主建筑类型的组件: %d 个，涉及 %d 种建筑类型",
        n_comp - other.n, #type_order)
    out[#out + 1] = ""

    -- 当前覆盖表已有的类型
    local known = {}
    if type(MeshMap.overrides) == "table" then
        for t in pairs(MeshMap.overrides) do known[t] = true end
    end

    out[#out + 1] = "=== ★★★ 查到了、但覆盖表里【还没有】的类型（照着填进 pwbp_meshmap.json）==="
    local n_new = 0
    for i = 1, #type_order do
        local t = type_order[i]
        if not known[t] then
            local e = by_type[t]
            -- 取组件数最多的那个网格
            local best, bestn = nil, -1
            for p, c in pairs(e) do
                if c > bestn then best, bestn = p, c end
            end
            -- ★ 必须归一化成 "Package.Object" 形式再输出 ——
            --   GetFullName() 带类名前缀（"StaticMesh /Game/..."），
            --   直接填进映射表会读不到。
            local bpath = MeshMap.asset_path_from_full(best) or best
            n_new = n_new + 1
            out[#out + 1] = string.format("  \"%s\": \"%s\",", t, tostring(bpath))
        end
    end
    if n_new == 0 then
        out[#out + 1] = "  （没有新的 —— 说明能查到的都已在覆盖表里）"
    end
    out[#out + 1] = ""

    out[#out + 1] = "=== 全部【建筑类型 -> 网格】==="
    out[#out + 1] = string.format("%-38s %6s  %s", "建筑类型", "组件", "网格")
    out[#out + 1] = string.rep("-", 120)
    local shown = 0
    for i = 1, #type_order do
        local t = type_order[i]
        for p, c in pairs(by_type[t]) do
            shown = shown + 1
            if shown > (max_lines or 200) then break end
            local npath = MeshMap.asset_path_from_full(p) or p
            -- ★ 区分两件事，否则会误报:
            --   · 路径不在 /Game/ 下 -> 注册表【按设计】只收 /Game/（见 build_registry
            --     里的 path:find("/Game/")），这是正常的，不是"枚举不全"
            --   · 在 /Game/ 下却不在第 1 节里 -> 那才是真的枚举不全
            local mark
            if not npath:find("/Game/", 1, true) then
                mark = "  （非 /Game/ 路径，注册表按设计不收，正常）"
            elseif in_registry[npath] then
                mark = ""
            else
                mark = "  ★不在第1节(枚举不全!)"
            end
            out[#out + 1] = string.format("%-38s %6d  %s%s", t, c, npath, mark)
        end
        if shown > (max_lines or 200) then
            out[#out + 1] = string.format("... 还有更多（超过 %d 行）", max_lines or 200)
            break
        end
    end
    out[#out + 1] = ""
    out[#out + 1] = string.format(
        "非建筑宿主的组件 %d 个（上面按类型统计），它们不在本表里。", other.n)
    if n_skeletal > 0 then
        out[#out + 1] = string.format(
            "其中 %d 个组件用的是 SkeletalMesh（动画机器）—— 这些以前会被整个跳过。",
            n_skeletal)
    end
    out[#out + 1] = ""
    out[#out + 1] = "=== 非建筑宿主里【名字像生产设备/工厂】的宿主类 ==="
    out[#out + 1] = "（如果那些找不到的建筑改成别的命名了，就会在这里露面）"
    local KEYS = { "factory", "mill", "crusher", "product", "recycl",
                   "generator", "pump", "machine", "assembly", "craft",
                   "display", "character", "workbench", "station" }
    local cls_list = {}
    for c, cnt in pairs(other.classes) do
        local low = c:lower()
        if low:find("buildobject", 1, true) then
            cls_list[#cls_list + 1] = { c = c, n = cnt, why = "BuildObject" }
        else
            for k = 1, #KEYS do
                if low:find(KEYS[k], 1, true) then
                    cls_list[#cls_list + 1] = { c = c, n = cnt, why = KEYS[k] }
                    break
                end
            end
        end
    end
    table.sort(cls_list, function(a, b) return a.c < b.c end)
    if #cls_list == 0 then
        out[#out + 1] = "  （没有）"
    else
        for i = 1, math.min(#cls_list, 120) do
            local e = cls_list[i]
            out[#out + 1] = string.format("  %-52s 组件 %4d   (命中 %s)",
                e.c, e.n, e.why)
        end
        if #cls_list > 120 then
            out[#out + 1] = string.format("  ... 还有 %d 个", #cls_list - 120)
        end
    end
    out[#out + 1] = ""
    out[#out + 1] = "★ 标记「不在第1节」的网格 = 第 1 节的全量网格清单里没有它 ——"
    out[#out + 1] = "  这说明 FindAllOf(\"StaticMesh\") 枚举不全，那才是我们真正的盲区。"
    return out
end

--- 导出【实例化网格组件实际在用的网格】。
---
--- ★ 为什么需要这一节（2026-09-26 更深夜，玩家问"缺失的资产还有办法拿出来吗"）:
---   有些建筑（结构件、工厂类）不是挂在 PalBuildObject 的 Mesh 组件上画的，
---   而是由 ISM / HISM（BP_PalStaticMeshImposterChunk 之类）批量绘制。
---   结果就是: `obj.Mesh` 是 nil、按名字又猜不到资产名 —— 看起来像"读不到"。
---
---   但那些网格【一定已经加载了】，否则画面里不会出现。
---   所以换个方向取证: 直接问"哪些网格正在被实例化组件使用"。
---   这一节列出来的就是【真正在画东西的网格】，从里面找就能对上号。
---
--- 只读（FindAllOf + 读属性 + GetInstanceCount）。这一节可能要几秒。
function MeshMap.ism_dump_lines(max_lines)
    local out = {}
    out[#out + 1] = "## 5. 实例化网格组件（ISM/HISM）实际在用的网格"
    out[#out + 1] = ""
    out[#out + 1] = "为什么要有这一节: 有些建筑（结构件、工厂类）不是用 PalBuildObject"
    out[#out + 1] = "上的 Mesh 组件画的，而是由 ISM/HISM 批量绘制。这一节列出【真正在画"
    out[#out + 1] = "东西的那些网格】—— 如果某个找不到的类型出现在这里，它的资产名就找到了。"
    out[#out + 1] = ""
    out[#out + 1] = "另一个用途: 拿这份清单和上面的「全部网格」（第 1 节）对比 ——"
    out[#out + 1] = "如果这里有第 1 节没有的网格，说明 FindAllOf(\"StaticMesh\") 枚举不全。"
    out[#out + 1] = ""

    local classes = {
        "InstancedStaticMeshComponent",
        "HierarchicalInstancedStaticMeshComponent",
    }
    local agg, order = {}, {}
    local n_comp_total = 0
    local per_class = {}
    -- 安全上限: 基地一大，实例化组件可能有几万个。这一节是诊断用的，
    -- 不值得为了它把游戏主线程卡十几秒。超了就停，并在输出里说明。
    local CAP = 20000
    local capped = false

    for k = 1, #classes do
        local ok, objs = pcall(function() return FindAllOf(classes[k]) end)
        local cnt = 0
        if ok and type(objs) == "table" then
            for i = 1, #objs do
                if n_comp_total >= CAP then capped = true break end
                local comp = Util.unwrap(objs[i])
                if Util.usable(comp) then
                    n_comp_total = n_comp_total + 1
                    cnt = cnt + 1
                    local mesh = Util.unwrap(Util.prop(comp, "StaticMesh"))
                    local mpath = Util.full_name(mesh)
                    if mpath ~= nil then
                        local e = agg[mpath]
                        if e == nil then
                            local inst = nil
                            pcall(function() inst = comp:GetInstanceCount() end)
                            e = {
                                n_comp = 0,
                                n_inst = tonumber(inst) or 0,
                                -- 组件全名里就带着宿主 Actor 的名字，不用额外取 Owner
                                sample = Util.full_name(comp) or "?",
                                cls = classes[k],
                            }
                            agg[mpath] = e
                            order[#order + 1] = mpath
                        end
                        e.n_comp = e.n_comp + 1
                    end
                end
            end
        end
        per_class[#per_class + 1] = string.format("%s=%d", classes[k], cnt)
    end

    table.sort(order)
    out[#out + 1] = string.format("实例化组件共 %d 个（%s）%s",
        n_comp_total, table.concat(per_class, " / "),
        capped and ("  ★ 已达上限 " .. tostring(CAP) .. "，结果不完整") or "")
    out[#out + 1] = string.format("它们用到的不同网格: %d 个", #order)
    out[#out + 1] = ""
    out[#out + 1] = string.format("%-30s %6s %8s  %s",
        "网格短名", "组件数", "实例数", "完整路径")
    out[#out + 1] = string.rep("-", 130)
    local lim = math.min(#order, max_lines or 300)
    for i = 1, lim do
        local p = order[i]
        local e = agg[p]
        local short = p:match("([^%.]+)$") or p
        out[#out + 1] = string.format("%-30s %6d %8d  %s",
            short, e.n_comp, e.n_inst, p)
    end
    if #order > lim then
        out[#out + 1] = string.format("... 还有 %d 个", #order - lim)
    end
    return out
end

--- 在注册表里按"材料词 + 关键词"找网格。
--- 返回 path, 分数, 并列数   （并列数 == -1 表示"并列到无法判定，已放弃"）
---
--- ★ 这里的规则是在【真实数据上离线验证过】才写进来的，
---   验证脚本: tools/meshmatch_sim.py（用 79 种真实类型 + 2310 个真实网格跑）
---
--- 三条规则，每条都是被真实数据教出来的:
---   1. 候选必须在 /Architecture/ 目录下。
---      不加这条会匹配到 SM_IceBlock / SM_Electricity01 / SM_Relic_Monkey
---      这类完全不相关的东西（都在别的目录下）。
---   2. 【严格】命中所有关键词 + 材料词，没有"放宽一轮"。
---      曾经加过 relaxed 轮（只要求第一个关键词），结果
---      HatchingPalEgg -> SM_PalSpa、FarmBlockRecipe -> SM_IceBlock —— 纯垃圾。
---   3. 同分并列时取名字最短的；如果连长度都一样 -> 放弃，返回 nil。
---      宁可这一件画不出来，也不要张冠李戴。
---
--- 实测效果（tools/meshmatch_sim.py 的输出）:
---   · 7 种结构件全部正确: Wood_Foundation -> SM_Floor_Wood、
---     Wood_Wall_V2 -> SM_Wall_Wood、Wood_WindowWall -> SM_WallWindow_Wood、
---     Wood_Roof/Stair -> SM_*_Wood、Stone_WallGate -> SM_WallGate_Stone
---   · 在 actor 上读得到网格的 26 种类型里，一致 11 / 不一致 6；
---     而那 6 种"不一致"的全都属于【actor 路径优先】，name 匹配根本不会被用到
function MeshMap.match_by_name(type_name)
    local material, parts = type_keywords(type_name)
    if material == nil or #material < 2 then return nil, 0, 0 end

    local best, best_score, best_len = nil, 0, 0
    local ties, same_len = 0, false
    local candidates = MeshMap.bucket(material)

    for i = 1, #candidates do
        local e = candidates[i]
        -- 规则 1: 只认 Architecture 目录
        if e.path:find("/Architecture/", 1, true) then
            local score = 0
            if e.norm:find(material, 1, true) then score = score + 2 end
            -- 规则 2: 严格命中所有关键词
            local all_parts = true
            for j = 1, #parts do
                if e.norm:find(parts[j], 1, true) then
                    score = score + 3
                else
                    all_parts = false
                end
            end
            if all_parts and score > 0 then
                local nlen = #e.norm
                if score > best_score then
                    best_score, best, best_len = score, e.path, nlen
                    ties, same_len = 1, false
                elseif score == best_score then
                    ties = ties + 1
                    -- 规则 3: 并列时取更短的（更"专用"）
                    if nlen < best_len then
                        best, best_len, same_len = e.path, nlen, false
                    elseif nlen == best_len then
                        same_len = true
                    end
                end
            end
        end
    end

    if best == nil then return nil, 0, 0 end
    if same_len and ties > 1 then
        -- 最短的也并列 -> 无法判定，放弃
        return nil, best_score, -1
    end
    return best, best_score, ties
end

-- --------------------------------------------------------------------------
-- 对外主入口
-- --------------------------------------------------------------------------

--- building: { t=类型, mesh=短名或nil }
--- 返回【网格路径列表】或 nil。
--- ★ 为什么要返回列表: 有些建筑由多个网格拼成（简约门 = 门框 + 左右门扇）。
---   只返回第一个会画出半个东西 —— 那是静默的错，比不画还糟。
function MeshMap.resolve_all(building)
    if type(building) ~= "table" then return nil end
    local t = tostring(building.t or "Unknown")
    local cached = MeshMap.cache[t]
    if cached ~= nil then
        if cached == false then return nil end
        return cached       -- 缓存里存的就是列表
    end

    local list = nil

    -- 0) ★【多网格】映射优先于 actor 单件 —— 2026-09-26 更深夜修的回归。
    --
    --    背景: 组件索引修好之后，64/72 种类型能从 actor 上读到网格名了，
    --    于是"actor 优先"这条规则开始压掉映射表。但 actor 只能给我们
    --    【一个】组件，而有些建筑天生是多个网格拼的:
    --        简约门     = 门框 + 左门扇 + 右门扇
    --        帕鲁装扮机 = 底座 + 帕鲁雕像
    --    结果就是画出"只有门框的门""只有底座的装扮机"。
    --
    --    规则: 映射表里写【数组】的，说明那是人工确认过的完整构成，
    --          直接用它，不要被 actor 的单件覆盖。
    --          （写单值的仍让 actor 先赢 —— actor 是游戏真值。）
    local ov = MeshMap.overrides[t]
    if type(ov) == "table" and #ov > 1 then
        MeshMap.resolve_stats.hit_override =
            MeshMap.resolve_stats.hit_override + 1
        MeshMap.cache[t] = ov
        return ov
    end

    -- 1) 蓝图里已经带了短名（来自 actor 上的 Mesh 组件）
    if type(building.mesh) == "string" and building.mesh ~= "" then
        local p = MeshMap.lookup_short(building.mesh)
        if p ~= nil then
            list = { p }
            MeshMap.resolve_stats.hit_actor =
                MeshMap.resolve_stats.hit_actor + 1
        end
    end

    -- 2) 覆盖表（优先于自动匹配；但让 actor 上的真值先赢）
    --
    --    特殊值 "-" 表示【不要画这个类型】。
    --    用于"自动匹配会给出错误网格、而游戏里又确实没有对应资产"的情况。
    --    画一个错的形状比不画更糟 —— 会让人以为是别的东西。
    if list == nil and ov ~= nil then
        if type(ov) == "table" and ov[1] == "-" then
            MeshMap.resolve_stats.hit_override =
                MeshMap.resolve_stats.hit_override + 1
            MeshMap.cache[t] = false
            return nil
        end
        list = ov
        MeshMap.resolve_stats.hit_override =
            MeshMap.resolve_stats.hit_override + 1
    end

    -- 3) 名字匹配（结构件）
    if list == nil then
        if not MeshMap.registry_ready then
            pcall(MeshMap.build_registry)
        end
        local m = MeshMap.match_by_name(t)
        if m ~= nil then
            list = { m }
            MeshMap.resolve_stats.hit_name =
                MeshMap.resolve_stats.hit_name + 1
        end
    end

    if list == nil then
        MeshMap.resolve_stats.miss = MeshMap.resolve_stats.miss + 1
        MeshMap.cache[t] = false
        return nil
    end
    MeshMap.cache[t] = list
    return list
end

--- 只要主网格路径的旧接口（保留，给只关心"有没有"的调用方用）
function MeshMap.resolve(building)
    local list = MeshMap.resolve_all(building)
    if list == nil then return nil end
    return list[1]
end

function MeshMap.stats_line()
    local s = MeshMap.resolve_stats
    return string.format(
        "网格解析: 直接命中 %d / 覆盖表 %d / 名字匹配 %d / 未解析 %d   注册表 %d 个网格",
        s.hit_actor, s.hit_override, s.hit_name, s.miss, #MeshMap.entries)
end

--- 把注册表导出（含匹配结果），用于把自动匹配固化成静态表
function MeshMap.discovery_lines(types)
    local out = {}
    out[#out + 1] = "# PWBP 静态网格注册表导出"
    out[#out + 1] = "# 时间: " .. Util.now_iso()
    out[#out + 1] = "# 已加载的 /Game/ 下 UStaticMesh 数量: " .. tostring(#MeshMap.entries)
    out[#out + 1] = ""
    out[#out + 1] = "## 1. 全部网格（按路径排序）"
    out[#out + 1] = ""
    local sorted = {}
    for i = 1, #MeshMap.entries do sorted[i] = MeshMap.entries[i] end
    table.sort(sorted, function(a, b) return a.path < b.path end)
    for i = 1, #sorted do
        out[#out + 1] = string.format("%-46s %s", sorted[i].short, sorted[i].path)
    end

    if type(types) == "table" and #types > 0 then
        out[#out + 1] = ""
        out[#out + 1] = "## 2. 当前采集到的类型 -> 自动匹配结果"
        out[#out + 1] = ""
        out[#out + 1] = string.format("%-34s %-8s %-8s %s", "短类型名", "数量", "分数", "匹配到的网格")
        out[#out + 1] = string.rep("-", 110)
        for i = 1, #types do
            local e = types[i]
            local p, score, ties = MeshMap.match_by_name(e.t)
            local note = ""
            if p ~= nil and ties > 1 then
                note = string.format("   (并列 %d)", ties)
            end
            out[#out + 1] = string.format("%-34s %-8d %-8s %s%s",
                e.t, e.count or 0, tostring(score or 0), tostring(p or "-"), note)
        end
    end
    return out
end

return MeshMap
