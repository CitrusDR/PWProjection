--[[
    pwpr_placed.lua —— "**已经放上去的那一件，投影就不再画**"

    ─────────────────────────────────────────────────────────────────────────
    为什么要有它（2026-09-29 玩家反馈）
    ─────────────────────────────────────────────────────────────────────────
    玩家原话:
      「投影上对应的建筑已经放下了，但是投影还在，会导致实际游戏渲染的彩色
        和投影的蓝色交替闪来闪去，可不可以放上了的就不渲染，拆掉再继续渲染呢」

    现象的解释: 我们按投影的坐标把实物放下去之后，**实物和投影的蓝色网格
    几乎完全重合** ⇒ 两个面在同一个深度上互相争夺（z-fighting）⇒ 肉眼看到
    的就是"彩色 / 蓝色交替闪"。不重合的时候反而不闪。

    做法（两条互补）:
      ① **重灌时扫一遍**（`Placed.refresh`）: 用 `Snap.gather` 拿到投影范围内的
         **真实建筑**（位置 + 类型），对每一条投影记录问一句"同类型、附近
         有没有实物" ⇒ 有就把这条记录**排除渲染**（写进 `Ghost.skip`）。
         这一步同时覆盖了"拆掉恢复"（拆了就没有实物了 ⇒ 不再排除）。
      ② **放下瞬间立刻隐藏**（`Placed.note_new_object`）: UE4SS 的
         `NotifyOnNewObject` 会在新建筑出现时通知我们，拿着这个 actor 的
         位置/类型直接匹配到记录 ⇒ 立刻标记隐藏并重灌一次。
         不用等下一次全扫（全扫要读几千个 actor，会卡一下）。

    拆掉之后怎么恢复: ② 里我们**记着那个 actor 的引用**，每隔几秒检查一次
    "它还活着吗"（`Util.valid`）；发现它没了 ⇒ 认为被拆了 ⇒ 解除隐藏并重灌。
    （世界切换时 main 会调 `Placed.forget()` 丢掉这些引用，绝不跨世界持有。）

    安全约定（和规矩 3b 一致）: 全程 pcall；任何一步失败都只是"没隐藏/没恢复"，
    绝不影响放置本身。

    配置: `ghost_hide_placed`（默认 true）、`ghost_hide_placed_cm`（默认 100）。
]]

local Util = require("pwpr_util")
local Log = require("pwpr_log")

local Placed = {}

Placed.hidden = {}        -- [记录序号] = true —— 这一条不再渲染
Placed.refs = {}          -- [记录序号] = actor —— 用来判断"拆掉了没有"
Placed.pending = {}       -- [记录序号] = true —— 已放上、**等批量窗口结束**再一起隐藏
Placed.pending_actor = {} -- [记录序号] = actor（批量窗口结束时一起并进 refs）
Placed.last_n = 0         -- 上一次隐藏了几件
-- ★ 进度版本号: 只要"已放上的名单"变过就 +1。用途 = 让调用方**只在真的变了**时才
--   把进度同步给"位置/进度记忆"（否则看门狗每 2.5 秒都会标脏 ⇒ 白白多写盘）。
Placed.version = 0
Placed.last_src = nil     -- 上一次的数据来源（日志/状态里显示）
Placed.max_records = 4000 -- 保险: 记录特别多时不全扫（避免长时间卡顿）

local function cfg_get(key)
    local ok, v = pcall(function()
        return require("pwpr_config").get(key)
    end)
    if ok then return v end
    return nil
end

--- 一条记录在当前投影下的世界坐标（与 pwrp_buildsnap / pwpr_snap 同一公式）
local function record_world(place, b)
    if type(b) ~= "table" or type(b.p) ~= "table" then return nil end
    local rx = (tonumber(b.p[1]) or 0.0) * 100.0
    local ry = (tonumber(b.p[2]) or 0.0) * 100.0
    local rz = (tonumber(b.p[3]) or 0.0) * 100.0
    local rad = math.rad(place.yaw or 0.0)
    local c, s = math.cos(rad), math.sin(rad)
    return place.x + (rx * c - ry * s), place.y + (rx * s + ry * c), place.z + rz
end

--- 清空（收起投影 / 换蓝图 / 换世界时调用）
function Placed.forget()
    Placed.hidden = {}
    Placed.refs = {}
    Placed.pending = {}
    Placed.pending_actor = {}
    Placed.last_n = 0
    Placed.version = Placed.version + 1     -- 进度变了（清空也算变）
end

