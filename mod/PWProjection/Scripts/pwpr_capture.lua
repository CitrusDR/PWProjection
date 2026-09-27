--[[ ===========================================================================
  PWPR · capture  ——  从游戏里读建筑（只读，绝不改状态）

  只用【已被 PWRecon 长期验证过】的调用:
      FindAllOf("PalBuildObject")          列建筑
      obj:K2_GetActorLocation()            位置（返回"带键的表"，不是数组！）
      obj:K2_GetActorRotation()            朝向
      obj:GetClass():GetFullName()         类型
      obj.Mesh.StaticMesh:GetFullName()    网格（只有功能性设施才有）
  每一次引擎调用都单独 pcall —— 任何一项失败只影响那一条记录。

  输出 records 的坐标是【世界厘米】，交给 pwpr_bp 去算原点/分层。
=========================================================================== ]]

local Util = require("pwpr_util")
local BP = require("pwpr_bp")
-- ★★★ 2026-09-28（做建筑吸附时发现的**真 bug**）: 这个文件原来**没有** require Log，
--   而下面所有 `if Log ~= nil then Log.line(...) end` 用的是**全局** `Log` ——
--   本项目里没有任何地方定义过全局 Log ⇒ 那些"崩溃取证"的跟踪行
--   （`[scan] N/M <actor 名>`、`[cap/name] ...`）**一行都没写出来过**。
--   实测证据: 部署目录里 1.7 MB 的 pwpr.log 里 `[scan]` / `[cap/name]` 出现 0 次，
--   而"==== 采集：玩家附近 ===="那一节后面**连"枚举到 N 个建筑"都没有**。
--   ⇒ 影响: 上一轮"旧存档按 Y 崩溃"的排查里，我把"日志里一条 [scan] 都没有"
--     当成了"崩在枚举本身"的证据 —— 其实那几行**根本没有实现**。
--     （结论（改用关卡 Actor 列表）本身是对的，但证据是无效的。）
--   ⇒ 修法: 像其他模块一样 require 进来。日志会多出几千行（只进文件、不刷控制台，
--     本来就是这么设计的）。
local Log = require("pwpr_log")

local Capture = {}

Capture.ACTOR_CLASS = "PalBuildObject"

--- 每个类型的"网格读取诊断"（只读，不碰引擎状态）
--- type -> { n=见到的件数, with_mesh=读到网格的件数, diag={...第一个样本的详情...} }
Capture.mesh_diag = {}

-- --------------------------------------------------------------------------
-- 单条读取
-- --------------------------------------------------------------------------

--- 取建筑的 Mesh 组件（没有就返回 nil）。
---
--- 判据用"能调通 GetFullName"而不是 IsValid —— 见 mesh_short_name 上面的注释。
---
--- ★ 三种"没有网格"必须分开记（2026-09-26 更深）:
---     1. obj.Mesh 本身就是 nil        -> 游戏没给这个建筑 Mesh 组件（HISM 绘制）
---     2. 有组件但 GetFullName 失败    -> 组件是占位对象/坏对象，性质完全不同
---     3. 有组件、StaticMesh 为空      -> 组件在但网格没设
---   上一版把 1 和 2 混成一句"没有 Mesh 组件"，看不出区别。
function Capture.mesh_component(obj, diag)
    local ok_c, raw = pcall(function() return obj.Mesh end)
    if not ok_c then
        if diag then diag.reason = "读 obj.Mesh 抛错" end
        return nil
    end
    if raw == nil then
        if diag then
            diag.reason = "obj.Mesh 是 nil —— 游戏没给这个建筑 Mesh 组件"
        end
        return nil
    end
    if diag then diag.raw_mesh_exists = true end

    -- ★★ 2026-09-26 更深夜找到的真 bug（玩家报「矿车方向不对」）:
    --   obj.Mesh 读出来的【经常是 UE4SS 的属性包装对象，不是组件本身】。
    --   不 unwrap 就直接 comp:GetFullName() —— 那当然调不通。
    --   后果有两个，而且都不报错:
    --     1) 61/72 种类型被误判成"没有 Mesh 组件"（我一度据此得出
    --        "游戏侧没给这些建筑网格"的错误结论）
    --     2) 朝向退回 actor 朝向 -> 带固定相对旋转的建筑方向就偏了
    --        （矿车就是其中一个）
    --   Util.unwrap 内部会试 v:get()，包装对象会被还原成真组件。
    local comp = Util.unwrap(raw)
    if comp == nil then
        if diag then diag.reason = "obj.Mesh 解开包装后是 nil" end
        return nil
    end

    local ok_f, full = pcall(function() return comp:GetFullName() end)
    if not ok_f or type(full) ~= "string" or full == "" then
        if diag then
            diag.reason = "有 Mesh 组件，但 GetFullName 失败（疑似占位对象）"
        end
        return nil
    end
    return comp, full
