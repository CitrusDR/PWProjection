--[[ ===========================================================================
  PWBP · ghost  ——  投影渲染（阶段 S4）

  ★ 这是本 mod 唯一会"创建 / 修改引擎对象"的模块 ★

  因此它有双重门禁:
    1. config.ghost_enabled 必须为 true（默认 false）
    2. pwbp_capabilities.json 里必须已经有【探测通过】的记录
       要求: get_world / spawn_host / add_ism_component / set_static_mesh / add_instance
    缺任何一项 -> 什么都不做，只报告缺什么。
    这样"没探测过就渲染"在结构上不可能发生。

  渲染方案（全部来自 SBB 架构分析里确认过的调用形状，代码是自己写的）
  ------------------------------------------------------------------
    · 一个宿主 Actor（空 Actor，运行时生成）
    · 每个"网格资产"一个 InstancedStaticMeshComponent
      一个基地通常 60~80 种网格 -> 60~80 个组件，而不是 358 个组件
    · 实例用局部坐标（蓝图相对坐标，厘米），组件承载"放置变换"
      -> 移动投影 = 改 60~80 个组件的变换，而不是重建几千个实例
    · 材质用游戏自带的 BuildingSurfaceMaterialSet.Highlight
      （不行就退回 LoadAsset 拿到的备用材质）
    · 分层显示 = 换一批实例（ClearInstances + 重新 AddInstance）

  失败处理
  --------
    任何一步失败都只是"这次不显示"，并且会记进日志。
    绝不因为渲染失败去做任何"补救性"的引擎调用。
=========================================================================== ]]

local Util = require("pwbp_util")
local Log = require("pwbp_log")
local BP = require("pwbp_bp")
local MeshMap = require("pwbp_meshmap")
local Hud = require("pwbp_hud")

local Ghost = {}

Ghost.host = nil
Ghost.root = nil
Ghost.components = {}       -- 组 key -> component（静态网格用 mesh_path，骨骼网格用 mesh_path\1序号）
Ghost.skel_list = {}        -- 骨骼网格的 {comp=,rx=,ry=,rz=,yaw=} 列表（不能实例化，逐件设变换）
Ghost.used = {}             -- 当前这批用到的组件（show() 只显示这些）
Ghost.mesh_assets = {}      -- mesh_path -> UStaticMesh
Ghost.material = nil
Ghost.instance_mode = "local"
Ghost.visible = false

Ghost.last_error = nil
Ghost.stats = { components = 0, failed_components = 0, instances = 0,
                skipped_no_mesh = 0, material_ok = 0, material_fail = 0,
                material_missing = 0, material_readback = nil }

-- --------------------------------------------------------------------------
-- 门禁
-- --------------------------------------------------------------------------

