--[[ ===========================================================================
  PWBP · probe  ——  渲染前置能力探测（阶段 S3）

  为什么要有这个东西
  ------------------
  我在这个项目上已经崩过 3 次游戏，全部发生在"以为一定没问题"的引擎调用上。
  教训是: 光靠读别人的代码推断 API 是不够的，必须在本机、本版本上实测。

  所以把"投影渲染"需要的每一个原语拆成一步，逐步执行、逐步落盘:

      ★ 每一步【执行前】先把 "STEP n START" 写进 pwbp_probe.txt
      ★ 每一步【执行后】再写结果
      ★ 于是如果游戏崩了，文件里最后那条 START 就是崩溃点

  这和 PWRecon 的 worldcheck 是同一套思路，但有两个改进:
      1. 记的是"开始"而不是"结束"，所以崩溃点不会歧义
      2. 结果同时写进 pwbp_capabilities.json，被 pwbp_ghost 当作门禁:
         没有探测通过的项，投影渲染会拒绝执行

  安全阀
  ------
    · 第 1..16 步全是只读（FindAllOf / 读属性 / LoadAsset）
    · 第 17 步开始才真正创建对象，且一定会在最后被销毁
    · config 里的 probe_max_step 可以只跑到某一步就停（0 = 全跑）
    · 即使中途停下，只要已经创建过宿主，也会补跑销毁步骤
    · 只读步骤失败不会中止；写步骤失败会中止后续依赖它的步骤
=========================================================================== ]]

local Util = require("pwbp_util")
local Json = require("pwbp_json")
local Log = require("pwbp_log")
local MeshMap = require("pwbp_meshmap")
local Hud = require("pwbp_hud")
local Sched = require("pwbp_sched")
local Config = require("pwbp_config")

local Probe = {}

Probe.FILE = "pwbp_probe.txt"
Probe.CAPS_FILE = "pwbp_capabilities.json"

Probe.caps = {}            -- id -> { ok=bool, detail=string }
Probe.last_summary = nil
Probe.ctx = nil

-- --------------------------------------------------------------------------
-- 小工具
-- --------------------------------------------------------------------------

local function cap(id, ok, detail)
    Probe.caps[id] = { ok = ok == true, detail = tostring(detail or "") }
    return ok == true
end

local function find_class(path)
    local ok, obj = pcall(function() return StaticFindObject(path) end)
    if not ok then return nil, "StaticFindObject 抛错" end
    if obj == nil then return nil, "找不到 " .. path end
    if not Util.usable_class(obj) then return nil, "找到但不是可用的类" end
    return obj
end

local function first_valid(list)
    if type(list) ~= "table" then return nil end
    for i = 1, #list do
        local v = Util.unwrap(list[i])
        if Util.usable(v) then return v end
    end
    return nil
end

--- 找一个可用的、已加载的静态网格（优先 Palworld 建筑资产）
local function pick_probe_mesh()
    local n = MeshMap.build_registry()
    if type(n) ~= "number" or n == 0 or #MeshMap.entries == 0 then
        return nil, nil
    end
    local best = nil
    for i = 1, #MeshMap.entries do
        local e = MeshMap.entries[i]
        if e.path:find("/Architecture/", 1, true) then
            best = best or e.path
        end
    end
    if best == nil then
        best = MeshMap.entries[1] and MeshMap.entries[1].path or nil
    end
    return best, nil
end

--- LoadAsset(path) -> 有效对象
local function load_asset(path)
    if type(path) ~= "string" or path == "" then return nil, "空路径" end
    if type(LoadAsset) ~= "function" then return nil, "LoadAsset 不存在" end
    local ok, res = pcall(function() return LoadAsset(path) end)
    local obj = ok and Util.unwrap(res) or nil
    if Util.usable(obj) then return obj, nil end
    -- 有的 UE4SS 版本 LoadAsset 只负责把包加载进内存，还要再 Find 一次
    local ok2, obj2 = pcall(function() return StaticFindObject(path) end)
    if ok2 and Util.usable(obj2) then return Util.unwrap(obj2), nil end
    return nil, "LoadAsset 后仍拿不到有效对象"
end

-- --------------------------------------------------------------------------
-- 步骤定义
--
-- 每个 fn(ctx) 返回 ok, detail
-- kind: "read" 只读（失败也无害） / "write" 会创建或修改对象
-- --------------------------------------------------------------------------