end

--- 网格资产短名。comp 由 Capture.mesh_component 给出。
---
--- ★ 2026-09-26 18:15 实测教训：
---   我原来在这里加了 `Util.valid(comp)` / `Util.valid(asset)` 判定，
---   结果一个 35 件的基地只有 4 件读到网格。
---   而 PWRecon 用的是"能调通 GetFullName 就算有"，同一个存档能读到 26/79 种。
---   说明 **UE4SS 的 IsValid() 在这类组件/资产上会把好对象误判为无效**。
---   所以这里改成 PWRecon 的判据，同时把 IsValid 的返回值记进诊断 ——
---   这样下一次采集就能看清"IsValid 到底骗了我们多少"。
function Capture.mesh_short_name(comp, diag)
    local d = diag
    if comp == nil then
        -- 具体原因由 Capture.mesh_component 写进 diag.reason
        if d and d.reason == nil then d.reason = "没有可用的 Mesh 组件" end
        return nil
    end
    -- ★ 细跟踪（崩溃排查用）: 只进文件、不刷控制台（调用方负责刷盘）
    local function tr(s)
        if Log ~= nil then Log.line("[cap/name] " .. tostring(s)) end
    end
    tr("开始 comp=" .. tostring(Util.full_name(comp)))
    if d then d.valid_comp = Util.valid(comp) end

    local ok_m, asset = pcall(function() return comp.StaticMesh end)
    if not ok_m or asset == nil then
        if d then d.reason = "组件存在，但 StaticMesh 为空" end
        tr("StaticMesh 为空（或读取失败）-> 返回 nil")
        return nil
    end
    -- ★★★ 2026-09-28: 玩家在【旧存档】里按 Y 崩，崩点就在下面两行 ——
    --   它们会去**碰那个网格资产指针**:
    --       Util.valid(asset)      → IsValid（要解引用对象）
    --       Util.full_name(asset)  → GetFullName（同样要解引用）
    --   老存档里可能存着"游戏更新后已被删除"的网格资源 ⇒ 那是**指向已释放内存的野指针**，
    --   碰它就是 EXCEPTION_ACCESS_VIOLATION（版本差异导致的典型表现）。
    --   先打标记再落盘: 崩了也能分清是"读到指针就崩"还是"指针能用、只是名字读不出来"。
    tr("StaticMesh 指针已读到（下一步会碰它）")
    if d then d.valid_asset = Util.valid(asset) end
    tr("Util.valid(asset) 通过")

    local a_full = Util.full_name(asset)
    tr("GetFullName 返回=" .. tostring(a_full))
    if a_full == nil then
        if d then d.reason = "StaticMesh 读到了但 GetFullName 不通（疑似占位对象）" end
        return nil
    end
    local short = a_full:match("([^%.]+)$") or a_full
    if short == "" then
        if d then d.reason = "网格名为空" end
        return nil
    end
    if d then d.mesh_full = a_full end
    return short
end

-- ---------------------------------------------------------------------------
-- 组件索引 —— 解决 obj.Mesh 读不出来（矿车方向第二次修的根因）
-- ---------------------------------------------------------------------------