--- ★ **精确隐藏一条记录**（吸附那边告诉我们"我正要往这一条放"）。
---
--- 为什么这条最重要（2026-09-29 实测）: 它是**唯一不需要猜**的路径 ——
---   投影侧知道玩家瞄准的是哪一条记录，所以"放一块 = 藏一条"，不会误伤旁边。
---   而全扫那条路是"按坐标猜"，只能作为兜底（拆掉恢复、别人放的东西等）。
---
--- ★ 2026-09-29 玩家提的方案（已实现）: **入队，不立刻隐藏**。
---   连放时只记录（零开销），停下来（默认 3 秒没有新放置）再**一次性**隐藏。
---   好处: ① 连放 20 块只重灌一次；② 每条记录只入队一次，放再快也不会漏。
function Placed.hide_now(rec_idx)
    if rec_idx == nil then return false end
    if Placed.hidden[rec_idx] == true then return false end
    if Placed.pending[rec_idx] == true then return false end
    Placed.pending[rec_idx] = true
    Placed.version = Placed.version + 1      -- 进度变了（见 Placed.version 的说明）
    -- ★ 记下"最后一次入队的时间" —— 队列表用它判断"安静够久了没有"
    --   （批量清算除了定时回调，还有一条兜底路径看这个值，见 main 的 watch tick）
    Placed.pending_since = os.clock()
    Placed.last_pending_n = Placed.pending_count()
    return true
end

--- 待处理队列"安静"了多少秒（没有待处理就返回 0）
function Placed.pending_idle_s()
    if Placed.pending_since == nil then return 0.0 end
    if Placed.pending_count() == 0 then return 0.0 end
    return os.clock() - Placed.pending_since
end

--- 一条记录在某个"投影变换"下的世界坐标（厘米）—— 对外公开，
--- 供"进度跨锚点换算"使用（内部那个是 local，这里包一层）。
function Placed.record_world_at(place, b)
    if type(place) ~= "table" or type(b) ~= "table" then return nil end
    return record_world(place, b)
end