--- 返回 ok, 原因, caps
function Ghost.check_gate(caps)
    if caps == nil then
        local Probe = require("pwbp_probe")
        caps = Probe.load_capabilities()
    end
    if type(caps) ~= "table" then
        return false, "还没有能力探测结果（先按探测键跑一次）", nil
    end
    local missing = {}
    local required = { "get_world", "spawn_host", "add_ism_component",
                       "set_static_mesh", "add_instance" }
    for i = 1, #required do
        local e = caps[required[i]]
        if e == nil or e.ok ~= true then missing[#missing + 1] = required[i] end
    end
    if #missing > 0 then
        return false, "探测未通过，缺少: " .. table.concat(missing, ", "), caps
    end
    return true, "探测通过", caps
end

-- --------------------------------------------------------------------------
-- 资源
-- --------------------------------------------------------------------------

local function find_class(path)
    local ok, obj = pcall(function() return StaticFindObject(path) end)
    if not ok or obj == nil then return nil end
    if not Util.usable_class(obj) then return nil end
    return obj
end

--- 不能拿来"造组件"的组件类（按类名片段排除）。
---
--- ★★★ 2026-09-28 实测抓到的真凶:
---   从世界里取"第一个 InstancedStaticMeshComponent 的类"，
---   取到了 **`/Script/Pal.PalFoliageISMComponentBase`** ——
---   那是 Palworld 的**植被**实例化组件（草/树用它），属于引擎的专用变体。
---   拿它的类去 `AddComponentByClass` 给普通 Actor 造组件 → **直接崩**
---   （日志: `组件类 OK 类=Class /Script/Pal.PalFoliageISMComponentBase`
---           → `准备 AddComponentByClass: 宿主有效=true 根有效=true` → 崩）。
---   为什么"偶发": 世界里第一个 ISM 是哪个，取决于玩家站在哪、当时加载了什么 ——
---   站在草地附近就容易先撞上植被组件。
local CLASS_DENY = {
    "Foliage", "Hierarchical", "Landscape", "Spline", "Grass",
}

--- 这个类是不是"不能用来造组件"的专用变体？返回 true, 命中的片段
local function class_denied(cls)
    local fn = Util.full_name(cls)
    if type(fn) ~= "string" then return false, nil end
    for i = 1, #CLASS_DENY do
        if fn:find(CLASS_DENY[i], 1, true) ~= nil then
            return true, CLASS_DENY[i]
        end
    end
    return false, nil
end

--- 取一个【真实存在】的组件类：从世界里已经有的同类组件上 GetClass()。
---
--- ★ 为什么不能只靠 StaticFindObject 的路径字符串（2026-09-26 实测）:
---   StaticFindObject("/Script/Engine.SkeletalMeshComponent") 拿到的是一个
---   **TrivialObject**（假对象，方法表是空的），用它 AddComponentByClass
---   造出来的组件也是 TrivialObject，于是:
---       attempt to call a TrivialObject value (method 'SetSkeletalMesh')
---   —— 报的是"对象是假的"，不是"方法不存在"，很容易看错方向。
---   而从世界里已经存在的同类组件取 GetClass() 一定是真类。
---
--- 返回 cls, 来源说明
local function find_live_component_class(class_name, fallback_path)
    local ok, objs = pcall(function() return FindAllOf(class_name) end)
    if ok and type(objs) == "table" then
        local skipped = {}
        for i = 1, #objs do
            local o = Util.unwrap(objs[i])
            if Util.usable(o) then
                local cls = nil
                pcall(function() cls = o:GetClass() end)
                cls = Util.unwrap(cls)
                if cls ~= nil and Util.usable_class(cls) then
                    -- ★★★ 排除"专用变体"（见 CLASS_DENY 的说明）:
                    --   拿植被/地形那类组件的类去造普通组件 **会崩**。
                    local denied, why = class_denied(cls)
                    if not denied then
                        if #skipped > 0 and Log ~= nil then
                            Log.line("[ghost] 组件类挑选: 跳过了 " .. #skipped
                                .. " 个专用变体（" .. table.concat(skipped, ", ") .. "）")
                        end
                        return cls, "live:" .. class_name
                    end
                    skipped[#skipped + 1] = tostring(why)
                end
            end
        end
    end
    if fallback_path ~= nil then
        local cls = find_class(fallback_path)
        if cls ~= nil then return cls, "path:" .. fallback_path end
    end
    return nil, "找不到可用的类 " .. tostring(class_name)
        .. "（活实例里的都是专用变体，且路径兜底也不可用）"
end

local function load_asset(path)
    if type(path) ~= "string" or path == "" then return nil end
    if type(LoadAsset) ~= "function" then return nil end
    local ok, res = pcall(function() return LoadAsset(path) end)
    local obj = ok and Util.unwrap(res) or nil
    if Util.usable(obj) then return obj end
    local ok2, obj2 = pcall(function() return StaticFindObject(path) end)
    if ok2 and Util.usable(obj2) then return Util.unwrap(obj2) end
    return nil
end

-- 建造预览材质所在目录
local BUILDING_PROCESS =
    "/Game/Pal/Material/MapObject/BuildObject/BuildingProcess/"

--- 按资产名直接加载的候选模式。
---
--- ★ 这份清单来自【游戏自己导出的材质清单】（pwbp_meshes.txt 第 4 节），
---   不是猜的。2026-09-26 深夜把它列出来之后才发现:
---     · MI_LooksPredicator【Building】和 Normal 是两个不同的材质
---       （玩家反馈 Normal 是灰白格子、没有蓝色 —— Building 很可能就是蓝的那个）
---     · 每个 Predicator 都有 _TwoSided 版本（薄墙用双面渲染更好看）
---     · 还有 MI_BuildObjectComplete（建造完成态）和 BeforeFix
Ghost.PATH_MODES = {
    building   = "MI_LooksPredicatorBuilding",
    building2  = "MI_LooksPredicatorBuilding_TwoSided",
    dismantle  = "MI_LooksPredicatorDismantle",
    complete   = "MI_BuildObjectComplete",
    beforefix  = "MI_LooksPredicatorBeforeFix",
}

--- 循环里保留的 4 档（玩家实测挑出来的）。
---
--- ★ 2026-09-26 深夜，玩家实测结论:
---     · 灰白格子 = highlight(MI_LooksPredicatorNormal)
---     · **蓝色就是它的下一个 = building(MI_LooksPredicatorBuilding)** ← 设为默认
---     · 红色   = error
---     · 黄色   = dismantle（建造即将完成）
---     · 彩色   = original（不覆盖材质）
---   其余候选（building2 / complete / beforefix）**仍然可用**，
---   只是不进循环 —— 在 pwbp_config.json 里把 ghost_material 直接写成那个名字
---   再按 F8 就行。详见 README 的材质对照表。
Ghost.MATERIAL_MODES = {
    "building",    -- 蓝（默认）
    "error",       -- 红
    "dismantle",   -- 黄
    "original",    -- 彩色（不覆盖）
}

--- 不在循环里、但填进配置就能用的候选（记录备用）
Ghost.EXTRA_MATERIAL_MODES = {
    "highlight",   -- 灰白格子 = MI_LooksPredicatorNormal
    "building2",   -- 蓝色双面渲染版
    "complete",    -- MI_BuildObjectComplete（建造完成态）
    "beforefix",   -- MI_LooksPredicatorBeforeFix
}

Ghost.material_mode = "building"
Ghost.material_note = nil

--- 取当前模式对应的材质。返回 material, 描述
--- "original" 模式返回 nil（表示不覆盖，用网格自身材质）
local function material_for_mode(mode)
    if mode == "original" then
        return nil, "不覆盖（用网格自己的材质，不透明）"
    end

    -- 按路径直接加载的候选
    local asset = Ghost.PATH_MODES[mode]
    if asset ~= nil then
        local m = load_asset(BUILDING_PROCESS .. asset .. "." .. asset)
        if Util.usable(m) then return m, asset end
        return nil, asset .. " 载入失败"
    end

    -- highlight / error 从游戏自带的材质集里取
    local ok, mgrs = pcall(function() return FindAllOf("PalMapObjectManager") end)
    if ok and type(mgrs) == "table" then
        for i = 1, #mgrs do
            local mgr = Util.unwrap(mgrs[i])
            if Util.usable(mgr) then
                local set = Util.prop(mgr, "BuildingSurfaceMaterialSet")
                local key = (mode == "error") and "Error" or "Highlight"
                local m = Util.unwrap(Util.prop(set, key))
                if Util.usable(m) then
                    return m, key .. "  " .. tostring(Util.full_name(m))
                end
            end
        end
    end
    return nil, "BuildingSurfaceMaterialSet." .. mode .. " 不可用"
end

--- 切到下一个材质模式。返回 模式名, 说明
--- 切换投影材质。sign = +1 下一档 / -1 上一档（默认 +1）。
--- ★★ 2026-09-28 修: 原来没有方向参数，于是左/右方向键都只会"下一档"，
---    要往回切只能循环一圈（玩家反馈）。现在两个方向都能用。
function Ghost.cycle_material(sign)
    -- ★ 方向: +1 = 下一档（右方向键），-1 = 上一档（左方向键）
    if sign ~= -1 then sign = 1 end
    local n = #Ghost.MATERIAL_MODES
    local cur = 1
    for i = 1, n do
        if Ghost.MATERIAL_MODES[i] == Ghost.material_mode then cur = i break end
    end
    cur = cur + sign
    if cur > n then cur = 1 end          -- 往后越界 → 回到第一档
    if cur < 1 then cur = n end          -- 往前越界 → 回到最后一档
    Ghost.material_mode = Ghost.MATERIAL_MODES[cur]
    return Ghost.material_mode
end

--- 找材质来画投影。返回 material, 名字
local function resolve_material(caps)
    local m, which = material_for_mode(Ghost.material_mode)
    Ghost.material_note = which
    return m, which
end

-- --------------------------------------------------------------------------
-- 宿主
-- --------------------------------------------------------------------------

local function destroy_host()
    if Util.valid(Ghost.host) then
        pcall(function() Ghost.host:K2_DestroyActor() end)
    end
    Ghost.host = nil
    Ghost.root = nil
    Ghost.components = {}
    Ghost.skel_list = {}
    Ghost.skel_mesh = {}
    Ghost.comp_mesh = {}
    Ghost.comp_skel = {}
    Ghost.used = {}
    Ghost.visible = false
end

--- caps 里记录的生成方式
local function acquire_host(caps)
    local world = nil
    -- ★ 用 Util.find_world()（FindFirstOf），**不要**用 UEHelpers.GetWorld():
    --   后者会拿"上个世界的废 PlayerController"去 GetWorld() → 访问违例
    --   （见 Util.find_world 的注释，2026-09-28 崩溃的根因）。
    pcall(function() world = Util.find_world() end)
    if not Util.valid(world) then
        return nil, "拿不到 World"
    end

    local class_actor = find_class("/Script/Engine.Actor")
    if class_actor == nil then return nil, "/Script/Engine.Actor 不可用" end

    local actor = nil
    local okS, res = pcall(function()
        return world:SpawnActor(class_actor, {}, {})
    end)
    actor = okS and Util.unwrap(res) or nil
    if not Util.valid(actor) then
        return nil, "SpawnActor 失败: " .. tostring(res)
    end

    Ghost.host = actor

    -- 根组件（失败也能继续：组件都用绝对变换）
    local class_scene = find_class("/Script/Engine.SceneComponent")
    if class_scene ~= nil then
        local okC, c = pcall(function()
            return actor:AddComponentByClass(class_scene, true,
                Util.identity_transform(), false)
        end)
        local root = okC and Util.unwrap(c) or nil
        if Util.valid(root) then
            Ghost.root = root
            pcall(function()
                root:SetMobility(2)
                root:SetAbsolute(true, true, true)
            end)
        end
    end
    return actor, nil
end

-- --------------------------------------------------------------------------
-- 组件与实例
-- --------------------------------------------------------------------------

--- 把"放置变换"和"建筑局部偏移"合成世界变换。
--- 两者都是绕 Z 的旋转，所以直接手算:
---   世界位置 = 放置位置 + 把局部偏移按放置朝向转一下
---   世界朝向 = 放置朝向 + 建筑朝向
--- ★ 为什么必须自己算: 骨骼网格的组件不能交给 ISM 的"局部实例"机制，
---   得把两个变换乘起来自己设上去。
local function compose_place(place, rx, ry, rz, yaw_b)
    local py = place.yaw or 0.0
    local rad = math.rad(py)
    local c, s = math.cos(rad), math.sin(rad)
    return Util.transform_at(
        (place.x or 0.0) + (rx * c - ry * s),
        (place.y or 0.0) + (rx * s + ry * c),
        (place.z or 0.0) + rz,
        py + (yaw_b or 0.0))
end

local function new_ism(mesh_path, reg_key)
    if not Util.valid(Ghost.host) then return nil, "没有宿主" end

    -- ★ 细跟踪: 只对前 N 组打全（放置崩溃的崩点总在前 19 组内），
    --   每一行都立刻刷盘 —— 崩了才知道是哪一步、哪个资产。
    local trace = (Ghost.trace_left or 0) > 0
    local function tr(s)
        if trace and Log ~= nil then
            Log.emit("[fill/ism] " .. tostring(s))
            Log.flush()
        end
    end
    Ghost.trace_left = math.max((Ghost.trace_left or 0) - 1, 0)
    tr(string.format("开始 网格=%s 键=%s", tostring(mesh_path), tostring(reg_key)))

    -- ---- 先载入资产，再决定用哪种组件 -----------------------------------
    -- ★ 2026-09-26 深夜: 后期工厂 / 磨粉机 / 碎冰机 / 石油钻机 / 古代发电机的
    --   资产是 SK_ 开头的【SkeletalMesh（骨骼网格）】。
    --   ISM 只能装 StaticMesh，SetStaticMesh 拿到骨骼网格会失败 ——
    --   所以必须先判断类型，走两条不同的路。
    local asset = Ghost.mesh_assets[mesh_path]
    if asset == nil then
        asset = load_asset(mesh_path)
        Ghost.mesh_assets[mesh_path] = asset
    end
    if not Util.usable(asset) then
        tr("资产载入失败 -> 返回")
        return nil, "网格资产载入失败: " .. tostring(mesh_path)
    end
    local a_full = Util.full_name(asset) or ""
    -- 资产全名带类名前缀: "StaticMesh /Game/..." 或 "SkeletalMesh /Game/..."
    local is_skeletal = a_full:find("SkeletalMesh", 1, true) ~= nil
    tr(string.format("资产 OK 骨骼=%s 全名=%s", tostring(is_skeletal), a_full))

    -- 类要从【世界里已存在的同类组件】上取（见 find_live_component_class 的注释:
    -- 直接 StaticFindObject 类路径对 SkeletalMeshComponent 会拿到 TrivialObject）。
    --
    -- ★★ 2026-09-28: 一次 fill 里**只向世界要一次类，后面复用**（存在 Ghost.fill_*_cls 上）。
    --   为什么: 世界里的现存组件可能包含"上个世界刚销毁、但还在对象表里"的废对象，
    --   而 `Util.usable` 在废对象上会撒谎 ⇒ 反复向世界要类 = 反复暴露在这个风险下。
    --   第一次成功拿到的类一定来自**本世界活着的组件**，复用它最安全（也更快）。
    local cls, cls_src
    if is_skeletal then
        cls, cls_src = Ghost.fill_skel_cls, "复用本次 fill 的骨骼类"
    else
        cls, cls_src = Ghost.fill_ism_cls, "复用本次 fill 的静态类"
    end
    if cls == nil then
        if is_skeletal then
            cls, cls_src = find_live_component_class("SkeletalMeshComponent",
                "/Script/Engine.SkeletalMeshComponent")
        else
            cls, cls_src = find_live_component_class("InstancedStaticMeshComponent",
                "/Script/Engine.InstancedStaticMeshComponent")
        end
    end
    if cls == nil then
        tr("找不到组件类 -> 返回")
        return nil, "找不到组件类: " .. tostring(cls_src)
    end
    -- 记下来给后面的组复用
    if is_skeletal then
        Ghost.fill_skel_cls = cls
    else
        Ghost.fill_ism_cls = cls
    end
    tr("组件类 OK 来源=" .. tostring(cls_src)
        .. " 类=" .. tostring(Util.full_name(cls)))

    tr(string.format("准备 AddComponentByClass: 宿主有效=%s 根有效=%s 骨骼=%s",
        tostring(Util.valid(Ghost.host)), tostring(Util.valid(Ghost.root)),
        tostring(is_skeletal)))
    local ok, c = pcall(function()
        return Ghost.host:AddComponentByClass(cls, true,
            Util.identity_transform(), false)
    end)
    local comp = ok and Util.unwrap(c) or nil
    tr(string.format("AddComponentByClass 返回: pcall_ok=%s 结果=%s",
        tostring(ok), tostring(c ~= nil)))
    if not Util.valid(comp) then
        tr("AddComponentByClass 结果无效 -> 返回")
        return nil, "AddComponentByClass 失败(" .. tostring(cls_src) .. "): "
            .. tostring(c)
    end
    tr("AddComponentByClass OK")
    pcall(function()
        comp:SetMobility(2)
        comp:SetAbsolute(true, true, true)
        comp:SetCollisionEnabled(0)
        comp:SetGenerateOverlapEvents(false)
        comp:SetCastShadow(false)
        comp:SetReceivesDecals(false)
        comp:SetRenderInMainPass(true)
        comp:SetRenderInDepthPass(true)
    end)
    tr("基础设置（Mobility/绝对变换/碰撞/阴影）OK")
    if Util.valid(Ghost.root) then
        local okA = pcall(function()
            comp:K2_AttachToComponent(Ghost.root, FName("None"), 0, 0, 0, false)
        end)
        if okA then
            pcall(function() comp:SetAbsolute(false, false, false) end)
        end
        tr("挂载到根组件: pcall_ok=" .. tostring(okA))
    else
        tr("根组件无效 -> 跳过挂载")
    end

    -- ---- 设网格 ----------------------------------------------------------
    -- 失败必须当失败处理 —— 否则后面会往一个没有网格的组件上加东西，
    -- 玩家只会看到"少了很多件"却不知道为什么。
    if is_skeletal then
        -- 骨骼网格: 按可靠性顺序多试几种写法。
        -- ★ 为什么不是只写一种: UE4SS 对 SkeletalMeshComponent 的 UFUNCTION
        --   绑定不一定完整，而不同的写法在不同版本上可用性不同。
        --   多试几种 + 记录哪一种成功，比"猜一个然后失败"可靠得多。
        local SKEL_SETTERS = {
            { "SetSkeletalMesh(mesh,true)", function()
                comp:SetSkeletalMesh(asset, true) end },
            { "SetSkeletalMesh(mesh)", function()
                comp:SetSkeletalMesh(asset) end },
            { "SetSkinnedAssetAndUpdate(asset,true)", function()
                comp:SetSkinnedAssetAndUpdate(asset, true) end },
            { "写属性 SkeletalMesh", function()
                comp.SkeletalMesh = asset end },
            { "写属性 SkinnedAsset", function()
                comp.SkinnedAsset = asset end },
        }
        local worked, last_err = nil, nil
        for si = 1, #SKEL_SETTERS do
            local okS, errS = pcall(SKEL_SETTERS[si][2])
            if okS then
                worked = SKEL_SETTERS[si][1]
                break
            end
            last_err = errS
        end
        if worked == nil then
            return nil, "骨骼网格设置全部失败(" .. tostring(cls_src)
                .. "): " .. tostring(last_err)
        end
        Ghost.stats.skel_setter = worked
        Ghost.stats.skeletal_components =
            (Ghost.stats.skeletal_components or 0) + 1
        if Log ~= nil and (Ghost.stats.skel_setter_logged or 0) < 1 then
            Ghost.stats.skel_setter_logged =
                (Ghost.stats.skel_setter_logged or 0) + 1
            Log.line("[ghost] 骨骼网格设置成功，用的是: " .. worked
                .. "   类来源=" .. tostring(cls_src))
        end
    else
        local okMesh, meshErr = pcall(function() comp:SetStaticMesh(asset) end)
        if not okMesh then
            tr("SetStaticMesh 失败 -> 返回")
            return nil, "SetStaticMesh 失败: " .. tostring(meshErr)
        end
    end
    tr("设网格 OK")

    -- ---- 材质 ----------------------------------------------------------
    -- ★ 2026-09-26 实测教训: 这里原来是
    --     if Util.valid(Ghost.material) then pcall(function() ... SetMaterial ... end) end
    --   两个地方都会静默吞掉问题:
    --     1) Util.valid 会把好材质判为无效 -> 整段跳过
    --     2) pcall 吞掉 SetMaterial 的失败
    --   结果就是投影画成了 UE 的 WorldGridMaterial（灰白格子）。
    --   现在: 用 Util.usable + 把所有材质槽都设一遍 + 失败要计数 + 回读验证。
    if Ghost.material_mode == "original" then
        -- 刻意不覆盖: 用网格自带材质（不透明，但形状/贴图最真实）
        Ghost.stats.material_original = (Ghost.stats.material_original or 0) + 1
    elseif Util.usable(Ghost.material) then
        local n_slots = 1
        pcall(function() n_slots = comp:GetNumMaterials() end)
        if type(n_slots) ~= "number" or n_slots < 1 then n_slots = 1 end
        local set_ok = 0
        for s = 0, n_slots - 1 do
            if pcall(function() comp:SetMaterial(s, Ghost.material) end) then
                set_ok = set_ok + 1
            end
        end
        if set_ok == 0 then
            Ghost.stats.material_fail = (Ghost.stats.material_fail or 0) + 1
            Log.line("[ghost] SetMaterial 全部失败（" .. tostring(n_slots)
                .. " 个槽）: " .. tostring(mesh_path))
        else
            Ghost.stats.material_ok = (Ghost.stats.material_ok or 0) + 1
        end
        -- 回读验证（只记第一个组件，避免刷屏）:
        -- 这是"材质到底有没有真的设上去"的硬证据。
        if Ghost.stats.material_readback == nil then
            local got = nil
            pcall(function() got = Util.full_name(comp:GetMaterial(0)) end)
            Ghost.stats.material_readback = got or "(回读失败)"
        end
    else
        Ghost.stats.material_missing = (Ghost.stats.material_missing or 0) + 1
    end

    pcall(function() comp:SetVisibility(true, true) end)
    pcall(function() comp:SetHiddenInGame(false, true) end)
    -- ★ 注册用的 key 由调用方给: 静态网格的 key 就是 mesh_path，
    --   骨骼网格每件一个组件，key 是 mesh_path\1序号。
    --   用 mesh_path 当 key 会把同一网格的多件互相覆盖，前面的组件就
    --   再也没人引用 -> 既不会随投影移动，也不会被销毁。
    Ghost.components[reg_key or mesh_path] = comp
    -- ★★★ 2026-09-28: 把"这个组件是骨骼网格"记在**组件上** —— 依据是
    --   **资产自身的类**（`is_skeletal` 是从 `GetClass()` 的真实全名判断的），
    --   所以这是**权威结论**。`fill` 用它纠正"注册表没加载该资产 ⇒ 误判为静态"
    --   的情况 —— 那个误判会让骨骼建筑堆在放置点上（见 MeshMap.is_skeletal 注释）。
    if Ghost.comp_skel == nil then Ghost.comp_skel = {} end
    Ghost.comp_skel[comp] = is_skeletal and true or false
    tr("组件创建完成 OK")
    return comp, nil