--- 从世界上已经存在的网格组件建【宿主 Actor 名 -> 组件】索引。
---
--- ★★★ 为什么必须这样做（2026-09-26 更深夜，玩家第二次报矿车方向不对）:
---   第一次我以为 obj.Mesh 是"属性包装对象"，加了 Util.unwrap 就能救 —— **没用**，
---   实测部署后 61/72 种类型依然读不到。
---   真相是: obj.Mesh 返回的是 UE4SS 的 **TrivialObject**（方法表为空的假对象），
---   unwrap 里那句 v:get() 也不存在，只能原样返回，GetFullName 当然调不通。
---
---   但【同样的组件】用 FindAllOf("StaticMeshComponent") 枚举出来却是完好的，
---   而且组件全名里带着宿主 Actor 名:
---       ...PL_MainWorld5:PersistentLevel.<Actor名>.<组件名>
---   第 5 节反向取证就是靠这条规律覆盖了 70+ 种类型的。
---   所以反过来建索引: 枚举组件 -> 按宿主名归档 -> 采集时按名字取。
---
---   ★ 这个索引【只用来取朝向】，不用来取网格名。
---     原因: 一个建筑可能有多个网格组件（简约门 = 门框 + 左右门扇），
---     索引里只留第一个；如果用索引回填蓝图的 mesh 字段，
---     会让"映射表里的多网格"失效（actor 路径优先级更高），反而画出半个门。
---     朝向不受影响 —— 同一 Actor 的所有组件旋转一致。
function Capture.build_index()
    if Capture.index_ready then return Capture.n_index or 0 end
    Capture.index_comp = {}
    local classes = {
        "StaticMeshComponent",
        "SkeletalMeshComponent",
        "InstancedStaticMeshComponent",
        "HierarchicalInstancedStaticMeshComponent",
    }
    local n = 0
    for ci = 1, #classes do
        local ok, objs = pcall(function() return FindAllOf(classes[ci]) end)
        if ok and type(objs) == "table" then
            for i = 1, #objs do
                local full = Util.full_name(objs[i])
                if full ~= nil then
                    local actor = full:match("PersistentLevel%.([^%.]+)%.")
                    if actor ~= nil and Capture.index_comp[actor] == nil then
                        local comp = Util.unwrap(objs[i])
                        if comp ~= nil then
                            Capture.index_comp[actor] = comp
                            n = n + 1
                        end
                    end
                end
            end
        end
    end
    Capture.index_ready = true
    Capture.n_index = n
    return n
end

--- 按 Actor 名取索引里的组件。没有就返回 nil。
function Capture.index_component(obj)
    if obj == nil then return nil end
    if not Capture.index_ready then pcall(Capture.build_index) end
    local full = Util.full_name(obj)
    if full == nil then return nil end
    local actor = full:match("PersistentLevel%.(.+)$")
        or full:match("([^%.]+)$")
    if actor == nil then return nil end
    return Capture.index_comp[actor]
end

--- 建筑的【视觉朝向】（度）。
---
--- ★ 为什么不能直接用 actor 的 Yaw（2026-09-26 玩家实测）:
---   玩家发现「道具存取机」的方向偏了 —— 说明 actor 朝向 ≠ 网格朝向。
---   原因是美术在蓝图里给网格组件设了固定的相对旋转，所以:
---       网格世界朝向 = actor 朝向 + 组件相对旋转
---   优先取组件的【世界旋转】（最准），取不到才退回 actor 朝向。
---
--- 返回 yaw, 来源说明, 与 actor 朝向的差值
function Capture.visual_yaw(obj, comp)
    local _, actor_yaw, _ = Util.rot_of(obj)
    -- 防御性 unwrap: 调用方可能直接把 obj.Mesh 的原始值传进来
    if comp ~= nil then comp = Util.unwrap(comp) end

    if comp ~= nil then
        -- 首选: 组件的世界旋转（已经把 actor 旋转和相对旋转都算进去了）
        local ok, rot = pcall(function() return comp:K2_GetComponentRotation() end)
        if ok and rot ~= nil then
            local y = Util.num(rot, "Yaw")
            if y ~= nil then
                return y, "mesh组件世界旋转",
                    Util.norm_yaw(y - actor_yaw)
            end
        end
        -- 次选: actor 朝向 + 组件相对旋转
        local rel = Util.prop(comp, "RelativeRotation")
        local rel_yaw = Util.num(rel, "Yaw")
        if rel_yaw ~= nil and math.abs(rel_yaw) > 0.01 then
            local y = Util.norm_yaw(actor_yaw + rel_yaw)
            return y, "actor朝向+组件相对旋转",
                Util.norm_yaw(y - actor_yaw)
        end
    end
    return actor_yaw, "actor朝向", 0.0
