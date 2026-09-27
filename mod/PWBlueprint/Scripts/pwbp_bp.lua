--[[ ===========================================================================
  PWBP · bp  ——  蓝图数据模型（纯 Lua，无引擎依赖）

  与 docs/蓝图格式.md 的 v1 规范严格一致：
    { "$format": "palworld-blueprint", "version": 1,
      "meta": {...}, "stats": {...}, "buildings": [ {t,p,yaw,mesh,layer}, ... ] }

  坐标系（最容易搞错的一点）:
    · 输入 records 的 x/y/z 是【世界厘米】
    · 输出 buildings[].p 是以【包围盒中心】为原点的【米】偏移，范围 ±size/2
    · meta.origin 是导出时的世界坐标（米），仅作记录，导入时不依赖
    · meta.origin 会向下吸附到 origin_snap_m 的网格 —— 所以相对坐标
      可能略微超出 ±size/2，这是正常的（见规范第 4 节）
=========================================================================== ]]

local Util = require("pwbp_util")

local BP = {}

BP.FORMAT = "palworld-blueprint"
BP.VERSION = 1
BP.SUPPORTED_VERSIONS = { [1] = true }

local function is_num(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- --------------------------------------------------------------------------
-- 分层：按 Z 聚类（比"固定层高"更贴合实际建筑）
-- --------------------------------------------------------------------------

--- 输入一列 Z（厘米），返回每层的起始 Z 数组（升序）
function BP.layer_bounds(zs, gap_cm)
    local sorted = {}
    for i = 1, #zs do sorted[i] = zs[i] end
    table.sort(sorted)
    local bounds = {}
    for i = 1, #sorted do
        if i == 1 or (sorted[i] - sorted[i - 1]) > gap_cm then
            bounds[#bounds + 1] = sorted[i]
        end
    end
    return bounds
end

--- 二分查找 z 属于第几层（bounds 为升序的层起始 Z）
function BP.layer_of(z, bounds)
    local lo, hi, ans = 1, #bounds, 0
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if bounds[mid] <= z then
            ans = mid
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return ans - 1        -- 0 基
end

-- --------------------------------------------------------------------------
-- 构建
-- --------------------------------------------------------------------------

--- records: { {t=类型, x=,y=,z= (世界厘米), yaw=度, mesh=资产短名或nil}, ... }
--- opts:    { name=, source=, gameVersion=, layerGapCm=, snapM= }
--- 返回 bp 表 或 nil, 错误
function BP.build(records, opts)
    opts = opts or {}
    if type(records) ~= "table" or #records == 0 then
        return nil, "没有可用的建筑记录"
    end

    local gap_cm = tonumber(opts.layerGapCm) or 200
    local snap_m = tonumber(opts.snapM) or 1.0
    if snap_m <= 0 then snap_m = 1.0 end

    -- 1) 包围盒
    local minx, miny, minz = math.huge, math.huge, math.huge
    local maxx, maxy, maxz = -math.huge, -math.huge, -math.huge
    local zs = {}
    for i = 1, #records do
        local r = records[i]
        if not (is_num(r.x) and is_num(r.y) and is_num(r.z)) then
            return nil, string.format("第 %d 条记录坐标非法", i)
        end
        if r.x < minx then minx = r.x end
        if r.y < miny then miny = r.y end
        if r.z < minz then minz = r.z end
        if r.x > maxx then maxx = r.x end
        if r.y > maxy then maxy = r.y end
        if r.z > maxz then maxz = r.z end
        zs[i] = r.z
    end

    -- 2) 原点 = 包围盒中心，向下吸附到网格（厘米）
    local snap_cm = snap_m * 100.0
    local cx = math.floor(((minx + maxx) * 0.5) / snap_cm) * snap_cm
    local cy = math.floor(((miny + maxy) * 0.5) / snap_cm) * snap_cm
    local cz = math.floor(((minz + maxz) * 0.5) / snap_cm) * snap_cm

    -- 3) 分层
    local bounds = BP.layer_bounds(zs, gap_cm)

    -- 4) 装配
    local buildings = {}
    local type_counts, type_mesh = {}, {}
    -- ★ 2026-09-28: 同时统计"完整路径"的覆盖情况（换存档投影是否完整看这个）
    local type_mesh_path, with_path = {}, 0
    local layer_count, layer_zmin, layer_zmax = {}, {}, {}
    local with_mesh = 0

    for i = 1, #records do
        local r = records[i]
        local rx = (r.x - cx) / 100.0
        local ry = (r.y - cy) / 100.0
        local rz = (r.z - cz) / 100.0
        local layer = BP.layer_of(r.z, bounds)

        local b = {
            t = tostring(r.t or "Unknown"),
            p = { Util.round(rx, 3), Util.round(ry, 3), Util.round(rz, 3) },
            yaw = Util.round(Util.norm_yaw(r.yaw or 0.0), 2),
            layer = layer,
        }
        if type(r.mesh) == "string" and r.mesh ~= "" and r.mesh ~= "-" then
            b.mesh = r.mesh
            with_mesh = with_mesh + 1
            if type_mesh[b.t] == nil then type_mesh[b.t] = r.mesh end
        end
        -- ★★★ 2026-09-28: 把网格的**完整资产路径**也写进蓝图。
        --
        -- 为什么必须写（玩家反馈: "换一个存档投影就缺件，那这模组就没意义了"）:
        --   蓝图原来只存【短名】（如 `SM_Floor_Wood`），投影时靠
        --   "短名 → 路径"的注册表去查 —— 而那张表是用 `FindAllOf("StaticMesh")`
        --   建的，**只包含当前世界里已经加载的资产**。
        --   在【采集的那个存档】里，那些建筑都在场，资产自然全加载（能解析）；
        --   换到【另一个存档】，蓝图里的大量资产根本没被加载 → 查不到 → 跳过不画
        --   ⇒ 表现就是"投影缺件"。
        --   ⇒ 采集时我们**本来就知道完整路径**（从 actor 的网格组件上读到的全名），
        --     把它存下来，投影时直接 `LoadAsset(路径)` —— 与"当前加载了什么"无关。
        --   （旧蓝图没有这个字段，仍然走原来的短名解析 → 缺件的老蓝图建议重采一次。）
        --
        -- ★★★ 2026-09-28 第二个坑（这个 bug 让上面那套修复**完全没生效**）:
        --   `Util.full_name()` 返回的是 **"StaticMesh /Game/Pal/.../X.X"** ——
        --   **带类名前缀**（日志里每行 `全名=StaticMesh /Game/...` 都是这个格式）。
        --   我原来写的是 `r.mesh_path:sub(1,1) == "/"`，首字符其实是 `S`
        --   ⇒ **每一条记录都被挡掉**，蓝图里一个 `mesh_path` 都没有
        --   （玩家重采了很多次也没用，因为问题不在采集，在这行判断）。
        --   ⇒ 正确做法: 先把 `/` 之后的部分抠出来，再用它当路径。
        if type(r.mesh_path) == "string" then
            local only = r.mesh_path:match("(/.*)$")   -- 去掉 "StaticMesh " 之类的前缀
            if only ~= nil and only:find("/Game/", 1, true) ~= nil then
                b.mesh_path = only
                with_path = with_path + 1
                if type_mesh_path[b.t] == nil then
                    type_mesh_path[b.t] = only
                end
            end
        end
        buildings[i] = b

        type_counts[b.t] = (type_counts[b.t] or 0) + 1

        local lk = layer
        layer_count[lk] = (layer_count[lk] or 0) + 1
        local z = b.p[3]
        if layer_zmin[lk] == nil or z < layer_zmin[lk] then layer_zmin[lk] = z end
        if layer_zmax[lk] == nil or z > layer_zmax[lk] then layer_zmax[lk] = z end
    end

    -- 5) stats
    local types = {}
    for t, n in pairs(type_counts) do
        local e = { count = n }
        if type_mesh[t] then e.mesh = type_mesh[t] end
        types[t] = e
    end
    local layers = {}
    for lk, n in pairs(layer_count) do
        layers[tostring(lk)] = {
            count = n,
            z_min = Util.round(layer_zmin[lk] or 0.0, 3),
            z_max = Util.round(layer_zmax[lk] or 0.0, 3),
        }
    end

    local n_types = 0
    for _ in pairs(type_counts) do n_types = n_types + 1 end

    local bp = {
        ["$format"] = BP.FORMAT,
        version = BP.VERSION,
        meta = {
            name = tostring(opts.name or "blueprint"),
            createdAt = Util.now_iso(),
            source = tostring(opts.source or "PWBlueprint (UE4SS)"),
            gameVersion = tostring(opts.gameVersion or "Palworld 1.0.x"),
            total = #buildings,
            typeCount = n_types,
            layerCount = #bounds,
            units = "meter",
            origin = { Util.round(cx / 100.0, 3),
                       Util.round(cy / 100.0, 3),
                       Util.round(cz / 100.0, 3) },
            size = {
                x = Util.round((maxx - minx) / 100.0, 3),
                y = Util.round((maxy - miny) / 100.0, 3),
                z = Util.round((maxz - minz) / 100.0, 3),
            },
            layerGapCm = gap_cm,
            meshCoverage = { withMesh = with_mesh, withPath = with_path, total = #buildings },
            -- ★ 自检（2026-09-28 加）: 有网格名、却一个完整路径都没写出来 ——
            --   这正是那个 bug 的样子（`Util.full_name` 带 "StaticMesh " 前缀，
            --   而我按"首字符是 /"去判断 ⇒ 全部被挡掉 ⇒ 蓝图没有 mesh_path
            --   ⇒ 换存档投影缺件，而且**采集日志一切正常**，很难发现）。
            --   有了这一行，下次同样的毛病会在采集当场就喊出来。
            meshPathWarn = (with_mesh > 0 and with_path == 0)
                and "读了网格名但没写出任何 mesh_path —— 路径提取逻辑可能失效（跨存档投影会缺件）"
                or nil,
        },
        stats = { types = types, layers = layers },
        buildings = buildings,
    }
    return bp
end

-- --------------------------------------------------------------------------
-- 校验（与 tools/blueprint.py check 的规则保持一致）
-- --------------------------------------------------------------------------

--- 返回 ok(boolean), errors(表), warnings(表)
function BP.validate(bp)
    local errors, warnings = {}, {}
    local function E(s) errors[#errors + 1] = s end
    local function W(s) warnings[#warnings + 1] = s end

    if type(bp) ~= "table" then
        E("顶层不是对象")
        return false, errors, warnings
    end
    if bp["$format"] == nil then E("缺少 $format") 
    elseif bp["$format"] ~= BP.FORMAT then
        E("$format 不等于 " .. BP.FORMAT .. "（实际 " .. tostring(bp["$format"]) .. "）")
    end
    if type(bp.version) ~= "number" then
        E("缺少 version")
    elseif not BP.SUPPORTED_VERSIONS[bp.version] then
        W("version = " .. tostring(bp.version) .. " 不是本工具支持的版本")
    end

    local meta = bp.meta
    if type(meta) ~= "table" then
        E("缺少 meta")
    else
        if meta.units ~= "meter" then
            E("meta.units 必须是 \"meter\"（实际 " .. tostring(meta.units) .. "）")
        end
        if type(meta.total) ~= "number" then
            W("meta.total 缺失")
        end
    end

    local bs = bp.buildings
    if type(bs) ~= "table" then
        E("缺少 buildings")
        return #errors == 0, errors, warnings
    end
    if type(meta) == "table" and type(meta.total) == "number"
        and meta.total ~= #bs then
        E(string.format("meta.total = %d 与实际条数 %d 不符", meta.total, #bs))
    end

    local seen_types, layer_seen = {}, {}
    for i = 1, #bs do
        local b = bs[i]
        if type(b) ~= "table" then
            E(string.format("buildings[%d] 不是对象", i))
        else
            if type(b.t) ~= "string" or b.t == "" then
                E(string.format("buildings[%d].t 缺失或非字符串", i))
            else
                seen_types[b.t] = true
            end
            if type(b.p) ~= "table" or #b.p ~= 3
                or not (is_num(b.p[1]) and is_num(b.p[2]) and is_num(b.p[3])) then
                E(string.format("buildings[%d].p 不是 3 个数字", i))
            end
            if b.yaw ~= nil then
                if not is_num(b.yaw) then
                    E(string.format("buildings[%d].yaw 不是数字", i))
                elseif b.yaw < -180.0 or b.yaw > 180.0 then
                    W(string.format("buildings[%d].yaw = %s 超出 -180..180", i, tostring(b.yaw)))
                end
            end
            if b.layer == nil then
                W(string.format("buildings[%d] 缺少 layer", i))
            else
                layer_seen[b.layer] = true
            end
        end
    end

    -- stats 一致性
    local stats = bp.stats
    if type(stats) == "table" and type(stats.types) == "table" then
        local actual = {}
        for i = 1, #bs do
            local b = bs[i]
            if type(b) == "table" and type(b.t) == "string" then
                actual[b.t] = (actual[b.t] or 0) + 1
            end
        end
        for t, entry in pairs(stats.types) do
            if type(entry) == "table" and type(entry.count) == "number" then
                if entry.count ~= (actual[t] or 0) then
                    E(string.format("stats.types[%s].count = %d 实际 %d",
                        tostring(t), entry.count, actual[t] or 0))
                end
            end
            if seen_types[t] == nil then
                W("stats.types 里有 buildings 中不存在的类型: " .. tostring(t))
            end
        end
    end

    return #errors == 0, errors, warnings
end

-- --------------------------------------------------------------------------
-- 摘要 / 分层过滤
-- --------------------------------------------------------------------------

--- 返回若干行文字，用于控制台输出
function BP.summary_lines(bp, max_types)
    local out = {}
    if type(bp) ~= "table" then return { "(空蓝图)" } end
    local meta = bp.meta or {}
    local size = meta.size or {}
    out[#out + 1] = string.format("名称     %s", tostring(meta.name or "?"))
    out[#out + 1] = string.format("建筑数   %s    类型数 %s    层数 %s",
        tostring(meta.total or #(bp.buildings or {})),
        tostring(meta.typeCount or "?"),
        tostring(meta.layerCount or "?"))
    out[#out + 1] = string.format("包围盒   %.1f x %.1f x %.1f 米",
        tonumber(size.x) or 0, tonumber(size.y) or 0, tonumber(size.z) or 0)
    local mc = meta.meshCoverage
    if type(mc) == "table" then
        out[#out + 1] = string.format("有网格   %s / %s",
            tostring(mc.withMesh), tostring(mc.total))
    end

    local stats = bp.stats
    if type(stats) == "table" and type(stats.layers) == "table" then
        local keys = {}
        for k in pairs(stats.layers) do keys[#keys + 1] = tonumber(k) or 0 end
        table.sort(keys)
        for i = 1, #keys do
            local e = stats.layers[tostring(keys[i])] or {}
            out[#out + 1] = string.format("  层 %d: %-5s 件   Z %s .. %s",
                keys[i], tostring(e.count or "?"),
                tostring(e.z_min or "?"), tostring(e.z_max or "?"))
        end
    end

    if type(stats) == "table" and type(stats.types) == "table" then
        local list = {}
        for t, e in pairs(stats.types) do
            list[#list + 1] = { t = t, n = (type(e) == "table" and e.count) or 0 }
        end
        table.sort(list, function(a, b)
            if a.n == b.n then return a.t < b.t end
            return a.n > b.n
        end)
        local lim = math.min(#list, max_types or 12)
        for i = 1, lim do
            out[#out + 1] = string.format("  %-32s %d", list[i].t, list[i].n)
        end
        if #list > lim then
            out[#out + 1] = string.format("  ... 还有 %d 种类型", #list - lim)
        end
    end
    return out
end

--- 按分层模式挑出要显示的建筑（返回下标数组 + 计数）
--- mode: "all" | "single" | "range"
function BP.select_indices(bp, mode, index, lo, hi)
    local bs = bp and bp.buildings
    local picked = {}
    if type(bs) ~= "table" then return picked end
    for i = 1, #bs do
        local b = bs[i]
        local layer = (type(b) == "table" and tonumber(b.layer)) or 0
        local keep = true
        if mode == "single" then
            keep = (layer == (index or 0))
        elseif mode == "range" then
            keep = (layer >= (lo or 0) and layer <= (hi or 0))
        end
        if keep then picked[#picked + 1] = i end
    end
    return picked
end

--- 相对位置（米）-> 相对位置（厘米），渲染用
function BP.rel_cm(b)
    if type(b) ~= "table" or type(b.p) ~= "table" then return nil end
    return (tonumber(b.p[1]) or 0) * 100.0,
           (tonumber(b.p[2]) or 0) * 100.0,
           (tonumber(b.p[3]) or 0) * 100.0
end

--- 统计每个"网格资产"下有多少建筑 —— 渲染按资产分组，一组一个 ISM 组件
function BP.group_by_mesh(bp, picked, resolve)
    local groups, order = {}, {}
    local bs = bp and bp.buildings or {}
    for i = 1, #picked do
        local b = bs[picked[i]]
        if type(b) == "table" then
            local mesh = resolve(b)
            if mesh then
                if groups[mesh] == nil then
                    groups[mesh] = {}
                    order[#order + 1] = mesh
                end
                groups[mesh][#groups[mesh] + 1] = b
            end
        end
    end
    return groups, order
end

return BP