end

local function clear_instances()
    for _, comp in pairs(Ghost.components) do
        if Util.valid(comp) then
            pcall(function() comp:ClearInstances() end)
        end
    end
end

--- 把一批建筑灌进组件。place 是 { x=,y=,z=, yaw= } （世界厘米 + 度）
function Ghost.fill(bp, place, mode, layer_index, lo, hi)
    if not Util.valid(Ghost.host) then return false, "没有宿主" end
    local picked = BP.select_indices(bp, mode or "all", layer_index, lo, hi)
    if #picked == 0 then return false, "该分层下没有建筑" end
    if Log ~= nil then
        Log.emit(string.format("[fill] 阶段: 入口（选中 %d 件，模式 %s 层 %s）",
            #picked, tostring(mode), tostring(layer_index)))
        Log.flush()
    end

    local max_inst = 6000
    pcall(function()
        max_inst = tonumber(require("pwbp_config").get("ghost_max_instances")) or 6000
    end)
    if #picked > max_inst then
        return false, string.format("要显示 %d 件，超过上限 %d", #picked, max_inst)
    end

    clear_instances()
    -- ★★ 2026-09-26 更深夜修的 bug（玩家按 L 换层时发现）:
    --   clear_instances() 对骨骼网格【完全无效】—— 它调的是 ISM 的
    --   ClearInstances()，而骨骼网格不是实例、是【组件】。
    --   结果: 换层时静态件清掉了，上一批的骨骼网格却留在原地不动，
    --   按多少次 L 都消失不了。
    --   对策: 每次重灌前先把【所有】组件隐藏，用到哪些再重新显示。
    --   （隐藏 ISM 也不会有副作用 —— 它没实例时本来就不画东西。）
    Ghost.used = {}
    Ghost.comp_mesh = {}
    for _, c in pairs(Ghost.components) do
        if Util.valid(c) then
            pcall(function() c:SetVisibility(false, true) end)
            pcall(function() c:SetHiddenInGame(true, true) end)
        end
    end
    Ghost.skel_list = {}
    Ghost.skel_mesh = {}
    Ghost.stats = { components = 0, failed_components = 0, instances = 0,
                skipped_no_mesh = 0, material_ok = 0, material_fail = 0,
                material_missing = 0, material_original = 0,
                material_readback = nil, skeletal_components = 0 }

    local bs = bp.buildings
    local groups, order = {}, {}
    -- ★ 骨骼网格不能实例化（一个组件只能画一件），所以每个建筑单独一组。
    --   组 key 用 mesh .. "\1" .. 序号，和静态网格的组区分开。
    --   \1 是控制字符，不可能出现在正常的资产路径里。
    local SKEL_SEP = "\1"
    local MULTI_SEP = "\2"
    for i = 1, #picked do
        local b = bs[picked[i]]
        if type(b) ~= "table" then
            -- 蓝图文件损坏时不要抛错（抛错会留下一个没有实例的宿主 actor）
            Ghost.stats.skipped_no_mesh = Ghost.stats.skipped_no_mesh + 1
        else
            -- ★ 一个建筑可能由【多个网格】拼成（简约门 = 门框 + 左右门扇），
            --   所以要遍历列表；只取第一个会画出半个东西。
            local meshes = MeshMap.resolve_all(b)
            if meshes == nil then
                Ghost.stats.skipped_no_mesh = Ghost.stats.skipped_no_mesh + 1
                -- ★ 2026-09-28: 按【类型】统计缺网格的件数 —— 报告里直接列出
                --   "哪些类型没解析到"，玩家/我都能一眼看出该补哪条映射，
                --   而不是只知道"缺了 N 件"却不知道缺的是谁。
                local tn = Ghost.stats.no_mesh_by_type
                if tn == nil then
                    tn = {}
                    Ghost.stats.no_mesh_by_type = tn
                end
                local tk = tostring(b.t or "Unknown")
                tn[tk] = (tn[tk] or 0) + 1
            else
                for mi = 1, #meshes do
                    local mesh = meshes[mi]
                    if MeshMap.is_skeletal(mesh) then
                        local key = mesh .. SKEL_SEP .. tostring(i)
                            .. MULTI_SEP .. tostring(mi)
                        groups[key] = { b }
                        order[#order + 1] = key
                    else
                        if groups[mesh] == nil then
                            groups[mesh] = {}
                            order[#order + 1] = mesh
                        end
                        groups[mesh][#groups[mesh] + 1] = b
                    end
                end
            end
        end
    end

    local ok_world = (Ghost.instance_mode == "world")
    local failed_components = 0
    -- ★ 2026-09-27 崩溃排查: 放置阶段的日志点太少，
    --   "材质行"到"骨骼网格行"之间崩了就什么也看不出来。
    --   这里加"阶段标记"（进文件 + 刷盘）与"每组一行"的细跟踪
    --   （只进文件缓冲，不刷控制台 —— 371 组刷控制台会淹没日志）。
    if Log ~= nil then
        Log.emit(string.format("[fill] 阶段: 选件=%d 组=%d（骨骼组另算）",
            #picked, #order))
        -- ★ 只对前 25 组打细跟踪（实测崩点都在前 19 组内），并且每组建完就刷盘。
        --   为什么限个数: 75 组 × 每人数行会把日志淹掉，也没必要。
        Ghost.trace_left = 25
        -- ★ 每次 fill 重新取组件类（本世界第一次创建时取，之后复用）
        Ghost.fill_ism_cls, Ghost.fill_skel_cls = nil, nil
        Log.flush()
    end
    for i = 1, #order do
        local key = order[i]
        local base = key:match("^(.-)" .. SKEL_SEP) or key
        local is_skel = (base ~= key)
        local comp = Ghost.components[key]
        if Log ~= nil then
            Log.line(string.format("[fill] 组 %d/%d 类型=%s 网格=%s 骨骼=%s 件数=%d 复用=%s",
                i, #order, tostring((groups[key] ~= nil and groups[key][1] ~= nil)
                    and groups[key][1].t or "?"),
                tostring(base), tostring(is_skel),
                (groups[key] ~= nil) and #groups[key] or 0,
                tostring(Util.valid(comp))))
            -- ★ 前 25 组每组都刷盘（崩了也能看到"正做到第几组"）
            if i <= 25 or (i % 20) == 0 then Log.flush() end
        end
        if not Util.valid(comp) then
            local cerr = nil
            comp, cerr = new_ism(base, key)
            if not Util.valid(comp) then
                failed_components = failed_components + 1
                if Log ~= nil and failed_components <= 3 then
                    Log.line("[ghost] 组件创建失败 " .. tostring(base)
                        .. " : " .. tostring(cerr))
                end
            end
        end
        if Util.valid(comp) then
            -- ★★★ 2026-09-28 权威纠正: `new_ism` 是按**资产自身的类**判断骨骼与否的，
            --   如果它说"这是骨骼组件"，那不管分组 key 怎么来的，都必须走骨骼分支
            --   （静态分支的 `AddInstance` 在骨骼组件上必然失败 ⇒ 0 实例 +
            --     不进 skel_list ⇒ 组件停在放置点上 = 玩家看到"堆在终端上面"）。
            if Ghost.comp_skel ~= nil and Ghost.comp_skel[comp] == true then
                if not is_skel and Log ~= nil then
                    Log.line("[ghost] 注意: 分组当成静态了，但资产是骨骼网格 —— "
                        .. "按骨骼处理（注册表未加载该资产时会误判）: " .. tostring(base))
                end
                is_skel = true
            end
            -- 这一批要用它 -> 显示出来，并记进 used（show() 只显示 used 里的，
            -- 否则按 K 收起再放开会把上一批的骨骼网格一起放出来）
            Ghost.used[comp] = true
            -- ★ 取证用: 记下"这个组件是哪个网格、往它里面放了几件"
            --   （apply_transform 里会按"组件世界坐标 vs 放置点"核对悬空问题）
            if Ghost.comp_mesh == nil then Ghost.comp_mesh = {} end
            Ghost.comp_mesh[comp] = { mesh = base, n = 0 }
            pcall(function() comp:SetVisibility(true, true) end)
            pcall(function() comp:SetHiddenInGame(false, true) end)
            local list = groups[key]
            for j = 1, #list do
                local b = list[j]
                local rx, ry, rz = BP.rel_cm(b)
                if rx == nil then
                    Ghost.stats.skipped_no_mesh = Ghost.stats.skipped_no_mesh + 1
                else
                local yaw = tonumber(b.yaw) or 0.0
                if is_skel then
                    -- 骨骼网格: 组件本身就是那一件，直接设它的变换。
                    -- 记进 skel_list，apply_transform 时按"放置变换 ∘ 局部偏移"重算。
                    Ghost.skel_list[#Ghost.skel_list + 1] = {
                        comp = comp, rx = rx, ry = ry, rz = rz, yaw = yaw,
                    }
                    -- ★ 记下"这个骨骼组件是哪个网格"（取证用: 悬空/跑偏时能指名道姓）
                    if Ghost.skel_mesh == nil then Ghost.skel_mesh = {} end
                    Ghost.skel_mesh[comp] = base
                    if ok_world then
                        pcall(function()
                            comp:K2_SetRelativeTransform(
                                compose_place(place, rx, ry, rz, yaw),
                                false, {}, true)
                        end)
                    else
                        pcall(function()
                            comp:K2_SetRelativeTransform(
                                Util.transform_at(rx, ry, rz, yaw),
                                false, {}, true)
                        end)
                    end
                    Ghost.stats.instances = Ghost.stats.instances + 1
                else
                local tf
                if ok_world then
                    tf = Util.transform_at(
                        place.x + rx, place.y + ry, place.z + rz,
                        place.yaw + yaw)
                else
                    tf = Util.transform_at(rx, ry, rz, yaw)
                end
                local okAdd = pcall(function()
                    if ok_world then
                        comp:AddInstanceWorldSpace(tf)
                    else
                        comp:AddInstance(tf, false)
                    end
                end)
                if okAdd then
                    Ghost.stats.instances = Ghost.stats.instances + 1
                    if Ghost.comp_mesh ~= nil and Ghost.comp_mesh[comp] ~= nil then
                        Ghost.comp_mesh[comp].n = Ghost.comp_mesh[comp].n + 1
                    end
                end
                end
                end
            end
        end
    end

    Ghost.stats.components = 0
    for _ in pairs(Ghost.components) do
        Ghost.stats.components = Ghost.stats.components + 1
    end
    Ghost.stats.failed_components = failed_components
    Ghost.visible = true
    -- ★ 记下"这个投影是在哪个世界建出来的" —— 之后所有触碰组件的操作
    --   都先用它做一次**字符串比较**，避免摸到上个世界的废对象（见 stale_world）。
    Ghost.world_name = Util.world_tag()
    if Log ~= nil then
        Log.emit(string.format("[fill] 阶段: 组件循环完成（失败 %d）→ apply_transform",
            failed_components))
        Log.flush()
    end
    Ghost.apply_transform(place)
    if Log ~= nil then
        Log.emit("[fill] 阶段: apply_transform 完成")
        Log.flush()
    end
    return true, nil
end

--- 把"放置变换"写到所有组件上
function Ghost.apply_transform(place)
    -- ★★ 这里**不再**做"世界标记"检查 —— 2026-09-28 实测（玩家日志）:
    --   标记每次调用都在变（`AActor: ...FAF8 -> ...5758`），于是这一步被**误跳过**，
    --   投影的 374 件实例全部留在宿主原点上 ⇒ 玩家看到"放了但什么都没有"。
    --   跨世界的清理**只由 LoadMapPre 钩子负责**（日志证明它每次都正确触发）。
    if not Util.valid(Ghost.host) then return false end
    if Ghost.instance_mode == "world" then
        -- 世界空间实例无需组件变换。但骨骼网格是【组件】不是实例，
        -- 所以它那部分在 fill 里就已经按世界坐标设好了，这里不用动。
        return true
    end
    local tf = Util.transform_at(place.x, place.y, place.z, place.yaw)
    for _, comp in pairs(Ghost.components) do
        if Util.valid(comp) then
            local ok = pcall(function()
                comp:K2_SetRelativeTransform(tf, false, {}, true)
            end)
            if not ok then
                pcall(function()
                    comp:K2_SetWorldLocation(
                        { X = place.x, Y = place.y, Z = place.z }, false, {}, true)
                end)
            end
        end
    end
    -- ★ 骨骼网格的组件【必须放在最后覆盖】:
    --   上一段把所有组件的相对变换都设成了"放置变换"（对 ISM 是对的，
    --   因为实例偏移在实例里）。但骨骼网格的偏移必须一起乘进来，
    --   否则所有骨骼网格会叠在同一个点上。
    if Ghost.skel_list ~= nil then
        for i = 1, #Ghost.skel_list do
            local e = Ghost.skel_list[i]
            if Util.valid(e.comp) then
                pcall(function()
                    e.comp:K2_SetRelativeTransform(
                        compose_place(place, e.rx, e.ry, e.rz, e.yaw),
                        false, {}, true)
                end)
            end
        end
    end

    -- ★★★ 2026-09-28 取证: "投影里有个东西悬在空中"（玩家截图）——
    --   蓝图数据是干净的（z 最大 3.65 米，无异常记录），所以问题在渲染侧:
    --   某个组件/实例的变换没生效，或者它被放到了别的地方。
    --   而**骨骼网格**是"一个组件就是一件"，位置最好核对 ⇒ 把它们的
    --   【期望位置】和【引擎回读的实际位置】都打出来，一对比就知道是谁跑偏了。
    if Log ~= nil then
        local hx, hy, hz = nil, nil, nil
        pcall(function()
            local l = Ghost.host:K2_GetActorLocation()
            if l ~= nil then hx, hy, hz = l.X, l.Y, l.Z end
        end)
        local ncomp = 0
        for _ in pairs(Ghost.components) do ncomp = ncomp + 1 end
        Log.line(string.format(
            "[ghost/dump] 放置点=(%.0f, %.0f, %.0f) 宿主=(%s, %s, %s) 组件=%d 骨骼=%d 模式=%s",
            place.x, place.y, place.z,
            tostring(hx), tostring(hy), tostring(hz),
            ncomp,
            (Ghost.skel_list ~= nil) and #Ghost.skel_list or 0,
            tostring(Ghost.instance_mode)))
        if Ghost.skel_list ~= nil then
            for i = 1, #Ghost.skel_list do
                local e = Ghost.skel_list[i]
                local want = compose_place(place, e.rx, e.ry, e.rz, e.yaw)                -- ★ 注意 Util.transform_at 的返回形状是
                --   { Rotation = ..., Translation = { X, Y, Z }, Scale3D = ... }
                --   —— 平移在 .Translation 里，**不是** .X/.Y/.Z。
                --   （差点在这里把 nil 传进 string.format，那会当场炸掉放置。）
                local tr = (type(want) == "table") and want.Translation or nil
                local wx = (tr ~= nil and tr.X) or 0.0
                local wy = (tr ~= nil and tr.Y) or 0.0
                local wz = (tr ~= nil and tr.Z) or 0.0
                -- 期望的世界位置（compose_place 的平移部分）
                local gx, gy, gz = nil, nil, nil
                pcall(function()
                    local l = e.comp:K2_GetComponentLocation()
                    if l ~= nil then gx, gy, gz = l.X, l.Y, l.Z end
                end)
                local d = "?"
                if gx ~= nil then
                    local dx, dy, dz = gx - wx, gy - wy, gz - wz
                    d = string.format("%.1f", math.sqrt(dx * dx + dy * dy + dz * dz))
                end
                Log.line(string.format(
                    "  [ghost/dump] 骨骼 #%d %s 期望=(%.0f, %.0f, %.0f) 实际=(%s, %s, %s) 差=%s 厘米",
                    i, tostring(Ghost.skel_mesh and Ghost.skel_mesh[e.comp] or "?"),
                    wx, wy, wz,
                    gx and string.format("%.0f", gx) or "读不到",
                    gy and string.format("%.0f", gy) or "读不到",
                    gz and string.format("%.0f", gz) or "读不到",
                    d))
            end
        end

        -- ★★★ 最关键的一条判据（2026-09-28，排查"某件悬在空中"）:
        --   静态 ISM 的【偏移全在实例里】，所以每个组件的**世界坐标本身**
        --   应该正好等于【放置点】。谁不等于放置点，谁就是那个跑偏的东西。
        --   （骨骼组件不适用: 它们的偏移在组件自己的变换里，上面已单独核对过。）
        Log.line("  [ghost/dump] —— 下面按「组件世界坐标 vs 放置点」核对（不等于放置点的就是嫌疑）——")
        local nbad = 0
        for comp, info in pairs(Ghost.comp_mesh or {}) do
            if Util.valid(comp) then
                local cx, cy, cz = nil, nil, nil
                pcall(function()
                    local l = comp:K2_GetComponentLocation()
                    if l ~= nil then cx, cy, cz = l.X, l.Y, l.Z end
                end)
                local n_eng = nil
                pcall(function() n_eng = comp:GetInstanceCount() end)
                local dist = nil
                if cx ~= nil then
                    local dx, dy, dz = cx - place.x, cy - place.y, cz - place.z
                    dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                end
                local suspicious = (dist == nil) or (dist > 50.0)
                if suspicious then nbad = nbad + 1 end
                Log.line(string.format(
                    "    [ghost/dump]%s %s 组件世界=(%s, %s, %s) 距放置点=%s 厘米 实例(我们/引擎)=%s/%s",
                    suspicious and " ★嫌疑" or "",
                    tostring(info.mesh or "?"),
                    cx and string.format("%.0f", cx) or "读不到",
                    cy and string.format("%.0f", cy) or "读不到",
                    cz and string.format("%.0f", cz) or "读不到",
                    dist and string.format("%.0f", dist) or "?",
                    tostring(info.n or "?"),
                    tostring(n_eng)))
            end
        end
        Log.line(string.format("  [ghost/dump] 核对完成: 组件 %d 个，其中距放置点 >50 厘米的 %d 个",
            (function()
                local n = 0
                for _ in pairs(Ghost.comp_mesh or {}) do n = n + 1 end
                return n
            end)(), nbad))
        Log.flush()
    end
    return true
end

function Ghost.hide()
    -- 同上: 不做世界标记检查（它不稳定，会误跳过）。跨世界清理由 LoadMapPre 钩子负责。
    if not Util.valid(Ghost.host) then return false end
    for _, comp in pairs(Ghost.components) do
        if Util.valid(comp) then
            pcall(function() comp:SetVisibility(false, true) end)
            pcall(function() comp:SetHiddenInGame(true, true) end)
        end
    end
    Ghost.visible = false
    return true
end

function Ghost.show()
    if not Util.valid(Ghost.host) then return false end
    -- ★ 只显示【当前这一批用到的】组件。
    --   如果无脑显示全部，上一批遗留的骨骼网格组件会一起冒出来 ——
    --   那正是"按 L 换层后东西不消失"的成因（骨骼网格不是实例，
    --   ClearInstances 管不到它，只能靠可见性控制）。
    --   used 为空时（还没 fill 过）才退回显示全部。
    local has_used = false
    if Ghost.used ~= nil then
        for _ in pairs(Ghost.used) do has_used = true break end
    end
    for _, comp in pairs(Ghost.components) do
        if Util.valid(comp) then
            local want = (not has_used) or (Ghost.used[comp] == true)
            pcall(function() comp:SetVisibility(want, true) end)
            pcall(function() comp:SetHiddenInGame(not want, true) end)
        end
    end
    Ghost.visible = true
    return true
end

function Ghost.clear()
    -- 同上: 不做世界标记检查。换世界后的清理由 LoadMapPre 钩子丢引用完成
    -- （那时这些对象已经随旧世界销毁，也没什么可清的）。
    clear_instances()
    destroy_host()
    Ghost.mesh_assets = {}
    Ghost.skel_list = {}
    Ghost.skel_mesh = {}
    Ghost.stats = { components = 0, failed_components = 0, instances = 0,
                skipped_no_mesh = 0, material_ok = 0, material_fail = 0,
                material_missing = 0, material_original = 0,
                material_readback = nil, skeletal_components = 0 }
    return true
end

--- 【只丢引用，绝不碰引擎】
--- 世界重载/换地图时用这个。这是前几次访问违例崩溃的直接对策:
--- 在 LoadMapPre 那一刻去 K2_DestroyActor 旧世界的对象 = 和引擎抢析构。
function Ghost.forget(reason)
    Ghost.host = nil
    Ghost.root = nil
    Ghost.components = {}
    Ghost.skel_list = {}
    Ghost.skel_mesh = {}
    Ghost.comp_mesh = {}
    Ghost.comp_skel = {}
    Ghost.used = {}
    Ghost.mesh_assets = {}
    Ghost.visible = false
    Ghost.stats = { components = 0, failed_components = 0, instances = 0,
                skipped_no_mesh = 0, material_ok = 0, material_fail = 0,
                material_missing = 0, material_original = 0,
                material_readback = nil }
    if Log ~= nil then
        Log.line("[ghost] 已丢弃引用（不触碰引擎）: " .. tostring(reason))
    end
    return true
end

--- 世界换了吗？—— ★★ **只用于诊断/日志，绝对不要拿它决定"要不要跳过或销毁"**。
---
--- 2026-09-28 实测结论（玩家日志，两次事故）:
---   · 这个"标记"**每次调用都可能不同**:
---       `AActor: 0000016C81FEFAF8 -> AActor: 0000016C78405758 -> ...`
---     （世界里存在多个 PlayerController，`FindAllOf` 返回顺序不定，
---       而 `IsLocalPlayerController` 在 UE4SS 里似乎取不到 ⇒ 每次挑到不同的那个）；
---   · 一旦依它做判断:
---       跳过 → 提示全没了、投影不上变换（"放了什么都没有"）；
---       销毁 → 刚建好的投影被丢掉（"每次 0 件"）。
---   ⇒ **跨世界的唯一权威信号是 `LoadMapPre` 钩子**（日志证明它每次都正确触发）。
---     这个函数留着只为"哪天需要打印诊断信息"，不要在行为分支里用它。
function Ghost.stale_world()
    local t = Util.world_tag()
    if Ghost.world_name == nil or t == nil or t == "" or t == "no-tag" then
        return false
    end
    return Ghost.world_name ~= t
end

--- 投影在"哪个世界"里建出来的（fill 时记录）
Ghost.world_name = nil

function Ghost.describe()
    local s = Ghost.stats
    local mat = "无"
    if Ghost.material_mode == "original" then
        mat = "不覆盖"
    elseif Util.usable(Ghost.material) then
        mat = "有"
    end
    return string.format(
        "投影: 宿主=%s 组件=%d(失败 %d) 实例=%d 缺网格=%d 材质[%s]=%s(成功 %d/失败 %d/缺 %d) 模式=%s",
        Util.valid(Ghost.host) and "有" or "无",
        s.components, s.failed_components or 0, s.instances,
        s.skipped_no_mesh, tostring(Ghost.material_mode), mat,
        s.material_ok or 0, s.material_fail or 0, s.material_missing or 0,
        tostring(Ghost.instance_mode))
end

--- 当前材质模式的说明（含具体资产名）
function Ghost.material_description()
    return string.format("%s  (%s)", tostring(Ghost.material_mode),
        tostring(Ghost.material_note or "?"))
end

--- 材质回读结果（"材质到底有没有真的设上去"的硬证据）
function Ghost.material_readback()
    local s = Ghost.stats or {}
    return s.material_readback
end

-- --------------------------------------------------------------------------
-- 对外主入口
-- --------------------------------------------------------------------------

--- 准备渲染环境（生成宿主 + 找材质）。返回 ok, err
function Ghost.prepare(config)
    Ghost.last_error = nil
    if config ~= nil and config.get ~= nil and not config.get("ghost_enabled") then
        Ghost.last_error = "config.ghost_enabled = false"
        return false, Ghost.last_error
    end
    local ok, why, caps = Ghost.check_gate(nil)
    if not ok then
        Ghost.last_error = why
        return false, why
    end

    -- 探测时若局部空间 AddInstance 不可用，只会退回 AddInstanceWorldSpace，
    -- 那种模式下移动投影必须重建实例。这里把结论接过来。
    local add = caps and caps.add_instance
    if type(add) == "table" and type(add.detail) == "string"
        and add.detail:find("AddInstanceWorldSpace", 1, true)
        and not add.detail:find("AddInstance(tf", 1, true) then
        Ghost.instance_mode = "world"
    else
        Ghost.instance_mode = "local"
    end

    -- 材质模式（配置里可以指定，游戏里用小键盘 * 循环切换）
    if config ~= nil and config.get ~= nil then
        local mode = config.get("ghost_material")
        if type(mode) == "string" then
            Ghost.material_mode = mode
        end
    end

    if Util.valid(Ghost.host) then return true, nil end

    local _, err = acquire_host(nil)
    if err ~= nil then
        Ghost.last_error = err
        return false, err
    end
    local mat, which = resolve_material(nil)
    Ghost.material = mat
    if mat == nil then
        Log.emit("[ghost] 警告: 没找到材质 —— 投影会显示成 UE 自带的灰白网格材质")
        print("[PWBP] WARNING: no material found -- ghost will look like"
            .. " the default grey grid material")
    else
        Log.emit("[ghost] 材质: " .. tostring(which) .. "   "
            .. tostring(Util.full_name(mat)))
    end
    return true, nil
end

return Ghost