end

--- 读一条建筑。返回 record 或 nil, 原因
function Capture.read_one(obj, diag)
    if obj == nil then return nil, "nil" end
    if not Util.valid(obj) then return nil, "invalid" end

    local x, y, z = Util.loc_of(obj)
    if x == nil then return nil, "no_position" end

    local t = Util.type_of(obj)
    if t == nil then t = "Unknown" end

    local comp = Capture.mesh_component(obj, diag)
    -- ★★ 组件索引兜底（矿车方向第二次修）:
    --   obj.Mesh 是 TrivialObject 时读不出任何东西，但组件确实存在，
    --   而且 FindAllOf 枚举得到。用宿主 Actor 名去索引里取。
    --   这里【只补组件、不补网格名】—— 见 Capture.build_index 的注释。
    if comp == nil then
        comp = Capture.index_component(obj)
        if comp ~= nil and diag ~= nil then diag.from_index = true end
    end
    -- 即使网格【名字】读不到，朝向也要尽力从组件上取 ——
    --   读旋转不需要名字，而且不带名字的占位组件上照样有正确的相对旋转。
    --   之前这里 comp 为 nil 就整段退回 actor 朝向，矿车的方向就是这么偏的。
    local yaw_comp = comp
    if yaw_comp == nil then
        pcall(function() yaw_comp = obj.Mesh end)
    end
    local yaw, yaw_src, yaw_delta = Capture.visual_yaw(obj, yaw_comp)

    if diag ~= nil then
        diag.yaw_src = yaw_src
        diag.yaw_delta = yaw_delta
    end

    return {
        t = t,
        x = x, y = y, z = z,
        yaw = yaw,
        mesh = Capture.mesh_short_name(comp, diag),
        -- ★★★ 2026-09-28: 同时把**完整资产路径**带出去（写进蓝图）。
        --   投影端靠它 `LoadAsset(路径)`，不再依赖"当前世界里加载了什么资产" ——
        --   这是"换存档投影缺件"的根治办法。见 pwpr_bp.lua 里的长注释。
        mesh_path = (diag ~= nil) and diag.mesh_full or nil,
    }
end

-- --------------------------------------------------------------------------
-- 扫描
-- --------------------------------------------------------------------------

--- 判断"这个类的继承链里有没有 wanted 这个名字"。
---
--- ★ 不用 `obj:IsA(...)`（UE4SS 对这个方法的暴露情况没验证过），
---   改成**读属性**走继承链: `UClass.SuperStruct` 是 UPROPERTY，读到的是父类，
---   一路向上比名字 —— 全程只读属性，不调方法，最稳。
local function class_chain_has(cls, wanted)
    for _ = 1, 12 do
        if cls == nil then return false end
        local fn = Util.full_name(cls)
        if type(fn) == "string" and fn:find(wanted, 1, true) ~= nil then
            return true
        end
        local sup = nil
        pcall(function() sup = cls.SuperStruct end)
        sup = Util.unwrap(sup)
        if sup == nil then return false end
        cls = sup
    end
    return false
end