--- ★★★ 2026-09-29 玩家实测（三个问题同一个根因）: **进度是"序号"，而序号的世界位置
---   依赖锚点**。按 `H` 挪一下投影（哪怕只挪几十米），那批序号对应的位置就整体平移了 ⇒
---   于是"藏错了件"（投影缺了不该缺的）或"什么都不藏"（K 重开后建过的又画出来）。
---   ⇒ 这里按**几何**把一份序号从一个锚点换算到另一个锚点:
---     对每个序号，算出它在 `from_place` 下的世界坐标，再在 `to_place` 下找**最近的记录**
---     （容差内、一对一贪心）⇒ 返回新的序号表。
---   容差取 200 厘米: 覆盖"锚点挪了几米"（记录间距通常 ≥ 一个地基边长 ≈ 2~4 米）。
function Placed.convert_indices(bp, from_place, indices, to_place, tol_cm)
    if type(bp) ~= "table" or type(bp.buildings) ~= "table" then return nil end
    if type(from_place) ~= "table" or type(to_place) ~= "table" then return nil end
    if type(indices) ~= "table" then return nil end
    local tol = tonumber(tol_cm) or 200.0
    local tol2 = tol * tol

    -- 目标锚点下所有记录的世界坐标（一次算好）
    local dst = {}
    for i = 1, #bp.buildings do
        local w = Placed.record_world_at(to_place, bp.buildings[i])
        if w ~= nil then
            dst[#dst + 1] = { idx = i, x = w[1], y = w[2], z = w[3] }
        end
    end
    if #dst == 0 then return nil end

    local pairs_all = {}
    for _, src_idx in ipairs(indices) do
        local b = bp.buildings[src_idx]
        if type(b) == "table" then
            local w = Placed.record_world_at(from_place, b)
            if w ~= nil then
                for j = 1, #dst do
                    local d = dst[j]
                    local dx, dy, dz = d.x - w[1], d.y - w[2], d.z - w[3]
                    local d2 = dx * dx + dy * dy + dz * dz
                    if d2 <= tol2 then
                        pairs_all[#pairs_all + 1] =
                            { src = src_idx, dst = d.idx, d2 = d2 }
                    end
                end
            end
        end
    end
    table.sort(pairs_all, function(a, b2)
        if a.d2 ~= b2.d2 then return a.d2 < b2.d2 end
        return a.src < b2.src
    end)
    local out, used_dst, seen_src = {}, {}, {}
    for k = 1, #pairs_all do
        local pr = pairs_all[k]
        if seen_src[pr.src] ~= true and used_dst[pr.dst] ~= true then
            seen_src[pr.src] = true
            used_dst[pr.dst] = true
            out[#out + 1] = pr.dst
        end
    end
    table.sort(out)
    return out
end

--- ★ 导出"已放上"的进度（记录序号数组）—— 给"位置/进度记忆"落盘用。
---   放在这里而不是直接读 Placed.hidden，是为了让"进度"只有这一个出口。
function Placed.export_list()
    local out = {}
    for idx in pairs(Placed.hidden) do out[#out + 1] = idx end
    table.sort(out)
    return out
end

--- ★ 从记忆里恢复进度（下次加载同一张蓝图时，先按上次的进度把已建好的那批不画）。
---   `max_idx` = 当前蓝图的记录总数 ⇒ 超出范围的序号一律丢掉
---   （蓝图文件重名概率低，但"宁可丢也不能画错"）。
function Placed.load_from(list, max_idx)
    if type(list) ~= "table" then return 0 end
    local n, dropped = 0, 0
    for _, idx in ipairs(list) do
        local i = tonumber(idx)
        if i ~= nil and (max_idx == nil or i <= max_idx) then
            Placed.hidden[i] = true
            n = n + 1
        elseif i ~= nil then
            dropped = dropped + 1
        end
    end
    if dropped > 0 then
        Log.emit(string.format(
            "  [placed] 记忆里有 %d 条进度超出当前蓝图范围，已丢掉", dropped))
    end
    if n > 0 then Placed.version = Placed.version + 1 end   -- 进度变了
    return n
end

--- ★ 这一条记录是不是"已经放上过了"（已隐藏，或在待处理队列里）。
--- 用途: 吸附的"防误配"闸 —— 已经放上的位置不要再把人往那儿按（那儿已被占住）。
function Placed.is_taken(rec_idx)
    if rec_idx == nil then return false end
    return Placed.hidden[rec_idx] == true or Placed.pending[rec_idx] == true
end

--- 等批量窗口结束时调用: 把"待隐藏"的挪进"隐藏"名单，返回这次的记录序号表。
--- 没有待处理的就返回空表。
function Placed.take_pending()
    local list = {}
    for idx in pairs(Placed.pending) do
        list[#list + 1] = idx
        Placed.hidden[idx] = true
        local actor = Placed.pending_actor[idx]
        if actor ~= nil then Placed.refs[idx] = actor end
    end
    Placed.pending = {}
    Placed.pending_actor = {}
    Placed.pending_since = nil
    Placed.last_n = Placed.count()
    if #list > 0 then Placed.version = Placed.version + 1 end   -- 进度变了
    return list
end

--- 撤销"待隐藏"（游戏拒绝了这次放置时用）。返回 true 表示确实取消了
function Placed.cancel_pending(rec_idx)
    if rec_idx == nil or Placed.pending[rec_idx] ~= true then return false end
    Placed.pending[rec_idx] = nil
    Placed.pending_actor[rec_idx] = nil
    if Placed.pending_count() == 0 then Placed.pending_since = nil end
    Placed.last_pending_n = Placed.pending_count()
    return true
end

--- 待处理条数（状态行/日志用）
function Placed.pending_count()
    local n = 0
    for _ in pairs(Placed.pending) do n = n + 1 end
    return n
end

--- 落地确认成功: 记下这个 actor（"拆掉检测"要用）。
--- 注意: 这时那一件可能还在"待隐藏"队列里 ⇒ 先放 pending_actor，批量结束时并进 refs。
function Placed.stash_actor(rec_idx, actor)
    if rec_idx == nil or actor == nil then return end
    if Placed.hidden[rec_idx] == true then
        Placed.refs[rec_idx] = actor
    else
        Placed.pending_actor[rec_idx] = actor
    end
end

--- 落地确认成功（旧名字，保留兼容）: 记下这个 actor
function Placed.confirm_hidden(rec_idx, actor)
    Placed.stash_actor(rec_idx, actor)
end

--- 撤销隐藏（游戏没建出来时用）。返回 true 表示确实撤销了
function Placed.unhide(rec_idx)
    if rec_idx == nil then return false end
    local did = false
    if Placed.pending[rec_idx] == true then
        Placed.pending[rec_idx] = nil
        Placed.pending_actor[rec_idx] = nil
        Placed.last_pending_n = Placed.pending_count()
        did = true
    end
    if Placed.hidden[rec_idx] == true then
        Placed.hidden[rec_idx] = nil
        Placed.refs[rec_idx] = nil
        Placed.last_n = Placed.count()
        did = true
    end
    if did then Placed.version = Placed.version + 1 end          -- 进度变了
    return did
end

--- 记录集是否为空（给状态行用）
function Placed.count()
    local n = 0
    for _ in pairs(Placed.hidden) do n = n + 1 end
    return n
end

--- ★ 全扫一遍: 把"已经放上了"的记录标出来。
--- 返回 隐藏件数, 说明（失败时返回 nil, 原因）
function Placed.refresh(bp, place, claimed_outside)
    -- ★★ 自保: 这条路径要**枚举关卡建筑**，而 `level.Actors` 会保留已摧毁的
    --   actor（读它 = 原生访问违例，见 pwpr_config.lua 的 ghost_hide_enum）。
    --   默认关闭；只有显式打开才允许跑。
    if cfg_get("ghost_hide_enum") ~= true then
        return nil, "枚举已关闭（ghost_hide_enum = false）"
    end
    if cfg_get("ghost_hide_placed") ~= true then
        Placed.hidden = {}
        Placed.refs = {}
        Placed.last_src = "功能已关闭"
        return 0, "功能已关闭"
    end
    if type(bp) ~= "table" or type(bp.buildings) ~= "table" or place == nil then
        return nil, "没有蓝图/投影位置"
    end
    -- ★ 把"待批量处理"的先并进 hidden —— 这样在批量窗口结束前按 K / 换层，
    --   已经放上的那些也不会被这次全扫"忘掉"。
    for idx in pairs(Placed.pending) do
        Placed.hidden[idx] = true
        local actor = Placed.pending_actor[idx]
        if actor ~= nil then Placed.refs[idx] = actor end
    end
    Placed.pending = {}
    Placed.pending_actor = {}

    local n_rec = #bp.buildings
    if n_rec > Placed.max_records then
        Placed.hidden = {}
        Placed.last_src = string.format("记录太多（%d > %d），跳过", n_rec,
            Placed.max_records)
        return nil, Placed.last_src
    end

    local Snap = nil
    local okr = pcall(function() Snap = require("pwpr_snap") end)
    if not okr or Snap == nil or Snap.gather == nil then
        return nil, "拿不到 pwpr_snap（不做隐藏）"
    end

    -- 收集范围: 投影记录到原点最远有多远 + 判定半径 ⇒ 范围内没有遗漏
    local reach = 0.0
    for i = 1, n_rec do
        local b = bp.buildings[i]
        if type(b) == "table" and type(b.p) == "table" then
            local d = math.sqrt((tonumber(b.p[1]) or 0.0) ^ 2
                + (tonumber(b.p[2]) or 0.0) ^ 2
                + (tonumber(b.p[3]) or 0.0) ^ 2)
            if d > reach then reach = d end
        end
    end
    local near_cm = tonumber(cfg_get("ghost_hide_placed_cm")) or 40.0
    local radius_cm = reach * 100.0 + near_cm

    local anchors, src = Snap.gather(place.x, place.y, place.z, radius_cm)
    if anchors == nil then
        return nil, "扫真实建筑失败: " .. tostring(src)
    end
    -- ★★★ 2026-09-29 玩家实测抓到的第二个问题:
    --   "切换回原来的蓝图位置，反倒是把所有建过/没建过的都投影了"。
    --   原因: 这次扫描如果**一件参照都没扫到**，`apply_anchors` 会算出空名单
    --   ⇒ 把"已经放上的"整个清空 ⇒ 投影把建过的也画出来 ✗
    --   ⇒ 现在: **扫不到参照 = 这次没测到东西** ⇒ **保留上一次的名单**（不清空）。
    --   这样"拆掉之后按 K 重放"仍然有效（只要附近还有别的参照 ⇒ 名单会重算），
    --   但"在别的地方/扫描失败"不会把进度洗掉。
    if #anchors == 0 then
        Placed.last_src = "扫到 0 件参照 ⇒ 本次不更新已放上名单（保留上次的 "
            .. tostring(Placed.count()) .. " 件）"
        Log.emit("  [placed] " .. Placed.last_src)
        return Placed.count(), Placed.last_src
    end
    -- 剩下的匹配/点名逻辑和"分片全扫"共用（见 apply_anchors）
    return Placed.apply_anchors(bp, place, anchors, claimed_outside)
end

--- ★★ **分片全扫**（2026-09-29 加的，为修"每次刷新都卡一下"）
---
--- 为什么: 兜底全扫原来一次读完**整个关卡**的建筑列表（实测 600+ 个 actor，
---   每个还要读位置/类型/朝向 —— 全是跨 Lua/引擎边界的调用），
---   这一趟集中在**同一帧**里 ⇒ 玩家看到的就是"每隔几秒卡一下"。
---   （以前没被发现，是因为这个全扫**从来没跑起来过**，见 §59。）
---
--- 现在拆成两块优化:
---   ① **只关心"已隐藏的那几条记录的类型"** —— 类型对不上的 actor
---      连位置都不用读（省掉一半以上的反射调用）；
---   ② **每个 tick 只读一小片**（默认 150 个）⇒ 一趟扫完约 4~5 个 tick
---      （约 10 秒），但**任何一帧的开销都很小**，不再有可见的卡顿。
---
--- 返回: nil, "progress"（还没扫完） / 记录序号表（扫完了，可能为空表）
function Placed.scan_step(max_n)
    local deps = Placed.deps
    if deps == nil or deps.context == nil then return nil, "没有 context" end
    local ok, bp, place = pcall(deps.context)
    if not ok or bp == nil or place == nil then
        Placed.scan = nil
        return nil, "没有投影"
    end

    -- 没在扫就开一趟（**只在确实藏了东西时才扫** —— 没藏东西时完全零开销）
    -- ★★ 自保（两道）: 周期性扫描要**两个开关都开**才允许跑 ——
    --   `ghost_hide_enum`（允许枚举）+ `ghost_hide_scan`（允许周期性扫描）。
    --   后者是两次崩溃的路线（拆完建筑后读到 pending-kill 对象），默认关。
    if cfg_get("ghost_hide_enum") ~= true
        or cfg_get("ghost_hide_scan") ~= true then
        Placed.scan = nil
        return {}, "周期性扫描已关闭"
    end

    local s = Placed.scan
    if s == nil then
        if Placed.count() == 0 then return {}, "nothing-hidden" end
        local types = {}
        for idx in pairs(Placed.hidden) do
            local b = bp.buildings[idx]
            if type(b) == "table" then types[Util.norm_id(b.t)] = true end
        end
        if next(types) == nil then return {}, "no-types" end
        local Capture = nil
        pcall(function() Capture = require("pwpr_capture") end)
        if Capture == nil or Capture.list_build_actors == nil then
            return nil, "拿不到建筑列表"
        end
        local objs, src = Capture.list_build_actors()
        if objs == nil then return nil, "列不出建筑: " .. tostring(src) end
        s = { objs = objs, cursor = 1, types = types, anchors = {} }
        Placed.scan = s
    end

    -- 这一片: 读 150 个 actor（类型不关心就只读类型）
    local upto = math.min(#s.objs, s.cursor + (max_n or 150) - 1)
    for i = s.cursor, upto do
        local obj = s.objs[i]
        local t = nil
        pcall(function() t = Util.type_of(obj) end)
        local k = (t ~= nil) and Util.norm_id(t) or ""
        if k ~= "" and s.types[k] == true then
            local x, y, z = Util.loc_of(obj)
            if x ~= nil then
                s.anchors[#s.anchors + 1] = { x = x, y = y, z = z, t = t, obj = obj }
            end
        end
    end
    s.cursor = upto + 1
    if s.cursor <= #s.objs then
        return nil, string.format("progress %d/%d", upto, #s.objs)
    end

    -- 读完了 ⇒ 用这批参照重算名单（和完整 refresh 用同一套匹配）
    local anchors = s.anchors
    local n_objs = #s.objs
    Placed.scan = nil
    -- ★ 注意: apply_anchors 的第一个返回值是"隐藏件数（数字）"，
    --   而这里要返回的是"变了哪几条"（表）—— 用 last_delta，别搞混。
    pcall(Placed.apply_anchors, bp, place, anchors)
    local delta = Placed.last_delta or {}
    Placed.last_src = string.format("分片全扫: %d/%d 个参照, 隐藏 %d 件",
        #anchors, n_objs, Placed.count())
    return delta, "done"
end

--- 用一批"真实建筑参照"重算隐藏名单。返回"变化了的记录序号表"。
--- （完整全扫 `refresh` 与分片全扫 `scan_step` 共用这一段）
--- ★★★ 2026-09-29 玩家实测（问题 2 最后一次）:
---   「H 移动的时候展示的是不完整的投影（排除了已放置的）」。
---   真因: 扫描是"拿真实建筑按位置去认领记录"，而**旧基地的建筑也可能正好落在
---   新位置的网格上**（规则网格平移整格 ⇒ 几何上完全无法区分）⇒ 它把**别处的**建筑
---   认成"这里建过" ⇒ 刚按 H 放下的新投影就缺件 ✗
---   （新加的"排他表"就是为此: 一条实物如果已经被**别的记录**认领了，这次扫描不许再认领）
function Placed.apply_anchors(bp, place, anchors)
    -- ★★★★★ 2026-09-29 玩家实测（问题 2 的最终解）—— **扫描只减不增**:
    --
    -- 历史: 这个函数原来是"拿真实建筑按位置**认领**记录"（认领 = 往名单里加）。
    --   而蓝图是**规则网格** ⇒ 网格平移整数格之后，"别处已建好的那一片"会**正好落在
    --   新位置的网格上** ⇒ 几何上完全无法区分 ⇒ 被误认成"这里建过" ⇒
    --   ① 按 `H` 放到新位置的投影立刻缺件（"W1 对应的位置还是没有显示"）✗
    --   ② 在 B 放的件会被算到 A 的头上（"切回 A，W1 和 W2 都没显示"）✗
    --   我试过"排他表"去救（一条实物只归一处），但治标不治本 —— 认领这件事本身就带歧义。
    --
    -- ⇒ 现在的职责划分（简单、可预测）:
    --   · **"已放上"名单只由两处产生**: ① `Placed.hide_now`（吸附时的**精确通道** ——
    --     它明确知道"我正要往第几条放"，不需要猜）；② 记录里存的进度（`Resume`）。
    --   · **扫描只负责"减"**: 名单里某一条，如果它的世界坐标附近**没有**真实建筑了
    --     ⇒ 说明被拆了 ⇒ 从名单里去掉（这就是"拆掉自动恢复"）。
    --   · **扫描绝不往里加** ⇒ 不会再出现"别处的建筑被认成本处建过"这类串味 ✓
    --
    -- 代价（明确写在这里）: **不是通过本模组放的老建筑不会被自动识别**（投影会照常画它们）。
    --   要做到"旧基地也认出来"，就按 `K` 时让吸附去逐件放置（精确通道会登记）——
    --   这比"猜"可靠得多；而且"缺件显示"本来就是给"用蓝图继续建"用的。
    local near_cm = tonumber(cfg_get("ghost_hide_placed_cm")) or 40.0
    local near2 = near_cm * near_cm
    local n_rec = #bp.buildings
    local prev_hidden = Placed.hidden or {}

    -- 参照（真实建筑）按 1 米网格归档，方便"这一条附近还有没有实物"的查询
    local span = math.max(1, math.ceil(near_cm / 100.0))
    local grid = {}
    for i = 1, #anchors do
        local a = anchors[i]
        local k = string.format("%d:%d:%d", math.floor(a.x / 100.0),
            math.floor(a.y / 100.0), math.floor(a.z / 100.0))
        local l = grid[k]
        if l == nil then l = {}; grid[k] = l end
        l[#l + 1] = a
    end

    --- 这一条记录的世界坐标附近，有没有真实建筑？（返回实物或 nil）
    local function find_real(wx, wy, wz)
        local cx = math.floor(wx / 100.0)
        local cy = math.floor(wy / 100.0)
        local cz = math.floor(wz / 100.0)
        for ox = -span, span do
            for oy = -span, span do
                for oz = -span, span do
                    local l = grid[string.format("%d:%d:%d",
                        cx + ox, cy + oy, cz + oz)]
                    if l ~= nil then
                        for j = 1, #l do
                            local a = l[j]
                            local dx, dy, dz = a.x - wx, a.y - wy, a.z - wz
                            if dx * dx + dy * dy + dz * dz <= near2 then
                                return a
                            end
                        end
                    end
                end
            end
        end
        return nil
    end

    local hidden = {}
    local fresh_refs = {}
    local n_kept, n_dropped = 0, 0
    local dropped_show = {}
    for idx in pairs(prev_hidden) do
        local b = bp.buildings[idx]
        local wx, wy, wz = record_world(place, b)
        if wx == nil then
            hidden[idx] = true              -- 算不出坐标 ⇒ 不猜，保留
            n_kept = n_kept + 1
        else
            local a = find_real(wx, wy, wz)
            if a ~= nil then
                hidden[idx] = true          -- 实物还在 ⇒ 继续不画
                if a.obj ~= nil then fresh_refs[idx] = a.obj end
                n_kept = n_kept + 1
            else
                n_dropped = n_dropped + 1   -- 实物没了 ⇒ 恢复渲染（拆掉自动恢复）
                if #dropped_show < 6 then
                    dropped_show[#dropped_show + 1] = "#" .. tostring(idx)
                end
            end
        end
    end

    local prev_n = 0
    for _ in pairs(prev_hidden) do prev_n = prev_n + 1 end
    if prev_n > 0 and n_kept == 0 and n_dropped > 0 and #anchors == 0 then
        -- 一件参照都没有（多半是在别的地方/刚读档）⇒ **不判"全拆了"**，保留原名单
        Placed.last_delta = {}
        Placed.last_n = prev_n
        Placed.last_src = string.format(
            "扫到 0 件参照 ⇒ 本次不改名单（保留 %d 件）", prev_n)
        Log.emit("  [placed] " .. Placed.last_src)
        return prev_n, Placed.last_src
    end

    Placed.hidden = hidden
    Placed.refs = fresh_refs
    Placed.last_hidden_note = (#dropped_show > 0)
        and ("恢复渲染: " .. table.concat(dropped_show, " ")) or nil

    local delta = {}
    for i in pairs(hidden) do
        if prev_hidden[i] ~= true then delta[#delta + 1] = i end
    end
    for i in pairs(prev_hidden) do
        if hidden[i] ~= true then delta[#delta + 1] = i end
    end
    Placed.last_delta = delta
    Placed.last_n = n_kept
    Placed.last_pair_note = string.format(
        "只减不增: 核对 %d 件（%d 件确认还在 / %d 件已拆⇒恢复渲染）；%d 件参照",
        prev_n, n_kept, n_dropped, #anchors)
    Placed.last_src = Placed.last_pair_note
    if n_dropped > 0 or prev_n > 0 then
        Log.emit("  [placed] " .. Placed.last_pair_note)
    end
    Placed.version = Placed.version + 1
    return n_kept, Placed.last_src
end


--- ★ 新建筑出现时**只做记录**，不再拿它去匹配（2026-09-29 实测教训）。
---
--- 为什么把"直接匹配"删掉:
---   `NotifyOnNewObject` 触发得**太早**，那一刻新 actor 的位置/类型还没填好
---   （一次会话里 80 次改发 / 33 次确认建出，而这条快路径 **0 次命中**；
---   更糟的是它偶尔会读到一个**不可靠的位置**，于是把**旁边那条记录**也藏了 ——
---   玩家实测:「除了放置的那块，还会把他边上的某块也一起取消投影，
---   在下一次放置的时候又给他补回去」（下一次全扫是可靠的 ⇒ 自动纠正）。
---   ⇒ 结论: **只留可靠的那条路**（收到通知 → 排一次重灌 → 里面的全扫），
---     这条只把读到的值写进日志，供以后排查。
--- 返回: 永远 nil（调用方不要再据此决定"要不要重灌"）
function Placed.note_new_object(obj)
    if obj == nil then return nil end
    local Snap = nil
    pcall(function() Snap = require("pwpr_snap") end)
    if Snap == nil then return nil end
    local a = nil
    pcall(function() a = Snap.read_anchor(obj) end)
    if a == nil then
        Placed.last_read = "通知时读不到位置/类型（太早）"
    else
        Placed.last_read = string.format("%s @ (%.0f,%.0f,%.0f)",
            tostring(a.t), a.x, a.y, a.z)
    end
    Log.line("  [placed] 新建筑通知（只记录，不据此隐藏）: " ..
        tostring(Placed.last_read))
    return nil
end

--- ★ 轻量检查: 我们隐藏的那些实物还在不在（拆掉 ⇒ 解除隐藏）。
--- 返回 true 表示"有变化，应该重灌一次"（调用方负责重灌）
---
--- ⚠️ 2026-09-29 玩家实测: 这条**有时不灵**（"拆除后没效果，只能按两次 K"）——
---   游戏的拆除不一定会让 `Util.valid` 立刻变 false（可能先播动画/延迟销毁，
---   也可能对象被回收后 IsValid 仍然撒谎）。
---   ⇒ 所以调用方现在还会**每隔几秒做一次全扫**（成本很低: 实测这个基地只读
---     677 个 actor），全扫的结果才是权威的。这里保留快路径只是为了
---     "拆了以后 2.5 秒内就恢复"这种更好的手感。
function Placed.check_alive()
    -- ★★ 自保: 这条路径默认是**关**的（`ghost_hide_alive_check`）——
    --   它会对可能已摧毁的 actor 调引擎函数，而原生崩溃 pcall 抓不住。
    --   这里再拦一道，防止以后有别的调用方误用它。
    if cfg_get("ghost_hide_alive_check") ~= true then return nil end
    -- ★ 没有句柄 = 快路径**查不了**（2026-09-29 实测踩过: 那些件只能等十几秒的
    --   兜底全扫，玩家体感就是"拆掉恢复不触发了"）。这里明确写出来，
    --   免得下次又要从"没反应"倒推。
    if next(Placed.refs) == nil then
        if Placed.count() > 0 then
            Log.line(string.format(
                "  [placed] 拆掉检查: **0 个句柄**（藏了 %d 件，但这些件没记到 actor "
                .. "⇒ 只能等兜底全扫；看上面的入队/批量隐藏日志找原因）",
                Placed.count()))
        end
        return nil
    end
    local changed = {}
    local checked, alive_n = 0, 0
    for idx, actor in pairs(Placed.refs) do
        local alive = false
        pcall(function() alive = Util.valid(actor) end)
        checked = checked + 1
        if alive then
            alive_n = alive_n + 1
        else
            Placed.refs[idx] = nil
            if Placed.hidden[idx] == true then
                Placed.hidden[idx] = nil
                changed[#changed + 1] = idx
                Log.emit(string.format(
                    "  [placed] 记录 #%d 的实物没了（拆掉/被摧毁）⇒ 恢复渲染它", idx))
            end
        end
    end
    -- ★ 把"检查了几个、几个还活着"写进日志 —— 下次就能看出这条快路径到底灵不灵
    --   （如果一直显示"全部存活"而玩家明明拆了，那就是 IsValid 在撒谎）。
    Log.line(string.format("  [placed] 拆掉检查: %d 个引用，%d 个存活",
        checked, alive_n))
    if #changed > 0 then
        local Ghost = nil
        pcall(function() Ghost = require("pwpr_ghost") end)
        if Ghost ~= nil then Ghost.skip = Placed.hidden end
        Placed.last_n = Placed.count()
    end
    return changed
end

--- ★ 定时全扫: 返回**变化了的记录序号表**（没变就是空表）。
--- 调用方拿着这个表去 `Ghost.rehide(表)` ⇒ 只重灌受影响的组，不重灌整个投影。
function Placed.refresh_delta()
    local deps = Placed.deps
    if deps == nil or deps.context == nil then return nil end
    local ok, bp, place = pcall(deps.context)
    if not ok or bp == nil or place == nil then return nil end
    local n_ok = pcall(Placed.refresh, bp, place)
    if not n_ok then return nil end
    local delta = Placed.last_delta or {}
    if #delta > 0 then
        Log.emit(string.format(
            "  [placed] 定时全扫: 名单变了 %d 条（现在共隐藏 %d 件）",
            #delta, Placed.count()))
    else
        Log.line("  [placed] 定时全扫: 名单没变（隐藏 "
            .. tostring(Placed.count()) .. " 件）")
    end
    return delta
end

--- 隐藏名单的"指纹"（只用来比较变没变）
function Placed.signature()
    local keys = {}
    for i in pairs(Placed.hidden) do keys[#keys + 1] = i end
    table.sort(keys)
    return table.concat(keys, ",")
end

--- 给状态行（F7）用的一句话
function Placed.status_line()
    if cfg_get("ghost_hide_placed") ~= true then
        return "已放上的不渲染: 关（ghost_hide_placed = false）"
    end
    local extra = ""
    if Placed.last_read ~= nil then
        extra = "；最近一次新建筑通知读到: " .. tostring(Placed.last_read)
    end
    if cfg_get("ghost_hide_scan") ~= true then
        return string.format(
            "已放上的不渲染: 开（精确隐藏 %d 件，待处理 %d；按 K 会扫一遍标出"
            .. "已放过的件）；**自动发现拆除: 关**（ghost_hide_scan=false，防崩）"
            .. "—— 拆掉的件按 K 收起再放一次就会重新画出来",
            Placed.count(), Placed.pending_count())
    end
    return string.format("已放上的不渲染: 开（隐藏 %d 件，待处理 %d，%d 个可追踪；%s%s）",
        Placed.count(), Placed.pending_count(), (function()
            local n = 0
            for _ in pairs(Placed.refs) do n = n + 1 end
            return n
        end)(), tostring(Placed.last_src or "还没扫过"), extra)
end

return Placed