local STEPS = {
    -- ============ 第一段：环境（只读） ============
    {
        id = "sched", kind = "read",
        title = "UE4SS 游戏线程调度器",
        fn = function()
            local ok = Sched.detect()
            return ok, Sched.describe()
        end,
    },
    {
        id = "uehelpers", kind = "read",
        title = "require(\"UEHelpers\")",
        fn = function(ctx)
            local ok, mod = pcall(require, "UEHelpers")
            if not ok or type(mod) ~= "table" then
                return false, "require 失败: " .. tostring(mod)
            end
            ctx.uehelpers = mod
            local v = "?"
            pcall(function() v = mod.GetUEHelpersVersion() end)
            return true, "UEHelpers 版本 " .. tostring(v)
        end,
    },
    {
        id = "get_world", kind = "read",
        title = "UEHelpers.GetWorld()",
        fn = function(ctx)
            if ctx.uehelpers == nil then return false, "UEHelpers 不可用" end
            local ok, w = pcall(ctx.uehelpers.GetWorld)
            if not ok then return false, "调用抛错" end
            ctx.world = Util.unwrap(w)
            if not Util.valid(ctx.world) then return false, "World 无效" end
            return true, "World = " .. tostring(Util.full_name(ctx.world))
        end,
    },
    {
        id = "get_pawn", kind = "read",
        title = "UEHelpers.GetPlayer()",
        fn = function(ctx)
            if ctx.uehelpers == nil then return false, "UEHelpers 不可用" end
            local ok, p = pcall(ctx.uehelpers.GetPlayer)
            if not ok then return false, "调用抛错" end
            ctx.pawn = Util.unwrap(p)
            if not Util.valid(ctx.pawn) then return false, "Pawn 无效" end
            local x, y, z = Util.loc_of(ctx.pawn)
            if x == nil then return true, "Pawn 有效（但坐标读不到）" end
            return true, string.format("Pawn 位置 %.1f %.1f %.1f 米",
                x / 100, y / 100, z / 100)
        end,
    },
    {
        id = "kismet", kind = "read",
        title = "UKismetSystemLibrary",
        fn = function(ctx)
            if ctx.uehelpers == nil then return false, "UEHelpers 不可用" end
            local ok, k = pcall(ctx.uehelpers.GetKismetSystemLibrary)
            if not ok then return false, "调用抛错" end
            ctx.kismet = Util.unwrap(k)
            if not Util.valid(ctx.kismet) then return false, "对象无效" end
            return true, "可用"
        end,
    },
    {
        id = "gameplay_statics", kind = "read",
        title = "UGameplayStatics",
        fn = function(ctx)
            if ctx.uehelpers == nil then return false, "UEHelpers 不可用" end
            local ok, g = pcall(ctx.uehelpers.GetGameplayStatics)
            if not ok then return false, "调用抛错" end
            ctx.gameplay = Util.unwrap(g)
            if not Util.valid(ctx.gameplay) then return false, "对象无效" end
            return true, "可用（备用生成路径）"
        end,
    },
    {
        id = "class_actor", kind = "read",
        title = "/Script/Engine.Actor",
        fn = function(ctx)
            local c, err = find_class("/Script/Engine.Actor")
            if c == nil then return false, err end
            ctx.class_actor = c
            return true, Util.full_name(c) or "ok"
        end,
    },
    {
        id = "class_scene_component", kind = "read",
        title = "/Script/Engine.SceneComponent",
        fn = function(ctx)
            local c, err = find_class("/Script/Engine.SceneComponent")
            if c == nil then return false, err end
            ctx.class_scene = c
            return true, Util.full_name(c) or "ok"
        end,
    },
    {
        id = "class_static_mesh_component", kind = "read",
        title = "/Script/Engine.StaticMeshComponent",
        fn = function(ctx)
            local c, err = find_class("/Script/Engine.StaticMeshComponent")
            if c == nil then return false, err end
            ctx.class_smc = c
            return true, Util.full_name(c) or "ok"
        end,
    },
    {
        id = "class_ism_component", kind = "read",
        title = "/Script/Engine.InstancedStaticMeshComponent",
        fn = function(ctx)
            local c, err = find_class(
                "/Script/Engine.InstancedStaticMeshComponent")
            if c == nil then return false, err end
            ctx.class_ism = c
            return true, Util.full_name(c) or "ok"
        end,
    },

    -- ============ 第三段：材质与网格（只读 + 加载） ============
    {
        id = "material_highlight", kind = "read",
        title = "PalMapObjectManager.BuildingSurfaceMaterialSet.Highlight",
        fn = function(ctx)
            local list = FindAllOf("PalMapObjectManager")
            local mgr = first_valid(list)
            if mgr == nil then return false, "找不到 PalMapObjectManager 实例" end
            ctx.mapobject_manager = mgr
            local set = Util.prop(mgr, "BuildingSurfaceMaterialSet")
            if set == nil then return false, "读 BuildingSurfaceMaterialSet 失败" end
            local hi = Util.unwrap(Util.prop(set, "Highlight"))
            if not Util.usable(hi) then
                ctx.material_set = set
                return false, "Highlight 无效"
            end
            ctx.material_set = set
            ctx.material_highlight = hi
            return true, "可用（游戏自带的「可放置」材质）"
        end,
    },
    {
        id = "material_error", kind = "read",
        title = "BuildingSurfaceMaterialSet.Error",
        fn = function(ctx)
            if ctx.material_set == nil then return false, "材质集不可用" end
            local er = Util.unwrap(Util.prop(ctx.material_set, "Error"))
            if not Util.usable(er) then return false, "Error 无效" end
            ctx.material_error = er
            return true, "可用（游戏自带的「不可放置」材质）"
        end,
    },
    {
        id = "material_fallback_load", kind = "write",
        title = "LoadAsset 备用材质 MI_LooksPredicatorError",
        fn = function(ctx)
            local obj, err = load_asset(
                "/Game/Pal/Material/MapObject/BuildObject/BuildingProcess/"
                .. "MI_LooksPredicatorError.MI_LooksPredicatorError")
            if obj == nil then return false, err end
            ctx.material_fallback = obj
            return true, "已加载"
        end,
    },
    {
        id = "mesh_registry", kind = "read",
        title = "FindAllOf(\"StaticMesh\") 网格注册表（可能要几秒，会卡一下）",
        fn = function(ctx)
            local n, err = MeshMap.build_registry(true)
            if type(n) ~= "number" then return false, tostring(err) end
            ctx.mesh_count = n
            if n == 0 then return false, "注册表为空" end
            return true, string.format("%d 个已加载网格", n)
        end,
    },
    {
        id = "mesh_pick", kind = "read",
        title = "挑一个可用的测试网格",
        fn = function(ctx)
            local path = pick_probe_mesh()
            if path == nil then return false, "没有可用网格" end
            ctx.mesh_path = path
            return true, path
        end,
    },

    -- ============ 第四段：真正的创建（写） ============
    {
        id = "load_mesh_asset", kind = "write",
        title = "LoadAsset 载入测试网格",
        fn = function(ctx)
            if ctx.mesh_path == nil then return false, "没有测试网格路径" end
            local obj, err = load_asset(ctx.mesh_path)
            if obj == nil then return false, err end
            ctx.mesh_asset = obj
            return true, tostring(Util.full_name(obj))
        end,
    },
    {
        id = "spawn_host", kind = "write",
        title = "生成宿主 Actor（第一个会创建对象的步骤）",
        fn = function(ctx)
            if ctx.world == nil then return false, "World 不可用" end
            local attempts = {}
            local class_list = {
                { label = "Engine.Actor", cls = ctx.class_actor },
            }
            local class_sma, err_sma = find_class("/Script/Engine.StaticMeshActor")
            if class_sma ~= nil then
                class_list[#class_list + 1] =
                    { label = "Engine.StaticMeshActor", cls = class_sma }
            else
                attempts[#attempts + 1] = "StaticMeshActor 类不可用: "
                    .. tostring(err_sma)
            end

            for ci = 1, #class_list do
                local entry = class_list[ci]
                if entry.cls ~= nil then
                    -- 路径 A: UWorld:SpawnActor(Class, Transform, Params)
                    local okA, actorA = pcall(function()
                        return ctx.world:SpawnActor(entry.cls, {}, {})
                    end)
                    local a = okA and Util.unwrap(actorA) or nil
                    if Util.valid(a) then
                        ctx.host = a
                        ctx.host_class = entry.label
                        ctx.host_method = "World:SpawnActor"
                        return true, string.format("%s via World:SpawnActor",
                            entry.label)
                    end
                    attempts[#attempts + 1] = string.format(
                        "%s/World:SpawnActor 失败 ok=%s err=%s",
                        entry.label, tostring(okA), tostring(actorA))

                    -- 路径 B: GameplayStatics 延迟生成
                    if Util.valid(ctx.gameplay) then
                        local tf = Util.identity_transform()
                        local okB, actorB = pcall(function()
                            return ctx.gameplay:BeginDeferredActorSpawnFromClass(
                                ctx.world, entry.cls, tf, 0, nil)
                        end)
                        local b = okB and Util.unwrap(actorB) or nil
                        if Util.valid(b) then
                            local okF = pcall(function()
                                ctx.gameplay:FinishSpawningActor(b, tf)
                            end)
                            if okF and Util.valid(b) then
                                ctx.host = b
                                ctx.host_class = entry.label
                                ctx.host_method = "BeginDeferred+Finish"
                                return true, string.format(
                                    "%s via BeginDeferredActorSpawnFromClass",
                                    entry.label)
                            end
                            attempts[#attempts + 1] = string.format(
                                "%s/FinishSpawningActor 失败", entry.label)
                        else
                            attempts[#attempts + 1] = string.format(
                                "%s/BeginDeferred 失败 ok=%s err=%s",
                                entry.label, tostring(okB), tostring(actorB))
                        end
                    end
                end
            end
            return false, table.concat(attempts, " | ")
        end,
    },
    {
        id = "add_root_component", kind = "write",
        title = "宿主 AddComponentByClass(SceneComponent) 作为根",
        fn = function(ctx)
            if not Util.valid(ctx.host) then return false, "没有宿主" end
            if ctx.class_scene == nil then return false, "SceneComponent 类不可用" end
            local ok, c = pcall(function()
                return ctx.host:AddComponentByClass(
                    ctx.class_scene, true, Util.identity_transform(), false)
            end)
            local comp = ok and Util.unwrap(c) or nil
            if not Util.valid(comp) then
                return false, "AddComponentByClass 失败 err=" .. tostring(c)
            end
            ctx.root = comp
            local setup_ok, setup_err = pcall(function()
                comp:SetMobility(2)
                comp:SetAbsolute(true, true, true)
            end)
            if not setup_ok then
                return true, "组件已创建，但 SetMobility/SetAbsolute 失败: "
                    .. tostring(setup_err)
            end
            return true, "已创建并设为绝对变换"
        end,
    },
    {
        id = "add_ism_component", kind = "write",
        title = "宿主 AddComponentByClass(InstancedStaticMeshComponent)",
        fn = function(ctx)
            if not Util.valid(ctx.host) then return false, "没有宿主" end
            if ctx.class_ism == nil then return false, "ISM 类不可用" end
            local ok, c = pcall(function()
                return ctx.host:AddComponentByClass(
                    ctx.class_ism, true, Util.identity_transform(), false)
            end)
            local comp = ok and Util.unwrap(c) or nil
            if not Util.valid(comp) then
                return false, "AddComponentByClass 失败 err=" .. tostring(c)
            end
            ctx.ism = comp
            pcall(function()
                comp:SetMobility(2)
                comp:SetAbsolute(true, true, true)
            end)
            return true, "已创建 ISM 组件"
        end,
    },
    {
        id = "configure_component", kind = "write",
        title = "配置组件（碰撞/阴影/可见性）",
        fn = function(ctx)
            if not Util.valid(ctx.ism) then return false, "没有 ISM 组件" end
            local failed = {}
            local function try(what, fn)
                local ok = pcall(fn)
                if not ok then failed[#failed + 1] = what end
            end
            try("SetCollisionEnabled", function() ctx.ism:SetCollisionEnabled(0) end)
            try("SetGenerateOverlapEvents", function()
                ctx.ism:SetGenerateOverlapEvents(false) end)
            try("SetCastShadow", function() ctx.ism:SetCastShadow(false) end)
            try("SetReceivesDecals", function() ctx.ism:SetReceivesDecals(false) end)
            try("SetRenderInMainPass", function()
                ctx.ism:SetRenderInMainPass(true) end)
            try("SetVisibility", function() ctx.ism:SetVisibility(true, true) end)
            try("SetHiddenInGame", function()
                ctx.ism:SetHiddenInGame(false, true) end)
            if #failed > 0 then
                return true, "部分失败: " .. table.concat(failed, ",")
            end
            return true, "全部成功"
        end,
    },
    {
        id = "attach_component", kind = "write",
        title = "K2_AttachToComponent（可选，失败不影响渲染）",
        fn = function(ctx)
            if not Util.valid(ctx.ism) or not Util.valid(ctx.root) then
                return false, "缺少 ISM 或根组件"
            end
            local ok = pcall(function()
                ctx.ism:K2_AttachToComponent(ctx.root, FName("None"), 0, 0, 0, false)
            end)
            if not ok then return false, "K2_AttachToComponent 失败" end
            pcall(function() ctx.ism:SetAbsolute(false, false, false) end)
            return true, "已挂到根组件下"
        end,
    },
    {
        id = "set_static_mesh", kind = "write",
        title = "ISM:SetStaticMesh",
        fn = function(ctx)
            if not Util.valid(ctx.ism) then return false, "没有 ISM 组件" end
            if ctx.mesh_asset == nil then return false, "没有网格资产" end
            local ok = pcall(function() ctx.ism:SetStaticMesh(ctx.mesh_asset) end)
            if not ok then return false, "SetStaticMesh 失败" end
            local got = nil
            pcall(function() got = Util.full_name(ctx.ism.StaticMesh) end)
            if got == nil then
                return true, "调用成功，但回读 StaticMesh 失败（不一定有问题）"
            end
            return true, "已设置，回读 = " .. tostring(got)
        end,
    },
    {
        id = "set_material", kind = "write",
        title = "ISM:SetMaterial(0, ...)",
        fn = function(ctx)
            if not Util.valid(ctx.ism) then return false, "没有 ISM 组件" end
            local mat = ctx.material_highlight or ctx.material_fallback
            if not Util.usable(mat) then return false, "没有可用材质" end
            local n = -1
            pcall(function() n = ctx.ism:GetNumMaterials() end)
            local ok = pcall(function() ctx.ism:SetMaterial(0, mat) end)
            if not ok then return false, "SetMaterial 失败（槽位 0）" end
            return true, string.format("已设置槽位 0（组件材质槽数 %s）", tostring(n))
        end,
    },
    {
        id = "set_component_transform", kind = "write",
        title = "组件变换 K2_SetRelativeTransform / K2_SetWorldLocation",
        fn = function(ctx)
            if not Util.valid(ctx.ism) then return false, "没有 ISM 组件" end
            local tf = Util.transform_at(0.0, 0.0, 0.0, 0.0)
            local okR = pcall(function()
                ctx.ism:K2_SetRelativeTransform(tf, false, {}, true)
            end)
            if okR then return true, "K2_SetRelativeTransform 成功" end
            local okW = pcall(function()
                ctx.ism:K2_SetWorldLocation({ X = 0.0, Y = 0.0, Z = 0.0 },
                    false, {}, true)
            end)
            if okW then return true, "退回 K2_SetWorldLocation 成功" end
            return false, "两种变换设置都失败"
        end,
    },
    {
        id = "add_instance", kind = "write",
        title = "ISM:AddInstance / AddInstanceWorldSpace",
        fn = function(ctx)
            if not Util.valid(ctx.ism) then return false, "没有 ISM 组件" end
            local tf = Util.transform_at(0.0, 0.0, 0.0, 0.0)

            -- 首选: 局部空间 AddInstance(tf, false) —— 移动时只要改变组件变换
            local ok1, r1 = pcall(function()
                return ctx.ism:AddInstance(tf, false)
            end)
            if ok1 then
                ctx.instance_mode = "local"
                return true, "AddInstance(tf, false) 局部空间可用 -> " .. tostring(r1)
            end

            -- 次选: AddInstance(tf) 单参数（老版本签名）
            local ok2, r2 = pcall(function()
                return ctx.ism:AddInstance(tf)
            end)
            if ok2 then
                ctx.instance_mode = "local"
                return true, "AddInstance(tf) 局部空间可用 -> " .. tostring(r2)
            end

            -- 兜底: 世界空间（移动时要重建实例，性能差但能用）
            local ok3, r3 = pcall(function()
                return ctx.ism:AddInstanceWorldSpace(tf)
            end)
            if ok3 then
                ctx.instance_mode = "world"
                return true, "AddInstanceWorldSpace 可用（移动需重建实例） -> "
                    .. tostring(r3)
            end

            return false, string.format(
                "三种都失败: (tf,false)=%s (tf)=%s worldSpace=%s",
                tostring(r1), tostring(r2), tostring(r3))
        end,
    },
    {
        id = "clear_instances", kind = "write",
        title = "ISM:ClearInstances",
        fn = function(ctx)
            if not Util.valid(ctx.ism) then return false, "没有 ISM 组件" end
            local ok = pcall(function() ctx.ism:ClearInstances() end)
            if not ok then return false, "ClearInstances 失败" end
            local n = -1
            pcall(function() n = ctx.ism:GetInstanceCount() end)
            return true, "已清空，实例数 = " .. tostring(n)
        end,
    },

    -- ============ 第五段：清理（无论前面如何都会跑） ============
    {
        id = "destroy_host", kind = "write", always = true,
        title = "销毁宿主 Actor",
        fn = function(ctx)
            if not Util.valid(ctx.host) then
                return true, "没有需要销毁的宿主（正常）"
            end
            local ok = pcall(function() ctx.host:K2_DestroyActor() end)
            if not ok then
                local ok2 = pcall(function() ctx.host:DestroyActor() end)
                if not ok2 then return false, "两种销毁调用都失败" end
            end
            ctx.host = nil
            return true, "已销毁"
        end,
    },

    -- ============ 第六段：已知会崩的东西（不调用，只登记）============
    --
    -- ★ 2026-09-26 18:15 实测：这一条一调用就崩游戏。
    --   所以这里【只登记结论】、不做任何引擎调用。
    --   以前它是第 28 步，导致 27 步的成果全部没写进 capabilities.json。
    --
    --   将来要重新评估屏幕文字，不要在探测流程里"顺手再试一次" ——
    --   那会再崩一次游戏。要试就单独设计一个最小实验。
    {
        id = "hud_print", kind = "read",
        title = "屏幕文字 PrintString（★已知会崩，仅登记，不调用）",
        fn = function()
            return false,
                "已知会崩游戏（实测 2026-09-26 18:15），本步骤不发起任何调用"
        end,
    },
}

-- ==========================================================================
-- 第七段 S9: 屏幕提示通道（按 O 单独跑，不跑前面 28 步）
--
-- 目标: 找出"把一行文字显示在游戏画面上"的可用通道。
-- 背景: PrintString 会崩（上面那条），所以必须另找路径。
--
-- ★ 方法论（这是本段最重要的部分）:
--   1) **先枚举，再调用。** 用反射（ForEachFunction / ForEachProperty）
--      把游戏里真实存在的函数名和**参数签名**读出来，写进 pwbp_ui.txt。
--      不猜类名、不猜参数个数 —— 本项目的教训（见 docs 5b 节）就是"猜类名"。
--   2) 参数个数没看清之前**绝不去调那个函数**。PrintString 就是这么崩的。
--   3) 唯一会真的调用游戏函数的步骤是最后一条 s9_send_test，
--      它被配置开关挡住，默认不执行。
-- ==========================================================================