--- 列出【当前关卡里】的建筑 Actor。
---
--- ★★★ 为什么不用 `FindAllOf("PalBuildObject")`（见 scan 里的长注释）:
---   它走全局对象表，而刚销毁的世界会留下大批死对象 ⇒ 遍历时解引用它们 = 崩。
---   `world.PersistentLevel.Actors` 是引擎维护的"本关卡活着的 Actor"数组，只含活对象。
---
--- 返回 objs, 来源说明；失败返回 nil, 原因
function Capture.list_build_actors()
    local out = {}
    local w = Util.find_world()
    local level = nil
    if w ~= nil then
        pcall(function() level = w.PersistentLevel end)
    end
    level = Util.unwrap(level)

    local actors = nil
    if level ~= nil then
        pcall(function() actors = level.Actors end)
    end
    if type(actors) == "table" and #actors > 0 then
        for i = 1, #actors do
            local a = Util.unwrap(actors[i])
            if a ~= nil then
                local cls = nil
                pcall(function() cls = a:GetClass() end)
                cls = Util.unwrap(cls)
                if class_chain_has(cls, Capture.ACTOR_CLASS) then
                    out[#out + 1] = a
                end
            end
        end
        if #out > 0 then
            return out, string.format("PersistentLevel.Actors（关卡共 %d 个 Actor）",
                #actors)
        end
        return out, string.format("PersistentLevel.Actors（关卡共 %d 个 Actor，其中没有建筑）",
            #actors)
    end

    -- 兜底: 老办法（全局对象表）。只有拿不到关卡列表时才走这里。
    local ok, objs = pcall(function() return FindAllOf(Capture.ACTOR_CLASS) end)
    if ok and type(objs) == "table" then
        return objs, "FindAllOf（全局表，可能含上个世界的死对象）"
    end
    return nil, "拿不到关卡 Actor 列表，FindAllOf 也失败"
end

--- filter: { mode = "all" | "sphere", cx, cy, cz, radius_cm }
--- 返回 records, info
function Capture.scan(filter, progress)
    filter = filter or { mode = "all" }
    local info = {
        total = 0, kept = 0, skipped = 0,
        no_position = 0, invalid = 0, unknown_type = 0,
        list_error = nil,
    }
    local records = {}

    -- ★★★ 2026-09-28: 枚举方式换了 —— **不再直接走全局对象表**。
    --
    -- 玩家实测的规律（很关键）:
    --   新存档 → 回标题 → 旧存档（大基地，2454 个 actor）→ 回标题 → 新存档 → 按 Y → **崩**。
    --   而日志显示: `==== 采集 ====` 之后**连一条 [scan] 都没打出来**就崩了 ——
    --   说明崩在**枚举本身**（或最前面几个对象上）。
    -- 机制: `FindAllOf` 会遍历**全局对象表**并对每个对象解引用它的类来判断继承；
    --   而刚被销毁的那个世界留下了大批**已释放的对象**，遍历到它们就是访问违例。
    --   ⇒ 改用 **当前关卡自己的 Actor 列表** `world.PersistentLevel.Actors`：
    --     那是引擎维护的"本关卡活着的 Actor"数组，里面不会有死对象。
    local objs, src = Capture.list_build_actors()
    if objs == nil then
        info.list_error = tostring(src)
        return records, info
    end
    if Log ~= nil then
        Log.emit(string.format("  [scan] 枚举到 %d 个建筑（来源: %s）",
            #objs, tostring(src)))
        Log.flush()
    end
    info.total = #objs

    local r2 = nil
    if filter.mode == "sphere" then
        if filter.cx == nil then
            info.list_error = "球体筛选缺少中心点"
            return records, info
        end
        local rcm = tonumber(filter.radius_cm) or 0
        r2 = rcm * rcm
    end

    Capture.mesh_diag = {}
    -- ★ 组件索引必须每次采集重建: 换地图/读档后 Actor 会换新对象，
    --   旧索引里的组件已经是上一个世界的了（拿它读旋转会读到过期数据）。
    Capture.index_ready = false
    Capture.index_comp = {}
    for i = 1, #objs do
        local diag = {}
        -- ★★★ 2026-09-28: 逐个对象写一行"正在处理谁"（只进文件、每 25 个刷一次盘）。
        --   玩家在【旧存档】里按 Y 崩过 —— 崩点在扫描过程中，而这行能直接指出
        --   **崩在哪一个建筑上**（老存档里可能有"游戏更新后已删除"的网格资源，
        --   碰它的指针就是野指针访问）。
        --   代价: 2454 个对象 × 1 行 ≈ 日志多 2454 行，可接受（只进文件不刷控制台）。
        if Log ~= nil then
            local okn, nm = pcall(function() return Util.full_name(objs[i]) end)
            Log.line(string.format("  [scan] %d/%d %s", i, #objs,
                (okn and type(nm) == "string") and nm or "（名字读不到）"))
            -- ★ 前 50 个逐个刷盘（崩点通常在最前面几个），之后每 25 个刷一次。
            --   教训: 上一次崩在"第 1~24 个对象"，而我只在 25 的倍数刷盘，
            --   结果那几行全被缓冲吞掉、什么也没留下来 ⇒ 这次改成一开始就逐个落盘。
            if i <= 50 or (i % 25) == 0 then Log.flush() end
        end
        local rec, why = Capture.read_one(objs[i], diag)
        if rec == nil then
            if why == "no_position" then
                info.no_position = info.no_position + 1
            else
                info.invalid = info.invalid + 1
            end
        else
            if rec.t == "Unknown" then info.unknown_type = info.unknown_type + 1 end
            local keep = true
            if r2 ~= nil then
                local dx = rec.x - filter.cx
                local dy = rec.y - filter.cy
                local dz = rec.z - filter.cz
                keep = (dx * dx + dy * dy + dz * dz) <= r2
            end
            if keep then
                records[#records + 1] = rec
                info.kept = info.kept + 1
                -- 按类型聚合网格读取诊断
                local td = Capture.mesh_diag[rec.t]
                if td == nil then
                    td = { n = 0, with_mesh = 0, diag = diag }
                    Capture.mesh_diag[rec.t] = td
                end
                td.n = td.n + 1
                if rec.mesh ~= nil then
                    td.with_mesh = td.with_mesh + 1
                    -- 优先保留"成功读到网格"的那个样本，失败原因才有意义
                    if td.diag == nil or td.diag.mesh_full == nil then
                        td.diag = diag
                    end
                end
            else
                info.skipped = info.skipped + 1
            end
        end
        -- 进度回调（可选），用于长扫描时给玩家反馈
        if progress ~= nil and (i % 100 == 0 or i == #objs) then
            pcall(progress, i, #objs)
        end
    end

    return records, info
end

-- --------------------------------------------------------------------------
-- 按类型汇总（用于诊断"哪些类型缺网格"）
-- --------------------------------------------------------------------------

--- 返回按数量降序的 { {t=, count=, mesh=, sample_z=}, ... }
function Capture.type_table(records)
    local by_type = {}
    local order = {}
    for i = 1, #records do
        local r = records[i]
        local e = by_type[r.t]
        if e == nil then
            e = { t = r.t, count = 0, mesh = nil, z_min = nil, z_max = nil }
            by_type[r.t] = e
            order[#order + 1] = r.t
        end
        e.count = e.count + 1
        if e.mesh == nil and r.mesh ~= nil then e.mesh = r.mesh end
        if e.z_min == nil or r.z < e.z_min then e.z_min = r.z end
        if e.z_max == nil or r.z > e.z_max then e.z_max = r.z end
    end
    local list = {}
    for i = 1, #order do list[i] = by_type[order[i]] end
    table.sort(list, function(a, b)
        if a.count == b.count then return a.t < b.t end
        return a.count > b.count
    end)
    return list
end

--- 生成一份人类可读的类型报告（写文件用）
function Capture.type_report_lines(records, limit)
    local list = Capture.type_table(records)
    local out = {}
    out[#out + 1] = string.format("%-34s %8s  %-34s", "短类型名", "数量", "网格资产")
    out[#out + 1] = string.rep("-", 80)
    local lim = math.min(#list, limit or 400)
    local no_mesh = 0
    for i = 1, lim do
        local e = list[i]
        if e.mesh == nil then no_mesh = no_mesh + 1 end
        out[#out + 1] = string.format("%-34s %8d  %-34s",
            e.t, e.count, e.mesh or "-")
    end
    out[#out + 1] = string.rep("-", 80)
    out[#out + 1] = string.format("共 %d 种类型，其中 %d 种没有直接的网格资产（结构件属于这一类）",
        #list, no_mesh)
    return out, list
end

--- 网格读取诊断报告。
--- 关键用途：直接回答"到底为什么读不到网格" —— 是组件没有、
--- 还是 StaticMesh 为空、还是 IsValid 误判。
function Capture.mesh_diag_lines()
    local out = {}
    out[#out + 1] = "## 3. 网格读取诊断（每个类型取一个样本，说明为什么读不到）"
    out[#out + 1] = ""
    out[#out + 1] = string.format("%-30s %6s %6s  %-9s %-9s %-9s %s",
        "短类型名", "件数", "有网格", "comp有效", "asset有效", "朝向差", "说明")
    out[#out + 1] = string.rep("-", 122)

    local names = {}
    for t in pairs(Capture.mesh_diag) do names[#names + 1] = t end
    table.sort(names)

    local n_no_mesh, n_baked = 0, 0
    local n_no_component, n_bad_component, n_from_index = 0, 0, 0
    for i = 1, #names do
        local t = names[i]
        local e = Capture.mesh_diag[t]
        local d = e.diag or {}
        if d.from_index == true then n_from_index = n_from_index + 1 end
        if e.with_mesh == 0 then
            n_no_mesh = n_no_mesh + 1
            if d.raw_mesh_exists == true then
                n_bad_component = n_bad_component + 1
            else
                n_no_component = n_no_component + 1
            end
        end
        local dy = tonumber(d.yaw_delta) or 0
        if math.abs(dy) > 0.5 then n_baked = n_baked + 1 end
        local why = d.mesh_full or d.reason or "-"
        out[#out + 1] = string.format("%-30s %6d %6d  %-9s %-9s %-9s %s",
            t, e.n, e.with_mesh,
            tostring(d.valid_comp), tostring(d.valid_asset),
            string.format("%.1f", dy),
            tostring(why))
    end
    out[#out + 1] = string.rep("-", 122)
    out[#out + 1] = string.format(
        "共 %d 种类型，其中 %d 种一件都没读到网格", #names, n_no_mesh)
    out[#out + 1] = string.format(
        "  · %d 种是【obj.Mesh 本身就是 nil】—— 游戏没给这些建筑 Mesh 组件"
        .. "（和结构件一样由 HISM 批量绘制）。这是游戏侧的事实，不是我们读不到。",
        n_no_component)
    out[#out + 1] = string.format(
        "  · %d 种是【有组件但读失败】—— 这才可能是我们的问题，需要单独查。",
        n_bad_component)
    out[#out + 1] = string.format(
        "组件索引: 归档 %d 个宿主 Actor；本次采集有 %d 种类型靠索引拿到了组件"
        .. "（obj.Mesh 是 TrivialObject 时走这条路取朝向）",
        Capture.n_index or 0, n_from_index)
    out[#out + 1] = string.format(
        "★ 其中 %d 种的【网格朝向和 actor 朝向不一致】（朝向差 != 0）—— "
        .. "这些就是「方向偏了」的原因，本版已改用网格朝向", n_baked)
    out[#out + 1] = ""
    out[#out + 1] = "读法说明: 本版【不再】用 IsValid() 判定组件/资产（那会把好对象"
    out[#out + 1] = "误判为无效），改为 PWRecon 验证过的「能调通 GetFullName 就算有」。"
    out[#out + 1] = "上表里的 comp有效/asset有效 两列只作记录，不参与判定。"
    out[#out + 1] = "朝向差 = 网格世界朝向 - actor 朝向（度）；非 0 说明美术给网格组件"
    out[#out + 1] = "设了固定的相对旋转。"
    return out
end

--- 组装成蓝图（坐标换算 + 分层 + 统计都在 pwpr_bp 里做）
function Capture.to_blueprint(records, opts)
    return BP.build(records, opts)
end

return Capture