Probe.UI_FILE = "pwbp_ui.txt"

local function ui_write(lines, overwrite)
    local path = Util.join(Util.script_dir, Probe.UI_FILE)
    local text = table.concat(lines, "\r\n") .. "\r\n"
    if overwrite then return Util.write_file(path, text, true) end
    return Util.append_file(path, text)
end

--- 候选名字表 —— ★ 全部来自【本机实机证据】或 UE 官方 API 名，不是凭空猜的
---
--- 证据来源:
---   Mods\FirstPerson\Scripts\main.lua（实机在用）:
---     · 拿玩家控制器: FindFirstOf("BP_PalPlayerController_C")
---     · Palworld 的 UI 类是蓝图控件，命名形如
---       "WBP_Graphic_Settings.WBP_Graphic_Settings_C"
---     · 文本控件的属性名形如 BP_PalTextBlock_Name，用 SetText(FText(...)) 设字
---   UE 官方 APlayerController 接口: ClientMessage / AddOnScreenDebugMessage ...
---
--- ★★ 为什么改成"候选名单 + 存在性检查"，而不再做反射枚举:
---   obj:ForEachFunction / obj:ForEachProperty 在本构建里【实测把游戏打崩】
---   （2026-09-27 16:19，按 O 的第 2 步，崩溃栈 80 帧全在 UE4SS 里）。
---   见 docs\踩坑记录.md 第 17 节 —— 而且 3c-3 / 3f-2 早就记过
---   "ForEachProperty 确认不可用"。
---   所以反射枚举【永久禁用】(luacheck 第 11 项会拦)，
---   只保留本项目用了几个月的两种安全操作:
---     FindAllOf("精确类名")  ／  obj.方法名 存在性查询
local PC_METHOD_CANDIDATES = {
    -- UE 标准 APlayerController 接口（参数个数是公开已知的）
    "ClientMessage", "AddOnScreenDebugMessage", "ClientSetHUD", "GetHUD",
    -- Palworld 可能有的消息/提示接口（只查"存不存在"，不调用）
    "ShowSystemMessage", "DisplaySystemMessage", "ShowMessage", "DisplayMessage",
    "ShowNotice", "AddNotice", "ShowToast", "ShowPopup", "ShowError",
    "ClientShowMessage", "ClientShowSystemMessage", "ClientNotice",
    "ShowTips", "ShowTutorial", "ShowBuildGuide",
}

--- ★ 对照组：这些方法【我们已经在用】，所以它们必须被判为"存在"。
---
--- 为什么要对照组（2026-09-27 的教训）:
---   第一版把三个 `WBP_*_Settings_C` 当对照组，说"如果它们也是 0，
---   说明查询方式不管用"。**这个推理是错的** ——
---   设置页控件只在打开设置菜单时才存在，平时本来就查不到。
---   对照组必须是"**此刻一定在**"的东西。
---   `GetControlRotation` 是 `pwbp_session.lua` 里一直在用的（读视角朝向），
---   所以它一定可调用 —— 用它来验证"方法名查询"这条路本身是通的。
local PC_METHOD_CONTROLS = {
    "GetControlRotation", "GetPawn", "GetWorld",
}

local CLASS_CANDIDATES = {
    -- ★★ 实机确认存在的通知控件（2026-09-27 探测命中 1 个实例）:
    --    WBP_Notice_C /Game/Pal/Blueprint/UI/Log/WBP_NoticeLog.WBP_NoticeLog_C:WidgetTree.WBP_Notice
    --    ⇒ Palworld 的"通知/提示"系统在这里，名字是 Notice
    "WBP_NoticeLog_C", "WBP_Notice_C",
    -- 顺着 Notice 这个命名再往外找一圈
    "WBP_NoticeItem_C", "WBP_NoticeMessage_C", "WBP_Log_C", "WBP_MessageLog_C",
    -- 其它按 Palworld 的 WBP_ 命名风格猜的候选
    "WBP_SystemMessage_C", "WBP_Toast_C", "WBP_Message_C", "WBP_Popup_C",
    "WBP_IngameHUD_C", "WBP_HUD_C", "WBP_Ingame_C", "WBP_Tips_C",
    "WBP_PlayerHUD_C", "WBP_Overlay_C", "PalNotice_C", "PalHUD_C",
}

--- 要展开控件树的通知控件（按"最可能有文字"的顺序）
local NOTICE_WIDGET_CANDIDATES = {
    "WBP_Notice_C",       -- 实机确认存活的那个（在 WBP_NoticeLog 的 WidgetTree 里）
    "WBP_NoticeLog_C",    -- 它的宿主
    "WBP_NoticeItem_C",
}

local UI_STEPS = {
    {
        id = "s9_player_controller", kind = "read",
        title = "拿到本地 PlayerController（以后发文字的对象）",
        fn = function(ctx)
            local pc = Hud.find_pc()
            if pc == nil then
                ui_write({
                    "!! 拿不到 PlayerController。",
                    "   先进世界、能自由走动、画面稳定之后再按 O。",
                })
                return false, "拿不到 PlayerController（先进世界站稳再按 O）"
            end
            ctx.pc = pc
            ui_write({
                "",
                "=== 发送对象 ===",
                "PlayerController: " .. tostring(Util.full_name(pc)),
            })
            return true, tostring(Util.full_name(pc))
        end,
    },

    {
        id = "s9_ftext", kind = "read",
        title = "FText 构造（ASCII + 中文）与回读",
        fn = function(ctx)
            ctx = ctx
            local lines = {
                "",
                "=== FText ===",
                "全局 FText 构造函数存在: " .. tostring(FText ~= nil)
                    .. "   （证据: Mods\\FirstPerson 里 SetText(FText(\"第一人称\"))）",
            }
            local ft_a, e1 = Hud.ftext("PWBP-TEST")
            lines[#lines + 1] = "ASCII 构造: " .. ((ft_a ~= nil) and "OK" or ("失败 " .. tostring(e1)))
            if ft_a ~= nil then
                lines[#lines + 1] = "  回读: " ..
                    tostring(Hud.ftext_to_string(ft_a) or "(读不回来)")
            end
            local ft_c, e2 = Hud.ftext("蓝图投影")
            lines[#lines + 1] = "中文构造: " .. ((ft_c ~= nil) and "OK" or ("失败 " .. tostring(e2)))
            if ft_c ~= nil then
                lines[#lines + 1] = "  回读: " ..
                    tostring(Hud.ftext_to_string(ft_c) or "(读不回来)")
            end
            lines[#lines + 1] = "★ 回读能拿到中文原文 = 中文这条路是通的。"
            lines[#lines + 1] = "  回读读不回来只说明没有回读函数，**不代表发送会失败**。"
            ui_write(lines)
            return (ft_a ~= nil), ((ft_a ~= nil) and "FText 可用" or tostring(e1))
        end,
    },

    {
        id = "s9_widgetlib", kind = "read",
        title = "UMG 静态函数库 CDO（将来做自己的提示控件才需要）",
        fn = function(ctx)
            ctx = ctx
            local lib = nil
            pcall(function()
                lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
            end)
            local usable = Util.usable(lib)
            local create = nil
            if usable then pcall(function() create = lib.Create end) end
            ui_write({
                "",
                "=== UMG ===",
                "/Script/UMG.Default__WidgetBlueprintLibrary: " .. (usable and "可用" or "拿不到"),
                "  lib:Create（创建控件）: " .. ((create ~= nil) and "存在" or "不存在"),
                "★ 这条只是备选路线: 真要自己造提示控件才需要它。",
            })
            return usable, usable
                and ("UMG 库可用（Create 存在=" .. tostring(create ~= nil) .. "）")
                or "拿不到 UMG 库"
        end,
    },

    {
        id = "s9_candidates", kind = "read",
        title = "候选名单存在性检查（方法名查询 + FindAllOf）—— 替代会崩的反射枚举",
        fn = function(ctx)
            local lines = {
                "",
                "=== 候选名单检查（只判断「存不存在 / 有几个」，一律不调用）===",
                "★ 为什么是候选名单而不是枚举: obj:ForEachFunction / ForEachProperty",
                "  在本构建里把游戏打崩了（2026-09-27 16:19，S9 第 2 步，崩溃栈全在 UE4SS）。",
                "  见 docs\\踩坑记录.md 第 17 节。反射枚举已永久禁用（luacheck 第 11 项会拦）。",
            }
            local found_methods, found_classes = 0, 0

            --- 查一个类名。返回 (数量, 说明, 实例全名样例)
            --- ★ 实测发现: FindAllOf 在没有匹配时【返回 nil 而不是空表】，
            ---   所以不能把"nil"一律当成"查询失败"（第一版就报错成"查询失败"了）。
            local function class_count(nm)
                local ok, lst = pcall(function() return FindAllOf(nm) end)
                if not ok then return -1, "抛错: " .. tostring(lst), nil end
                if type(lst) ~= "table" then return -1, "返回 " .. type(lst), nil end
                local sample = nil
                if #lst > 0 then
                    pcall(function() sample = Util.full_name(lst[1]) end)
                end
                return #lst, nil, sample
            end

            --- 一行信号文本
            local function sig_text(s)
                if s == nil then return "（取不到）" end
                return string.format("type=%-8s __call=%-5s usable=%-5s",
                    tostring(s.type), tostring(s.has_call), tostring(s.usable))
            end

            -- ---- 1) 先用【对照组】定标: 什么信号才代表"这个方法真的能用" ----
            --
            -- ★★ 为什么必须这么做（2026-09-27 两次实测纠正）:
            --   第一版: 以为不存在时返回 nil          → 错，返回 userdata
            --   第二版: 以为 userdata = 占位、不可用   → **也错**
            --           `GetControlRotation`（每帧都在用）同样是 userdata！
            --   所以判据不能写死，只能用"已知可用的方法"当基准反推。
            local ctrl = {}
            local rule, classify
            if ctx.pc == nil then
                lines[#lines + 1] = ""
                lines[#lines + 1] = "--- 对照组 ---"
                lines[#lines + 1] = "  (没有 PlayerController，无法定标)"
                rule = "无法定标"
                classify = function() return false end
            else
                for i = 1, #PC_METHOD_CONTROLS do
                    ctrl[i] = Hud.method_signals(ctx.pc, PC_METHOD_CONTROLS[i])
                end
                local all_call, all_usable = true, true
                for i = 1, #ctrl do
                    if ctrl[i] == nil or ctrl[i].has_call ~= true then all_call = false end
                    if ctrl[i] == nil or ctrl[i].usable ~= true then all_usable = false end
                end
                if all_call then
                    rule = "mt.__call 存在（userdata 靠 __call 才能被调用）"
                    classify = function(s) return s ~= nil and s.has_call == true end
                elseif all_usable then
                    rule = "GetFullName 可读（Util.usable）"
                    classify = function(s) return s ~= nil and s.usable == true end
                else
                    rule = "type=='function'（★ 对照组都没通过，结论本身就不可信）"
                    classify = function(s) return s ~= nil and s.type == "function" end
                end
                lines[#lines + 1] = ""
                lines[#lines + 1] = "--- 对照组：这些方法我们已经在用，用它们定标 ---"
                for i = 1, #PC_METHOD_CONTROLS do
                    lines[#lines + 1] = string.format("  %-22s %s",
                        PC_METHOD_CONTROLS[i], sig_text(ctrl[i]))
                end
            end
            lines[#lines + 1] = "  ⇒ 本次采用的判定依据: " .. tostring(rule)

            lines[#lines + 1] = ""
            lines[#lines + 1] = "--- PlayerController 上的方法候选 ---"
            local pc = ctx.pc
            if pc == nil then
                lines[#lines + 1] = "  (上一步没拿到 PlayerController，跳过)"
            else
                for i = 1, #PC_METHOD_CANDIDATES do
                    local nm = PC_METHOD_CANDIDATES[i]
                    local s = Hud.method_signals(pc, nm)
                    if classify(s) then
                        found_methods = found_methods + 1
                        lines[#lines + 1] = string.format("  ★ %-28s %s", nm, sig_text(s))
                    else
                        lines[#lines + 1] = string.format("    %-28s %s", nm, sig_text(s))
                    end
                end
            end

            lines[#lines + 1] = ""
            lines[#lines + 1] = "--- 类名候选（FindAllOf，数字 = 当前存活实例数）---"
            for i = 1, #CLASS_CANDIDATES do
                local nm = CLASS_CANDIDATES[i]
                local cnt, why, sample = class_count(nm)
                if cnt > 0 then
                    found_classes = found_classes + 1
                    lines[#lines + 1] = string.format("  ★ %-28s %d 个   例: %s",
                        nm, cnt, tostring(sample))
                elseif cnt < 0 then
                    lines[#lines + 1] = string.format("  ?  %-28s %s", nm, tostring(why))
                else
                    lines[#lines + 1] = string.format("     %-28s 0 个（FindAllOf 无匹配）", nm)
                end
            end

            lines[#lines + 1] = ""
            lines[#lines + 1] = string.format("小计: 方法命中 %d / %d，类命中 %d / %d",
                found_methods, #PC_METHOD_CANDIDATES, found_classes, #CLASS_CANDIDATES)
            lines[#lines + 1] = "★ 判读要点:"
            lines[#lines + 1] = "  · 对照组 type 不是 function → 说明「方法名查询」这条路本身有问题，"
            lines[#lines + 1] = "    此时所有「没有/占位」都不可信（别把工具问题当成游戏事实）。"
            lines[#lines + 1] = "  · 类名候选里若「0 个」，可能是该类此刻真的没有存活实例"
            lines[#lines + 1] = "    （UMG 控件是按需创建的，比如设置页只在打开菜单时存在）。"
            ui_write(lines)
            return true, string.format("方法命中 %d，类命中 %d（含对照组）",
                found_methods, found_classes)
        end,
    },

    {
        id = "s9_hud", kind = "read",
        title = "HUD 对象上的消息接口候选（ClientMessage 已证实是真的，看看 HUD 上有没有更好的）",
        fn = function(ctx)
            local lines = { "", "=== HUD 对象（pc:GetHUD()）===" }
            local pc = ctx.pc
            if pc == nil then
                lines[#lines + 1] = "  (没有 PlayerController)"
                ui_write(lines)
                return false, "没有 PlayerController"
            end
            local hud = nil
            pcall(function() hud = pc:GetHUD() end)
            lines[#lines + 1] = string.format("  GetHUD() -> %s   usable=%s",
                tostring(Util.full_name(hud)), tostring(Util.usable(hud)))
            -- ★ 判据（实测得来）: 看 Util.usable（GetFullName 能调通）。
            --   19 个候选里 usable=true 的只有 4 个，其中 GetControlRotation 是
            --   我们每帧都在用的对照组 —— 所以 usable 是"真方法"的可靠信号。
            local HUD_METHODS = {
                "AddDebugText", "ShowDebugInfo", "Message", "ShowMessage",
                "DisplayMessage", "AddTextMessage", "ShowSystemMessage",
                "ShowNotice", "AddNotice", "ShowToast", "ShowPopup",
                "DrawText", "ShowHUD", "ClientMessage",
            }
            if Util.usable(hud) then
                for i = 1, #HUD_METHODS do
                    local nm = HUD_METHODS[i]
                    local s = Hud.method_signals(hud, nm)
                    if s ~= nil and s.type ~= "nil" then
                        lines[#lines + 1] = string.format(
                            "  %-20s type=%-9s usable=%-5s %s", nm, tostring(s.type),
                            tostring(s.usable), (s.usable and "← 很可能是真方法" or ""))
                    end
                end
                lines[#lines + 1] = "  （只列了拿得到东西的名字）"
            end
            ui_write(lines)
            return Util.usable(hud), tostring(Util.full_name(hud) or "拿不到 HUD")
        end,
    },

    {
        id = "s9_notice_widget", kind = "read",
        title = "探索 Palworld 自己的通知控件（WBP_NoticeLog / WBP_Notice）的控件树",
        fn = function(ctx)
            -- ★ 这一段【边查边写盘】。理由: 它是全流程风险最高的一步，
            --   如果崩在第一个候选上，写在最后的报告就一条都留不下。
            --   所以每查一个类、每读一层，都立刻 append 到 pwbp_ui.txt。
            local function emit(line) ui_write({ line }) end

            emit("")
            emit("=== 通知控件的控件树 ===")
            emit("目标: 找到『那个显示文字的 TextBlock 叫什么名字』。")
            emit("手段: 读 UWidgetBlueprintGeneratedClass.WidgetTree.AllWidgets")
            emit("      （这是【属性读取 + 数组下标】，不是反射枚举 —— 本项目安全的手法）。")
            emit("★★ 这一步是 S9 里风险最高的一步（读 UMG 控件内部结构）。")
            emit("   所以它【边查边写盘】—— 崩了也能看到查到哪儿了。")

            local total_widgets = 0
            for i = 1, #NOTICE_WIDGET_CANDIDATES do
                local nm = NOTICE_WIDGET_CANDIDATES[i]
                emit("")
                emit("--- " .. nm .. " ---")
                local ok, lst = pcall(function() return FindAllOf(nm) end)
                if not ok or type(lst) ~= "table" or #lst == 0 then
                    emit("  没有存活实例（UI 控件是按需创建的）")
                else
                    local inst = lst[1]
                    emit("  实例: " .. tostring(Util.full_name(inst)))
                    local cls = nil
                    pcall(function() cls = inst:GetClass() end)
                    emit("  类  : " .. tostring(Util.full_name(cls)))

                    -- ★ 读属性时同样要报告信号: `x ~= nil` 在这个构建里
                    --   既可能是真对象，也可能是占位对象（29 号的教训）。
                    local tree, sig = nil, nil
                    pcall(function() tree = cls.WidgetTree end)
                    pcall(function() sig = Hud.method_signals(cls, "WidgetTree") end)
                    emit("  WidgetTree: " .. tostring(tree ~= nil)
                        .. "   usable=" .. tostring(Util.usable(tree))
                        .. "   （method_signals: " .. tostring(sig and sig.type or "?") .. "）")
                    if tree ~= nil then
                        local all = nil
                        pcall(function() all = tree.AllWidgets end)
                        emit("  AllWidgets: " .. tostring(all ~= nil)
                            .. "   type=" .. tostring(type(all))
                            .. "   usable=" .. tostring(Util.usable(all)))
                        -- 试 4 种读法，报告哪种能用（上次 GetArrayNum 直接失败）
                        local n1, n2, n3 = nil, nil, nil
                        pcall(function() n1 = #all end)
                        pcall(function() n2 = all:GetArrayNum() end)
                        pcall(function() n3 = all:GetArrayMax() end)
                        emit(string.format("  读数组: #all=%s  GetArrayNum=%s  GetArrayMax=%s",
                            tostring(n1), tostring(n2), tostring(n3)))
                        local first = nil
                        pcall(function() first = all[1] end)
                        if first ~= nil then
                            local fc = nil
                            pcall(function() fc = Util.short_name(first:GetClass()) end)
                            emit("  all[1] = " .. tostring(fc) .. "  " .. tostring(Util.full_name(first)))
                        end
                        -- ForEach 是 dump_object.lua 用过的写法
                        local fe_count = 0
                        pcall(function()
                            all:ForEach(function(idx, elem)
                                fe_count = fe_count + 1
                                if fe_count <= 40 then
                                    local ec = "?"
                                    pcall(function() ec = Util.short_name(elem:GetClass()) end)
                                    total_widgets = total_widgets + 1
                                    emit(string.format("     [%2d] %-34s %s", idx,
                                        tostring(ec), tostring(Util.full_name(elem))))
                                end
                            end)
                        end)
                        emit("  ForEach 走访到: " .. tostring(fe_count) .. " 个")
                    end
                end
            end
            -- ★★ 另一条更直接的路: 列举【活着的】文本控件。
            --
            -- ★ 第一版这里犯了个大错: 把 CDO（类默认对象里的设计期控件）也当成目标，
            --   于是 SetText"成功"（8 条 0 失败）但屏幕上**一个字都没有**。
            --   现在只列【活实例】= 全名在 /Engine/Transient 下的，并且顺便回读
            --   它当前显示的文字 —— 挑目标时必须知道自己要覆盖什么。
            emit("")
            emit("=== 活着的文本控件（只列 /Engine/Transient 下的真实例）===")
            local tbs = Hud.find_textblocks("", true)     -- "" = 不过滤；true = 只要活实例
            local notice_hits = 0
            emit(string.format("  文本控件总数 %d，其中活实例 %d 个",
                tonumber(Hud.textblock_total) or 0, tonumber(Hud.textblock_live) or 0))
            if tbs == nil or #tbs == 0 then
                emit("  没有活实例 —— 说明此刻画面上一个文本控件都没有（或类名不对）")
            else
                local shown = math.min(#tbs, 60)
                for k = 1, shown do
                    local fn = Util.full_name(tbs[k])
                    local cur = Hud.widget_text(tbs[k])
                    local mark = ""
                    if type(fn) == "string" and fn:find("Notice", 1, true) ~= nil then
                        mark = "  ← ★ 通知控件里的"
                        notice_hits = notice_hits + 1
                    end
                    emit(string.format("   [%2d] %s", k, tostring(fn)))
                    emit(string.format("        现在显示: %s%s",
                        (cur == nil) and "(读不到)" or ("「" .. tostring(cur) .. "」"), mark))
                end
                if #tbs > shown then
                    emit(string.format("   ...（还有 %d 个没列）", #tbs - shown))
                end
            end
            emit(string.format("  其中带 Notice 的活控件: %d 个", notice_hits))

            -- ★★★ 按"文字长度"找通知控件（玩家截图给的决定性线索）
            emit("")
            emit("=== 长文本控件（≥6 字，按长度降序；通知/提示那种整句话就在这里）===")
            local longs = Hud.long_text_blocks(6, 25)
            if #longs == 0 then
                emit("  没有长文本控件（此刻屏幕上没有整句话的文字）")
            else
                for i = 1, #longs do
                    local e = longs[i]
                    emit(string.format("   [%2d] 长度%3d 可视性=%s  显示:「%s」",
                        i, #e.text, tostring(e.vis), e.text))
                    emit(string.format("        控件: %s", tostring(e.name)))
                end
            end
            emit("  ★ 上面这些就是「整句话」，游戏左下角通知区显示的就是它们。")
            emit("    下一步的「标记测试」会往其中几个写 PWBP#1/#2/#3，请告诉我看见没有、在哪。")

            -- ★★ 最强的一招: "屏幕上现在显示着 X，哪个控件在显示它？"
            --   玩家能在屏幕上看到通知文字，把那段文字填进配置 notify_probe_grep，
            --   这里就逐个回读【全部活文本控件】的当前文字，把命中的控件全名列出来。
            --   这比猜控件名可靠得多 —— 是"从现象反查控件"。
            local grep = Config.get("notify_probe_grep")
            if type(grep) == "string" and grep ~= "" then
                emit("")
                emit("=== 按内容反查控件（notify_probe_grep = 「" .. grep .. "」）===")
                local all = Hud.find_textblocks("", true)
                local hit = 0
                if all ~= nil then
                    for i = 1, #all do
                        local cur = Hud.widget_text(all[i])
                        if type(cur) == "string" and cur:find(grep, 1, true) ~= nil then
                            hit = hit + 1
                            emit(string.format("   ★ 命中: %s", tostring(Util.full_name(all[i]))))
                            emit(string.format("        显示: 「%s」  可视性=%s", cur,
                                tostring(Hud.widget_visibility(all[i]))))
                        end
                    end
                    emit(string.format("  （回读了 %d 个活文本控件，命中 %d 个）", #all, hit))
                end
            else
                emit("  （想按屏幕上的文字反查控件: 把那段文字填进配置 notify_probe_grep）")
            end
            emit("  当前 notify_textblock_filter = "
                .. tostring(Config.get("notify_textblock_filter")))
            emit("  notify_own_widget = " .. tostring(Config.get("notify_own_widget"))
                .. "   （true = 自己 Create 一个控件来显示，不借游戏的）")

            emit("")
            emit("★ 上面的 [序号] 后面是【控件类名】，再后面是完整路径。")
            return true, string.format("活文本控件 %d/%d 个（带 Notice %d 个）",
                (tbs ~= nil) and #tbs or 0, tonumber(Hud.textblock_live) or 0, notice_hits)
        end,
    },

    {
        id = "s9_overlay", kind = "read",
        title = "★ 浮层方案试用（SBB 的姿势: 复制一个「天生就是浮层」的控件 + GetWidgetFromName）",
        fn = function(ctx)
            ctx = ctx
            local emit = ui_write
            -- ★ 默认跳过（见 probe_overlay_test 的说明）:
            --   这个步骤会真的创建游戏浮层控件，按 O 时屏幕上会多出几个框
            --   （包括"睡眠中"那个大框）。它的使命已经完成，别每次都来打扰。
            if Config.get("probe_overlay_test") ~= true then
                emit({ "", "=== 浮层方案试用: 已跳过 ===",
                       "  （配置 probe_overlay_test=false；要再试控件类就把它打开）" })
                return true, "跳过: probe_overlay_test=false"
            end
            emit({ "", "=== 浮层方案（照 SBB 的做法，只读参考未复用代码）===" })
            emit({ "  SBB 的左下角进度提示是**它自己的 UMG 控件**画的:",
                   "    CreateWidget -> AddToPlayerScreen(50) -> GetWidgetFromName(子控件) -> SetText",
                   "  关键是它复制的控件**天生就是独立浮层**（有锚点有尺寸）。",
                   "  我们以前复制 WBP_Notice（列表里的一项）→ 单独拿出来布局是空的。",
                   "  下面逐个试**游戏自带的浮层控件**，各写一个 PG#n 标记。" })

            -- 候选: {类名, 里面的文本框子控件名}
            -- 名字都来自玩家报告里的活控件全名（实测存在）
            local CANDIDATES = {
                { "WBP_Warning_LowMemory_C", "Text_Warning" },
                { "WBP_Ingame_Sleep_C",      "Text_Sleeptips" },
                { "WBP_IngameSmesTop_C",     "BPPalTextBlock_Smes_01" },
            }
            local pc = ctx.pc
            local lib = nil
            pcall(function()
                lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
            end)
            if pc == nil or not Util.usable(lib) then
                emit({ "  跳过: 没有 PlayerController 或拿不到 UMG 库" })
                return false, "前置条件不足"
            end

            local made = 0
            for i = 1, #CANDIDATES do
                local cname, child_name = CANDIDATES[i][1], CANDIDATES[i][2]
                local marker = "PG#" .. i
                emit({ "", string.format("--- [%d] %s / %s ---", i, cname, child_name) })
                local insts = Hud.find_widgets(cname)
                if insts == nil or #insts == 0 then
                    emit({ "  没有活实例 → 拿不到它的类，跳过" })
                else
                    local cls = nil
                    pcall(function() cls = insts[1]:GetClass() end)
                    emit({ "  类: " .. tostring(Util.full_name(cls)) })
                    local w = nil
                    local okc = pcall(function() w = lib:Create(pc, cls, pc) end)
                    if not okc or w == nil then
                        emit({ "  Create 失败" })
                    else
                        local attach = "AddToPlayerScreen"
                        local ok_ps = pcall(function() w:AddToPlayerScreen(50) end)
                        if not ok_ps then
                            attach = "AddToViewport"
                            pcall(function() w:AddToViewport(50) end)
                        end
                        local tb, how = Hud.widget_child(w, child_name)
                        emit({ "  挂载=" .. attach
                            .. " 在视口里=" .. tostring(Hud.in_viewport(w))
                            .. " 期望尺寸=" .. tostring(Hud.desired_size(w))
                            .. " 根控件尺寸=" .. tostring(Hud.desired_size(Hud.root_widget(w))) })
                        emit({ "  取子控件 " .. tostring(child_name) .. " -> "
                            .. tostring(Util.full_name(tb)) .. "  方式=" .. tostring(how) })
                        -- ★ 如果按名字取不到，就查"这个新控件下面有没有文本框" ——
                        --   一个都没有 = 控件树根本没被复制出来（那取不到就正常了）
                        if tb == nil then
                            local under = Hud.textblocks_under(w)
                            emit({ "  它下面的活文本控件数: "
                                .. tostring(under ~= nil and #under or 0)
                                .. (under ~= nil and #under > 0
                                    and ("  例: " .. tostring(Util.full_name(under[1])))
                                    or "  ← 一个都没有 ⇒ 控件树没建出来") })
                            if under ~= nil and #under > 0 then
                                tb = under[1]
                                emit({ "  退回用第一个: " .. tostring(Util.full_name(tb)) })
                            end
                        end
                        if tb == nil then
                            emit({ "  ★ 没取到那个子控件（名字可能不对）" })
                        else
                            local ft = Hud.ftext(marker .. " —— PWBP 浮层测试")
                            local ok1 = false
                            if ft ~= nil then
                                ok1 = pcall(function() tb:SetText(ft) end)
                            end
                            -- ★ 用 3（HitTestInvisible）: 渲染但绝不吃输入
                            Hud.force_display(w)
                            Hud.force_display(tb)
                            emit({ "  SetText=" .. tostring(ok1)
                                .. " 回读=「" .. tostring(Hud.widget_text(tb)) .. "」" })
                            made = made + 1
                            -- 25 秒后收拾掉，别留着污染画面
                            Sched.game_thread(function()
                                pcall(function() w:RemoveFromParent() end)
                                ui_write({ string.format("   [%d] 25 秒后已移除浮层", i) })
                            end, 25000)
                        end
                    end
                end
            end
            emit({ "", string.format("  建了 %d 个浮层。★ 请在 25 秒内看屏幕: 有没有看到 PG#几？在哪？",
                made) })
            return made > 0, string.format("试用 %d 个浮层控件", made)
        end,
    },

    {
        id = "s9_channels", kind = "read",
        title = "通道探测（只查“有没有”，不发任何文字；会先重读一次配置）",
        fn = function(ctx)
            -- ★ 自动重读配置。
            --   2026-09-27 实测踩到: 玩家把 notify_try_client_message 改成 true 后
            --   直接按 O，结果探测里那条高风险通道仍显示「默认关」——
            --   因为配置是启动/F8 时读进内存的，改文件不会自动生效。
            --   与其让玩家记住"改完要按 F8"，不如按 O 时自己重读一次（和 F8 干的事一样）。
            local cfg_note = "（没重读）"
            local _, note = Config.load(Util.script_dir)
            cfg_note = tostring(note)

            local name, detail = Hud.probe({ pc = ctx.pc })
            local lines = {
                "",
                "=== 通道探测结果 ===",
                "（本步已自动重读配置: " .. cfg_note .. "）",
                "选中通道: " .. tostring(name) .. "   " .. tostring(detail),
            }
            local sl = Hud.status_lines()
            for i = 1, #sl do lines[#lines + 1] = sl[i] end
            lines[#lines + 1] = ""
            lines[#lines + 1] = "★ 想要游戏内文字，两步:"
            lines[#lines + 1] = "  1) 把配置 notify_try_client_message 改成 true"
            lines[#lines + 1] = "     （或者 notify_allow_named_1arg=true 且 notify_func=<上面签名合适的函数名>）"
            lines[#lines + 1] = "  2) 回游戏再按一次 O —— 最后一步会真的发一行测试文字"
            lines[#lines + 1] = "     ★ 那一步有把游戏打崩的风险（未验证参数个数的调用），所以默认不执行。"
            ui_write(lines)
            return true, string.format("选中 %s（%s）", tostring(name), tostring(detail))
        end,
    },

    {
        id = "s9_color", kind = "read",
        title = "★ 文字颜色接口探测（想把正常提示改成蓝色；先只读看有没有，再试一次调用）",
        fn = function(ctx)
            ctx = ctx
            local emit = ui_write
            emit({ "", "=== 文字颜色（SBB 之外的补充: 想给正常提示换个不刺眼的颜色）===" })
            emit({ "  现在正常/出错都只能用警告条的红色，因为另一个控件创建失败。",
                   "  最省事的办法: 直接改**那个能用的**文本框的颜色。" })
            -- 1) 先只读: 颜色构造函数在不在
            --    ★ 用 _G 动态取，而不是直接写 FLinearColor(...) ——
            --      因为这两个全局**没验证过存在**，直接写会被检查器判为未定义
            --      （它的判断是对的: 没验证过的东西不该当成已知全局用）。
            local lin_ctor, slate_ctor = nil, nil
            pcall(function() lin_ctor = _G.FLinearColor end)
            pcall(function() slate_ctor = _G.FSlateColor end)
            emit({ "  _G.FLinearColor = " .. tostring(type(lin_ctor))
                .. "   _G.FSlateColor = " .. tostring(type(slate_ctor)) })

            -- 2) 我们自己控件的文本框上有没有 SetColorAndOpacity
            local st = Hud.style_state("error")
            local tb = st.textblocks and st.textblocks[1] or nil
            if tb == nil then
                emit({ "  还没有我们自己的控件/文本框 —— 先按 Y/J/K 让它建出来，再按 O" })
                return false, "没有可用的文本框"
            end
            local sig = Hud.method_signals(tb, "SetColorAndOpacity")
            emit({ "  SetColorAndOpacity: type=" .. tostring(sig and sig.type)
                .. " usable=" .. tostring(sig and sig.usable) })
            if type(lin_ctor) ~= "function" or type(slate_ctor) ~= "function" then
                emit({ "  ★ 颜色构造函数不全 ⇒ 不改颜色；改用「换一个控件类」的办法" })
                return false, "颜色构造函数不可用"
            end
            -- 3) 真的试一次（放在最后，且只作用于我们自己的控件）
            local okc, err = pcall(function()
                local lin = lin_ctor(0.45, 0.75, 1.0, 1.0)      -- 淡蓝
                tb:SetColorAndOpacity(slate_ctor(lin))
            end)
            emit({ "  试着把颜色改成淡蓝: " .. (okc and "调用成功" or ("失败: " .. tostring(err))) })
            emit({ "  ★ 如果成功，屏幕上原本红色的字应该变成淡蓝（或下次提示才是蓝色）" })
            return okc, okc and "SetColorAndOpacity 调用成功" or tostring(err)
        end,
    },

    {
        id = "s9_send_test", kind = "write",
        title = "★ 真的发一行测试文字（任何非控制台通道都会执行）",
        fn = function(ctx)
            ctx = ctx
            local ch = Hud.channel_by_name(Hud.active)
            if ch == nil or ch.name == "console" then
                return true, "跳过: 当前通道是零风险的 console，不需要这一步"
            end
            -- ★★ never_call: 已知会崩的通道，**连"真发一行测试文字"都不许调**。
            --   2026-09-27: ClientMessage 就是这样把游戏打崩的（这个步骤写下了
            --   "如果本文件到此为止就是这一步" —— 结果真的一语成谶）。
            --   留档比"再试一次"重要，所以这里直接拒绝。
            if ch.never_call == true then
                ui_write({
                    "",
                    "=== 通道 " .. tostring(Hud.active) .. " 标记为 never_call ===",
                    "★ 已知调用它会崩游戏，探测【拒绝调用】。本条只为留档。",
                })
                return true, "跳过: " .. tostring(Hud.active) .. " 已知会崩，拒绝调用"
            end
            -- 先把"即将调用"落盘。崩了的话，文件最后一行就是崩在哪个通道上。
            ui_write({
                "",
                "=== 即将真的调用通道 " .. tostring(Hud.active) .. " ===",
                "如果本文件到此为止，就是这一步把游戏打崩的。",
                "恢复方法: 把配置 notify_try_notice_text / notify_try_client_message",
                "          / notify_allow_named_1arg 改回 false。",
            })
            local ok, err = Hud.show("PWBP 测试文字 —— 能看见这行就说明通道可用", "PWBP test message")
            -- ★ 把"这次发送到底发生了什么"完整落盘 ——
            --   "SetText 没报错"完全不能说明字写进去了（CDO 那次就是这样），
            --   所以必须记录: 走了哪条路 / 控件叫什么 / 在不在视口 / 可视性 / 回读到了什么。
            local lines = {
                string.format("  结果: %s   %s", tostring(ok), tostring(err)),
                "  ---- 本次发送实况 ----",
            }
            local detail = tostring(Hud.last_detail or "(没有记录)")
            for piece in detail:gmatch("[^|]+") do
                lines[#lines + 1] = "   " .. tostring(piece):gsub("^%s+", "")
            end
            local sl = Hud.status_lines()
            lines[#lines + 1] = "  ---- 通道状态 ----"
            for i = 1, #sl do lines[#lines + 1] = "   " .. sl[i] end

            -- ★ 顺便同时试一次"借用路线": 直接写游戏【活着的】通知文本框。
            --   理由: 自建控件那条路"什么都对但看不见"，而借用的是一个
            --   **正在被游戏渲染**的控件（位置/透明度/层级都是对的），
            --   所以它能回答"是自建控件的问题，还是我们写字的方式有问题"。
            --
            --   ★★ 但必须**排除我们自己的控件** —— 上一次就踩了这个:
            --     我们自建的也是 WBP_Notice_C，filter 一样能匹配到，
            --     于是"借用测试"其实写的是自己的文本框，等于没有独立验证。
            lines[#lines + 1] = "  ---- 借用路线测试（直接写游戏活控件）----"
            local filter = Config.get("notify_textblock_filter")
            local borrowed = Hud.find_textblocks(filter, true)
            local own_names = {}
            local own_list = Hud.find_own_textblocks()
            if own_list ~= nil then
                for i = 1, #own_list do
                    local fn = Util.full_name(own_list[i])
                    if type(fn) == "string" then own_names[fn] = true end
                end
            end
            local keep = {}
            if borrowed ~= nil then
                for i = 1, #borrowed do
                    local fn = Util.full_name(borrowed[i])
                    if type(fn) == "string" and own_names[fn] ~= true then
                        keep[#keep + 1] = borrowed[i]
                    end
                end
            end
            borrowed = keep
            lines[#lines + 1] = string.format(
                "  匹配「%s」的活控件 %d 个（已排除我们自建的 %d 个）",
                tostring(filter), #borrowed, #own_list or 0)
            if #borrowed == 0 then
                lines[#lines + 1] = "   游戏此刻没有在显示通知（它的通知控件是按需创建的）"
            else
                local tb = borrowed[1]
                local before = Hud.widget_text(tb)
                local ft = Hud.ftext("PWBP 借用测试 —— 能看见这行说明借用路线可用")
                local okb = false
                if ft ~= nil then
                    okb = pcall(function() tb:SetText(ft) end)
                end
                Hud.force_display(tb)
                lines[#lines + 1] = "   目标: " .. tostring(Util.full_name(tb))
                lines[#lines + 1] = "   覆盖前显示: 「" .. tostring(before) .. "」"
                lines[#lines + 1] = "   可视性=" .. tostring(Hud.widget_visibility(tb))
                    .. " 不透明度=" .. tostring(Hud.render_opacity(tb))
                lines[#lines + 1] = "   SetText=" .. tostring(okb)
                    .. "  回读=「" .. tostring(Hud.widget_text(tb)) .. "」"
            end

            -- ★ 默认跳过: 这一段会**真的改写游戏自己的文本框**（12 秒后还原），
            --   属于侵入性诊断。它的使命已完成（证明了"属性不可信"），
            --   不该每次按 O 都去动游戏的 UI。要看就把 probe_marker_test 打开。
            if Config.get("probe_marker_test") == true then
            -- ★★★ 标记测试 v2: **按"不同界面"分组，每组各写一个带编号的标记**。
            --
            -- 为什么不用 v1（按文字长度挑 3 个）: v1 挑出来的全是
            --   设置/警告界面里的字（「目前语言：简体中文」「PCの空きメモリ…」），
            --   而它们的"自身+父链可视性"看起来完全正常 ——
            --   因为 Palworld 把大量控件一直留在内存里（WidgetSwitcher 非活动页等），
            --   **Visibility 属性问不出"在不在屏幕上"**。
            -- ⇒ 不挑了，铺开写: 12 个不同界面各写一个编号，
            --   哪一组真在屏幕上，玩家就会看到对应编号 —— 用玩家的眼睛当判据。
            lines[#lines + 1] = "  ---- 标记测试（12 个不同界面各写一个编号）----"
            local own_names2 = {}
            local own2 = Hud.find_own_textblocks()
            if own2 ~= nil then
                for i = 1, #own2 do
                    local fn = Util.full_name(own2[i])
                    if type(fn) == "string" then own_names2[fn] = true end
                end
            end
            local groups = Hud.textblock_groups(16)
            local picks = {}
            for i = 1, #groups do
                local g = groups[i]
                if own_names2[g.name] ~= true and #picks < 12 then
                    local shown, chain = Hud.chain_visible(g.obj)
                    picks[#picks + 1] = {
                        obj = g.obj, name = g.name, key = g.key,
                        shown = shown, chain = chain,
                        text = Hud.widget_text(g.obj),
                    }
                end
            end
            if #picks == 0 then
                lines[#lines + 1] = "   一个活文本控件都没有"
            else
                for i = 1, #picks do
                    local e = picks[i]
                    local marker = "PWBP#" .. i
                    local orig = e.text
                    local mft = Hud.ftext(marker)
                    local okm = false
                    if mft ~= nil then
                        okm = pcall(function() e.obj:SetText(mft) end)
                    end
                    Hud.force_display(e.obj)
                    lines[#lines + 1] = string.format(
                        "   [%2d] 「%s」 界面=%s  父链可见=%s  SetText=%s",
                        i, marker, tostring(e.key), tostring(e.shown), tostring(okm))
                    lines[#lines + 1] = "        原内容=「" .. tostring(orig) .. "」"
                    lines[#lines + 1] = "        控件: " .. tostring(e.name)
                    -- 1.5 秒后回读: 被改回原文 => 这个控件有属性绑定（每帧重算）
                    Sched.game_thread(function()
                        ui_write({ string.format(
                            "   [%d] 1.5 秒后回读: 「%s」（若已不是 %s，说明它每帧被游戏重算）",
                            i, tostring(Hud.widget_text(e.obj)), marker) })
                    end, 1500)
                    -- 12 秒后恢复原文（给玩家足够时间到处看一眼）
                    Sched.game_thread(function()
                        local rft = Hud.ftext(orig)
                        if rft ~= nil then
                            pcall(function() e.obj:SetText(rft) end)
                        end
                        ui_write({ string.format("   [%2d] 12 秒后已恢复原文", i) })
                    end, 12000)
                end
                lines[#lines + 1] = "   ★ 请在 12 秒内看一眼屏幕，然后告诉我在哪些位置看到了"
                lines[#lines + 1] = "     PWBP#1 ~ PWBP#" .. #picks .. " 里的哪几个编号。"
            end

            end

            -- ★ 默认跳过: 这一段会**真的改写游戏自己的文本框**（12 秒后还原），
            --   属于侵入性诊断。它的使命已完成（证明了"属性不可信"），
            --   不该每次按 O 都去动游戏的 UI。要看就把 probe_marker_test 打开。
            if Config.get("probe_marker_test") == true then
            -- ★★★ 测试 B（决定性）: 把【同一段可见文字的每一份拷贝】都写上标记。
            --
            -- 玩家的反馈给出了关键线索: 「目前语言：简体中文」是他**屏幕上看得见**的字
            -- （ESC → 选项 → 选项页签），我们写了 PWBP#1 进去、回读也确认写进去了，
            -- **但屏幕上的字没有变**。只剩两种解释:
            --   (a) 我们写的是"另一份拷贝" —— Palworld 常给同一个值保留多个控件
            --       （类名里的 ForDisplay 就是暗示），渲染的那份不是我们写的那份；
            --   (b) SetText 根本进不了渲染（属性变了但 Slate 不重画）。
            -- 把每一份拷贝都写一遍，就能把 (a) 排除掉。
            local grep = Config.get("notify_probe_grep")
            -- ★ 内置一个"玩家实测在屏幕上看得见"的诊断目标。
            --   为什么不只靠配置: 配置项一旦被 Config.save 写进文件，
            --   之后改默认值是**不生效的**（这个坑本项目踩过两次）。
            --   诊断目标写成内置的，就不受配置文件状态影响。
            local GREP_DIAG = { "目前语言" }
            local greps = {}
            if type(grep) == "string" and grep ~= "" then
                greps[#greps + 1] = grep
            end
            for i = 1, #GREP_DIAG do
                if greps[1] ~= GREP_DIAG[i] then
                    greps[#greps + 1] = GREP_DIAG[i]
                end
            end
            for gi = 1, #greps do
                grep = greps[gi]
                local entries = Hud.textblock_entries(true)
                local hits = {}
                for i = 1, #entries do
                    local t = Hud.widget_text(entries[i].obj)
                    if type(t) == "string" and t:find(grep, 1, true) ~= nil then
                        hits[#hits + 1] = {
                            obj = entries[i].obj, name = entries[i].name, text = t,
                        }
                    end
                end
                lines[#lines + 1] = string.format(
                    "  ---- 测试 B:「%s」的所有拷贝（找到 %d 份）----", grep, #hits)
                if #hits == 0 then
                    lines[#lines + 1] = "   没找到 —— 这段字此刻不在屏幕上，或你还没打开那个界面"
                else
                    for i = 1, #hits do
                        local h = hits[i]
                        local marker = "GP#" .. i
                        local mft = Hud.ftext(marker)
                        if mft ~= nil then
                            pcall(function() h.obj:SetText(mft) end)
                        end
                        Hud.force_display(h.obj)
                        lines[#lines + 1] = string.format(
                            "   [%d] 写成「%s」 原内容=「%s」", i, marker, h.text)
                        lines[#lines + 1] = "        控件: " .. tostring(h.name)
                        Sched.game_thread(function()
                            ui_write({ string.format("   [%d] 1.5 秒后回读: 「%s」", i,
                                tostring(Hud.widget_text(h.obj))) })
                        end, 1500)
                        Sched.game_thread(function()
                            local rft = Hud.ftext(h.text)
                            if rft ~= nil then
                                pcall(function() h.obj:SetText(rft) end)
                            end
                            ui_write({ string.format("   [%d] 20 秒后已恢复原文", i) })
                        end, 20000)
                    end
                    lines[#lines + 1] = "   ★★ 请在 20 秒内盯着那段文字: **它变了吗？变成了 GP#几？**"
                    lines[#lines + 1] = "      变了 => SetText 能进渲染，之前只是挑错了拷贝（可修）"
                    lines[#lines + 1] = "      没变 => SetText 进不了渲染，这条路线彻底排除"
                end
            end
            end

            ui_write(lines)
            return ok == true,
                ok and ("通道 " .. tostring(Hud.active) .. " 发送成功")
                or tostring(err)
        end,
    },
}

-- ★ S9 【故意不接进 STEPS】。
--
-- 理由: STEPS 是"投影渲染门禁"（按 N），它已经被实机验证通过，
--   而且 pass/fail 直接决定 K 能不能创建引擎对象。
--   把一段**新的、还在摸索的**探测接进去，会让
--   "渲染门禁失败"和"提示通道没找到"两件事混在一起，
--   而且 S9 的类名枚举要跑几秒（N 会变慢）。
--   所以: N = 渲染门禁（原样不动），O = 提示通道（本段）。
--   两边的纪律一样: 每步执行前写 START，崩了就知道崩在哪一步。

-- --------------------------------------------------------------------------
-- 门禁判定
-- --------------------------------------------------------------------------

--- 投影渲染至少要这些能力
Probe.REQUIRED = {
    "get_world", "spawn_host", "add_ism_component",
    "set_static_mesh", "add_instance",
}

--- 返回 ok, 缺失列表
function Probe.readiness(caps)
    caps = caps or Probe.caps
    local missing = {}
    for i = 1, #Probe.REQUIRED do
        local id = Probe.REQUIRED[i]
        local e = caps[id]
        if e == nil or e.ok ~= true then missing[#missing + 1] = id end
    end
    return #missing == 0, missing
end

function Probe.save_capabilities()
    local out = {
        generatedAt = Util.now_iso(),
        gameVersion = "Palworld 1.0.x",
        caps = {},
    }
    for id, e in pairs(Probe.caps) do
        out.caps[id] = { ok = e.ok, detail = e.detail }
    end
    local ready, missing = Probe.readiness()
    out.readyForGhost = ready
    out.missing = missing
    local text = Json.encode(out, true)
    return Util.write_file(Util.join(Util.script_dir, Probe.CAPS_FILE),
        text .. "\n", true)
end

--- 从磁盘读回能力表（供 ghost 做门禁；游戏重启后仍然有效）
function Probe.load_capabilities()
    local path = Util.join(Util.script_dir, Probe.CAPS_FILE)
    if not Util.file_exists(path) then return nil, "还没有探测结果" end
    local text, err = Util.read_file(path)
    if text == nil then return nil, tostring(err) end
    local parsed, perr = Json.decode(text)
    if type(parsed) ~= "table" or type(parsed.caps) ~= "table" then
        return nil, "能力表格式不对: " .. tostring(perr)
    end
    local caps = {}
    for id, e in pairs(parsed.caps) do
        if type(e) == "table" then
            caps[id] = { ok = e.ok == true, detail = tostring(e.detail or "") }
        end
    end
    return caps, nil
end

-- --------------------------------------------------------------------------
-- 执行器
-- --------------------------------------------------------------------------

--- opts: { max_step = 0(全部) | n, only = nil|id }
--- 返回 摘要文字（表）
function Probe.run(script_dir, opts)
    opts = opts or {}
    local max_step = tonumber(opts.max_step) or 0
    Log.clear()
    Probe.caps = {}
    Probe.ctx = { caps = Probe.caps }

    local ctx = Probe.ctx
    local ran, failed, skipped = 0, 0, 0

    Log.line("==================================================================")
    Log.line("PWBP 渲染能力探测")
    Log.line("时间: " .. Util.now_iso())
    Log.line("说明: 每步【执行前】写 START，执行后写结果。")
    Log.line("      如果游戏崩了，文件里最后一条 START 就是崩溃点。")
    Log.line("调度: " .. Sched.describe())
    if max_step > 0 then
        Log.line("限制: 只跑到第 " .. max_step .. " 步（之后中止，销毁步骤仍会跑）")
    end
    Log.line("==================================================================")
    Log.dump(Probe.FILE)

    local aborted = false
    for i = 1, #STEPS do
        local step = STEPS[i]
        local limited = (max_step > 0 and i > max_step and step.always ~= true)

        if limited then
            if not aborted then
                aborted = true
                Log.line("")
                Log.line(string.format("[%d] %s  —— 被 max_step 跳过", i, step.id))
                Log.dump(Probe.FILE)
            end
            skipped = skipped + 1
            cap(step.id, false, "被 max_step 跳过")
        else
            Log.line("")
            Log.line(string.format("[%d/%d] START %s  (%s)",
                i, #STEPS, step.id, step.title))
            Log.line("       类型: " .. step.kind)
            Log.dump(Probe.FILE)

            -- step.fn(ctx) 返回 ok, detail
            -- pcall 之后: pok = 是否无 Lua 错误, sok = 第一个返回值, sdetail = 第二个
            local pok, sok, sdetail = pcall(step.fn, ctx)
            if not pok then
                cap(step.id, false, "步骤函数抛 Lua 错误: " .. tostring(sok))
                Log.line("       结果: LUA ERROR -> " .. tostring(sok))
                failed = failed + 1
            else
                cap(step.id, sok == true, tostring(sdetail))
                if sok ~= true then failed = failed + 1 end
                Log.line("       结果: " .. (sok == true and "OK" or "FAIL")
                    .. "  " .. tostring(sdetail))
            end
            -- ★ 每一步都把能力表落盘。
            -- 2026-09-26 18:15 那次：前 27 步全 OK，第 28 步崩，
            -- 而能力表是最后才写的 —— 结果 27 步的结论全丢了，白测一次。
            pcall(function() Probe.save_capabilities() end)
            Log.dump(Probe.FILE)
            ran = ran + 1
        end
    end

    Log.line("")
    Log.line("==================================================================")
    Log.line("探测结束")
    Log.line("==================================================================")
    Log.dump(Probe.FILE)

    local ready, missing = Probe.readiness()
    local okwrite = Probe.save_capabilities()

    Log.line("")
    Log.line("能力汇总:")
    local ids = {}
    for id in pairs(Probe.caps) do ids[#ids + 1] = id end
    table.sort(ids)
    for k = 1, #ids do
        local e = Probe.caps[ids[k]]
        Log.line(string.format("  %-30s %s  %s", ids[k],
            e.ok and "OK  " or "FAIL", e.detail))
    end
    Log.line("")
    Log.line(string.format("跑完 %d 步（跳过 %d，失败步骤数见上）", ran, skipped))
    Log.line(string.format("能力表写入: %s", tostring(okwrite)))
    Log.line(string.format("投影渲染就绪: %s%s", tostring(ready),
        ready and "" or ("  缺少: " .. table.concat(missing, ", "))))
    Log.dump(Probe.FILE)
    Log.flush()

    Probe.last_summary = {
        ready = ready, missing = missing, ran = ran, skipped = skipped,
    }
    return ready, missing
end

-- --------------------------------------------------------------------------
-- S9 单独执行器（按 O）
--
-- 为什么不复用 run(): 那会跑完前面 28 步（含创建/销毁引擎对象），
-- 而"我想看看屏幕上能不能出字"不该顺带做那些事。
-- 两边的纪律是一样的: 【每步执行前】把 START 落盘，崩了就知道崩在哪一步。
-- --------------------------------------------------------------------------

--- 只跑 S9（屏幕提示通道）。返回 ok, detail
---
--- ★★ 这个函数【绝不写 pwbp_capabilities.json】。
---   那个文件是"投影渲染门禁"的凭据（Ghost.check_gate 会读它）。
---   第一版我在 S9 里也调了 save_capabilities()，等于按一次 O 就把
---   渲染门禁的凭据覆盖成只剩 s9_* 几条 —— 结果 K 会突然拒绝渲染，
---   得再按一次 N 才能恢复。**新功能不许动已验证的那条路的凭据。**
---   S9 的结论只写 pwbp_ui.txt（谁也不会去读它做门禁）。
function Probe.run_ui(script_dir)
    Log.clear()
    Probe.caps = {}
    local ctx = { caps = Probe.caps }
    Probe.ctx = ctx

    ui_write({
        "==================================================================",
        "PWBP S9 屏幕提示通道探测",
        "时间: " .. Util.now_iso(),
        "为什么: KismetSystemLibrary:PrintString 在 Shipping 构建里会崩游戏（已实测），",
        "        所以屏幕上显示文字必须另找通道。本文件是枚举结果，不是猜的。",
        "纪律: 每步执行前写 START。崩了的话，本文件最后一条就是崩溃点。",
        "==================================================================",
    }, true)

    Log.line("==================================================================")
    Log.line("PWBP S9 屏幕提示通道探测（结果写 " .. Probe.UI_FILE .. "）")
    Log.line("时间: " .. Util.now_iso())
    Log.line("==================================================================")

    local n_ok, n_fail = 0, 0
    local last_detail = ""
    for i = 1, #UI_STEPS do
        local step = UI_STEPS[i]
        Log.emit(string.format("[%d/%d] %s", i, #UI_STEPS, step.id))
        ui_write({ "", string.format("---------- [%d/%d] START %s (%s) ----------",
            i, #UI_STEPS, step.id, step.title) })

        local pok, sok, sdetail = pcall(step.fn, ctx)
        local ok, detail
        if not pok then
            ok, detail = false, "Lua 错误: " .. tostring(sok)
        else
            ok, detail = (sok == true), tostring(sdetail or "")
        end
        cap(step.id, ok, detail)
        if ok then n_ok = n_ok + 1 else n_fail = n_fail + 1 end
        if detail ~= "" then last_detail = detail end

        ui_write({ "       结果: " .. (ok and "OK" or "FAIL") .. "   " .. detail })
        Log.emit("       " .. (ok and "OK" or "FAIL") .. "   " .. detail)
        Log.flush()
    end

    ui_write({
        "",
        string.format("S9 结束: OK %d, FAIL %d", n_ok, n_fail),
        "把 " .. Probe.UI_FILE .. " 整个发出来，就能确定下一步用哪条通道。",
    })
    Log.emit(string.format("S9 结束: OK %d, FAIL %d", n_ok, n_fail))
    Log.emit("报告: " .. Util.join(script_dir or Util.script_dir, Probe.UI_FILE))
    Log.flush()

    Probe.last_summary = { ready = (n_fail == 0), missing = {}, ran = #UI_STEPS, skipped = 0 }
    return (n_fail == 0), last_detail
end

return Probe
